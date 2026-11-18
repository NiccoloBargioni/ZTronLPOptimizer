import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

// The facade is the only import an app needs: everything below resolves through it.

struct Plant: Hashable, Sendable { let id: Int }
struct Market: Hashable, Sendable { let id: Int }

/// The worked example of §4.6.
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

enum Transport: LPVariable {
    case ship(Int, Int)
}

private let inf = Double.infinity

@Suite struct WorkedExampleTests {
    let plants = (0..<3).map(Plant.init)
    let markets = (0..<4).map(Market.init)
    let fixedCost: [Plant: Double] = [Plant(id: 0): 120, Plant(id: 1): 90, Plant(id: 2): 150]
    let supply: [Plant: Double] = [Plant(id: 0): 60, Plant(id: 1): 45, Plant(id: 2): 80]
    let demand: [Market: Double] = [Market(id: 0): 20, Market(id: 1): 25, Market(id: 2): 15, Market(id: 3): 30]

    func cost(_ p: Plant, _ m: Market) -> Double {
        Double(2 + (p.id * 3 + m.id * 5) % 7)
    }

    var model: LPModel<Vars> {
        LPModel<Vars>()
            .minimizing(
                sum(over: plants) { p in
                    fixedCost[p]! * Vars.open(p)
                        + sum(over: markets) { m in cost(p, m) * Vars.ship(p, m) }
                }
            )
            .subjectTo {
                for p in plants {
                    (sum(over: markets) { m in Vars.ship(p, m) } <= supply[p]! * Vars.open(p))
                        .named("supply[\(p.id)]")
                }
                for m in markets {
                    (sum(over: plants) { p in Vars.ship(p, m) } >= demand[m]!).named("demand[\(m.id)]")
                }
            }
    }

    /// §4.6, verbatim API: `BranchAndBound().solve(model)`, `value(of:)`, `analysis.root`.
    @Test func facilityLocation() async throws {
        let solution = try await BranchAndBound().solve(model)      // default engine: Simplex(.primal)
        #expect(solution.status.isOptimal)
        let opened = plants.filter { solution.value(of: .open($0)) > 0.5 }
        #expect(!opened.isEmpty)
        let rootIterations = solution.analysis.root.iterations      // the decorated root-LP analysis
        #expect(rootIterations > 0)

        // Check the answer against enumeration over the three open/closed decisions.
        var best = Double.infinity
        for mask in 0..<8 {
            let open = plants.filter { mask & (1 << $0.id) != 0 }
            guard open.reduce(0, { $0 + supply[$1]! }) >= demand.values.reduce(0, +) else { continue }
            let transport = LPModel<Vars>()
                .minimizing(sum(over: open) { p in sum(over: markets) { m in cost(p, m) * Vars.ship(p, m) } })
                .subjectTo {
                    for p in open { sum(over: markets) { m in Vars.ship(p, m) } <= supply[p]! }
                    for m in markets { sum(over: open) { p in Vars.ship(p, m) } >= demand[m]! }
                }
            let lp = try await Simplex(.dual).solve(transport)
            guard lp.status.isOptimal else { continue }
            best = min(best, lp.objectiveValue! + open.reduce(0) { $0 + fixedCost[$1]! })
        }
        #expect(abs(solution.objectiveValue! - best) <= 1e-6 * max(1, best))
        // Every demand is met and no closed plant ships.
        for m in markets {
            let received = plants.reduce(0) { $0 + solution.value(of: .ship($1, m)) }
            #expect(received >= demand[m]! - 1e-6)
        }
        for p in plants where solution.value(of: .open(p)) < 0.5 {
            #expect(solution.values { if case .ship(let from, _) = $0 { return from == p } else { return false } }.values.allSatisfy { $0 <= 1e-6 })
        }
    }

