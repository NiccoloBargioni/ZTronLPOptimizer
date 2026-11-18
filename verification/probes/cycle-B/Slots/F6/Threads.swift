// SolveContext.threads honoured (CPU utilisation), parallel search vs enumeration across thread
// counts, and cancellation latency on large uninterruptible work.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func utilisation<S: SolverStrategy>(_ label: String, _ s: S, _ lp: CompiledLP, threads: Int?, limit: Double) async {
    var ctx = SolveContext()
    ctx.timeLimit = limit
    ctx.threads = threads
    let c0 = cpuSeconds()
    let t = nowNs()
    let a = try? await s.solve(lp, context: ctx)
    let wall = secs(t)
    let cpu = cpuSeconds() - c0
    let util = cpu / max(wall, 1e-9)
    let limitThreads = Double(threads ?? ProcessInfo.processInfo.activeProcessorCount)
    let verdict = util <= limitThreads + 0.35 ? "OK" : "OVER"
    print("THREADS \(verdict) \(label) threads=\(threads.map(String.init) ?? "nil") wall=\(String(format: "%.2f", wall)) cpu=\(String(format: "%.2f", cpu)) utilisation=\(String(format: "%.2f", util)) status=\(a.map { statusName($0.status) } ?? "threw")")
}

func runThreads(_ args: [String]) async {
    let which = args.first ?? "all"
    let mip = Problems.mipHard()
    if which == "all" || which == "util" {
        for th in [1, 2, 4] {
            await utilisation("BranchAndBound/mipHard", BranchAndBound(), mip, threads: th, limit: 2.5)
            await utilisation("CPSAT/mipHard", CPSAT(), mip, threads: th, limit: 2.5)
        }
        await utilisation("Portfolio(bnb,cpsat)/mipHard", Portfolio([BranchAndBound(), CPSAT()]), mip, threads: 2, limit: 2.5)
        await utilisation("Portfolio(bnb,cpsat)/mipHard", Portfolio([BranchAndBound(), CPSAT()]), mip, threads: 1, limit: 2.5)
        await utilisation("Portfolio(bnb,cpsat,bnbdual)/mipHard", Portfolio([BranchAndBound(), CPSAT(), BranchAndBound(engine: Simplex(.dual))]), mip, threads: 1, limit: 2.5)
        await utilisation("CPSAT(workers:4)/mipHard", CPSAT(workers: 4), mip, threads: 1, limit: 2.5)
        let big = InstanceGenerator.transport(sources: 100, sinks: 1_200, seed: 12)  // n=120,000 nnz=240,000: parallel pricing
        await utilisation("Simplex(.primal)/transport120k", Simplex(.primal), big, threads: 1, limit: 6)
        await utilisation("Simplex(.dual)/transport120k", Simplex(.dual), big, threads: 1, limit: 6)
        await utilisation("InteriorPoint/transport120k", InteriorPoint(), big, threads: 1, limit: 6)
    }
    if which == "all" || "diff" == which {
        var mism = 0
        for seed in UInt64(1)...25 {
            let ip = smallIP(seed: 7000 + seed, rows: 6, cols: 13, upper: seed % 4 == 0 ? 2 : 1)
            let ref = enumerateOptimum(ip)
            var line = "seed=\(7000 + seed) ref=\(f(ref))"
            var bad = false
            for th in [1, 2, 8] {
                var ctx = SolveContext(); ctx.threads = th; ctx.timeLimit = 20
                let b = try? await BranchAndBound().solve(ip, context: ctx)
                let c = try? await CPSAT().solve(ip, context: ctx)
                let d = try? await BranchAndBound(engine: Simplex(.dual), nodeSelection: .depthFirst).solve(ip, context: ctx)
                for (tag, a) in [("bnb", b.map { ($0.status, $0.objectiveValue) }), ("cpsat", c.map { ($0.status, $0.objectiveValue) }), ("bnbDualDF", d.map { ($0.status, $0.objectiveValue) })] {
                    guard let (st, v) = a, st == .optimal, let v, let r = ref, abs(v - r) <= 1e-6 * max(1, abs(r)) + 1e-4 * abs(r) else {
                        bad = true; line += " \(tag)@\(th)=\(a.map { "\(statusName($0.0)) \(f($0.1))" } ?? "threw")"; continue
                    }
                }
            }
            if bad { mism += 1; print("THREADS DIFF MISMATCH \(line)") }
        }
        print("THREADS DIFF bnb/cpsat/bnbDualDF x threads{1,2,8} vs enumeration: \(mism) mismatching seeds of 25")
    }
}

