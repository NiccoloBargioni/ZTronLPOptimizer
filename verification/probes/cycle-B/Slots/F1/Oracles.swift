// Cycle B, finder F1: independent oracles (no package helpers used for checking).
import Foundation
import ZTronLPOptimizer

// MARK: - RNG (SplitMix64, own implementation)

struct RNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0, a.count - 1)] }
}

// MARK: - Dense helpers

func denseColumns(_ lp: CompiledLP) -> [[(Int, Double)]] {
    var cols: [[(Int, Double)]] = []
    for j in 0..<lp.n {
        var col: [(Int, Double)] = []
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { col.append((Int(lp.a.rowIndex[p]), lp.a.values[p])) }
        cols.append(col)
    }
    return cols
}

func activity(_ lp: CompiledLP, _ x: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { r[Int(lp.a.rowIndex[p])] += lp.a.values[p] * x[j] }
    }
    return r
}

/// Objective in the model's own sense, computed independently: sense-flipped internal form.
func reportedObjective(_ lp: CompiledLP, _ x: [Double]) -> Double {
    var t = lp.c0
    for j in 0..<lp.n { t += lp.c[j] * x[j] }
    return lp.sense == .maximize ? -t : t
}

// MARK: - KKT oracle

/// Checks primal feasibility, and (when y and d are given) the dual side in the convention the
/// package documents: dual[i] and reducedCosts are sensitivities of the REPORTED objective;
/// in minimization form yMin = flip*y must satisfy dMin = c - A^T yMin, sign conditions and
/// complementary slackness. Returns human-readable violations.
func kkt(_ lp: CompiledLP, x: [Double], y: [Double]?, d: [Double]?, tol: Double = 1e-6, objective: Double? = nil) -> [String] {
    var bad: [String] = []
    guard x.count == lp.n else { return ["primal has \(x.count) entries, n=\(lp.n)"] }
    for j in 0..<lp.n {
        if x[j].isNaN { bad.append("x[\(j)] is NaN"); continue }
        let t = tol * (1 + Swift.abs(x[j]))
        if x[j] < lp.xl[j] - t { bad.append("x[\(j)]=\(x[j]) < xl=\(lp.xl[j])") }
        if x[j] > lp.xu[j] + t { bad.append("x[\(j)]=\(x[j]) > xu=\(lp.xu[j])") }
    }
    let r = activity(lp, x)
    for i in 0..<lp.m {
        let t = tol * (1 + Swift.abs(r[i]))
        if r[i] < lp.rl[i] - t { bad.append("row \(i) activity \(r[i]) < rl=\(lp.rl[i])") }
        if r[i] > lp.ru[i] + t { bad.append("row \(i) activity \(r[i]) > ru=\(lp.ru[i])") }
    }
    if let objective {
        let o = reportedObjective(lp, x)
        if Swift.abs(o - objective) > tol * (1 + Swift.abs(o)) { bad.append("objectiveValue \(objective) != objective at x \(o)") }
    }
    guard let y, let d else { return bad }
    guard y.count == lp.m else { return bad + ["dual has \(y.count) entries, m=\(lp.m)"] }
    guard d.count == lp.n + lp.m else { return bad + ["reducedCosts has \(d.count) entries, n+m=\(lp.n + lp.m)"] }
    let flip: Double = lp.sense == .maximize ? -1 : 1
    let yMin = y.map { flip * $0 }
    let dMin = d.map { flip * $0 }
    let cols = denseColumns(lp)
    var scale = 1.0
    for v in lp.c { scale = Swift.max(scale, Swift.abs(v)) }
    for v in yMin { scale = Swift.max(scale, Swift.abs(v)) }
    let dt = tol * scale
    for j in 0..<lp.n {
        var expect = lp.c[j]
        for (i, a) in cols[j] { expect -= a * yMin[i] }
        if Swift.abs(expect - dMin[j]) > dt * 10 { bad.append("d[\(j)]=\(dMin[j]) != c - A^T y = \(expect)") }
        let dj = expect
        let t = tol * (1 + Swift.abs(x[j]))
        let atL = Swift.abs(x[j] - lp.xl[j]) <= t
        let atU = Swift.abs(x[j] - lp.xu[j]) <= t
        if atL && atU { continue }
        if atL { if dj < -dt { bad.append("col \(j) at lower but d=\(dj) < 0") } }
        else if atU { if dj > dt { bad.append("col \(j) at upper but d=\(dj) > 0") } }
        else if Swift.abs(dj) > dt { bad.append("col \(j) strictly inside (x=\(x[j])) but d=\(dj)") }
    }
    for i in 0..<lp.m {
        if Swift.abs(d[lp.n + i] - y[i]) > dt { bad.append("logical rc[\(lp.n + i)]=\(d[lp.n + i]) != dual[\(i)]=\(y[i])") }
        let t = tol * (1 + Swift.abs(r[i]))
        let atL = Swift.abs(r[i] - lp.rl[i]) <= t
        let atU = Swift.abs(r[i] - lp.ru[i]) <= t
        if atL && atU { continue }
        if atL { if yMin[i] < -dt { bad.append("row \(i) at lower but y=\(yMin[i]) < 0") } }
        else if atU { if yMin[i] > dt { bad.append("row \(i) at upper but y=\(yMin[i]) > 0") } }
        else if Swift.abs(yMin[i]) > dt { bad.append("row \(i) slack (r=\(r[i]) in [\(lp.rl[i]),\(lp.ru[i])]) but y=\(yMin[i])") }
    }
    return bad
}

