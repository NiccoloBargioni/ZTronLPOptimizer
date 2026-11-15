// Contracts every strategy keeps (specification §11.4) and the concurrency and liveness rules
// of §12 as they apply to CP-SAT: cancellation and limits are results, never errors; a
// strategy value can be solved again after a cancelled run and concurrently with itself;
// `.finished` is the last event, exactly once, on every exit path (L10); `deterministic: true`
// gives identical results and identical event sequences (C9); learned clauses respect the
// memory budget (L7); a solve that cannot start fails fast (L9).

import Foundation
import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

@Suite struct LivenessTests {
    // MARK: C9 — determinism

    /// Twenty runs of one worker with a fixed seed: the same analysis, counter for counter,
    /// and the same events in the same order.
    @Test func deterministicModeIsReproducible() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 5, columns: 22, seed: 4)
        var reference: (analysis: CPSATAnalysis, events: [SolverEvent])? = nil
        for run in 0..<20 {
            let recorder = EventRecorder()
            var context = SolveContext()
            context.progress = recorder.callback
            let analysis = try await CPSAT(seed: 42, deterministic: true).solve(lp, context: context)
            let events = normalized(await recorder.finish())
            #expect(eventContractHolds(events))
            if let reference {
                #expect(analysis.status == reference.analysis.status, "run \(run)")
                #expect(analysis.objectiveValue == reference.analysis.objectiveValue, "run \(run)")
                #expect(analysis.bound == reference.analysis.bound, "run \(run)")
                #expect(analysis.primal == reference.analysis.primal, "run \(run)")
                #expect(analysis.conflicts == reference.analysis.conflicts, "run \(run)")
                #expect(analysis.decisions == reference.analysis.decisions, "run \(run)")
                #expect(analysis.propagations == reference.analysis.propagations, "run \(run)")
                #expect(analysis.restarts == reference.analysis.restarts, "run \(run)")
                #expect(analysis.learnedClauses == reference.analysis.learnedClauses, "run \(run)")
                #expect(events == reference.events, "run \(run): the event sequence differs")
            } else {
                #expect(analysis.status == .optimal)
                #expect(analysis.workers == 1 && analysis.winningWorker == 0)
                #expect(events.contains { if case .newIncumbent = $0 { return true } else { return false } })
                reference = (analysis, events)
            }
        }
    }

    /// `deterministic` overrides the worker count; a different seed is a different, equally valid run.
    @Test func deterministicModeUsesOneWorkerWhateverIsAsked() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 4, columns: 16, seed: 9)
        var context = SolveContext()
        context.threads = 8
        let analysis = try await CPSAT(workers: 6, deterministic: true).solve(lp, context: context)
        #expect(analysis.workers == 1)
        let other = try await CPSAT(seed: 7, deterministic: true).solve(lp)
        #expect(other.objectiveValue == analysis.objectiveValue)
    }

    @Test func workerCountFollowsTheContextUnlessGiven() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 3, columns: 12, seed: 2)
        var context = SolveContext()
        context.threads = 3
        #expect(try await CPSAT().solve(lp, context: context).workers == 3)
        #expect(try await CPSAT(workers: 2).solve(lp, context: context).workers == 2)
        #expect(try await CPSAT(workers: 0).solve(lp, context: context).workers == 1)
    }

    // MARK: L10 — events

    @Test func finishedIsTheLastEventExactlyOnceOnEveryExitPath() async throws {
        func events(_ lp: CompiledLP, strategy: CPSAT, configure: (inout SolveContext) -> Void = { _ in }) async throws -> (SolveStatus, [SolverEvent]) {
            let recorder = EventRecorder()
            var context = SolveContext()
            context.progress = recorder.callback
            configure(&context)
            let analysis = try await strategy.solve(lp, context: context)
            return (analysis.status, await recorder.finish())
        }
        func check(_ result: (SolveStatus, [SolverEvent]), _ label: String) {
            #expect(eventContractHolds(result.1), "\(label): \(result.1)")
            if case .finished(let status, let seconds)? = result.1.last {
                #expect(status == result.0, "\(label): the finished event and the analysis disagree")
                #expect(seconds >= 0)
            }
            if case .started(let engine, _, _, _)? = result.1.first { #expect(engine == "CPSAT") }
        }
        // Optimal, single worker and portfolio.
        let knapsack = InstanceGenerator.randomMILP(rows: 4, columns: 16, seed: 1)
        let optimal = try await events(knapsack, strategy: CPSAT(deterministic: true))
        #expect(optimal.0 == .optimal)
        check(optimal, "optimal")
        check(try await events(knapsack, strategy: CPSAT(workers: 4)), "optimal, portfolio")
        // Infeasible by search, and infeasible at load.
        let refuted = try await events(pigeonhole(holes: 4), strategy: CPSAT(workers: 2))
        #expect(refuted.0 == .infeasible)
        check(refuted, "infeasible")
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1), (0, 1, 1)])
        let impossible = CompiledLP(a: a, c: [0, 0], xl: [0, 0], xu: [1, 1], rl: [5], ru: [.infinity], integerColumns: [0, 1])
        check(try await events(impossible, strategy: CPSAT()), "infeasible at load")
        // A satisfiability problem.
        check(try await events(CNFFormula.random3SAT(variables: 30, clauses: 100, seed: 3).compiled(), strategy: CPSAT(workers: 3)), "satisfiable")
        // Time limit, with and without an incumbent.
        let limited = try await events(slowKnapsack(), strategy: CPSAT(workers: 2)) { $0.timeLimit = 0.4 }
        #expect(limited.0 == .feasible(stoppedBy: .timeLimit))
        check(limited, "time limit with an incumbent")
        let stuck = try await events(pigeonhole(holes: 12), strategy: CPSAT(workers: 2)) { $0.timeLimit = 0.15 }
        #expect(stuck.0 == .noSolution(stoppedBy: .timeLimit))
        check(stuck, "time limit without an incumbent")
        // Memory budget.
        let starved = try await events(knapsack, strategy: CPSAT(workers: 2)) { $0.memoryBudgetBytes = 1 }
        #expect(starved.0 == .noSolution(stoppedBy: .memoryBudget))
        check(starved, "memory budget")
        // Cancellation.
        let recorder = EventRecorder()
        var context = SolveContext()
        context.progress = recorder.callback
        let hard = pigeonhole(holes: 12)
        let cancelledContext = context
        let task = Task { try await CPSAT(workers: 3).solve(hard, context: cancelledContext) }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        let cancelled = try await task.value
        #expect(cancelled.status == .noSolution(stoppedBy: .cancelled))
        check((cancelled.status, await recorder.finish()), "cancelled")
    }

    /// Incumbent events improve monotonically and the last one is the reported objective.
    @Test func incumbentEventsImproveMonotonically() async throws {
        for workers in [1, 4] {
            let recorder = EventRecorder()
            var context = SolveContext()
            context.progress = recorder.callback
            let lp = InstanceGenerator.randomMILP(rows: 5, columns: 24, seed: 11)     // a maximization
            let analysis = try await CPSAT(workers: workers).solve(lp, context: context)
            let incumbents = await recorder.finish().compactMap { event -> Double? in
                if case .newIncumbent(let objective, _, let source) = event {
                    #expect(source.hasPrefix("cpsat["))
                    return objective
                }
                return nil
            }
            #expect(!incumbents.isEmpty)
            for (previous, next) in zip(incumbents, incumbents.dropFirst()) {
                #expect(next > previous, "workers \(workers): \(incumbents)")
            }
            #expect(incumbents.last == analysis.objectiveValue)
        }
    }

    // MARK: §11.4 — limits and cancellation are results

    @Test func timeLimitReturnsTheBestIncumbent() async throws {
        let lp = slowKnapsack()
        var context = SolveContext()
        context.timeLimit = 0.4
        let started = Date()
        let analysis = try await CPSAT(workers: 4).solve(lp, context: context)
        let elapsed = Date().timeIntervalSince(started)
        #expect(analysis.status == .feasible(stoppedBy: .timeLimit))
        #expect(analysis.status.hasSolution && !analysis.status.isOptimal)
        #expect(elapsed >= 0.4 && elapsed < 3, "a 0.4 s limit ended the solve after \(elapsed) s")
        // The incumbent is a feasible integer point with the reported value.
        let primal = try #require(analysis.primal)
        let violation = lp.maxViolation(at: primal)
        #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
        let objective = try #require(analysis.objectiveValue)
        #expect(abs(lp.objective(at: primal) - objective) <= 1e-9 * max(1, abs(objective)))
        // The bound is the propagated bound of the objective row: valid, on the right side of
        // the incumbent for a maximization, and not claimed to be tight.
        let bound = try #require(analysis.bound)
        #expect(bound >= objective)
    }

    @Test func timeLimitWithoutAnIncumbentIsNoSolution() async throws {
        var context = SolveContext()
        // Long enough for the search to get under way, also in an instrumented build.
        context.timeLimit = 0.1 * LivenessHarness.instrumentationScale
        // With and without the LP propagator: its relaxation of the pigeonhole — the rows
        // "at most one pigeon per hole" — proves nothing, and the worker backs off from it.
        for strategy in [CPSAT(deterministic: true), CPSAT(lpPropagator: false, deterministic: true)] {
            let analysis = try await strategy.solve(pigeonhole(holes: 12), context: context)
            #expect(analysis.status == .noSolution(stoppedBy: .timeLimit))
            #expect(analysis.primal == nil && analysis.objectiveValue == nil)
            // The search was under way when the limit came.
            #expect(analysis.decisions > 0)
            if !strategy.lpPropagator { #expect(analysis.conflicts > 0) }
        }
    }

    /// L2: cancel, then solve again with the same strategy value. Nothing is left behind that
    /// could block or mislead the second run.
    @Test func cancelThenSolveAgainWithTheSameStrategy() async throws {
        let strategy = CPSAT(workers: 4)
        let hard = pigeonhole(holes: 12)
        let easy = InstanceGenerator.randomMILP(rows: 4, columns: 16, seed: 5)
        let expected = try await CPSAT(deterministic: true).solve(easy).objectiveValue
        var latencies: [Double] = []
        for round in 0..<8 {
            let task = Task { try await strategy.solve(hard) }
            // Cancel at a different point of the search each round.
            try await Task.sleep(nanoseconds: UInt64(5_000_000 + 12_000_000 * round))
            let cancelledAt = Date()
            task.cancel()
            let cancelled = try await task.value
            latencies.append(Date().timeIntervalSince(cancelledAt))
            #expect(cancelled.status == .noSolution(stoppedBy: .cancelled), "round \(round): \(cancelled.status)")
            let again = try await strategy.solve(easy)
            #expect(again.status == .optimal, "round \(round)")
            #expect(again.objectiveValue == expected, "round \(round)")
        }
        let worst = latencies.max() ?? 0
        print("CP-SAT cancellation latency over \(latencies.count) cancellations: max \(String(format: "%.1f", worst * 1e3)) ms")
        // §12.2 asks for p99 ≤ 50 ms and max ≤ 200 ms; that is measured by the liveness suite on
        // a quiet machine. Here the bound only has to catch a solver that does not stop.
        #expect(worst < 1.0)
    }

    /// Cancelling a run that already has an incumbent returns that incumbent.
    @Test func cancellationKeepsTheIncumbent() async throws {
        let lp = slowKnapsack(seed: 21)
        var context = SolveContext()
        let events = context.makeEventStream()
        let solveContext = context
        let task = Task { try await CPSAT(workers: 2).solve(lp, context: solveContext) }
        // Cancel as soon as the first incumbent is announced, however long that takes.
        for await event in events {
            if case .newIncumbent = event { break }
            if event.isFinished { break }
        }
        task.cancel()
        let analysis = try await task.value
        #expect(analysis.status == .feasible(stoppedBy: .cancelled))
        let primal = try #require(analysis.primal)
        let violation = lp.maxViolation(at: primal)
        #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
    }

    /// A task that is already cancelled gets an answer at once, not an error.
    @Test func solvingInACancelledTaskReturnsImmediately() async throws {
        let task = Task { () -> CPSATAnalysis in
            // Wait for the cancellation, then solve inside the cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return try await CPSAT(workers: 2).solve(pigeonhole(holes: 12))
        }
        task.cancel()
        let started = Date()
        let analysis = try await task.value
        #expect(analysis.status == .noSolution(stoppedBy: .cancelled))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// A strategy value is immutable: concurrent solves on the same value are allowed and each
    /// run allocates its own workers.
    @Test func concurrentSolvesOnOneStrategyValue() async throws {
        let strategy = CPSAT(workers: 2)
        let problems = (0..<8).map { InstanceGenerator.randomMILP(rows: 4, columns: 16, seed: UInt64(100 + $0)) }
        var expected: [Double?] = []
        for lp in problems { expected.append(try await CPSAT(deterministic: true).solve(lp).objectiveValue) }
        let results = try await withThrowingTaskGroup(of: (Int, Double?).self) { group -> [Double?] in
            for (index, lp) in problems.enumerated() {
                group.addTask { (index, try await strategy.solve(lp).objectiveValue) }
            }
            var collected = [Double?](repeating: nil, count: problems.count)
            for try await (index, objective) in group { collected[index] = objective }
            return collected
        }
        #expect(results == expected)
    }

    // MARK: L7, L9 — memory

    /// A budget the model itself does not fit fails fast with a status, not a hang or a crash.
    @Test func aBudgetTooSmallForTheModelStopsAtOnce() async throws {
        var context = SolveContext()
        context.memoryBudgetBytes = 1
        let started = Date()
        let analysis = try await CPSAT(workers: 4).solve(pigeonhole(holes: 12), context: context)
        #expect(analysis.status == .noSolution(stoppedBy: .memoryBudget))
        #expect(analysis.conflicts == 0)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// With a tight allowance the worker forgets learned clauses and keeps going: the answer
    /// is still right, and the database was reduced on the way.
    @Test func aTightBudgetForgetsClausesAndStillAnswers() async throws {
        let lp = pigeonhole(holes: 7)
        let model = try CPModel(lp)
        var probe = CPWorker(model: model, options: WorkerOptions())
        _ = probe.propagate()
        let baseline = probe.approximateBytes
        // Room for the model and for a few hundred learned clauses, no more.
        var context = SolveContext()
        context.memoryBudgetBytes = model.approximateBytes + baseline + 48_000
        let result = try await CPSAT(deterministic: true).run(lp, context: context, recordLearnedClauses: false)
        #expect(result.analysis.status == .infeasible)
        let report = try #require(result.reports.first)
        #expect(report.reductions > 0, "the search never had to forget a clause: \(report.learnedClauses) learned")
        // An unlimited run gives the same verdict.
        #expect(try await CPSAT(deterministic: true).solve(lp).status == .infeasible)
    }

    /// When forgetting everything is still not enough, the solve stops with `.memoryBudget`
    /// and keeps whatever incumbent it has.
    @Test func exhaustingTheBudgetStopsWithTheIncumbent() async throws {
        let lp = slowKnapsack(seed: 33)
        let model = try CPModel(lp)
        var probe = CPWorker(model: model, options: WorkerOptions())
        _ = probe.propagate()
        var context = SolveContext()
        // Exactly the model and the worker's initial state: the first learned clauses, or the
        // trail of the first dive, push the worker over and nothing can be forgotten.
        context.memoryBudgetBytes = model.approximateBytes + probe.approximateBytes
        context.timeLimit = 20
        let analysis = try await CPSAT(deterministic: true).solve(lp, context: context)
        #expect(analysis.status.stopReason == .memoryBudget, "\(analysis.status)")
        if analysis.status.hasSolution {
            let violation = lp.maxViolation(at: try #require(analysis.primal))
            #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
        }
    }

    // MARK: L3 — termination

    /// Every restart is bounded by its conflict limit and the objective bound only decreases,
    /// so the search ends; with `.never` it ends too, by exhausting the tree.
    @Test func searchTerminatesUnderEveryRestartPolicy() async throws {
        let lp = pigeonhole(holes: 5)
        for policy in [RestartPolicy.luby(unit: 100), .luby(unit: 1), .geometric(first: 10, factor: 2), .never] {
            let analysis = try await CPSAT(restarts: policy, deterministic: true).solve(lp)
            #expect(analysis.status == .infeasible, "\(policy)")
        }
    }
}
