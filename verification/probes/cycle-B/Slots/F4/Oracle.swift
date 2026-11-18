// Cycle B, slot F4: independent oracles for small MILPs.
// - Instance: dense data in the MODEL's sense (maximize or minimize).
// - Exhaustive enumeration of the integer part; the continuous part (<= 3 columns, finite
//   bounds) is solved by vertex enumeration with Gaussian elimination (independent of the
//   package's LP engines).
import Foundation
import ZTronLPOptimizer

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x1234_5678_9ABC_DEF1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

struct Inst {
    var label: String
    var nI: Int            // integer columns are 0..<nI
    var nC: Int            // continuous columns are nI..<nI+nC
    var rows: [[Double]]   // m x n dense
    var rl: [Double]
    var ru: [Double]
    var xl: [Double]       // bounds as given to the solver (may be infinite for integer columns)
    var xu: [Double]
    var domLo: [Int]       // enumeration domain of each integer column (superset of feasible values)
    var domHi: [Int]
    var cost: [Double]     // model sense
    var c0: Double
    var maximize: Bool
    var n: Int { nI + nC }
    var m: Int { rows.count }

    func compiled() -> CompiledLP {
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { for j in 0..<n where rows[i][j] != 0 { entries.append((i, j, rows[i][j])) } }
        let sign = maximize ? -1.0 : 1.0
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: cost.map { sign * $0 }, c0: sign * c0,
            sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru,
            integerColumns: (0..<nI).map { Int32($0) })
    }
}

enum OracleResult: CustomStringConvertible {
    case optimal(Double, [Double])
    case infeasible
    case unbounded
    var description: String {
        switch self {
        case .optimal(let z, let x): return "optimal \(z) at \(x)"
        case .infeasible: return "infeasible"
        case .unbounded: return "unbounded"
        }
    }
}

/// Solves an n x n system by Gaussian elimination with partial pivoting; nil if singular.
func solveDense(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let k = b.count
    var m = a
    var r = b
    for col in 0..<k {
        var piv = col
        for row in col..<k where abs(m[row][col]) > abs(m[piv][col]) { piv = row }
        if abs(m[piv][col]) < 1e-11 { return nil }
        if piv != col { m.swapAt(piv, col); r.swapAt(piv, col) }
        for row in 0..<k where row != col {
            let f = m[row][col] / m[col][col]
            if f == 0 { continue }
            for c2 in col..<k { m[row][c2] -= f * m[col][c2] }
            r[row] -= f * r[col]
        }
    }
    return (0..<k).map { r[$0] / m[$0][$0] }
}

/// min (or max) g.y over { lo_i <= A_i.y <= hi_i, l <= y <= u } with all of l,u finite.
/// Vertex enumeration. Returns nil when infeasible.
func continuousOpt(rows: [[Double]], lo: [Double], hi: [Double], l: [Double], u: [Double], g: [Double], maximize: Bool) -> (Double, [Double])? {
    let k = g.count
    // Half-spaces as (normal, rhs, isUpper): normal.y <= rhs  (we store <= form).
    var hs: [([Double], Double)] = []
    for i in 0..<rows.count {
        if hi[i] < .infinity { hs.append((rows[i], hi[i])) }
        if lo[i] > -.infinity { hs.append((rows[i].map { -$0 }, -lo[i])) }
    }
    for j in 0..<k {
        var e = [Double](repeating: 0, count: k); e[j] = 1
        hs.append((e, u[j]))
        hs.append((e.map { -$0 }, -l[j]))
    }
    func feasible(_ y: [Double]) -> Bool {
        for (nrm, rhs) in hs {
            var s = 0.0
            for j in 0..<k { s += nrm[j] * y[j] }
            if s > rhs + 1e-9 * (1 + abs(rhs)) { return false }
        }
        return true
    }
    var best: (Double, [Double])? = nil
    // choose k of hs
    var idx = Array(0..<k)
    let total = hs.count
    if total < k { return nil }
    while true {
        let mat = idx.map { hs[$0].0 }
        let rhs = idx.map { hs[$0].1 }
        if let y = solveDense(mat, rhs), feasible(y) {
            var v = 0.0
            for j in 0..<k { v += g[j] * y[j] }
            if best == nil || (maximize ? v > best!.0 : v < best!.0) { best = (v, y) }
        }
        // next combination
        var p = k - 1
        while p >= 0 && idx[p] == total - k + p { p -= 1 }
        if p < 0 { break }
        idx[p] += 1
        for q in (p + 1)..<k { idx[q] = idx[q - 1] + 1 }
    }
    return best
}

