// Independent oracles for cycle B / F3: dense linear algebra (own GEPP, inverse, Jacobi SVD),
// a KKT checker on the ORIGINAL model, and an independent basis-optimality checker.
// Nothing here calls package numerics.
import Foundation
import ZTronLPOptimizer

// MARK: - Dense linear algebra (row-major [[Double]])

/// Solves A x = b by Gaussian elimination with partial pivoting. Returns nil if singular.
func gepp(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
    let n = a0.count
    var a = a0
    var b = b0
    for k in 0..<n {
        var p = k
        var best = abs(a[k][k])
        for i in (k + 1)..<max(k + 1, n) where abs(a[i][k]) > best { best = abs(a[i][k]); p = i }
        if best == 0 { return nil }
        if p != k { a.swapAt(p, k); b.swapAt(p, k) }
        let piv = a[k][k]
        for i in (k + 1)..<max(k + 1, n) {
            let f = a[i][k] / piv
            if f == 0 { continue }
            for j in k..<n { a[i][j] -= f * a[k][j] }
            b[i] -= f * b[k]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var s = b[i]
        for j in (i + 1)..<max(i + 1, n) { s -= a[i][j] * x[j] }
        x[i] = s / a[i][i]
    }
    return x
}

func transpose(_ a: [[Double]]) -> [[Double]] {
    let m = a.count
    let n = m == 0 ? 0 : a[0].count
    var t = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
    for i in 0..<m { for j in 0..<n { t[j][i] = a[i][j] } }
    return t
}

/// Explicit inverse via GEPP on each unit vector.
func inverse(_ a: [[Double]]) -> [[Double]]? {
    let n = a.count
    var cols: [[Double]] = []
    for j in 0..<n {
        var e = [Double](repeating: 0, count: n)
        e[j] = 1
        guard let x = gepp(a, e) else { return nil }
        cols.append(x)
    }
    return transpose(cols)
}

func oneNorm(_ a: [[Double]]) -> Double {
    let n = a.count
    guard n > 0 else { return 0 }
    var best = 0.0
    for j in 0..<a[0].count {
        var s = 0.0
        for i in 0..<n { s += abs(a[i][j]) }
        best = max(best, s)
    }
    return best
}

/// Singular values by one-sided Jacobi (Hestenes), accurate to high relative precision.
func singularValues(_ a0: [[Double]]) -> [Double] {
    // Work on columns of A (m x n), orthogonalize column pairs.
    let m = a0.count
    let n = m == 0 ? 0 : a0[0].count
    var u = transpose(a0)  // u[j] = column j
    for _ in 0..<100 {
        var off = 0.0
        for p in 0..<n {
            for q in (p + 1)..<max(p + 1, n) {
                var alpha = 0.0, beta = 0.0, gamma = 0.0
                for i in 0..<m {
                    alpha += u[p][i] * u[p][i]
                    beta += u[q][i] * u[q][i]
                    gamma += u[p][i] * u[q][i]
                }
                if gamma == 0 { continue }
                let c0 = abs(gamma) / (alpha * beta).squareRoot()
                off = max(off, c0)
                if c0 < 1e-15 { continue }
                let zeta = (beta - alpha) / (2 * gamma)
                let t = (zeta >= 0 ? 1.0 : -1.0) / (abs(zeta) + (1 + zeta * zeta).squareRoot())
                let c = 1 / (1 + t * t).squareRoot()
                let s = c * t
                for i in 0..<m {
                    let up = u[p][i], uq = u[q][i]
                    u[p][i] = c * up - s * uq
                    u[q][i] = s * up + c * uq
                }
            }
        }
        if off < 1e-15 { break }
    }
    var sv = u.map { col in (col.reduce(0) { $0 + $1 * $1 }).squareRoot() }
    sv.sort(by: >)
    return sv
}

// MARK: - Model helpers

func denseA(_ lp: CompiledLP) -> [[Double]] {
    var a = [[Double]](repeating: [Double](repeating: 0, count: lp.n), count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            a[Int(lp.a.rowIndex[p])][j] += lp.a.values[p]
        }
    }
    return a
}

func activity(_ lp: CompiledLP, _ x: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            r[Int(lp.a.rowIndex[p])] += lp.a.values[p] * x[j]
        }
    }
    return r
}

func aTy(_ lp: CompiledLP, _ y: [Double]) -> [Double] {
    var g = [Double](repeating: 0, count: lp.n)
    for j in 0..<lp.n {
        var s = 0.0
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { s += lp.a.values[p] * y[Int(lp.a.rowIndex[p])] }
        g[j] = s
    }
    return g
}

func fmt(_ v: Double) -> String { String(format: "%.3e", v) }

// MARK: - KKT checker on the original model

