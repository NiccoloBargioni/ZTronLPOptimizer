// Generators with a known answer, built from first principles (not from the package's own
// generators): planted KKT points, infeasible models with a planted Farkas vector, unbounded
// models with a planted ray, Hilbert, Klee-Minty and assignment LPs.
import Foundation
import ZTronLPOptimizer

struct Planted {
    var lp: LP
    var x: [Double]
    var y: [Double]      // minimization form
    var d: [Double]      // minimization form, n entries
    var opt: Double      // model sense
    var tags: String
}

struct PlantOpts {
    var density = 0.4
    var integerData = true
    var degenerate = 0.25      // probability that an "active" row/col gets a zero multiplier
    var maximize = false
    var spread = 0.0           // decades of row/column scaling
    var allowFree = true
    var allowRanged = true
}

/// x*, y*, d* with complementary slackness; rows and costs built so that KKT holds.
func planted(seed: UInt64, m: Int, n: Int, _ o: PlantOpts) -> Planted {
    var g = RNG(seed)
    func coef() -> Double {
        if o.integerData { let v = Double(g.int(1, 9)); return g.chance(0.5) ? v : -v }
        let v = g.u(0.2, 5); return g.chance(0.5) ? v : -v
    }
    func val(_ a: Double, _ b: Double) -> Double { o.integerData ? Double(g.int(Int(a), Int(b))) : g.u(a, b) }
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    for i in 0..<m { for j in 0..<n where g.chance(o.density) { A[i][j] = coef() } }
    for j in 0..<n where !(0..<m).contains(where: { A[$0][j] != 0 }) { A[g.int(0, m - 1)][j] = coef() }
    for i in 0..<m where !A[i].contains(where: { $0 != 0 }) { A[i][g.int(0, n - 1)] = coef() }
    if o.spread > 0 {
        let rs = (0..<m).map { _ in pow(10, g.u(-o.spread, o.spread)) }
        let cs = (0..<n).map { _ in pow(10, g.u(-o.spread, o.spread)) }
        for i in 0..<m { for j in 0..<n { A[i][j] *= rs[i] * cs[j] } }
    }
    var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: .infinity, count: n)
    var x = [Double](repeating: 0, count: n), d = [Double](repeating: 0, count: n)
    var kinds: [String: Int] = [:]
    func pos() -> Double { g.chance(o.degenerate) ? 0 : val(1, 6) }
    for j in 0..<n {
        let kind = g.int(0, o.allowFree ? 7 : 6)
        switch kind {
        case 0, 1: // [0, inf)
            xl[j] = 0; xu[j] = .infinity
            if g.chance(0.5) { x[j] = 0; d[j] = pos() } else { x[j] = val(1, 5); d[j] = 0 }
            kinds["std", default: 0] += 1
        case 2: // [l, inf), l possibly negative
            xl[j] = val(-5, 5); xu[j] = .infinity
            if g.chance(0.5) { x[j] = xl[j]; d[j] = pos() } else { x[j] = xl[j] + val(1, 4); d[j] = 0 }
            kinds["lower", default: 0] += 1
        case 3: // (-inf, u]; u = 0 is a "negative" column
            xl[j] = -.infinity; xu[j] = g.chance(0.5) ? 0 : val(-4, 4)
            if g.chance(0.5) { x[j] = xu[j]; d[j] = -pos() } else { x[j] = xu[j] - val(1, 4); d[j] = 0 }
            kinds["upper", default: 0] += 1
        case 4, 5: // boxed
            xl[j] = val(-4, 2); xu[j] = xl[j] + val(1, 6)
            let r = g.int(0, 2)
            if r == 0 { x[j] = xl[j]; d[j] = pos() } else if r == 1 { x[j] = xu[j]; d[j] = -pos() } else {
                x[j] = o.integerData ? xl[j] : g.u(xl[j], xu[j])
                if o.integerData {
                    // interior point of the box when it has one; otherwise sit on a bound with d = 0
                    if xu[j] - xl[j] >= 2 { x[j] = xl[j] + Double(g.int(1, Int(xu[j] - xl[j]) - 1)) }
                }
                d[j] = 0
            }
            kinds["boxed", default: 0] += 1
        case 6: // fixed
            xl[j] = val(-3, 3); xu[j] = xl[j]; x[j] = xl[j]
            d[j] = o.integerData ? Double(g.int(-5, 5)) : g.u(-5, 5)
            kinds["fixed", default: 0] += 1
        default: // free
            xl[j] = -.infinity; xu[j] = .infinity; x[j] = val(-4, 4); d[j] = 0
            kinds["free", default: 0] += 1
        }
    }
    var s = [Double](repeating: 0, count: m)
    for i in 0..<m { for j in 0..<n { s[i] += A[i][j] * x[j] } }
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    var y = [Double](repeating: 0, count: m)
    var rkinds: [String: Int] = [:]
    for i in 0..<m {
        let kind = g.int(0, o.allowRanged ? 6 : 5)
        switch kind {
        case 0: // equality
            rl[i] = s[i]; ru[i] = s[i]
            y[i] = o.integerData ? Double(g.int(-4, 4)) : g.u(-4, 4)
            rkinds["eq", default: 0] += 1
        case 1, 2: // >= active or not
            if g.chance(0.6) { rl[i] = s[i]; y[i] = pos() } else { rl[i] = s[i] - val(1, 5); y[i] = 0 }
            rkinds["ge", default: 0] += 1
        case 3, 4: // <=
            if g.chance(0.6) { ru[i] = s[i]; y[i] = -pos() } else { ru[i] = s[i] + val(1, 5); y[i] = 0 }
            rkinds["le", default: 0] += 1
        case 5: // free row, or a redundant inactive one
            if g.chance(0.3) { y[i] = 0 } else { rl[i] = s[i] - val(1, 3); ru[i] = .infinity; y[i] = 0 }
            rkinds["free/inactive", default: 0] += 1
        default: // ranged
            let r = g.int(0, 2)
            if r == 0 { rl[i] = s[i]; ru[i] = s[i] + val(1, 5); y[i] = pos() } else if r == 1 {
                ru[i] = s[i]; rl[i] = s[i] - val(1, 5); y[i] = -pos()
            } else { rl[i] = s[i] - val(1, 3); ru[i] = s[i] + val(1, 3); y[i] = 0 }
            rkinds["ranged", default: 0] += 1
        }
    }
    // c (minimization form) = Aᵀy + d
    var cmin = d
    for j in 0..<n { for i in 0..<m { cmin[j] += A[i][j] * y[i] } }
    var optMin = 0.0
    for j in 0..<n { optMin += cmin[j] * x[j] }
    let c = o.maximize ? cmin.map { -$0 } : cmin
    let lp = LP(m: m, n: n, A: A, c: c, c0: 0, maximize: o.maximize, xl: xl, xu: xu, rl: rl, ru: ru)
    let tags = kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") + ";"
        + rkinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    return Planted(lp: lp, x: x, y: y, d: d, opt: o.maximize ? -optMin : optMin, tags: tags)
}