/// Farkas check for a dual ray of an infeasible LP (min form): y with A^T y = z and
/// sum over rows (y>0 ? rl*y : ru*y) - sum over columns (z>0 ? xu*z : xl*z) > 0 ... we test the
/// standard sufficient certificate: the maximum of y^T A x over the box is below the minimum of
/// y^T r over the row box (or the reverse sign).
func farkasValid(_ lp: CompiledLP, ray: [Double]) -> (Bool, String) {
    guard ray.count == lp.m else { return (false, "ray has \(ray.count) entries, m=\(lp.m)") }
    // z = A^T ray
    let cols = denseColumns(lp)
    var z = [Double](repeating: 0, count: lp.n)
    for j in 0..<lp.n { for (i, a) in cols[j] { z[j] += a * ray[i] } }
    // For feasibility we need some x in box with ray^T A x = ray^T r for some r in row box.
    // Range of ray^T A x over the column box:
    var axLo = 0.0, axHi = 0.0
    for j in 0..<lp.n {
        let zj = z[j]
        if Swift.abs(zj) < 1e-12 { continue }
        let a = zj * lp.xl[j], b = zj * lp.xu[j]
        axLo += Swift.min(a, b)
        axHi += Swift.max(a, b)
    }
    var rLo = 0.0, rHi = 0.0
    for i in 0..<lp.m {
        let yi = ray[i]
        if Swift.abs(yi) < 1e-12 { continue }
        let a = yi * lp.rl[i], b = yi * lp.ru[i]
        rLo += Swift.min(a, b)
        rHi += Swift.max(a, b)
    }
    // Infeasible certificate: intervals [axLo, axHi] and [rLo, rHi] are disjoint.
    let ok = axHi < rLo - 1e-9 * (1 + Swift.abs(rLo)) || rHi < axLo - 1e-9 * (1 + Swift.abs(axLo))
    return (ok, "A^T y range [\(axLo), \(axHi)] vs y^T r range [\(rLo), \(rHi)]")
}

/// Primal ray check for unboundedness (model sense): A r stays within the recession cone of
/// the rows, r within the recession cone of the bounds, and the objective improves.
func primalRayValid(_ lp: CompiledLP, ray: [Double]) -> (Bool, String) {
    guard ray.count == lp.n else { return (false, "ray has \(ray.count) entries") }
    var cr = 0.0
    for j in 0..<lp.n { cr += lp.c[j] * ray[j] }   // internal min form must decrease
    var norm = 0.0
    for v in ray { norm = Swift.max(norm, Swift.abs(v)) }
    if norm == 0 { return (false, "zero ray") }
    let t = 1e-9 * norm
    var why: [String] = []
    if cr >= -t { why.append("c^T r = \(cr) does not improve") }
    for j in 0..<lp.n {
        if ray[j] < -t && lp.xl[j] > -.infinity { why.append("r[\(j)] < 0 but xl finite") }
        if ray[j] > t && lp.xu[j] < .infinity { why.append("r[\(j)] > 0 but xu finite") }
    }
    let ar = activity(lp, ray)
    for i in 0..<lp.m {
        if ar[i] < -1e-7 * norm && lp.rl[i] > -.infinity { why.append("(Ar)[\(i)] < 0 but rl finite") }
        if ar[i] > 1e-7 * norm && lp.ru[i] < .infinity { why.append("(Ar)[\(i)] > 0 but ru finite") }
    }
    return (why.isEmpty, why.joined(separator: "; "))
}

// MARK: - Random LP generator with a known feasible point

