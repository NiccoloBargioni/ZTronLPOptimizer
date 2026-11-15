# ZTronLPOptimizer

Linear programming (LP) and mixed-integer linear programming (MILP) for Apple platforms,
written in Swift on top of Accelerate.

This page is the view from outside: what the package is for, every public declaration and what
it costs, what can go wrong, and what was measured. How it is built — the design decisions,
the target layout, the test strategy, the complete benchmark output and the list of deviations
from the specification — is in [HANDBOOK.md](HANDBOOK.md).

| | |
|---|---|
| Version | 0.1; implements *ZTronLPOptimizer — Technical Specification v0.1* |
| Platforms | iOS 15, macOS 12, Mac Catalyst 15 |
| Toolchain | Swift tools 6.0, Swift 6 language mode. Built and tested with Swift 6.4 only |
| Dependencies | `swift-atomics`, `swift-collections`; Accelerate and, optionally, Metal from the SDK |
| Verified on | One machine: Apple M3, macOS 27. Built, but not run, for iOS and Mac Catalyst |

1. [Intent](#1-intent)
2. [Public API](#2-public-api)
3. [Risk assessment](#3-risk-assessment)
4. [Known defects and limits](#4-known-defects-and-limits)
5. [Measured performance](#5-measured-performance)

## 1. Intent

**What it is for.** An app that has to make an optimal decision on the device — a plan, a
schedule, an assignment, a blend — states it as a linear model in Swift and gets back the
optimum, or a clear statement of why there is none. There is no server, no solver binary to
ship and no C++: the package is Swift on Accelerate (BLAS, LAPACK, vDSP, Sparse Solvers), with
an optional Metal tier.

**What goes in.** A model declared with the typed DSL (`LPModel`), an MPS or LP file, or a
`CompiledLP` built by hand: minimize or maximize a linear objective subject to linear
constraints and bounds, over continuous, integer and binary variables.

**What comes out.** Always a status first (`SolveStatus`). Then, as far as the status allows:
the objective value, a proven bound, the variable values, duals and reduced costs, a
certificate when the model is infeasible or unbounded, and the facts of the engine that ran
(iterations, final basis, nodes, conflicts).

**What it promises.**

1. *A nonlinear model does not compile.* Expressions are linear by construction; there is no
   product of two expressions.
2. *One algorithm, one value.* Each solver is a `SolverStrategy` configured in its
   initializer: `Simplex`, `InteriorPoint`, `BranchAndBound`, `CPSAT`. `Automatic` chooses
   one, `Portfolio` races several, `Conditioned` adds a numerical report. Run-level resources
   — time, threads, memory, progress — travel separately, in `SolveContext`.
3. *Stopping is a result, never an error.* A time limit, an iteration or node limit, the
   memory budget and task cancellation all return what exists so far. `solve` throws only
   `SolverError`, and only for a model that is invalid or outside what the engine accepts.
4. *Double precision decides.* Feasibility and optimality are decided in IEEE double on the
   CPU. The GPU tier only proposes candidates, which the CPU checks again.
5. *A solve is a good citizen.* It does not block a thread of the cooperative pool, answers
   cancellation within milliseconds (4.4 ms at worst over 240 measured solves), bounds the
   memory of its search, and delivers `.finished` as the last progress event exactly once.
6. *Reproducible on request.* `BranchAndBound(deterministic: true)` and
   `CPSAT(deterministic: true)` give the same result and the same event sequence every run.

**What it is not.** Not a replacement for HiGHS, Gurobi or CPLEX on large or hard models:
there is no sparse LU, there are no cutting planes, and the presolve is small
([Known defects and limits](#4-known-defects-and-limits)). Not for quadratic or nonlinear
models. Not for Linux: every engine needs Accelerate.

### Adding it to a project

The package has no remote yet, so it is added by path:

```swift
// Package.swift of the app or package that uses it
dependencies: [
    .package(path: "../ZTronLPOptimizer"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ZTronLPOptimizer", package: "ZTronLPOptimizer"),
    ]),
]
```

`import ZTronLPOptimizer` brings in everything section 2 lists. Each layer is also a product
of its own (`ZTronLPCore`, `ZTronLPSimplex`, …) for a client that wants less.

### What using it looks like

```swift
import ZTronLPOptimizer

enum Product: CaseIterable, Sendable { case chair, table, desk }

enum Plan: LPVariable {
    case make(Product)      // units to build
    case overtime           // whether to open the extra shift

    var domain: VariableDomain {
        switch self {
        case .make: return .integer     // whole units, x ≥ 0
        case .overtime: return .binary
        }
    }
}

let profit: [Product: Double] = [.chair: 45, .table: 80, .desk: 110]
let hours:  [Product: Double] = [.chair: 5,  .table: 20, .desk: 15]
let wood:   [Product: Double] = [.chair: 10, .table: 15, .desk: 25]

let model = LPModel<Plan>()
    .maximizing(sum(over: Product.allCases) { profit[$0]! * Plan.make($0) } - 400 * Plan.overtime)
    .subjectTo {
        (sum(over: Product.allCases) { hours[$0]! * Plan.make($0) } <= 250 + 150 * Plan.overtime)
            .named("hours")
        (sum(over: Product.allCases) { wood[$0]! * Plan.make($0) } <= 650)
            .named("wood")
    }

var context = SolveContext()
context.timeLimit = 5                               // seconds; reaching it is a result, not an error

let solution = try await Automatic().solve(model, context: context)

switch solution.status {
case .optimal:                                      // proven, within the MIP gap
    print(solution.objectiveValue!)                 // 2600.0
    print(solution.value(of: .make(.chair)))        // 56.0
    print(solution.value(of: .overtime))            // 1.0
case .feasible(let reason):                         // an incumbent; `reason` says what stopped the search
    print("stopped by \(reason)")
case .infeasible, .unbounded, .infeasibleOrUnbounded, .noSolution, .numericalFailure:
    print("nothing to read: \(solution.status)")
}

// The same model as a plain LP, for its shadow prices.
let relaxed = model.continuous(forEach: Product.allCases, Plan.make).continuous(.overtime)
let lp = try await Simplex(.dual).solve(relaxed)
print(lp.objectiveValue!)                           // 2725.0: the relaxation opens half a shift
print(lp.dual(ofConstraintNamed: "wood")!)          // 3.1666…: what one more unit of wood is worth
print(lp.analysis.iterations)                       // engine facts, typed per engine
```

The declarations, the model and the numbers of this example are compiled and checked by
`Tests/ZTronLPOptimizerTests/ReadmeExampleTests.swift`.

## 2. Public API

Everything `import ZTronLPOptimizer` makes visible: the declarations of the facade target and
of the eight library targets it re-exports (`ZTronLPCore`, `ZTronLPNumerics`, `ZTronLPSimplex`,
`ZTronLPInteriorPoint`, `ZTronLPBranchAndBound`, `ZTronLPCPSAT`, `ZTronLPMetal`,
`ZTronLPConditioning`). `ZTronLPTestSupport` and the `ZTronLPBenchmarks` executable are not
part of it. That is 117 top-level declarations and 22 nested types, with about 700 public
members and enum cases between them.

Most apps touch a small part of this surface: the modelling types of 2.1, a strategy of 2.5,
`SolveContext` and `SolveStatus` of 2.3 and `Solution` of 2.4. The rest is there for a caller
who reads files, builds problems by hand, writes a strategy of their own, or wants the
numerical blocks the engines are made of.

### Reading the tables

Each row is one public declaration, or one group of members of a larger type that share a
cost; nested types are named in the row of their parent. **Related** names the declarations it
is used with. **Time** and **Space** are worst-case bounds in the symbols below unless the
cell says otherwise. On a plain value type, O(1) means a fixed number of fields.

| Symbol | Meaning |
|---|---|
| `m`, `n`, `z` | Rows, columns and stored nonzeros of the constraint matrix A |
| `t`, `T` | Terms of one expression; terms of the whole model (objective plus every constraint) |
| `L` | Characters of a text that is read or written |
| `I` | Simplex pivots of a solve; capped at max(50,000, 100·(m + n)) unless `maxIterations` is given |
| `K` | Interior-point iterations; at most `maxIterations`, 200 by default |
| `N`, `C` | Branch-and-bound nodes processed; CP-SAT conflicts |
| `F` | One basis factorization. Dense LU: ⅔·m³ flops, 8·m² bytes held and as much again while it is rebuilt. Sparse QR: depends on fill-in |
| `S` | One solve with a factored basis. Dense LU: 2·m² flops plus the update file (at most 100 updates of at most m entries). Sparse QR: one sparse solve plus the update file (at most 50 updates) |
| `W` | Worker tasks of a solve: `SolveContext.resolvedThreads`, the active processor count by default |
| exp. | Expected, not worst-case: the bound relies on hashing |

Three things to know before reading the bounds:

- **Search has no polynomial bound.** The number of simplex pivots `I`, of nodes `N` and of
  conflicts `C` can grow exponentially with the size of the model. The tables give the cost
  per pivot, node or conflict and the limit that ends the run; section 5 has what was measured.
- **Sparse factorizations have no closed form.** The cost of Accelerate's sparse QR and
  Cholesky depends on the fill-in, which depends on the pattern of the matrix.
- **Memory is budgeted, partly.** `SolveContext.memoryBudgetBytes` (a quarter of the available
  memory by default) bounds what a search accumulates — open nodes, learned clauses — and
  not the working storage of one LP solve.

### 2.1 Modelling

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `LPVariable` | Protocol of a variable family: usually an enum, with an indexed variable as a case with associated values. Both requirements have defaults: `domain` (`.continuous`) and `name` (derived from the case's description). | `VariableDomain`, `LPName`, `LinearExpressible`, `LPModel` | `domain` O(1); default `name` O(length of the description) | O(1) |
| `VariableKind` | `.continuous`, `.integer`, `.binary`. | `VariableDomain`, `LPModel` | O(1) | O(1) |
| `Bounds` | Interval `[lower, upper]`, either end may be infinite. Presets `.nonNegative`, `.free`, `.unit`; `fixed(_:)`, `range(_:)`, `atLeast(_:)`, `atMost(_:)`; `intersection(_:)`, `isFixed`. | `VariableDomain`, `LPModel`, `BoundChange` | O(1) | O(1) |
| `VariableDomain` | A kind plus bounds. Presets `.continuous` (x ≥ 0), `.free`, `.integer` (x ≥ 0), `.binary`; `continuous(_:)` and `integer(_:)` take `Bounds`. | `LPVariable`, `VariableKind`, `Bounds` | O(1) | O(1) |
| `LPName` | Name helpers for export and diagnostics: `derived(fromDescription:)`, `sanitized(_:)`, `uniqued(_:)`. | `LPVariable`, `LPNames`, `LPFormat`, `MPSFormat` | O(characters); `uniqued` exp. | O(characters) |
| `LinearExpressible` | Anything usable where an expression is expected: a variable or a `LinearExpr`. `linearExpr` converts; `within(_:)` and `equal(to:)` build constraints. `_accumulate(into:scale:)` is the requirement the operators are built on, not something to call. | `LinearExpr`, `LPVariable`, `LinearConstraint` | O(t) | O(t) |
| `LinearExpr` | Canonical linear form Σ aᵢ·xᵢ + k: each variable once, no zero coefficient, insertion order kept. `constant`, `variables`, `coefficients`, `count`, `isConstant`, `subscript`, `add(_:_:)`, `add(constant:)`, `reserveCapacity(_:)`, `evaluated(_:)`, `description`; `Hashable` regardless of term order. | `LinearExpressible`, `LinearConstraint`, `LPModel`, `sum(over:_:)` | Lookup and `add` O(1) exp. (a scan up to 8 terms; removing a term that cancels is O(t)); `evaluated`, `==`, `hash`, `description` O(t) | O(t), plus a hash index above 8 terms |
| `+`, `-`, `*`, `/`, unary `-`, `+=`, `-=`, `*=`, `/=` | Arithmetic between expressions, variables and `Double`. No product of two expressions exists. | `LinearExpr`, `LinearExpressible` | O(terms of the operands) exp. | O(terms of the result) |
| `sum(over:_:)`, `LinearExpr.sum(over:_:)` | The sum of a closure over a sequence, accumulated in place; nests to any depth. | `LinearExpr` | O(terms produced) exp.: linear, not quadratic | O(distinct variables) |
| `LinearConstraint` | `lower ≤ expr ≤ upper`, optionally named: `expr`, `lower`, `upper`, `name`, `named(_:)`, `description`. | `LinearExpr`, `Constraints`, `LPModel`, `LoweredConstraint` | O(t) to build; `named(_:)` O(1) | O(t) |
| `<=`, `>=`, `==` | Build a `LinearConstraint` from two expressions, or from an expression and a `Double` on either side. | `LinearConstraint`, `LinearExpressible` | O(t) exp. | O(t) |
| `Constraints` | The result builder behind `subjectTo { … }` and `add { … }`: single constraints, arrays, `for`, `if`/`else`. Its `buildExpression`, `buildBlock`, `buildArray`, `buildOptional` and `buildEither` are what the compiler calls. | `LPModel`, `LinearConstraint` | O(constraints collected) | O(constraints collected) |
| `ObjectiveSense` | `.minimize`, `.maximize`. | `LPModel`, `CompiledLP` | O(1) | O(1) |
| `LPModel` — building | The model as declared: `objective`, `sense`, `constraints`, `boundOverrides`, `kindOverrides`. Chainable `minimizing`, `maximizing`, `subjectTo` (one constraint, a builder, or `forEach:`), `bounding` (one variable, or `forEach:` over one to three sequences), `integer`, `binary`, `continuous`; mutating `setObjective`, `add`, `setBounds`, `setKind`. | `LinearExpr`, `LinearConstraint`, `Constraints`, `Bounds`, `VariableKind` | O(1) amortized per constraint or override, plus building its expression | O(T) |
| `LPModel.compile(options:)` | Validates the model and lowers it to a `CompiledModel`. Throws `SolverError.invalidModel`. | `CompileOptions`, `CompiledModel`, `ModelDiagnostic`, `SolverStrategy` | O(T·log(longest row)) exp. | O(z + m + n) |
| `LPModel.lpString()`, `LPModel.mpsString(free:)` | Compile, then write the problem as text. | `LPFormat`, `MPSFormat` | One `compile` plus O(z + m + n) | O(L) |
| `CompileOptions` | `lowerSingletonConstraints` (a one-variable constraint becomes a bound; on by default), `dropTolerance` (1e-14), `diagnostics` (a callback for warnings). | `LPModel`, `LoweredConstraint`, `ModelDiagnostic` | O(1) | O(1) |

### 2.2 The compiled problem, presolve, scaling, files

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `CompiledModel` | What `compile` returns: the problem (`lp`) and the maps back to the DSL — `column`, `variableAt`, `rowNamed`, `lowered`, `diagnostics`. | `LPModel`, `CompiledLP`, `Solution`, `LoweredConstraint` | Lookups O(1) exp. | O(n + constraints) beside `lp` |
| `LoweredConstraint` | Record of a one-variable constraint that became a bound (`column`, `coefficient`, `lower`, `upper`), kept so that its dual can still be reported. | `CompiledModel`, `Solution`, `CompileOptions` | O(1) | O(1) |
| `CompiledLP` — data | The problem every strategy solves: `min` or `max` of cᵀx + c0 with rl ≤ Ax ≤ ru and xl ≤ x ≤ xu. `m`, `n`, `a`, `aT`, `c`, `c0`, `sense`, `xl`, `xu`, `rl`, `ru`, `integerColumns`, `names`, `scaling`, `nnz`, `hasIntegerColumns`, `integerMask()`. Immutable; its initializer builds one by hand. `c` and `c0` are stored for minimization, `sense` records what the model asked for. | `SparseCSC`, `LPNames`, `Scaling`, `SolverStrategy`, `MPSFormat`, `LPFormat` | Initializer O(z + m + n), O(1) when the transpose is passed in; `integerMask()` O(n) | About 24·z + 32·n + 24·m bytes (A, its transpose, costs, bounds) plus the names |
| `CompiledLP` — evaluation | `objective(at:)`, `internalObjective(at:)`, `reportedObjective(_:)`, `rowActivity(_:)`, `maxViolation(at:)`, `reducedCosts(forDuals:)`: check a point or a dual vector against the problem. | `SolutionAnalysis`, `Solution` | Objective O(n); the others O(z + m + n) | O(m + n) |
| `CompiledLP` — derivation | `withColumnBounds(xl:xu:)`, `withRowBounds(rl:ru:)`, `withObjective(_:constant:)`, `relaxed()`, `applying(_:)`: a copy with other bounds, another objective, no integrality, or a list of `BoundChange` applied. The matrix is shared, not copied. | `BoundChange`, `WarmStart` | O(n) or O(m) for the arrays replaced; `relaxed()` O(1) | O(n) or O(m) |
| `LPNames` | Column and row names: `columns`, `rows`, `column(_:)`, `row(_:)`, `default(columns:rows:)`. Produced on first use, then cached. | `CompiledLP`, `LPName` | First use O(m + n) names; O(1) afterwards | O(characters) |
| `SparseCSC` — storage | Immutable compressed-sparse-column matrix with 32-bit row indices: `rows`, `cols`, `colStart`, `rowIndex`, `values`, `nnz`, `range(ofColumn:)`, `count(inColumn:)`, `subscript`, `density`. | `CompiledLP`, `DenseMatrix` | O(1); an element lookup is O(log(column length)) | 12·z + 8·(n + 1) bytes |
| `SparseCSC.fromTriplets(rows:cols:_:)`, `SparseCSC.transposed()` | Assembly from coordinate entries (duplicates summed, zeros dropped), and the transpose. | `CompiledLP` | Triplets O(z·log(longest column) + n); transpose O(z + m + n) | O(z + m + n) |
| `SparseCSC` — products; `sparseMultiplyThreshold` | `multiply(_:)`, `multiplyTranspose(_:)` and their `into:` forms, `multiplyTranspose(_:columns:)`, and the per-column kernels `dot(column:_:)`, `axpy(column:_:into:)`, `scatter(column:into:)`, `maxAbs(inColumn:)`. From `sparseMultiplyThreshold` (100,000) nonzeros a product goes through Accelerate's `SparseMultiply`. | `Vec`, `CompiledLP` | Products O(z + m + n); per-column kernels O(column length) | O(m) or O(n) for the result |
| `Presolve` — running | `run(_:tolerances:mode:)`, `identity(_:)`: removes fixed columns, singleton rows, empty rows and columns, and rounds integer bounds. `outcome`, `original`, `reduced`, `columnOrigin`, `rowOrigin`, `removedRows`, `removedColumns`, `isIdentityMapping`, `unboundedColumn`, `unboundedDirection`. Nested `Presolve.Outcome` (`.reduced`, `.solved`, `.infeasible`) and `Presolve.Mode` (`.off`, `.boundsOnly`, `.full`). | `CompiledLP`, `Tolerances`, `Simplex`, `InteriorPoint` | At most 10 passes of O(z + m + n) | O(z + m + n): the reduced copy and the undo steps |
| `Presolve` — postsolve | `expandPrimal(_:)`, `expandPrimalRay(_:)`, `reducePrimal(_:)`, `expandDual(_:objective:)`, `expandBasis(_:)`, `reduceBasis(_:)`: map a solution, a ray or a basis between the reduced and the original problem. | `Basis`, `SolutionAnalysis` | O(m + n); `expandDual` also passes over one column of A per removed singleton row | O(m + n) |
| `Scaler` | `factors(for:mode:)`, `apply(_:to:)`, `scale(_:mode:)`, `powerOfTwo(nearest:)`: row and column scale factors, each a power of two, and the scaled copy of a problem. | `ScalingMode`, `Scaling`, `CompiledLP` | At most 20 geometric passes and one equilibration pass, each O(z); `apply` O(z + m + n) | O(m + n) factors; O(z + m + n) for a scaled copy |
| `Scaling` | The factors applied to a scaled problem: `rows`, `columns`, `isIdentity`, and `unscalePrimal(_:)`, `scalePrimal(_:)`, `unscaleDual(_:)`, `unscaleReducedCosts(_:)`, `unscaleRowActivity(_:)`. | `Scaler`, `CompiledLP` | O(m + n) | O(m + n) |
| `ScalingMode` | `.none`, `.equilibration`, `.geometricEquilibration` (the LP engines' default). | `Scaler`, `Simplex`, `InteriorPoint` | O(1) | O(1) |
| `MPSFormat` | `read(_:options:)`, `read(contentsOf:options:)`, `write(_:free:name:)`; free and fixed MPS. Nested `MPSFormat.ReadOptions` (`keepFreeRows`, `fixedColumns`). A malformed file throws `SolverError.invalidModel` with a `.syntax` diagnostic; quadratic, SOS, indicator and semi-continuous sections throw `.unsupported`. | `CompiledLP`, `LPFormat`, `ModelDiagnostic` | Read O(L + z·log(longest column)) exp.; write O(z + m + n) | O(L + z + m + n) |
| `LPFormat` | `write(_:)`, `read(_:)`, `read(contentsOf:)`: the CPLEX LP text format. | `CompiledLP`, `MPSFormat`, `LPName` | As `MPSFormat` | O(L + z + m + n) |

### 2.3 The solve contract

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `SolverStrategy` | Protocol of every solver: an `Analysis` type and `solve(_:context:)` on a `CompiledLP`. Extensions add `solve(_:)` with a default context, `solve(_:context:)` on an `LPModel` (compile, solve, return a `Solution`) and `engineName`. | `SolveContext`, `SolutionAnalysis`, `Solution`, `SolverError` | The strategy's; the `LPModel` form adds one `compile` | The strategy's |
| `SolveContext` | Run-level resources: `timeLimit`, `threads`, `memoryBudgetBytes`, `metal`, `warmStart`, `progress`, `accelerator`. `resolvedThreads`; `makeEventStream()` (an `AsyncStream` of events); `nested()` and `silenced()` for a solve inside a solve; `candidateKernels`, `attachMetal(_:)`, `attachingMetal(_:)` for the GPU tier. | `SolverStrategy`, `WarmStart`, `MetalPolicy`, `SolverEvent`, `MemoryBudget`, `MetalAccelerator` | O(1) | O(1); the event stream keeps the newest 256 events |
| `Tolerances` | `primalFeasibility` 1e-7, `dualFeasibility` 1e-7, `pivot` 1e-7, `harris` 1e-9, `dropZero` 1e-14, `integrality` 1e-6, `mipRelativeGap` 1e-4, `mipAbsoluteGap` 1e-6, `ipmResidual` 1e-8; `.default`. | `Simplex`, `InteriorPoint`, `Presolve`, `Gap` | O(1) | O(1) |
| `WarmStart` | `.none`, `.basis(_:)`, `.incremental(parent:changes:)`, `.primalPoint(_:)`, `.crash(_:)`. `Simplex` reads every kind; `CPSAT` reads `.primalPoint` as a hint for its first decisions; `InteriorPoint` and `BranchAndBound` ignore it. | `SolveContext`, `Basis`, `BoundChange`, `CrashKind` | O(1) | O(m + n) for a basis or a point |
| `Basis` | A simplex basis of the logical form [A −I]: `status` (n + m entries), `basic` (m columns); `allLogical(for:)`, `nonbasicStatus(lower:upper:)`, `approximateBytes`. | `BasisStatus`, `WarmStart`, `BasisProviding`, `SimplexAnalysis`, `NodeStateSizing` | O(m + n) to build or copy | n + 5·m bytes |
| `BasisStatus` | `.basic`, `.atLower`, `.atUpper`, `.free`, `.fixed`. | `Basis` | O(1) | 1 byte |
| `BoundChange` | New bounds for one column: `column`, `lower`, `upper`. | `WarmStart`, `CompiledLP`, `SimplexEngine`, `NodeLPStrategy` | O(1) | 24 bytes |
| `CrashKind` | Cold-start bases: `.slack` (all logical), `.triangular` (a triangular basis of structural columns). | `WarmStart` | O(1) to name; the triangular crash itself is O(z + m + n) | O(1) |
| `MetalPolicy` | `.off`, `.automatic` (the default: only above the size thresholds, with a provider attached), `.forced` (for tests). | `SolveContext`, `KernelThresholds`, `MetalAccelerator` | O(1) | O(1) |
| `SolveAccelerator` | Marker protocol for what `SolveContext.accelerator` carries. | `SolveContext`, `CandidateKernelProvider` | O(1): it has no requirements | O(1) |
| `SolveStatus` | `.optimal`, `.infeasible`, `.unbounded`, `.infeasibleOrUnbounded`, `.feasible(stoppedBy:)`, `.noSolution(stoppedBy:)`, `.numericalFailure(_:)`; `isOptimal`, `hasSolution`, `stopReason`. | `StopReason`, `SolutionAnalysis`, `Solution` | O(1) | O(1) |
| `StopReason` | `.timeLimit`, `.iterationLimit`, `.nodeLimit`, `.cancelled`, `.gapReached`, `.memoryBudget`. | `SolveStatus`, `SolveContext` | O(1) | O(1) |
| `SolverError` | The only errors `solve` and `compile` throw: `.invalidModel(_:)`, `.unsupported(_:)`, `.internalInconsistency(_:)`. | `ModelDiagnostic`, `SolverStrategy`, `LPModel` | O(1) | O(1) |
| `ModelDiagnostic` | A problem found while compiling or reading: `severity`, `kind`, `message`. Nested `ModelDiagnostic.Severity` (`.warning`, `.error`) and `ModelDiagnostic.Kind` (`.nonFiniteCoefficient`, `.nonFiniteValue`, `.infeasibleConstantConstraint`, `.inconsistentVariableBounds`, `.inconsistentRowBounds`, `.duplicateConstraintName`, `.nonIntegralFixedBound`, `.sizeLimitExceeded`, `.droppedSmallCoefficient`, `.syntax`). | `SolverError`, `CompileOptions`, `CompiledModel` | O(1) | O(message) |
| `SolverEvent` | Progress: `.started`, `.presolved`, `.simplexIteration`, `.ipmIteration`, `.newIncumbent`, `.boundImproved`, `.nodes`, `.warning`, `.finished`; `isFinished`. Simplex iterations are reported at most every 100, nodes at most every 100 ms; `.finished` is last and unique. | `SolveContext`, `EventSink` | O(1) | O(1) |
| `EventSink` | Actor that serializes the events of one solve and enforces their order; for the author of a strategy. `emit(_:)`, `warn(_:)`, `finish(status:seconds:)`, `warnings`, `isFinished`, `hasListener`. | `SolverEvent`, `SolveContext`, `SolverStrategy` | O(1) per event, one actor hop | O(warnings) |

### 2.4 Results

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `SolutionAnalysis` | What every result has: `status`, `objectiveValue`, `bound`, `primal` (n values), `dual` (m row duals; `nil` for MILP results), `reducedCosts` (n + m), `seconds`, `warnings`. Values are unscaled and in the model's own sense. | `SolveStatus`, `SolveRecord`, `AnalysisDecorator`, `Solution` | O(1) access | 16·(n + m) bytes when every array is present |
| `SolveRecord` | The concrete record of those eight fields that every engine fills. | `SolutionAnalysis`, `AnalysisDecorator` | O(1) | As `SolutionAnalysis` |
| `AnalysisDecorator` | Protocol of an analysis that wraps another one (`base`) and forwards the eight fields; how each engine adds its own facts. | `SolveRecord`, `SimplexAnalysis`, `ConditionedAnalysis` | O(1) | Its `base` plus its own fields |
| `BasisProviding` | Protocol of an analysis that carries a final basis: `finalBasis`. | `Basis`, `SimplexAnalysis`, `ConditioningAnalyzer` | O(1) | O(m + n) |
| `AnySolutionAnalysis` | Type-erased analysis, what `Automatic` and `Portfolio` return: `engine`, `unwrap(as:)`, `finalBasis`. | `Automatic`, `PortfolioAnalysis`, `SolutionAnalysis` | O(1) | The wrapped analysis |
| `Solution` | A result keyed by the model's variables: `analysis`, `compiled`, `status`, `objectiveValue`, `value(of:)`, `values(where:)`, `dual(ofConstraintNamed:)`, `reducedCost(of:)`. `value(of:)` and `reducedCost(of:)` return 0 for a variable the model does not contain or when there is nothing to report. | `SolverStrategy`, `CompiledModel`, `SolutionAnalysis`, `LoweredConstraint` | O(1) exp. per lookup; `values(where:)` O(n) | The analysis plus the compiled model |

### 2.5 Strategies and their analyses

What one solve costs, per engine:

- **Simplex.** I × (O(z + m + n) + at most 3·S), plus one F every 100 pivots (50 with sparse
  QR). Before that, presolve and scaling: at most 31 passes of O(z + m + n). Beside the
  caller's problem it holds the presolved and the scaled copy, a dozen work vectors of length
  m + n and the factor: 8·m² bytes with the dense basis — 18 MB at its 1,500-row limit —
  and fill-dependent with sparse QR.
  Pricing and the pivot row run in parallel only from 20,000 columns and 200,000 nonzeros.
- **Interior point.** K × (O(Σⱼ zⱼ²) to form AΘAᵀ, with zⱼ the nonzeros of column j, plus one
  Cholesky or LDLᵀ factorization of that m × m matrix, plus O(z) for the residuals). The
  factorization is dense, ⅓·m³ flops and 8·m² bytes, when m ≤ 300 or the matrix is at least
  25 % dense, and Accelerate's sparse one otherwise. `crossover: .lite` adds a simplex run
  that starts from the interior point.
- **Branch and bound.** The root LP, then N node LPs, each a warm-started simplex run of at
  most max(1,000, 10·(m + n)) pivots (retried once with four times as many, then once cold),
  plus strong-branching probes of at most 50 pivots and the heuristics. Every worker owns
  one engine. An open node holds its path of bound changes (24 bytes per changed column) and
  shares its parent's saved state (about 17·n + 5·m bytes); the open nodes together stay
  under the memory budget.
- **CP-SAT.** C conflicts, each a unit propagation over the clauses and linear rows touched,
  plus one conflict analysis. An LP worker adds a dual simplex run of at most
  max(1,000, 4·rows) pivots each time propagation reaches a fixed point. Each worker holds
  its own trail and learned clauses, kept under its share of the memory budget; an LP worker
  also holds one simplex engine on the relaxation.

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `Simplex` | Bounded-variable revised simplex. `Simplex(_:pricing:factorization:perturbation:maxIterations:presolve:scaling:tolerances:)`, `.dual` by default. Nested `Simplex.Method` (`.primal`, `.dual`), `Simplex.Pricing` (`.dantzig`, `.devex`, `.steepestEdge`, `.partial(sections:)`), `Simplex.Factorization` (`.automatic`, `.denseLU`, `.sparseQR`), `Simplex.Perturbation` (`.off`, `.always`, `.onStall`). Also `denseBasisLimit` (1,500), `makeFactorization(rows:)`, `iterationCap(rows:columns:)`. Returns a vertex with its basis, and a ray when the answer is `.infeasible` or `.unbounded`. | `SimplexAnalysis`, `SimplexEngine`, `BasisFactorization`, `WarmStart`, `Tolerances`, `NodeLPStrategy` | I × (O(z + m + n) + 3·S) + F per 100 pivots; I ≤ max(50,000, 100·(m + n)), then `.iterationLimit` | O(z + m + n) + F's storage |
| `SimplexAnalysis` | `method`, `basis`, `iterations`, `phase1Iterations`, `refactorizations`, `degeneracy`, `primalRay`, `dualRay`, `finalBasis`, over a `SolveRecord`. | `Simplex`, `Basis`, `BasisProviding`, `InteriorPointAnalysis` | O(1) | O(m + n) |
| `SimplexEngine` | The engine itself, non-copyable and owned by one task, for solving a sequence of related problems without rebuilding: `init(lp:strategy:factorization:)`, `solve(method:warmStart:cutoff:gate:)`, `applyBoundChanges(_:)`, `basis`. No presolve. | `Simplex`, `WorkGate`, `BoundChange`, `NodeLPStrategy` | Initializer O(z + m + n); `solve` as `Simplex` without presolve and scaling; `applyBoundChanges` O(changes) | As `Simplex` |
| `InteriorPoint` | Mehrotra predictor–corrector on the normal equations, then crossover to a vertex. `InteriorPoint(crossover:maxIterations:regularization:presolve:scaling:tolerances:)`. Nested `InteriorPoint.Crossover` (`.none`, `.lite`, the default) and `InteriorPoint.Regularization` (`primal` 1e-8, `dual` 1e-10). Answers `.infeasibleOrUnbounded` when it cannot tell the two apart. | `InteriorPointAnalysis`, `SparseSymmetricSolver`, `Simplex`, `NodeLPStrategy` | K × (O(Σⱼ zⱼ²) + one m × m factorization + O(z)), K ≤ 200; plus the crossover's pivots | O(z + fill), or 8·m² bytes when the normal equations are dense; plus the crossover's engine |
| `InteriorPointAnalysis` | `iterations`, `finalMu`, `primalResidual`, `dualResidual`, `crossover` (the `SimplexAnalysis` of the crossover, when one ran), `finalBasis`. | `InteriorPoint`, `SimplexAnalysis`, `BasisProviding` | O(1) | O(m + n) |
| `BranchAndBound` | Parallel branch and bound for models with integer columns. `BranchAndBound(engine:branching:nodeSelection:heuristics:gap:nodeLimit:deterministic:seed:)`; without `engine:` the node LPs use `Simplex(.primal)`. `.optimal` means within `gap`. | `NodeLPStrategy`, `BranchingRule`, `NodeSelection`, `Heuristics`, `Gap`, `BranchAndBoundAnalysis` | Root LP + N × node LP; N is exponential in the integer columns at worst and ends at `nodeLimit`, the time limit or the memory budget | W engines + open nodes, held under the memory budget |
| `BranchingRule` | `.mostFractional`, `.pseudocost(reliability:)` (the default, reliability 4), `.strong(candidates:)`. | `BranchAndBound` | Per node: a pass over the integer columns, plus two probes of at most 50 pivots for each candidate that is strong-branched (at most 8 per node under `.pseudocost`) | O(integer columns) pseudocosts |
| `NodeSelection` | `.bestBound`, `.bestBoundWithPlunging(maxDepth:)` (the default, depth 32), `.depthFirst`. | `BranchAndBound` | O(log(open nodes)) per node | O(1) |
| `Heuristics` | `rounding`, `diving`, `divingInterval` (100 nodes), `divingMaxDepth` (50), `divingIterationLimit` (500), `roundingBatch` (128); `.default`, `.none`. | `BranchAndBound`, `BatchedActivityEvaluating` | Rounding O(z) per point; a dive at most 500 pivots | O(n) per point |
| `Gap` | `relative` (1e-4) and `absolute` (1e-6): when the search may stop and call the incumbent optimal. | `BranchAndBound`, `Tolerances` | O(1) | O(1) |
| `IncumbentEvent` | One improvement of the incumbent: `objective`, `node`, `seconds`, `source`. | `BranchAndBoundAnalysis`, `SolverEvent` | O(1) | O(1) |
| `BranchAndBoundAnalysis` | `root` (the node engine's own analysis of the root LP), `gap`, `nodesProcessed`, `nodesOpen`, `lpIterations`, `incumbents`, `incumbentHistory`, `finalBasis`. | `BranchAndBound`, `IncumbentEvent`, `SimplexAnalysis` | O(1) | O(n + m + incumbents) |
| `NodeLPStrategy` | Protocol of an LP engine that can solve the nodes of a tree: `State`, a non-copyable `Worker`, `makeWorker(lp:context:)`, `solveRoot(_:gate:)`, `solveNode(_:changes:parent:cutoff:iterationLimit:gate:)`, `probe(_:changes:parent:iterationLimit:gate:)`, `rootAnalysis(_:worker:)`. Two conformers ship: `Simplex` (`Simplex.State` is `Basis`, `Simplex.Worker` is `SimplexEngine`) and `InteriorPoint` (`InteriorPoint.State` is `Basis`, `InteriorPoint.Worker` is `InteriorPointNodeWorker`). | `BranchAndBound`, `NodeLPResult`, `NodeStateSizing`, `WorkGate` | The conformer's | One worker per search task; one `State` per processed node that still has open children |
| `NodeLPResult` | What a node LP produced: `outcome`, `state`, `iterations`. Nested `NodeLPResult.Outcome`: `.optimal(objective:x:reducedCosts:)`, `.infeasible`, `.cutoff`, `.unbounded`, `.limit`. | `NodeLPStrategy` | O(1) | O(n + m) |
| `NodeStateSizing` | Protocol: `approximateBytes`, so that the tree can count a custom warm-start state against the memory budget. `Basis` conforms. | `NodeLPStrategy`, `Basis`, `MemoryBudget` | O(1) | O(1) |
| `InteriorPointNodeWorker` | The non-copyable worker `InteriorPoint` uses as a node engine: interior point at the root, dual simplex at the nodes. | `InteriorPoint`, `NodeLPStrategy` | As `InteriorPoint`, then as `SimplexEngine` | As `InteriorPoint`, then as `SimplexEngine` |
| `CPSAT` | Conflict-driven clause learning with lazy bound literals, linear propagation and, by default, the linear relaxation as a propagator, for pure integer and binary models. `CPSAT(workers:restarts:clauseSharing:lpPropagator:seed:deterministic:)`. Throws `.unsupported` for a continuous column, an integer column without finite bounds, data that no power of 10 up to 1e6 makes integral, or activities beyond Int64. | `CPSATAnalysis`, `RestartPolicy`, `SolveContext`, `Simplex` | C conflicts, exponential in the columns at worst; ends at the time limit or the memory budget | The model, plus per worker a trail and learned clauses under budget ÷ workers; plus a simplex engine per LP worker |
| `RestartPolicy` | `.luby(unit:)` (the default, unit 100 conflicts), `.geometric(first:factor:)`, `.never`; `lubyTerm(_:)`. | `CPSAT` | `lubyTerm` O(log i) | O(1) |
| `CPSATAnalysis` | `conflicts`, `decisions`, `propagations`, `restarts`, `learnedClauses`, `workers`, `winningWorker`, `lpSolves`. | `CPSAT` | O(1) | O(n) |
| `Automatic` | Picks an engine from the shape of the problem: integer columns → `BranchAndBound`; at most 4,000 rows → `Simplex(.dual)`; more than 10,000 rows with a column over 30 % dense → `Simplex(.dual)` on sparse QR; otherwise `InteriorPoint`. Nested `Automatic.Choice` (`.branchAndBound`, `.dualSimplex`, `.sparseSimplex`, `.interiorPoint`); `choice(for:)`, `hasDenseColumn(_:)`, `interiorPointRows`, `denseColumnRows`, `denseColumnFraction`. | `AnySolutionAnalysis`, `BranchAndBound`, `Simplex`, `InteriorPoint` | O(n) to choose, then the chosen engine's | The chosen engine's |
| `Portfolio` | Runs several strategies at once on the same problem and returns the first that reaches `.optimal`, `.infeasible` or `.unbounded`, cancelling the rest; `strategies`. | `PortfolioAnalysis`, `SolverStrategy`, `SolveContext` | Wall time: the first conclusive strategy's, with threads ÷ k each, plus the cancellation latency of the others | The sum over k strategies, each with budget ÷ k |
| `PortfolioAnalysis` | `winner`, `others` (name and status of every other strategy), over the winner's `AnySolutionAnalysis`. | `Portfolio`, `AnySolutionAnalysis` | O(1) | O(n + m + k) |
| `Conditioned` | Wraps a strategy: runs `inner`, then analyzes the problem with the solution and basis it produced. | `ConditionedAnalysis`, `ConditioningAnalyzer`, `SolverStrategy` | `inner`'s plus one `ConditioningAnalyzer.analyze` | `inner`'s plus the analyzer's |

### 2.6 Conditioning analysis

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `ConditioningAnalyzer` | `analyze(_:basis:primal:context:options:budget:)` and `analyze(_:after:context:options:budget:)`: why a model is slow or numerically fragile. Nested `ConditioningAnalyzer.Options` (`maxFindingsPerKind` 100, `parallelRowThreshold` 4,096, `boundTolerance`); thresholds `wideRangeWarning`, `wideRangeSevere`, `bigMRatio`, `parallelCosine`, `denseColumnDensity`, `degenerateBasisFraction`, `illConditionedWarning`, `illConditionedSevere`, `maxRowsForConditionEstimate`. | `ConditioningReport`, `Conditioned`, `Basis`, `ConcurrencyBudget` | O(z + m + n) exp., in parallel over row blocks from 4,096 rows; with a basis and m ≤ 4,000, one dense LU and condition estimate, O(m³) | O(z + m + n); 16·m² bytes for the condition estimate, skipped if that exceeds the memory budget |
| `ConditioningReport` | `coefficientRange` (matrix, objective, right-hand sides, bounds), `suggestedScaling`, `basisConditionEstimate`, `findings`, `omittedFindings`, `basisAnalysis`, `dimensions`, `scalingIsApplied`, `worstSeverity`, `findings(of:)`, `ratio(_:)`, `summary`, `markdown`. | `ConditioningAnalyzer`, `Finding`, `BasisAnalysisOutcome` | `summary`, `markdown` O(findings) | O(m + n + findings) |
| `Finding` | One observation: `severity`, `kind`, `message`. Nested `Finding.Severity` (`.info`, `.warning`, `.severe`) and `Finding.Kind` (`.wideCoefficientRange`, `.bigM`, `.emptyRow`, `.emptyColumn`, `.singletonRow`, `.nearParallelRows`, `.freeColumn`, `.fixedColumn`, `.denseColumn`, `.degenerateBasis`, `.illConditionedBasis`). | `ConditioningReport` | O(1) | O(message) |
| `BasisAnalysisOutcome` | What became of the basis part of the analysis: `.noBasis`, `.invalidBasis`, `.tooManyRows(_:)`, `.overMemoryBudget`, `.analyzed`. | `ConditioningReport` | O(1) | O(1) |
| `ConditionedAnalysis` | The analysis `Conditioned` returns: the inner one (`base`) plus `report`; `finalBasis`. | `Conditioned`, `ConditioningReport`, `AnalysisDecorator` | O(1) | `base` plus the report |

### 2.7 Numerical building blocks

Public because the engines live in separate modules and share them. They are usable on their
own, but they are the engines' tools: dimension mismatches are preconditions, not errors.

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `DenseVector` | Alias of `[Double]`. | `Vec` | As `[Double]` | 8 bytes per entry |
| `Vec` | vDSP and BLAS kernels on `[Double]`: `dot`, `axpy`, `scale`, `norm2`, `maxAbs`, `add`, `subtract`, `multiply`, `divide`, `scaledAdd`, `addScaled`, `clip`, `abs`, `minimum`, `sum`, `toSingle`, `toDouble`. | `DenseVector`, `SparseCSC`, `DenseMatrix` | O(length) | In place; the two conversions allocate their result |
| `IndexedVector` | Dense values plus the list of their nonzero positions, for solves whose result is mostly zero: `values`, `indices`, `isSparse`, `sparseDensity` (0.10), `count`, `reindex(dropTolerance:)`, `clear()`. | `BasisFactorization` | `reindex` O(length); `clear` O(nonzeros) while the list is valid | 12 bytes per entry at most |
| `DenseMatrix` | Column-major dense matrix: `rows`, `cols`, `storage`, `identity(_:)`, `subscript`, a conversion from `SparseCSC`, `multiply(_:)`, `multiplyTranspose(_:)`, `multiplied(by:)`, `weightedGram(_:)`, `oneNorm()`, `transposed()`. | `DenseLU`, `DenseCholesky`, `DenseQR`, `SparseCSC` | Matrix–vector O(rows·cols); `multiplied(by:)` O(rows·cols·k); `weightedGram` O(rows²·cols) | 8·rows·cols bytes |
| `DenseLU` | LAPACK `dgetrf` with partial pivoting: `solve(_:transpose:)`, `deficientPivots(relativeTolerance:)`, `reciprocalCondition()`, `conditionEstimate()`, `factors`, `pivots`, `oneNorm`, `smallestPivot`, `largestPivot`. | `DenseMatrix`, `DenseLUBasis`, `NumericalError` | Factor ⅔·n³; solve 2·n²; condition estimate O(n²) | 8·n² bytes |
| `DenseCholesky` | LAPACK `dpotrf`: `init(lowerTriangleOf:)`, `solve(_:)`, `factor`. Throws `.notPositiveDefinite`. | `DenseMatrix`, `InteriorPoint`, `NumericalError` | Factor ⅓·n³; solve 2·n² | 8·n² bytes |
| `DenseQR` | LAPACK `dgeqrf`: `rank(relativeTolerance:)`, `solveLeastSquares(_:)`, `factors`, `tau`. | `DenseMatrix`, `NumericalError` | O(rows·cols²) | 8·rows·cols bytes |
| `denseSolve(_:_:)` | One linear system by LU; `nil` when the matrix is singular. | `DenseLU`, `DenseMatrix` | O(n³) | O(n²) |
| `triangularSolve(_:_:upper:transpose:unitDiagonal:)` | One triangular system, in place. | `DenseMatrix` | O(n²) | O(1) extra |
| `NumericalError` | `.singular(positions:rows:)`, `.notPositiveDefinite(_:)`, `.unstableUpdate(pivot:)`, `.factorizationFailed(_:)`. Never reaches the caller of `solve`: an engine turns it into a recovery step or a status. | `BasisFactorization`, `DenseLU`, `SparseSymmetricSolver` | O(1) | O(1) |
| `SparseSymmetricSolver` | Accelerate's sparse Cholesky or LDLᵀ with the symbolic analysis reused across factorizations; non-copyable. `init(n:lowerColStart:lowerRowIndex:kind:)`, `factor(values:)`, `switchKind(to:)`, `solve(_:)`, `n`, `nnz`, `kind`, `factorizations`. Nested `SparseSymmetricSolver.Kind` (`.cholesky`, `.ldlt`). | `InteriorPoint`, `NumericalError` | Symbolic analysis once; each numeric factorization and solve depends on fill-in | O(nonzeros + fill) |
| `BasisFactorization` | Protocol of a basis factorization: `refactor(basic:lp:)`, `ftran(_:)`, `btran(_:)`, `update(alpha:leaving:)`, `updatesSinceRefactor`, `needsRefactor`, `conditionEstimate()`. | `DenseLUBasis`, `SparseQRBasis`, `Simplex`, `SimplexEngine` | `refactor` F; `ftran` and `btran` S; `update` O(m) | The conformer's |
| `DenseLUBasis` | Dense LU with product-form updates; `refactorInterval` (100), `dropTolerance`, `singularityTolerance`. What `Simplex` uses up to 1,500 rows. | `BasisFactorization`, `DenseLU`, `Simplex` | Refactor ⅔·m³; solve 2·m² plus the updates | 8·m² bytes, twice that while refactoring, plus the update file |
| `SparseQRBasis` | Accelerate's sparse QR with product-form updates; `refactorInterval` (50), `dropTolerance`. What `Simplex` uses above 1,500 rows. Has no condition estimate, and cannot say which columns make a basis singular. | `BasisFactorization`, `Simplex` | Fill-dependent | Fill-dependent |
| `basisDensity(basic:lp:)` | Stored entries of the basic columns over m². | `BasisFactorization`, `CompiledLP` | O(m) | O(1) |
| `KernelThresholds` | The sizes from which the GPU kernels are used under `.automatic`: `reducedCostScanColumns` (3,000,000), `reducedCostScanNonzeros` (6,000,000), `reducedCostCandidates` (64), `batchedActivityPoints` (64), `batchedActivityNonzeros` (100,000), `batchedActivityMaxBatch` (1,024), `disagreementFraction` (0.05); `allowsReducedCostScan(columns:nonzeros:policy:)`, `allowsBatchedActivity(points:nonzeros:policy:)`. | `MetalPolicy`, `MetalAccelerator` | O(1) | O(1) |
| `PricingEligibility` | Codes for the scan kernel: `none`, `increase`, `decrease`, `either`. | `ReducedCostScanning` | O(1) | 1 byte per column |
| `ReducedCostScanning` | Protocol of a pricing kernel: `scan(costs:duals:weights:eligibility:limit:)` returns candidate columns, or `nil` when it could not run. | `MetalReducedCostScan`, `CandidateKernelProvider`, `Simplex` | The conformer's | The conformer's |
| `BatchedActivityEvaluating` | Protocol of a feasibility screen: `evaluate(points:count:tolerance:)` returns one flag per point, or `nil`. | `MetalBatchedActivity`, `PolicyBoundActivityEvaluator`, `Heuristics` | The conformer's | The conformer's |
| `CandidateKernelProvider` | Protocol of what supplies those kernels for a problem: `reducedCostScanner(for:policy:)`, `activityEvaluator(for:policy:)`. | `SolveAccelerator`, `MetalAccelerator`, `SolveContext` | The conformer's | The conformer's |
| `KernelDisagreementGuard` | Counts how often the double-precision check contradicts a kernel and switches the kernel off above 5 %: `record(candidates:disagreements:)`, `disagreementRate`, `candidates`, `disagreements`, `isDisabled`, `minimumSample`. | `KernelThresholds`, `ReducedCostScanning` | O(1) | O(1) |

### 2.8 Time, cancellation and budgets

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `Deadline` | A point in time, or none: `uptimeNanoseconds`, `.none`, `after(seconds:)`, `now`, `hasPassed`, `remainingSeconds`, `earlier(_:)`. | `WorkGate`, `SolveContext` | O(1) | O(1) |
| `StopSignal` | What a `WorkGate` throws: `.cancelled`, `.deadline`. Engines turn it into a `StopReason`; it never reaches the caller of `solve`. | `WorkGate`, `StopReason` | O(1) | O(1) |
| `StopFlag` | One-way atomic flag that stops every worker of a solve: `set()`, `isSet`. | `WorkGate`, `Portfolio` | O(1), lock-free | O(1) |
| `WorkGate` | The check every long loop calls: `tick()`, `check()`, `stopFlag`, `checks`, `yields`, `elapsedNanoseconds`, `elapsedSeconds`, `currentDeadline`, `stopReason`. `tick()` is a counter decrement; a full check of cancellation, flag and deadline happens at least every 64 ticks and about every millisecond when iterations are slow; the task yields at most every 10 ms. | `Deadline`, `StopFlag`, `StopSignal`, `SimplexEngine`, `NodeLPStrategy` | O(1) | O(1) |
| `ConcurrencyBudget` | Actor holding the CPU slots of one solve, so that nested parallel regions never exceed `threads`: `capacity`, `borrow(upTo:)`, `giveBack(_:)`, `slotsInUse`, `peakInUse`. A borrow never waits: it returns what is free. | `parallelBlocks(count:blocks:budget:_:)`, `SolveContext` | O(1), one actor hop | O(1) |
| `parallelBlocks(count:blocks:budget:_:)` | Runs a closure over contiguous blocks of a range on the calling task plus the slots the budget grants; results come back in block order. | `ConcurrencyBudget` | The closure's work plus O(blocks) | O(blocks) results |
| `MemoryBudget` | `availableBytes()` — what the process may still allocate on iOS, the physical memory on macOS and Mac Catalyst — and `resolve(_:)`: the context's budget, or a quarter of that. | `SolveContext`, `NodeStateSizing` | O(1) | O(1) |
| `secondsSince(_:)` | Wall-clock seconds since an uptime taken from `Deadline.now`. | `Deadline` | O(1) | O(1) |

### 2.9 The Metal tier

Optional single-precision candidate generation. Nothing it computes is trusted: every
candidate is recomputed in double precision before it is used.

| API | What it is | Related | Time | Space |
|---|---|---|---|---|
| `MetalAccelerator` | The kernel provider that ships: `shared`, `init()`, `init(device:)`, `reducedCostScanner(for:policy:)`, `activityEvaluator(for:policy:)`, `status()`, `isAvailable`, `context()`. `Automatic`, `Portfolio` and `Conditioned` attach it themselves; a direct engine call opts in with `SolveContext.attachMetal(_:)`. Returns `nil`, leaving the engine on the CPU, when the policy is `.off`, the problem is under the thresholds, or there is no usable device. | `CandidateKernelProvider`, `SolveContext`, `MetalPolicy`, `KernelThresholds` | First request loads or compiles the shaders, once; a new kernel copies A in single precision, O(z) | 8·z + 4·(n + 1) bytes per scan kernel, 8·z + 12·m bytes per activity kernel; refused above a quarter of the available memory |
| `MetalContext` | The device and the compiled kernels: `device`, `librarySource`. Nested `MetalContext.LibrarySource` (`.precompiled`, `.compiledFromSource`). | `MetalAccelerator`, `MetalTierStatus` | O(1) | O(1) |
| `MetalTierStatus` | `.ready(device:library:)`, `.noDevice`, `.libraryUnavailable(_:)`; `isReady`. | `MetalAccelerator` | O(1) | O(1) |
| `MetalReducedCostScan` | Actor; the pricing kernel. `scan(costs:duals:weights:eligibility:limit:)` scores every column on the GPU and returns the best `limit`; `scores(costs:duals:weights:eligibility:)` returns the raw scores; `matrix`, `rows`, `columns`, `dispatches`. | `ReducedCostScanning`, `PricingEligibility`, `Simplex` | One GPU pass over the z nonzeros, plus O(m + n·log(limit)) on the CPU to convert the inputs and pick the candidates | The static copy, plus O(m + n) per call in flight |
| `MetalBatchedActivity` | Actor; the feasibility screen. `evaluate(points:count:tolerance:)` flags the points whose row activities stay within the bounds; `activities(points:count:)` returns the activities; `matrix`, `rowLower`, `rowUpper`, `columnLower`, `columnUpper`, `rows`, `columns`, `dispatches`. Never rejects a point that is feasible in exact arithmetic. | `BatchedActivityEvaluating`, `Heuristics`, `BranchAndBound` | O(points·z) on the GPU plus O(points·n) packing; at most 1,024 points per dispatch | The static copy, plus at most 64 MB of scratch per dispatch |
| `PolicyBoundActivityEvaluator` | The activity kernel behind the size thresholds, checked on every call: `kernel`, `policy`, `nonzeros`, `evaluate(points:count:tolerance:)`. | `MetalBatchedActivity`, `KernelThresholds`, `MetalPolicy` | As the kernel, or O(1) when under the threshold | As the kernel |

## 3. Risk assessment

For someone deciding whether to put this package in an app. Likelihood and impact are
judgements; the evidence column says what they rest on.

| # | Risk | Likelihood | Impact | Evidence | What limits it, what to do |
|---|---|---|---|---|---|
| 1 | **A wrong or failed answer on a model unlike the tested ones.** Simplex and interior point are floating-point algorithms with tolerances. | Medium | High | Correctness was checked on 13 netlib LPs (at most 444 × 534), 10 MIPLIB 3 instances (at most 331 rows, 319 columns), instances built with a known optimum, and by enumeration on small integer models. Nothing larger, nothing badly scaled beyond those. | Read the status before the values. An `.infeasible` or `.unbounded` LP result carries a ray that can be checked independently; `CompiledLP.maxViolation(at:)` checks a point; `Conditioned` reports scaling and conditioning problems; solving once more with a different engine (`InteriorPoint` after `Simplex`, or the reverse) cross-checks the answer. |
| 2 | **The model outgrows the engines.** | High above a few thousand rows | Medium: time limit reached, or memory | The basis is a dense LU up to 1,500 rows (O(m²) memory, O(m³) per refactorization) and Accelerate's sparse QR above; there is no sparse LU. The largest LP solved end to end is 2,000 × 20,000 (0.14 s to 3.6 s by engine). | Always set `timeLimit`. Measure on a model of production size before committing. `Automatic` switches to the interior point above 4,000 rows. |
| 3 | **A hard integer model does not close.** | High on hard instances | Medium: `.feasible` with a gap, or `.noSolution` | Branch and bound has no cutting planes and a small presolve; CP-SAT improves the objective one incumbent at a time. Measured only on ten small MIPLIB 3 instances; `stein45` (331 × 45) already takes 16 to 20 s. | Set `timeLimit` or `nodeLimit`, and read `bound` and `BranchAndBoundAnalysis.gap` to know how far the incumbent may be from the optimum. Try both `BranchAndBound` and `CPSAT` on pure integer models. |
| 4 | **Memory pressure on a phone.** iOS ends a process that exceeds its allowance; that is not an error the app can catch. | Medium for integer models | High: the app is terminated | The benchmark run peaked at 1.16 GB resident after the branch-and-bound section on a 24 GB Mac. The budget counts open nodes and learned clauses, not the working storage of an LP solve, and nothing was run on an iPhone. | Set `memoryBudgetBytes` explicitly on iOS instead of relying on the default quarter of the remaining allowance; set `nodeLimit`; test on the smallest supported device. |
| 5 | **Platform and toolchain gaps.** | Medium | Medium: a build failure or a behaviour difference found late | Built and run with Swift 6.4 on an M3 only. iOS and Mac Catalyst are compiled but were never executed, on a device or in a simulator; Intel was never run; the Swift 6.0 to 6.3 path, which needs an experimental feature flag, was never compiled. | Run the test suite on the target device and toolchain before relying on it. |
| 6 | **Deprecated Accelerate entry points.** | Low in the near term | Medium: one target to port | The package calls the legacy CLAPACK and CBLAS symbols, which Apple has marked deprecated since iOS 16.4, because its floor is iOS 15. | All such calls sit in one C target, `CLAPACKShim`. Raising the floor to iOS 16.4 allows the new interface. |
| 7 | **Slow solves when the app is busy.** | Medium | Medium: latency | Workers are tasks on Swift's cooperative pool. In a debug build, branch and bound on `flugpl` took 0.07 s on its own and 34 to 50 s while the rest of the test suite ran in parallel. | Run one solve at a time, or give each its share with `SolveContext.threads`; keep long CPU-bound work off the pool while a solve runs. |
| 8 | **Results differ between runs.** Parallel search explores in a different order each time. | Certain for parallel search | Low, unless a test compares solutions or timings | Node counts, timings and, when there are several optima, the solution returned vary; the objective agrees within the gap. | `deterministic: true` on `BranchAndBound` and `CPSAT` runs a single worker with a fixed seed. Compare objectives, not solutions. |
| 9 | **A value read from a solve that has none.** | Medium | Medium: a silent zero flows on | `Solution.value(of:)` and `Solution.reducedCost(of:)` return 0, not `nil`, when there is no solution or the variable is not in the model. | Check `status.hasSolution` first; `SolutionAnalysis.primal` is `nil` when there is nothing. |
| 10 | **"Optimal" taken as exact for an integer model.** | Medium on large objective values | Low to medium | `.optimal` means within a relative gap of 1e-4 and an absolute gap of 1e-6. CP-SAT's gap cannot be changed: its proof is exact for integral costs only while the objective stays below 10⁴. | Pass a tighter `Gap` to `BranchAndBound` when the exact optimum matters; for CP-SAT, keep objective values below 10⁴ or use `BranchAndBound`. |
| 11 | **The API changes.** | High before 1.0 | Low to medium: source breaks | Version 0.1; a large public surface, much of it building blocks; two defaults already differ from the specification (the CP-SAT LP propagator, the Metal thresholds). | Depend on the types of sections 2.1 to 2.5 rather than on the building blocks, and expect renames until 1.0. |
| 12 | **A file from an untrusted source.** | Low to medium | Medium: the process stops | The MPS and LP readers are tested on the corpus files, golden files and malformed inputs, which yield `SolverError.invalidModel`. They were not fuzzed, and a violated precondition in Swift traps. | Validate or sandbox files that come from outside. |
| 13 | **A debug build mistaken for the real speed.** | High during development | Low | A package builds with the app's configuration. Search is about two orders of magnitude slower unoptimized: CP-SAT on `mod008` took about 50 s in the debug test suite against 0.26 s in release. | Judge performance in a release build only. |
| 14 | **The GPU tier adds risk without a return.** | Low | Low | Its speed-up over the CPU ranged from 0.35× to 2.30× over eleven runs, and its automatic threshold (3,000,000 columns) is 150 times the largest problem solved end to end here. When the shader library is not precompiled, the first use compiles it. | Leave `MetalPolicy` at `.automatic`, which in practice keeps the tier off, or set `.off`. Correctness does not depend on it. |
| 15 | **An interleaving the tests never produced.** Parallel search has logic that depends on the order in which workers reach the shared tree. | Low | Unknown by nature; wasted work in the one case found | Thread Sanitizer finds data races, not ordering mistakes. One was found while this page was being written: a node whose LP had failed three times could be handed to a second worker before the tree closed, and that worker repeated the attempt. The result was not affected, and it is fixed. What stands against others: 10,000 random trees with random cancellation, twenty identical deterministic runs, and the published optima reached with both node engines. | Set `timeLimit`, which ends a search whatever state it is in; use `deterministic: true` where one worker is fast enough. |

## 4. Known defects and limits

### Defects

Behaviour that falls short of what the specification or common sense expects.

1. **CP-SAT needs its LP propagator to close two of the seven pure-integer MIPLIB 3
   instances.** `CPSAT(lpPropagator: false)`, the configuration the specification defaults to,
   stops at the 60 s limit on `mod008` (329 against an optimum of 307) and on `p0201` (7675
   against 7615). The default here is `lpPropagator: true`, which closes all seven; that
   default is itself a deviation from the specification.
2. **The Metal pricing kernel does not meet its acceptance criterion.** It was to be at least
   1.5× faster than the CPU at 200,000 columns; it is slower there (0.35× to 1.23× over eleven
   runs) and only sometimes faster at 1,000,000. The remedy the specification prescribes was
   applied: the automatic threshold is 3,000,000 columns and 6,000,000 nonzeros, not 50,000
   and 500,000.
3. **The memory budget does not cover a single LP solve.** `memoryBudgetBytes` bounds open
   nodes, learned clauses and the conditioning analyzer's factorization; the GPU buffers are
   held to a quarter of the available memory whatever the setting. A dense basis (8·m²
   bytes), a sparse QR factor or dense normal equations are allocated whatever the budget
   says, and `Simplex` and `InteriorPoint` never return `.memoryBudget`.
4. **Branch and bound slows down sharply on a busy cooperative pool** (risk 7). Every node
   crosses an actor; when other work occupies the pool those hops queue.
5. **Unoptimized builds are slow out of proportion** (risk 13).
6. **`Solution.value(of:)` cannot tell "zero" from "nothing"** (risk 9).
7. **The interior point cannot always tell infeasible from unbounded.** Without a homogeneous
   self-dual embedding it answers `.infeasibleOrUnbounded` for some models; a simplex solve of
   the same model decides it and returns the certificate.

### Limits by design in v0.1

- **Model class.** Linear objective and constraints only. No quadratic terms, SOS sets,
  indicator constraints or semi-continuous variables; the MPS reader rejects those sections.
- **Size.** At most 2,147,483,647 rows, columns and nonzeros (32-bit indices). In practice the
  bound is risk 2, far below that.
- **Linear algebra.** No sparse LU and no Forrest–Tomlin update: the basis is a dense LU up to
  1,500 rows and a sparse QR above, both with product-form updates.
- **Interior point.** No dense-column handling: a column with more than 30 % nonzeros makes
  the normal equations dense (a warning says so). Crossover is the light variant — a crash
  from the interior point, a dual push, then simplex — not a full crossover.
- **Branch and bound.** No cutting planes, no feasibility pump or RINS, and a presolve that
  only tightens bounds. Heuristics are rounding and diving.
- **CP-SAT.** Pure integer and binary models with finite bounds, whose data becomes integral
  when multiplied by a power of 10 up to 10⁶ and whose row activities fit in 64-bit
  integers. No continuous columns, with or without the LP propagator. No global constraints.
  The objective is improved by linear search, and the optimality gap is fixed.
- **Presolve.** Fixed columns, singleton rows, empty rows and columns, integer bound rounding.
  No duplicate rows, dominated columns or doubleton equations.
- **Results.** A MILP result has no duals. `.optimal` for a MILP means within the gap. An
  integer column handed to an LP engine is relaxed, with a warning and not an error.
- **Parallel search is not reproducible** unless `deterministic: true`, which uses one worker.
- **Progress.** `SolveContext.makeEventStream()` keeps the newest 256 events; a consumer that
  falls further behind loses the older ones, never `.finished`.
- **File formats.** The LP reader needs each section keyword on a line of its own. A range
  row is written to LP format as an equality against an extra `Rg…` column. Fixed-format MPS
  is lossy by nature (eight-character names, twelve-character numbers); free format is the
  default.
- **Misuse of the building blocks traps.** A `CompiledLP`, `SparseCSC` or `DenseMatrix` built
  with inconsistent dimensions, or a kernel called with mismatched lengths, is a precondition
  failure, not a thrown error.
- **Platforms.** Apple platforms only.

### Not verified

- **Swift 6.0 to 6.3.** Only Swift 6.4 was used.
- **Any device other than one M3 Mac.** No iPhone, iPad, simulator or Intel Mac ran the code.
  The acceptance criteria of the specification are stated for an M1 MacBook Air, an iPhone 13
  and an iPhone 15 Pro; none was available.
- **The precompiled Metal library.** Only the compile-at-first-use path was exercised.
- **Memory behaviour under an iOS allowance.** The check on a device was not done; an
  automated stand-in runs on the Mac.
- **Exported files in another solver.** LP and MPS exports round-trip through this package's
  own readers; they were not read back by HiGHS or another solver.
- **Models larger than the ones measured**, and solves that run for hours.

## 5. Measured performance

One machine, one run of the benchmark, unless a range over several runs is given: MacBook with
an Apple M3 (8 cores, 24 GB), macOS 27, Swift 6.4, release build.

```bash
swift run -c release ZTronLPBenchmarks
```

Times are wall-clock seconds. The acceptance column quotes the specification, which states its
limits for an M1; an M3 is faster, so "met" below means met on this machine. The complete
output of the run is in [HANDBOOK.md](HANDBOOK.md#benchmarks).

### Summary

| Workload | Measured | Acceptance | Result |
|---|---|---|---|
| 13 netlib LPs, primal simplex, cold start | 0.112 s in total | ≤ 2 s | met |
| 13 netlib LPs, dual simplex | 0.087 s in total | ≤ 2 s | met |
| 13 netlib LPs, interior point with crossover | 0.038 s in total | ≤ 3 s | met |
| Transport LP, 2,000 × 20,000, simplex | 0.64 s to 3.62 s by basis and method | ≤ 10 s with both bases | met |
| 10 MIPLIB 3 instances, branch and bound | All optimal; slowest 19.6 s (primal node engine), 15.9 s (dual) | each ≤ 60 s with both | met |
| 7 pure-integer MIPLIB 3 instances, `CPSAT()` | 7 of 7 optimal; slowest 18.6 s | each ≤ 60 s | met |
| The same, `CPSAT(lpPropagator: false)` | 5 of 7 optimal; 2 stop at the 60 s limit | each ≤ 60 s | **not met** |
| Metal pricing kernel against the CPU | 0.40× at 200,000 columns, 1.53× at 3,000,000 | ≥ 1.5× at 200,000 columns, or raise the threshold | not met; threshold raised |
| Cancellation latency, 240 solves | p99 3.64 ms, worst 4.43 ms | p99 ≤ 50 ms | met |

### Linear programs: the netlib set

Pivots and seconds for a cold primal simplex and a dual simplex; iterations, crossover pivots
and seconds for the interior point. Every optimum agrees with the published value to a relative
error of at most 1.3e-11.

| Instance | Rows × columns | Nonzeros | Primal pivots | s | Dual pivots | s | IPM iterations | Crossover pivots | s |
|---|---|---|---|---|---|---|---|---|---|
| `afiro` | 27 × 32 | 83 | 16 | 0.001 | 14 | 0.000 | 10 | 1 | 0.001 |
| `sc50a` | 50 × 48 | 130 | 49 | 0.000 | 49 | 0.000 | 9 | 0 | 0.001 |
| `sc50b` | 50 × 48 | 118 | 49 | 0.000 | 49 | 0.000 | 8 | 0 | 0.000 |
| `sc105` | 105 × 103 | 280 | 99 | 0.002 | 99 | 0.001 | 10 | 6 | 0.002 |
| `kb2` | 43 × 41 | 286 | 58 | 0.000 | 57 | 0.001 | 12 | 0 | 0.001 |
| `adlittle` | 56 × 97 | 383 | 109 | 0.001 | 68 | 0.001 | 12 | 6 | 0.001 |
| `blend` | 74 × 83 | 491 | 89 | 0.001 | 89 | 0.001 | 13 | 4 | 0.001 |
| `share2b` | 96 × 79 | 694 | 107 | 0.001 | 110 | 0.002 | 16 | 14 | 0.002 |
| `stocfor1` | 117 × 111 | 447 | 88 | 0.001 | 107 | 0.001 | 12 | 10 | 0.001 |
| `scagr7` | 129 × 140 | 420 | 164 | 0.002 | 154 | 0.002 | 14 | 0 | 0.001 |
| `beaconfd` | 173 × 262 | 3,375 | 98 | 0.002 | 95 | 0.001 | 12 | 4 | 0.003 |
| `israel` | 174 × 142 | 2,269 | 123 | 0.003 | 108 | 0.003 | 17 | 3 | 0.005 |
| `degen2` | 444 × 534 | 3,978 | 1,011 | 0.098 | 539 | 0.073 | 13 | 127 | 0.022 |
| **Total** | | | | **0.112** | | **0.087** | | | **0.038** |

### Linear programs: a larger one

A random transport problem with 2,000 rows, 20,000 columns and 40,000 nonzeros; every
configuration reaches the same optimum.

| Engine | Pivots or iterations | Refactorizations | Seconds |
|---|---|---|---|
| `Simplex(.dual)`, dense LU basis | 1,000 | 11 | 2.041 |
| `Simplex(.primal)`, dense LU basis | 1,942 | 21 | 3.616 |
| `Simplex(.dual)`, sparse QR basis | 1,000 | 21 | 0.639 |
| `Simplex(.primal)`, sparse QR basis | 1,942 | 40 | 1.032 |
| `InteriorPoint()` | 12 | — | 0.141 |

At this size the sparse QR basis is three times faster than the dense one, which is why it is
the automatic choice above 1,500 rows, and the interior point is faster than either.

### Mixed-integer programs: branch and bound

The MIPLIB 3 set with the default search and both simplex methods at the nodes. All twenty runs
prove the published optimum.

| Instance | Rows × columns | `Simplex(.primal)` nodes | LP pivots | s | `Simplex(.dual)` nodes | LP pivots | s |
|---|---|---|---|---|---|---|---|
| `p0033` | 16 × 33 | 915 | 8,005 | 0.02 | 733 | 5,538 | 0.01 |
| `stein27` | 118 × 27 | 4,383 | 27,247 | 0.19 | 4,149 | 18,430 | 0.16 |
| `stein45` | 331 × 45 | 55,254 | 555,548 | 19.63 | 54,744 | 343,009 | 15.92 |
| `enigma` | 21 × 100 | 2,674 | 93,600 | 0.09 | 5,001 | 157,026 | 0.15 |
| `lseu` | 28 × 89 | 31,697 | 127,732 | 0.39 | 30,930 | 77,318 | 0.36 |
| `mod008` | 6 × 319 | 5,229 | 37,547 | 0.11 | 6,630 | 30,111 | 0.13 |
| `flugpl` | 18 × 18 | 3,066 | 3,693 | 0.02 | 2,938 | 3,390 | 0.02 |
| `egout` | 98 × 141 | 5,784 | 60,903 | 0.49 | 5,602 | 41,026 | 0.43 |
| `misc03` | 96 × 160 | 667 | 35,409 | 0.27 | 1,214 | 34,441 | 0.27 |
| `p0201` | 133 × 201 | 550 | 36,101 | 0.30 | 503 | 23,647 | 0.27 |

The primal node engine, the default, takes between 0.60 and 1.65 times the LP pivots of the
dual one. Node counts and times of a parallel search change from run to run (risk 8).

### Pure integer programs: CP-SAT

The seven pure-integer instances of the same set, with a 60 s limit.

| Instance | `CPSAT()` conflicts | LP solves | s | `CPSAT(lpPropagator: false)` conflicts | s |
|---|---|---|---|---|---|
| `p0033` | 1,585 | 424 | 0.00 | 2,886 | 0.00 |
| `stein27` | 84,729 | 2,920 | 0.09 | 91,267 | 0.10 |
| `stein45` | 10,674,216 | 9,872 | 18.62 | 10,699,050 | 19.11 |
| `enigma` | 938 | 209 | 0.00 | 1,172 | 0.00 |
| `lseu` | 89,089 | 30,333 | 0.36 | 709,366 | 1.66 |
| `mod008` | 14,400 | 11,835 | 0.26 | 3,468,156 | 60.00, stopped at 329 (optimum 307) |
| `p0201` | 137,682 | 7,488 | 0.79 | 23,931,691 | 60.00, stopped at 7675 (optimum 7615) |

### The Metal pricing kernel

One pricing scan — reduced costs of every column and the 64 best candidates — on the GPU
against the CPU. In every run the 64 candidates were the ones double precision picks.

| Rows × columns | Nonzeros | CPU ms | Metal ms | Speed-up, this run | Over eleven runs |
|---|---|---|---|---|---|
| 5,000 × 200,000 | 400,000 | 0.550 | 1.373 | 0.40× | 0.35× to 1.23× |
| 10,000 × 1,000,000 | 2,000,000 | 2.577 | 2.071 | 1.24× | 1.08× to 1.89× |
| 20,000 × 3,000,000 | 6,000,000 | 9.138 | 5.986 | 1.53× | 1.17× to 2.30× |

The kernel's time depends on the state of the GPU when it is called, hence the spread.

### Cancellation latency

Time from cancelling the task to `solve` returning, 40 solves per configuration.

| Configuration | Interrupted mid-solve | p50 ms | p99 ms | Worst ms |
|---|---|---|---|---|
| `Simplex(.primal)` | 31 | 0.56 | 3.13 | 3.13 |
| `Simplex(.dual)` | 33 | 0.82 | 2.86 | 2.86 |
| `InteriorPoint()` | 8 | 0.40 | 3.46 | 3.46 |
| `BranchAndBound()` | 34 | 0.85 | 1.68 | 1.68 |
| `CPSAT()` | 30 | 0.69 | 1.71 | 1.71 |
| `CPSAT(lpPropagator: false)` | 40 | 2.34 | 4.43 | 4.43 |
| All 240 | | | 3.64 | 4.43 |

### Memory

Peak resident memory of the benchmark process, read after each section. It is cumulative: a
later figure includes whatever earlier sections left allocated.

| After | Peak resident memory |
|---|---|
| The netlib set | 28 MB |
| The 2,000 × 20,000 transport LP | 131 MB |
| Branch and bound on the MIPLIB 3 set | 1,162 MB |
| CP-SAT on the MIPLIB 3 set | 1,162 MB |
| The Metal section (problems up to 20,000 × 3,000,000) | 1,360 MB |

### Building and testing

| | Measured |
|---|---|
| Clean debug build of the package and its tests | about 22 s |
| The whole test suite, debug build | about 4 minutes |
| Tests | 529 in 13 targets pass in a debug build; the release run of the integration, liveness, CP-SAT and facade targets passes with one recorded known issue (defect 1) |
| Thread Sanitizer | No reports on the simplex, interior-point, branch-and-bound, CP-SAT, facade, integration and liveness targets |

### What these numbers do not say

They come from one machine and from small instances. They say nothing about an iPhone, about
an M1 — the device the acceptance criteria name — or about models larger than 2,000 × 20,000.
Section 3 treats each of those as a risk.
