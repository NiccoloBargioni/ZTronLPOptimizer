// V037: the vertex of a returned basis, computed independently of the package: the basic
// system [A −I]_B z_B = −[A −I]_N z_N is equilibrated (rows, then columns, by their largest
// entry), solved by Gaussian elimination with partial pivoting, and refined three times with
// residuals accumulated in double-double (fma). This tells apart "the basis is wrong" from
// "the basis is right but its vertex was computed wrongly".
import Foundation
import ZTronLPOptimizer

struct DD { var hi = 0.0, lo = 0.0
    mutating func add(_ a: Double) { let s = hi + a; let bb = s - hi; let err = (hi - (s - bb)) + (a - bb); hi = s; lo += err }
    mutating func addProduct(_ a: Double, _ b: Double) { let p = a * b; add(p); lo += fma(a, b, -p) }
    var value: Double { hi + lo }
}

struct VertexReport {
    var x: [Double] = []           // structural values
    var r: [Double] = []           // logical values (row activities as the basis defines them)
    var basicViolation = 0.0       // largest bound violation of a basic variable (absolute)
    var basicViolationAt = -1
    var consistency = 0.0          // max |A x − r| over rows
    var refinedResidual = 0.0      // max scaled residual after refinement
    var kappaScaled = 0.0          // ‖B‖₁‖B⁻¹‖₁ of the equilibrated basis matrix
    var objective = 0.0
}

func vertex(of basis: Basis, in lp: CompiledLP) -> VertexReport? {
    let m = lp.m, n = lp.n
    guard basis.status.count == n + m, basis.basic.count == m else { return nil }
    func bounds(_ j: Int) -> (Double, Double) { j < n ? (lp.xl[j], lp.xu[j]) : (lp.rl[j - n], lp.ru[j - n]) }
    var value = [Double](repeating: 0, count: n + m)
    for j in 0..<(n + m) where basis.status[j] != .basic {
        let (lo, hi) = bounds(j)
        switch basis.status[j] {
        case .atLower, .fixed: value[j] = lo
        case .atUpper: value[j] = hi
        default: value[j] = 0
        }
    }
    // Dense columns of A.
    var acol = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
    for j in 0..<n { for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { acol[j][Int(lp.a.rowIndex[p])] = lp.a.values[p] } }
    var B = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)   // B[i][k]
    for (k, jj) in basis.basic.enumerated() {
        let j = Int(jj)
        if j < n { for i in 0..<m { B[i][k] = acol[j][i] } } else { B[j - n][k] = -1 }
    }
    // rhs = −Σ_N col_j·value_j, accumulated in double-double.
    var rhsDD = [DD](repeating: DD(), count: m)
    for j in 0..<(n + m) where basis.status[j] != .basic {
        if j < n { for i in 0..<m where acol[j][i] != 0 { rhsDD[i].addProduct(-acol[j][i], value[j]) } }
        else { rhsDD[j - n].add(value[j]) }
    }
    // Equilibrate.
    var rs = [Double](repeating: 1, count: m), cs = [Double](repeating: 1, count: m)
    for i in 0..<m { let mx = B[i].map { abs($0) }.max() ?? 0; rs[i] = mx > 0 ? 1 / mx : 1 }
    for k in 0..<m { var mx = 0.0; for i in 0..<m { mx = max(mx, abs(B[i][k] * rs[i])) }; cs[k] = mx > 0 ? 1 / mx : 1 }
    var S = B
    for i in 0..<m { for k in 0..<m { S[i][k] = B[i][k] * rs[i] * cs[k] } }
    // LU with partial pivoting of S.
    var lu = S
    var perm = Array(0..<m)
    for c in 0..<m {
        var p = c
        for i in c..<m where abs(lu[i][c]) > abs(lu[p][c]) { p = i }
        if lu[p][c] == 0 { return nil }
        lu.swapAt(c, p); perm.swapAt(c, p)
        for i in (c + 1)..<max(c + 1, m) {
            let f = lu[i][c] / lu[c][c]
            lu[i][c] = f
            for k in (c + 1)..<m { lu[i][k] -= f * lu[c][k] }
        }
    }
    func solve(_ b: [Double]) -> [Double] {
        var y = perm.map { b[$0] }
        for i in 0..<m { for k in 0..<i { y[i] -= lu[i][k] * y[k] } }
        for i in stride(from: m - 1, through: 0, by: -1) {
            for k in (i + 1)..<max(i + 1, m) { y[i] -= lu[i][k] * y[k] }
            y[i] /= lu[i][i]
        }
        return y
    }
    let bScaled = (0..<m).map { rhsDD[$0].value * rs[$0] }
    var u = solve(bScaled)   // scaled unknowns: z_B = cs ∘ u
    var resid = 0.0
    for _ in 0..<3 {
        var res = [Double](repeating: 0, count: m)
        for i in 0..<m {
            var acc = DD()
            acc.add(rhsDD[i].hi * rs[i]); acc.add(rhsDD[i].lo * rs[i])
            for k in 0..<m where S[i][k] != 0 { acc.addProduct(-S[i][k], u[k]) }
            res[i] = acc.value
        }
        resid = res.map { abs($0) }.max() ?? 0
        let du = solve(res)
        for k in 0..<m { u[k] += du[k] }
    }
    // κ₁ of S by explicit inverse (m is small).
    var invNorm = 0.0
    for c in 0..<m { var e = [Double](repeating: 0, count: m); e[c] = 1; let col = solve(e); invNorm = max(invNorm, col.map { abs($0) }.reduce(0, +)) }
    var sNorm = 0.0
    for k in 0..<m { var s = 0.0; for i in 0..<m { s += abs(S[i][k]) }; sNorm = max(sNorm, s) }
    // Duals of the basis: Bᵀy = c_B (logical costs 0), via Sᵀw = C·c_B, y = R·w.
    var g = [Double](repeating: 0, count: m)
    for (k, jj) in basis.basic.enumerated() { let j = Int(jj); g[k] = (j < n ? lp.c[j] : 0) * cs[k] }
    var t = g
    for i in 0..<m { for k in 0..<i { t[i] -= lu[k][i] * t[k] }; t[i] /= lu[i][i] }          // Uᵀt = g
    for i in stride(from: m - 1, through: 0, by: -1) { for k in (i + 1)..<max(i + 1, m) { t[i] -= lu[k][i] * t[k] } }  // Lᵀv = t
    var w = [Double](repeating: 0, count: m)
    for i in 0..<m { w[perm[i]] = t[i] }
    let yB = (0..<m).map { w[$0] * rs[$0] }
    var dualViol = 0.0, dualAt = -1
    for j in 0..<(n + m) where basis.status[j] != .basic {
        var dj = 0.0
        if j < n { var acc = DD(); acc.add(lp.c[j]); for i in 0..<m where acol[j][i] != 0 { acc.addProduct(-acol[j][i], yB[i]) }; dj = acc.value }
        else { dj = yB[j - n] }
        let v: Double
        switch basis.status[j] { case .atLower: v = -dj; case .atUpper: v = dj; case .free: v = abs(dj); default: v = 0 }
        if v > dualViol { dualViol = v; dualAt = j }
    }
    print("  duals of this basis (independent): largest reduced-cost sign violation \(e(dualViol)) = \(dualViol) at \(dualAt < 0 ? "-" : (dualAt < n ? "column \(dualAt)" : "row \(dualAt - n)"))")
    var rep = VertexReport()
    rep.refinedResidual = resid
    rep.kappaScaled = sNorm * invNorm
    for (k, jj) in basis.basic.enumerated() { value[Int(jj)] = u[k] * cs[k] }
    rep.x = Array(value[0..<n]); rep.r = Array(value[n..<(n + m)])
    for jj in basis.basic {
        let j = Int(jj)
        let (lo, hi) = bounds(j)
        let v = max(lo.isFinite ? lo - value[j] : 0, hi.isFinite ? value[j] - hi : 0, 0)
        if v > rep.basicViolation { rep.basicViolation = v; rep.basicViolationAt = j }
    }
    let (act, _) = activities(lp, rep.x)
    for i in 0..<m { rep.consistency = max(rep.consistency, abs(act[i] - rep.r[i])) }
    rep.objective = modelObjective(lp, rep.x)
    return rep
}

