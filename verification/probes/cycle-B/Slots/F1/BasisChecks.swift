// Postsolved basis oracle: the basis a presolved Simplex solve returns must be a basis of the
// ORIGINAL problem that is consistent with the returned primal point, and must restart the
// unpresolved simplex at an optimal vertex.
import Foundation
import ZTronLPOptimizer

func basisViolations(_ lp: CompiledLP, _ b: Basis, x: [Double], tol: Double = 1e-6) -> [String] {
    var bad: [String] = []
    let n = lp.n, m = lp.m
    guard b.status.count == n + m else { return ["status has \(b.status.count) entries, n+m=\(n + m)"] }
    let basicCount = b.status.filter { $0 == .basic }.count
    if basicCount != m { bad.append("\(basicCount) basic statuses for m=\(m) rows") }
    if b.basic.count != m { bad.append("basic list has \(b.basic.count) entries for m=\(m)") }
    if Set(b.basic).count != b.basic.count { bad.append("basic list has duplicates") }
    for k in b.basic where Int(k) >= n + m || b.status[Int(k)] != .basic { bad.append("basic list entry \(k) not basic"); break }
    let r = activity(lp, x)
    for k in 0..<(n + m) {
        let (v, lo, hi) = k < n ? (x[k], lp.xl[k], lp.xu[k]) : (r[k - n], lp.rl[k - n], lp.ru[k - n])
        let t = tol * (1 + abs(v))
        switch b.status[k] {
        case .atLower: if !(lo > -.infinity && abs(v - lo) <= t) { bad.append("\(k < n ? "col" : "row") \(k < n ? k : k - n) atLower but value \(v), lower \(lo)") }
        case .atUpper: if !(hi < .infinity && abs(v - hi) <= t) { bad.append("\(k < n ? "col" : "row") \(k < n ? k : k - n) atUpper but value \(v), upper \(hi)") }
        case .fixed: if !(lo == hi && abs(v - lo) <= t) { bad.append("\(k < n ? "col" : "row") \(k < n ? k : k - n) fixed but bounds [\(lo),\(hi)] value \(v)") }
        case .free: if !(lo == -.infinity && hi == .infinity) { bad.append("\(k < n ? "col" : "row") \(k < n ? k : k - n) free but bounds [\(lo),\(hi)]") }
        case .basic: break
        }
    }
    return bad
}

func runBasis(from: Int, count: Int) async {
    var failures = 0, checked = 0, restartIters = 0, restartMax = 0
    for s in from..<(from + count) {
        var o = GenOptions(); o.boundedOnly = true
        let (lp, _) = randomLP(seed: UInt64(s), o)
        for (name, strat) in [("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("dual-noscale", Simplex(.dual, scaling: .none))] {
            guard let r = try? await strat.solve(lp, context: ctx(10)), r.status == .optimal, let x = r.primal else { continue }
            checked += 1
            let v = basisViolations(lp, r.basis, x: x)
            if !v.isEmpty { failures += 1; if failures <= 12 { print("seed \(s) \(name): basis \(v.prefix(3))"); print(describeLP(lp)); print(" x=\(x) status=\(r.basis.status)") } }
            // restart the unpresolved, unscaled simplex from that basis
            var c = ctx(10); c.warmStart = .basis(r.basis)
            if let w = try? await Simplex(.dual, presolve: false, scaling: .none).solve(lp, context: c) {
                restartIters += w.iterations; restartMax = max(restartMax, w.iterations)
                if w.status != .optimal || abs((w.objectiveValue ?? .nan) - (r.objectiveValue ?? .nan)) > 1e-7 * (1 + abs(r.objectiveValue ?? 0)) {
                    failures += 1; print("seed \(s) \(name): warm restart from the postsolved basis gives \(statusName(w.status)) \(w.objectiveValue ?? .nan) vs \(r.objectiveValue ?? .nan)")
                }
            }
        }
    }
    print("basis done seeds \(from)..<\(from + count): checked=\(checked) failures=\(failures) restart iterations total=\(restartIters) max=\(restartMax)")
}
