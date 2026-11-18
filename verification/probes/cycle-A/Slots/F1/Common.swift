// Cycle A, finder F1: shared helpers (independent oracles: KKT, basis, rays, generators).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let inf = Double.infinity

func fmt(_ v: Double) -> String { String(format: "%.6g", v) }

/// Dense matrix of a CompiledLP (small problems only).
func dense(_ lp: CompiledLP) -> [[Double]] {
    var A = [[Double]](repeating: [Double](repeating: 0, count: lp.n), count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            A[Int(lp.a.rowIndex[p])][j] += lp.a.values[p]
        }
    }
    return A
}

func activity(_ A: [[Double]], _ x: [Double]) -> [Double] {
    A.map { row in zip(row, x).reduce(0) { $0 + $1.0 * $1.1 } }
}

struct KKTReport {
    var primalViolation = 0.0      // relative
    var dualSignViolation = 0.0    // relative to cost scale
    var reducedCostMismatch = 0.0  // |d - (c - A^T y)|
    var logicalMismatch = 0.0      // |d[n+i] - y[i]|
    var objectiveMismatch = 0.0    // |reported - c^T x - c0|
    var dualityGap = 0.0           // relative
    var notes: [String] = []
    var ok: Bool {
        primalViolation <= 1e-6 && dualSignViolation <= 1e-6 && reducedCostMismatch <= 1e-6
            && logicalMismatch <= 1e-9 && objectiveMismatch <= 1e-7 && dualityGap <= 1e-6
    }
    var summary: String {
        "pv=\(fmt(primalViolation)) dsv=\(fmt(dualSignViolation)) rc=\(fmt(reducedCostMismatch)) log=\(fmt(logicalMismatch)) obj=\(fmt(objectiveMismatch)) gap=\(fmt(dualityGap)) \(notes.prefix(3).joined(separator: "; "))"
    }
}

