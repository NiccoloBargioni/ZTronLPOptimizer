import Foundation
import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

private let inf = Double.infinity

private func dense(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xu: [Double]? = nil, integer: [Int] = [],
    sense: ObjectiveSense = .minimize
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, sense: sense,
        xl: [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: .infinity, count: n), rl: rl, ru: ru,
        integerColumns: integer.map { Int32($0) })
}

/// Rule L3: every engine terminates in bounded iterations — simplex by anti-cycling and
/// `maxIterations`, the interior point by its 200-iteration cap, branch and bound by finite
/// domains, node limit and gap, CP-SAT by its conflict limit per restart and the
/// objective-tightening sequence.
@Suite struct L3TerminationTests {
    static func kleeMinty(_ n: Int) -> CompiledLP {
        func power(_ base: Double, _ k: Int) -> Double { (0..<k).reduce(1.0) { value, _ in value * base } }
        var rows: [[Double]] = []
        var ru: [Double] = []
        for i in 0..<n {
            var row = [Double](repeating: 0, count: n)
            for j in 0..<i { row[j] = power(2, i - j + 1) }
            row[i] = 1
            rows.append(row)
            ru.append(power(5, i + 1))
        }
        return dense(
            c: (0..<n).map { power(2, n - 1 - $0) }, rows: rows, rl: [Double](repeating: -inf, count: n), ru: ru,
            sense: .maximize)
    }

    static let beale = dense(
        c: [-0.75, 150, -0.02, 6], rows: [[0.25, -60, -0.04, 9], [0.5, -90, -0.02, 3], [0, 0, 1, 0]],
        rl: [-inf, -inf, -inf], ru: [0, 0, 1])

    @Test func kleeMintyAndBealeTerminate() async throws {
        let cube = Self.kleeMinty(10)
        let optimum = (0..<10).reduce(1.0) { value, _ in value * 5 }
        for method in [Simplex.Method.primal, .dual] {
            let first = try await Simplex(method, pricing: .dantzig, presolve: false, scaling: .none).solve(cube)
            #expect(first.status == .optimal && abs(first.objectiveValue! - optimum) <= 1e-6 * optimum)
            // Beale's example cycles under Dantzig pricing with the textbook ratio test.
            let second = try await Simplex(method, pricing: .dantzig, perturbation: .off, presolve: false, scaling: .none)
                .solve(Self.beale)
            #expect(second.status == .optimal && abs(second.objectiveValue! - (-0.05)) <= 1e-9)
        }
        let interior = try await InteriorPoint().solve(cube)
        #expect(interior.status == .optimal && interior.iterations <= 200)
    }

