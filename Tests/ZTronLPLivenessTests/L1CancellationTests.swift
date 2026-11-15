import Foundation
import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Problems that keep each engine busy long enough to be interrupted.
enum LivenessProblems {
    /// The largest and most degenerate bundled netlib instance.
    static func lp() throws -> CompiledLP { try NetlibFixtures.load("degen2") }
    /// A binary knapsack-style model whose tree takes thousands of nodes.
    static func mip() -> CompiledLP { InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1) }
    /// A smaller one, for tests that solve it many times.
    static func smallMIP() -> CompiledLP { InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1) }
}

/// The latency bounds of rule L1. The specification's numbers are for an optimized build; an
/// unoptimized one runs each loop iteration several times slower, so its bound is widened by
/// the same factor rather than dropped.
enum LatencyBounds {
    /// A further factor for runs under instrumentation: Thread Sanitizer slows the code by an
    /// order of magnitude, and what that run is for is races, not latency. Set
    /// `ZTRONLP_LATENCY_SCALE` (≥ 1) there; unset, the bounds are the ones below.
    static let scale = LivenessHarness.instrumentationScale

    #if DEBUG
    static var p99: Double { 0.200 * scale }
    static var max: Double { 0.800 * scale }
    /// The latest point of a solve at which a cancellation is placed. Unoptimized solves take
    /// seconds each, and two hundred of them cancelled anywhere in their run take minutes; the
    /// optimized build covers the whole run.
    static let window = 0.6
    #else
    static var p99: Double { 0.050 * scale }
    static var max: Double { 0.200 * scale }
    static let window = Double.infinity
    #endif
}

/// Rule L1: every loop that can run more than ~1 ms calls `gate.tick()`; cancellation is seen
/// within the latency bound. Cancel at random points in 200 solves.
@Suite(.serialized) struct L1CancellationLatencyTests {
    @Test func cancellationLatencyAcrossEngines() async throws {
        let lp = try LivenessProblems.lp()
        let mip = LivenessProblems.mip()

        // How long each solve takes when left alone decides where the random cancellations fall.
        func duration(_ body: () async throws -> Void) async rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try await body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        var limited = SolveContext()
        limited.timeLimit = 3
        let windows: [Double] = [
            try await duration { _ = try await Simplex(.primal).solve(lp) },
            try await duration { _ = try await Simplex(.dual).solve(lp) },
            try await duration { _ = try await InteriorPoint().solve(lp) },
            try await duration { _ = try await BranchAndBound().solve(mip, context: limited) },
            try await duration { _ = try await CPSAT().solve(mip, context: limited) },
        ]

        var rng = SeededGenerator(seed: 2026)
        var latencies: [Double] = []
        var interrupted = 0
        var statuses: [SolveStatus] = []
        for _ in 0..<40 {
            for engine in 0..<5 {
                let delay = rng.uniform(in: 0...min(windows[engine], LatencyBounds.window))
                let sample: LivenessHarness.CancellationSample
                switch engine {
                case 0: sample = await LivenessHarness.cancellationLatency(Simplex(.primal), problem: lp, after: delay)
                case 1: sample = await LivenessHarness.cancellationLatency(Simplex(.dual), problem: lp, after: delay)
                case 2: sample = await LivenessHarness.cancellationLatency(InteriorPoint(), problem: lp, after: delay)
                case 3: sample = await LivenessHarness.cancellationLatency(BranchAndBound(), problem: mip, after: delay)
                default: sample = await LivenessHarness.cancellationLatency(CPSAT(), problem: mip, after: delay)
                }
                latencies.append(sample.latency)
                statuses.append(sample.status)
                if sample.status.stopReason == .cancelled { interrupted += 1 }
            }
        }
        #expect(latencies.count == 200)
        // Cancellation is a result, never an error, and nothing else can come back.
        for status in statuses {
            #expect(status == .optimal || status.stopReason == .cancelled, "unexpected status \(status)")
        }
        // The test only means something if a good share of the solves were really interrupted.
        #expect(interrupted >= 60, "only \(interrupted) of 200 solves were interrupted")
        let p99 = LivenessHarness.quantile(latencies, 0.99)
        let worst = latencies.max() ?? 0
        #expect(p99 <= LatencyBounds.p99, "p99 cancellation latency \(p99 * 1000) ms")
        #expect(worst <= LatencyBounds.max, "max cancellation latency \(worst * 1000) ms")
    }

