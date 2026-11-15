// ZTronLPBenchmarks — prints the benchmark table of specification §14.3.
//
// Run it in an optimized build before a tagged release (it is not part of CI):
//
//     swift run -c release ZTronLPBenchmarks            # every workload
//     swift run -c release ZTronLPBenchmarks netlib mip # a selection
//
// Workloads: netlib, transport, mip, cpsat, metal, latency. The MIPLIB and CP-SAT rows need
// the corpus that Scripts/fetch-miplib.sh downloads; rows whose instance is missing say so.

import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Output helpers

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

/// Four decimals; a negative zero prints as zero.
func fixed(_ value: Double) -> String { String(format: "%.4f", value == 0 ? 0 : value) }

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func elapsed(since start: UInt64) -> Double { Double(now() - start) / 1e9 }

/// Peak resident memory of the process so far, in megabytes.
func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    // ru_maxrss is in bytes on Darwin.
    return Double(usage.ru_maxrss) / (1024 * 1024)
}

func heading(_ title: String, acceptance: String) {
    print("\n## \(title)")
    print("acceptance for v1: \(acceptance)")
}

func describe(_ status: SolveStatus) -> String {
    switch status {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "inf/unbd"
    case .feasible(let reason): return "feasible/\(reason)"
    case .noSolution(let reason): return "none/\(reason)"
    case .numericalFailure: return "numerical"
    }
}

// MARK: - Netlib

func netlib() async throws {
    heading("Netlib set", acceptance: "primal ≤ 2 s, dual ≤ 2 s, IPM + crossover-lite ≤ 3 s in total on M1")
    print(pad("instance", 10) + pad("primal it", 11) + pad("s", 9) + pad("dual it", 9) + pad("s", 9) + pad("IPM it", 8) + pad("xover it", 10) + pad("s", 9) + "max rel. error")
    var totals = [0.0, 0.0, 0.0]
    for instance in ReferenceValues.netlib {
        let lp = try NetlibFixtures.load(instance.name)
        let primal = try await Simplex(.primal).solve(lp)
        let dual = try await Simplex(.dual).solve(lp)
        let interior = try await InteriorPoint(crossover: .lite).solve(lp)
        totals[0] += primal.seconds
        totals[1] += dual.seconds
        totals[2] += interior.seconds
        let errors = [primal.objectiveValue, dual.objectiveValue, interior.objectiveValue].map {
            $0.map { ReferenceValues.relativeError($0, reference: instance.optimalObjective) } ?? .infinity
        }
        print(
            pad(instance.name, 10) + pad("\(primal.iterations)", 11) + pad(seconds(primal.seconds), 9)
                + pad("\(dual.iterations)", 9) + pad(seconds(dual.seconds), 9) + pad("\(interior.iterations)", 8)
                + pad("\(interior.crossover?.iterations ?? 0)", 10) + pad(seconds(interior.seconds), 9)
                + String(format: "%.1e", errors.max() ?? .infinity))
    }
    print("total seconds: primal \(seconds(totals[0])), dual \(seconds(totals[1])), IPM + crossover-lite \(seconds(totals[2]))")
}

// MARK: - Transport LP, dense LU vs sparse QR

/// A sparse transportation problem with `sources + sinks` rows and `arcs` columns. Every
/// source can cover the demand of every sink it reaches, so the problem is always feasible.
func sparseTransport(sources: Int, sinks: Int, arcs: Int, seed: UInt64) -> CompiledLP {
    var rng = SeededGenerator(seed: seed)
    var entries: [(row: Int, col: Int, value: Double)] = []
    var cost: [Double] = []
    let demand = (0..<sinks).map { _ in (rng.uniform(in: 5...50)).rounded() }
    var load = [Double](repeating: 0, count: sources)
    var column = 0
    var seen = Set<Int>()
    func arc(_ s: Int, _ t: Int) {
        guard seen.insert(s * sinks + t).inserted else { return }
        entries.append((s, column, 1))
        entries.append((sources + t, column, 1))
        cost.append((rng.uniform(in: 1...100)).rounded())
        load[s] += demand[t]
        column += 1
    }
    for t in 0..<sinks { arc(rng.integer(in: 0...(sources - 1)), t) }
    while column < arcs { arc(rng.integer(in: 0...(sources - 1)), rng.integer(in: 0...(sinks - 1))) }
    var rl = [Double](repeating: -.infinity, count: sources + sinks)
    var ru = [Double](repeating: .infinity, count: sources + sinks)
    for s in 0..<sources { ru[s] = Swift.max(load[s], 1) }
    for t in 0..<sinks { rl[sources + t] = demand[t] }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: sources + sinks, cols: column, entries), c: cost,
        xl: [Double](repeating: 0, count: column), xu: [Double](repeating: .infinity, count: column), rl: rl, ru: ru)
}

