// V037 (cycle A, sceptic for A2-03). The instance generator is a copy of the finder's
// KKT generator (Slots/F2/Common.swift, makeKKT), so that seed 1273 gives the same LP. It is
// only a generator: nothing below trusts its reported objective. The oracle is in Oracle.swift.
import Foundation
import ZTronLPOptimizer

struct GenRng {
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

struct GenInstance {
    let lp: CompiledLP
    let x: [Double]        // constructed primal point
    let yMin: [Double]     // constructed row duals, minimization form
    let generatorObjective: Double
    let label: String
}

func generate(m: Int, n: Int, seed: UInt64, maximize: Bool, degenerate: Bool, density: Double = 0.3,
              scaleSpread: Double = 0) -> GenInstance {
    var r = GenRng(seed)
    func val() -> Double { (r.u(-1, 1) * 1000).rounded() / 1000 }
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
        case 0, 1, 2:
            xl[j] = r.chance(0.5) ? 0 : (r.u(-5, 5) * mag)
            xu[j] = r.chance(0.5) ? .infinity : xl[j] + r.u(0.5, 6) * mag
            x[j] = xl[j]
            d[j] = r.chance(pDeg) ? 0 : r.u(0.1, 3)
        case 3, 4:
            xu[j] = r.u(-5, 5) * mag
            xl[j] = r.chance(0.4) ? -.infinity : xu[j] - r.u(0.5, 6) * mag
            x[j] = xu[j]
            d[j] = r.chance(pDeg) ? 0 : -r.u(0.1, 3)
        case 5, 6:
            xl[j] = r.chance(0.3) ? -.infinity : r.u(-5, 0) * mag
            xu[j] = r.chance(0.3) ? .infinity : r.u(0.5, 5) * mag
            let lo = xl[j].isFinite ? xl[j] : -6 * mag
            let hi = xu[j].isFinite ? xu[j] : 6 * mag
            x[j] = lo + (hi - lo) * r.u(0.2, 0.8)
            d[j] = 0
        case 7:
            xl[j] = -.infinity; xu[j] = .infinity
            x[j] = r.u(-4, 4) * mag
            d[j] = 0
        case 8:
            xl[j] = r.u(-3, 3) * mag; xu[j] = xl[j]; x[j] = xl[j]
            d[j] = r.u(-2, 2)
        default:
            xl[j] = -.infinity; xu[j] = 0
            if r.chance(0.5) { x[j] = 0; d[j] = r.chance(pDeg) ? 0 : -r.u(0.1, 3) }
            else { x[j] = -r.u(0.5, 4) * mag; d[j] = 0 }
        }
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
        case 0, 1:
            rl[i] = s; ru[i] = s
            y[i] = r.chance(pDeg) ? 0 : r.u(-2, 2)
        case 2, 3:
            rl[i] = s; ru[i] = r.chance(0.6) ? .infinity : s + r.u(0.5, 4) * mag
            y[i] = r.chance(pDeg) ? 0 : r.u(0.1, 2)
        case 4, 5:
            ru[i] = s; rl[i] = r.chance(0.6) ? -.infinity : s - r.u(0.5, 4) * mag
            y[i] = r.chance(pDeg) ? 0 : -r.u(0.1, 2)
        case 6, 7:
            rl[i] = r.chance(0.3) ? -.infinity : s - r.u(0.2, 3) * mag
            ru[i] = r.chance(0.3) ? .infinity : s + r.u(0.2, 3) * mag
            y[i] = 0
        case 8:
            rl[i] = s; ru[i] = r.chance(0.5) ? .infinity : s + r.u(0.5, 3) * mag
            y[i] = 0
        default:
            rl[i] = -.infinity; ru[i] = .infinity; y[i] = 0
        }
        y[i] /= rowScale[i]
    }
    let aty = a.multiplyTranspose(y)
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = d[j] / colScale[j] + aty[j] }
    let c0 = (r.u(-10, 10) * 100).rounded() / 100
    let lp = CompiledLP(a: a, c: c, c0: c0, sense: maximize ? .maximize : .minimize,
                        xl: xl, xu: xu, rl: rl, ru: ru)
    var obj = c0
    for j in 0..<n { obj += c[j] * x[j] }
    return GenInstance(lp: lp, x: x, yMin: y, generatorObjective: maximize ? -obj : obj,
                       label: "seed\(seed) m\(m) n\(n) max\(maximize) deg\(degenerate) spread\(scaleSpread)")
}
