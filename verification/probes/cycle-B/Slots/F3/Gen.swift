// Own generators for cycle B / F3 (not the package's InstanceGenerator):
// LPs with a known optimum built from KKT conditions, infeasible LPs with a Farkas
// certificate, unbounded LPs with a ray. Deterministic from a seed (SplitMix64).
import Foundation
import ZTronLPOptimizer

struct Rng {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x1234_5678_9ABC_DEF1 }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func u(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    mutating func chance(_ p: Double) -> Bool { u() < p }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
}

struct Known {
    var lp: CompiledLP
    var x: [Double]
    var y: [Double]      // internal (min-form) row duals
    var objective: Double  // reported
    var note: String
}

struct GenOptions {
    var density = 0.3
    var degenerate = false   // zero duals on active rows / zero reduced costs at bounds
    var free = true
    var ranged = true
    var equality = true
    var maximize = false
    var spread = 0.0         // log10 spread of row/col scale factors
    var infiniteBounds = true
}

func makeSparse(_ rng: inout Rng, m: Int, n: Int, density: Double, spread: Double) -> [[Double]] {
    var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    let rs = (0..<m).map { _ in pow(10, spread * rng.u(-1, 1)) }
    let cs = (0..<n).map { _ in pow(10, spread * rng.u(-1, 1)) }
    for i in 0..<m {
        for j in 0..<n where rng.chance(density) {
            a[i][j] = (rng.chance(0.5) ? 1 : -1) * rng.u(0.1, 1) * rs[i] * cs[j]
        }
    }
    // every row and column at least one entry
    for i in 0..<m where a[i].allSatisfy({ $0 == 0 }) {
        let j = rng.int(0, n - 1); a[i][j] = rng.u(0.2, 1) * rs[i] * cs[j]
    }
    for j in 0..<n where (0..<m).allSatisfy({ a[$0][j] == 0 }) {
        let i = rng.int(0, m - 1); a[i][j] = -rng.u(0.2, 1) * rs[i] * cs[j]
    }
    return a
}

func compile(_ a: [[Double]], c: [Double], c0: Double = 0, sense: ObjectiveSense = .minimize,
             xl: [Double], xu: [Double], rl: [Double], ru: [Double]) -> CompiledLP {
    let m = a.count, n = c.count
    var e: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where a[i][j] != 0 { e.append((i, j, a[i][j])) } }
    return CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, e), c: c, c0: c0, sense: sense,
                      xl: xl, xu: xu, rl: rl, ru: ru)
}

