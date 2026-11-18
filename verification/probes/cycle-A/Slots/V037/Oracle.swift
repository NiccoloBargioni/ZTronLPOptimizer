// V037: an oracle independent of the finder's. It never uses the generator's objective or
// CompiledLP.maxViolation: row activities are recomputed here with compensated (Neumaier)
// summation, and the optimum is certified by weak duality from the constructed (x, y):
// d = c - Aᵀy recomputed here, every multiplier checked to sit on a finite bound of the
// right side, and the dual objective D compared with the primal objective P at x.
import Foundation
import ZTronLPOptimizer

struct Acc {
    var s = 0.0, comp = 0.0, mag = 0.0
    mutating func add(_ v: Double) {
        let t = s + v
        if abs(s) >= abs(v) { comp += (s - t) + v } else { comp += (v - t) + s }
        s = t
        mag += abs(v)
    }
    var value: Double { s + comp }
}

/// Row activities (compensated) and Σ|a_ij x_j| per row.
func activities(_ lp: CompiledLP, _ x: [Double]) -> (act: [Double], mag: [Double]) {
    var acc = [Acc](repeating: Acc(), count: lp.m)
    let a = lp.a
    for j in 0..<lp.n {
        for p in a.colStart[j]..<a.colStart[j + 1] { acc[Int(a.rowIndex[p])].add(a.values[p] * x[j]) }
    }
    return (acc.map { $0.value }, acc.map { $0.mag })
}

struct Violation {
    var rowAbs = 0.0, rowRel = 0.0, boundAbs = 0.0, boundRel = 0.0
    var worstRow = -1, worstRowMag = 0.0, worstRowActivity = 0.0, worstRowLo = 0.0, worstRowHi = 0.0
}

/// Absolute violation, and violation relative to max(1, Σ|a_ij x_j|, |bound|) for rows and
/// max(1, |bound|) for columns.
func violation(_ lp: CompiledLP, _ x: [Double]) -> Violation {
    var v = Violation()
    let (act, mag) = activities(lp, x)
    for i in 0..<lp.m {
        let lo = lp.rl[i], hi = lp.ru[i]
        var e = 0.0, ref = max(1, mag[i])
        if lo.isFinite, act[i] < lo { e = lo - act[i]; ref = max(ref, abs(lo)) }
        if hi.isFinite, act[i] > hi { e = act[i] - hi; ref = max(ref, abs(hi)) }
        if e > v.rowAbs {
            v.rowAbs = e; v.worstRow = i; v.worstRowMag = mag[i]; v.worstRowActivity = act[i]
            v.worstRowLo = lo; v.worstRowHi = hi
        }
        v.rowRel = max(v.rowRel, e / ref)
    }
    for j in 0..<lp.n {
        var e = 0.0, ref = 1.0
        if lp.xl[j].isFinite, x[j] < lp.xl[j] { e = lp.xl[j] - x[j]; ref = max(1, abs(lp.xl[j])) }
        if lp.xu[j].isFinite, x[j] > lp.xu[j] { e = x[j] - lp.xu[j]; ref = max(1, abs(lp.xu[j])) }
        v.boundAbs = max(v.boundAbs, e)
        v.boundRel = max(v.boundRel, e / ref)
    }
    return v
}

/// cᵀx + c0 in the model's sense (c is stored for minimization).
func modelObjective(_ lp: CompiledLP, _ x: [Double]) -> Double {
    var acc = Acc()
    acc.add(lp.c0)
    for j in 0..<lp.n { acc.add(lp.c[j] * x[j]) }
    return lp.sense == .maximize ? -acc.value : acc.value
}

struct Certificate {
    var primalObjective = 0.0    // model sense, at the constructed x
    var dualObjective = 0.0      // model sense, weak-duality bound from (y, d)
    var primalViolationRel = 0.0
    var badSigns = 0             // multipliers on an infinite bound (beyond noise)
    var noiseOnInfinite = 0.0    // largest |d_j| treated as rounding noise on an infinite side
    var valid: Bool { badSigns == 0 && primalViolationRel <= 1e-12
        && abs(primalObjective - dualObjective) <= 1e-9 * max(1, abs(primalObjective)) }
}

/// Weak duality, minimization form: for any x' with xl ≤ x' ≤ xu and rl ≤ Ax' ≤ ru,
/// cᵀx' = dᵀx' + yᵀAx' ≥ Σ_j d_j·(d_j > 0 ? xl_j : xu_j) + Σ_i y_i·(y_i > 0 ? rl_i : ru_i).
func certify(_ lp: CompiledLP, x: [Double], yMin: [Double]) -> Certificate {
    var cert = Certificate()
    cert.primalViolationRel = max(violation(lp, x).rowRel, violation(lp, x).boundRel)
    let a = lp.a
    var dual = Acc()
    dual.add(lp.c0)
    for i in 0..<lp.m where yMin[i] != 0 {
        let b = yMin[i] > 0 ? lp.rl[i] : lp.ru[i]
        if b.isFinite { dual.add(yMin[i] * b) } else { cert.badSigns += 1 }
    }
    for j in 0..<lp.n {
        var dj = Acc()
        dj.add(lp.c[j])
        for p in a.colStart[j]..<a.colStart[j + 1] { dj.add(-a.values[p] * yMin[Int(a.rowIndex[p])]) }
        let value = dj.value
        let noise = 1e-13 * max(dj.mag, 1e-300)
        if abs(value) <= noise {
            if value != 0 { cert.noiseOnInfinite = max(cert.noiseOnInfinite, abs(value)) }
            // contributes d_j·x'_j, |d_j| below rounding of its own terms: counted at x
            dual.add(value * x[j])
            continue
        }
        let b = value > 0 ? lp.xl[j] : lp.xu[j]
        if b.isFinite { dual.add(value * b) } else { cert.badSigns += 1 }
    }
    let p = modelObjective(lp, x)
    cert.primalObjective = p
    cert.dualObjective = lp.sense == .maximize ? -dual.value : dual.value
    return cert
}

/// Farkas check of a row ray r (r_i > 0 pairs with rl_i): lower bound of rᵀAx over the rows
/// minus upper bound of (Aᵀr)ᵀx over the column bounds, divided by ‖r‖∞. Positive certifies.
func farkas(_ lp: CompiledLP, _ r: [Double]) -> Double {
    let scale = r.map { abs($0) }.max() ?? 0
    guard scale > 0 else { return -.infinity }
    var value = Acc()
    for i in 0..<lp.m where r[i] != 0 {
        let b = r[i] > 0 ? lp.rl[i] : lp.ru[i]
        if b.isFinite { value.add(r[i] * b) } else if abs(r[i]) > 1e-9 * scale { return -.infinity }
    }
    let z = lp.a.multiplyTranspose(r)
    let zs = max(z.map { abs($0) }.max() ?? 0, scale)
    for j in 0..<lp.n where z[j] != 0 {
        let b = z[j] > 0 ? lp.xu[j] : lp.xl[j]
        if b.isFinite { value.add(-z[j] * b) } else if abs(z[j]) > 1e-9 * zs { return -.infinity }
    }
    return value.value / scale
}

func e(_ v: Double) -> String { String(format: "%.3e", v) }