struct GenOptions {
    var maxN = 7
    var maxM = 6
    var boundedOnly = true       // every column finite on both sides -> optimum exists
    var integerData = true
    var specials = true          // fixed columns, singleton/empty rows, empty columns, duplicates
}

func randomLP(seed: UInt64, _ o: GenOptions = GenOptions()) -> (lp: CompiledLP, x0: [Double]) {
    var g = RNG(seed)
    let n = g.int(1, o.maxN)
    let m = g.int(0, o.maxM)
    func val(_ lo: Double, _ hi: Double) -> Double {
        o.integerData ? Double(g.int(Int(lo), Int(hi))) : lo + (hi - lo) * g.unit()
    }
    var x0 = [Double](repeating: 0, count: n)
    var xl = [Double](repeating: 0, count: n)
    var xu = [Double](repeating: 0, count: n)
    for j in 0..<n {
        x0[j] = val(-4, 4)
        let kind = g.int(0, o.boundedOnly ? 3 : 7)
        switch kind {
        case 0: xl[j] = x0[j] - val(0, 3); xu[j] = x0[j] + val(0, 3)
        case 1: xl[j] = x0[j]; xu[j] = x0[j]                         // fixed
        case 2: xl[j] = Swift.min(0, x0[j]); xu[j] = x0[j] + val(1, 4)
        case 3: xl[j] = x0[j] - val(1, 4); xu[j] = Swift.max(x0[j], 1)
        case 4: xl[j] = -.infinity; xu[j] = .infinity
        case 5: xl[j] = x0[j] - val(0, 3); xu[j] = .infinity
        case 6: xl[j] = -.infinity; xu[j] = x0[j] + val(0, 3)
        default: x0[j] = Swift.abs(x0[j]); xl[j] = 0; xu[j] = .infinity
        }
        if !o.specials && xl[j] == xu[j] { xu[j] += 1 }
    }
    var entries: [(row: Int, col: Int, value: Double)] = []
    var rl = [Double](repeating: 0, count: m)
    var ru = [Double](repeating: 0, count: m)
    var rows: [[(Int, Double)]] = []
    for i in 0..<m {
        var row: [(Int, Double)] = []
        let shape = o.specials ? g.int(0, 9) : 5
        if shape == 0 {
            // empty row
        } else if shape == 1 {
            row.append((g.int(0, n - 1), val(-5, 5) == 0 ? 2 : val(-5, 5)))
        } else if shape == 2 && i > 0 && !rows[i - 1].isEmpty {
            row = rows[i - 1].map { ($0.0, $0.1 * 2) }            // duplicate (scaled) row
        } else {
            for j in 0..<n where g.chance(0.6) {
                var a = val(-5, 5)
                if a == 0 { a = 1 }
                row.append((j, a))
            }
        }
        if row.contains(where: { $0.1 == 0 }) { row = row.filter { $0.1 != 0 } }
        // merge duplicate columns
        var merged: [Int: Double] = [:]
        for (j, a) in row { merged[j, default: 0] += a }
        row = merged.filter { $0.value != 0 }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        rows.append(row)
        var act = 0.0
        for (j, a) in row { act += a * x0[j]; entries.append((i, j, a)) }
        let t = g.int(0, 4)
        switch t {
        case 0: rl[i] = -.infinity; ru[i] = act + val(0, 3)
        case 1: rl[i] = act - val(0, 3); ru[i] = .infinity
        case 2: rl[i] = act; ru[i] = act
        case 3: rl[i] = act - val(0, 3); ru[i] = act + val(0, 3)
        default: rl[i] = act - val(0, 2); ru[i] = act + val(1, 3)
        }
    }
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = (o.specials && g.chance(0.2)) ? 0 : val(-6, 6) }
    let maximize = g.chance(0.5)
    let c0 = val(-3, 3)
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    // c is stored for minimization: the model's objective is cm; stored c = flip*cm
    let lp = CompiledLP(
        a: a, c: maximize ? c.map { $0 == 0 ? 0 : -$0 } : c, c0: maximize ? -c0 : c0,
        sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru)
    return (lp, x0)
}

// MARK: - Structural equality of two CompiledLPs