/// A random LP whose optimum (x, y) is planted through the KKT conditions.
func knownOptimum(seed: UInt64, m: Int, n: Int, _ o: GenOptions, matrix: [[Double]]? = nil) -> Known {
    var rng = Rng(seed)
    let a = matrix ?? makeSparse(&rng, m: m, n: n, density: o.density, spread: o.spread)
    var x = [Double](repeating: 0, count: n), xl = x, xu = x, d = x
    var nBasicLike = 0
    for j in 0..<n {
        let t = rng.u()
        let inf = o.infiniteBounds
        if t < 0.25 && nBasicLike < m / 2 {         // strictly between bounds
            nBasicLike += 1
            x[j] = rng.u(-5, 5)
            xl[j] = inf && rng.chance(0.3) ? -.infinity : x[j] - rng.u(0.5, 3)
            xu[j] = inf && rng.chance(0.3) ? .infinity : x[j] + rng.u(0.5, 3)
            d[j] = 0
        } else if t < 0.55 {  // at lower
            x[j] = rng.u(-3, 3).rounded()
            xl[j] = x[j]
            xu[j] = inf && rng.chance(0.4) ? .infinity : x[j] + rng.u(1, 5)
            d[j] = o.degenerate && rng.chance(0.3) ? 0 : rng.u(0.1, 2)
        } else if t < 0.8 {  // at upper
            x[j] = rng.u(-3, 3).rounded()
            xu[j] = x[j]
            xl[j] = inf && rng.chance(0.4) ? -.infinity : x[j] - rng.u(1, 5)
            d[j] = o.degenerate && rng.chance(0.3) ? 0 : -rng.u(0.1, 2)
        } else if t < 0.9 {  // fixed
            x[j] = rng.u(-2, 2)
            xl[j] = x[j]; xu[j] = x[j]
            d[j] = rng.u(-1, 1)
        } else if o.free && nBasicLike < m / 2 {  // free
            nBasicLike += 1
            x[j] = rng.u(-5, 5)
            xl[j] = -.infinity; xu[j] = .infinity
            d[j] = 0
        } else {  // at lower, nonnegative
            x[j] = 0; xl[j] = 0; xu[j] = .infinity; d[j] = o.degenerate && rng.chance(0.3) ? 0 : rng.u(0.1, 2)
        }
    }
    var r = [Double](repeating: 0, count: m)
    for i in 0..<m { for j in 0..<n { r[i] += a[i][j] * x[j] } }
    var rl = r, ru = r, y = [Double](repeating: 0, count: m)
    for i in 0..<m {
        let t = rng.u()
        if t < 0.25 {  // inactive
            rl[i] = rng.chance(0.4) ? -.infinity : r[i] - rng.u(0.5, 3)
            ru[i] = (rl[i] == -.infinity || rng.chance(0.5)) ? r[i] + rng.u(0.5, 3) : .infinity
            if !o.ranged && rl[i].isFinite && ru[i].isFinite { ru[i] = .infinity }
            y[i] = 0
        } else if t < 0.55 {  // active at lower
            rl[i] = r[i]
            ru[i] = o.ranged && rng.chance(0.3) ? r[i] + rng.u(1, 5) : .infinity
            y[i] = o.degenerate && rng.chance(0.3) ? 0 : rng.u(0.1, 2)
        } else if t < 0.8 || !o.equality {  // active at upper
            ru[i] = r[i]
            rl[i] = o.ranged && rng.chance(0.3) ? r[i] - rng.u(1, 5) : -.infinity
            y[i] = o.degenerate && rng.chance(0.3) ? 0 : -rng.u(0.1, 2)
        } else {  // equality
            rl[i] = r[i]; ru[i] = r[i]
            y[i] = rng.u(-2, 2)
        }
    }
    // c = d + A^T y   (min form)
    var c = d
    for j in 0..<n { for i in 0..<m { c[j] += a[i][j] * y[i] } }
    let c0 = rng.u(-10, 10).rounded()
    var obj = c0
    for j in 0..<n { obj += c[j] * x[j] }
    let sense: ObjectiveSense = o.maximize ? .maximize : .minimize
    let lp = compile(a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru)
    return Known(lp: lp, x: x, y: y, objective: o.maximize ? -obj : obj, note: "known seed=\(seed) m=\(m) n=\(n)")
}

/// Infeasible LP with a planted Farkas certificate (margin > 0). Box columns, a few free columns
/// that do not touch certificate rows.
func infeasibleLP(seed: UInt64, m: Int, n: Int, density: Double, margin: Double) -> (lp: CompiledLP, y: [Double]) {
    var rng = Rng(seed)
    var a = makeSparse(&rng, m: m, n: n, density: density, spread: 0)
    var y = [Double](repeating: 0, count: m)
    for i in 0..<m where rng.chance(0.5) { y[i] = (rng.chance(0.6) ? 1 : -1) * rng.u(0.5, 2) }
    if y.allSatisfy({ $0 == 0 }) { y[0] = 1 }
    var xl = [Double](repeating: 0, count: n), xu = xl
    var isFree = [Bool](repeating: false, count: n)
    for j in 0..<n {
        if rng.chance(0.1) {
            isFree[j] = true; xl[j] = -.infinity; xu[j] = .infinity
            for i in 0..<m where y[i] != 0 { a[i][j] = 0 }
        } else {
            xl[j] = rng.u(-3, 0).rounded(); xu[j] = xl[j] + rng.u(1, 6).rounded()
        }
    }
    // free columns without entries left: give them one in a y=0 row if any
    let zeroRows = (0..<m).filter { y[$0] == 0 }
    for j in 0..<n where isFree[j] && (0..<m).allSatisfy({ a[$0][j] == 0 }) {
        if let i = zeroRows.first { a[i][j] = 0.7 } else { isFree[j] = false; xl[j] = 0; xu[j] = 1 }
    }
    var g = [Double](repeating: 0, count: n)
    for j in 0..<n { for i in 0..<m { g[j] += a[i][j] * y[i] } }
    var U = 0.0
    for j in 0..<n where !isFree[j] { U += g[j] > 0 ? g[j] * xu[j] : g[j] * xl[j] }
    let x0 = (0..<n).map { j in isFree[j] ? rng.u(-2, 2) : rng.u(xl[j], xu[j]) }
    var r0 = [Double](repeating: 0, count: m)
    for i in 0..<m { for j in 0..<n { r0[i] += a[i][j] * x0[j] } }
    var gx0 = 0.0
    for j in 0..<n { gx0 += g[j] * x0[j] }
    let k = Double(y.filter { $0 != 0 }.count)
    let need = U - gx0 + margin
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    for i in 0..<m {
        if y[i] > 0 {
            rl[i] = r0[i] + need / (k * y[i])
            if rng.chance(0.3) { ru[i] = rl[i] + rng.u(1, 4) }
        } else if y[i] < 0 {
            ru[i] = r0[i] - need / (k * -y[i])
            if rng.chance(0.3) { rl[i] = ru[i] - rng.u(1, 4) }
        } else {
            let t = rng.u()
            if t < 0.4 { rl[i] = r0[i] - rng.u(0, 2) } else if t < 0.8 { ru[i] = r0[i] + rng.u(0, 2) } else {
                rl[i] = r0[i] - rng.u(0, 2); ru[i] = r0[i] + rng.u(0, 2)
            }
        }
    }
    let c = (0..<n).map { _ in rng.u(-1, 1) }
    return (compile(a, c: c, xl: xl, xu: xu, rl: rl, ru: ru), y)
}

