import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Exact optimum of a 2-variable integer program by scanning x and solving y analytically.
/// Integer data only. Returns nil when infeasible; otherwise the best internal objective.
func exact2(_ lp: CompiledLP) -> (Int64, Int64, Int64)? {   // (bestInternalNoConstant, x, y)
    precondition(lp.n == 2)
    let xl = Int64(lp.xl[0]), xu = Int64(lp.xu[0]), yl = Int64(lp.xl[1]), yu = Int64(lp.xu[1])
    var rows = [(Int64, Int64, Double, Double)]()   // a, b, rl, ru
    var coef = [[Int64]](repeating: [0, 0], count: lp.m)
    for j in 0..<2 {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { coef[Int(lp.a.rowIndex[p])][j] = Int64(lp.a.values[p]) }
    }
    for i in 0..<lp.m { rows.append((coef[i][0], coef[i][1], lp.rl[i], lp.ru[i])) }
    let cx = Int64(lp.c[0]), cy = Int64(lp.c[1])
    var best: (Int64, Int64, Int64)? = nil
    func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { let q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q }
    func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }
    var x = xl
    while x <= xu {
        var lo = yl, hi = yu
        var ok = true
        for (a, b, rl, ru) in rows {
            // rl <= a x + b y <= ru, rl/ru integral or infinite
            let ax = a * x
            if b == 0 {
                let v = Double(ax)
                if v < rl || v > ru { ok = false; break }
                continue
            }
            if ru.isFinite {
                let r = Int64(ru) - ax   // b y <= r
                if b > 0 { hi = min(hi, floorDiv(r, b)) } else { lo = max(lo, ceilDiv(r, b)) }
            }
            if rl.isFinite {
                let r = Int64(rl) - ax   // b y >= r
                if b > 0 { lo = max(lo, ceilDiv(r, b)) } else { hi = min(hi, floorDiv(r, b)) }
            }
            if lo > hi { ok = false; break }
        }
        if ok && lo <= hi {
            let y = cy >= 0 ? lo : hi
            let v = cx * x + cy * y
            if best == nil || v < best!.0 { best = (v, x, y) }
        }
        x += 1
    }
    return best
}

func runWide2(count: Int, seed: UInt64, cfg: String, width: Int) async {
    let s = config(cfg).strategy
    var rng = SeededGenerator(seed: seed)
    var bad = 0, feas = 0, infeas = 0, timeouts = 0, gapOnly = 0
    for k in 0..<count {
        let W = Int64(width)
        let xl = Double(-Int64(rng.integer(in: 0...Int(W)))), yl = Double(-Int64(rng.integer(in: 0...Int(W))))
        let xu = xl + Double(rng.integer(in: Int(W)...Int(2 * W))), yu = yl + Double(rng.integer(in: Int(W)...Int(2 * W)))
        let m = rng.integer(in: 1...3)
        var rows: [[(Int, Double)]] = []
        var rl = [Double](), ru = [Double]()
        for _ in 0..<m {
            var a = Double(rng.integer(in: -9...9)), b = Double(rng.integer(in: -9...9))
            if a == 0 && b == 0 { a = 1; b = 3 }
            rows.append([(0, a), (1, b)])
            let amin = min(a * xl, a * xu) + min(b * yl, b * yu), amax = max(a * xl, a * xu) + max(b * yl, b * yu)
            let u = (amin + (amax - amin) * rng.uniform()).rounded(), v = (amin + (amax - amin) * rng.uniform()).rounded()
            switch rng.integer(in: 0...3) {
            case 0: rl.append(-.infinity); ru.append(u)
            case 1: rl.append(u); ru.append(.infinity)
            case 2: rl.append(min(u, v)); ru.append(max(u, v))
            default: rl.append(u); ru.append(u)
            }
        }
        let c = [Double(rng.integer(in: -9...9)), Double(rng.integer(in: -9...9))]
        let lp = makeLP(n: 2, rows: rows, rl: rl, ru: ru, c: c, xl: [xl, yl], xu: [xu, yu])
        let truth = exact2(lp)
        let r = await trySolve(s, lp, limit: 20)
        guard case .success(let a) = r else { print("k=\(k) \(describe(r))"); bad += 1; continue }
        if let t = truth {
            feas += 1
            if a.status == .optimal, let obj = a.objectiveValue, let x = a.primal {
                let viol = pointViolation(lp, x)
                let diff = obj - Double(t.0)
                let allowed = max(1e-6, 1e-4 * max(1, abs(obj)))
                let b = a.bound ?? .nan
                if viol > 0 || diff < 0 || diff > allowed || !(b <= Double(t.0)) {
                    print("k=\(k) WRONG obj=\(obj) bound=\(b) truth=\(t.0) at (\(t.1),\(t.2)) x=\(x) viol=\(viol) allowed=\(allowed) rows=\(rows) rl=\(rl) ru=\(ru) c=\(c) bounds=\([xl, xu, yl, yu])"); bad += 1
                } else if diff > 0 {
                    gapOnly += 1
                    if gapOnly <= 3 { print("k=\(k) within-gap obj=\(obj) bound=\(b) truth=\(t.0) diff=\(diff) allowed=\(allowed)") }
                }
            } else if case .noSolution = a.status { timeouts += 1 } else if case .feasible = a.status { timeouts += 1; print("k=\(k) feasible-stop obj=\(a.objectiveValue!) truth=\(t.0)") } else {
                print("k=\(k) status \(statusString(a.status)) truth=\(t.0)"); bad += 1
            }
        } else {
            infeas += 1
            if a.status != .infeasible {
                if case .noSolution = a.status { timeouts += 1; print("k=\(k) infeasible model: noSolution (limit)"); continue }
                print("k=\(k) expected infeasible, got \(describe(r))"); bad += 1
            }
        }
    }
    print("wide2 cfg=\(cfg) width=\(width) seed=\(seed) count=\(count): feasible=\(feas) infeasible=\(infeas) bad=\(bad) withinGapNotOptimal=\(gapOnly) timeouts=\(timeouts)")
}

