// Independent oracles for cycle B, area F2 (simplex). Nothing here calls package helpers to
// judge a result: activities, reduced costs, dual objective and certificates are recomputed
// from the dense data of the model.
import Foundation
import ZTronLPOptimizer

// MARK: - RNG (splitmix64, own implementation)
struct RNG: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x0123_4567_89AB_CDEF }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func u(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
    mutating func chance(_ p: Double) -> Bool { u() < p }
}

// MARK: - Dense LP in the model's own sense
struct LP {
    var m: Int
    var n: Int
    var A: [[Double]]
    var c: [Double]          // model sense
    var c0: Double = 0
    var maximize = false
    var xl: [Double]
    var xu: [Double]
    var rl: [Double]
    var ru: [Double]

    func compiled() -> CompiledLP {
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { for j in 0..<n where A[i][j] != 0 { entries.append((i, j, A[i][j])) } }
        let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
        let cm = maximize ? c.map { $0 == 0 ? 0 : -$0 } : c
        return CompiledLP(
            a: a, c: cm, c0: maximize ? (c0 == 0 ? 0 : -c0) : c0, sense: maximize ? .maximize : .minimize,
            xl: xl, xu: xu, rl: rl, ru: ru)
    }

    static func from(_ p: CompiledLP) -> LP {
        var A = [[Double]](repeating: [Double](repeating: 0, count: p.n), count: p.m)
        for j in 0..<p.n {
            for q in p.a.colStart[j]..<p.a.colStart[j + 1] { A[Int(p.a.rowIndex[q])][j] = p.a.values[q] }
        }
        let mx = p.sense == .maximize
        return LP(
            m: p.m, n: p.n, A: A, c: mx ? p.c.map { -$0 } : p.c, c0: mx ? -p.c0 : p.c0, maximize: mx,
            xl: p.xl, xu: p.xu, rl: p.rl, ru: p.ru)
    }

    func activity(_ x: [Double]) -> [Double] {
        (0..<m).map { i in
            var s = 0.0
            for j in 0..<n where A[i][j] != 0 { s += A[i][j] * x[j] }
            return s
        }
    }
    func objective(_ x: [Double]) -> Double {
        var s = c0
        for j in 0..<n { s += c[j] * x[j] }
        return s
    }
    /// Max violation of bounds and rows, each relative to 1 + |bound|.
    func primalViolation(_ x: [Double]) -> Double {
        var v = 0.0
        for j in 0..<n {
            if xl[j] > -.infinity { v = max(v, (xl[j] - x[j]) / (1 + abs(xl[j]))) }
            if xu[j] < .infinity { v = max(v, (x[j] - xu[j]) / (1 + abs(xu[j]))) }
            if !x[j].isFinite { v = .infinity }
        }
        let s = activity(x)
        for i in 0..<m {
            if rl[i] > -.infinity { v = max(v, (rl[i] - s[i]) / (1 + abs(rl[i]))) }
            if ru[i] < .infinity { v = max(v, (s[i] - ru[i]) / (1 + abs(ru[i]))) }
        }
        return v
    }
}

// MARK: - KKT oracle

struct KKT: CustomStringConvertible {
    var primal = 0.0      // relative primal violation
    var dual = 0.0        // dual-sign violation, relative to 1 + max|c|
    var comp = 0.0        // largest complementarity product, relative to 1 + |obj|
    var dcons = 0.0       // |returned d - (c - A^T y)|, relative to 1 + max|c|
    var gap = 0.0         // |P - D| / (1 + |P|)
    var objErr = 0.0      // |obj - ref| / max(1, |ref|)
    var repObjErr = 0.0   // |reported objectiveValue - objective(x)| / max(1,|.|)
    var signNote = ""
    var description: String {
        String(
            format: "pv=%.1e dv=%.1e cs=%.1e dc=%.1e gap=%.1e objErr=%.1e repErr=%.1e%@", primal, dual, comp, dcons,
            gap, objErr, repObjErr, signNote.isEmpty ? "" : " " + signNote)
    }
    func ok(_ t: Double = 1e-6) -> Bool {
        primal <= t && dual <= t && comp <= t && dcons <= t && gap <= t && objErr <= t && repObjErr <= t
    }
}