/// Exhaustive oracle. Integer columns enumerate their domain intersected with the given bounds.
func oracle(_ inst: Inst) -> OracleResult {
    let n = inst.n
    var lo = [Int](), hi = [Int]()
    for j in 0..<inst.nI {
        var a = inst.domLo[j], b = inst.domHi[j]
        if inst.xl[j] > -.infinity { a = max(a, Int((inst.xl[j] - 1e-12).rounded(.up))) }
        if inst.xu[j] < .infinity { b = min(b, Int((inst.xu[j] + 1e-12).rounded(.down))) }
        lo.append(a); hi.append(b)
        if a > b { return .infeasible }
    }
    var x = lo
    var best: (Double, [Double])? = nil
    let contRows: [[Double]] = inst.rows.map { Array($0[inst.nI..<n]) }
    let g = Array(inst.cost[inst.nI..<n])
    let cl = Array(inst.xl[inst.nI..<n]), cu = Array(inst.xu[inst.nI..<n])
    while true {
        // residual rows
        var rlo = [Double](), rhi = [Double]()
        var intObj = inst.c0
        for j in 0..<inst.nI { intObj += inst.cost[j] * Double(x[j]) }
        var ok = true
        for i in 0..<inst.m {
            var s = 0.0
            for j in 0..<inst.nI { s += inst.rows[i][j] * Double(x[j]) }
            rlo.append(inst.rl[i] - s); rhi.append(inst.ru[i] - s)
            if inst.nC == 0 {
                if s < inst.rl[i] - 1e-9 * (1 + abs(inst.rl[i])) || s > inst.ru[i] + 1e-9 * (1 + abs(inst.ru[i])) { ok = false }
            }
        }
        if ok {
            var value: Double? = nil
            var y: [Double] = []
            if inst.nC == 0 {
                value = intObj
            } else if let (v, yy) = continuousOpt(rows: contRows, lo: rlo, hi: rhi, l: cl, u: cu, g: g, maximize: inst.maximize) {
                value = intObj + v
                y = yy
            }
            if let v = value {
                if best == nil || (inst.maximize ? v > best!.0 + 1e-12 : v < best!.0 - 1e-12) {
                    best = (v, x.map(Double.init) + y)
                }
            }
        }
        // increment
        var p = 0
        while p < inst.nI {
            x[p] += 1
            if x[p] <= hi[p] { break }
            x[p] = lo[p]
            p += 1
        }
        if p == inst.nI || inst.nI == 0 { break }
    }
    if let best { return .optimal(best.0, best.1) }
    return .infeasible
}