/// An infeasible model: a planted Farkas vector yF with yFᵀA x ≤ U on the column box and the
/// row bounds chosen so that every feasible s has yFᵀs ≥ U + gap.
func plantedInfeasible(seed: UInt64, m: Int, n: Int, free: Bool) -> LP {
    var g = RNG(seed ^ 0xFEED)
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    for i in 0..<m { for j in 0..<n where g.chance(0.5) { A[i][j] = Double(g.int(-6, 6)) } }
    var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: 0, count: n)
    for j in 0..<n { xl[j] = Double(g.int(-3, 0)); xu[j] = xl[j] + Double(g.int(1, 5)) }
    // y on the rows: a few nonzeros
    var yF = [Double](repeating: 0, count: m)
    for i in 0..<m where g.chance(0.6) { yF[i] = Double(g.int(1, 3)) * (g.chance(0.5) ? 1 : -1) }
    if !yF.contains(where: { $0 != 0 }) { yF[0] = 1 }
    if free {
        // free columns: make z_j = 0 exactly on them by adjusting a coefficient of a row whose
        // multiplier is forced to ±1 (integer data keeps the cancellation exact)
        let k = yF.firstIndex(where: { $0 != 0 })!
        yF[k] = yF[k] > 0 ? 1 : -1
        for j in 0..<n where g.chance(0.3) {
            xl[j] = -.infinity; xu[j] = .infinity
            var z = 0.0
            for i in 0..<m where i != k { z += A[i][j] * yF[i] }
            A[k][j] = -z / yF[k]
        }
    }
    var z = [Double](repeating: 0, count: n)
    for i in 0..<m { for j in 0..<n { z[j] += A[i][j] * yF[i] } }
    var U = 0.0
    for j in 0..<n where z[j] != 0 { U += z[j] > 0 ? z[j] * xu[j] : z[j] * xl[j] }
    // pick a point x0 inside the box, s0 = A x0, then shift the rows so that yFᵀ s ≥ U + gap
    var x0 = [Double](repeating: 0, count: n)
    for j in 0..<n { x0[j] = xl[j].isFinite ? (xl[j] + xu[j]) / 2 : 0 }
    var s0 = [Double](repeating: 0, count: m)
    for i in 0..<m { for j in 0..<n { s0[i] += A[i][j] * x0[j] } }
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    // inf over rows of yF_i s_i must exceed U: yF_i > 0 needs rl_i, yF_i < 0 needs ru_i
    var L = 0.0
    for i in 0..<m {
        if yF[i] > 0 { rl[i] = s0[i].rounded(); if g.chance(0.4) { ru[i] = rl[i] + Double(g.int(0, 4)) } }
        else if yF[i] < 0 { ru[i] = s0[i].rounded(); if g.chance(0.4) { rl[i] = ru[i] - Double(g.int(0, 4)) } }
        else { rl[i] = s0[i].rounded() - Double(g.int(1, 9)); if g.chance(0.5) { ru[i] = rl[i] + 20 } }
        if yF[i] > 0 { L += yF[i] * rl[i] } else if yF[i] < 0 { L += yF[i] * ru[i] }
    }
    // shift one row with yF != 0 so that L ≥ U + gap
    let gap = Double(g.int(1, 3))
    if L < U + gap {
        let k = yF.firstIndex(where: { $0 != 0 })!
        let need = (U + gap - L) / abs(yF[k])
        if yF[k] > 0 { rl[k] += need.rounded(.up); if ru[k] < .infinity { ru[k] += need.rounded(.up) } } else {
            ru[k] -= need.rounded(.up); if rl[k] > -.infinity { rl[k] -= need.rounded(.up) }
        }
    }
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = Double(g.int(-5, 5)) }
    return LP(m: m, n: n, A: A, c: c, c0: 0, maximize: g.chance(0.5), xl: xl, xu: xu, rl: rl, ru: ru)
}

