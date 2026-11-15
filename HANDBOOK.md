# ZTronLPOptimizer — handbook

The view from inside: how the package is put together, how it is tested, the full benchmark
output, and where it departs from its specification. The view from outside — intent, the
public API with its costs, risks, known defects and limits, measured performance — is in
[README.md](README.md).

A Swift package for declaring and solving linear programs (LP) and mixed-integer linear
programs (MILP) on Apple platforms, built on Accelerate and, where single precision is
acceptable, Metal. It implements *ZTronLPOptimizer — Technical Specification v0.1*; section
numbers below (§) refer to that document.

- **Platforms:** iOS 15, macOS 12, Mac Catalyst 15. Swift tools 6.0, every target in the Swift 6
  language mode (complete concurrency checking is an error).
- **Dependencies:** `swift-atomics` and `swift-collections`, nothing else.
- **Numerics:** everything that decides feasibility or optimality runs in IEEE double precision
  on the CPU. The GPU only proposes candidates that the CPU verifies.

**Status of v0.1.** Everything the specification puts in v1 is implemented, the optional
conditioning analyzer and the items on the cut list of §15 included. On the development
machine (Apple M3, macOS 27, Swift 6.4) the test suite passes in debug and release builds, the
Thread Sanitizer run is clean, the package builds for iOS 15 and Mac Catalyst 15, and every
acceptance row of §14.3 holds. One of them, the CP-SAT row, holds because CP-SAT runs with
its LP propagator, which the specification leaves as a post-v1 hook that is off by default;
here it is implemented and on by default. [Known gaps](#known-gaps-against-the-specification)
and [Not verified](#not-verified) say exactly what is missing.

## Quick start

```swift
import ZTronLPOptimizer

enum Vars: LPVariable {
    case ship(Plant, Market)
    case open(Plant)

    var domain: VariableDomain {
        switch self {
        case .ship: return .continuous      // x ≥ 0
        case .open: return .binary
        }
    }
}

let model = LPModel<Vars>()
    .minimizing(
        sum(over: plants) { p in
            fixedCost[p] * Vars.open(p)
                + sum(over: markets) { m in cost[p, m] * Vars.ship(p, m) }
        }
    )
    .subjectTo {
        for p in plants {
            (sum(over: markets) { m in Vars.ship(p, m) } <= supply[p] * Vars.open(p))
                .named("supply[\(p.id)]")
        }
        for m in markets {
            sum(over: plants) { p in Vars.ship(p, m) } >= demand[m]
        }
    }

let solution = try await BranchAndBound().solve(model)      // default node engine: Simplex(.primal)
guard solution.status.isOptimal else { return }
let opened = plants.filter { solution.value(of: .open($0)) > 0.5 }
let rootIterations = solution.analysis.root.iterations      // the decorated root-LP analysis
```

A variable family is an enum; an indexed variable is a case with associated values. Expressions
are generic over the variable type, canonical (each variable once, no zero coefficients,
insertion order kept) and linear by construction: there is no `*` between two expressions, so a
nonlinear model does not compile. `sum(over:_:)` nests to any depth in linear time.

## Strategies

Every solver is a value conforming to `SolverStrategy`: configured in its initializer, run with
`solve(_:)`, reusable, and safe to run concurrently.

| Strategy | What it is | Analysis |
|---|---|---|
| `Simplex(.dual)` / `Simplex(.primal)` | Bounded-variable revised simplex; Devex, steepest-edge, Dantzig or partial pricing; Harris ratio tests; dense-LU or sparse-QR basis; four warm starts | `SimplexAnalysis` |
| `InteriorPoint()` | Mehrotra predictor–corrector on Accelerate's sparse Cholesky, with crossover-lite to a vertex | `InteriorPointAnalysis` |
| `BranchAndBound(engine:)` | Parallel tree search; the node LP engine is a `NodeLPStrategy` (`Simplex(.primal)` by default, `Simplex(.dual)`, `InteriorPoint`, or your own) | `BranchAndBoundAnalysis<Engine.Analysis>` |
| `CPSAT()` | CDCL with lazy bound literals, linear propagation and the linear relaxation as a propagator, for pure integer/Boolean models; `CPSAT(lpPropagator: false)` is the CDCL core alone | `CPSATAnalysis` |
| `Automatic()` | `Simplex(.dual)` up to 4,000 rows, `InteriorPoint` above, `BranchAndBound` when integer columns exist | `AnySolutionAnalysis` |
| `Portfolio([…])` | Runs strategies concurrently, returns the first to conclude, cancels the rest | `PortfolioAnalysis` |
| `Conditioned(inner)` | Runs `inner`, then attaches a `ConditioningReport` | `ConditionedAnalysis<Inner.Analysis>` |

```swift
let lp   = try await Simplex(.dual).solve(model)                           // Solution<Vars, SimplexAnalysis>
let mip  = try await BranchAndBound(engine: Simplex(.dual)).solve(model)   // Solution<Vars, BranchAndBoundAnalysis<SimplexAnalysis>>
let root = mip.analysis.root.basis                                         // the engine's decorated root-LP analysis
var ctx  = SolveContext(); ctx.timeLimit = 10
let ipm  = try await InteriorPoint().solve(compiled.lp, context: ctx)      // InteriorPointAnalysis
let sat  = try await CPSAT(workers: 4).solve(model)
let auto = try await Conditioned(Automatic()).solve(model)                 // ConditionedAnalysis<AnySolutionAnalysis>
```

Run-level resources — time limit, threads, memory budget, Metal policy, warm start, progress
callback — travel in `SolveContext`. There is no global options bag: an initializer carries
exactly the knobs its engine reads.

**Results.** `SolutionAnalysis` is the interface every result conforms to (status, objective,
bound, primal, duals, reduced costs, seconds, warnings). Each engine decorates a shared
`SolveRecord` with its own facts — the final basis and iteration counts, the interior-point
residuals, the node count and incumbent history. Values are unscaled and refer to the problem
as given; the objective and bound are in the model's own sense; `dual[i]` is the sensitivity of
the reported objective to the right-hand side of row *i*; `reducedCosts` has *n + m* entries,
structural then logical.

**Contracts that hold for every strategy.** Cancellation is a result, not an error: cancelling
the task that awaits `solve` returns `.feasible(stoppedBy: .cancelled)` or
`.noSolution(stoppedBy: .cancelled)` with whatever exists. `solve` throws only `SolverError`.
`.finished` is the last progress event and is delivered exactly once on every exit path.
An `.infeasible` LP result carries a dual ray (a Farkas certificate) and an `.unbounded` one a
primal ray.

## Targets

```
ZTronLPOptimizer            Automatic, Portfolio, Conditioned; re-exports everything below
├─ ZTronLPBranchAndBound    NodeLPStrategy, SearchTree actor, workers, branching, heuristics
├─ ZTronLPCPSAT             CDCL core, bound literals, clause/linear/LP propagators, portfolio
├─ ZTronLPInteriorPoint     Mehrotra predictor–corrector, normal equations, crossover-lite
├─ ZTronLPSimplex           primal and dual simplex, pricing, ratio tests, warm starts
├─ ZTronLPMetal             optional fp32 GPU tier: reducedCostScan, batchedActivity
├─ ZTronLPConditioning      optional analyzer: ConditioningReport
├─ ZTronLPNumerics          BLAS/LAPACK/vDSP kernels, Accelerate Sparse wrappers, basis
│                           factorizations, Deadline, WorkGate, ConcurrencyBudget
├─ ZTronLPCore              DSL, LPModel, CompiledLP, presolve-lite, scaling, MPS/LP I/O
├─ CLAPACKShim (C)          legacy BLAS/LAPACK with deprecations silenced, Int32 wrappers
└─ ZTronLPTestSupport       netlib fixtures, reference values, generators, liveness harness
```

Each layer imports only the layers beneath it; branch and bound and CP-SAT are the two that
import an LP engine (§3). `ZTronLPCore` is pure Swift; every engine needs Accelerate.

## Testing

```bash
Scripts/fetch-miplib.sh
```

```bash
Scripts/fetch-satlib.sh
```

```bash
swift test
```

The thirteen netlib LP instances of §14.1 are bundled (with the netlib README the reference
optima were verified against). The MIPLIB 3 and SATLIB instances are fetched by the two scripts
into `.corpora/` with pinned SHA-256 checksums; tests that need a missing instance report a
known issue instead of failing.

Correctness rests on the oracles of §14.1: constructed optima (instances whose optimum is known
by construction), published optima on netlib and MIPLIB 3, cross-engine agreement, and
certificates (every infeasible result's dual ray and every unbounded result's primal ray are
checked numerically). CP-SAT adds two of its own: with the CDCL core alone every learned
clause is replayed from its reason set (§14.2), and with the LP propagator — where a clause
no longer follows by unit propagation — every clause an LP worker learns is checked against
every feasible point of small models by enumeration. The liveness rules of §12.2 each have
a test in `ZTronLPLivenessTests`.
A debug build runs a reduced corpus; the full one (1,000 constructed instances per engine, the
slow MIPLIB instances) needs an optimized build:

```bash
swift test -c release --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests'
```

(`ZTRONLP_SLOW_TESTS=1` runs the slow MIPLIB instances in a debug build as well.) The latency
bounds of rule L1 are the specification's in an optimized build and four times wider in a
debug one. Under Thread Sanitizer, which slows the code about tenfold and is there to find
races, `ZTRONLP_LATENCY_SCALE` widens them, and the time limits of the corpus tests, further:

```bash
ZTRONLP_LATENCY_SCALE=20 swift test --sanitize=thread --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests|ZTronLPBranchAndBoundTests|ZTronLPCPSATTests'
```

`Scripts/lint.sh` runs the greps behind the concurrency rules: no `nonisolated(unsafe)`, no
global mutable state, every `@unchecked Sendable` listed with its invariant, no blocking
primitives. `.github/workflows/ci.yml` runs the build with warnings as errors, the lint, the
tests, the Thread Sanitizer job and an iOS Simulator build.

## Benchmarks

```bash
swift run -c release ZTronLPBenchmarks
```

prints the table of §14.3. The numbers below were measured with it on the machine this package
was developed on — a MacBook with an Apple M3 (8 cores, 24 GB), macOS 27, Swift 6.4, release
build. The specification's reference devices are an M1 MacBook Air, an iPhone 13 and an iPhone
15 Pro; none of them was available, so the last column says what holds on an M3, and nothing
has been **measured on the reference devices**.

| Workload (§14.3) | Measured on the M3 | Acceptance (on an M1) | Result |
|---|---|---|---|
| Netlib set, primal simplex, cold | 0.112 s in total | ≤ 2 s | met |
| Netlib set, dual simplex | 0.087 s in total | ≤ 2 s | met |
| Netlib set, IPM + crossover-lite | 0.038 s in total; at most 17 IPM iterations, crossover at most 127 | ≤ 3 s | met |
| Transport LP, 2,000 × 20,000 | `DenseLUBasis` 2.04 s dual, 3.62 s primal; `SparseQRBasis` 0.64 s dual, 1.03 s primal | both ≤ 10 s; the faster becomes the automatic choice | met; sparse QR is the automatic choice above 1,500 rows |
| MIPLIB 3 set, B&B, primal vs dual node strategy | all ten optimal with both; slowest is `stein45`, 19.6 s primal and 15.9 s dual; the primal strategy takes 0.60–1.65× the dual's LP iterations | every instance ≤ 60 s with both | met |
| MIPLIB 3 set, CP-SAT | 7 of 7 proven optimal: `p0033`, `enigma` 0.00 s, `stein27` 0.09 s, `stein45` 18.6 s, `lseu` 0.36 s, `mod008` 0.26 s, `p0201` 0.79 s | every pure-integer instance ≤ 60 s | met |
| The same with `CPSAT(lpPropagator: false)`, the subset of §10.2 alone | 5 of 7 proven optimal: `p0033`, `enigma` 0.00 s, `stein27` 0.10 s, `stein45` 19.1 s, `lseu` 1.66 s; `mod008` stops at the limit on 329 against 307, `p0201` stops at the limit on 7675 against 7615 | the same | **not met** (see Known gaps) |
| `reducedCostScan`, Metal vs CPU | 0.40× at 200,000 columns, 1.24× at 1,000,000, 1.53× at 3,000,000 in this run; over 11 runs 0.35–1.23×, 1.08–1.89× and 1.17–2.30×, at or above 1.5× in 0, 2 and 9 of them; the 64 candidates agree with fp64 every time | ≥ 1.5× at 5,000 × 200,000, or the threshold is raised | threshold raised to n ≥ 3,000,000 and nnz ≥ 6,000,000 |
| Cancellation latency | p99 3.6 ms, max 4.4 ms over 240 solves across 6 engine configurations | p99 ≤ 50 ms | met |

Peak resident memory over the whole run was 1.3 GB: 1.1 GB after the branch-and-bound section
(the `stein45` trees), the rest from the 3,000,000-column problem of the Metal section. A
solve's default budget is a quarter of the machine's memory.

<details>
<summary>The full output of that run</summary>

```text
# ZTronLPOptimizer benchmarks (specification §14.3)
machine: arm64, 8 cores, 24 GB; build: release

## Netlib set
acceptance for v1: primal ≤ 2 s, dual ≤ 2 s, IPM + crossover-lite ≤ 3 s in total on M1
instance  primal it  s        dual it  s        IPM it  xover it  s        max rel. error
afiro     16         0.001    14       0.000    10      1         0.001    6.1e-12
sc50a     49         0.000    49       0.000    9       0         0.001    6.7e-12
sc50b     49         0.000    49       0.000    8       0         0.000    2.0e-16
sc105     99         0.002    99       0.001    10      6         0.002    5.6e-12
kb2       58         0.000    57       0.001    12      0         0.001    3.5e-12
adlittle  109        0.001    68       0.001    12      6         0.001    1.1e-11
blend     89         0.001    89       0.001    13      4         0.001    5.6e-12
share2b   107        0.001    110      0.002    16      14        0.002    3.4e-12
stocfor1  88         0.001    107      0.001    12      10        0.001    1.1e-11
scagr7    164        0.002    154      0.002    14      0         0.001    1.3e-11
beaconfd  98         0.002    95       0.001    12      4         0.003    6.0e-12
israel    123        0.003    108      0.003    17      3         0.005    3.4e-12
degen2    1011       0.098    539      0.073    13      127       0.022    7.9e-16
total seconds: primal 0.112, dual 0.087, IPM + crossover-lite 0.038
(netlib: 0.272 s wall, peak memory so far 28 MB)

## Random transport LP, 2,000 × 20,000
acceptance for v1: DenseLUBasis and SparseQRBasis both ≤ 10 s on M1; the faster becomes the automatic choice at that size
rows 2000, columns 20000, nonzeros 40000
basis         method   status      iterations  refactors  seconds   objective
DenseLUBasis  dual     optimal     1000        11         2.041     162355.0000
DenseLUBasis  primal   optimal     1942        21         3.616     162355.0000
SparseQRBasis dual     optimal     1000        21         0.639     162355.0000
SparseQRBasis primal   optimal     1942        40         1.032     162355.0000
(interior point)       optimal     12          -          0.141     162355.0000
(transport: 7.472 s wall, peak memory so far 131 MB)

## MIPLIB 3 set, branch and bound, primal vs dual node strategy
acceptance for v1: both solve every instance in ≤ 60 s on M1; the table reports the ratio
instance primal: status  nodes   LP it    s       dual: status  nodes   LP it    s       it ratio objective (reference)
p0033    optimal         915     8005     0.02    optimal       733     5538     0.01    1.45     3089.0000 (3089.0)
stein27  optimal         4383    27247    0.19    optimal       4149    18430    0.16    1.48     18.0000 (18.0)
stein45  optimal         55254   555548   19.63   optimal       54744   343009   15.92   1.62     30.0000 (30.0)
enigma   optimal         2674    93600    0.09    optimal       5001    157026   0.15    0.60     0.0000 (0.0)
lseu     optimal         31697   127732   0.39    optimal       30930   77318    0.36    1.65     1120.0000 (1120.0)
mod008   optimal         5229    37547    0.11    optimal       6630    30111    0.13    1.25     307.0000 (307.0)
flugpl   optimal         3066    3693     0.02    optimal       2938    3390     0.02    1.09     1201500.0000 (1201500.0)
egout    optimal         5784    60903    0.49    optimal       5602    41026    0.43    1.48     568.1007 (568.1007)
misc03   optimal         667     35409    0.27    optimal       1214    34441    0.27    1.03     3360.0000 (3360.0)
p0201    optimal         550     36101    0.30    optimal       503     23647    0.27    1.53     7615.0000 (7615.0)
(mip: 39.255 s wall, peak memory so far 1162 MB)

## MIPLIB 3 set, CP-SAT
acceptance for v1: every pure-integer instance ≤ 60 s on M1
instance configuration              status              conflicts  decisions  LP solves  s        objective (reference)
p0033    CPSAT()                    optimal             1585       2019       424        0.00     3089.0000 (3089.0)
p0033    CPSAT(lpPropagator: false) optimal             2886       3481       0          0.00     3089.0000 (3089.0)
stein27  CPSAT()                    optimal             84729      89911      2920       0.09     18.0000 (18.0)
stein27  CPSAT(lpPropagator: false) optimal             91267      96803      0          0.10     18.0000 (18.0)
stein45  CPSAT()                    optimal             10674216   11324212   9872       18.62    30.0000 (30.0)
stein45  CPSAT(lpPropagator: false) optimal             10699050   11347846   0          19.11    30.0000 (30.0)
enigma   CPSAT()                    optimal             938        1294       209        0.00     0.0000 (0.0)
enigma   CPSAT(lpPropagator: false) optimal             1172       1706       0          0.00     0.0000 (0.0)
lseu     CPSAT()                    optimal             89089      142089     30333      0.36     1120.0000 (1120.0)
lseu     CPSAT(lpPropagator: false) optimal             709366     1217662    0          1.66     1120.0000 (1120.0)
mod008   CPSAT()                    optimal             14400      37293      11835      0.26     307.0000 (307.0)
mod008   CPSAT(lpPropagator: false) feasible/timeLimit  3468156    13645603   0          60.00    329.0000 (307.0)
p0201    CPSAT()                    optimal             137682     170763     7488       0.79     7615.0000 (7615.0)
p0201    CPSAT(lpPropagator: false) feasible/timeLimit  23931691   28690683   0          60.00    7675.0000 (7615.0)
proven optimal within the limit: 7 of 7 by default, 5 of 7 without the LP propagator
(cpsat: 161.017 s wall, peak memory so far 1162 MB)

## reducedCostScan, Metal vs CPU
acceptance for v1: Metal ≥ 1.5× faster on a 5,000 × 200,000 LP, or the threshold is raised
rows    columns    nonzeros   CPU ms    Metal ms  speedup  candidates agreeing with fp64
5000    200000     400000     0.550     1.373     0.40×    64 of 64
10000   1000000    2000000    2.577     2.071     1.24×    64 of 64
20000   3000000    6000000    9.138     5.986     1.53×    64 of 64
automatic thresholds in force: n ≥ 3000000 and nnz ≥ 6000000
(metal: 0.939 s wall, peak memory so far 1360 MB)

## Cancellation latency
acceptance for v1: p99 ≤ 50 ms across engines
engine                      solves  interrupted  p50 ms   p99 ms   max ms
Simplex(.primal)            40      31           0.56     3.13     3.13
Simplex(.dual)              40      33           0.82     2.86     2.86
InteriorPoint               40      8            0.40     3.46     3.46
BranchAndBound              40      34           0.85     1.68     1.68
CPSAT                       40      30           0.69     1.71     1.71
CPSAT(lpPropagator: false)  40      40           2.34     4.43     4.43
all engines: p99 3.64 ms, max 4.43 ms over 240 solves
(latency: 139.964 s wall, peak memory so far 1360 MB)
```

</details>

## Decisions where the specification left room, or contradicts itself

1. **`ZTronLPInteriorPoint` imports `ZTronLPSimplex`.** §3 says engines never depend on each
   other, but crossover-lite (§8.4) runs the simplex engine and `InteriorPointAnalysis.crossover`
   is a `SimplexAnalysis` (§11.3). That one import is unavoidable.
2. **Metal reaches the engines by dependency injection.** §3 has no engine importing the Metal
   target, yet §7.5 and §9.5 have the simplex and branch and bound use its kernels. The kernel
   protocols (`ReducedCostScanning`, `BatchedActivityEvaluating`, `CandidateKernelProvider`) live
   in `ZTronLPNumerics`, and the provider travels in `SolveContext.accelerator`. `Automatic`,
   `Portfolio` and `Conditioned` attach `MetalAccelerator.shared` themselves; a direct engine
   call opts in with `context.attachMetal()`. The same seam lets the tests inject a kernel that
   lies and watch it being disabled.
3. **One `@unchecked Sendable`, not the two §12.1 anticipates.** Rule C3 expects it on
   MetalContext's buffer wrapper and on `NodeState`. Neither needs it: the Metal kernels are
   actors, and `NodeState` is an immutable class of `Sendable` properties. The one occurrence
   is the wrapper around Accelerate's sparse QR factorization (`SparseQRFactorization`), whose
   handles are C structs of raw pointers; without it `SparseQRBasis` could not satisfy
   `BasisFactorization: Sendable` (§6.3). It carries its `// INVARIANT:` comment.
4. **Perturbation: the primal method perturbs bounds, the dual method costs.** §7.3 says "costs
   (primal) or bounds (dual)", and then "the other method cleans up". Cleaning up with the other
   method only works the classical way round — after a bound perturbation the basis stays dual
   feasible, so the dual method repairs it, and vice versa — so that is what is implemented.
5. **The dual regularization is relative to each pivot of M**, not one scalar δ·‖M‖. Near the
   solution the pivots of AΘAᵀ span twenty orders of magnitude; a scalar swamps the small ones
   and the primal residual stalls (netlib `beaconfd` and `israel` did not converge).
6. **Crossover-lite uses the duals as well as the primal point.** §8.4 describes a crash from
   the primal point followed by phase 1 and phase 2. On a degenerate problem that is not
   enough: netlib `degen2` took 278 iterations that way against a budget of 202 (20% of the
   1,011 a cold primal solve takes). Two additions, both on the simplex engine:
   - *The optimal face first.* The duals say which columns rest on a bound in every optimal
     solution; the crash holds them there, so phase 1 ends on a vertex of the optimal face
     instead of somewhere off it. The crash itself ranks logical and structural columns together
     and matches them to rows along augmenting paths, so it recovers the optimal basis from a
     near-vertex point.
   - *A dual push.* The basis of that vertex holds columns the duals pin to a bound (177 of 444
     on `degen2`), so its own duals are far from feasible and repairing them by primal pivots is
     one degenerate pivot after the other. The interior-point duals are feasible already; they
     are moved in a straight line towards the duals of the basis, and each time a nonbasic
     reduced cost reaches zero that column replaces a held one — at most one pivot per held
     column, every pivot counted as a crossover iteration. `degen2` now takes 127.

   This is still not full crossover (there is no primal push of superbasic columns; the crash and
   phase 1 stand in for it), which stays post-v1.
7. **Branch and bound presolves bounds only** (integer rounding, singleton rows to bounds) and
   keeps every row and column, so node LPs, bases, bound changes and the root analysis all live
   in the original column space.
8. **MILP "optimal" means optimal within the gap**, as the comment on `SolveStatus.optimal` says.
   `StopReason.gapReached` is what an LP solve reports when the dual method stops on a cutoff.
9. **An empty column with an improving cost** makes the model unbounded only if the rest of it
   is feasible, so the rest is still solved to tell `.unbounded` (with its ray) from
   `.infeasible`, rather than reported without solving (§5.3 rule 4).
10. **The `reducedCostScan` threshold is raised** from n ≥ 50,000 / nnz ≥ 500,000 to
    n ≥ 3,000,000 / nnz ≥ 6,000,000, as §14.3 prescribes when the kernel is not 1.5× faster than
    the CPU at the specified size. The measurement moves a good deal from run to run — the
    kernel's time depends on the state the GPU is in when the benchmark reaches it — so the
    threshold rests on eleven runs, not one: at 200,000 columns Metal was never 1.5× faster
    (0.35–1.23×); at 1,000,000 it was in two runs (1.08–1.89×); at 3,000,000 in nine
    (1.17–2.30×; the two below were both taken inside the full benchmark, after minutes of
    all-core load). An earlier state of this package had the threshold at 1,000,000, from the
    first two runs alone.
11. **Shader packaging.** Xcode compiles `Shaders/Kernels.metal` into `default.metallib`. The
    command-line build of Swift 6.4 also tries to, and fails outright when the Metal Toolchain
    component is not installed, so `Package.swift` processes the shader only when the manifest
    is evaluated by Xcode (or `ZTRONLP_METAL_PRECOMPILE=1`) and otherwise copies the source,
    which `MetalContext` compiles with `makeLibrary(source:)` at first use.
12. **Small additions to the specified API.** `SolverStrategy.engineName`;
    `SolveContext.accelerator`; `CPSAT(deterministic:)` (§10.3 refers to it, §11.2's initializer
    omits it); `NodeLPStrategy.probe` returns `.infinity` for a child proven infeasible;
    `CompileOptions.lowerSingletonConstraints`; `LPModel` chaining methods are `consuming`;
    `CPSATAnalysis.lpSolves`. One default differs from §11.2: `CPSAT(lpPropagator:)` is `true`
    (decision 15).
13. **Integer columns handed to an LP engine** are relaxed, with a warning.
14. **File formats.** MPS is written in free format by default (fixed format on request, lossy by
    nature). A range row has no portable spelling in LP format and is written as an equality
    against an `Rg…` column, as Gurobi and CPLEX do. The LP reader needs each section keyword on
    its own line.

15. **The LP propagator is implemented, and on by default.** §10.4 leaves
    `CPSAT(lpPropagator:)` as a post-v1 hook and §11.2 defaults it to `false`. Without it the
    CP-SAT row of §14.3 is not met (see Known gaps), so it is implemented and the default is
    `true`; `CPSAT(lpPropagator: false)` is the subset of §10.2 on its own. With the
    propagator every other worker, starting with the first, solves the linear relaxation over
    its current domains — dual simplex, warm-started from the previous basis — each time
    propagation reaches a fixed point. An infeasible relaxation, or one the incumbent rules
    out, is a conflict; reduced costs tighten bounds; an integral optimum is taken as a
    solution; a fractional one names the variable to branch on. None of this rests on
    floating point: the engine's duals (or its Farkas ray) are rounded to integer
    multipliers, the combination of the model's rows they describe is formed in exact Int64
    arithmetic, and conflicts, bound changes and their lazy explanations are read off that
    row. A non-negative integer combination of valid rows is valid whatever the multipliers
    are, so a wrong dual can only prove nothing. Three things keep the default from costing
    anything where the relaxation has nothing to say: rows that are clauses stay out of it,
    so a model made of clauses is searched exactly as before; every look at it is bounded in
    simplex iterations; and a worker whose relaxation keeps proving nothing looks at it less
    and less often. The other half of the portfolio stays pure CDCL.

16. **An unlimited simplex run ends with a second look at tighter tolerances.** "Optimal"
    in v0.1 means that no bound and no reduced-cost sign is violated by more than 1e-7. On an
    ill-conditioned problem several neighbouring bases satisfy that, and their vertices can
    lie far apart: on the 8 × 8 Hilbert matrix as an equality system the basis with seven of
    the eight columns satisfies every row to 2e-10, at distance 1 from the only solution, and
    every engine of the first v0.1 build returned such a point. So when the recomputed
    optimal vertex still shows a violation that stands clear of rounding — above 1e-10, and
    above 1e4 units of roundoff on the terms it is computed from, which is what keeps the
    pass from chasing noise on badly scaled problems — the method goes on at that tolerance,
    with pivots down to the same relative size, for at most min(500, max(50, 2·m)) pivots
    (`SimplexEngine.refine`). The pass can only replace an optimal answer by a better one:
    anything but an optimal ending returns the engine to the basis it started from. It runs
    only when the run has no cutoff and no iteration budget, so branch-and-bound nodes,
    probes and CP-SAT's looks at its relaxation are not touched. On the netlib set and on
    several hundred constructed instances, badly scaled ones included, it changes nothing —
    not a pivot, not a warning; on Hilbert problems up to order 8 every LP
    strategy now returns the solution to about 1e-6, which is what a dense solve in double
    precision gives. Beyond that order the solution cannot be recovered in double precision;
    the answer is then optimal within the tolerances and carries a warning. The warning
    comes from a condition estimate of the optimal basis — `dgecon` on the dense factors,
    Hager's estimate through `ftran` and `btran` otherwise.
17. **The interior point hands a stall to the simplex.** The normal equations square the
    condition number, so on such a problem the residuals stop falling around 1e-6 while
    the complementarity goes to zero. v0.1's test for "not converging" read that as
    infeasible-or-unbounded, which was wrong. A run whose complementarity is closed and
    whose residuals are stuck below 1e-4 is now "stalled": with `crossover: .lite` the
    simplex finishes from the last iterate and its verdict is the answer; with
    `crossover: .none` the result is a numerical failure that says so.
18. **Small pivots as a last resort, and tolerances kept in proportion.** A ratio test that
    finds no entry above the pivot tolerance used to conclude at once: the dual method that
    the row proves infeasibility, the primal method that the step is blocked or unbounded,
    and phase 1 that the infeasibility has no direction of descent. Each of those is only
    true if it is true of the entries that were set aside as too small, so they now get a
    second look, down to a thousandth of the tolerance; a pivot taken there is followed by a
    refactorization, must agree in its own digits when computed by row and by column, and
    counts against a limit of m + 50 per run. Separately, a caller who lowers the
    feasibility tolerances and nothing else gets the pivot tolerance and the Harris slack
    lowered in the proportion the defaults have (`Tolerances.consistent`): with a pivot
    tolerance above the feasibility tolerance the method keeps breaking the feasibility it
    has just restored, which on the Hilbert problem ended in a false "infeasible".

## Known gaps against the specification

- **The CP-SAT row of §14.3 is met only with the LP propagator, and so the default of
  `CPSAT(lpPropagator:)` is not the specification's.** §14.3 gives every pure-integer
  instance of the MIPLIB 3 set 60 s under CP-SAT. There are seven. The subset of §10.2 on its
  own, `CPSAT(lpPropagator: false)`, proves five optimal (`p0033`, `stein27`, `stein45`,
  `enigma`, `lseu`); on `mod008` — which §14.2 lists for CP-SAT — and on `p0201` — which it
  lists for branch and bound only — it finds solutions but neither reaches nor proves the
  optimum inside the limit (across the runs made, `mod008` ended on 316 to 330 against 307,
  `p0201` on 7675 to 7725 against 7615). `mod008` is six covering rows over 319 binaries
  whose costs lie between 56 and 87, so a solution takes four or five columns; proving that
  none costs 306 or less needs a bound on what a budget can cover across the rows, and bounds
  propagation row by row with clause learning does not produce one — it enumerates subsets.
  This is the weakness the risk table of §15 anticipates ("weak on hard combinatorial
  instances"). The LP propagator supplies that bound, and with it, which is the default, all
  seven are proven optimal inside the limit: `mod008` in 0.26 s, `p0201` in 0.79 s, the
  slowest, `stein45`, in 19 s (decision 15, and the benchmark table). The corpus tests cover
  both settings: the default has to close all seven, and the subset of §10.2 records the
  missing proof on `mod008` as a known issue.
- **The LP propagator does not open CP-SAT to continuous columns.** §10 mentions the hook as
  what would let CP-SAT take a MILP with continuous columns. That part is not implemented:
  such a model is rejected with `SolverError.unsupported` with or without the flag, and
  belongs to branch and bound.

## Not verified

- **Swift 6.0.** The package was built and tested with Swift 6.4 only. `Package.swift` enables the
  `SuppressedAssociatedTypes` experimental feature for older compilers, which
  `associatedtype Worker: ~Copyable` (§9.1) needs there; that path has not been compiled.
- **Devices.** Everything ran on an Apple M3 Mac. The iOS and Mac Catalyst builds are verified
  (`xcodebuild`, targets `arm64-apple-ios15.0` and `ios15.0-macabi` for arm64 and x86_64);
  nothing was executed on an iPhone, a simulator or an Intel Mac, and the manual check of rule
  L8 on an iPhone 13 was not done (an automated stand-in runs on the Mac). The benchmark
  acceptance of §14.3 is stated for an M1, which was not available either.
- **Precompiled Metal library.** This Mac has no Metal Toolchain component, so only the
  `makeLibrary(source:)` path was exercised.
- **HiGHS read-back of an LP export** (§14.2, a manual check) was not done.

## Post-v1

As listed in §15: a sparse LU with Forrest–Tomlin updates, Gomory mixed-integer cuts,
feasibility pump and RINS, dense-column handling and a homogeneous self-dual embedding in the
interior point, full crossover, continuous columns, automatic bounding, global constraints
and core-based search in CP-SAT, duplicate-row and dominated-column presolve, a Linux build
of the core.