/// Independent KKT check of an LP result on the ORIGINAL problem. `dualRep`, `rcRep` are in
/// the model's sense (as the analysis reports them).
func kkt(_ lp: CompiledLP, x: [Double], dualRep: [Double]?, rcRep: [Double]?, objective: Double?) -> KKTReport {
    var r = KKTReport()
    let A = dense(lp)
    let s = activity(A, x)
    let flip: Double = lp.sense == .maximize ? -1 : 1
    for j in 0..<lp.n {
        let v = max(lp.xl[j] - x[j], x[j] - lp.xu[j], 0) / (1 + min(abs(x[j]), 1e6))
        if v > r.primalViolation { r.primalViolation = v; if v > 1e-6 { r.notes.append("col \(j) x=\(x[j]) [\(lp.xl[j]),\(lp.xu[j])]") } }
        if x[j].isNaN { r.primalViolation = .infinity; r.notes.append("x[\(j)] NaN") }
    }
    for i in 0..<lp.m {
        let v = max(lp.rl[i] - s[i], s[i] - lp.ru[i], 0) / (1 + min(abs(s[i]), 1e6))
        if v > r.primalViolation { r.primalViolation = v; if v > 1e-6 { r.notes.append("row \(i) s=\(s[i]) [\(lp.rl[i]),\(lp.ru[i])]") } }
    }
    if let objective {
        let expect = lp.objective(at: x)
        r.objectiveMismatch = abs(objective - expect) / (1 + abs(expect))
        if r.objectiveMismatch > 1e-7 { r.notes.append("objective \(objective) vs c'x+c0=\(expect)") }
    }
    guard let dualRep, let rcRep else { r.notes.append("no duals"); return r }
    if dualRep.count != lp.m || rcRep.count != lp.n + lp.m {
        r.notes.append("dual sizes \(dualRep.count)/\(rcRep.count) for m=\(lp.m) n=\(lp.n)")
        r.reducedCostMismatch = .infinity
        return r
    }
    let y = dualRep.map { flip * $0 }
    let d = rcRep.map { flip * $0 }
    let cscale = 1 + (lp.c.map { abs($0) }.max() ?? 0)
    // d = c - A^T y
    for j in 0..<lp.n {
        var aty = 0.0
        var mag = abs(lp.c[j])
        for i in 0..<lp.m { aty += A[i][j] * y[i]; mag += abs(A[i][j] * y[i]) }
        let diff = abs(d[j] - (lp.c[j] - aty)) / (1 + mag)
        if diff > r.reducedCostMismatch { r.reducedCostMismatch = diff; if diff > 1e-6 { r.notes.append("d[\(j)]=\(d[j]) vs c-A'y=\(lp.c[j] - aty)") } }
    }
    for i in 0..<lp.m {
        let diff = abs(d[lp.n + i] - y[i])
        if diff > r.logicalMismatch { r.logicalMismatch = diff; if diff > 1e-9 { r.notes.append("logical d[n+\(i)]=\(d[lp.n + i]) vs y=\(y[i])") } }
    }
    // Sign conditions (minimization form), complementary slackness.
    func tolAt(_ v: Double) -> Double { 1e-7 * (1 + abs(v)) * 10 }
    for j in 0..<lp.n {
        let atL = lp.xl[j] > -inf && abs(x[j] - lp.xl[j]) <= tolAt(lp.xl[j])
        let atU = lp.xu[j] < inf && abs(x[j] - lp.xu[j]) <= tolAt(lp.xu[j])
        var v = 0.0
        if atL && atU { v = 0 } else if atL { v = max(0, -d[j]) } else if atU { v = max(0, d[j]) } else { v = abs(d[j]) }
        v /= cscale
        if v > r.dualSignViolation { r.dualSignViolation = v; if v > 1e-6 { r.notes.append("col \(j) d=\(d[j]) x=\(x[j]) atL=\(atL) atU=\(atU)") } }
    }
    for i in 0..<lp.m {
        let atL = lp.rl[i] > -inf && abs(s[i] - lp.rl[i]) <= tolAt(lp.rl[i])
        let atU = lp.ru[i] < inf && abs(s[i] - lp.ru[i]) <= tolAt(lp.ru[i])
        var v = 0.0
        if atL && atU { v = 0 } else if atL { v = max(0, -y[i]) } else if atU { v = max(0, y[i]) } else { v = abs(y[i]) }
        v /= cscale
        if v > r.dualSignViolation { r.dualSignViolation = v; if v > 1e-6 { r.notes.append("row \(i) y=\(y[i]) s=\(s[i]) [\(lp.rl[i]),\(lp.ru[i])]") } }
    }
    // Dual objective (minimization form).
    var dobj = lp.c0
    var finite = true
    for i in 0..<lp.m {
        if abs(y[i]) <= 1e-9 { dobj += y[i] * s[i]; continue }
        let b = y[i] > 0 ? lp.rl[i] : lp.ru[i]
        if b.isInfinite { finite = false; dobj += y[i] * s[i] } else { dobj += y[i] * b }
    }
    for j in 0..<lp.n {
        if abs(d[j]) <= 1e-9 { dobj += d[j] * x[j]; continue }
        let b = d[j] > 0 ? lp.xl[j] : lp.xu[j]
        if b.isInfinite { finite = false; dobj += d[j] * x[j] } else { dobj += d[j] * b }
    }
    let pobj = lp.internalObjective(at: x)
    r.dualityGap = abs(pobj - dobj) / (1 + abs(pobj))
    if !finite { r.notes.append("nonzero multiplier on an infinite bound") }
    if r.dualityGap > 1e-6 { r.notes.append("primal \(pobj) dual \(dobj)") }
    return r
}