/// An unbounded model: a planted feasible point x0 and a direction r in the recession cone
/// with an improving objective. Rows: those touched by Ar ≠ 0 get the one-sided bound that r
/// respects; the others any bounds around A x0.
func plantedUnbounded(seed: UInt64, m: Int, n: Int, maximize: Bool) -> LP {
    var g = RNG(seed ^ 0xBEEF)
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    for i in 0..<m { for j in 0..<n where g.chance(0.5) { A[i][j] = Double(g.int(-6, 6)) } }
    var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: .infinity, count: n)
    var r = [Double](repeating: 0, count: n)
    var x0 = [Double](repeating: 0, count: n)
    for j in 0..<n {
        let k = g.int(0, 3)
        switch k {
        case 0: xl[j] = 0; xu[j] = .infinity; x0[j] = Double(g.int(0, 3)); r[j] = g.chance(0.5) ? Double(g.int(0, 2)) : 0
        case 1: xl[j] = -.infinity; xu[j] = Double(g.int(-2, 2)); x0[j] = xu[j] - Double(g.int(0, 2)); r[j] = g.chance(0.5) ? -Double(g.int(0, 2)) : 0
        case 2: xl[j] = Double(g.int(-3, 0)); xu[j] = xl[j] + Double(g.int(1, 4)); x0[j] = xl[j]; r[j] = 0
        default: xl[j] = -.infinity; xu[j] = .infinity; x0[j] = Double(g.int(-2, 2)); r[j] = g.chance(0.5) ? Double(g.int(-2, 2)) : 0
        }
    }
    if !r.contains(where: { $0 != 0 }) { xl[0] = 0; xu[0] = .infinity; x0[0] = 0; r[0] = 1 }
    var s0 = [Double](repeating: 0, count: m), ar = [Double](repeating: 0, count: m)
    for i in 0..<m { for j in 0..<n { s0[i] += A[i][j] * x0[j]; ar[i] += A[i][j] * r[j] } }
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    for i in 0..<m {
        if ar[i] > 0 { rl[i] = s0[i] - Double(g.int(0, 3)) }          // only a lower bound
        else if ar[i] < 0 { ru[i] = s0[i] + Double(g.int(0, 3)) }     // only an upper bound
        else {
            let k = g.int(0, 2)
            if k == 0 { rl[i] = s0[i]; ru[i] = s0[i] } else if k == 1 { rl[i] = s0[i] - Double(g.int(0, 2)); ru[i] = s0[i] + Double(g.int(0, 2)) } else { ru[i] = s0[i] }
        }
    }
    // c with c·r strictly improving: random c, then fix the sign along r
    var c = (0..<n).map { _ in Double(g.int(-4, 4)) }
    var cr = 0.0
    for j in 0..<n { cr += c[j] * r[j] }
    let want: Double = maximize ? 1 : -1
    if cr * want <= 0 {
        let j = r.firstIndex(where: { $0 != 0 })!
        let need = (abs(cr) + 1) / abs(r[j])
        c[j] += want * need.rounded(.up) * (r[j] > 0 ? 1 : -1)
    }
    return LP(m: m, n: n, A: A, c: c, c0: 0, maximize: maximize, xl: xl, xu: xu, rl: rl, ru: ru)
}