/// y and d in the reported (model) sense, as SolutionAnalysis returns them.
func checkKKT(_ lp: LP, x: [Double], yRep: [Double]?, dRep: [Double]?, reported: Double?, ref: Double?) -> KKT {
    var k = KKT()
    let P = lp.objective(x)
    k.primal = lp.primalViolation(x)
    if let ref { k.objErr = abs(P - ref) / max(1, abs(ref)) }
    if let reported { k.repObjErr = abs(reported - P) / max(1, abs(P)) } else { k.repObjErr = .infinity }
    guard let yRep else {
        k.dual = .infinity
        return k
    }
    let flip = lp.maximize ? -1.0 : 1.0
    let y = yRep.map { flip * $0 }   // minimization form
    let cmin = lp.c.map { flip * $0 }
    var d = cmin
    for j in 0..<lp.n { for i in 0..<lp.m where lp.A[i][j] != 0 { d[j] -= lp.A[i][j] * y[i] } }
    let cScale = 1 + (cmin.map { abs($0) }.max() ?? 0) + (y.map { abs($0) }.max() ?? 0)
    if let dRep {
        if dRep.count != lp.n + lp.m {
            k.dcons = .infinity
            k.signNote += "dcount=\(dRep.count)"
        } else {
            for j in 0..<lp.n { k.dcons = max(k.dcons, abs(flip * dRep[j] - d[j]) / cScale) }
            for i in 0..<lp.m { k.dcons = max(k.dcons, abs(flip * dRep[lp.n + i] - y[i]) / cScale) }
        }
    }
    let s = lp.activity(x)
    let objScale = 1 + abs(P)
    var D = lp.maximize ? -lp.c0 : lp.c0
    // columns
    for j in 0..<lp.n {
        let dp = max(d[j], 0), dm = max(-d[j], 0)
        if dp > 0 {
            if lp.xl[j] == -.infinity { k.dual = max(k.dual, dp / cScale) } else {
                D += dp * lp.xl[j]
                k.comp = max(k.comp, dp * abs(x[j] - lp.xl[j]) / objScale)
            }
        }
        if dm > 0 {
            if lp.xu[j] == .infinity { k.dual = max(k.dual, dm / cScale) } else {
                D -= dm * lp.xu[j]
                k.comp = max(k.comp, dm * abs(lp.xu[j] - x[j]) / objScale)
            }
        }
    }
    for i in 0..<lp.m {
        let yp = max(y[i], 0), ym = max(-y[i], 0)
        if yp > 0 {
            if lp.rl[i] == -.infinity { k.dual = max(k.dual, yp / cScale) } else {
                D += yp * lp.rl[i]
                k.comp = max(k.comp, yp * abs(s[i] - lp.rl[i]) / objScale)
            }
        }
        if ym > 0 {
            if lp.ru[i] == .infinity { k.dual = max(k.dual, ym / cScale) } else {
                D -= ym * lp.ru[i]
                k.comp = max(k.comp, ym * abs(lp.ru[i] - s[i]) / objScale)
            }
        }
    }
    let Pmin = flip * P
    k.gap = abs(Pmin - D) / objScale
    return k
}

// MARK: - Certificates

/// Farkas check for {rl ≤ Ax ≤ ru, xl ≤ x ≤ xu}: for z = Aᵀy, sup over the box of zᵀx must be
/// below inf over the row box of yᵀs. Tries y and −y; returns the margin (positive = proof),
/// normalised by ‖y‖∞·(scale), and which sign worked.
func farkasMargin(_ lp: LP, _ y: [Double]) -> (margin: Double, sign: Double) {
    func margin(_ y: [Double]) -> Double {
        let ymax = y.map { abs($0) }.max() ?? 0
        if ymax == 0 || !ymax.isFinite { return -.infinity }
        // entries at roundoff level (below 1e-11 of the largest) are taken as zero
        let yy = y.map { abs($0) <= 1e-11 * ymax ? 0 : $0 / ymax }
        var z = [Double](repeating: 0, count: lp.n)
        for i in 0..<lp.m where yy[i] != 0 { for j in 0..<lp.n { z[j] += lp.A[i][j] * yy[i] } }
        var U = 0.0   // sup_x z^T x
        for j in 0..<lp.n {
            if abs(z[j]) <= 1e-9 * (1 + abs(z[j])) { continue }
            if z[j] > 0 { if lp.xu[j] == .infinity { return -.infinity } else { U += z[j] * lp.xu[j] } }
            if z[j] < 0 { if lp.xl[j] == -.infinity { return -.infinity } else { U += z[j] * lp.xl[j] } }
        }
        var L = 0.0   // inf_s y^T s
        for i in 0..<lp.m where yy[i] != 0 {
            if yy[i] > 0 { if lp.rl[i] == -.infinity { return -.infinity } else { L += yy[i] * lp.rl[i] } }
            if yy[i] < 0 { if lp.ru[i] == .infinity { return -.infinity } else { L += yy[i] * lp.ru[i] } }
        }
        return (L - U) / (1 + abs(L) + abs(U))
    }
    let a = margin(y), b = margin(y.map { -$0 })
    return a >= b ? (a, 1) : (b, -1)
}