    @Test func degenerateNetlibInstanceTerminates() async throws {
        let lp = try NetlibFixtures.load("degen2")
        let reference = ReferenceValues.netlib(named: "degen2")!.optimalObjective
        for strategy in [Simplex(.primal), Simplex(.dual), Simplex(.primal, perturbation: .off), Simplex(.dual, perturbation: .off)] {
            let analysis = try await strategy.solve(lp)
            #expect(analysis.status == .optimal)
            #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        }
    }

    @Test func iterationAndNodeLimitsBoundEverySolve() async throws {
        let lp = try NetlibFixtures.load("degen2")
        for method in [Simplex.Method.primal, .dual] {
            let analysis = try await Simplex(method, maxIterations: 25).solve(lp)
            #expect(analysis.status.stopReason == .iterationLimit && analysis.iterations <= 25)
        }
        let capped = try await InteriorPoint(crossover: .none, maxIterations: 2).solve(lp)
        #expect(capped.status == .noSolution(stoppedBy: .iterationLimit) && capped.iterations == 2)

        // Random MIPs with a node limit.
        for seed in 0..<10 {
            let mip = InstanceGenerator.randomMILP(rows: 10, columns: 50, seed: UInt64(60 + seed), upper: 2)
            let analysis = try await BranchAndBound(nodeLimit: 20).solve(mip)
            #expect(analysis.status == .optimal || analysis.status.stopReason == .nodeLimit)
            // The limit is checked when a node is handed back, so workers in flight may add a few.
            #expect(analysis.nodesProcessed <= 20 + ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    @Test func cpSatTerminatesOnSatisfiableAndUnsatisfiableModels() async throws {
        // Feasible, with a nontrivial optimum.
        let mip = LivenessProblems.smallMIP()
        let reference = try await BranchAndBound(engine: Simplex(.dual)).solve(mip).objectiveValue!
        let analysis = try await CPSAT().solve(mip)
        #expect(analysis.status == .optimal && abs(analysis.objectiveValue! - reference) <= 1e-6)
        // Infeasible: x + y ≥ 3 over binaries.
        let none = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [inf], xu: [1, 1], integer: [0, 1])
        #expect(try await CPSAT().solve(none).status == .infeasible)
    }
}

/// Rule L6: numerical safeguards converge — at most 3 consecutive residual failures, at most
/// 2 Cholesky retries, at most 500 perturbation clean-up iterations; each exhausts into
/// `.numericalFailure`, never a retry loop.
@Suite struct L6SafeguardTests {
    @Test func residualFailuresExhaustIntoNumericalFailure() async throws {
        let lp = try NetlibFixtures.load("share2b")
        for method in [Simplex.Method.primal, .dual] {
            var engine = Simplex(method).makeEngine(for: lp, context: SolveContext())
            engine.faults.failingResidualChecks = .max
            var gate = WorkGate(deadline: .none)
            let failed = try await engine.solve(method: method, warmStart: .none, gate: &gate)
            guard case .numericalFailure(let message) = failed.status else {
                Issue.record("expected a numerical failure, got \(failed.status)")
                continue
            }
            #expect(message.contains("three times"))
            // The engine is still usable: with the fault gone it solves.
            engine.faults.failingResidualChecks = 0
            let recovered = try await engine.solve(method: method, warmStart: .none, gate: &gate)
            #expect(recovered.status == .optimal)
        }
    }

    @Test func choleskyRetriesAreBoundedAndEndInLDLT() async throws {
        let problem = try NetlibFixtures.load("share2b")
        let scaled = Scaler.scale(Presolve.run(problem).reduced, mode: .geometricEquilibration)
        var worker = try IPMWorker(lp: scaled, config: InteriorPoint())
        // Two forced breakdowns: δ × 100, then LDLᵀ for the rest of the solve.
        worker.failingFactorizations = 2
        var gate = WorkGate(deadline: .none)
        let outcome = try await worker.run(gate: &gate)
        #expect(outcome.status == .converged)
        #expect(outcome.warnings.filter { $0.contains("Cholesky broke down") }.count == 2)
        #expect(outcome.iterations <= 200)
    }