/// Hilbert LP, own construction: H x = b with b = H·1 (computed in floating point), min cᵀx with
/// c = Hᵀ1 so that y = 1 is dual optimal for the covering and equality forms.
func hilbertLP(order k: Int, form: Int) -> (lp: LP, opt: Double) {
    var A = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
    for i in 0..<k { for j in 0..<k { A[i][j] = 1 / Double(i + j + 1) } }
    var b = [Double](repeating: 0, count: k), c = [Double](repeating: 0, count: k)
    for i in 0..<k { for j in 0..<k { b[i] += A[i][j]; c[j] += A[i][j] } }
    let zero = [Double](repeating: 0, count: k), inf = [Double](repeating: .infinity, count: k)
    let ninf = [Double](repeating: -.infinity, count: k)
    let opt = b.reduce(0, +)
    switch form {
    case 0: return (LP(m: k, n: k, A: A, c: c, maximize: false, xl: zero, xu: inf, rl: b, ru: b), opt)
    case 1: return (LP(m: k, n: k, A: A, c: c, maximize: false, xl: ninf, xu: inf, rl: b, ru: b), opt)
    case 2: return (LP(m: k, n: k, A: A, c: c, maximize: false, xl: zero, xu: inf, rl: b, ru: inf), opt)
    default: return (LP(m: k, n: k, A: A, c: c, maximize: true, xl: zero, xu: inf, rl: ninf, ru: b), opt)
    }
}

/// Klee-Minty cube (Chvátal's form): max Σ 10^{n-j} x_j, 2 Σ_{j<i} 10^{i-j} x_j + x_i ≤ 100^{i-1}.
/// Optimum: x_n = 100^{n-1}, others 0; objective 100^{n-1}.
func kleeMinty(_ k: Int) -> (lp: LP, opt: Double) {
    var A = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
    var ru = [Double](repeating: 0, count: k)
    var c = [Double](repeating: 0, count: k)
    for i in 0..<k {
        for j in 0..<i { A[i][j] = 2 * pow(10, Double(i - j)) }
        A[i][i] = 1
        ru[i] = pow(100, Double(i))
        c[i] = pow(10, Double(k - 1 - i))
    }
    let lp = LP(
        m: k, n: k, A: A, c: c, maximize: true, xl: [Double](repeating: 0, count: k),
        xu: [Double](repeating: .infinity, count: k), rl: [Double](repeating: -.infinity, count: k), ru: ru)
    return (lp, pow(100, Double(k - 1)))
}

/// Assignment LP, k × k, costs from a small set (ties: highly degenerate). The LP optimum is
/// integral (Birkhoff); reference by exhaustive search over permutations (k ≤ 8) or Hungarian.
func assignmentLP(k: Int, seed: UInt64, levels: Int) -> (lp: LP, cost: [[Double]]) {
    var g = RNG(seed ^ 0xA55)
    let cost = (0..<k).map { _ in (0..<k).map { _ in Double(g.int(0, levels - 1)) } }
    let n = k * k, m = 2 * k
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    var c = [Double](repeating: 0, count: n)
    for i in 0..<k {
        for j in 0..<k {
            let v = i * k + j
            A[i][v] = 1
            A[k + j][v] = 1
            c[v] = cost[i][j]
        }
    }
    let lp = LP(
        m: m, n: n, A: A, c: c, maximize: false, xl: [Double](repeating: 0, count: n),
        xu: [Double](repeating: .infinity, count: n), rl: [Double](repeating: 1, count: m),
        ru: [Double](repeating: 1, count: m))
    return (lp, cost)
}

/// Hungarian algorithm (O(k³)), own implementation, minimisation.
func hungarian(_ a: [[Double]]) -> Double {
    let n = a.count
    var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
    var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: n + 1)
        var used = [Bool](repeating: false, count: n + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...n where !used[j] {
                let cur = a[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                if minv[j] < delta { delta = minv[j]; j1 = j }
            }
            for j in 0...n {
                if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    var total = 0.0
    for j in 1...n { total += a[p[j] - 1][j - 1] }
    return total
}