/// Mid-size binary/small-integer models against enumeration, optionally under a tight memory budget
/// and with random primal-point hints.
func runMid(count: Int, seed: UInt64, cfg: String, budget: Int?, hints: Bool) async {
    let s = config(cfg).strategy
    var rng = SeededGenerator(seed: seed)
    var bad = 0, feas = 0, infeas = 0, timeouts = 0
    for k in 0..<count {
        let n = rng.integer(in: 12...16)
        let xl = (0..<n).map { _ in Double(rng.integer(in: -1...0)) }
        let xu = xl.map { $0 + Double(rng.integer(in: 1...2)) }
        let m = rng.integer(in: 3...7)
        var rows: [[(Int, Double)]] = []
        var rl = [Double](), ru = [Double]()
        for _ in 0..<m {
            var r: [(Int, Double)] = []
            for j in 0..<n where rng.chance(0.5) { r.append((j, Double(rng.integer(in: -7...7)))) }
            if r.isEmpty { r.append((0, 1)) }
            var amin = 0.0, amax = 0.0
            for (j, a) in r { amin += min(a * xl[j], a * xu[j]); amax += max(a * xl[j], a * xu[j]) }
            let u = (amin + (amax - amin) * rng.uniform(in: 0.2...0.8)).rounded()
            switch rng.integer(in: 0...2) {
            case 0: rl.append(-.infinity); ru.append(u)
            case 1: rl.append(u); ru.append(.infinity)
            default: rl.append(u - Double(rng.integer(in: 0...3))); ru.append(u)
            }
            rows.append(r)
        }
        let c = (0..<n).map { _ in Double(rng.integer(in: -20...20)) }
        let lp = makeLP(n: n, rows: rows, rl: rl, ru: ru, c: c, c0: 0, sense: rng.chance(0.5) ? .maximize : .minimize, xl: xl, xu: xu)
        // for maximize, c given is the minimization form already (fine for a random test)
        let truth = enumerate(lp)
        var context = ctx(30)
        context.memoryBudgetBytes = budget
        if hints { context.warmStart = .primalPoint((0..<n).map { _ in Double(rng.integer(in: -3...3)) }) }
        let a: CPSATAnalysis
        do { a = try await s.solve(lp, context: context) } catch { print("k=\(k) THROW \(error)"); bad += 1; continue }
        if truth.feasibleCount == 0 {
            infeas += 1
            if a.status != .infeasible {
                if case .noSolution(let r) = a.status { timeouts += 1; print("k=\(k) noSolution(\(r))"); continue }
                print("k=\(k) expected infeasible got \(statusString(a.status))"); bad += 1
            }
            continue
        }
        feas += 1
        let best = lp.reportedObjective(truth.bestInternal)
        guard a.status == .optimal, let obj = a.objectiveValue, let x = a.primal else {
            if case .feasible(let r) = a.status { timeouts += 1; print("k=\(k) feasible(\(r)) obj=\(a.objectiveValue!) best=\(best)"); continue }
            if case .noSolution(let r) = a.status { timeouts += 1; print("k=\(k) noSolution(\(r))"); continue }
            print("k=\(k) expected optimal \(best), got \(statusString(a.status))"); bad += 1; continue
        }
        if abs(obj - best) > 1e-9 || pointViolation(lp, x) > 1e-9 { print("k=\(k) WRONG obj=\(obj) best=\(best) viol=\(pointViolation(lp, x))"); bad += 1 }
    }
    print("mid cfg=\(cfg) budget=\(budget.map(String.init) ?? "nil") hints=\(hints) seed=\(seed) count=\(count): feasible=\(feas) infeasible=\(infeas) bad=\(bad) stopped=\(timeouts)")
}
