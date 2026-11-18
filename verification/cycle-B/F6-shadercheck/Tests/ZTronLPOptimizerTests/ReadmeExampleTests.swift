import Testing
import ZTronLPOptimizer

// The usage example of README.md, compiled and checked here so the README cannot drift from
// the API. Keep the two in step: the declarations and the model below are the README's.

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

@Suite struct ReadmeExampleTests {
    let profit: [Product: Double] = [.chair: 45, .table: 80, .desk: 110]
    let hours: [Product: Double] = [.chair: 5, .table: 20, .desk: 15]
    let wood: [Product: Double] = [.chair: 10, .table: 15, .desk: 25]

    var model: LPModel<Plan> {
        LPModel<Plan>()
            .maximizing(sum(over: Product.allCases) { profit[$0]! * Plan.make($0) } - 400 * Plan.overtime)
            .subjectTo {
                (sum(over: Product.allCases) { hours[$0]! * Plan.make($0) } <= 250 + 150 * Plan.overtime)
                    .named("hours")
                (sum(over: Product.allCases) { wood[$0]! * Plan.make($0) } <= 650)
                    .named("wood")
            }
    }

    /// The mixed-integer solve of the README: `Automatic` picks branch and bound.
    @Test func theIntegerPlanIsSolvedToOptimality() async throws {
        var context = SolveContext()
        context.timeLimit = 5       // seconds; reaching it is a result, not an error

        let solution = try await Automatic().solve(model, context: context)

        switch solution.status {
        case .optimal:
            break
        case .feasible(let reason):
            Issue.record("stopped by \(reason) with an incumbent")
        case .infeasible, .unbounded, .infeasibleOrUnbounded, .noSolution, .numericalFailure:
            Issue.record("no solution: \(solution.status)")
        }

        // The optimum, checked against every plan the two resources allow.
        var best = -Double.infinity
        for overtime in 0...1 {
            for chairs in 0...65 {
                for tables in 0...43 {
                    for desks in 0...26 {
                        let used = 5.0 * Double(chairs) + 20 * Double(tables) + 15 * Double(desks)
                        let boards = 10.0 * Double(chairs) + 15 * Double(tables) + 25 * Double(desks)
                        guard used <= 250 + 150 * Double(overtime), boards <= 650 else { continue }
                        let value = 45.0 * Double(chairs) + 80 * Double(tables) + 110 * Double(desks)
                            - 400 * Double(overtime)
                        best = max(best, value)
                    }
                }
            }
        }
        #expect(solution.objectiveValue == best)
        #expect(solution.objectiveValue == 2_600)
        #expect(solution.value(of: .make(.chair)) == 56)
        #expect(solution.value(of: .make(.table)) == 6)
        #expect(solution.value(of: .make(.desk)) == 0)
        #expect(solution.value(of: .overtime) == 1)
        #expect(solution.analysis.engine == "BranchAndBound<Simplex(.primal)>")
    }

    /// The relaxation of the README: a plain LP, with its shadow prices.
    @Test func theRelaxationHasShadowPrices() async throws {
        let relaxed = model
            .continuous(forEach: Product.allCases, Plan.make)
            .continuous(.overtime)
        let lp = try await Simplex(.dual).solve(relaxed)

        #expect(lp.status.isOptimal)
        let objective = try #require(lp.objectiveValue)
        let woodPrice = try #require(lp.dual(ofConstraintNamed: "wood"))
        let hoursPrice = try #require(lp.dual(ofConstraintNamed: "hours"))
        // The relaxation opens half a shift: 65 chairs, overtime = 0.5, 2,725 against 2,600.
        #expect(abs(objective - 2_725) < 1e-6)
        #expect(abs(lp.value(of: .overtime) - 0.5) < 1e-9)
        // One more board-foot of wood is worth 19/6, one more regular hour 8/3.
        #expect(abs(woodPrice - 19.0 / 6) < 1e-9)
        #expect(abs(hoursPrice - 8.0 / 3) < 1e-9)
        #expect(lp.analysis.iterations > 0)
    }
}
