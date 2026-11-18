import Testing
import ZTronLPCore
import ZTronLPInteriorPoint
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

private let inf = Double.infinity

/// Builds a small problem from dense rows.
func denseMIP(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double]? = nil, xu: [Double]? = nil,
    integer: [Int], sense: ObjectiveSense = .minimize
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, sense: sense,
        xl: xl ?? [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: .infinity, count: n),
        rl: rl, ru: ru, integerColumns: integer.map { Int32($0) })
}

/// The optimum of a pure-integer problem with small finite domains, by enumeration; `nil`
/// when no integer point is feasible. The value is in the model's own sense.
func bruteForce(_ lp: CompiledLP) -> Double? {
    precondition(lp.integerColumns.count == lp.n, "enumeration needs a pure-integer problem")
    var point = lp.xl
    var best: Double? = nil
    func better(_ a: Double, than b: Double) -> Bool { lp.sense == .maximize ? a > b : a < b }
    while true {
        let activity = lp.a.multiply(point)
        var feasible = true
        for i in 0..<lp.m where activity[i] < lp.rl[i] - 1e-9 || activity[i] > lp.ru[i] + 1e-9 {
            feasible = false
            break
        }
        if feasible {
            let value = lp.objective(at: point)
            if best == nil || better(value, than: best!) { best = value }
        }
        // Next point, odometer style.
        var j = 0
        while j < lp.n {
            if point[j] < lp.xu[j] {
                point[j] += 1
                break
            }
            point[j] = lp.xl[j]
            j += 1
        }
        if j == lp.n { break }
    }
    return best
}

/// Checks that a MIP solution is integral and feasible for the problem as given.
func isIntegralAndFeasible(_ lp: CompiledLP, _ x: [Double]) -> Bool {
    for column in lp.integerColumns where abs(x[Int(column)] - x[Int(column)].rounded()) > 1e-6 { return false }
    let violation = lp.maxViolation(at: x)
    return violation.bounds <= 1e-6 && violation.rows <= 1e-6
}

@Suite struct BranchAndBoundBasicsTests {
    @Test func theDefaultEngineIsThePrimalSimplex() {
        // §9: "The default engine is Simplex(.primal), as required."
        #expect(BranchAndBound().engine.method == .primal)
        #expect(BranchAndBound(engine: Simplex(.dual)).engine.method == .dual)
        #expect(BranchAndBound().branching == .pseudocost(reliability: 4))
        #expect(BranchAndBound().nodeSelection == .bestBoundWithPlunging(maxDepth: 32))
        #expect(BranchAndBound().gap == Gap(relative: 1e-4, absolute: 1e-6))
    }

    @Test func textbookKnapsack() async throws {
        // max 5x + 4y + 3z  s.t.  2x + 3y + z ≤ 5, 4x + y + 2z ≤ 11, 3x + 4y + 2z ≤ 8, integers.
        let lp = denseMIP(
            c: [5, 4, 3], rows: [[2, 3, 1], [4, 1, 2], [3, 4, 2]], rl: [-inf, -inf, -inf], ru: [5, 11, 8],
            xu: [10, 10, 10], integer: [0, 1, 2], sense: .maximize)
        let expected = try #require(bruteForce(lp))
        #expect(expected == 13)
        for engine in [Simplex(.primal), Simplex(.dual)] {
            let analysis = try await BranchAndBound(engine: engine).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - expected) < 1e-9)
            #expect(isIntegralAndFeasible(lp, analysis.primal!))
            #expect(analysis.bound != nil && analysis.gap! <= 1e-4)
            #expect(analysis.dual == nil && analysis.reducedCosts == nil)
            #expect(analysis.incumbents == analysis.incumbentHistory.count && analysis.incumbents >= 1)
            // The root is the engine's own analysis of the root LP.
            #expect(analysis.root.status == .optimal)
            #expect(analysis.root.objectiveValue! >= expected - 1e-9)
            #expect(analysis.root.basis.basic.count == lp.m)
            #expect(analysis.finalBasis == analysis.root.basis)
        }
    }

    @Test func infeasibleAndUnboundedModels() async throws {
        // No integer point: 2x = 3.
        let odd = denseMIP(c: [1], rows: [[2]], rl: [3], ru: [3], xu: [10], integer: [0])
        #expect(try await BranchAndBound().solve(odd).status == .infeasible)
        // LP infeasible already.
        let empty = denseMIP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 3], ru: [1, inf], integer: [0, 1])
        let analysis = try await BranchAndBound().solve(empty)
        #expect(analysis.status == .infeasible)
        #expect(analysis.root.status == .infeasible && analysis.root.dualRay != nil)
        // Unbounded relaxation.
        let open = denseMIP(c: [-1, -1], rows: [[1, -1]], rl: [-inf], ru: [1], integer: [0, 1])
        #expect(try await BranchAndBound().solve(open).status == .infeasibleOrUnbounded)
        // An integer column whose bounds contain no integer.
        let gap = denseMIP(c: [1, 1], rows: [[1, 1]], rl: [1], ru: [inf], xl: [0.2, 0], xu: [0.8, 5], integer: [0])
        #expect(try await BranchAndBound().solve(gap).status == .infeasible)
    }

    @Test func aPureLPIsSolvedAtTheRoot() async throws {
        let lp = denseMIP(c: [3, 5], rows: [[1, 0], [0, 2], [3, 2]], rl: [-inf, -inf, -inf], ru: [4, 12, 18], integer: [], sense: .maximize)
        let analysis = try await BranchAndBound().solve(lp)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - 36) < 1e-9)
        #expect(analysis.nodesProcessed == 1 && analysis.nodesOpen == 0)
    }

    @Test func mixedIntegerWithGeneralIntegers() async throws {
        // min x + 2y − z with x integer in [0, 7], y continuous, z integer in [−3, 3].
        let lp = denseMIP(
            c: [1, 2, -1], rows: [[2, 1, 1], [1, -1, 3]], rl: [7.5, -inf], ru: [inf, 6.2],
            xl: [0, 0, -3], xu: [7, 10, 3], integer: [0, 2])
        var objectives: [Double] = []
        let configurations: [BranchAndBound<Simplex>] = [
            BranchAndBound(), BranchAndBound(engine: Simplex(.dual)),
            BranchAndBound(branching: .mostFractional), BranchAndBound(branching: .strong(candidates: 10)),
            BranchAndBound(nodeSelection: .bestBound), BranchAndBound(nodeSelection: .depthFirst),
            BranchAndBound(heuristics: .none), BranchAndBound(deterministic: true),
        ]
        for configuration in configurations {
            let analysis = try await configuration.solve(lp)
            #expect(analysis.status == .optimal)
            #expect(isIntegralAndFeasible(lp, analysis.primal!))
            objectives.append(analysis.objectiveValue!)
        }
        for value in objectives { #expect(abs(value - objectives[0]) <= 1e-6) }
    }
}

