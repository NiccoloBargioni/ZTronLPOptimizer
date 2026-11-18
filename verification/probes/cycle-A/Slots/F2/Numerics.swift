import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

private func naiveMul(_ a: [[Double]], _ x: [Double]) -> [Double] { a.map { row in zip(row, x).reduce(0) { $0 + $1.0 * $1.1 } } }
private func maxAbsDiff(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
private func relDiff(_ a: [Double], _ b: [Double]) -> Double { maxAbsDiff(a, b) / max(1, b.map { abs($0) }.max() ?? 0) }

func denseFromRows(_ rows: [[Double]]) -> DenseMatrix {
    let m = rows.count, n = rows.first?.count ?? 0
    var d = DenseMatrix(rows: m, cols: n)
    for j in 0..<n { for i in 0..<m { d.storage[j * m + i] = rows[i][j] } }
    return d
}

func runNumerics() {
    var r = Rng(4242)
    var report: [String: Double] = [:]
    func note(_ k: String, _ v: Double) { report[k] = max(report[k] ?? 0, v) }
    // 1. Dense products
    for _ in 0..<20 {
        let m = r.int(1, 30), n = r.int(1, 30)
        let rows = (0..<m).map { _ in (0..<n).map { _ in r.u(-1, 1) } }
        let d = denseFromRows(rows)
        let x = (0..<n).map { _ in r.u(-1, 1) }, y = (0..<m).map { _ in r.u(-1, 1) }
        note("dense multiply", relDiff(d.multiply(x), naiveMul(rows, x)))
        let t = (0..<n).map { j in (0..<m).map { i in rows[i][j] } }
        note("dense multiplyTranspose", relDiff(d.multiplyTranspose(y), naiveMul(t, y)))
        let k = r.int(1, 10)
        let brow = (0..<n).map { _ in (0..<k).map { _ in r.u(-1, 1) } }
        let prod = d.multiplied(by: denseFromRows(brow))
        var e = 0.0
        for i in 0..<m { for c in 0..<k { var s = 0.0; for p in 0..<n { s += rows[i][p] * brow[p][c] }; e = max(e, abs(prod[i, c] - s)) } }
        note("dense multiplied(by:)", e)
        let w = (0..<n).map { _ in r.u(0, 2) }
        let g = d.weightedGram(w)
        var eg = 0.0
        for i in 0..<m { for l in 0..<m { var s = 0.0; for p in 0..<n { s += rows[i][p] * w[p] * rows[l][p] }; eg = max(eg, abs(g[i, l] - (i >= l ? s : 0))) } }
        note("dense weightedGram", eg)
        var one = 0.0
        for j in 0..<n { one = max(one, (0..<m).map { abs(rows[$0][j]) }.reduce(0, +)) }
        note("dense oneNorm", abs(d.oneNorm() - one))
    }
    // 2. Sparse products, including the Accelerate path above sparseMultiplyThreshold.
    for (m, n, density) in [(40, 50, 0.2), (3, 200, 0.5), (1500, 1500, 0.06)] {
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<n { for i in 0..<m where r.chance(density) { entries.append((i, j, r.u(-1, 1))) } }
        let s = SparseCSC.fromTriplets(rows: m, cols: n, entries)
        var dense = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
        for e in entries { dense[e.row][e.col] += e.value }
        let x = (0..<n).map { _ in r.u(-1, 1) }, y = (0..<m).map { _ in r.u(-1, 1) }
        let ref = naiveMul(dense, x)
        note("sparse multiply nnz\(s.nnz)", relDiff(s.multiply(x), ref))
        var into = (0..<m).map { _ in r.u(-1, 1) }
        let base = into
        s.multiply(x, into: &into, accumulate: true)
        note("sparse multiply accumulate nnz\(s.nnz)", relDiff(into, zip(base, ref).map { $0 + $1 }))
        var into2 = (0..<m).map { _ in r.u(-1, 1) }
        s.multiply(x, into: &into2, accumulate: false)
        note("sparse multiply into (no accumulate) nnz\(s.nnz)", relDiff(into2, ref))
        let t = (0..<n).map { j in (0..<m).map { i in dense[i][j] } }
        let refT = naiveMul(t, y)
        note("sparse multiplyTranspose nnz\(s.nnz)", relDiff(s.multiplyTranspose(y), refT))
        var intoT = (0..<n).map { _ in 7.0 }
        s.multiplyTranspose(y, into: &intoT)
        note("sparse multiplyTranspose into nnz\(s.nnz)", relDiff(intoT, refT))
        let lo = r.int(0, n - 1), hi = r.int(lo, n)
        let part = s.multiplyTranspose(y, columns: lo..<hi)
        note("sparse multiplyTranspose(columns:) nnz\(s.nnz)", relDiff(part, Array(refT[lo..<hi])))
        let j = r.int(0, n - 1)
        note("sparse dot(column:)", abs(s.dot(column: j, y) - (0..<m).map { dense[$0][j] * y[$0] }.reduce(0, +)))
        var ax = y
        s.axpy(column: j, 0.7, into: &ax)
        note("sparse axpy(column:)", maxAbsDiff(ax, (0..<m).map { y[$0] + 0.7 * dense[$0][j] }))
        var sc = [Double](repeating: 0, count: m)
        s.scatter(column: j, into: &sc)
        note("sparse scatter(column:)", maxAbsDiff(sc, (0..<m).map { dense[$0][j] }))
        note("sparse maxAbs(inColumn:)", abs(s.maxAbs(inColumn: j) - ((0..<m).map { abs(dense[$0][j]) }.max() ?? 0)))
        let tr = s.transposed()
        var et = 0.0
        for p in 0..<min(200, entries.count) { let e = entries[p]; et = max(et, abs(tr[e.col, e.row] - s[e.row, e.col])) }
        note("sparse transposed", et)
        print("sparse case m\(m) n\(n) nnz \(s.nnz) (threshold \(sparseMultiplyThreshold))")
    }
    // 3. triangularSolve, all variants
    for _ in 0..<10 {
        let n = r.int(1, 25)
        var rows = (0..<n).map { _ in (0..<n).map { _ in r.u(-1, 1) } }
        for i in 0..<n { rows[i][i] = r.u(2, 4) * (r.chance(0.5) ? 1 : -1) }
        for upper in [true, false] { for transpose in [true, false] { for unit in [true, false] {
            var t = rows
            for i in 0..<n { for j in 0..<n {
                if upper ? (j < i) : (j > i) { t[i][j] = 0 }
                if i == j && unit { t[i][j] = 1 }
            } }
            var op = t
            if transpose { op = (0..<n).map { i in (0..<n).map { j in t[j][i] } } }
            let xTrue = (0..<n).map { _ in r.u(-1, 1) }
            var b = naiveMul(op, xTrue)
            // the stored matrix keeps garbage in the unused triangle and, for unit, on the diagonal
            triangularSolve(denseFromRows(rows), &b, upper: upper, transpose: transpose, unitDiagonal: unit)
            note("triangularSolve u\(upper) t\(transpose) unit\(unit)", maxAbsDiff(b, xTrue))
        } } }
    }
    // 4. DenseLU solves (dense and leading-zero RHS, both orientations), condition estimate
    for _ in 0..<20 {
        let n = r.int(1, 40)
        let rows = (0..<n).map { _ in (0..<n).map { _ in r.u(-1, 1) } }
        let d = denseFromRows(rows)
        guard let lu = try? DenseLU(d) else { continue }
        for leading in [0, n / 2, n - 1] {
            var xTrue = (0..<n).map { _ in r.u(-1, 1) }
            // b with leading zeros: choose b, then x = A⁻¹ b
            var b = (0..<n).map { _ in r.u(-1, 1) }
            for i in 0..<leading { b[i] = 0 }
            guard let xs = denseSolve(d, b) else { continue }
            var bb = b
            lu.solve(&bb)
            note("DenseLU solve leading\(leading > 0)", relDiff(bb, xs))
            let at = denseFromRows((0..<n).map { i in (0..<n).map { j in rows[j][i] } })
            guard let xt = denseSolve(at, b) else { continue }
            var bt = b
            lu.solve(&bt, transpose: true)
            note("DenseLU solve transpose leading\(leading > 0)", relDiff(bt, xt))
            xTrue[0] += 0
        }
        // exact κ1 by explicit inverse
        var inv1 = 0.0
        for j in 0..<n {
            var e = [Double](repeating: 0, count: n); e[j] = 1
            lu.solve(&e)
            inv1 = max(inv1, e.map { abs($0) }.reduce(0, +))
        }
        let kappa = inv1 * d.oneNorm()
        if let est = lu.conditionEstimate() { note("DenseLU conditionEstimate underestimate factor", kappa / est) }
    }
    // 5. Singular matrices
    var singularNotes: [String] = []
    do {
        let rows: [[Double]] = [[1, 2, 3], [2, 4, 6], [1, 0, 1]]
        do { _ = try DenseLU(denseFromRows(rows)); singularNotes.append("DenseLU accepted an exactly singular matrix") }
        catch { singularNotes.append("DenseLU singular -> \(error)") }
        singularNotes.append("denseSolve singular -> \(String(describing: denseSolve(denseFromRows(rows), [1, 2, 3])))")
    }
    // 6. Cholesky and QR
    for _ in 0..<10 {
        let n = r.int(1, 20)
        let g = (0..<n).map { _ in (0..<n).map { _ in r.u(-1, 1) } }
        var spd = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in 0..<n { for k in 0..<n { spd[i][j] += g[i][k] * g[j][k] }; if i == j { spd[i][j] += 0.5 } } }
        let ch = try! DenseCholesky(lowerTriangleOf: denseFromRows(spd))
        let xTrue = (0..<n).map { _ in r.u(-1, 1) }
        var b = naiveMul(spd, xTrue)
        ch.solve(&b)
        note("Cholesky solve", relDiff(b, xTrue))
        let mm = n + r.int(0, 10)
        let a = (0..<mm).map { _ in (0..<n).map { _ in r.u(-1, 1) } }
        let qr = try! DenseQR(denseFromRows(a))
        let rhs = (0..<mm).map { _ in r.u(-1, 1) }
        let ls = qr.solveLeastSquares(rhs)!
        // normal equations residual Aᵀ(Ax − b) ≈ 0
        let res = zip(naiveMul(a, ls), rhs).map { $0 - $1 }
        let at = (0..<n).map { j in (0..<mm).map { a[$0][j] } }
        note("QR least squares normal residual", naiveMul(at, res).map { abs($0) }.max() ?? 0)
        note("QR rank deficit", Double(n - qr.rank()))
    }
    do {
        let notPD: [[Double]] = [[1, 2], [2, 1]]
        do { _ = try DenseCholesky(lowerTriangleOf: denseFromRows(notPD)); singularNotes.append("Cholesky accepted an indefinite matrix") }
        catch { singularNotes.append("Cholesky indefinite -> \(error)") }
        let rankDef = DenseQR.self
        _ = rankDef
        let qr = try! DenseQR(denseFromRows([[1, 2], [2, 4], [3, 6]]))
        singularNotes.append("QR rank of a rank-1 3x2 matrix: \(qr.rank())")
    }
    // 7. BasisFactorization: refactor, ftran/btran, product-form updates, refactor triggers
    for factorization in ["dense", "qr"] {
        for trial in 0..<6 {
            let m = r.int(3, 30), n = r.int(m, 2 * m + 5)
            var entries: [(row: Int, col: Int, value: Double)] = []
            for j in 0..<n { for i in 0..<m where r.chance(0.3) || i == j % m { entries.append((i, j, r.u(-1, 1) + (i == j % m ? 2 : 0))) } }
            let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
            let lp = CompiledLP(a: a, c: [Double](repeating: 0, count: n), xl: [Double](repeating: 0, count: n),
                                xu: [Double](repeating: 1, count: n), rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
            func column(_ j: Int) -> [Double] {
                var v = [Double](repeating: 0, count: m)
                if j < n { for p in a.colStart[j]..<a.colStart[j + 1] { v[Int(a.rowIndex[p])] = a.values[p] } } else { v[j - n] = -1 }
                return v
            }
            var basic: [Int32] = (0..<m).map { Int32(n + $0) }
            // put some structurals in
            for k in 0..<m where r.chance(0.6) { basic[k] = Int32(k < n ? k : n + k) }
            var f: any BasisFactorization = factorization == "dense" ? DenseLUBasis() : SparseQRBasis()
            do { try f.refactor(basic: basic, lp: lp) } catch { print("refactor failed \(factorization) trial \(trial): \(error)"); continue }
            var updates = 0
            for _ in 0..<60 {
                // explicit B
                let bcols = basic.map { column(Int($0)) }
                let bRows = (0..<m).map { i in (0..<m).map { k in bcols[k][i] } }
                let bm = denseFromRows(bRows)
                let rhs = (0..<m).map { _ in r.u(-1, 1) }
                if let xs = denseSolve(bm, rhs) {
                    var v = rhs; f.ftran(&v); note("\(factorization) ftran after updates", relDiff(v, xs))
                    let bt = denseFromRows((0..<m).map { i in (0..<m).map { k in bRows[k][i] } })
                    if let xt = denseSolve(bt, rhs) { var w = rhs; f.btran(&w); note("\(factorization) btran after updates", relDiff(w, xt)) }
                }
                // pick an entering column not basic, a leaving row with a sound pivot
                let q = r.int(0, n + m - 1)
                if basic.contains(Int32(q)) { continue }
                var alpha = column(q)
                f.ftran(&alpha)
                guard let rr = alpha.indices.filter({ abs(alpha[$0]) > 0.3 }).randomElement(using: &rngShim) else { continue }
                do { try f.update(alpha: alpha, leaving: rr) } catch { print("update threw \(error)"); continue }
                basic[rr] = Int32(q)
                updates += 1
                if f.needsRefactor {
                    note("\(factorization) needsRefactor at updates (expected <= interval)", Double(f.updatesSinceRefactor))
                    do { try f.refactor(basic: basic, lp: lp) } catch { print("refactor after updates failed: \(error)"); break }
                }
            }
            note("\(factorization) updates done", Double(updates))
        }
        // Singular basis: duplicate columns
        let m = 4
        let entries: [(row: Int, col: Int, value: Double)] = [(0, 0, 1), (1, 0, 2), (0, 1, 1), (1, 1, 2), (2, 2, 1), (3, 3, 1)]
        let a = SparseCSC.fromTriplets(rows: m, cols: 4, entries)
        let lp = CompiledLP(a: a, c: [0, 0, 0, 0], xl: [0, 0, 0, 0], xu: [1, 1, 1, 1], rl: [0, 0, 0, 0], ru: [1, 1, 1, 1])
        var f: any BasisFactorization = factorization == "dense" ? DenseLUBasis() : SparseQRBasis()
        do {
            try f.refactor(basic: [0, 1, 2, 3], lp: lp)
            singularNotes.append("\(factorization): singular basis accepted")
        } catch {
            singularNotes.append("\(factorization): singular basis -> \(error)")
            if case .singular(let positions, let rows) = error, !positions.isEmpty {
                var repaired: [Int32] = [0, 1, 2, 3]
                for (k, p) in positions.enumerated() { repaired[Int(p)] = Int32(4 + Int(rows[k])) }
                do { try f.refactor(basic: repaired, lp: lp); singularNotes.append("\(factorization): repair with the named logicals factors: \(repaired)") }
                catch { singularNotes.append("\(factorization): repair with the named logicals still singular: \(repaired) \(error)") }
            }
        }
        // ftran on an un-factored basis
        let g = DenseLUBasis()
        var v = [1.0, 2.0]
        g.ftran(&v)
        singularNotes.append("DenseLUBasis.ftran before any refactor leaves rhs as \(v)")
    }
    for (k, v) in report.sorted(by: { $0.key < $1.key }) { print(String(format: "%-60@ %.3e", k as NSString, v)) }
    for s in singularNotes { print("NOTE", s) }
}

var rngShim = SeededGenerator(seed: 7)