func runVertex(_ inst: GenInstance, _ cert: Certificate, names: Set<String>) async {
    for cfg in grid() where names.contains(cfg.name) {
        do {
            let an = try await cfg.s.solve(inst.lp, context: context())
            print("VERTEX \(cfg.name): status \(an.status), returned objective \(an.objectiveValue.map { "\($0)" } ?? "nil")")
            guard let rep = vertex(of: an.basis, in: inst.lp) else { print("  basis did not fit or is singular"); continue }
            let basicLogicals = an.basis.basic.filter { Int($0) >= inst.lp.n }.count
            print("  basis: \(an.basis.basic.count) basic (\(basicLogicals) logical); equilibrated κ₁ \(e(rep.kappaScaled)); refined residual \(e(rep.refinedResidual)); |Ax − r| \(e(rep.consistency))")
            let label = rep.basicViolationAt < 0 ? "-" : (rep.basicViolationAt < inst.lp.n ? "column \(rep.basicViolationAt)" : "row \(rep.basicViolationAt - inst.lp.n)")
            print("  vertex of this basis (independent): basic bound violation \(e(rep.basicViolation)) at \(label); objective \(rep.objective) (certified optimum \(cert.primalObjective))")
            let v = violation(inst.lp, rep.x)
            print("  vertex structural x against the rows: abs \(e(v.rowAbs)) rel \(e(v.rowRel)); bounds abs \(e(v.boundAbs))")
            if let x = an.primal {
                var dx = 0.0
                for j in 0..<inst.lp.n { dx = max(dx, abs(x[j] - rep.x[j]) / (1 + abs(rep.x[j]))) }
                print("  returned x vs this vertex: max rel distance \(e(dx))")
            }
        } catch { print("VERTEX \(cfg.name): threw \(error)") }
    }
}
