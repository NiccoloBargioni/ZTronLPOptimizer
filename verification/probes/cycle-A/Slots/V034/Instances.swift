// V034: the instances. `finderInstance(k)` regenerates instance k of the finder's L·D·U family
// (same seed scheme and evaluation order, so that k15 is the same bits); it defines the input
// only. `freshInstance` is a second family from my own generator, to see whether the effect
// is more than one instance.
import Foundation
import ZTronLPOptimizer

struct Instance {
    let label: String
    let n: Int
    let decades: Double
    let A: [[Double]]
    let b: [Double]
    let c: [Double]
    let xl: [Double]
    let xu: [Double]
    let lp: CompiledLP
}

func buildLP(_ A: [[Double]], _ b: [Double], _ c: [Double], _ xl: [Double], _ xu: [Double]) -> CompiledLP {
    let n = A.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<n { for j in 0..<n where A[i][j] != 0 { entries.append((i, j, A[i][j])) } }
    return CompiledLP(a: SparseCSC.fromTriplets(rows: n, cols: n, entries), c: c, xl: xl, xu: xu, rl: b, ru: b)
}

/// The finder's SplitMix-style stream (input definition only).
struct FinderStream {
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
}

func ldu(n: Int, decades: Double, draw: () -> Double) -> [[Double]] {
    var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    var U = L
    for i in 0..<n { for j in 0..<n {
        if i == j { L[i][j] = 1; U[i][j] = 1 } else if i > j { L[i][j] = draw() } else { U[i][j] = draw() }
    } }
    let d = (0..<n).map { pow(10, -decades * Double($0) / Double(max(1, n - 1))) }
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0..<n {
        var s = 0.0
        for p in 0..<n { s += L[i][p] * d[p] * U[p][j] }
        A[i][j] = s
    } }
    return A
}

func finderInstance(_ k: Int) -> Instance {
    var r = FinderStream(UInt64(900 + k))
    let n = r.int(5, 12)
    let decades = Double(r.int(6, 13))
    let A = ldu(n: n, decades: decades) { r.u(-1, 1) }
    var b = [Double](repeating: 0, count: n), c = [Double](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<n where A[i][j] != 0 { b[i] += A[i][j]; c[j] += A[i][j] } }
    for j in 0..<n { c[j] += 1 }
    let xl = [Double](repeating: -10, count: n), xu = [Double](repeating: 10, count: n)
    return Instance(label: "finder-k\(k)", n: n, decades: decades, A: A, b: b, c: c, xl: xl, xu: xu,
                    lp: buildLP(A, b, c, xl, xu))
}

/// xorshift64* — my own stream for the fresh family.
struct XorShift {
    var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E37_79B9 : seed ^ 0xDEAD_BEEF_CAFE_F00D }
    mutating func next() -> UInt64 {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s &* 2_685_821_657_736_338_717
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

func freshInstance(seed: UInt64) -> Instance {
    var g = XorShift(seed)
    for _ in 0..<4 { _ = g.next() }
    let n = 6 + Int(g.next() % 7)                    // 6 ... 12
    let decades = 5.0 + Double(g.next() % 5)        // D spans 1e-5 ... 1e-9
    let A = ldu(n: n, decades: decades) { 2 * g.unit() - 1 }
    var b = [Double](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<n { b[i] += A[i][j] } }
    let c = (0..<n).map { _ in 2 * g.unit() - 1 }
    let xl = [Double](repeating: -10, count: n), xu = [Double](repeating: 10, count: n)
    return Instance(label: "fresh-s\(seed)", n: n, decades: decades, A: A, b: b, c: c, xl: xl, xu: xu,
                    lp: buildLP(A, b, c, xl, xu))
}

/// My oracle for one instance: verified nonsingularity, a rigorous bound on the distance of
/// the unique solution x* from 1, hence feasibility, and x*, cᵀx* from a refined solve.
struct Oracle {
    let kappa1: Double, kappaInf: Double, kappa2: Double
    let normE: Double
    let residualOfOnes: Double          // ‖b − A·1‖∞, exact
    let distanceBound: Double           // rigorous upper bound on ‖x* − 1‖∞
    let feasible: Bool                  // proven: x* strictly inside the bounds
    let xStar: [Double]
    let xStarResidual: Double
    let objective: Double               // cᵀx*, exact sum of the products
    init(_ inst: Instance) {
        let v = VerifiedInverse(inst.A)
        normE = v.normE
        kappa1 = norm1(inst.A) * norm1(v.r)
        kappaInf = normInf(inst.A) * normInf(v.r)
        kappa2 = sigmaMax(inst.A) * sigmaMax(v.r)
        let ones = [Double](repeating: 1, count: inst.n)
        residualOfOnes = exactResidual(inst.A, ones, inst.b).map { abs($0) }.max() ?? 0
        distanceBound = v.invNormBound * residualOfOnes * (1 + 1e-12)
        var inside = distanceBound.isFinite
        for j in 0..<inst.n where !(1 - distanceBound > inst.xl[j] && 1 + distanceBound < inst.xu[j]) { inside = false }
        feasible = inside
        let s = refinedSolve(inst.A, inst.b) ?? (x: [], residual: .infinity)
        xStar = s.x
        xStarResidual = s.residual
        var e = Expansion()
        for j in 0..<s.x.count { e.addProduct(inst.c[j], s.x[j]) }
        objective = e.value
    }
}