/// Dense Gaussian elimination with partial pivoting; returns nil when singular.
func solveDense(_ M: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var a = M
    var rhs = b
    for k in 0..<n {
        var p = k
        for i in k..<n where abs(a[i][k]) > abs(a[p][k]) { p = i }
        if abs(a[p][k]) < 1e-12 { return nil }
        a.swapAt(k, p); rhs.swapAt(k, p)
        for i in (k + 1)..<max(k + 1, n) {
            let f = a[i][k] / a[k][k]
            if f == 0 { continue }
            for jj in k..<n { a[i][jj] -= f * a[k][jj] }
            rhs[i] -= f * rhs[k]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for k in stride(from: n - 1, through: 0, by: -1) {
        var s = rhs[k]
        for jj in (k + 1)..<max(k + 1, n) { s -= a[k][jj] * x[jj] }
        x[k] = s / a[k][k]
    }
    return x
}

/// Checks that `basis` is a valid basis of `lp` [A -I] that reproduces x and (if given) y.
func checkBasis(_ lp: CompiledLP, _ basis: Basis, x: [Double], dualRep: [Double]?, rcRep: [Double]?) -> [String] {
    var problems: [String] = []
    let n = lp.n, m = lp.m
    guard basis.status.count == n + m else { return ["status count \(basis.status.count) != n+m \(n + m)"] }
    let basicByStatus = (0..<(n + m)).filter { basis.status[$0] == .basic }
    if basicByStatus.count != m { problems.append("basic statuses \(basicByStatus.count) != m \(m)") }
    if basis.basic.count != m { problems.append("basic list \(basis.basic.count) != m \(m)") }
    if Set(basis.basic.map { Int($0) }) != Set(basicByStatus) { problems.append("basic list differs from statuses") }
    let A = dense(lp)
    let s = activity(A, x)
    func value(_ k: Int) -> Double { k < n ? x[k] : s[k - n] }
    func lo(_ k: Int) -> Double { k < n ? lp.xl[k] : lp.rl[k - n] }
    func hi(_ k: Int) -> Double { k < n ? lp.xu[k] : lp.ru[k - n] }
    for k in 0..<(n + m) where basis.status[k] != .basic {
        let v = value(k)
        let tol = 1e-6 * (1 + abs(v))
        switch basis.status[k] {
        case .atLower: if !(lo(k) > -inf && abs(v - lo(k)) <= tol) { problems.append("k=\(k) atLower but value \(v) lo \(lo(k))") }
        case .atUpper: if !(hi(k) < inf && abs(v - hi(k)) <= tol) { problems.append("k=\(k) atUpper but value \(v) hi \(hi(k))") }
        case .fixed: if !(lo(k) == hi(k) && abs(v - lo(k)) <= tol) { problems.append("k=\(k) fixed but [\(lo(k)),\(hi(k))] value \(v)") }
        case .free: if !(abs(v) <= tol) { problems.append("k=\(k) free nonbasic but value \(v)") }
        default: break
        }
    }
    guard basicByStatus.count == m, problems.isEmpty || !problems.contains(where: { $0.hasPrefix("basic") }) else { return problems }
    // B x_B = - N x_N for [A -I][x; s] = 0
    if m > 0 {
        var B = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for (col, k) in basicByStatus.enumerated() {
            for i in 0..<m { B[i][col] = k < n ? A[i][k] : (i == k - n ? -1 : 0) }
        }
        var rhs = [Double](repeating: 0, count: m)
        for k in 0..<(n + m) where basis.status[k] != .basic {
            let v = value(k)
            for i in 0..<m { rhs[i] -= (k < n ? A[i][k] : (i == k - n ? -1 : 0)) * v }
        }
        if let xb = solveDense(B, rhs) {
            for (col, k) in basicByStatus.enumerated() {
                let diff = abs(xb[col] - value(k))
                if diff > 1e-6 * (1 + abs(value(k))) { problems.append("basic k=\(k) value \(value(k)) but B^-1 gives \(xb[col])") }
            }
        } else {
            problems.append("basis matrix singular")
        }
    }
    if let dualRep, let rcRep, rcRep.count == n + m {
        let flip: Double = lp.sense == .maximize ? -1 : 1
        for k in basicByStatus {
            let d = flip * rcRep[k]
            if abs(d) > 1e-6 * (1 + (lp.c.map { abs($0) }.max() ?? 0)) { problems.append("basic k=\(k) has reduced cost \(d)") }
        }
        _ = dualRep
    }
    return problems
}

/// Checks a primal ray in the original space: feasible direction that improves the objective.
func checkPrimalRay(_ lp: CompiledLP, _ ray: [Double]) -> String? {
    guard ray.count == lp.n else { return "ray size \(ray.count) != n \(lp.n)" }
    let norm = ray.map { abs($0) }.max() ?? 0
    guard norm > 0 else { return "zero ray" }
    let r = ray.map { $0 / norm }
    let tol = 1e-7
    for j in 0..<lp.n {
        if lp.xl[j] > -inf && r[j] < -tol { return "ray leaves lower bound of col \(j): \(r[j])" }
        if lp.xu[j] < inf && r[j] > tol { return "ray leaves upper bound of col \(j): \(r[j])" }
    }
    let ar = activity(dense(lp), r)
    for i in 0..<lp.m {
        if lp.rl[i] > -inf && ar[i] < -tol { return "ray violates row \(i) lower: \(ar[i])" }
        if lp.ru[i] < inf && ar[i] > tol { return "ray violates row \(i) upper: \(ar[i])" }
    }
    let cr = zip(lp.c, r).reduce(0) { $0 + $1.0 * $1.1 }
    if !(cr < -1e-9) { return "ray does not improve the min-form objective: c'r=\(cr)" }
    return nil
}

/// Farkas check, convention free: tries y and -y.
func checkFarkas(_ lp: CompiledLP, _ yIn: [Double]) -> String? {
    guard yIn.count == lp.m else { return "dual ray size \(yIn.count) != m \(lp.m)" }
    let A = dense(lp)
    func certifies(_ y: [Double]) -> Double? {
        // For feasible x: y'Ax <= sum_i max_{s in [rl,ru]} y_i s  and  y'Ax >= sum_j min_{x in [xl,xu]} (A'y)_j x_j
        var upper = 0.0
        for i in 0..<lp.m where y[i] != 0 {
            let b = y[i] > 0 ? lp.ru[i] : lp.rl[i]
            if abs(y[i]) < 1e-12 { continue }
            if b.isInfinite { return nil }
            upper += y[i] * b
        }
        var lower = 0.0
        for j in 0..<lp.n {
            var g = 0.0
            for i in 0..<lp.m { g += A[i][j] * y[i] }
            if abs(g) < 1e-9 { continue }
            let b = g > 0 ? lp.xl[j] : lp.xu[j]
            if b.isInfinite { return nil }
            lower += g * b
        }
        return lower - upper
    }
    let scale = 1 + (yIn.map { abs($0) }.max() ?? 0)
    let y = yIn.map { $0 / scale }
    let a = certifies(y), b = certifies(y.map { -$0 })
    if let a, a > 1e-9 { return nil }
    if let b, b > 1e-9 { return nil }
    return "not a Farkas certificate (margins \(a.map(fmt) ?? "inf"), \(b.map(fmt) ?? "inf"))"
}

func statusKey(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infOrUnb"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let t): return "numericalFailure(\(t.prefix(60)))"
    }
}

func ctx(_ seconds: Double = 10) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.threads = 1
    c.metal = .off
    return c
}

