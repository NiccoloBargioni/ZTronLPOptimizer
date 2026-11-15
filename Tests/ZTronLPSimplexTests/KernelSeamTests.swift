import Testing
import ZTronLPCore
import ZTronLPNumerics
@testable import ZTronLPSimplex
import ZTronLPTestSupport

/// Counts what a stub kernel was asked.
actor ScanLog {
    private(set) var scans = 0
    private(set) var requests = 0
    func scanned() { scans += 1 }
    func requested() { requests += 1 }
}

/// An honest stand-in for the `reducedCostScan` kernel: the same candidates the GPU would
/// produce, computed in Double.
struct HonestScanner: ReducedCostScanning {
    let lp: CompiledLP
    let log: ScanLog

    func scan(costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int) async -> [Int32]? {
        await log.scanned()
        var scored: [(Double, Int32)] = []
        for j in 0..<lp.n where eligibility[j] != PricingEligibility.none {
            let d = costs[j] - lp.a.dot(column: j, duals)
            let attractive: Bool
            switch eligibility[j] {
            case PricingEligibility.increase: attractive = d < 0
            case PricingEligibility.decrease: attractive = d > 0
            default: attractive = d != 0
            }
            if attractive { scored.append((d * d / weights[j], Int32(j))) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.prefix(limit).map(\.1)
    }
}

/// A kernel that lies: it always proposes the same columns, whatever their reduced costs.
struct LyingScanner: ReducedCostScanning {
    let log: ScanLog

    func scan(costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int) async -> [Int32]? {
        await log.scanned()
        return (0..<Swift.min(limit, costs.count)).map { Int32($0) }
    }
}

struct StubProvider: CandidateKernelProvider {
    let honest: Bool
    let log: ScanLog

    func reducedCostScanner(for lp: CompiledLP, policy: MetalPolicy) async -> (any ReducedCostScanning)? {
        await log.requested()
        return honest ? HonestScanner(lp: lp, log: log) : LyingScanner(log: log)
    }

    func activityEvaluator(for lp: CompiledLP, policy: MetalPolicy) async -> (any BatchedActivityEvaluating)? { nil }
}

/// §6.4: the engine uses a candidate kernel only as a proposal, verifies every candidate in
/// Double, and disables a kernel that disagrees with verification on more than 5% of them.
@Suite struct KernelSeamTests {
    @Test(arguments: ["share2b", "israel", "scagr7"])
    func anHonestKernelLeadsToTheSameOptimum(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let log = ScanLog()
        var context = SolveContext()
        context.metal = .forced
        context.accelerator = StubProvider(honest: true, log: log)
        let analysis = try await Simplex(.primal).solve(lp, context: context)
        #expect(analysis.status == .optimal)
        let reference = ReferenceValues.netlib(named: name)!.optimalObjective
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        #expect(await log.requests == 1)
        #expect(await log.scans > 0)
        #expect(!analysis.warnings.contains { $0.contains("reducedCostScan") })
    }

    @Test func aLyingKernelIsDisabledAndTheSolveIsStillRight() async throws {
        let lp = try NetlibFixtures.load("share2b")
        let log = ScanLog()
        var context = SolveContext()
        context.metal = .forced
        context.accelerator = StubProvider(honest: false, log: log)
        let analysis = try await Simplex(.primal).solve(lp, context: context)
        #expect(analysis.status == .optimal)
        let reference = ReferenceValues.netlib(named: "share2b")!.optimalObjective
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
        #expect(analysis.warnings.contains { $0.contains("reducedCostScan") && $0.contains("disabled") })
        // Once disabled it is not asked again: far fewer scans than iterations.
        #expect(await log.scans < analysis.iterations)
    }

    @Test func thePolicyGatesTheKernel() async throws {
        let lp = try NetlibFixtures.load("afiro")
        for (policy, expected) in [(MetalPolicy.off, 0), (.automatic, 0), (.forced, 1)] {
            let log = ScanLog()
            var context = SolveContext()
            context.metal = policy
            context.accelerator = StubProvider(honest: true, log: log)
            let analysis = try await Simplex(.primal).solve(lp, context: context)
            #expect(analysis.status == .optimal)
            // `.automatic` stays on the CPU below n ≥ 50,000 and nnz ≥ 500,000.
            #expect(await log.requests == expected, "\(policy)")
        }
    }

    /// §7.5: pricing and pivot-row products over column blocks in a task group, each child
    /// producing its own slice. The thresholds are lowered so a small problem takes the path.
    @Test(arguments: bothMethods)
    func parallelPricingGivesTheSameAnswer(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("israel")
        let strategy = Simplex(method, presolve: false)
        var serial = strategy.makeEngine(for: lp, context: SolveContext())
        var gate = WorkGate(deadline: .none)
        let reference = try await serial.solve(method: method, warmStart: .none, gate: &gate)

        var context = SolveContext()
        context.threads = 4
        var parallel = strategy.makeEngine(for: lp, context: context)
        let budget = ConcurrencyBudget(threads: 4)
        parallel.budget = budget
        parallel.parallelColumns = 1
        parallel.parallelNonzeros = 1
        let analysis = try await parallel.solve(method: method, warmStart: .none, gate: &gate)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - reference.objectiveValue!) <= 1e-9 * max(1, abs(reference.objectiveValue!)))
        // Same pivots: the block products are the same numbers as the serial ones.
        #expect(analysis.iterations == reference.iterations)
        #expect(await budget.peakInUse <= 4)
        #expect(await budget.peakInUse > 1)
        #expect(await budget.slotsInUse == 1)
    }
}
