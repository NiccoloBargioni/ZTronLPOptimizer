// Numerical building blocks against naive references (own Gaussian elimination, own products).
import Foundation
import ZTronLPOptimizer

/// Naive Gaussian elimination with partial pivoting on a dense row-major copy; nil if singular.
func naiveSolve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var m = a
    var x = b
    for k in 0..<n {
        var p = k
        for i in k..<n where abs(m[i][k]) > abs(m[p][k]) { p = i }
        if m[p][k] == 0 { return nil }
        m.swapAt(k, p); x.swapAt(k, p)
        for i in (k + 1)..<max(k + 1, n) {
            let f = m[i][k] / m[k][k]
            if f == 0 { continue }
            for j in k..<n { m[i][j] -= f * m[k][j] }
            x[i] -= f * x[k]
        }
    }
    for k in stride(from: n - 1, through: 0, by: -1) {
        var s = x[k]
        for j in (k + 1)..<max(k + 1, n) { s -= m[k][j] * x[j] }
        x[k] = s / m[k][k]
    }
    return x
}

func relErr(_ a: [Double], _ b: [Double]) -> Double {
    var e = 0.0, s = 0.0
    for i in 0..<a.count { e = max(e, abs(a[i] - b[i])); s = max(s, abs(b[i])) }
    return e / max(1, s)
}

/// Dense B = columns `basic` of [A −I] (row-major).
func basisMatrix(_ lp: LP, _ basic: [Int32]) -> [[Double]] {
    var B = [[Double]](repeating: [Double](repeating: 0, count: lp.m), count: lp.m)
    for (k, col) in basic.enumerated() {
        let j = Int(col)
        if j < lp.n { for i in 0..<lp.m { B[i][k] = lp.A[i][j] } } else { B[j - lp.n][k] = -1 }
    }
    return B
}
func transpose(_ a: [[Double]]) -> [[Double]] {
    guard let c = a.first?.count else { return [] }
    return (0..<c).map { j in a.map { $0[j] } }
}