func transport() async throws {
    heading("Random transport LP, 2,000 × 20,000", acceptance: "DenseLUBasis and SparseQRBasis both ≤ 10 s on M1; the faster becomes the automatic choice at that size")
    let lp = sparseTransport(sources: 1_000, sinks: 1_000, arcs: 20_000, seed: 1)
    print("rows \(lp.m), columns \(lp.n), nonzeros \(lp.nnz)")
    print(pad("basis", 14) + pad("method", 9) + pad("status", 12) + pad("iterations", 12) + pad("refactors", 11) + pad("seconds", 10) + "objective")
    var context = SolveContext()
    context.timeLimit = 120
    for (name, factorization) in [("DenseLUBasis", Simplex.Factorization.denseLU), ("SparseQRBasis", .sparseQR)] {
        for method in [Simplex.Method.dual, .primal] {
            let analysis = try await Simplex(method, factorization: factorization).solve(lp, context: context)
            print(
                pad(name, 14) + pad(method == .dual ? "dual" : "primal", 9) + pad(describe(analysis.status), 12)
                    + pad("\(analysis.iterations)", 12) + pad("\(analysis.refactorizations)", 11)
                    + pad(seconds(analysis.seconds), 10) + (analysis.objectiveValue.map { fixed($0) } ?? "-"))
        }
    }
    let interior = try await InteriorPoint().solve(lp, context: context)
    print(
        pad("(interior point)", 23) + pad(describe(interior.status), 12) + pad("\(interior.iterations)", 12) + pad("-", 11)
            + pad(seconds(interior.seconds), 10) + (interior.objectiveValue.map { fixed($0) } ?? "-"))
}

// MARK: - MIPLIB

func mip() async throws {
    heading("MIPLIB 3 set, branch and bound, primal vs dual node strategy", acceptance: "both solve every instance in ≤ 60 s on M1; the table reports the ratio")
    print(
        pad("instance", 9) + pad("primal: status", 16) + pad("nodes", 8) + pad("LP it", 9) + pad("s", 8)
            + pad("dual: status", 14) + pad("nodes", 8) + pad("LP it", 9) + pad("s", 8) + pad("it ratio", 9) + "objective (reference)")
    var context = SolveContext()
    context.timeLimit = 60
    for instance in ReferenceValues.miplib3 {
        guard let lp = try Corpora.loadMIPLIB3(instance.name) else {
            print(pad(instance.name, 9) + "not fetched (run Scripts/fetch-miplib.sh)")
            continue
        }
        let primal = try await BranchAndBound().solve(lp, context: context)
        let dual = try await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: context)
        let ratio = dual.lpIterations > 0 ? Double(primal.lpIterations) / Double(dual.lpIterations) : .nan
        print(
            pad(instance.name, 9) + pad(describe(primal.status), 16) + pad("\(primal.nodesProcessed)", 8)
                + pad("\(primal.lpIterations)", 9) + pad(String(format: "%.2f", primal.seconds), 8)
                + pad(describe(dual.status), 14) + pad("\(dual.nodesProcessed)", 8) + pad("\(dual.lpIterations)", 9)
                + pad(String(format: "%.2f", dual.seconds), 8) + pad(String(format: "%.2f", ratio), 9)
                + "\(primal.objectiveValue.map { fixed($0) } ?? "-") (\(instance.optimalObjective))")
    }
}

