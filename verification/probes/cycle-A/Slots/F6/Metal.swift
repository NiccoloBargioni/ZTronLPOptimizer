import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Double reference of the scan: score_j = |d_j|/sqrt(w_j) when eligible and attractive.
func referenceScores(_ lp: CompiledLP, costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8]) -> [Double] {
    let product = lp.a.multiplyTranspose(duals)
    var scores = [Double](repeating: 0, count: lp.n)
    for j in 0..<lp.n {
        let d = costs[j] - product[j]
        let code = eligibility[j]
        let attractive = (code == 1 && d < 0) || (code == 2 && d > 0) || (code == 3 && d != 0)
        if attractive { scores[j] = Swift.abs(d) / weights[j].squareRoot() }
    }
    return scores
}

func topK(_ scores: [Double], _ k: Int) -> [Int] {
    scores.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }.prefix(k).map { $0 }
}

func randomSparse(rows m: Int, cols n: Int, perColumn: Int, seed: UInt64, valueRange: ClosedRange<Double> = -10...10) -> SparseCSC {
    var rng = SeededGenerator(seed: seed)
    var entries: [(row: Int, col: Int, value: Double)] = []
    entries.reserveCapacity(n * perColumn)
    for j in 0..<n {
        var used = Set<Int>()
        for _ in 0..<perColumn {
            var i = rng.integer(in: 0...(m - 1))
            while used.contains(i) { i = (i + 1) % m }
            used.insert(i)
            entries.append((i, j, rng.uniform(in: valueRange)))
        }
    }
    return SparseCSC.fromTriplets(rows: m, cols: n, entries)
}

