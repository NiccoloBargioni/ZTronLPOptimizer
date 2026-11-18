// Cycle A, F2 probe helpers: an independent KKT-constructed LP generator and independent
// checkers of optimality certificates, Farkas rays and primal rays.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func u(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
    mutating func chance(_ p: Double) -> Bool { u() < p }
}

struct KKTInstance {
    let lp: CompiledLP
    let x: [Double]
    let yMin: [Double]
    let objective: Double   // in the model's sense
    let label: String
}

/// Builds an LP for which (x, y) satisfies the KKT conditions by construction. Column kinds:
/// at lower, at upper, strictly between, free, fixed, negative (upper 0 / -inf lower).
/// Row kinds: equality, active at lower, active at upper, ranged active, inactive, free.
/// `degenerate` adds zero duals on active rows and zero reduced costs on nonbasic columns
/// (alternative optima), plus basic-at-bound columns.
func makeKKT(m: Int, n: Int, seed: UInt64, maximize: Bool, degenerate: Bool, density: Double = 0.3,
             scaleSpread: Double = 0, integral: Bool = false) -> KKTInstance {
    var r = Rng(seed)
    func val() -> Double {
        if integral { return Double(r.int(-4, 4)) }
        return (r.u(-1, 1) * 1000).rounded() / 1000
    }
    var entries: [(row: Int, col: Int, value: Double)] = []
    let rowScale = (0..<m).map { _ in pow(10, r.u(-scaleSpread, scaleSpread)) }
    let colScale = (0..<n).map { _ in pow(10, r.u(-scaleSpread, scaleSpread)) }
    for i in 0..<m {
        for j in 0..<n where r.chance(density) {
            var v = val()
            if v == 0 { v = 0.5 }
            entries.append((i, j, v * rowScale[i] * colScale[j]))
        }
    }
    // Make sure every column and row has an entry most of the time.
    for j in 0..<n where !entries.contains(where: { $0.col == j }) && r.chance(0.9) {
        entries.append((r.int(0, m - 1), j, (val() + 2) * colScale[j]))
    }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    var x = [Double](repeating: 0, count: n)
    var xl = [Double](repeating: 0, count: n)
    var xu = [Double](repeating: 0, count: n)
    var d = [Double](repeating: 0, count: n)
    let pDeg = degenerate ? 0.35 : 0.0
    for j in 0..<n {
        let kind = r.int(0, 9)
        let mag = 1.0 / colScale[j]
        switch kind {
        case 0, 1, 2:   // at lower
            xl[j] = r.chance(0.5) ? 0 : (r.u(-5, 5) * mag)
            xu[j] = r.chance(0.5) ? .infinity : xl[j] + r.u(0.5, 6) * mag
            x[j] = xl[j]
            d[j] = r.chance(pDeg) ? 0 : r.u(0.1, 3)
        case 3, 4:      // at upper
            xu[j] = r.u(-5, 5) * mag
            xl[j] = r.chance(0.4) ? -.infinity : xu[j] - r.u(0.5, 6) * mag
            x[j] = xu[j]
            d[j] = r.chance(pDeg) ? 0 : -r.u(0.1, 3)
        case 5, 6:      // strictly between
            xl[j] = r.chance(0.3) ? -.infinity : r.u(-5, 0) * mag
            xu[j] = r.chance(0.3) ? .infinity : r.u(0.5, 5) * mag
            let lo = xl[j].isFinite ? xl[j] : -6 * mag
            let hi = xu[j].isFinite ? xu[j] : 6 * mag
            x[j] = lo + (hi - lo) * r.u(0.2, 0.8)
            d[j] = 0
        case 7:         // free
            xl[j] = -.infinity; xu[j] = .infinity
            x[j] = r.u(-4, 4) * mag
            d[j] = 0
        case 8:         // fixed
            xl[j] = r.u(-3, 3) * mag; xu[j] = xl[j]; x[j] = xl[j]
            d[j] = r.u(-2, 2)
        default:        // negative column: (-inf, 0] at its upper bound, or basic below 0
            xl[j] = -.infinity; xu[j] = 0
            if r.chance(0.5) { x[j] = 0; d[j] = r.chance(pDeg) ? 0 : -r.u(0.1, 3) }
            else { x[j] = -r.u(0.5, 4) * mag; d[j] = 0 }
        }
        // basic-at-bound degeneracy: a column at its bound with d = 0 is fine already.
    }
    let act = a.multiply(x)
    var rl = [Double](repeating: 0, count: m)
    var ru = [Double](repeating: 0, count: m)
    var y = [Double](repeating: 0, count: m)
    for i in 0..<m {
        let kind = r.int(0, 9)
        let s = act[i]
        let mag = rowScale[i]
        switch kind {
        case 0, 1:      // equality
            rl[i] = s; ru[i] = s
            y[i] = r.chance(pDeg) ? 0 : r.u(-2, 2)
        case 2, 3:      // active at lower
            rl[i] = s; ru[i] = r.chance(0.6) ? .infinity : s + r.u(0.5, 4) * mag
            y[i] = r.chance(pDeg) ? 0 : r.u(0.1, 2)
        case 4, 5:      // active at upper
            ru[i] = s; rl[i] = r.chance(0.6) ? -.infinity : s - r.u(0.5, 4) * mag
            y[i] = r.chance(pDeg) ? 0 : -r.u(0.1, 2)
        case 6, 7:      // inactive (ranged or one-sided)
            rl[i] = r.chance(0.3) ? -.infinity : s - r.u(0.2, 3) * mag
            ru[i] = r.chance(0.3) ? .infinity : s + r.u(0.2, 3) * mag
            y[i] = 0
        case 8:         // degenerate: active with zero dual
            rl[i] = s; ru[i] = r.chance(0.5) ? .infinity : s + r.u(0.5, 3) * mag
            y[i] = 0
        default:        // free row
            rl[i] = -.infinity; ru[i] = .infinity; y[i] = 0
        }
        y[i] /= rowScale[i]
    }
    // c = d + Aᵀy (minimization form)
    let aty = a.multiplyTranspose(y)
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = d[j] / colScale[j] + aty[j] }
    let c0 = (r.u(-10, 10) * 100).rounded() / 100
    let lp = CompiledLP(a: a, c: c, c0: c0, sense: maximize ? .maximize : .minimize,
                        xl: xl, xu: xu, rl: rl, ru: ru)
    var obj = c0
    for j in 0..<n { obj += c[j] * x[j] }
    let reported = maximize ? -obj : obj
    return KKTInstance(lp: lp, x: x, yMin: y, objective: reported,
                       label: "kkt m\(m) n\(n) seed\(seed) max\(maximize) deg\(degenerate) spread\(scaleSpread)")
}