func cpsat() async throws {
    heading("MIPLIB 3 set, CP-SAT", acceptance: "every pure-integer instance ≤ 60 s on M1")
    print(
        pad("instance", 9) + pad("configuration", 27) + pad("status", 20) + pad("conflicts", 11) + pad("decisions", 11)
            + pad("LP solves", 11) + pad("s", 9) + "objective (reference)")
    var context = SolveContext()
    context.timeLimit = 60
    // The six instances §14.2 lists for CP-SAT, then the other pure-integer one of the set.
    let listed = ["p0033", "stein27", "stein45", "enigma", "lseu", "mod008"]
    let instances = ReferenceValues.miplib3.filter { listed.contains($0.name) }
        + ReferenceValues.miplib3.filter { $0.pureInteger && !listed.contains($0.name) }
    var closed = [0, 0]
    for instance in instances {
        guard let lp = try Corpora.loadMIPLIB3(instance.name) else {
            print(pad(instance.name, 9) + "not fetched (run Scripts/fetch-miplib.sh)")
            continue
        }
        // As it runs by default, with the LP propagator of §10.4, and the subset of §10.2 alone.
        for (index, configuration) in [("CPSAT()", CPSAT()), ("CPSAT(lpPropagator: false)", CPSAT(lpPropagator: false))].enumerated() {
            let analysis = try await configuration.1.solve(lp, context: context)
            if analysis.status == .optimal { closed[index] += 1 }
            print(
                pad(instance.name, 9) + pad(configuration.0, 27) + pad(describe(analysis.status), 20)
                    + pad("\(analysis.conflicts)", 11) + pad("\(analysis.decisions)", 11) + pad("\(analysis.lpSolves)", 11)
                    + pad(String(format: "%.2f", analysis.seconds), 9)
                    + "\(analysis.objectiveValue.map { fixed($0) } ?? "-") (\(instance.optimalObjective))")
        }
    }
    print("proven optimal within the limit: \(closed[0]) of \(instances.count) by default, \(closed[1]) of \(instances.count) without the LP propagator")
}

// MARK: - Metal

func metal() async throws {
    heading("reducedCostScan, Metal vs CPU", acceptance: "Metal ≥ 1.5× faster on a 5,000 × 200,000 LP, or the threshold is raised")
    print(pad("rows", 8) + pad("columns", 11) + pad("nonzeros", 11) + pad("CPU ms", 10) + pad("Metal ms", 10) + pad("speedup", 9) + "candidates agreeing with fp64")
    // The specified size first, then larger ones to locate the crossover.
    for (sources, sinks, arcs) in [(2_500, 2_500, 200_000), (5_000, 5_000, 1_000_000), (10_000, 10_000, 3_000_000)] {
        let lp = sparseTransport(sources: sources, sinks: sinks, arcs: arcs, seed: 2)
        var rng = SeededGenerator(seed: 3)
        let duals = (0..<lp.m).map { _ in rng.uniform(in: -1...1) }
        let weights = (0..<lp.n).map { _ in rng.uniform(in: 1...4) }
        let eligibility = [UInt8](repeating: PricingEligibility.increase, count: lp.n)
        let rounds = 10

        // CPU: the same quantity in Double — d = c − Aᵀy, then the best 64 by d²/w.
        var cpuCandidates: [Int32] = []
        let cpuStart = now()
        for _ in 0..<rounds {
            var product = [Double](repeating: 0, count: lp.n)
            lp.a.multiplyTranspose(duals, into: &product)
            var best: [(Double, Int32)] = []
            var floor = 0.0
            for j in 0..<lp.n {
                let reduced = lp.c[j] - product[j]
                guard reduced < 0 else { continue }
                let score = reduced * reduced / weights[j]
                if best.count < KernelThresholds.reducedCostCandidates {
                    best.append((score, Int32(j)))
                    if best.count == KernelThresholds.reducedCostCandidates {
                        best.sort { $0.0 > $1.0 }
                        floor = best.last!.0
                    }
                } else if score > floor {
                    best[best.count - 1] = (score, Int32(j))
                    best.sort { $0.0 > $1.0 }
                    floor = best.last!.0
                }
            }
            cpuCandidates = best.map(\.1)
        }
        let cpuMillis = elapsed(since: cpuStart) * 1000 / Double(rounds)

        var line = pad("\(lp.m)", 8) + pad("\(lp.n)", 11) + pad("\(lp.nnz)", 11) + pad(String(format: "%.3f", cpuMillis), 10)
        if let scanner = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced) {
            // Warm up (pipeline creation, first buffer upload), then time.
            _ = await scanner.scan(costs: lp.c, duals: duals, weights: weights, eligibility: eligibility, limit: 64)
            var gpuCandidates: [Int32] = []
            let gpuStart = now()
            for _ in 0..<rounds {
                gpuCandidates = await scanner.scan(costs: lp.c, duals: duals, weights: weights, eligibility: eligibility, limit: 64) ?? []
            }
            let gpuMillis = elapsed(since: gpuStart) * 1000 / Double(rounds)
            let agreement = Set(gpuCandidates).intersection(cpuCandidates).count
            line += pad(String(format: "%.3f", gpuMillis), 10) + pad(String(format: "%.2f×", cpuMillis / gpuMillis), 9) + "\(agreement) of 64"
        } else {
            line += "Metal unavailable (\(await MetalAccelerator.shared.status()))"
        }
        print(line)
    }
    print("automatic thresholds in force: n ≥ \(KernelThresholds.reducedCostScanColumns) and nnz ≥ \(KernelThresholds.reducedCostScanNonzeros)")
}