    @Test func perturbationCleanupIsBounded() async throws {
        // Each problem is built so that the perturbation changes which constraint binds, for
        // every random draw — a perturbation is relative to the size of what it perturbs — so
        // that removing it at optimality always leaves work for the clean-up pass. A zero
        // budget for that pass must end the solve as a numerical failure, not loop.
        //
        // Primal method, bounds perturbed: max x with x + z ≤ 1001 (z fixed at 1000) and
        // x ≤ 1.0001. The first row's bound moves by about 1e-3, the second's by 1e-6, so the
        // perturbed optimum rests on the second row, 1e-4 beyond the first.
        let boundCase = CompiledLP(
            a: SparseCSC.fromTriplets(rows: 2, cols: 2, [(0, 0, 1), (0, 1, 1), (1, 0, 1)]), c: [-1, 0],
            sense: .minimize, xl: [0, 1000], xu: [inf, 1000], rl: [-inf, -inf], ru: [1001, 1.0001])
        // Dual method, costs perturbed: min −0.001a − 1.0001b with 0.001a + b ≤ 1, a ≤ 2000,
        // b ≤ 2. Per unit of the row, b is worth 1e-4 more than a; but a's cost moves by about
        // 1e-3 per unit and b's by 1e-6, so the perturbed optimum keeps a instead of b.
        let costCase = dense(c: [-0.001, -1.0001], rows: [[0.001, 1]], rl: [-inf], ru: [1], xu: [2000, 2])
        let cases: [(method: Simplex.Method, lp: CompiledLP, optimum: Double)] = [
            (.primal, boundCase, -1), (.dual, costCase, -1.0001),
        ]
        for (method, lp, optimum) in cases {
            // No presolve and no scaling: the sizes above are the point.
            var engine = Simplex(method, perturbation: .always, presolve: false, scaling: .none)
                .makeEngine(for: lp, context: SolveContext())
            var gate = WorkGate(deadline: .none)
            let normal = try await engine.solve(method: method, warmStart: .none, gate: &gate)
            #expect(normal.status == .optimal)
            #expect(abs((normal.objectiveValue ?? .nan) - optimum) <= 1e-9, "\(method): \(String(describing: normal.objectiveValue))")
            #expect(normal.iterations <= 10)

            engine.faults.cleanupIterationLimit = 0
            let starved = try await engine.solve(method: method, warmStart: .none, gate: &gate)
            guard case .numericalFailure(let message) = starved.status else {
                Issue.record("\(method): the clean-up should have run out of budget, got \(starved.status)")
                continue
            }
            #expect(message.contains("clean-up"))

            // With the budget back the same engine solves again.
            engine.faults.cleanupIterationLimit = 500
            let recovered = try await engine.solve(method: method, warmStart: .none, gate: &gate)
            #expect(recovered.status == .optimal)
            #expect(abs((recovered.objectiveValue ?? .nan) - optimum) <= 1e-9)
        }
    }
}

/// Rule L7: memory is bounded — the node pool respects the budget; exceeding it degrades
/// (drops bases) and, if still exceeded, stops with `.feasible(stoppedBy: .memoryBudget)`.
@Suite struct L7MemoryBudgetTests {
    @Test func sixteenMegabytesIsEnoughAndIsRespected() async throws {
        let mip = LivenessProblems.mip()
        var context = SolveContext()
        context.memoryBudgetBytes = 16 * 1024 * 1024
        // Generous, and wider still in an instrumented build: what is under test is the
        // budget, and a run that ends on the clock says nothing about it.
        context.timeLimit = 60 * LivenessHarness.instrumentationScale
        let analysis = try await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(mip, context: context)
        #expect(analysis.status == .optimal || analysis.status.stopReason == .memoryBudget, "\(analysis.status)")
        #expect(analysis.status.hasSolution)
    }

    @Test func aBudgetTooSmallForTheTreeStopsWithTheIncumbent() async throws {
        let mip = LivenessProblems.mip()
        var context = SolveContext()
        context.memoryBudgetBytes = 4_096
        let analysis = try await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(mip, context: context)
        #expect(analysis.status.stopReason == .memoryBudget, "\(analysis.status)")
        if analysis.status.hasSolution {
            #expect(analysis.primal != nil && analysis.gap != nil)
        }
        // CP-SAT under the same budget degrades by forgetting clauses and still answers.
        let sat = try await CPSAT().solve(LivenessProblems.smallMIP(), context: context)
        #expect(sat.status == .optimal || sat.status.stopReason == .memoryBudget, "\(sat.status)")
    }
}

/// Rule L8: the cooperative thread pool is never starved — CPU-bound work yields. The
/// specification verifies this by hand on an iPhone 13 (no UI tick later than 20 ms); this is
/// the automated stand-in: a timer task runs alongside solves that occupy every core.
@Suite(.serialized) struct L8PoolStarvationTests {
    @Test func aTimerKeepsTickingWhileEveryCoreSolves() async throws {
        let mip = LivenessProblems.mip()
        let lp = try LivenessProblems.lp()
        let timer = LivenessHarness.timer(interval: 0.005)
        defer { timer.cancel() }
        var context = SolveContext()
        context.timeLimit = 1.5
        _ = try await BranchAndBound().solve(mip, context: context)
        _ = try await Simplex(.primal).solve(lp, context: context)
        _ = try await CPSAT().solve(mip, context: context)
        timer.cancel()
        let lateness = await timer.value
        #expect(lateness.count >= 20, "the timer only ticked \(lateness.count) times")
        let p99 = LivenessHarness.quantile(lateness, 0.99)
        #expect(p99 <= 0.050 * LatencyBounds.scale, "p99 timer lateness \(p99 * 1000) ms")
        #expect((lateness.max() ?? 0) <= 0.250 * LatencyBounds.scale, "max timer lateness \((lateness.max() ?? 0) * 1000) ms")
    }
}

/// Rule L9: a solve that cannot start (no GPU, no memory, unsupported model) fails fast with a
/// thrown `SolverError` or a degraded path; it never waits for a resource.
@Suite struct L9FailFastTests {
    @Test func withoutAGPUTheSolveRunsOnTheCPU() async throws {
        let lp = try NetlibFixtures.load("share2b")
        var context = SolveContext()
        context.metal = .forced
        context.accelerator = MetalAccelerator(device: nil)
        let analysis = try await Simplex(.primal).solve(lp, context: context)
        #expect(analysis.status == .optimal)
        let reference = ReferenceValues.netlib(named: "share2b")!.optimalObjective
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        let mip = try await BranchAndBound().solve(LivenessProblems.smallMIP(), context: context)
        #expect(mip.status == .optimal)
    }