@Suite struct BranchAndBoundRandomTests {
    /// Random small pure-integer models against enumeration, with every strategy.
    @Test func agreesWithEnumeration() async throws {
        var checked = 0
        for seed in 0..<40 {
            let binary = seed % 2 == 0
            let lp = InstanceGenerator.randomMILP(
                rows: 3 + seed % 4, columns: binary ? 10 + seed % 4 : 6, seed: UInt64(1000 + seed), upper: binary ? 1 : 3)
            let expected = try #require(bruteForce(lp))
            let strategies: [BranchAndBound<Simplex>] = [
                BranchAndBound(), BranchAndBound(engine: Simplex(.dual)),
                BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none),
                BranchAndBound(deterministic: true),
            ]
            for strategy in strategies {
                let analysis = try await strategy.solve(lp)
                #expect(analysis.status == .optimal, "seed \(seed)")
                #expect(abs(analysis.objectiveValue! - expected) <= 1e-6, "seed \(seed): \(analysis.objectiveValue!) vs \(expected)")
                #expect(isIntegralAndFeasible(lp, analysis.primal!))
                checked += 1
            }
        }
        #expect(checked == 160)
    }

    @Test func interiorPointRootAgreesWithTheSimplexEngines() async throws {
        for seed in 0..<6 {
            let lp = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: UInt64(77 + seed), integerFraction: 0.6)
            let simplex = try await BranchAndBound(engine: Simplex(.dual)).solve(lp)
            let interior = try await BranchAndBound(engine: InteriorPoint()).solve(lp)
            #expect(simplex.status == .optimal && interior.status == .optimal)
            #expect(abs(simplex.objectiveValue! - interior.objectiveValue!) <= 1e-4 * max(1, abs(simplex.objectiveValue!)))
            // The root analysis is the interior point's, with its crossover basis.
            #expect(interior.root.iterations > 0)
            #expect(interior.root.crossover != nil)
            #expect(interior.finalBasis?.basic.count == lp.m)
        }
    }

    @Test func mixedModelsAgreeAcrossStrategiesAndWorkerCounts() async throws {
        for seed in 0..<8 {
            let lp = InstanceGenerator.randomMILP(
                rows: 6, columns: 24, seed: UInt64(500 + seed), integerFraction: 0.5, upper: 2, integralData: false)
            var reference: Double? = nil
            for threads in [1, 2, 8] {
                var context = SolveContext()
                context.threads = threads
                let analysis = try await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: context)
                #expect(analysis.status == .optimal)
                #expect(isIntegralAndFeasible(lp, analysis.primal!))
                if let reference {
                    #expect(abs(analysis.objectiveValue! - reference) <= 1e-4 * max(1, abs(reference)))
                } else {
                    reference = analysis.objectiveValue
                }
            }
        }
    }
}