    /// The same rule for both settings of CP-SAT's LP propagator. With it — the default, and
    /// what the test above runs — a worker's loop also runs the simplex engine, and a
    /// cancellation that lands inside a relaxation is seen there; without it the solve is
    /// the long one, pure CDCL from start to finish.
    @Test(arguments: [true, false])
    func cancellationReachesBothKindsOfCPSATWorker(_ lpPropagator: Bool) async throws {
        let mip = LivenessProblems.mip()
        var limited = SolveContext()
        limited.timeLimit = 3
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await CPSAT(lpPropagator: lpPropagator).solve(mip, context: limited)
        let window = min(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, LatencyBounds.window)
        var rng = SeededGenerator(seed: 77)
        var latencies: [Double] = []
        var interrupted = 0
        for _ in 0..<40 {
            let sample = await LivenessHarness.cancellationLatency(
                CPSAT(lpPropagator: lpPropagator), problem: mip, after: rng.uniform(in: 0...window))
            #expect(sample.status == .optimal || sample.status.stopReason == .cancelled, "unexpected status \(sample.status)")
            latencies.append(sample.latency)
            if sample.status.stopReason == .cancelled { interrupted += 1 }
        }
        #expect(interrupted >= 10, "only \(interrupted) of 40 solves were interrupted")
        let p99 = LivenessHarness.quantile(latencies, 0.99)
        #expect(p99 <= LatencyBounds.p99, "p99 cancellation latency \(p99 * 1000) ms")
        #expect((latencies.max() ?? 0) <= LatencyBounds.max, "max cancellation latency \((latencies.max() ?? 0) * 1000) ms")
    }

    @Test func timeLimitsAreHonouredPromptly() async throws {
        let mip = LivenessProblems.mip()
        var context = SolveContext()
        context.timeLimit = 0.25
        for run in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let status: SolveStatus
            switch run {
            case 0: status = try await BranchAndBound().solve(mip, context: context).status
            case 1: status = try await BranchAndBound(engine: InteriorPoint()).solve(mip, context: context).status
            default: status = try await CPSAT().solve(mip, context: context).status
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            #expect(status == .optimal || status.stopReason == .timeLimit, "\(status)")
            #expect(elapsed <= 0.25 + LatencyBounds.max, "run \(run) took \(elapsed) s against a 0.25 s limit")
        }
    }
}

/// Rule L2: cancellation and time limits return the best available result; they never throw
/// and never leave anything in a state that blocks later callers.
@Suite(.serialized) struct L2ReuseAfterStoppingTests {
    @Test func cancelThenSolveAgainWithTheSameStrategyValue() async throws {
        let lp = try NetlibFixtures.load("israel")
        let mip = LivenessProblems.smallMIP()
        let reference = ReferenceValues.netlib(named: "israel")!.optimalObjective
        let mipReference = try await BranchAndBound(engine: Simplex(.dual)).solve(mip).objectiveValue!
        var rng = SeededGenerator(seed: 7)

        let simplex = Simplex(.dual)
        let interior = InteriorPoint()
        let tree = BranchAndBound()
        let sat = CPSAT()
        let automatic = Automatic()
        for _ in 0..<12 {
            let delay = rng.uniform(in: 0...0.02)
            _ = await LivenessHarness.cancellationLatency(simplex, problem: lp, after: delay)
            _ = await LivenessHarness.cancellationLatency(interior, problem: lp, after: delay)
            _ = await LivenessHarness.cancellationLatency(tree, problem: mip, after: delay)
            _ = await LivenessHarness.cancellationLatency(sat, problem: mip, after: delay)
            _ = await LivenessHarness.cancellationLatency(automatic, problem: mip, after: delay)

            let first = try await simplex.solve(lp)
            #expect(first.status == .optimal)
            #expect(ReferenceValues.relativeError(first.objectiveValue!, reference: reference) <= 1e-6)
            let second = try await interior.solve(lp)
            #expect(second.status == .optimal)
            #expect(ReferenceValues.relativeError(second.objectiveValue!, reference: reference) <= 1e-6)
            let third = try await tree.solve(mip)
            #expect(third.status == .optimal && abs(third.objectiveValue! - mipReference) <= 1e-6)
            let fourth = try await sat.solve(mip)
            #expect(fourth.status == .optimal && abs(fourth.objectiveValue! - mipReference) <= 1e-6)
            let fifth = try await automatic.solve(mip)
            #expect(fifth.status == .optimal && abs(fifth.objectiveValue! - mipReference) <= 1e-6)
        }
    }

    @Test func concurrentSolvesOnOneStrategyValue() async throws {
        // §11.4: concurrent solve calls on the same value are allowed and each run allocates
        // its own workers.
        let mip = LivenessProblems.smallMIP()
        let strategy = BranchAndBound(engine: Simplex(.dual))
        let reference = try await strategy.solve(mip).objectiveValue!
        let objectives = try await withThrowingTaskGroup(of: Double?.self) { group -> [Double?] in
            for _ in 0..<8 {
                group.addTask { try await strategy.solve(mip).objectiveValue }
            }
            var all: [Double?] = []
            for try await value in group { all.append(value) }
            return all
        }
        #expect(objectives.count == 8)
        for value in objectives { #expect(abs((value ?? .nan) - reference) <= 1e-6) }
    }
}