struct KKT: CustomStringConvertible {
    var primalViol = 0.0      // max relative bound/row violation
    var dualSign = 0.0        // wrong-sign reduced cost on a side with an infinite bound (dual infeasibility), relative
    var compl = 0.0           // max |d_j| * distance to the bound its sign asks for, relative to 1+|obj|
    var gap = 0.0             // |primal obj - dual obj| / (1+|obj|) with own duals
    var rcConsistency = 0.0   // reported reduced costs vs c - A^T y
    var objReport = 0.0       // |reported objective - objective(at x)| / (1+|obj|)
    var objKnown = Double.nan // |reported - known| / (1+|known|)
    var hasDual = false
    var description: String {
        "pviol=\(fmt(primalViol)) dsign=\(fmt(dualSign)) compl=\(fmt(compl)) gap=\(fmt(gap)) rc=\(fmt(rcConsistency)) objRep=\(fmt(objReport)) objKnown=\(fmt(objKnown))"
    }
    func ok(_ tol: Double) -> Bool {
        primalViol <= tol && (!hasDual || (dualSign <= tol && gap <= tol && rcConsistency <= tol)) && objReport <= tol
            && (objKnown.isNaN || objKnown <= tol)
    }
}

/// x: n structural values; dual: m reported row duals; rc: n+m reported reduced costs.
func kktCheck(_ lp: CompiledLP, x: [Double], dual: [Double]?, rc: [Double]?, objective: Double?, known: Double?) -> KKT {
    var r = KKT()
    let n = lp.n, m = lp.m
    let flip: Double = lp.sense == .maximize ? -1 : 1
    // primal
    for j in 0..<n {
        if lp.xl[j].isFinite { r.primalViol = max(r.primalViol, (lp.xl[j] - x[j]) / (1 + abs(lp.xl[j]))) }
        if lp.xu[j].isFinite { r.primalViol = max(r.primalViol, (x[j] - lp.xu[j]) / (1 + abs(lp.xu[j]))) }
        if !x[j].isFinite { r.primalViol = .infinity }
    }
    let act = activity(lp, x)
    for i in 0..<m {
        if lp.rl[i].isFinite { r.primalViol = max(r.primalViol, (lp.rl[i] - act[i]) / (1 + abs(lp.rl[i]))) }
        if lp.ru[i].isFinite { r.primalViol = max(r.primalViol, (act[i] - lp.ru[i]) / (1 + abs(lp.ru[i]))) }
    }
    var pobj = lp.c0
    for j in 0..<n { pobj += lp.c[j] * x[j] }
    let reportedFromX = lp.sense == .maximize ? -pobj : pobj
    let scaleObj = 1 + abs(reportedFromX)
    if let objective { r.objReport = abs(objective - reportedFromX) / scaleObj } else { r.objReport = .infinity }
    if let known, let objective { r.objKnown = abs(objective - known) / (1 + abs(known)) }
    guard let dual, dual.count == m else { return r }
    r.hasDual = true
    let y = dual.map { flip * $0 }
    let g = aTy(lp, y)
    var d = [Double](repeating: 0, count: n)
    for j in 0..<n { d[j] = lp.c[j] - g[j] }
    let cScale = 1 + (lp.c.map { abs($0) }.max() ?? 0)
    if let rc, rc.count == n + m {
        for j in 0..<n { r.rcConsistency = max(r.rcConsistency, abs(flip * rc[j] - d[j]) / cScale) }
        for i in 0..<m { r.rcConsistency = max(r.rcConsistency, abs(flip * rc[n + i] - y[i]) / cScale) }
    } else {
        r.rcConsistency = .infinity
    }
    // dual objective with these duals; dual feasibility on infinite bounds
    var dobj = lp.c0
    func side(_ v: Double, _ value: Double, _ lo: Double, _ hi: Double) {
        // reduced cost v of a variable with value and bounds [lo, hi]
        if v > 0 {
            if lo.isFinite {
                dobj += v * lo
                r.compl = max(r.compl, v * abs(value - lo) / scaleObj)
            } else {
                r.dualSign = max(r.dualSign, v / cScale)
            }
        } else if v < 0 {
            if hi.isFinite {
                dobj += v * hi
                r.compl = max(r.compl, -v * abs(hi - value) / scaleObj)
            } else {
                r.dualSign = max(r.dualSign, -v / cScale)
            }
        }
    }
    for j in 0..<n { side(d[j], x[j], lp.xl[j], lp.xu[j]) }
    for i in 0..<m { side(y[i], act[i], lp.rl[i], lp.ru[i]) }
    r.gap = abs(pobj - dobj) / (1 + abs(pobj))
    return r
}

// MARK: - Basis checker

struct BasisCheck: CustomStringConvertible {
    var valid = true
    var note = ""
    var primalInf = 0.0   // relative bound violation of the basic solution
    var dualInf = 0.0     // relative wrong-sign reduced cost of a nonbasic
    var xDiff = 0.0       // max |x(basis) - returned x| / (1+|x|)
    var objDiff = 0.0     // relative
    var description: String {
        valid ? "basis primalInf=\(fmt(primalInf)) dualInf=\(fmt(dualInf)) xDiff=\(fmt(xDiff)) objDiff=\(fmt(objDiff)) \(note)" : "basis INVALID: \(note)"
    }
    func ok(_ tol: Double) -> Bool { valid && primalInf <= tol && dualInf <= tol && xDiff <= tol * 100 && objDiff <= tol }
}