/// Random small MILP. kind: "bin", "int", "mixed", "eq", "infeas", "freeint".
func randomInstance(seed: UInt64, kind: String) -> Inst {
    var r = SplitMix(seed)
    let nI = kind == "mixed" ? r.int(1, 3) : r.int(2, 5)
    let nC = kind == "mixed" ? r.int(1, 2) : (kind == "eq" ? r.int(0, 1) : 0)
    let n = nI + nC
    let m = r.int(1, 4)
    var xl = [Double](), xu = [Double](), domLo = [Int](), domHi = [Int]()
    for _ in 0..<nI {
        var a: Int, b: Int
        if kind == "bin" { a = 0; b = 1 }
        else {
            switch r.int(0, 5) {
            case 0: a = 0; b = 1
            case 1: a = -r.int(1, 3); b = r.int(-1, 2)
            case 2: a = -r.int(2, 4); b = -1
            case 3: a = r.int(1, 3); b = a + r.int(0, 3)
            case 4: a = r.int(-2, 2); b = a      // fixed
            default: a = -r.int(0, 2); b = r.int(1, 3)
            }
            if b < a { swap(&a, &b) }
        }
        domLo.append(a); domHi.append(b)
        if kind == "freeint" && r.chance(0.5) {
            xl.append(-.infinity); xu.append(.infinity)     // domain enforced by a singleton row below
        } else if kind == "int" && r.chance(0.3) {
            // fractional bounds that round inward to [a, b]
            xl.append(Double(a) - 0.5 * r.unit()); xu.append(Double(b) + 0.9 * r.unit())
        } else {
            xl.append(Double(a)); xu.append(Double(b))
        }
    }
    for _ in 0..<nC {
        let a = Double(r.int(-3, 1)) + (r.chance(0.5) ? 0.5 : 0)
        let b = a + Double(r.int(0, 4)) + (r.chance(0.5) ? 0.25 : 0)
        xl.append(a); xu.append(b)
    }
    // a hidden feasible point (unless kind == infeas)
    var point = [Double]()
    for j in 0..<nI { point.append(Double(r.int(domLo[j], domHi[j]))) }
    for j in nI..<n { point.append(xl[j] + (xu[j] - xl[j]) * r.unit()) }
    var rows = [[Double]](), rl = [Double](), ru = [Double]()
    for _ in 0..<m {
        var row = [Double](repeating: 0, count: n)
        for j in 0..<n where r.chance(0.7) { row[j] = Double(r.int(-6, 6)) }
        if row.allSatisfy({ $0 == 0 }) { row[r.int(0, n - 1)] = Double(r.int(1, 5)) }
        var act = 0.0
        for j in 0..<n { act += row[j] * point[j] }
        let t = kind == "eq" ? 2 : r.int(0, 3)
        switch t {
        case 0: rl.append(-.infinity); ru.append((act + Double(r.int(0, 3))).rounded(.up))
        case 1: rl.append((act - Double(r.int(0, 3))).rounded(.down)); ru.append(.infinity)
        case 2: rl.append(act); ru.append(act)
        default: rl.append((act - Double(r.int(0, 2))).rounded(.down)); ru.append((act + Double(r.int(0, 2))).rounded(.up))
        }
        rows.append(row)
    }
    if kind == "freeint" {
        for j in 0..<nI where xl[j] == -.infinity {
            var row = [Double](repeating: 0, count: n)
            let k = Double(r.int(1, 3))
            row[j] = k
            // sometimes a two-variable row instead of a singleton, with a bounded partner
            rows.append(row); rl.append(k * Double(domLo[j])); ru.append(k * Double(domHi[j]))
        }
    }
    if kind == "infeas" {
        // parity row: 2*sum(x) == odd
        var row = [Double](repeating: 0, count: n)
        for j in 0..<nI { row[j] = 2 }
        rows.append(row); rl.append(1); ru.append(1)
    }
    var cost = [Double]()
    for _ in 0..<n { cost.append(Double(r.int(-9, 9)) + (r.chance(0.3) ? 0.5 : 0)) }
    let maximize = r.chance(0.5)
    let c0 = r.chance(0.3) ? Double(r.int(-20, 20)) : 0
    return Inst(label: "\(kind)#\(seed)", nI: nI, nC: nC, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu,
                domLo: domLo, domHi: domHi, cost: cost, c0: c0, maximize: maximize)
}

