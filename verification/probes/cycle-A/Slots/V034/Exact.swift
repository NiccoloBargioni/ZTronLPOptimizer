// V034 (cycle A, sceptic of A2-02, lens REPRODUCE): exact arithmetic and dense linear algebra
// written for this probe only. Nothing here comes from the package or from the finder's probe.
import Foundation

@inline(__always) func twoSum(_ a: Double, _ b: Double) -> (s: Double, e: Double) {
    let s = a + b
    let bv = s - a
    let av = s - bv
    return (s, (a - av) + (b - bv))
}

/// a·b = p + e exactly (no underflow here: all magnitudes are far above 1e-150).
@inline(__always) func twoProd(_ a: Double, _ b: Double) -> (p: Double, e: Double) {
    let p = a * b
    return (p, (-p).addingProduct(a, b))
}

/// An exact sum of doubles: a nonoverlapping expansion, components in increasing magnitude
/// (Shewchuk's Grow-Expansion with zero elimination). Its sign is the sign of its largest
/// component; `value` is the sum rounded to within about one ulp.
struct Expansion {
    var parts: [Double] = []
    mutating func add(_ b: Double) {
        var q = b
        var h: [Double] = []
        h.reserveCapacity(parts.count + 1)
        for e in parts {
            let t = twoSum(q, e)
            if t.e != 0 { h.append(t.e) }
            q = t.s
        }
        if q != 0 { h.append(q) }
        parts = h
    }
    mutating func addProduct(_ a: Double, _ b: Double) {
        let t = twoProd(a, b)
        add(t.p)
        add(t.e)
    }
    var value: Double { parts.reduce(0, +) }
    var sign: Int { guard let last = parts.last else { return 0 }; return last > 0 ? 1 : -1 }
}

/// Row-major dense LU with partial pivoting, my own.
struct MyLU {
    let n: Int
    var a: [[Double]]
    var piv: [Int]
    init?(_ m: [[Double]]) {
        n = m.count
        a = m
        piv = Array(0..<n)
        for k in 0..<n {
            var p = k
            var best = abs(a[k][k])
            for i in (k + 1)..<n where abs(a[i][k]) > best { best = abs(a[i][k]); p = i }
            if best == 0 { return nil }
            if p != k { a.swapAt(p, k); piv.swapAt(p, k) }
            for i in (k + 1)..<n {
                let f = a[i][k] / a[k][k]
                a[i][k] = f
                for j in (k + 1)..<n { a[i][j] -= f * a[k][j] }
            }
        }
    }
    func solve(_ b: [Double]) -> [Double] {
        var x = (0..<n).map { b[piv[$0]] }
        for i in 0..<n { for j in 0..<i { x[i] -= a[i][j] * x[j] } }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in (i + 1)..<n { x[i] -= a[i][j] * x[j] }
            x[i] /= a[i][i]
        }
        return x
    }
    /// Explicit inverse, row-major.
    func inverse() -> [[Double]] {
        var r = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for j in 0..<n {
            var e = [Double](repeating: 0, count: n)
            e[j] = 1
            let col = solve(e)
            for i in 0..<n { r[i][j] = col[i] }
        }
        return r
    }
}

func normInf(_ m: [[Double]]) -> Double { m.map { $0.reduce(0) { $0 + abs($1) } }.max() ?? 0 }
func norm1(_ m: [[Double]]) -> Double {
    let n = m.first?.count ?? 0
    return (0..<n).map { j in m.reduce(0) { $0 + abs($1[j]) } }.max() ?? 0
}
func transpose(_ m: [[Double]]) -> [[Double]] {
    let r = m.count, c = m.first?.count ?? 0
    return (0..<c).map { j in (0..<r).map { i in m[i][j] } }
}
func matvec(_ m: [[Double]], _ v: [Double]) -> [Double] { m.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } } }

/// Largest singular value by power iteration on MᵀM.
func sigmaMax(_ m: [[Double]]) -> Double {
    let n = m.first?.count ?? 0
    let mt = transpose(m)
    var v = (0..<n).map { 1.0 + 0.01 * Double($0) }
    var sigma = 0.0
    for _ in 0..<500 {
        let w = matvec(mt, matvec(m, v))
        let nw = sqrt(w.reduce(0) { $0 + $1 * $1 })
        let nv = sqrt(v.reduce(0) { $0 + $1 * $1 })
        sigma = sqrt(nw / nv)
        v = w.map { $0 / nw }
    }
    return sigma
}