func checkBasis(_ lp: CompiledLP, _ basis: Basis, x returned: [Double]?) -> BasisCheck {
    var r = BasisCheck()
    let n = lp.n, m = lp.m
    guard basis.status.count == n + m, basis.basic.count == m else {
        r.valid = false; r.note = "sizes \(basis.status.count)/\(basis.basic.count) vs n+m=\(n + m), m=\(m)"; return r
    }
    var isBasic = [Bool](repeating: false, count: n + m)
    for k in basis.basic {
        let j = Int(k)
        guard j >= 0, j < n + m, !isBasic[j] else { r.valid = false; r.note = "bad basic index \(j)"; return r }
        isBasic[j] = true
    }
    var mismatched = 0
    for j in 0..<(n + m) where (basis.status[j] == .basic) != isBasic[j] { mismatched += 1 }
    if mismatched > 0 { r.note += "statusMismatch=\(mismatched) " }
    func lo(_ j: Int) -> Double { j < n ? lp.xl[j] : lp.rl[j - n] }
    func hi(_ j: Int) -> Double { j < n ? lp.xu[j] : lp.ru[j - n] }
    // full vector (x; s) with Ax - s = 0
    var v = [Double](repeating: 0, count: n + m)
    var badStatus = 0
    for j in 0..<(n + m) where !isBasic[j] {
        switch basis.status[j] {
        case .atLower: if lo(j).isFinite { v[j] = lo(j) } else { badStatus += 1 }
        case .atUpper: if hi(j).isFinite { v[j] = hi(j) } else { badStatus += 1 }
        case .fixed: if lo(j).isFinite { v[j] = lo(j) } else if hi(j).isFinite { v[j] = hi(j) } else { badStatus += 1 }
            if lo(j) != hi(j) { r.note += "fixedOnNonFixed(\(j)) " }
        case .free: v[j] = 0
            if lo(j).isFinite || hi(j).isFinite { r.note += "freeOnBounded(\(j)) " }
        case .basic: badStatus += 1
        }
    }
    if badStatus > 0 { r.note += "nonbasicAtInfiniteBound=\(badStatus) " }
    // B x_B = -N x_N  (columns of [A -I])
    let A = denseA(lp)
    func column(_ j: Int) -> [Double] {
        if j < n { return (0..<m).map { A[$0][j] } }
        var e = [Double](repeating: 0, count: m); e[j - n] = -1; return e
    }
    var rhs = [Double](repeating: 0, count: m)
    for j in 0..<(n + m) where !isBasic[j] && v[j] != 0 {
        let col = column(j)
        for i in 0..<m { rhs[i] -= col[i] * v[j] }
    }
    var B = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
    for (k, jj) in basis.basic.enumerated() {
        let col = column(Int(jj))
        for i in 0..<m { B[i][k] = col[i] }
    }
    guard m == 0 || gepp(B, rhs) != nil else { r.valid = false; r.note += "singular basis"; return r }
    if m > 0 {
        let xb = gepp(B, rhs)!
        for (k, jj) in basis.basic.enumerated() { v[Int(jj)] = xb[k] }
    }
    for j in 0..<(n + m) {
        if lo(j).isFinite { r.primalInf = max(r.primalInf, (lo(j) - v[j]) / (1 + abs(lo(j)))) }
        if hi(j).isFinite { r.primalInf = max(r.primalInf, (v[j] - hi(j)) / (1 + abs(hi(j)))) }
    }
    // duals: B^T y = c_B
    let cost: (Int) -> Double = { $0 < n ? lp.c[$0] : 0 }
    let cb = basis.basic.map { cost(Int($0)) }
    let y = m > 0 ? (gepp(transpose(B), cb) ?? []) : []
    let cScale = 1 + (lp.c.map { abs($0) }.max() ?? 0)
    for j in 0..<(n + m) where !isBasic[j] {
        let col = column(j)
        var dj = cost(j)
        for i in 0..<m { dj -= col[i] * y[i] }
        switch basis.status[j] {
        case .atLower: r.dualInf = max(r.dualInf, -dj / cScale)
        case .atUpper: r.dualInf = max(r.dualInf, dj / cScale)
        case .free: r.dualInf = max(r.dualInf, abs(dj) / cScale)
        default: break
        }
    }
    var obj = lp.c0
    for j in 0..<n { obj += lp.c[j] * v[j] }
    if let returned, returned.count == n {
        var robj = lp.c0
        for j in 0..<n {
            r.xDiff = max(r.xDiff, abs(v[j] - returned[j]) / (1 + abs(v[j])))
            robj += lp.c[j] * returned[j]
        }
        r.objDiff = abs(obj - robj) / (1 + abs(obj))
    }
    return r
}
