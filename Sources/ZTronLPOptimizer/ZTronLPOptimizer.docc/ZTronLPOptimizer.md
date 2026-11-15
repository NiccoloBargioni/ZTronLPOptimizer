# ``ZTronLPOptimizer``

Declare and solve linear and mixed-integer linear programs on Apple platforms.

## Overview

ZTronLPOptimizer is the facade of the package: one import brings the modeling DSL, the
compiled model, four engines and the strategies that combine them.

A model is written against a variable family — an enum whose cases are the decision
variables — and solved by a *strategy*, a value configured in its initializer:

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

let solution = try await BranchAndBound().solve(model)
guard solution.status.isOptimal else { return }
let opened = plants.filter { solution.value(of: .open($0)) > 0.5 }
```

Every strategy conforms to ``SolverStrategy`` and every result to ``SolutionAnalysis``; each
engine returns its own decorator over a shared ``SolveRecord``, so the status and the primal
values read the same way on any result while the basis, the node count or the interior-point
residuals stay reachable on the concrete type.

Cancellation and limits are results, never errors: cancelling the task that awaits `solve`
returns `.feasible(stoppedBy: .cancelled)` or `.noSolution(stoppedBy: .cancelled)` with
whatever exists. `solve` throws only ``SolverError``.

## Topics

### Modeling

- ``LPVariable``
- ``VariableDomain``
- ``Bounds``
- ``LinearExpr``
- ``LinearConstraint``
- ``LPModel``
- ``sum(over:_:)``

### Compiled models and file formats

- ``CompiledLP``
- ``CompiledModel``
- ``MPSFormat``
- ``LPFormat``
- ``Presolve``
- ``Scaler``

### Strategies

- ``SolverStrategy``
- ``SolveContext``
- ``Simplex``
- ``InteriorPoint``
- ``BranchAndBound``
- ``CPSAT``
- ``Automatic``
- ``Portfolio``
- ``Conditioned``

### Results

- ``SolutionAnalysis``
- ``Solution``
- ``SolveStatus``
- ``SolveRecord``
- ``SimplexAnalysis``
- ``InteriorPointAnalysis``
- ``BranchAndBoundAnalysis``
- ``CPSATAnalysis``
- ``PortfolioAnalysis``
- ``ConditionedAnalysis``
- ``AnySolutionAnalysis``

### Progress and warm starts

- ``SolverEvent``
- ``WarmStart``
- ``Basis``

### Engines behind the strategies

- ``NodeLPStrategy``
- ``SimplexEngine``
- ``BasisFactorization``
- ``WorkGate``
- ``MetalAccelerator``
- ``ConditioningAnalyzer``
