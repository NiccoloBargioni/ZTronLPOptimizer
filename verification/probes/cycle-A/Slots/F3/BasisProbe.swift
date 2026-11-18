import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Regenerates instance k of probeKKT's sequence.
func kktInstance(k target: Int, seed: UInt64, maxRows: Int, maxCols: Int, spread: Double = 0) -> ConstructedInstance {
    var rng = Rng(seed)
    for k in 0...target {
        let m = rng.int(5, maxRows)
        let n = rng.int(max(5, m / 2), maxCols)
        var options = ConstructedOptions()
        options.density = max(0.02, min(0.5, 6.0 / Double(m)))
        switch k % 6 {
        case 1: options.degenerate = true
        case 2: options.freeColumns = true
        case 3: options.rangeRows = true
        case 4: options.maximize = true
        case 5: options.degenerate = true; options.freeColumns = true; options.rangeRows = true; options.maximize = true
        default: break
        }
        options.scaleSpread = spread
        let s = rng.next()
        if k == target { return InstanceGenerator.constructedOptimum(rows: m, columns: n, seed: s, options: options) }
    }
    fatalError()
}

/// The vertex of a basis and its duals, computed from scratch: nonbasic columns where their
/// status puts them, basic ones from B x_B = -N x_N (logical form Ax - s = 0).
func basisVertex(_ lp: CompiledLP, _ basis: Basis) -> (x: [Double], s: [Double], y: [Double], d: [Double])? {
    let m = lp.m, n = lp.n
    func resting(_ st: BasisStatus, _ lo: Double, _ up: Double) -> Double {
        switch st {
        case .atLower, .fixed: return lo.isFinite ? lo : (up.isFinite ? up : 0)
        case .atUpper: return up.isFinite ? up : (lo.isFinite ? lo : 0)
        default: return 0
        }
    }
    var full = [Double](repeating: 0, count: n + m)
    for j in 0..<(n + m) where basis.status[j] != .basic {
        full[j] = j < n ? resting(basis.status[j], lp.xl[j], lp.xu[j]) : resting(basis.status[j], lp.rl[j - n], lp.ru[j - n])
    }
    var rhs = [Double](repeating: 0, count: m)
    for j in 0..<n where basis.status[j] != .basic && full[j] != 0 {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { rhs[Int(lp.a.rowIndex[p])] -= lp.a.values[p] * full[j] }
    }
    for i in 0..<m where basis.status[n + i] != .basic { rhs[i] += full[n + i] }
    let b = basisMatrix(lp, basis)
    guard let xb = solveDense(b, m, rhs, transpose: false) else { return nil }
    for (k, col) in basis.basic.enumerated() { full[Int(col)] = xb[k] }
    // Duals: B' y = c_B (logical cost 0, logical column -e_i).
    var cb = [Double](repeating: 0, count: m)
    for (k, col) in basis.basic.enumerated() { cb[k] = Int(col) < n ? lp.c[Int(col)] : 0 }
    guard let y = solveDense(b, m, cb, transpose: true) else { return nil }
    var d = lp.c
    for j in 0..<n { for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { d[j] -= lp.a.values[p] * y[Int(lp.a.rowIndex[p])] } }
    return (Array(full[0..<n]), Array(full[n...]), y, d)
}

/// Gaussian elimination with partial pivoting on a column-major matrix.
func solveDense(_ colMajor: [Double], _ m: Int, _ rhs: [Double], transpose: Bool) -> [Double]? {
    var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
    for i in 0..<m {
        for j in 0..<m { a[i][j] = transpose ? colMajor[i * m + j] : colMajor[j * m + i] }
        a[i][m] = rhs[i]
    }
    for k in 0..<m {
        var p = k
        for i in k..<m where abs(a[i][k]) > abs(a[p][k]) { p = i }
        if a[p][k] == 0 { return nil }
        a.swapAt(p, k)
        for i in (k + 1)..<max(k + 1, m) {
            let f = a[i][k] / a[k][k]
            if f == 0 { continue }
            for j in k...m { a[i][j] -= f * a[k][j] }
        }
    }
    var x = [Double](repeating: 0, count: m)
    for i in stride(from: m - 1, through: 0, by: -1) {
        var s = a[i][m]
        for j in (i + 1)..<max(i + 1, m) { s -= a[i][j] * x[j] }
        x[i] = s / a[i][i]
    }
    return x
}

