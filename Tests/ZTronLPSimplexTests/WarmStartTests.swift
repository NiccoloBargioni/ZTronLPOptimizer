import Testing
import ZTronLPCore
import ZTronLPNumerics
@testable import ZTronLPSimplex
import ZTronLPTestSupport

/// §14.2: each warm-start strategy reduces iterations vs a cold start on a modified netlib
/// instance (§7.4).
@Suite struct WarmStartTests {
    /// The instance with its costs nudged: the old optimal basis stays primal feasible and
    /// nearly optimal.
    static func perturbedCosts(_ lp: CompiledLP, seed: UInt64) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        let c = lp.c.map { $0 * (1 + 0.02 * (rng.uniform() - 0.5)) }
        return CompiledLP(
            a: lp.a, c: c, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu, rl: lp.rl, ru: lp.ru,
            integerColumns: lp.integerColumns, names: lp.names, transpose: lp.aT)
    }

    /// The instance with its finite right-hand sides nudged: the old basis stays dual feasible.
    static func perturbedRightHandSides(_ lp: CompiledLP, seed: UInt64) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        var rl = lp.rl
        var ru = lp.ru
        for i in 0..<lp.m {
            let factor = 1 + 0.01 * (rng.uniform() - 0.5)
            if rl[i] == ru[i] {
                rl[i] *= factor
                ru[i] = rl[i]
            } else {
                if rl[i].isFinite { rl[i] *= rl[i] > 0 ? (2 - factor) : factor }
                if ru[i].isFinite { ru[i] *= ru[i] > 0 ? factor : (2 - factor) }
            }
        }
        return lp.withRowBounds(rl: rl, ru: ru)
    }

    static let instances = ["share2b", "scagr7", "israel", "beaconfd"]

    @Test(arguments: instances)
    func basisWarmStartAfterEditingCosts(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let first = try await Simplex(.primal).solve(lp)
        let edited = Self.perturbedCosts(lp, seed: 5)
        let cold = try await Simplex(.primal).solve(edited)
        var context = SolveContext()
        context.warmStart = .basis(first.basis)
        let warm = try await Simplex(.primal).solve(edited, context: context)
        #expect(cold.status == .optimal && warm.status == .optimal)
        #expect(abs(cold.objectiveValue! - warm.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
        #expect(warm.iterations < cold.iterations, "\(name): warm \(warm.iterations) vs cold \(cold.iterations)")
    }

    @Test(arguments: instances)
    func basisWarmStartAfterEditingRightHandSides(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let first = try await Simplex(.dual).solve(lp)
        let edited = Self.perturbedRightHandSides(lp, seed: 9)
        let cold = try await Simplex(.dual).solve(edited)
        guard cold.status == .optimal else { return }   // the nudge made this one infeasible
        var context = SolveContext()
        context.warmStart = .basis(first.basis)
        let warm = try await Simplex(.dual).solve(edited, context: context)
        #expect(warm.status == .optimal)
        #expect(abs(cold.objectiveValue! - warm.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
        #expect(warm.iterations < cold.iterations, "\(name): warm \(warm.iterations) vs cold \(cold.iterations)")
    }

    @Test(arguments: instances, bothMethods)
    func incrementalWarmStartAfterABoundChange(_ name: String, _ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load(name)
        let first = try await Simplex(method).solve(lp)
        let x = try #require(first.primal)
        // Branch-style change: cut the largest basic structural value in half.
        var target = 0
        for j in 0..<lp.n where x[j] - lp.xl[j] > x[target] - lp.xl[target] { target = j }
        let change = BoundChange(column: Int32(target), lower: lp.xl[target], upper: lp.xl[target] + 0.5 * (x[target] - lp.xl[target]))
        let cold = try await Simplex(method).solve(lp.applying([change]))
        var context = SolveContext()
        context.warmStart = .incremental(parent: first.basis, changes: [change])
        let warm = try await Simplex(method).solve(lp, context: context)
        #expect(cold.status == warm.status)
        if cold.status == .optimal {
            #expect(abs(cold.objectiveValue! - warm.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
            #expect(warm.iterations < cold.iterations, "\(name) \(method): warm \(warm.iterations) vs cold \(cold.iterations)")
            #expect(warm.primal![target] <= change.upper + 1e-7)
        }
    }

    @Test(arguments: instances)
    func primalPointWarmStart(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let cold = try await Simplex(.primal).solve(lp)
        // A point near the optimum, pulled slightly into the interior, as an interior-point
        // method would deliver it.
        var point = try #require(cold.primal)
        for j in 0..<lp.n {
            let lo = lp.xl[j]
            if point[j] <= lo + 1e-9 { point[j] = lo + 1e-7 }
        }
        var context = SolveContext()
        context.warmStart = .primalPoint(point)
        let warm = try await Simplex(.primal).solve(lp, context: context)
        #expect(warm.status == .optimal)
        #expect(abs(cold.objectiveValue! - warm.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
        #expect(warm.iterations < cold.iterations, "\(name): warm \(warm.iterations) vs cold \(cold.iterations)")
    }

    @Test(arguments: ["sc105", "scagr7", "stocfor1", "share2b", "afiro"])
    func triangularCrashStillSolves(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let cold = try await Simplex(.primal).solve(lp)
        var context = SolveContext()
        context.warmStart = .crash(.triangular)
        let crashed = try await Simplex(.primal).solve(lp, context: context)
        #expect(crashed.status == .optimal)
        #expect(abs(cold.objectiveValue! - crashed.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
    }

    @Test func triangularCrashCutsPhase1OnAStructuredModel() async throws {
        // A staircase model: each stage's balance row ties it to the previous stage. The
        // all-logical basis is infeasible on every row; the crash basis is triangular.
        let stages = 60
        var entries: [(row: Int, col: Int, value: Double)] = []
        for t in 0..<stages {
            entries.append((t, t, 1))                 // production
            if t > 0 { entries.append((t, stages + t - 1, 1)) }   // inventory in
            entries.append((t, stages + t, -1))       // inventory out
        }
        let n = 2 * stages
        var rng = SeededGenerator(seed: 3)
        let demand = (0..<stages).map { _ in 5 + (rng.uniform() * 10).rounded() }
        let c = (0..<n).map { $0 < stages ? 1 + Double($0 % 7) : 0.5 }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: stages, cols: n, entries), c: c,
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n), rl: demand, ru: demand)
        let cold = try await Simplex(.primal, presolve: false).solve(lp)
        var context = SolveContext()
        context.warmStart = .crash(.triangular)
        let crashed = try await Simplex(.primal, presolve: false).solve(lp, context: context)
        #expect(cold.status == .optimal && crashed.status == .optimal)
        #expect(abs(cold.objectiveValue! - crashed.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
        #expect(crashed.phase1Iterations < cold.phase1Iterations, "crash \(crashed.phase1Iterations) vs cold \(cold.phase1Iterations)")
    }

    @Test func aBasisThatDoesNotFitIsIgnoredWithAWarning() async throws {
        let lp = try NetlibFixtures.load("afiro")
        var context = SolveContext()
        context.warmStart = .basis(Basis(status: [.basic, .atLower], basic: [0]))
        let analysis = try await Simplex(.dual).solve(lp, context: context)
        #expect(analysis.status == .optimal)
        #expect(analysis.warnings.contains { $0.contains("does not fit") })
    }

    @Test func aSingularWarmBasisIsRepaired() async throws {
        let lp = try NetlibFixtures.load("afiro")
        // Mark every structural column basic: far too many, and singular once truncated.
        var status = [BasisStatus](repeating: .basic, count: lp.n + lp.m)
        for i in 0..<lp.m { status[lp.n + i] = .atLower }
        var context = SolveContext()
        context.warmStart = .basis(Basis(status: status, basic: (0..<lp.m).map { Int32($0) }))
        for method in bothMethods {
            let analysis = try await Simplex(method, presolve: false).solve(lp, context: context)
            #expect(analysis.status == .optimal)
            let reference = ReferenceValues.netlib(named: "afiro")!.optimalObjective
            #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        }
    }
}