/// Harder random MILPs: more integer columns, fractional data (objective step 0), deeper trees.
/// kind: "knap" (binary multi-knapsack, fractional data), "hardint" (general integers, mixed signs),
/// "hardmix" (integers + up to 3 continuous), "bigobj" (objective ~1e5 so the default gap is ~10).
func hardInstance(seed: UInt64, kind: String) -> Inst {
    var r = SplitMix(seed &* 7919 &+ 17)
    var nI: Int, nC: Int, m: Int
    switch kind {
    case "knap": nI = r.int(10, 15); nC = 0; m = r.int(1, 3)
    case "hardint": nI = r.int(5, 7); nC = 0; m = r.int(2, 5)
    case "hardmix": nI = r.int(3, 5); nC = r.int(1, 3); m = r.int(2, 4)
    default: nI = r.int(8, 12); nC = 0; m = r.int(1, 3)
    }
    let n = nI + nC
    var xl = [Double](), xu = [Double](), domLo = [Int](), domHi = [Int]()
    var product = 1
    for _ in 0..<nI {
        var a = 0, b = 1
        if kind == "hardint" || kind == "hardmix" {
            a = -r.int(0, 3); b = a + r.int(1, 4)
            if product * (b - a + 1) > 150_000 { b = a + 1 }
        }
        product *= (b - a + 1)
        domLo.append(a); domHi.append(b); xl.append(Double(a)); xu.append(Double(b))
    }
    for _ in 0..<nC {
        let a = -Double(r.int(0, 3)) * 0.75
        let b = a + Double(r.int(1, 5)) * 0.6
        xl.append(a); xu.append(b)
    }
    var rows = [[Double]](), rl = [Double](), ru = [Double]()
    for _ in 0..<m {
        var row = [Double](repeating: 0, count: n)
        for j in 0..<n where r.chance(0.75) {
            switch kind {
            case "knap", "bigobj", "bigobj2": row[j] = (1 + 19 * r.unit() * 100).rounded() / 100
            default: row[j] = (Double(r.int(-80, 80)) / 10)
            }
        }
        if row.allSatisfy({ $0 == 0 }) { row[r.int(0, n - 1)] = 1.5 }
        if kind == "knap" || kind == "bigobj" || kind == "bigobj2" {
            let total = row.reduce(0, +)
            rl.append(-.infinity); ru.append((total * (0.3 + 0.3 * r.unit()) * 100).rounded() / 100)
        } else {
            // around a random point
            var act = 0.0
            for j in 0..<nI { act += row[j] * Double(r.int(domLo[j], domHi[j])) }
            for j in nI..<n { act += row[j] * (xl[j] + (xu[j] - xl[j]) * r.unit()) }
            switch r.int(0, 2) {
            case 0: rl.append(-.infinity); ru.append(act + Double(r.int(0, 20)) / 10)
            case 1: rl.append(act - Double(r.int(0, 20)) / 10); ru.append(.infinity)
            default: rl.append(act - Double(r.int(0, 10)) / 10); ru.append(act + Double(r.int(0, 10)) / 10)
            }
        }
        rows.append(row)
    }
    var cost = [Double]()
    for _ in 0..<n {
        switch kind {
        case "knap": cost.append((1 + 29 * r.unit() * 100).rounded() / 100)
        case "bigobj": cost.append(10_000 + Double(r.int(0, 3000)) + (r.chance(0.5) ? 0.5 : 0))
        case "bigobj2": cost.append(10_000 + 3000 * r.unit())
        default: cost.append(Double(r.int(-90, 90)) / 10 + 0.01 * Double(r.int(0, 9)))
        }
    }
    let maximize = (kind == "knap" || kind == "bigobj" || kind == "bigobj2") ? true : r.chance(0.5)
    return Inst(label: "\(kind)#\(seed)", nI: nI, nC: nC, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu,
                domLo: domLo, domHi: domHi, cost: cost, c0: 0, maximize: maximize)
}