struct OptimalityCheck {
    var objectiveError = 0.0   // relative
    var primalViolation = 0.0  // absolute, max over bounds and rows (unscaled)
    var dualSignViolation = 0.0 // relative to the duals' scale
    var logicalMismatch = 0.0
    var reducedCostMismatch = 0.0
    var gap = 0.0
    var missing = ""
}

/// Independent check of an optimal analysis: primal feasibility, dual sign conditions against
/// the returned point (complementary slackness), the duality gap, and the documented
/// conventions (dual = sensitivity of the reported objective, logical reduced cost = dual).
func checkOptimal(_ lp: CompiledLP, _ an: any SolutionAnalysis, expected: Double?) -> OptimalityCheck {
    var out = OptimalityCheck()
    guard let x = an.primal else { out.missing = "primal"; return out }
    if let expected, let o = an.objectiveValue {
        out.objectiveError = abs(o - expected) / max(1, abs(expected))
    } else if expected != nil { out.missing += "objective " }
    let v = lp.maxViolation(at: x)
    out.primalViolation = max(v.bounds, v.rows)
    guard let dual = an.dual, let rc = an.reducedCosts else { out.missing += "duals"; return out }
    let flip: Double = lp.sense == .maximize ? -1 : 1
    let y = dual.map { flip * $0 }
    let dRet = rc.map { flip * $0 }
    let n = lp.n, m = lp.m
    // reduced costs recomputed independently
    var d = lp.c
    let a = lp.a
    for j in 0..<n {
        for p in a.colStart[j]..<a.colStart[j + 1] { d[j] -= a.values[p] * y[Int(a.rowIndex[p])] }
    }
    let yScale = max(1, y.map { abs($0) }.max() ?? 0, lp.c.map { abs($0) }.max() ?? 0)
    for j in 0..<n { out.reducedCostMismatch = max(out.reducedCostMismatch, abs(d[j] - dRet[j]) / yScale) }
    if rc.count == n + m {
        for i in 0..<m { out.logicalMismatch = max(out.logicalMismatch, abs(dRet[n + i] - y[i]) / yScale) }
    } else { out.missing += "rc-count(\(rc.count)) " }
    let act = lp.rowActivity(x)
    func side(_ value: Double, _ lo: Double, _ hi: Double) -> (Bool, Bool) {
        let tol = 1e-7 * max(1, abs(value))
        return (lo.isFinite && value - lo <= tol, hi.isFinite && hi - value <= tol)
    }
    var worst = 0.0
    for j in 0..<n {
        let (atL, atU) = side(x[j], lp.xl[j], lp.xu[j])
        let dj = d[j] / yScale
        if atL && atU { continue }
        if atL { worst = max(worst, -dj) } else if atU { worst = max(worst, dj) } else { worst = max(worst, abs(dj)) }
    }
    for i in 0..<m {
        let (atL, atU) = side(act[i], lp.rl[i], lp.ru[i])
        let yi = y[i] / yScale
        if atL && atU { continue }
        if atL { worst = max(worst, -yi) } else if atU { worst = max(worst, yi) } else { worst = max(worst, abs(yi)) }
    }
    out.dualSignViolation = worst
    // duality gap: P - D with D the dual objective of (y, d) with tiny multipliers dropped
    var P = lp.c0
    for j in 0..<n { P += lp.c[j] * x[j] }
    var D = lp.c0
    let tiny = 1e-9 * yScale
    var dualInf = false
    for i in 0..<m where abs(y[i]) > tiny {
        let b = y[i] > 0 ? lp.rl[i] : lp.ru[i]
        if !b.isFinite { dualInf = true } else { D += y[i] * b }
    }
    for j in 0..<n where abs(d[j]) > tiny {
        let b = d[j] > 0 ? lp.xl[j] : lp.xu[j]
        if !b.isFinite { dualInf = true } else { D += d[j] * b }
    }
    out.gap = dualInf ? .infinity : abs(P - D) / max(1, abs(P))
    return out
}