@Suite struct SimplexEngineTests {
    @Test func engineHotPathKeepsTheFactorization() async throws {
        let lp = try NetlibFixtures.load("share2b")
        let strategy = Simplex(.dual)
        var engine = strategy.makeEngine(for: lp, context: SolveContext())
        var gate = WorkGate(deadline: .none)
        let root = try await engine.solve(method: .dual, warmStart: .none, gate: &gate)
        #expect(root.status == .optimal)
        let x = try #require(root.primal)
        var target = 0
        for j in 0..<lp.n where x[j] > x[target] { target = j }
        let change = BoundChange(column: Int32(target), lower: 0, upper: 0.5 * x[target])
        let child = try await engine.run(
            method: .dual, warmStart: .incremental(parent: root.basis, changes: [change]), cutoff: nil,
            iterationLimit: nil, gate: &gate)
        #expect(child.status == .optimal)
        // The parent's basis was still in the engine: no refactorization was needed to start.
        #expect(child.refactorizations <= 1)
        #expect(child.objective >= root.objectiveValue! - 1e-7 * (1 + abs(root.objectiveValue!)))
        #expect(child.x[target] <= change.upper + 1e-7)

        // A cutoff below the child's optimum stops the dual method early.
        let cut = try await engine.run(
            method: .dual, warmStart: .incremental(parent: root.basis, changes: [change]),
            cutoff: root.objectiveValue! + 1e-9 * abs(root.objectiveValue!), iterationLimit: nil, gate: &gate)
        if child.objective > root.objectiveValue! + 1e-6 * abs(root.objectiveValue!) {
            #expect(cut.status == .cutoff)
            #expect(cut.iterations <= child.iterations)
        }

        // Back at the root's bounds the root optimum is recovered.
        let again = try await engine.run(
            method: .dual, warmStart: .incremental(parent: root.basis, changes: []), cutoff: nil,
            iterationLimit: nil, gate: &gate)
        #expect(again.status == .optimal)
        #expect(abs(again.objective - root.objectiveValue!) <= 1e-7 * (1 + abs(root.objectiveValue!)))
    }