// MARK: - Cancellation latency

func latency() async throws {
    heading("Cancellation latency", acceptance: "p99 ≤ 50 ms across engines")
    let lp = try NetlibFixtures.load("degen2")
    let hard = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
    var rng = SeededGenerator(seed: 5)
    print(pad("engine", 28) + pad("solves", 8) + pad("interrupted", 13) + pad("p50 ms", 9) + pad("p99 ms", 9) + "max ms")
    var all: [Double] = []
    func row(_ name: String, window: Double, _ sample: (Double) async -> LivenessHarness.CancellationSample) async {
        var latencies: [Double] = []
        var interrupted = 0
        for _ in 0..<40 {
            let result = await sample(rng.uniform(in: 0...window))
            latencies.append(result.latency)
            if result.status.stopReason == .cancelled { interrupted += 1 }
        }
        all.append(contentsOf: latencies)
        print(
            pad(name, 28) + pad("\(latencies.count)", 8) + pad("\(interrupted)", 13)
                + pad(String(format: "%.2f", LivenessHarness.quantile(latencies, 0.5) * 1000), 9)
                + pad(String(format: "%.2f", LivenessHarness.quantile(latencies, 0.99) * 1000), 9)
                + String(format: "%.2f", (latencies.max() ?? 0) * 1000))
    }
    func duration(_ body: () async throws -> Void) async rethrows -> Double {
        let start = now()
        try await body()
        return elapsed(since: start)
    }
    var limited = SolveContext()
    limited.timeLimit = 5
    let primalWindow = try await duration { _ = try await Simplex(.primal).solve(lp) }
    await row("Simplex(.primal)", window: primalWindow) { await LivenessHarness.cancellationLatency(Simplex(.primal), problem: lp, after: $0) }
    let dualWindow = try await duration { _ = try await Simplex(.dual).solve(lp) }
    await row("Simplex(.dual)", window: dualWindow) { await LivenessHarness.cancellationLatency(Simplex(.dual), problem: lp, after: $0) }
    let interiorWindow = try await duration { _ = try await InteriorPoint().solve(lp) }
    await row("InteriorPoint", window: interiorWindow) { await LivenessHarness.cancellationLatency(InteriorPoint(), problem: lp, after: $0) }
    let treeWindow = try await duration { _ = try await BranchAndBound().solve(hard, context: limited) }
    await row("BranchAndBound", window: treeWindow) { await LivenessHarness.cancellationLatency(BranchAndBound(), problem: hard, after: $0) }
    let satWindow = try await duration { _ = try await CPSAT().solve(hard, context: limited) }
    await row("CPSAT", window: satWindow) { await LivenessHarness.cancellationLatency(CPSAT(), problem: hard, after: $0) }
    let pureWindow = try await duration { _ = try await CPSAT(lpPropagator: false).solve(hard, context: limited) }
    await row("CPSAT(lpPropagator: false)", window: pureWindow) {
        await LivenessHarness.cancellationLatency(CPSAT(lpPropagator: false), problem: hard, after: $0)
    }
    print("all engines: p99 \(String(format: "%.2f", LivenessHarness.quantile(all, 0.99) * 1000)) ms, max \(String(format: "%.2f", (all.max() ?? 0) * 1000)) ms over \(all.count) solves")
}

// MARK: - Driver

let workloads: [(String, () async throws -> Void)] = [
    ("netlib", netlib), ("transport", transport), ("mip", mip), ("cpsat", cpsat), ("metal", metal),
    ("latency", latency),
]
let requested = Array(CommandLine.arguments.dropFirst())
let unknown = requested.filter { name in !workloads.contains { $0.0 == name } }
if !unknown.isEmpty {
    print("unknown workload(s): \(unknown.joined(separator: ", ")); choose from \(workloads.map(\.0).joined(separator: ", "))")
    exit(2)
}

let machine: String = {
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}()
#if DEBUG
let configuration = "debug — timings are not representative; use `-c release`"
#else
let configuration = "release"
#endif
print("# ZTronLPOptimizer benchmarks (specification §14.3)")
print("machine: \(machine), \(ProcessInfo.processInfo.activeProcessorCount) cores, \(ProcessInfo.processInfo.physicalMemory / (1 << 30)) GB; build: \(configuration)")

for (name, run) in workloads where requested.isEmpty || requested.contains(name) {
    let start = now()
    try await run()
    print("(\(name): \(seconds(elapsed(since: start))) s wall, peak memory so far \(String(format: "%.0f", peakMemoryMB())) MB)")
}