func buildLP(_ rows: [[Double]], rl: [Double], ru: [Double], c: [Double], xl: [Double], xu: [Double],
             c0: Double = 0, sense: ObjectiveSense = .minimize, integer: [Int32] = [],
             names: LPNames? = nil) -> CompiledLP {
    let m = rows.count
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where rows[i][j] != 0 { entries.append((i, j, rows[i][j])) } }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    // c is given in the model's sense; store minimization form.
    let flip = sense == .maximize
    return CompiledLP(a: a, c: flip ? c.map { $0 == 0 ? 0 : -$0 } : c, c0: flip ? -c0 : c0, sense: sense,
                      xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer, names: names)
}

/// Random LP built around a feasible point, with features that exercise every presolve rule.
func presolveRichLP(seed: UInt64, m: Int, n: Int, infeasibleVariant: Bool = false) -> CompiledLP {
    var g = SeededGenerator(seed: seed)
    var x0 = [Double](repeating: 0, count: n)
    var xl = [Double](repeating: 0, count: n)
    var xu = [Double](repeating: 0, count: n)
    var emptyColumn = [Bool](repeating: false, count: n)
    for j in 0..<n {
        x0[j] = Double(g.integer(in: -6...6)) / 2
        let kind = g.integer(in: 0...9)
        switch kind {
        case 0, 1: xl[j] = x0[j]; xu[j] = x0[j]                            // fixed
        case 2: xl[j] = -inf; xu[j] = inf                                  // free (risk unbounded)
        case 3: xl[j] = x0[j] - Double(g.integer(in: 0...3)); xu[j] = inf
        case 4: xl[j] = -inf; xu[j] = x0[j] + Double(g.integer(in: 0...3))
        default: xl[j] = x0[j] - Double(g.integer(in: 0...4)); xu[j] = x0[j] + Double(g.integer(in: 0...4))
        }
        emptyColumn[j] = g.chance(0.12)
    }
    var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
    for i in 0..<m {
        let shape = g.integer(in: 0...9)
        if shape == 0 { continue }                                           // empty row
        if shape <= 3 {                                                       // singleton row
            let j = g.integer(in: 0...(n - 1))
            if !emptyColumn[j] { rows[i][j] = Double(g.integer(in: 1...4)) * (g.chance(0.5) ? 1 : -1) * (g.chance(0.3) ? 0.5 : 1) }
            continue
        }
        for j in 0..<n where !emptyColumn[j] && g.chance(0.4) {
            rows[i][j] = Double(g.integer(in: -5...5))
        }
    }
    let s = activity(rows, x0)
    var rl = [Double](repeating: 0, count: m)
    var ru = [Double](repeating: 0, count: m)
    for i in 0..<m {
        let t = g.integer(in: 0...5)
        let slack1 = g.chance(0.4) ? 0 : Double(g.integer(in: 1...6)) / 2
        let slack2 = g.chance(0.4) ? 0 : Double(g.integer(in: 1...6)) / 2
        switch t {
        case 0: rl[i] = s[i]; ru[i] = s[i]
        case 1: rl[i] = -inf; ru[i] = s[i] + slack1
        case 2: rl[i] = s[i] - slack1; ru[i] = inf
        case 3: rl[i] = s[i] - slack1; ru[i] = s[i] + slack2
        case 4: rl[i] = -inf; ru[i] = s[i] + slack1
        default: rl[i] = s[i] - slack2; ru[i] = inf
        }
    }
    if infeasibleVariant && m > 0 {
        let i = g.integer(in: 0...(m - 1))
        // push a row away from every feasible point: requires activity beyond its reachable range
        let reach = rows[i].enumerated().reduce(0.0) { acc, e in
            let (j, a) = e
            if a == 0 { return acc }
            let b = a > 0 ? xu[j] : xl[j]
            return acc + a * b
        }
        if reach.isFinite { rl[i] = reach + 1 + Double(g.integer(in: 0...3)); ru[i] = inf }
        else { rl[i] = 1; ru[i] = 1; for j in 0..<n { rows[i][j] = 0 } }   // empty infeasible row
    }
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = g.chance(0.2) ? 0 : Double(g.integer(in: -5...5)) }
    // Keep the LP bounded in most instances: an unbounded improving direction on a free/semi-free column
    // is allowed only with low probability.
    for j in 0..<n {
        let improvesDown = c[j] > 0 && xl[j] == -inf
        let improvesUp = c[j] < 0 && xu[j] == inf
        if (improvesDown || improvesUp) && !g.chance(0.15) {
            if improvesDown { xl[j] = x0[j] - 3 } else { xu[j] = x0[j] + 3 }
        }
    }
    let sense: ObjectiveSense = g.chance(0.5) ? .maximize : .minimize
    let c0 = g.chance(0.5) ? Double(g.integer(in: -20...20)) / 4 : 0
    let modelC = sense == .maximize ? c.map { -$0 } : c   // same min-form problem either way
    let integer: [Int32] = (0..<n).filter { _ in g.chance(0.2) }.map { Int32($0) }
    return buildLP(rows, rl: rl, ru: ru, c: modelC, xl: xl, xu: xu, c0: c0, sense: sense, integer: integer)
}