func metalProbe(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "status"
    switch which {
    case "status":
        let s = await MetalAccelerator.shared.status()
        print("status \(s) isAvailable \(await MetalAccelerator.shared.isAvailable)")
        if let c = await MetalAccelerator.shared.context() { print("context device \(c.device.name) source \(c.librarySource)") }
        let none = MetalAccelerator(device: nil)
        print("device nil: status \(await none.status())")
        let lp = try! NetlibFixtures.load("afiro")
        let k1 = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced)
        let k2 = await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .forced)
        print("forced kernels on afiro: scan \(k1 != nil) activity \(k2 != nil)")
        // Solves still work with forced policy.
        var ctx = SolveContext(); ctx.metal = .forced; ctx.attachMetal()
        let r = try? await Simplex(.primal).solve(lp, context: ctx)
        let mip = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)
        let b = try? await BranchAndBound().solve(mip, context: ctx)
        let bRef = try? await BranchAndBound().solve(mip)
        print("forced solves: simplex \(String(describing: r?.status)) \(String(describing: r?.objectiveValue)); BnB \(String(describing: b?.status)) \(String(describing: b?.objectiveValue)) vs CPU \(String(describing: bRef?.objectiveValue))")

    case "status2":
        // No fixtures (the binary may run without its resource bundles).
        let s = await MetalAccelerator.shared.status()
        print("status \(s)")
        let lp = InstanceGenerator.transport(sources: 20, sinks: 50, seed: 2)
        let mip = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)
        var ctx = SolveContext(); ctx.metal = .forced; ctx.attachMetal()
        let k = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced)
        let r = try? await Simplex(.primal).solve(lp, context: ctx)
        let r0 = try? await Simplex(.primal).solve(lp)
        let b = try? await BranchAndBound().solve(mip, context: ctx)
        let a = try? await Automatic().solve(mip, context: ctx)
        print("scanner \(k != nil); forced Simplex \(String(describing: r?.status)) \(String(describing: r?.objectiveValue)) (CPU \(String(describing: r0?.objectiveValue))); BnB \(String(describing: b?.status)) \(String(describing: b?.objectiveValue)); Automatic \(String(describing: a?.status)) \(String(describing: a?.objectiveValue))")
    case "thresholds":
        let T = KernelThresholds.self
        print("constants scanCols \(T.reducedCostScanColumns) scanNnz \(T.reducedCostScanNonzeros) cands \(T.reducedCostCandidates) actPts \(T.batchedActivityPoints) actNnz \(T.batchedActivityNonzeros) maxBatch \(T.batchedActivityMaxBatch) disagree \(T.disagreementFraction)")
        print("scan auto 3M/6M \(T.allowsReducedCostScan(columns: 3_000_000, nonzeros: 6_000_000, policy: .automatic)) 3M-1/6M \(T.allowsReducedCostScan(columns: 2_999_999, nonzeros: 6_000_000, policy: .automatic)) 3M/6M-1 \(T.allowsReducedCostScan(columns: 3_000_000, nonzeros: 5_999_999, policy: .automatic)) off \(T.allowsReducedCostScan(columns: 9_000_000, nonzeros: 90_000_000, policy: .off)) forced-small \(T.allowsReducedCostScan(columns: 1, nonzeros: 1, policy: .forced))")
        print("act auto 64/100k \(T.allowsBatchedActivity(points: 64, nonzeros: 100_000, policy: .automatic)) 63/100k \(T.allowsBatchedActivity(points: 63, nonzeros: 100_000, policy: .automatic)) 64/99999 \(T.allowsBatchedActivity(points: 64, nonzeros: 99_999, policy: .automatic)) off \(T.allowsBatchedActivity(points: 1000, nonzeros: 10_000_000, policy: .off)) forced-0 \(T.allowsBatchedActivity(points: 0, nonzeros: 1, policy: .forced))")
        // Provider honours them.
        let small = InstanceGenerator.transport(sources: 50, sinks: 1000, seed: 1)   // 100,000 nnz exactly
        print("small: n \(small.n) nnz \(small.nnz)")
        let a1 = await MetalAccelerator.shared.activityEvaluator(for: small, policy: .automatic)
        let a0 = await MetalAccelerator.shared.activityEvaluator(for: small, policy: .off)
        let s1 = await MetalAccelerator.shared.reducedCostScanner(for: small, policy: .automatic)
        print("provider on 100,000 nnz: activity auto \(a1 != nil) off \(a0 != nil); scan auto \(s1 != nil)")
        let smaller = InstanceGenerator.transport(sources: 50, sinks: 999, seed: 1)
        let a2 = await MetalAccelerator.shared.activityEvaluator(for: smaller, policy: .automatic)
        print("provider on \(smaller.nnz) nnz: activity auto \(a2 != nil)")
        if let a1 {
            let p63 = [Double](repeating: 0, count: 63 * small.n)
            let p64 = [Double](repeating: 0, count: 64 * small.n)
            let f63 = await a1.evaluate(points: p63, count: 63, tolerance: 1e-7)
            let f64 = await a1.evaluate(points: p64, count: 64, tolerance: 1e-7)
            print("PolicyBound evaluate 63 points -> \(f63 == nil ? "nil" : "flags") ; 64 points -> \(f64.map { "flags, feasible \($0.filter { $0 }.count)" } ?? "nil")")
        }
        // The context-level gate.
        var ctx = SolveContext(); ctx.metal = .off; ctx.attachMetal()
        print("attachMetal under .off: accelerator \(ctx.accelerator == nil ? "nil" : "set"), candidateKernels \(ctx.candidateKernels == nil ? "nil" : "set")")
        var ctx2 = SolveContext(); ctx2.accelerator = MetalAccelerator.shared; ctx2.metal = .off
        print("accelerator set, policy .off: candidateKernels \(ctx2.candidateKernels == nil ? "nil" : "set")")

    case "scan":
        // Kernel vs double at and above the threshold.
        let sizes: [(Int, Int, Int)] = args.count > 3 && args[3] == "big"
            ? [(20_000, 3_000_000, 2), (20_000, 3_200_000, 2)]
            : [(1_000, 20_000, 3), (5_000, 200_000, 2)]
        for (m, n, per) in sizes {
            let a = randomSparse(rows: m, cols: n, perColumn: per, seed: UInt64(n))
            var rng = SeededGenerator(seed: 77)
            let c = (0..<n).map { _ in rng.uniform(in: -1...1) }
            let lp = CompiledLP(a: a, c: c, xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
                                rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
            let duals = (0..<m).map { _ in rng.uniform(in: -1...1) }
            let weights = (0..<n).map { _ in rng.uniform(in: 1...4) }
            let eligibility = (0..<n).map { _ in UInt8(rng.integer(in: 0...3)) }
            let auto = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .automatic)
            guard let scanner = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced) else { print("no scanner"); continue }
            let gpu = await scanner.scan(costs: c, duals: duals, weights: weights, eligibility: eligibility, limit: 64) ?? []
            let ref = referenceScores(lp, costs: c, duals: duals, weights: weights, eligibility: eligibility)
            let cpuTop = topK(ref, 64)
            let overlap = Set(gpu.map { Int($0) }).intersection(cpuTop).count
            let worstGPU = gpu.map { ref[Int($0)] }.min() ?? 0
            let cut = cpuTop.last.map { ref[$0] } ?? 0
            let nonAttractive = gpu.filter { ref[Int($0)] <= 0 }.count
            // Scores vs double.
            let scores = await (scanner as? MetalReducedCostScan)?.scores(costs: c, duals: duals, weights: weights, eligibility: eligibility) ?? []
            var maxRel = 0.0
            var signFlips = 0
            for j in 0..<n where scores.count == n {
                let s = Double(scores[j])
                if (s > 0) != (ref[j] > 0) { signFlips += 1 }
                if ref[j] > 1e-3 { maxRel = Swift.max(maxRel, Swift.abs(s - ref[j]) / ref[j]) }
            }
            print("scan m=\(m) n=\(n) nnz=\(lp.nnz): auto kernel \(auto != nil); gpu \(gpu.count) cands, overlap with fp64 top-64 \(overlap), non-attractive \(nonAttractive), worst gpu cand score \(worstGPU) vs fp64 64th \(cut); scores max rel err (ref>1e-3) \(maxRel), attractive-flag flips \(signFlips)")
        }

    case "activity":
        // No false negatives: a point feasible in Double is never rejected.
        let m = 500, n = 400
        let a = randomSparse(rows: m, cols: n, perColumn: 250, seed: 5, valueRange: -1000...1000)   // 100,000 nnz
        var rng = SeededGenerator(seed: 9)
        // Points first, then bounds set so that the points lie exactly on or near bounds.
        let count = 256
        var points = [Double](repeating: 0, count: count * n)
        for k in 0..<(count * n) { points[k] = rng.uniform(in: -1e3...1e3) }
        // Row bounds: [min activity, max activity] over the first 128 points -> those are feasible.
        var lo = [Double](repeating: .infinity, count: m)
        var hi = [Double](repeating: -.infinity, count: m)
        for k in 0..<128 {
            let x = Array(points[(k * n)..<((k + 1) * n)])
            let product = a.multiply(x)
            for i in 0..<m { lo[i] = Swift.min(lo[i], product[i]); hi[i] = Swift.max(hi[i], product[i]) }
        }
        let lp = CompiledLP(a: a, c: [Double](repeating: 0, count: n), xl: [Double](repeating: -1e3, count: n), xu: [Double](repeating: 1e3, count: n), rl: lo, ru: hi)
        guard let ev = await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .automatic) else { print("no evaluator (nnz \(lp.nnz))"); return }
        let flags = await ev.evaluate(points: points, count: count, tolerance: 0) ?? []
        var falseNeg = 0, falsePos = 0, feasibleCount = 0
        for k in 0..<count {
            let x = Array(points[(k * n)..<((k + 1) * n)])
            let viol = lp.maxViolation(at: x)
            let feasible = viol.bounds <= 0 && viol.rows <= 0
            if feasible { feasibleCount += 1 }
            if feasible && !(flags[k]) { falseNeg += 1 }
            if !feasible && flags[k] { falsePos += 1 }
        }
        print("activity: \(count) points, fp64-feasible \(feasibleCount), false negatives \(falseNeg), false positives \(falsePos)")

    case "bigbound":
        // A row bound beyond the fp32 range (finite in Double) is clamped to 3e38 for the GPU.
        // A point whose activity is between 3e38 and the true bound is feasible in exact
        // arithmetic; does the screen reject it?
        let n = 2, m = 1
        let a = SparseCSC.fromTriplets(rows: m, cols: n, [(0, 0, 1.0), (0, 1, 1.0)])
        let lp = CompiledLP(a: a, c: [0, 0], xl: [0, 0], xu: [1e39, 1e39], rl: [-.infinity], ru: [1e39])
        guard let ev = await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .forced) else { print("no evaluator"); return }
        let points: [Double] = [1.6e38, 1.6e38, 1e38, 1e38, 0, 0]
        let flags = await ev.evaluate(points: points, count: 3, tolerance: 1e-7) ?? []
        for k in 0..<3 {
            let x = Array(points[(2 * k)..<(2 * k + 2)])
            print("point \(x): activity \(x[0] + x[1]) <= 1e39, fp64 maxViolation \(lp.maxViolation(at: x)), GPU flag feasible \(flags.count > k ? String(flags[k]) : "nil")")
        }

    default:
        print("unknown")
    }
}