/// Cancellation latency where single steps are large: dense IPM normal equations, Conditioned's
/// dense basis factorization, sparse-QR simplex.
func runBigCancel(_ args: [String]) async {
    let which = args.first ?? "all"
    let reps = args.count > 1 ? Int(args[1]) ?? 6 : 6
    if which == "all" || which == "conditioned" {
        var o = ConstructedOptions(); o.density = 0.0015
        let inst = InstanceGenerator.constructedOptimum(rows: 3_500, columns: 7_000, seed: 31, options: o)
        let lp = inst.lp
        print("BIG conditioned problem m=\(lp.m) n=\(lp.n) nnz=\(lp.nnz)")
        _ = await cancelSeries("Simplex(.dual)/m3500", Simplex(.dual), lp, reps: reps, seed: 41, windowCap: 2)
        _ = await cancelSeries("Conditioned(Simplex(.dual))/m3500", Conditioned(Simplex(.dual)), lp, reps: reps, seed: 41, windowCap: 2)
        await limitCase("Conditioned(Simplex(.dual))/m3500", Conditioned(Simplex(.dual)), lp, limit: 0.3)
        await limitCase("Simplex(.dual)/m3500", Simplex(.dual), lp, limit: 0.3)
    }
    if which == "all" || which == "ipm" {
        var o = ConstructedOptions(); o.density = 0.08
        let inst = InstanceGenerator.constructedOptimum(rows: 3_000, columns: 6_000, seed: 32, options: o)
        let lp = inst.lp
        print("BIG ipm problem m=\(lp.m) n=\(lp.n) nnz=\(lp.nnz)")
        _ = await cancelSeries("InteriorPoint/dense-m3000", InteriorPoint(), lp, reps: reps, seed: 42, windowCap: 3)
        await limitCase("InteriorPoint/dense-m3000", InteriorPoint(), lp, limit: 0.3)
    }
}

/// Attribution of Conditioned's overrun: time ConditioningAnalyzer.analyze on the stopped
/// solve's basis, and show that cancelling the task does not shorten it.
func runAnalyzerTiming(_ args: [String]) async {
    var o = ConstructedOptions(); o.density = 0.0015
    let lp = InstanceGenerator.constructedOptimum(rows: 3_500, columns: 7_000, seed: 31, options: o).lp
    var ctx = SolveContext(); ctx.timeLimit = 0.3
    guard let a = try? await Simplex(.dual).solve(lp, context: ctx) else { print("ANALYZER solve threw"); return }
    print("ANALYZER inner status=\(statusName(a.status)) hasBasis=\(a.finalBasis != nil)")
    for cancelAfter in [nil, 0.005] as [Double?] {
        let task = Task { () -> (Double, String) in
            let t = nowNs()
            let report = await ConditioningAnalyzer.analyze(lp, after: a, context: ctx.silenced())
            return (secs(t), "\(report.basisAnalysis)")
        }
        if let c = cancelAfter { try? await Task.sleep(nanoseconds: UInt64(c * 1e9)); task.cancel() }
        let (el, outcome) = await task.value
        print("ANALYZER analyze(after:) m=\(lp.m) took \(String(format: "%.3f", el)) s outcome=\(outcome) cancelledAfter=\(cancelAfter.map { "\($0)" } ?? "never")")
    }
}

/// threads = 1 on engines whose heavy steps are Accelerate calls.
func runUtil2(_ args: [String]) async {
    var o = ConstructedOptions(); o.density = 0.08
    let dense = InstanceGenerator.constructedOptimum(rows: 3_000, columns: 6_000, seed: 32, options: o).lp
    await utilisation("InteriorPoint/dense-m3000", InteriorPoint(), dense, threads: 1, limit: 4)
    await utilisation("InteriorPoint/dense-m3000", InteriorPoint(), dense, threads: 2, limit: 4)
    var o2 = ConstructedOptions(); o2.density = 0.0015
    let sq = InstanceGenerator.constructedOptimum(rows: 3_500, columns: 7_000, seed: 31, options: o2).lp
    await utilisation("Simplex(.dual,sparseQR)/m3500", Simplex(.dual), sq, threads: 1, limit: 4)
    await utilisation("Conditioned(Simplex(.dual))/m3500", Conditioned(Simplex(.dual)), sq, threads: 1, limit: 1)
}
