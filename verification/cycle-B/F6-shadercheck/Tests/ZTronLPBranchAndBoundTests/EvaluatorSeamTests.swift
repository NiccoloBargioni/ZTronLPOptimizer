import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

actor EvaluationLog {
    private(set) var batches = 0
    private(set) var points = 0
    func batch(_ count: Int) {
        batches += 1
        points += count
    }
}

/// An honest stand-in for the `batchedActivity` kernel: the same flags, computed in Double.
struct HonestEvaluator: BatchedActivityEvaluating {
    let lp: CompiledLP
    let log: EvaluationLog

    func evaluate(points: [Double], count: Int, tolerance: Double) async -> [Bool]? {
        await log.batch(count)
        return (0..<count).map { k in
            let x = Array(points[(k * lp.n)..<((k + 1) * lp.n)])
            let violation = lp.maxViolation(at: x)
            return violation.bounds <= tolerance && violation.rows <= tolerance * 10
        }
    }
}

/// A kernel that flags every point feasible.
struct FlagEverything: BatchedActivityEvaluating {
    let log: EvaluationLog

    func evaluate(points: [Double], count: Int, tolerance: Double) async -> [Bool]? {
        await log.batch(count)
        return [Bool](repeating: true, count: count)
    }
}

struct EvaluatorProvider: CandidateKernelProvider {
    let honest: Bool
    let log: EvaluationLog

    func reducedCostScanner(for lp: CompiledLP, policy: MetalPolicy) async -> (any ReducedCostScanning)? { nil }

    func activityEvaluator(for lp: CompiledLP, policy: MetalPolicy) async -> (any BatchedActivityEvaluating)? {
        honest ? HonestEvaluator(lp: lp, log: log) : FlagEverything(log: log)
    }
}

/// §6.4 and §9.5: the rounding heuristic may screen a batch of points with the
/// `batchedActivity` kernel, but the CPU re-evaluates every point flagged feasible in Double
/// before it becomes an incumbent, and a kernel that keeps being wrong is disabled.
@Suite struct EvaluatorSeamTests {
    static let problem = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)

    @Test func anHonestKernelScreensRoundingBatches() async throws {
        let reference = try await BranchAndBound(engine: Simplex(.dual)).solve(Self.problem)
        let log = EvaluationLog()
        var context = SolveContext()
        context.metal = .forced
        context.accelerator = EvaluatorProvider(honest: true, log: log)
        let analysis = try await BranchAndBound(engine: Simplex(.dual)).solve(Self.problem, context: context)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - reference.objectiveValue!) <= 1e-6)
        #expect(isIntegralAndFeasible(Self.problem, analysis.primal!))
        #expect(await log.batches > 0)
        // Each batch is the configured size (128 by default), within the 1,024-point cap.
        #expect(await log.points == 128 * (await log.batches))
        #expect(!analysis.warnings.contains { $0.contains("batchedActivity") })
    }

    @Test func aLyingKernelNeverProducesAnIncumbentAndIsDisabled() async throws {
        let reference = try await BranchAndBound(engine: Simplex(.dual)).solve(Self.problem)
        let log = EvaluationLog()
        var context = SolveContext()
        context.metal = .forced
        context.threads = 1
        context.accelerator = EvaluatorProvider(honest: false, log: log)
        let analysis = try await BranchAndBound(engine: Simplex(.dual)).solve(Self.problem, context: context)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - reference.objectiveValue!) <= 1e-6)
        // Whatever the kernel claimed, the incumbent is feasible in Double.
        #expect(isIntegralAndFeasible(Self.problem, analysis.primal!))
        #expect(analysis.warnings.contains { $0.contains("batchedActivity") && $0.contains("disabled") })
    }

    @Test func thePolicyGatesTheKernel() async throws {
        for (policy, used) in [(MetalPolicy.off, false), (.automatic, false), (.forced, true)] {
            let log = EvaluationLog()
            var context = SolveContext()
            context.metal = policy
            context.accelerator = EvaluatorProvider(honest: true, log: log)
            let analysis = try await BranchAndBound().solve(Self.problem, context: context)
            #expect(analysis.status == .optimal)
            // `.automatic` needs a batch of ≥ 64 points and nnz ≥ 100,000; this model is tiny.
            #expect((await log.batches > 0) == used, "\(policy)")
        }
    }
}
