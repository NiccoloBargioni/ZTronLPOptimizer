// Metal tier: thresholds/policy, kernel outputs vs a double-precision oracle, end-to-end
// equality with the CPU path.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func randomLP(m: Int, n: Int, perColumn: Int, seed: UInt64, integerValues: Bool = false, magnitude: Double = 4) -> CompiledLP {
    var rng = SeededGenerator(seed: seed)
    var e: [(row: Int, col: Int, value: Double)] = []
    e.reserveCapacity(n * perColumn)
    for j in 0..<n {
        for _ in 0..<perColumn {
            let i = rng.integer(in: 0...(m - 1))
            let v = integerValues ? Double(rng.integer(in: -Int(magnitude)...Int(magnitude))) : rng.uniform(in: -magnitude...magnitude)
            if v != 0 { e.append((i, j, v)) }
        }
    }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, e)
    return CompiledLP(a: a, c: (0..<n).map { _ in rng.uniform(in: -1...1) }, xl: .init(repeating: 0, count: n),
                      xu: .init(repeating: 10, count: n), rl: .init(repeating: -.infinity, count: m), ru: .init(repeating: 100, count: m))
}

func runMetal(_ args: [String]) async {
    let which = args.first ?? "all"
    let acc = MetalAccelerator.shared
    let status = await acc.status()
    print("METAL status=\(status) available=\(await acc.isAvailable)")
    let noDev = MetalAccelerator(device: nil)
    print("METAL device:nil status=\(await noDev.status())")

    if which == "all" || which == "thresholds" {
        typealias K = KernelThresholds
        let checks: [(String, Bool, Bool)] = [
            ("scan 3,000,000/6,000,000 auto", K.allowsReducedCostScan(columns: 3_000_000, nonzeros: 6_000_000, policy: .automatic), true),
            ("scan 2,999,999/6,000,000 auto", K.allowsReducedCostScan(columns: 2_999_999, nonzeros: 6_000_000, policy: .automatic), false),
            ("scan 3,000,000/5,999,999 auto", K.allowsReducedCostScan(columns: 3_000_000, nonzeros: 5_999_999, policy: .automatic), false),
            ("scan huge off", K.allowsReducedCostScan(columns: 9_000_000, nonzeros: 90_000_000, policy: .off), false),
            ("scan 1/1 forced", K.allowsReducedCostScan(columns: 1, nonzeros: 1, policy: .forced), true),
            ("act 64/100,000 auto", K.allowsBatchedActivity(points: 64, nonzeros: 100_000, policy: .automatic), true),
            ("act 63/100,000 auto", K.allowsBatchedActivity(points: 63, nonzeros: 100_000, policy: .automatic), false),
            ("act 64/99,999 auto", K.allowsBatchedActivity(points: 64, nonzeros: 99_999, policy: .automatic), false),
            ("act 1/1 forced", K.allowsBatchedActivity(points: 1, nonzeros: 1, policy: .forced), true),
            ("act 0/1 forced", K.allowsBatchedActivity(points: 0, nonzeros: 1, policy: .forced), false),
            ("act off", K.allowsBatchedActivity(points: 1000, nonzeros: 10_000_000, policy: .off), false),
        ]
        for (label, got, want) in checks { print("METAL THRESH \(got == want ? "HELD" : "FAIL") \(label): \(got)") }
        print("METAL consts scanCols=\(K.reducedCostScanColumns) scanNnz=\(K.reducedCostScanNonzeros) cand=\(K.reducedCostCandidates) actPts=\(K.batchedActivityPoints) actNnz=\(K.batchedActivityNonzeros) maxBatch=\(K.batchedActivityMaxBatch) disagree=\(K.disagreementFraction)")
        // provider gating
        let small = randomLP(m: 200, n: 2_000, perColumn: 3, seed: 1)
        let big = randomLP(m: 2_000, n: 25_000, perColumn: 5, seed: 2)   // nnz ~ 125,000
        let s1 = await acc.reducedCostScanner(for: small, policy: .automatic)
        let s2 = await acc.reducedCostScanner(for: small, policy: .forced)
        let s3 = await acc.reducedCostScanner(for: small, policy: .off)
        print("METAL PROVIDER scanner small auto=\(s1 != nil) forced=\(s2 != nil) off=\(s3 != nil) (expect false,true,false)")
        let e1 = await acc.activityEvaluator(for: small, policy: .automatic)
        let e2 = await acc.activityEvaluator(for: big, policy: .automatic)
        let e3 = await acc.activityEvaluator(for: small, policy: .forced)
        print("METAL PROVIDER evaluator small(nnz=\(small.nnz)) auto=\(e1 != nil) big(nnz=\(big.nnz)) auto=\(e2 != nil) small forced=\(e3 != nil)")
        if let e2 {
            let pts63 = [Double](repeating: 0, count: 63 * big.n)
            let pts64 = [Double](repeating: 0, count: 64 * big.n)
            let r63 = await e2.evaluate(points: pts63, count: 63, tolerance: 1e-7)
            let r64 = await e2.evaluate(points: pts64, count: 64, tolerance: 1e-7)
            print("METAL PROVIDER policy-bound evaluate auto: 63 points -> \(r63 == nil ? "nil" : "ran"), 64 points -> \(r64 == nil ? "nil" : "ran")")
        }
        let nd1 = await noDev.reducedCostScanner(for: small, policy: .forced)
        let nd2 = await noDev.activityEvaluator(for: small, policy: .forced)
        print("METAL PROVIDER device:nil forced scanner=\(nd1 != nil) evaluator=\(nd2 != nil) (expect false,false)")
    }

    if which == "all" || which == "scan" {
        // Scores vs double oracle.
        for (m, n, seed) in [(500, 5_000, UInt64(3)), (3_000, 60_000, UInt64(4))] {
            let lp = randomLP(m: m, n: n, perColumn: 5, seed: seed)
            guard let scanner = await acc.reducedCostScanner(for: lp, policy: .forced) as? MetalReducedCostScan else { print("METAL SCAN no kernel"); continue }
            var rng = SeededGenerator(seed: seed &+ 99)
            let y = (0..<m).map { _ in rng.uniform(in: -1...1) }
            let w = (0..<n).map { _ in rng.uniform(in: 1...5) }
            let elig = (0..<n).map { _ in UInt8(rng.integer(in: 0...3)) }
            let aty = lp.a.multiplyTranspose(y)
            var ref = [Double](repeating: 0, count: n)
            for j in 0..<n {
                let d = lp.c[j] - aty[j]
                let attractive = (elig[j] == 1 && d < 0) || (elig[j] == 2 && d > 0) || (elig[j] == 3 && d != 0)
                ref[j] = attractive ? abs(d) / w[j].squareRoot() : 0
            }
            guard let gpu = await scanner.scores(costs: lp.c, duals: y, weights: w, eligibility: elig) else { print("METAL SCAN scores nil"); continue }
            var maxAbsErr = 0.0, signFlips = 0
            for j in 0..<n {
                let g = Double(gpu[j])
                maxAbsErr = max(maxAbsErr, abs(g - ref[j]))
                if (g > 0) != (ref[j] > 0) && max(g, ref[j]) > 1e-4 { signFlips += 1 }
            }
            let top = await scanner.scan(costs: lp.c, duals: y, weights: w, eligibility: elig, limit: 64) ?? []
            let refTop = Array((0..<n).filter { ref[$0] > 0 }.sorted { ref[$0] > ref[$1] || (ref[$0] == ref[$1] && $0 < $1) }.prefix(64))
            let overlap = Set(top.map(Int.init)).intersection(refTop).count
            // the worst-ranked kernel candidate must be within fp32 noise of the 64th double score
            let kth = refTop.last.map { ref[$0] } ?? 0
            let weakest = top.map { ref[Int($0)] }.min() ?? 0
            print("METAL SCAN m=\(m) n=\(n) nnz=\(lp.nnz): maxAbsErr=\(String(format: "%.2e", maxAbsErr)) attractivenessFlips(>1e-4)=\(signFlips) top64 overlap=\(overlap)/64 weakestCandidateRefScore=\(String(format: "%.6g", weakest)) ref64th=\(String(format: "%.6g", kth))")
        }
    }

    if which == "all" || which == "activity" {
        // Claim: never rejects a point that is feasible in exact arithmetic. Integer data -> double is exact.
        var rejectedFeasible = 0, testedFeasible = 0, acceptedInfeasibleBeyondTol = 0
        for (m, n, perColumn, mag, xmax, seed) in [(300, 3_000, 4, 9.0, 20, UInt64(5)), (50, 20_000, 10, 4_000_000.0, 1_000, UInt64(6)), (5, 40_000, 2, 16_777_215.0, 7, UInt64(7))] {
            let base = randomLP(m: m, n: n, perColumn: perColumn, seed: seed, integerValues: true, magnitude: mag)
            var rng = SeededGenerator(seed: seed &+ 1)
            let count = 200
            var pts = [Double](repeating: 0, count: count * n)
            for k in 0..<count { for j in 0..<n { pts[k * n + j] = Double(rng.integer(in: 0...xmax)) } }
            // equality rows at the exact activity of point 0, so point 0 is exactly feasible (tight on every row)
            let x0 = Array(pts[0..<n])
            let act0 = base.a.multiply(x0)
            let lp = CompiledLP(a: base.a, c: base.c, xl: .init(repeating: 0, count: n), xu: .init(repeating: Double(xmax), count: n), rl: act0, ru: act0)
            guard let ev = await acc.activityEvaluator(for: lp, policy: .forced) as? PolicyBoundActivityEvaluator else { print("METAL ACT no kernel"); continue }
            guard let flags = await ev.kernel.evaluate(points: pts, count: count, tolerance: 0) else { print("METAL ACT nil"); continue }
            for k in 0..<count {
                let x = Array(pts[(k * n)..<((k + 1) * n)])
                let act = lp.a.multiply(x)
                var exactFeasible = true, beyond = false
                for i in 0..<m {
                    if act[i] != act0[i] { exactFeasible = false }
                    if abs(act[i] - act0[i]) > 1e-3 * (1 + abs(act0[i])) { beyond = true }
                }
                if exactFeasible { testedFeasible += 1; if !flags[k] { rejectedFeasible += 1 } }
                if beyond && flags[k] { acceptedInfeasibleBeyondTol += 1 }
            }
            // also: chunked dispatch (count > 1024) agrees with one-by-one
            print("METAL ACT m=\(m) n=\(n) nnz=\(lp.nnz) mag=\(mag): point0 flag=\(flags[0]) accepted=\(flags.filter { $0 }.count)/\(count)")
        }
        print("METAL ACT exact-feasible tested=\(testedFeasible) rejected=\(rejectedFeasible) acceptedClearlyInfeasible=\(acceptedInfeasibleBeyondTol)")
        // activities vs double
        let lp = randomLP(m: 400, n: 4_000, perColumn: 6, seed: 8)
        if let ev = await acc.activityEvaluator(for: lp, policy: .forced) as? PolicyBoundActivityEvaluator {
            var rng = SeededGenerator(seed: 80)
            let count = 1500   // > 1,024: two dispatches
            var pts = [Double](repeating: 0, count: count * lp.n)
            for k in 0..<(count * lp.n) { pts[k] = rng.uniform(in: 0...10) }
            if let acts = await ev.kernel.activities(points: pts, count: count) {
                var worstRel = 0.0
                for k in stride(from: 0, to: count, by: 97) {
                    let ref = lp.a.multiply(Array(pts[(k * lp.n)..<((k + 1) * lp.n)]))
                    for i in 0..<lp.m { worstRel = max(worstRel, abs(Double(acts[k * lp.m + i]) - ref[i]) / (1 + abs(ref[i]))) }
                }
                print("METAL ACT activities(1500 points, 2 dispatches) worst rel err vs double=\(String(format: "%.2e", worstRel)) dispatches=\(await ev.kernel.dispatches)")
            }
            if let all = await ev.kernel.evaluate(points: pts, count: count, tolerance: 1e-7) {
                var mismatch = 0
                for k in stride(from: 0, to: count, by: 50) {
                    let one = await ev.kernel.evaluate(points: Array(pts[(k * lp.n)..<((k + 1) * lp.n)]), count: 1, tolerance: 1e-7)
                    if one?.first != all[k] { mismatch += 1 }
                }
                print("METAL ACT batched vs single evaluate mismatches=\(mismatch) of \(count / 50)")
            }
        }
    }

    if which == "all" || which == "e2e" {
        // End-to-end: forced Metal vs off must give the same optimal objective (and the enumeration's).
        var mism = 0
        for seed in UInt64(1)...12 {
            let ip = smallIP(seed: 500 + seed, rows: 6, cols: 13)
            let ref = enumerateOptimum(ip)
            var on = SolveContext(); on.metal = .forced; on.timeLimit = 20
            var off = SolveContext(); off.metal = .off; off.timeLimit = 20
            let a = try? await Automatic().solve(ip, context: on)
            let b = try? await Automatic().solve(ip, context: off)
            var onAttached = on; onAttached.attachMetal()
            let c = try? await BranchAndBound().solve(ip, context: onAttached)
            let ok = [a?.objectiveValue, b?.objectiveValue, c?.objectiveValue].allSatisfy { v in v != nil && ref != nil && abs(v! - ref!) <= 1e-6 }
            if !ok { mism += 1; print("METAL E2E MISMATCH seed=\(500 + seed) ref=\(f(ref)) auto-forced=\(f(a?.objectiveValue)) auto-off=\(f(b?.objectiveValue)) bnb-forced=\(f(c?.objectiveValue))") }
        }
        print("METAL E2E MIP forced vs off vs enumeration: \(mism) mismatches of 12")
        var worst = 0.0
        for name in NetlibFixtures.names {
            guard let lp = try? NetlibFixtures.load(name), let ref = ReferenceValues.netlib(named: name)?.optimalObjective else { continue }
            var on = SolveContext(); on.metal = .forced; on.timeLimit = 30; on.attachMetal()
            let a = try? await Simplex(.primal).solve(lp, context: on)
            let b = try? await InteriorPoint().solve(lp, context: on)
            for (tag, v) in [("primal", a?.objectiveValue), ("ipm", b?.objectiveValue)] {
                let err = v.map { ReferenceValues.relativeError($0, reference: ref) } ?? .infinity
                worst = max(worst, err)
                if err > 1e-6 { print("METAL E2E LP MISMATCH \(name) \(tag) obj=\(f(v)) ref=\(ref) status=\(tag == "primal" ? (a.map { statusName($0.status) } ?? "-") : (b.map { statusName($0.status) } ?? "-"))") }
            }
        }
        print("METAL E2E netlib forced (primal, ipm): worst relErr=\(worst)")
        // large-ish primal LP where the scan really runs every pricing step
        let lp = Problems.lpTransport()
        var on = SolveContext(); on.metal = .forced; on.timeLimit = 60; on.attachMetal()
        var off = SolveContext(); off.metal = .off; off.timeLimit = 60
        let t1 = nowNs()
        let a = try? await Simplex(.primal).solve(lp, context: on)
        let e1 = secs(t1)
        let t2 = nowNs()
        let b = try? await Simplex(.primal).solve(lp, context: off)
        let e2 = secs(t2)
        print("METAL E2E transport primal forced: \(a.map { statusName($0.status) } ?? "-") obj=\(f(a?.objectiveValue)) it=\(a?.iterations ?? -1) t=\(String(format: "%.2f", e1)) warnings=\(a?.warnings ?? []) | off: \(b.map { statusName($0.status) } ?? "-") obj=\(f(b?.objectiveValue)) it=\(b?.iterations ?? -1) t=\(String(format: "%.2f", e2))")
    }
}