/// Ray check: r must be a recession direction of the feasible set that improves the objective
/// (model sense). Returns (violation of the recession cone relative to ‖r‖∞, improvement per
/// unit of ‖r‖∞ in model sense, positive = improving).
func rayCheck(_ lp: LP, _ r: [Double]) -> (cone: Double, improve: Double) {
    let rmax = r.map { abs($0) }.max() ?? 0
    if rmax == 0 || !rmax.isFinite { return (.infinity, 0) }
    let rr = r.map { $0 / rmax }
    var v = 0.0
    for j in 0..<lp.n {
        if lp.xl[j] > -.infinity { v = max(v, -rr[j]) }
        if lp.xu[j] < .infinity { v = max(v, rr[j]) }
    }
    let ar = lp.activity(rr)
    let aScale = 1 + (lp.A.flatMap { $0 }.map { abs($0) }.max() ?? 0)
    for i in 0..<lp.m {
        if lp.rl[i] > -.infinity { v = max(v, -ar[i] / aScale) }
        if lp.ru[i] < .infinity { v = max(v, ar[i] / aScale) }
    }
    var cr = 0.0
    for j in 0..<lp.n { cr += lp.c[j] * rr[j] }
    let improve = lp.maximize ? cr : -cr
    let cScale = 1 + (lp.c.map { abs($0) }.max() ?? 0)
    return (v, improve / cScale)
}

// MARK: - Configurations

struct Config: CustomStringConvertible {
    var method: Simplex.Method
    var factorization: Simplex.Factorization
    var presolve: Bool
    var scaling: ScalingMode
    var pricing: Simplex.Pricing
    var perturbation: Simplex.Perturbation
    var maxIterations: Int? = nil
    var tolerances: Tolerances = .default
    var simplex: Simplex {
        Simplex(
            method, pricing: pricing, factorization: factorization, perturbation: perturbation,
            maxIterations: maxIterations, presolve: presolve, scaling: scaling, tolerances: tolerances)
    }
    var description: String {
        let f: String
        switch factorization { case .automatic: f = "auto"; case .denseLU: f = "LU"; case .sparseQR: f = "QR" }
        let sc: String
        switch scaling { case .none: sc = "none"; case .equilibration: sc = "eq"; case .geometricEquilibration: sc = "geo" }
        let pr: String
        switch pricing {
        case .dantzig: pr = "dantzig"
        case .devex: pr = "devex"
        case .steepestEdge: pr = "se"
        case .partial(let s): pr = "partial\(s)"
        }
        let pt: String
        switch perturbation { case .off: pt = "off"; case .always: pt = "always"; case .onStall: pt = "onStall" }
        return "\(method == .primal ? "P" : "D")/\(f)/pre=\(presolve ? 1 : 0)/sc=\(sc)/\(pr)/pert=\(pt)"
    }
}

func allConfigs() -> [Config] {
    var out: [Config] = []
    for method in [Simplex.Method.primal, .dual] {
        for f in [Simplex.Factorization.automatic, .denseLU, .sparseQR] {
            for pre in [true, false] {
                for sc in [ScalingMode.none, .equilibration, .geometricEquilibration] {
                    for pr in [Simplex.Pricing.dantzig, .devex, .steepestEdge, .partial(sections: 3)] {
                        for pt in [Simplex.Perturbation.off, .always, .onStall] {
                            out.append(Config(method: method, factorization: f, presolve: pre, scaling: sc, pricing: pr, perturbation: pt))
                        }
                    }
                }
            }
        }
    }
    return out
}

/// method × {auto, QR} × presolve × 3 scalings × {off, onStall}, devex pricing.
func midConfigs() -> [Config] {
    var out: [Config] = []
    for method in [Simplex.Method.primal, .dual] {
        for f in [Simplex.Factorization.automatic, .sparseQR] {
            for pre in [true, false] {
                for sc in [ScalingMode.none, .equilibration, .geometricEquilibration] {
                    for pt in [Simplex.Perturbation.off, .onStall] {
                        out.append(Config(method: method, factorization: f, presolve: pre, scaling: sc, pricing: .devex, perturbation: pt))
                    }
                }
            }
        }
    }
    return out
}

/// A smaller grid: method × factorization × presolve × scaling, default pricing/perturbation.
func coreConfigs() -> [Config] {
    var out: [Config] = []
    for method in [Simplex.Method.primal, .dual] {
        for f in [Simplex.Factorization.denseLU, .sparseQR] {
            for pre in [true, false] {
                for sc in [ScalingMode.none, .geometricEquilibration] {
                    out.append(Config(method: method, factorization: f, presolve: pre, scaling: sc, pricing: .devex, perturbation: .onStall))
                }
            }
        }
    }
    return out
}

func ctx(_ limit: Double = 20, warm: WarmStart = .none) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = limit
    c.threads = 1
    c.metal = .off
    c.warmStart = warm
    return c
}

func statusName(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infOrUnb"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let s): return "numericalFailure(\(s))"
    }
}