func structuralDiff(_ p: CompiledLP, _ q: CompiledLP, names: Bool = true) -> String? {
    if p.m != q.m || p.n != q.n { return "shape \(p.m)x\(p.n) vs \(q.m)x\(q.n)" }
    if p.sense != q.sense { return "sense" }
    if p.c != q.c { return "c \(p.c) vs \(q.c)" }
    if p.c0 != q.c0 { return "c0 \(p.c0) vs \(q.c0)" }
    if p.xl != q.xl { return "xl \(p.xl) vs \(q.xl)" }
    if p.xu != q.xu { return "xu \(p.xu) vs \(q.xu)" }
    if p.rl != q.rl { return "rl \(p.rl) vs \(q.rl)" }
    if p.ru != q.ru { return "ru \(p.ru) vs \(q.ru)" }
    if p.a.colStart != q.a.colStart || p.a.rowIndex != q.a.rowIndex || p.a.values != q.a.values { return "matrix" }
    if p.integerColumns != q.integerColumns { return "integerColumns \(p.integerColumns) vs \(q.integerColumns)" }
    if names && (p.names.columns != q.names.columns || p.names.rows != q.names.rows) {
        return "names \(p.names.columns)/\(p.names.rows) vs \(q.names.columns)/\(q.names.rows)"
    }
    return nil
}

/// True when the problem data contain something no well-formed LP has.
func invalidData(_ lp: CompiledLP) -> String? {
    for j in 0..<lp.n {
        if lp.c[j].isNaN || lp.c[j].isInfinite { return "c[\(j)]=\(lp.c[j])" }
        if lp.xl[j].isNaN || lp.xu[j].isNaN { return "NaN bound on column \(j)" }
        if lp.xl[j] == .infinity { return "xl[\(j)] = +inf" }
        if lp.xu[j] == -.infinity { return "xu[\(j)] = -inf" }
    }
    if !lp.c0.isFinite { return "c0=\(lp.c0)" }
    for i in 0..<lp.m {
        if lp.rl[i].isNaN || lp.ru[i].isNaN { return "NaN bound on row \(i)" }
        if lp.rl[i] == .infinity { return "rl[\(i)] = +inf" }
        if lp.ru[i] == -.infinity { return "ru[\(i)] = -inf" }
    }
    for v in lp.a.values where !v.isFinite { return "coefficient \(v)" }
    return nil
}

// MARK: - Brute force for small pure-integer programs

func bruteForceIP(_ lp: CompiledLP, limit: Int = 2_000_000) -> (status: String, best: Double?, x: [Double]?) {
    let n = lp.n
    var lo = [Int](repeating: 0, count: n)
    var hi = [Int](repeating: 0, count: n)
    var count = 1
    for j in 0..<n {
        lo[j] = Int((lp.xl[j] - 1e-9).rounded(.up))
        hi[j] = Int((lp.xu[j] + 1e-9).rounded(.down))
        if hi[j] < lo[j] { return ("infeasible", nil, nil) }
        count *= (hi[j] - lo[j] + 1)
        if count > limit { return ("too-big", nil, nil) }
    }
    var x = lo.map(Double.init)
    var best: Double? = nil
    var bestX: [Double]? = nil
    var idx = lo
    while true {
        for j in 0..<n { x[j] = Double(idx[j]) }
        let r = activity(lp, x)
        var ok = true
        for i in 0..<lp.m where r[i] < lp.rl[i] - 1e-9 || r[i] > lp.ru[i] + 1e-9 { ok = false; break }
        if ok {
            let o = reportedObjective(lp, x)
            let better: Bool
            if let b = best { better = lp.sense == .maximize ? o > b : o < b } else { better = true }
            if better { best = o; bestX = x }
        }
        var k = 0
        while k < n {
            idx[k] += 1
            if idx[k] <= hi[k] { break }
            idx[k] = lo[k]
            k += 1
        }
        if k == n { break }
    }
    return (best == nil ? "infeasible" : "optimal", best, bestX)
}

func statusName(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infeasibleOrUnbounded"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let m): return "numericalFailure(\(m.prefix(60)))"
    }
}

func ctx(_ seconds: Double = 10) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.threads = 2
    c.metal = .off
    return c
}

func describeLP(_ lp: CompiledLP) -> String {
    var s = "sense=\(lp.sense) m=\(lp.m) n=\(lp.n) c=\(lp.c) c0=\(lp.c0)\n xl=\(lp.xl)\n xu=\(lp.xu)\n rl=\(lp.rl)\n ru=\(lp.ru)\n int=\(lp.integerColumns)\n"
    for i in 0..<lp.m {
        var row: [String] = []
        for j in 0..<lp.n {
            let v = lp.a[i, j]
            if v != 0 { row.append("\(v)*x\(j)") }
        }
        s += "  r\(i): \(row.joined(separator: " + "))\n"
    }
    return s
}