@Suite struct BranchAndBoundLimitsTests {
    static func hardInstance() -> CompiledLP {
        InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)
    }

    @Test func nodeLimitIsAResult() async throws {
        let analysis = try await BranchAndBound(nodeLimit: 3).solve(Self.hardInstance())
        #expect(analysis.status.stopReason == .nodeLimit)
        #expect(analysis.nodesProcessed >= 3)
        if analysis.status.hasSolution {
            #expect(isIntegralAndFeasible(Self.hardInstance(), analysis.primal!))
            #expect(analysis.gap != nil)
        }
    }

    @Test func timeLimitAndCancellationAreResults() async throws {
        let lp = Self.hardInstance()
        var context = SolveContext()
        context.timeLimit = 0
        let limited = try await BranchAndBound().solve(lp, context: context)
        #expect(limited.status.stopReason == .timeLimit)

        let strategy = BranchAndBound()
        let task = Task { try await strategy.solve(lp) }
        task.cancel()
        let cancelled = try await task.value
        #expect(cancelled.status.stopReason == .cancelled)
        // Rule L2: the same strategy value solves again afterwards.
        #expect(try await strategy.solve(lp).status == .optimal)
    }

    /// Rule L7: with a tiny budget the pool first drops parent states, then stops with
    /// `.memoryBudget`, keeping whatever incumbent exists.
    @Test func memoryBudgetDegradesThenStops() async throws {
        let lp = Self.hardInstance()
        var context = SolveContext()
        context.memoryBudgetBytes = 2_000
        let analysis = try await BranchAndBound(nodeSelection: .bestBound, heuristics: .none).solve(lp, context: context)
        #expect(analysis.status.stopReason == .memoryBudget || analysis.status == .optimal)
        // A comfortable budget solves it.
        context.memoryBudgetBytes = 16 * 1024 * 1024
        #expect(try await BranchAndBound().solve(lp, context: context).status == .optimal)
    }

    @Test func aLooseGapStopsEarlyAndReportsIt() async throws {
        let lp = Self.hardInstance()
        let exact = try await BranchAndBound(engine: Simplex(.dual)).solve(lp)
        let loose = try await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0.2, absolute: 1e-6)).solve(lp)
        #expect(loose.status == .optimal)
        #expect(loose.nodesProcessed <= exact.nodesProcessed)
        #expect(loose.gap! <= 0.2 + 1e-9)
        // The reported bound really bounds the true optimum (a maximization: bound ≥ optimum).
        #expect(loose.bound! >= exact.objectiveValue! - 1e-6)
    }

    /// Rule L10 and §11.4: events are ordered, `.finished` comes last and once.
    @Test func eventsAreOrderedAndFinishOnce() async throws {
        var context = SolveContext()
        let stream = context.makeEventStream()
        let analysis = try await BranchAndBound(deterministic: true).solve(Self.hardInstance(), context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        guard case .started(let engine, _, _, _) = events.first else {
            Issue.record("the first event is not .started")
            return
        }
        #expect(engine == "BranchAndBound<Simplex(.primal)>")
        #expect(events.filter(\.isFinished).count == 1 && events.last?.isFinished == true)
        let incumbents = events.compactMap { event -> Double? in
            if case .newIncumbent(let objective, _, _) = event { return objective }
            return nil
        }
        #expect(incumbents.count == analysis.incumbents)
        // A maximization: every new incumbent is better than the last.
        #expect(incumbents == incumbents.sorted())
        #expect(incumbents.last == analysis.objectiveValue)
    }
}

/// Rule C9: deterministic mode produces identical results and identical event sequences.
@Suite struct BranchAndBoundDeterminismTests {
    static func strip(_ events: [SolverEvent]) -> [SolverEvent] {
        events.map { event in
            if case .finished(let status, _) = event { return .finished(status: status, seconds: 0) }
            return event
        }
    }

    @Test func twentyRunsAreIdentical() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 10, columns: 40, seed: 9, upper: 1)
        var first: (objective: Double, nodes: Int, iterations: Int, primal: [Double], events: [SolverEvent])? = nil
        for _ in 0..<20 {
            var context = SolveContext()
            context.threads = 4
            let stream = context.makeEventStream()
            let analysis = try await BranchAndBound(deterministic: true, seed: 7).solve(lp, context: context)
            var events: [SolverEvent] = []
            for await event in stream { events.append(event) }
            let run = (analysis.objectiveValue!, analysis.nodesProcessed, analysis.lpIterations, analysis.primal!, Self.strip(events))
            if let first {
                #expect(run.0 == first.objective)
                #expect(run.1 == first.nodes)
                #expect(run.2 == first.iterations)
                #expect(run.3 == first.primal)
                #expect(run.4 == first.events)
            } else {
                first = run
                #expect(analysis.status == .optimal)
            }
        }
    }
}