func runNumerics(seed: UInt64, trials: Int) -> [String] {
    var out: [String] = []
    var g = RNG(seed)
    var worst: [String: Double] = [:]
    func rec(_ k: String, _ v: Double) { worst[k] = max(worst[k] ?? 0, v.isNaN ? .infinity : v) }

    for _ in 0..<trials {
        // --- dense products and LU
        let n = g.int(1, 30)
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in 0..<n where g.chance(0.7) { rows[i][j] = g.u(-5, 5) } }
        for i in 0..<n { rows[i][i] += 10 }   // keep it comfortably nonsingular
        var storage = [Double](repeating: 0, count: n * n)
        for i in 0..<n { for j in 0..<n { storage[j * n + i] = rows[i][j] } }
        let M = DenseMatrix(rows: n, cols: n, storage: storage)
        let x = (0..<n).map { _ in g.u(-3, 3) }
        let Mx = M.multiply(x)
        var naiveMx = [Double](repeating: 0, count: n)
        for i in 0..<n { for j in 0..<n { naiveMx[i] += rows[i][j] * x[j] } }
        rec("DenseMatrix.multiply", relErr(Mx, naiveMx))
        let MTx = M.multiplyTranspose(x)
        var naiveMTx = [Double](repeating: 0, count: n)
        for i in 0..<n { for j in 0..<n { naiveMTx[j] += rows[i][j] * x[i] } }
        rec("DenseMatrix.multiplyTranspose", relErr(MTx, naiveMTx))
        var on = 0.0
        for j in 0..<n { on = max(on, (0..<n).map { abs(rows[$0][j]) }.reduce(0, +)) }
        rec("DenseMatrix.oneNorm", abs(M.oneNorm() - on) / max(1, on))
        do {
            let lu = try DenseLU(M)
            var b = naiveMx
            lu.solve(&b)
            rec("DenseLU.solve", relErr(b, x))
            var bt = naiveMTx
            lu.solve(&bt, transpose: true)
            rec("DenseLU.solve(transpose)", relErr(bt, x))
            // sparse right-hand sides (leading zeros exercise the trailing-block path)
            for _ in 0..<3 {
                var e = [Double](repeating: 0, count: n)
                let k = g.int(0, n - 1)
                for i in k..<n where g.chance(0.5) { e[i] = g.u(-1, 1) }
                var s1 = e, s2 = e
                lu.solve(&s1)
                lu.solve(&s2, transpose: true)
                if let r1 = naiveSolve(rows, e) { rec("DenseLU.solve(sparse rhs)", relErr(s1, r1)) }
                if let r2 = naiveSolve(transpose(rows), e) { rec("DenseLU.solve(sparse rhs, transpose)", relErr(s2, r2)) }
            }
            if let ds = denseSolve(M, naiveMx) { rec("denseSolve", relErr(ds, x)) } else { rec("denseSolve", .infinity) }
        } catch { out.append("DenseLU threw on a nonsingular matrix: \(error)") }

        // --- triangular solves
        for upper in [true, false] {
            for tr in [true, false] {
                for unit in [true, false] {
                    var T = rows
                    for i in 0..<n { for j in 0..<n where (upper ? j < i : j > i) { T[i][j] = 0 } }
                    var st = [Double](repeating: 0, count: n * n)
                    for i in 0..<n { for j in 0..<n { st[j * n + i] = T[i][j] } }
                    let op = tr ? transpose(T) : T
                    var opUnit = op
                    if unit { for i in 0..<n { opUnit[i][i] = 1 } }
                    var b = [Double](repeating: 0, count: n)
                    for i in 0..<n { for j in 0..<n { b[i] += opUnit[i][j] * x[j] } }
                    let rhs0 = b
                    triangularSolve(DenseMatrix(rows: n, cols: n, storage: st), &b, upper: upper, transpose: tr, unitDiagonal: unit)
                    // backward error: residual of the computed solution (a forward error can be large
                    // on these random, possibly very ill-conditioned triangular matrices)
                    var res = [Double](repeating: 0, count: n)
                    var scale = 0.0
                    for i in 0..<n { var s = 0.0, t = 0.0; for j in 0..<n { s += opUnit[i][j] * b[j]; t += abs(opUnit[i][j] * b[j]) }; res[i] = s - rhs0[i]; scale = max(scale, t) }
                    rec("triangularSolve (backward error)", (res.map { abs($0) }.max() ?? 0) / max(1e-300, scale))
                }
            }
        }

        // --- singular matrix: denseSolve nil, DenseLU throws .singular
        if n >= 2 {
            var srows = rows
            let a = g.int(0, n - 1), bcol = (a + 1) % n
            for i in 0..<n { srows[i][bcol] = 2 * srows[i][a] }   // dependent column
            var ss = [Double](repeating: 0, count: n * n)
            for i in 0..<n { for j in 0..<n { ss[j * n + i] = srows[i][j] } }
            let S = DenseMatrix(rows: n, cols: n, storage: ss)
            do {
                let lu = try DenseLU(S)
                let d = lu.deficientPivots(relativeTolerance: 1e-11)
                if d.positions.isEmpty { rec("singular: not flagged by deficientPivots(1e-11)", 1) }
            } catch { /* exact singularity reported: fine */ }
        }

        // --- SparseCSC ops
        let m2 = g.int(1, 20), n2 = g.int(1, 20)
        var ent: [(row: Int, col: Int, value: Double)] = []
        var dense = [[Double]](repeating: [Double](repeating: 0, count: n2), count: m2)
        for i in 0..<m2 { for j in 0..<n2 where g.chance(0.3) { let v = g.u(-4, 4); ent.append((i, j, v)); dense[i][j] += v } }
        // duplicates are summed
        if !ent.isEmpty { let e0 = ent[0]; ent.append((e0.row, e0.col, 1.5)); dense[e0.row][e0.col] += 1.5 }
        let A = SparseCSC.fromTriplets(rows: m2, cols: n2, ent)
        let v = (0..<n2).map { _ in g.u(-2, 2) }
        let w = (0..<m2).map { _ in g.u(-2, 2) }
        var Av = [Double](repeating: 0, count: m2), ATw = [Double](repeating: 0, count: n2)
        for i in 0..<m2 { for j in 0..<n2 { Av[i] += dense[i][j] * v[j]; ATw[j] += dense[i][j] * w[i] } }
        rec("SparseCSC.multiply", relErr(A.multiply(v), Av))
        rec("SparseCSC.multiplyTranspose", relErr(A.multiplyTranspose(w), ATw))
        rec("SparseCSC.transposed.multiply", relErr(A.transposed().multiply(w), ATw))
        var sub = 0.0
        for i in 0..<m2 { for j in 0..<n2 { sub = max(sub, abs(A[i, j] - dense[i][j])) } }
        rec("SparseCSC.subscript", sub)
        rec("DenseMatrix(SparseCSC)", {
            let D = DenseMatrix(A)
            var e = 0.0
            for i in 0..<m2 { for j in 0..<n2 { e = max(e, abs(D[i, j] - dense[i][j])) } }
            return e
        }())

        // --- Vec kernels
        let len = g.int(0, 40)
        let p = (0..<len).map { _ in g.u(-3, 3) }, q = (0..<len).map { _ in g.u(-3, 3) }
        rec("Vec.dot", abs(Vec.dot(p, q) - zip(p, q).map(*).reduce(0, +)))
        var yv = q
        Vec.axpy(0.7, p, into: &yv)
        rec("Vec.axpy", relErr(yv, zip(p, q).map { 0.7 * $0 + $1 }))
        rec("Vec.maxAbs", abs(Vec.maxAbs(p) - (p.map { abs($0) }.max() ?? 0)))
        rec("Vec.norm2", abs(Vec.norm2(p) - sqrt(p.map { $0 * $0 }.reduce(0, +))))
        rec("Vec.sum", abs(Vec.sum(p) - p.reduce(0, +)))
        if len > 0 { rec("Vec.minimum", abs(Vec.minimum(p) - p.min()!)) }
    }

    // --- basis factorizations with product-form updates
    for trial in 0..<trials {
        let m = g.int(1, 25), n = g.int(1, 30)
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
        for i in 0..<m { for j in 0..<n where g.chance(0.4) { A[i][j] = Double(g.int(-5, 5)) } }
        let lp = LP(m: m, n: n, A: A, c: [Double](repeating: 0, count: n), maximize: false,
                    xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n),
                    rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 0, count: m))
        let p = lp.compiled()
        for kind in 0..<2 {
            var f: any BasisFactorization = kind == 0 ? DenseLUBasis() : SparseQRBasis()
            let name = kind == 0 ? "DenseLUBasis" : "SparseQRBasis"
            var basic: [Int32] = (0..<m).map { Int32(n + $0) }
            do { try f.refactor(basic: basic, lp: p) } catch { out.append("\(name): slack basis refactor threw \(error)"); continue }
            var updates = 0
            for _ in 0..<min(60, 3 * m) {
                // entering column q (nonbasic), leaving position r chosen with a usable pivot
                let q = g.int(0, n + m - 1)
                if basic.contains(Int32(q)) { continue }
                var aq = [Double](repeating: 0, count: m)
                if q < n { for i in 0..<m { aq[i] = A[i][q] } } else { aq[q - n] = -1 }
                var alpha = aq
                f.ftran(&alpha)
                let usable = (0..<m).filter({ abs(alpha[$0]) > 0.5 })
                if usable.isEmpty { continue }
                let r = usable[g.int(0, usable.count - 1)]
                // the reference: ftran agrees with a naive solve with the current basis
                let B = basisMatrix(lp, basic)
                if let ref = naiveSolve(B, aq) { rec("\(name).ftran(after \(updates) updates)", relErr(alpha, ref)) }
                do { try f.update(alpha: alpha, leaving: r) } catch { out.append("\(name): update threw \(error)"); break }
                basic[r] = Int32(q)
                updates += 1
                let B2 = basisMatrix(lp, basic)
                let rhs = (0..<m).map { _ in Double(g.int(-3, 3)) }
                var s1 = rhs, s2 = rhs
                f.ftran(&s1)
                f.btran(&s2)
                if let ref = naiveSolve(B2, rhs) { rec("\(name).ftran", relErr(s1, ref)) }
                if let ref = naiveSolve(transpose(B2), rhs) { rec("\(name).btran", relErr(s2, ref)) }
                if f.needsRefactor {
                    do { try f.refactor(basic: basic, lp: p) } catch { out.append("\(name): refactor after updates threw \(error)") }
                    rec("\(name).updatesSinceRefactor after refactor", Double(f.updatesSinceRefactor))
                }
            }
            if f.updatesSinceRefactor != updates % (kind == 0 ? 100 : 50) && updates < (kind == 0 ? 100 : 50) {
                out.append("\(name): updatesSinceRefactor \(f.updatesSinceRefactor) != \(updates)")
            }
            // singular basis: duplicate a structural column in two positions
            if m >= 2 && n >= 1 {
                let j = g.int(0, n - 1)
                if (0..<m).contains(where: { A[$0][j] != 0 }) {
                    var bad = basic
                    bad[0] = Int32(j); bad[1] = Int32(j)
                    do {
                        try f.refactor(basic: bad, lp: p)
                        out.append("\(name): duplicated column \(j) in the basis was accepted (trial \(trial), m=\(m))")
                    } catch {
                        if case .singular(let positions, _) = error {
                            if kind == 0 && positions.isEmpty { out.append("DenseLUBasis: singular without positions") }
                            if kind == 0 { rec("DenseLUBasis singular positions include 0 or 1 (1 = no)", positions.contains(where: { $0 == 0 || $0 == 1 }) ? 0 : 1) }
                        } else { out.append("\(name): duplicate column gave \(error), not .singular") }
                    }
                }
            }
        }
    }
    // refactorInterval semantics
    do {
        var f = DenseLUBasis(refactorInterval: 3)
        let lp = LP(m: 2, n: 2, A: [[1, 0], [0, 1]], c: [0, 0], maximize: false, xl: [0, 0], xu: [1, 1], rl: [0, 0], ru: [0, 0])
        let p = lp.compiled()
        try f.refactor(basic: [2, 3], lp: p)
        var flags: [Bool] = []
        for _ in 0..<3 {
            try f.update(alpha: [-1, 0], leaving: 0)
            flags.append(f.needsRefactor)
        }
        out.append("DenseLUBasis(refactorInterval: 3).needsRefactor after 1,2,3 updates: \(flags)")
        do { try f.update(alpha: [0, 1], leaving: 0); out.append("update with zero pivot accepted") } catch { out.append("update with zero pivot -> \(error)") }
    } catch { out.append("refactorInterval probe threw \(error)") }

    for (k, v) in worst.sorted(by: { $0.key < $1.key }) { out.append(String(format: "%-60@ worst %.2e", k as NSString, v)) }
    return out
}