    /// The transport example of the reference design maps one-to-one: remove `open`.
    @Test func transportLPWithNamedDuals() async throws {
        let supply = [30.0, 25, 45]
        let demand = [20.0, 30, 10, 25]
        func cost(_ i: Int, _ j: Int) -> Double { Double(1 + (i * 4 + j * 3) % 6) }
        let model = LPModel<Transport>()
            .minimizing(sum(over: 0..<3) { i in sum(over: 0..<4) { j in cost(i, j) * Transport.ship(i, j) } })
            .subjectTo(forEach: 0..<3, name: { "supply[\($0)]" }) { i in
                sum(over: 0..<4) { j in Transport.ship(i, j) } <= supply[i]
            }
            .subjectTo(forEach: 0..<4, name: { "demand[\($0)]" }) { j in
                sum(over: 0..<3) { i in Transport.ship(i, j) } >= demand[j]
            }
        let lp = try await Simplex(.dual).solve(model)                           // Solution<Transport, SimplexAnalysis>
        #expect(lp.status.isOptimal)
        // Strong duality by name: Σ supply·dual + Σ demand·dual = objective.
        var dualObjective = 0.0
        for i in 0..<3 { dualObjective += supply[i] * (try #require(lp.dual(ofConstraintNamed: "supply[\(i)]"))) }
        for j in 0..<4 { dualObjective += demand[j] * (try #require(lp.dual(ofConstraintNamed: "demand[\(j)]"))) }
        #expect(abs(dualObjective - lp.objectiveValue!) <= 1e-7 * max(1, abs(lp.objectiveValue!)))
        #expect(lp.dual(ofConstraintNamed: "nope") == nil)
        // Reduced costs are nonnegative at the optimum of a minimization with x ≥ 0.
        for i in 0..<3 { for j in 0..<4 { #expect(lp.reducedCost(of: .ship(i, j)) >= -1e-7) } }
        // An interior-point solve of the same model agrees.
        let ipm = try await InteriorPoint().solve(model)
        #expect(abs(ipm.objectiveValue! - lp.objectiveValue!) <= 1e-6 * max(1, abs(lp.objectiveValue!)))
    }

    /// The calls of §11.2, as written there.
    @Test func theStrategiesOfSection11Compose() async throws {
        let compiled = try model.compile()
        let lp = try await Simplex(.dual).solve(model)                           // Solution<Vars, SimplexAnalysis>
        let mip = try await BranchAndBound(engine: Simplex(.dual)).solve(model)  // Solution<Vars, BranchAndBoundAnalysis<SimplexAnalysis>>
        let root = mip.analysis.root.basis                                       // the engine's decorated root-LP analysis
        var ctx = SolveContext(); ctx.timeLimit = 10
        let ipm = try await InteriorPoint().solve(compiled.lp, context: ctx)     // InteriorPointAnalysis
        let auto = try await Conditioned(Automatic()).solve(model)               // ConditionedAnalysis<AnySolutionAnalysis>
        #expect(lp.status.isOptimal && ipm.status.isOptimal && mip.status.isOptimal && auto.status.isOptimal)
        #expect(root.basic.count == compiled.lp.m)
        // The relaxation bounds the MIP from below (a minimization).
        #expect(lp.objectiveValue! <= mip.objectiveValue! + 1e-7)
        #expect(abs(lp.objectiveValue! - ipm.objectiveValue!) <= 1e-6 * max(1, abs(lp.objectiveValue!)))
        #expect(abs(auto.objectiveValue! - mip.objectiveValue!) <= 1e-6 * max(1, abs(mip.objectiveValue!)))
        #expect(!auto.analysis.report.markdown.isEmpty)
        // The type-erased analysis unwraps to the concrete one.
        #expect(auto.analysis.base.unwrap(as: BranchAndBoundAnalysis<SimplexAnalysis>.self) != nil)
        #expect(auto.analysis.base.unwrap(as: SimplexAnalysis.self) == nil)
    }
}

@Suite struct AutomaticTests {
    static func shell(rows: Int, columns: Int, integer: Bool = false, denseColumn: Bool = false) -> CompiledLP {
        // One entry per row; optionally one column that touches every row.
        var entries: [(row: Int, col: Int, value: Double)] = (0..<rows).map { ($0, $0 % columns, 1.0) }
        if denseColumn { entries += (0..<rows).map { ($0, columns - 1, 1.0) } }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: rows, cols: columns, entries), c: [Double](repeating: 1, count: columns),
            xl: [Double](repeating: 0, count: columns), xu: [Double](repeating: 1, count: columns),
            rl: [Double](repeating: 0, count: rows), ru: [Double](repeating: inf, count: rows),
            integerColumns: integer ? [0] : [])
    }

    @Test func choiceFollowsTheShapeOfTheProblem() {
        #expect(Automatic.choice(for: Self.shell(rows: 10, columns: 5)) == .dualSimplex)
        #expect(Automatic.choice(for: Self.shell(rows: 4_000, columns: 50)) == .dualSimplex)
        #expect(Automatic.choice(for: Self.shell(rows: 4_001, columns: 50)) == .interiorPoint)
        #expect(Automatic.choice(for: Self.shell(rows: 10_001, columns: 50)) == .interiorPoint)
        #expect(Automatic.choice(for: Self.shell(rows: 10_001, columns: 50, denseColumn: true)) == .sparseSimplex)
        #expect(Automatic.choice(for: Self.shell(rows: 9_000, columns: 50, denseColumn: true)) == .interiorPoint)
        // Integer columns win over everything else.
        #expect(Automatic.choice(for: Self.shell(rows: 10, columns: 5, integer: true)) == .branchAndBound)
        #expect(Automatic.choice(for: Self.shell(rows: 20_000, columns: 50, integer: true, denseColumn: true)) == .branchAndBound)
    }

    @Test func runsTheChosenEngineAndErasesItsAnalysis() async throws {
        let lp = try NetlibFixtures.load("afiro")
        let analysis = try await Automatic().solve(lp)
        #expect(analysis.status == .optimal && analysis.engine == "Simplex(.dual)")
        let simplex = try #require(analysis.unwrap(as: SimplexAnalysis.self))
        #expect(simplex.method == .dual || simplex.method == .primal)
        #expect(analysis.finalBasis == simplex.basis)
        let reference = ReferenceValues.netlib(named: "afiro")!.optimalObjective
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)

        let mip = InstanceGenerator.randomMILP(rows: 5, columns: 15, seed: 3)
        let second = try await Automatic().solve(mip)
        #expect(second.status == .optimal && second.engine == "BranchAndBound<Simplex(.primal)>")
        #expect(second.unwrap(as: BranchAndBoundAnalysis<SimplexAnalysis>.self) != nil)
        #expect(second.dual == nil)
    }

    @Test func eventsFinishExactlyOnce() async throws {
        var context = SolveContext()
        let stream = context.makeEventStream()
        _ = try await Automatic().solve(try NetlibFixtures.load("sc50a"), context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.filter(\.isFinished).count == 1 && events.last?.isFinished == true)
        #expect(events.filter { if case .started = $0 { return true } else { return false } }.count == 1)
    }
}

@Suite struct PortfolioTests {
    @Test func theFirstToConcludeWinsAndTheOthersAreReported() async throws {
        let lp = try NetlibFixtures.load("israel")
        let portfolio = Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()])
        var context = SolveContext()
        let stream = context.makeEventStream()
        let analysis = try await portfolio.solve(lp, context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }

        #expect(analysis.status == .optimal)
        let reference = ReferenceValues.netlib(named: "israel")!.optimalObjective
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        #expect(analysis.others.count == 2)
        let names = Set([analysis.winner] + analysis.others.map(\.strategy))
        #expect(names == ["Simplex(.primal)", "Simplex(.dual)", "InteriorPoint(crossover: .lite)"])
        #expect(analysis.base.engine == analysis.winner)
        // The losers either finished too or were cancelled; none failed.
        for other in analysis.others {
            #expect(other.status == .optimal || other.status.stopReason == .cancelled, "\(other)")
        }
        // One start, one finish, and the finish is last.
        #expect(events.filter(\.isFinished).count == 1 && events.last?.isFinished == true)
        #expect(events.filter { if case .started = $0 { return true } else { return false } }.count == 1)
        if case .started(let engine, _, _, _) = events[0] { #expect(engine.hasPrefix("Portfolio(")) }
    }
}

@Suite struct ConditionedTests {
    @Test func attachesAReportAndForwardsTheAnalysis() async throws {
        let lp = try NetlibFixtures.load("share2b")
        let plain = try await Simplex(.dual).solve(lp)
        let conditioned = try await Conditioned(Simplex(.dual)).solve(lp)
        #expect(conditioned.status == plain.status)
        #expect(conditioned.objectiveValue == plain.objectiveValue)
        #expect(conditioned.primal == plain.primal)
        #expect(conditioned.base.basis == plain.basis)
        #expect(conditioned.finalBasis == plain.basis)
        // The basis was available, so its condition number was estimated.
        #expect(conditioned.report.basisConditionEstimate != nil)
        #expect(conditioned.report.markdown.contains("#"))
        #expect(conditioned.report.coefficientRange.matrix.upperBound >= conditioned.report.coefficientRange.matrix.lowerBound)
    }

    @Test func eventsFinishOnceAfterTheInnerSolve() async throws {
        var context = SolveContext()
        let stream = context.makeEventStream()
        _ = try await Conditioned(BranchAndBound()).solve(InstanceGenerator.randomMILP(rows: 5, columns: 14, seed: 2), context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.filter(\.isFinished).count == 1 && events.last?.isFinished == true)
        if case .started(let engine, _, _, _) = events[0] {
            #expect(engine == "Conditioned<BranchAndBound<Simplex(.primal)>>")
        } else {
            Issue.record("the first event is not .started")
        }
        #expect(events.contains { if case .newIncumbent = $0 { return true } else { return false } })
    }
}