/// The basis's own duals (min form) and whether it is dual feasible (an optimal basis).
func basisDualFeasibility(_ lp: CompiledLP, _ basis: Basis) -> (y: [Double]?, violations: [String]) {
    let n = lp.n, m = lp.m
    let basic = (0..<(n + m)).filter { basis.status[$0] == .basic }
    guard basic.count == m else { return (nil, ["not m basics"]) }
    if m == 0 { return ([], []) }
    let A = dense(lp)
    // B^T y = c_B ; column k of [A -I]
    var BT = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
    var rhs = [Double](repeating: 0, count: m)
    for (r, k) in basic.enumerated() {
        for i in 0..<m { BT[r][i] = k < n ? A[i][k] : (i == k - n ? -1 : 0) }
        rhs[r] = k < n ? lp.c[k] : 0
    }
    guard let y = solveDense(BT, rhs) else { return (nil, ["singular"]) }
    var v: [String] = []
    let tol = 1e-7 * (1 + (lp.c.map { abs($0) }.max() ?? 0))
    for k in 0..<(n + m) where basis.status[k] != .basic {
        var d: Double
        if k < n { d = lp.c[k]; for i in 0..<m { d -= A[i][k] * y[i] } } else { d = y[k - n] }
        switch basis.status[k] {
        case .atLower: if d < -tol { v.append("k=\(k) atLower d=\(d)") }
        case .atUpper: if d > tol { v.append("k=\(k) atUpper d=\(d)") }
        case .free: if abs(d) > tol { v.append("k=\(k) free d=\(d)") }
        default: break
        }
    }
    return (y, v)
}
