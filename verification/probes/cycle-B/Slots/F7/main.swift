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

// ---- end of the README §1 block (verbatim, lines 89-139 of README.md) ----
await F7Probes.dispatch()