/// Unbounded LP: feasible point x0 and a ray r with c^T r < 0 inside the recession cone.
func unboundedLP(seed: UInt64, m: Int, n: Int, density: Double, maximize: Bool) -> (lp: CompiledLP, ray: [Double]) {
    var rng = Rng(seed)
    let a = makeSparse(&rng, m: m, n: n, density: density, spread: 0)
    var ray = [Double](repeating: 0, count: n)
    let support = max(1, n / 5)
    for _ in 0..<support { ray[rng.int(0, n - 1)] = (rng.chance(0.6) ? 1 : -1) * rng.u(0.5, 2) }
    let x0 = (0..<n).map { _ in rng.u(-2, 2) }
    var xl = [Double](repeating: 0, count: n), xu = xl
    for j in 0..<n {
        xl[j] = x0[j] - rng.u(0, 3); xu[j] = x0[j] + rng.u(0, 3)
        if ray[j] > 0 { xu[j] = .infinity; if rng.chance(0.3) { xl[j] = -.infinity } }
        if ray[j] < 0 { xl[j] = -.infinity; if rng.chance(0.3) { xu[j] = .infinity } }
    }
    var r0 = [Double](repeating: 0, count: m), ar = r0
    for i in 0..<m { for j in 0..<n { r0[i] += a[i][j] * x0[j]; ar[i] += a[i][j] * ray[j] } }
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    for i in 0..<m {
        if ar[i] > 1e-12 { rl[i] = r0[i] - rng.u(0, 2) }
        else if ar[i] < -1e-12 { ru[i] = r0[i] + rng.u(0, 2) }
        else { rl[i] = r0[i] - rng.u(0, 2); ru[i] = r0[i] + rng.u(0, 2) }
    }
    var c = (0..<n).map { _ in rng.u(-1, 1) }
    var cr = 0.0, rr = 0.0
    for j in 0..<n { cr += c[j] * ray[j]; rr += ray[j] * ray[j] }
    let shift = (cr + 0.5) / rr
    for j in 0..<n { c[j] -= shift * ray[j] }   // now c^T r = -0.5 (min form)
    return (compile(a, c: c, sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru), ray)
}

func hilbertLP(order n: Int, form: String) -> (lp: CompiledLP, objective: Double) {
    var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    var b = [Double](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<n { a[i][j] = 1 / Double(i + j + 1); b[i] += a[i][j] } }
    let c = (0..<n).map { j in (0..<n).reduce(0.0) { $0 + a[$1][j] } }
    let zero = [Double](repeating: 0, count: n)
    let inf = [Double](repeating: .infinity, count: n)
    let ninf = [Double](repeating: -.infinity, count: n)
    let total = b.reduce(0, +)
    switch form {
    case "equality": return (compile(a, c: c, xl: zero, xu: inf, rl: b, ru: b), total)
    case "equalityFree": return (compile(a, c: c, xl: ninf, xu: inf, rl: b, ru: b), total)
    case "covering": return (compile(a, c: c, xl: zero, xu: inf, rl: b, ru: inf), total)
    default: return (compile(a, c: c.map { -$0 }, sense: .maximize, xl: zero, xu: inf, rl: ninf, ru: b), total)
    }
}