/// Checks whether a basis is primal and dual feasible for its statuses (minimization form).
func basisCheck(_ lp: CompiledLP, _ basis: Basis, primal: [Double]?) -> String {
    guard let v = basisVertex(lp, basis) else { return "singular basis" }
    let n = lp.n, m = lp.m
    var pviol = 0.0
    for j in 0..<n { pviol = max(pviol, lp.xl[j] - v.x[j], v.x[j] - lp.xu[j]) }
    for i in 0..<m { pviol = max(pviol, lp.rl[i] - v.s[i], v.s[i] - lp.ru[i]) }
    var dviol = 0.0
    var details: [String] = []
    for j in 0..<(n + m) where basis.status[j] != .basic {
        let dj = j < n ? v.d[j] : v.y[j - n]
        let viol: Double
        switch basis.status[j] {
        case .atLower: viol = max(0, -dj)
        case .atUpper: viol = max(0, dj)
        case .free: viol = abs(dj)
        default: viol = 0
        }
        if viol > 1e-7 && details.count < 4 {
            let lo = j < n ? lp.xl[j] : lp.rl[j - n], up = j < n ? lp.xu[j] : lp.ru[j - n]
            details.append("\(j < n ? "col \(j)" : "row \(j - n)") \(basis.status[j]) d=\(e(dj)) bounds [\(lo), \(up)]")
        }
        dviol = max(dviol, viol)
    }
    var dist = Double.nan
    if let primal { dist = zip(primal, v.x).map { abs($0 - $1) }.max() ?? 0 }
    var nonbasicFreeAtNonzero = 0
    if let primal {
        for j in 0..<n where basis.status[j] == .free && abs(primal[j]) > 1e-9 { nonbasicFreeAtNonzero += 1 }
    }
    return "basis vertex pviol \(e(pviol)) dviol \(e(dviol)) |x_returned - x_basis| \(e(dist)) free-nonbasic-at-nonzero \(nonbasicFreeAtNonzero) \(details)"
}

/// args: k seed maxRows maxCols
func probeBasis(_ args: [String]) async throws {
    let ks = args.count > 0 ? args[0].split(separator: ",").map { Int($0)! } : [2, 5, 20, 56]
    let seed = args.count > 1 ? UInt64(args[1])! : 7
    let maxRows = args.count > 2 ? Int(args[2])! : 60
    let maxCols = args.count > 3 ? Int(args[3])! : 120
    for k in ks {
        let inst = kktInstance(k: k, seed: seed, maxRows: maxRows, maxCols: maxCols)
        let lp = inst.lp
        let free = (0..<lp.n).filter { lp.xl[$0] == -.infinity && lp.xu[$0] == .infinity }.count
        print("instance k=\(k) \(lp.m)x\(lp.n), free columns \(free)")
        for (name, strategy) in [("IPM lite presolve", InteriorPoint()), ("IPM lite nopresolve", InteriorPoint(presolve: false))] {
            let a = try await strategy.solve(lp, context: ctx())
            guard let basis = a.finalBasis else { print("  \(name): no basis"); continue }
            print("  \(name): \(statusName(a.status)) crossover it \(a.crossover?.iterations ?? -1); \(basisCheck(lp, basis, primal: a.primal))")
        }
        for (name, strategy) in [("Simplex(.dual) presolve", Simplex(.dual)), ("Simplex(.primal) presolve", Simplex(.primal))] {
            let a = try await strategy.solve(lp, context: ctx())
            var c = ctx()
            c.warmStart = .basis(a.basis)
            let w = try await Simplex(.primal, presolve: false).solve(lp, context: c)
            print("  \(name): \(statusName(a.status)) warm primal it \(w.iterations); \(basisCheck(lp, a.basis, primal: a.primal))")
        }
    }
}

/// Details of the rows a presolved basis gets wrong. args: k row
func probeBasisRow(_ args: [String]) async throws {
    let k = Int(args[0])!, row = Int(args[1])!
    let inst = kktInstance(k: k, seed: 7, maxRows: 60, maxCols: 120)
    let lp = inst.lp
    let pre = Presolve.run(lp)
    print("presolve: outcome \(pre.outcome) removed rows \(pre.removedRows) cols \(pre.removedColumns); row \(row) kept: \(pre.rowOrigin.contains(Int32(row)))")
    let aT = lp.aT
    var cols: [Int] = []
    for p in aT.colStart[row]..<aT.colStart[row + 1] {
        let j = Int(aT.rowIndex[p]); cols.append(j)
        print("  row \(row): a[\(j)] = \(aT.values[p]); column bounds [\(lp.xl[j]), \(lp.xu[j])] kept: \(pre.columnOrigin.contains(Int32(j))) x* = \(inst.primal[j])")
    }
    print("  row bounds [\(lp.rl[row]), \(lp.ru[row])], y* = \(inst.dual[row])")
    let a = try await InteriorPoint().solve(lp, context: ctx())
    let b = a.finalBasis!
    for j in cols {
        print("  basis status col \(j): \(b.status[j]); returned x \(a.primal![j]); reported d \(a.reducedCosts![j])")
        // Every other row touching column j.
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            let i = Int(lp.a.rowIndex[p])
            let cnt = aT.colStart[i + 1] - aT.colStart[i]
            print("     col \(j) in row \(i) (\(cnt) entries, kept \(pre.rowOrigin.contains(Int32(i)))), status \(b.status[lp.n + i]), bounds [\(lp.rl[i]), \(lp.ru[i])], reported dual \(a.dual![i])")
        }
    }
    print("  row \(row) logical status \(b.status[lp.n + row]), reported dual \(a.dual![row])")
}