/// The certificate of a verified inverse: with R ≈ A⁻¹ and E = I − R·A evaluated exactly
/// entry by entry, ‖E‖∞ < 1 proves A nonsingular and ‖A⁻¹‖∞ ≤ ‖R‖∞ / (1 − ‖E‖∞).
struct VerifiedInverse {
    let r: [[Double]]
    let normE: Double
    let invNormBound: Double   // upper bound on ‖A⁻¹‖∞, or +∞ if not verified
    init(_ a: [[Double]]) {
        let n = a.count
        guard let lu = MyLU(a) else { r = []; normE = .infinity; invNormBound = .infinity; return }
        let rr = lu.inverse()
        var worst = 0.0
        for i in 0..<n {
            var rowSum = 0.0
            for j in 0..<n {
                var e = Expansion()
                e.add(i == j ? 1 : 0)
                for k in 0..<n { e.addProduct(-rr[i][k], a[k][j]) }
                rowSum += abs(e.value)
            }
            worst = max(worst, rowSum)
        }
        let safeE = worst * (1 + 1e-12) + 1e-300
        r = rr
        normE = safeE
        invNormBound = safeE < 1 ? normInf(rr) * (1 + 1e-12) / (1 - safeE) : .infinity
    }
}

/// Exact Farkas value of a row combination y for {rl ≤ Ax ≤ ru, xl ≤ x ≤ xu}: with z = Aᵀy,
/// F(y) = Σᵢ (yᵢ > 0 ? yᵢ·rlᵢ : yᵢ·ruᵢ) − Σⱼ (zⱼ > 0 ? zⱼ·xuⱼ : zⱼ·xlⱼ).
/// Any feasible x gives F(y) ≤ 0, so F(y) > 0 proves infeasibility; F(y) ≤ 0 proves nothing.
/// Every term is evaluated exactly; the returned sign is exact, the value correct to an ulp.
func exactFarkas(a: [[Double]], rl: [Double], ru: [Double], xl: [Double], xu: [Double], y: [Double])
    -> (value: Double, sign: Int, termScale: Double)
{
    let m = a.count, n = a.first?.count ?? 0
    var f = Expansion()
    var scale = 0.0
    for i in 0..<m where y[i] != 0 {
        let b = y[i] > 0 ? rl[i] : ru[i]
        if !b.isFinite { return (-.infinity, -1, .infinity) }
        f.addProduct(y[i], b)
        scale += abs(y[i] * b)
    }
    for j in 0..<n {
        var z = Expansion()
        for i in 0..<m where y[i] != 0 { z.addProduct(a[i][j], y[i]) }
        let s = z.sign
        if s == 0 { continue }
        let b = s > 0 ? xu[j] : xl[j]
        if !b.isFinite { return (-.infinity, -1, .infinity) }
        for p in z.parts { f.addProduct(-p, b) }
        scale += abs(z.value * b)
    }
    return (f.value, f.sign, scale)
}

/// Exact residual b − A·x, rounded entry by entry.
func exactResidual(_ a: [[Double]], _ x: [Double], _ b: [Double]) -> [Double] {
    (0..<a.count).map { i in
        var e = Expansion()
        e.add(b[i])
        for j in 0..<x.count { e.addProduct(-a[i][j], x[j]) }
        return e.value
    }
}

/// x* = A⁻¹b by LU and iterative refinement with exact residuals.
func refinedSolve(_ a: [[Double]], _ b: [Double]) -> (x: [Double], residual: Double)? {
    guard let lu = MyLU(a) else { return nil }
    var x = lu.solve(b)
    for _ in 0..<20 {
        let r = exactResidual(a, x, b)
        let dx = lu.solve(r)
        for j in 0..<x.count { x[j] += dx[j] }
    }
    let r = exactResidual(a, x, b)
    return (x, r.map { abs($0) }.max() ?? 0)
}

func sci(_ v: Double) -> String { String(format: "%.3e", v) }