/// Farkas certificate check over rows: with z = Aᵀr, min over row bounds of rᵀs minus max
/// over column bounds of zᵀx, normalised by ‖r‖∞·(1+‖bounds‖). Positive means infeasibility
/// is certified. Entries below 1e-9·‖r‖∞ are ignored on infinite bounds only.
func farkasMargin(_ lp: CompiledLP, _ r: [Double]) -> Double {
    let scale = r.map { abs($0) }.max() ?? 0
    guard scale > 0 else { return -.infinity }
    let ignore = 1e-9 * scale
    var value = 0.0
    for i in 0..<lp.m where r[i] != 0 {
        let b = r[i] > 0 ? lp.rl[i] : lp.ru[i]
        if !b.isFinite { if abs(r[i]) > ignore { return -.infinity } else { continue } }
        value += r[i] * b
    }
    let z = lp.a.multiplyTranspose(r)
    let zScale = max(z.map { abs($0) }.max() ?? 0, scale)
    for j in 0..<lp.n where z[j] != 0 {
        let b = z[j] > 0 ? lp.xu[j] : lp.xl[j]
        if !b.isFinite { if abs(z[j]) > 1e-9 * zScale { return -.infinity } else { continue } }
        value -= z[j] * b
    }
    return value / scale
}

/// Primal ray check (minimization form): recession directions of the bounds and rows within
/// 1e-9 relative, and a strictly improving slope. Returns the normalised slope (negative is
/// good) and the worst recession violation.
func rayCheck(_ lp: CompiledLP, _ v: [Double]) -> (slope: Double, violation: Double) {
    let scale = v.map { abs($0) }.max() ?? 0
    guard scale > 0 else { return (0, .infinity) }
    var viol = 0.0
    for j in 0..<lp.n {
        if lp.xu[j].isFinite { viol = max(viol, v[j] / scale) }
        if lp.xl[j].isFinite { viol = max(viol, -v[j] / scale) }
    }
    let av = lp.a.multiply(v)
    for i in 0..<lp.m {
        if lp.ru[i].isFinite { viol = max(viol, av[i] / scale) }
        if lp.rl[i].isFinite { viol = max(viol, -av[i] / scale) }
    }
    var slope = 0.0
    for j in 0..<lp.n { slope += lp.c[j] * v[j] }
    return (slope / scale, viol)
}

func statusName(_ s: SolveStatus) -> String { "\(s)" }

struct Config {
    let name: String
    let s: Simplex
}

/// The configuration grid: method × factorization × presolve × scaling with default pricing
/// and perturbation, then pricing and perturbation variants.
func configGrid(full: Bool = true) -> [Config] {
    var out: [Config] = []
    let facts: [(String, Simplex.Factorization)] = [("auto", .automatic), ("dense", .denseLU), ("qr", .sparseQR)]
    let scs: [(String, ScalingMode)] = [("none", .none), ("eq", .equilibration), ("geo", .geometricEquilibration)]
    for method in [Simplex.Method.primal, .dual] {
        for (fn, f) in facts {
            for pre in [true, false] {
                for (sn, sc) in scs where full || sn != "eq" {
                    out.append(Config(name: "\(method)/\(fn)/pre\(pre)/\(sn)",
                                      s: Simplex(method, factorization: f, presolve: pre, scaling: sc)))
                }
            }
        }
    }
    let pricings: [(String, Simplex.Pricing)] = [("dantzig", .dantzig), ("steep", .steepestEdge), ("partial3", .partial(sections: 3))]
    for (pn, p) in pricings {
        for pre in [true, false] {
            out.append(Config(name: "primal/\(pn)/pre\(pre)", s: Simplex(.primal, pricing: p, presolve: pre)))
        }
    }
    let perts: [(String, Simplex.Perturbation)] = [("off", .off), ("always", .always)]
    for method in [Simplex.Method.primal, .dual] {
        for (pn, p) in perts {
            out.append(Config(name: "\(method)/pert-\(pn)", s: Simplex(method, perturbation: p)))
            out.append(Config(name: "\(method)/pert-\(pn)/qr/nopre", s: Simplex(method, factorization: .sparseQR, perturbation: p, presolve: false)))
        }
    }
    var tight = Tolerances()
    tight.primalFeasibility = 1e-9
    tight.dualFeasibility = 1e-9
    for method in [Simplex.Method.primal, .dual] {
        out.append(Config(name: "\(method)/tol1e-9", s: Simplex(method, tolerances: tight)))
    }
    return out
}

func ctx(_ seconds: Double = 20, warm: WarmStart = .none) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.metal = .off
    c.warmStart = warm
    return c
}

func fmt(_ v: Double) -> String { String(format: "%.2e", v) }