/// Pure integer, integral costs (objective step 1), with "near-integral" rows whose coefficients are
/// scaled by 1e6 and whose right-hand side is shifted by delta in (0,1): LP vertices on them sit
/// within 1e-6 of an integer, which the search accepts as integral.
func nearIntInstance(seed: UInt64) -> Inst {
    var r = SplitMix(seed &* 104_729 &+ 3)
    let nI = r.int(4, 7)
    var xl = [Double](), xu = [Double](), domLo = [Int](), domHi = [Int]()
    for _ in 0..<nI {
        let b = r.chance(0.7) ? 1 : 2
        domLo.append(0); domHi.append(b); xl.append(0); xu.append(Double(b))
    }
    var rows = [[Double]](), rl = [Double](), ru = [Double]()
    let regular = r.int(1, 3)
    for _ in 0..<regular {
        var row = [Double](repeating: 0, count: nI)
        for j in 0..<nI where r.chance(0.6) { row[j] = Double(r.int(-4, 6)) }
        if row.filter({ $0 != 0 }).count < 2 { row[0] = 2; row[nI - 1] = 3 }
        let total = row.map { max(0, $0) }.reduce(0, +)
        if r.chance(0.5) { rl.append(-.infinity); ru.append((total * (0.3 + 0.4 * r.unit())).rounded()) }
        else { rl.append((total * (0.2 + 0.3 * r.unit())).rounded()); ru.append(.infinity) }
        rows.append(row)
    }
    let near = r.int(1, 2)
    for _ in 0..<near {
        var row = [Double](repeating: 0, count: nI)
        var support = 0
        for j in 0..<nI where r.chance(0.5) { row[j] = 1e6; support += 1 }
        if support < 2 { row[0] = 1e6; row[1] = 1e6; support = 2 }
        let k = Double(r.int(1, max(1, support - 1)))
        let delta = 0.1 + 0.8 * r.unit()
        if r.chance(0.5) { rl.append(1e6 * k - delta); ru.append(.infinity) }   // sum >= k (exactly, for integers)
        else { rl.append(-.infinity); ru.append(1e6 * k + delta) }             // sum <= k
        rows.append(row)
    }
    var cost = [Double]()
    for _ in 0..<nI { cost.append(Double(r.int(-20, 20))) }
    return Inst(label: "nearint#\(seed)", nI: nI, nC: 0, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu,
                domLo: domLo, domHi: domHi, cost: cost, c0: 0, maximize: r.chance(0.5))
}

/// Like nearIntInstance but with knapsack rows over 8-11 binaries so the root is fractional and
/// the tree is deeper; profits integral (objective step 1); 1-2 near-integral linking rows
/// d <= e + delta*1e-6 (scaled by 1e6) that let the LP gain a hair on an integral-looking vertex.
func nearInt2Instance(seed: UInt64) -> Inst {
    var r = SplitMix(seed &* 15_485_863 &+ 11)
    let nI = r.int(8, 11)
    let xl = [Double](repeating: 0, count: nI), xu = [Double](repeating: 1, count: nI)
    var rows = [[Double]](), rl = [Double](), ru = [Double]()
    for _ in 0..<r.int(1, 2) {
        var row = [Double](repeating: 0, count: nI)
        for j in 0..<nI where r.chance(0.8) { row[j] = Double(r.int(1, 9)) }
        let total = row.reduce(0, +)
        rows.append(row); rl.append(-.infinity); ru.append((total * (0.35 + 0.3 * r.unit())).rounded(.down))
    }
    for _ in 0..<r.int(1, 3) {
        var row = [Double](repeating: 0, count: nI)
        let d = r.int(0, nI - 1)
        var e = r.int(0, nI - 1)
        if e == d { e = (d + 1) % nI }
        row[d] = 1e6; row[e] = -1e6
        rows.append(row); rl.append(-.infinity); ru.append(1e6 * 0 + (0.1 + 0.8 * r.unit()))
    }
    var cost = [Double]()
    for _ in 0..<nI { cost.append(Double(r.int(1, 25))) }
    return Inst(label: "nearint2#\(seed)", nI: nI, nC: 0, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu,
                domLo: [Int](repeating: 0, count: nI), domHi: [Int](repeating: 1, count: nI), cost: cost, c0: 0, maximize: true)
}