    @Test func iterationLimitOnTheEngineReturnsLimit() async throws {
        let lp = try NetlibFixtures.load("israel")
        var engine = Simplex(.primal).makeEngine(for: lp, context: SolveContext())
        var gate = WorkGate(deadline: .none)
        let outcome = try await engine.run(method: .primal, warmStart: .none, cutoff: nil, iterationLimit: 10, gate: &gate)
        #expect(outcome.status == .iterationLimit)
        #expect(outcome.iterations == 10)
    }

    /// Rule L6: at most three consecutive residual failures, then `.numericalFailure` — never
    /// a retry loop.
    @Test(arguments: bothMethods)
    func threeResidualFailuresEndTheSolve(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("share2b")
        var engine = Simplex(method).makeEngine(for: lp, context: SolveContext())
        engine.faults.failingResidualChecks = 1_000
        var gate = WorkGate(deadline: .none)
        let analysis = try await engine.solve(method: method, warmStart: .none, gate: &gate)
        guard case .numericalFailure(let message) = analysis.status else {
            Issue.record("expected a numerical failure, got \(analysis.status)")
            return
        }
        #expect(message.contains("residual"))

        // Two failures are survivable: the engine refactors and carries on.
        var second = Simplex(method).makeEngine(for: lp, context: SolveContext())
        second.faults.failingResidualChecks = 2
        let recovered = try await second.solve(method: method, warmStart: .none, gate: &gate)
        #expect(recovered.status == .optimal)
    }

    @Test(arguments: bothMethods)
    func cancellationIsAResultAndTheStrategyIsReusable(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("degen2")
        let strategy = Simplex(method)
        let task = Task { try await strategy.solve(lp) }
        task.cancel()
        let cancelled = try await task.value
        #expect(cancelled.status.stopReason == .cancelled)
        // Rule L2: cancel, then solve again with the same strategy value.
        let again = try await strategy.solve(lp)
        #expect(again.status == .optimal)
    }

    @Test(arguments: bothMethods)
    func timeLimitIsAResult(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("degen2")
        var context = SolveContext()
        context.timeLimit = 0
        let analysis = try await Simplex(method).solve(lp, context: context)
        #expect(analysis.status.stopReason == .timeLimit)
    }

    /// Rule L10: `.finished` is the last event, delivered exactly once.
    @Test(arguments: bothMethods)
    func eventsAreOrderedAndFinishOnce(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("degen2")
        var context = SolveContext()
        let stream = context.makeEventStream()
        let analysis = try await Simplex(method).solve(lp, context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        #expect(analysis.status == .optimal)
        guard case .started(let engine, let rows, let columns, _) = events.first else {
            Issue.record("the first event is not .started")
            return
        }
        #expect(engine.hasPrefix("Simplex") && rows == lp.m && columns == lp.n)
        #expect(events.filter(\.isFinished).count == 1)
        #expect(events.last == .finished(status: .optimal, seconds: analysis.seconds))
        #expect(events.contains { if case .presolved = $0 { return true } else { return false } })
        // Iterations are reported at most every 100.
        let reported = events.compactMap { event -> Int? in
            if case .simplexIteration(let iteration, _, _, _) = event { return iteration }
            return nil
        }
        #expect(!reported.isEmpty && reported.allSatisfy { $0 % 100 == 0 })
        #expect(reported == reported.sorted())
    }
}