    @Test func anUnsupportedModelThrowsAtOnce() async throws {
        let lp = try NetlibFixtures.load("afiro")   // continuous columns
        let start = DispatchTime.now().uptimeNanoseconds
        await #expect(throws: SolverError.self) { _ = try await CPSAT().solve(lp) }
        await #expect(throws: SolverError.self) { _ = try await CPSAT(lpPropagator: true).solve(lp) }
        #expect(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < 1)
    }

    @Test func noMemoryBudgetStopsInsteadOfWaiting() async throws {
        var context = SolveContext()
        context.memoryBudgetBytes = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let analysis = try await BranchAndBound(heuristics: .none).solve(LivenessProblems.mip(), context: context)
        #expect(analysis.status.stopReason == .memoryBudget || analysis.status == .optimal, "\(analysis.status)")
        #expect(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < 10)
    }
}

/// Rule L10: event delivery is monotone — `.finished` is the last event, delivered exactly
/// once, on every exit path.
@Suite struct L10EventOrderTests {
    func check<S: SolverStrategy>(
        _ strategy: S, _ problem: CompiledLP, context: SolveContext = .init(), expecting: (SolveStatus) -> Bool,
        _ label: String
    ) async {
        let (events, result) = await LivenessHarness.recordEvents(strategy, problem: problem, context: context)
        #expect(LivenessHarness.finishesExactlyOnce(events), "\(label): \(events.filter(\.isFinished).count) .finished event(s), last is \(String(describing: events.last))")
        if case .started = events.first {} else { Issue.record("\(label): the first event is not .started") }
        guard case .success(let analysis) = result else {
            Issue.record("\(label): threw")
            return
        }
        #expect(expecting(analysis.status), "\(label): \(analysis.status)")
        if case .finished(let status, _) = events.last { #expect(status == analysis.status, "\(label)") }
    }

    func cancelled<S: SolverStrategy>(_ strategy: S, _ problem: CompiledLP, _ label: String) async {
        let recorder = EventRecorder()
        let task = Task { try await strategy.solve(problem, context: recorder.context) }
        task.cancel()
        let status = try? await task.value.status
        let events = await recorder.finish()
        #expect(LivenessHarness.finishesExactlyOnce(events), "\(label): cancelled")
        #expect(status == .optimal || status?.stopReason == .cancelled, "\(label): \(String(describing: status))")
    }

    @Test func everyExitPathOfEveryEngine() async throws {
        let lp = try NetlibFixtures.load("share2b")
        let big = try LivenessProblems.lp()
        let mip = LivenessProblems.mip()
        let infeasible = dense(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 3], ru: [1, inf])
        let unbounded = dense(c: [-1, -1], rows: [[1, -1], [-1, 1]], rl: [-inf, -inf], ru: [1, 2])
        let infeasibleMIP = dense(c: [1], rows: [[2]], rl: [3], ru: [3], xu: [10], integer: [0])
        var noTime = SolveContext()
        noTime.timeLimit = 0
        var noMemory = SolveContext()
        noMemory.memoryBudgetBytes = 512

        for method in [Simplex.Method.primal, .dual] {
            let name = "Simplex(\(method))"
            await check(Simplex(method), lp, expecting: { $0 == .optimal }, "\(name) optimal")
            await check(Simplex(method), infeasible, expecting: { $0 == .infeasible }, "\(name) infeasible")
            await check(Simplex(method), unbounded, expecting: { $0 == .unbounded }, "\(name) unbounded")
            await check(Simplex(method, maxIterations: 3), big, expecting: { $0.stopReason == .iterationLimit }, "\(name) iteration limit")
            await check(Simplex(method), big, context: noTime, expecting: { $0.stopReason == .timeLimit }, "\(name) time limit")
            await cancelled(Simplex(method), big, name)
        }

        await check(InteriorPoint(), lp, expecting: { $0 == .optimal }, "IPM optimal")
        await check(InteriorPoint(crossover: .none), lp, expecting: { $0 == .optimal }, "IPM optimal, no crossover")
        await check(InteriorPoint(maxIterations: 2), big, expecting: { $0 == .noSolution(stoppedBy: .iterationLimit) }, "IPM iteration cap")
        await check(InteriorPoint(presolve: false), infeasible, expecting: { !$0.hasSolution }, "IPM infeasible")
        await check(InteriorPoint(), big, context: noTime, expecting: { $0.stopReason == .timeLimit }, "IPM time limit")
        await cancelled(InteriorPoint(), big, "IPM")

        await check(BranchAndBound(), LivenessProblems.smallMIP(), expecting: { $0 == .optimal }, "B&B optimal")
        await check(BranchAndBound(), infeasibleMIP, expecting: { $0 == .infeasible }, "B&B infeasible")
        await check(BranchAndBound(), infeasible, expecting: { $0 == .infeasible }, "B&B infeasible root")
        await check(BranchAndBound(nodeLimit: 2), mip, expecting: { $0.stopReason == .nodeLimit }, "B&B node limit")
        await check(BranchAndBound(), mip, context: noTime, expecting: { $0.stopReason == .timeLimit }, "B&B time limit")
        await check(BranchAndBound(heuristics: .none), mip, context: noMemory, expecting: { $0.stopReason == .memoryBudget }, "B&B memory budget")
        await check(BranchAndBound(engine: InteriorPoint()), LivenessProblems.smallMIP(), expecting: { $0 == .optimal }, "B&B with IPM root")
        await cancelled(BranchAndBound(), mip, "B&B")

        await check(CPSAT(), LivenessProblems.smallMIP(), expecting: { $0 == .optimal }, "CP-SAT optimal")
        await check(CPSAT(), infeasibleMIP, expecting: { $0 == .infeasible }, "CP-SAT infeasible")
        await check(CPSAT(), mip, context: noTime, expecting: { $0.stopReason == .timeLimit }, "CP-SAT time limit")
        await cancelled(CPSAT(), mip, "CP-SAT")

        await check(Automatic(), lp, expecting: { $0 == .optimal }, "Automatic LP")
        await check(Automatic(), LivenessProblems.smallMIP(), expecting: { $0 == .optimal }, "Automatic MIP")
        await check(Conditioned(Simplex(.dual)), lp, expecting: { $0 == .optimal }, "Conditioned")
        await check(Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()]), lp, expecting: { $0 == .optimal }, "Portfolio")
        await cancelled(Portfolio([BranchAndBound(), CPSAT()]), mip, "Portfolio")
        await cancelled(Conditioned(Automatic()), mip, "Conditioned")
    }

    /// A thrown `SolverError` is an exit path too.
    @Test func aThrowingSolveStillFinishesOnce() async throws {
        let lp = try NetlibFixtures.load("afiro")
        for run in 0..<2 {
            let (events, result): ([SolverEvent], Bool)
            if run == 0 {
                let recorded = await LivenessHarness.recordEvents(Portfolio([]), problem: lp)
                (events, result) = (recorded.events, { if case .failure = recorded.result { return true } else { return false } }())
            } else {
                let recorded = await LivenessHarness.recordEvents(CPSAT(), problem: lp)
                (events, result) = (recorded.events, { if case .failure = recorded.result { return true } else { return false } }())
            }
            #expect(result, "run \(run) did not throw")
            #expect(LivenessHarness.finishesExactlyOnce(events), "run \(run): \(events)")
        }
    }
}
