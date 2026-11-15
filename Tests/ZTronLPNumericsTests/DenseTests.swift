// Specification §6.1 and §6.2: the dense container and the LAPACK wrappers (LU, Cholesky,
// QR, triangular solves) against straightforward loops.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

/// A·B by the definition.
private func product(_ a: DenseMatrix, _ b: DenseMatrix) -> DenseMatrix {
    var c = DenseMatrix(rows: a.rows, cols: b.cols)
    for i in 0..<a.rows {
        for j in 0..<b.cols {
            var total = 0.0
            for k in 0..<a.cols { total += a[i, k] * b[k, j] }
            c[i, j] = total
        }
    }
    return c
}

private func maxDifference(_ a: DenseMatrix, _ b: DenseMatrix) -> Double {
    maxDifference(a.storage, b.storage)
}

@Suite("Dense containers and LAPACK")
struct DenseTests {
    // MARK: DenseMatrix

    @Test func storageIsColumnMajor() {
        var a = DenseMatrix(rows: 2, cols: 3)
        #expect(a.storage == [0, 0, 0, 0, 0, 0])
        a[0, 0] = 1
        a[1, 0] = 2
        a[0, 2] = 5
        #expect(a.storage == [1, 2, 0, 0, 5, 0])
        #expect(a[1, 0] == 2 && a[0, 2] == 5 && a[1, 2] == 0)
        let b = DenseMatrix(rows: 2, cols: 2, storage: [1, 2, 3, 4])
        #expect(b[0, 1] == 3 && b[1, 1] == 4)
        #expect(b == DenseMatrix(rows: 2, cols: 2, storage: [1, 2, 3, 4]))
        #expect(b != b.transposed())
        #expect(b.transposed().storage == [1, 3, 2, 4])
        #expect(DenseMatrix.identity(3).storage == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(DenseMatrix(rows: 0, cols: 0).storage.isEmpty)
        // A copy is independent (copy-on-write).
        var copy = b
        copy[0, 0] = 9
        #expect(b[0, 0] == 1 && copy[0, 0] == 9)
    }

    @Test func aSparseMatrixConvertsToItsDenseForm() {
        let sparse = SparseCSC.fromTriplets(rows: 3, cols: 2, [(row: 0, col: 0, value: 1), (row: 2, col: 0, value: -2), (row: 1, col: 1, value: 4)])
        let dense = DenseMatrix(sparse)
        #expect(dense.rows == 3 && dense.cols == 2)
        #expect(dense.storage == [1, 0, -2, 0, 4, 0])
    }

    @Test(arguments: [(1, 1), (3, 5), (7, 2), (20, 20), (33, 17)])
    func matrixVectorAndMatrixMatrixProducts(_ rows: Int, _ cols: Int) {
        var rng = SeededGenerator(seed: UInt64(rows * 100 + cols))
        let a = randomDense(rows: rows, cols: cols, &rng)
        let x = randomVector(cols, &rng)
        let y = randomVector(rows, &rng)

        let ax = a.multiply(x)
        let aty = a.multiplyTranspose(y)
        for i in 0..<rows {
            var total = 0.0
            for j in 0..<cols { total += a[i, j] * x[j] }
            #expect(abs(ax[i] - total) <= 1e-12 * Double(cols))
        }
        for j in 0..<cols {
            var total = 0.0
            for i in 0..<rows { total += a[i, j] * y[i] }
            #expect(abs(aty[j] - total) <= 1e-12 * Double(rows))
        }

        let b = randomDense(rows: cols, cols: 4, &rng)
        #expect(maxDifference(a.multiplied(by: b), product(a, b)) <= 1e-12 * Double(cols))
        #expect(maxDifference(a.multiplied(by: .identity(cols)), a) <= 1e-15)

        // ‖A‖₁ is the largest absolute column sum.
        var norm = 0.0
        for j in 0..<cols {
            var columnSum = 0.0
            for i in 0..<rows { columnSum += abs(a[i, j]) }
            norm = max(norm, columnSum)
        }
        #expect(abs(a.oneNorm() - norm) <= 1e-12 * Double(rows))
        #expect(a.transposed().transposed() == a)
    }

    @Test func theWeightedGramMatrixFillsTheLowerTriangle() {
        var rng = SeededGenerator(seed: 5)
        let a = randomDense(rows: 6, cols: 11, &rng)
        let d = (0..<11).map { _ in rng.uniform(in: 0.1...3) }
        let gram = a.weightedGram(d)
        #expect(gram.rows == 6 && gram.cols == 6)
        for i in 0..<6 {
            for j in 0..<6 {
                if j > i {
                    #expect(gram[i, j] == 0)                    // the upper triangle is not written
                } else {
                    var total = 0.0
                    for k in 0..<11 { total += a[i, k] * d[k] * a[j, k] }
                    #expect(abs(gram[i, j] - total) <= 1e-12)
                }
            }
        }
        // A zero weight removes its column; a negative one is treated as zero.
        var weights = [Double](repeating: 0, count: 11)
        weights[3] = 4
        weights[4] = -1
        let single = a.weightedGram(weights)
        #expect(abs(single[2, 1] - 4 * a[2, 3] * a[1, 3]) <= 1e-13)
    }

    // MARK: LU

    @Test(arguments: [1, 2, 5, 16, 50])
    func luSolvesBothSystems(_ n: Int) throws {
        var rng = SeededGenerator(seed: UInt64(n) &+ 40)
        var a = randomDense(rows: n, cols: n, &rng)
        for i in 0..<n { a[i, i] += 3 }                         // comfortably nonsingular
        let lu = try DenseLU(a)
        #expect(lu.n == n && lu.factors.count == n * n && lu.pivots.count == n)
        #expect(lu.pivots.allSatisfy { $0 >= 1 && Int($0) <= n })   // one-based, as LAPACK returns them
        #expect(lu.smallestPivot > 0 && lu.largestPivot >= lu.smallestPivot)
        #expect(abs(lu.oneNorm - a.oneNorm()) <= 1e-15)
        #expect(lu.deficientPivots(relativeTolerance: 1e-11).positions.isEmpty)

        let rhs = randomVector(n, &rng)
        var x = rhs
        lu.solve(&x)
        #expect(residual(a, x, rhs) <= 1e-11)
        var y = rhs
        lu.solve(&y, transpose: true)
        #expect(residual(a.transposed(), y, rhs) <= 1e-11)
        // The reference solver agrees.
        let reference = try #require(denseSolve(a, rhs))
        #expect(maxDifference(x, reference) <= 1e-11)
    }

    @Test func luReportsExactlySingularMatricesWithTheirPositions() {
        // Column 2 repeats column 0, and every multiplier is a binary fraction: the third
        // pivot is exactly zero, not merely tiny.
        let a = DenseMatrix(rows: 3, cols: 3, storage: [4, 2, 1, 1, 3, 5, 4, 2, 1])
        do {
            _ = try DenseLU(a)
            Issue.record("a singular matrix factored")
        } catch {
            guard case .singular(let positions, let rows) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(positions == [2] && rows.count == 1)
        }
        #expect(denseSolve(a, [1, 1, 1]) == nil)
        // A zero matrix: every position is deficient, and the rows named are all different.
        do {
            _ = try DenseLU(DenseMatrix(rows: 3, cols: 3))
            Issue.record("the zero matrix factored")
        } catch {
            guard case .singular(let positions, let rows) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(positions == [0, 1, 2] && Set(rows) == [0, 1, 2])
        }
    }

    @Test func deficientPivotsNameTheRowLeftUncovered() throws {
        // diag(1, ε, 1) with rows 0 and 2 swapped by pivoting on a larger entry below.
        let a = DenseMatrix(rows: 3, cols: 3, storage: [1, 0, 5, 0, 1e-14, 0, 0, 0, 1])
        let lu = try DenseLU(a)
        #expect(lu.smallestPivot <= 1e-13)
        let strict = lu.deficientPivots(relativeTolerance: 1e-11)
        #expect(strict.positions == [1])
        #expect(strict.rows == [1])                             // row 1 holds the tiny pivot
        #expect(lu.deficientPivots(relativeTolerance: 0).positions.isEmpty)
        #expect(lu.deficientPivots(relativeTolerance: 1).positions.count >= 2)
    }

    @Test func luConditionEstimate() throws {
        #expect(try DenseLU(.identity(4)).conditionEstimate() == 1)
        #expect(try DenseLU(.identity(4)).reciprocalCondition() == 1)
        // diag(1, 1e-6): κ₁ = 1e6.
        let scaled = try DenseLU(DenseMatrix(rows: 2, cols: 2, storage: [1, 0, 0, 1e-6]))
        let estimate = try #require(scaled.conditionEstimate())
        #expect(abs(estimate - 1e6) <= 1)
        // The empty matrix is perfectly conditioned by convention.
        let empty = try DenseLU(DenseMatrix(rows: 0, cols: 0))
        #expect(empty.conditionEstimate() == 1)
        var nothing: [Double] = []
        empty.solve(&nothing)
        #expect(nothing.isEmpty)
    }

    // MARK: Cholesky

    @Test(arguments: [1, 3, 12, 40])
    func choleskySolvesPositiveDefiniteSystems(_ n: Int) throws {
        var rng = SeededGenerator(seed: UInt64(n) &+ 60)
        let g = randomDense(rows: n, cols: n + 3, &rng)
        // M = G·Gᵀ + I, full storage; the factorization reads the lower triangle only.
        var m = product(g, g.transposed())
        for i in 0..<n { m[i, i] += 1 }
        var lowerOnly = m
        for j in 0..<n { for i in 0..<j { lowerOnly[i, j] = .nan } }   // poison the upper triangle
        let cholesky = try DenseCholesky(lowerTriangleOf: lowerOnly)
        #expect(cholesky.n == n)
        let rhs = randomVector(n, &rng)
        var x = rhs
        cholesky.solve(&x)
        #expect(residual(m, x, rhs) <= 1e-10)
        // The lower triangle of the Gram kernel feeds it directly.
        let gram = g.weightedGram([Double](repeating: 1, count: n + 3))
        var shifted = gram
        for i in 0..<n { shifted[i, i] += 1 }
        var y = rhs
        try DenseCholesky(lowerTriangleOf: shifted).solve(&y)
        #expect(maxDifference(x, y) <= 1e-10)
    }

    @Test func choleskyRejectsMatricesThatAreNotPositiveDefinite() {
        // The leading minor of order 2 is the first that fails.
        let indefinite = DenseMatrix(rows: 3, cols: 3, storage: [4, 2, 0, 2, 1, 0, 0, 0, 1])   // det of the 2×2 minor is 0
        do {
            _ = try DenseCholesky(lowerTriangleOf: indefinite)
            Issue.record("a semidefinite matrix factored")
        } catch {
            #expect(error == .notPositiveDefinite(2))
        }
        do {
            _ = try DenseCholesky(lowerTriangleOf: DenseMatrix(rows: 2, cols: 2, storage: [-1, 0, 0, 1]))
            Issue.record("a negative definite minor factored")
        } catch {
            #expect(error == .notPositiveDefinite(1))
        }
        #expect(throws: Never.self) { try DenseCholesky(lowerTriangleOf: DenseMatrix(rows: 0, cols: 0)) }
    }

    // MARK: QR

    @Test func qrReportsTheRank() throws {
        var rng = SeededGenerator(seed: 70)
        let full = randomDense(rows: 9, cols: 6, &rng)
        #expect(try DenseQR(full).rank() == 6)
        // Make column 4 a combination of columns 0 and 2: rank 5.
        var deficient = full
        for i in 0..<9 { deficient[i, 4] = 2 * full[i, 0] - 0.5 * full[i, 2] }
        #expect(try DenseQR(deficient).rank() == 5)
        // Two more dependent columns: rank 3.
        for i in 0..<9 {
            deficient[i, 5] = full[i, 1]
            deficient[i, 3] = full[i, 1] + full[i, 0]
        }
        #expect(try DenseQR(deficient).rank() == 3)
        #expect(try DenseQR(DenseMatrix(rows: 4, cols: 3)).rank() == 0)
        #expect(try DenseQR(.identity(5)).rank() == 5)
        let square = try DenseQR(.identity(5))
        #expect(square.rows == 5 && square.cols == 5 && square.tau.count == 5)
        #expect(try DenseQR(DenseMatrix(rows: 3, cols: 0)).rank() == 0)
    }

    @Test func qrSolvesLeastSquares() throws {
        var rng = SeededGenerator(seed: 71)
        let a = randomDense(rows: 12, cols: 5, &rng)
        // A consistent system is solved exactly.
        let truth = randomVector(5, &rng)
        let qr = try DenseQR(a)
        let exact = try #require(qr.solveLeastSquares(a.multiply(truth)))
        #expect(maxDifference(exact, truth) <= 1e-12)
        // An inconsistent one: the residual is orthogonal to the columns (the normal equations).
        let b = randomVector(12, &rng)
        let x = try #require(qr.solveLeastSquares(b))
        var r = a.multiply(x)
        for i in 0..<12 { r[i] -= b[i] }
        #expect(Vec.maxAbs(a.multiplyTranspose(r)) <= 1e-12)
        // A square nonsingular system.
        var s = randomDense(rows: 6, cols: 6, &rng)
        for i in 0..<6 { s[i, i] += 3 }
        let rhs = randomVector(6, &rng)
        let squareQR = try DenseQR(s)
        let solved = try #require(squareQR.solveLeastSquares(rhs))
        #expect(residual(s, solved, rhs) <= 1e-12)
        // An exactly singular R has no solution.
        let zero = try DenseQR(DenseMatrix(rows: 3, cols: 2))
        #expect(zero.solveLeastSquares([1, 2, 3]) == nil)
        let noColumns = try DenseQR(DenseMatrix(rows: 3, cols: 0))
        #expect(noColumns.solveLeastSquares([1, 2, 3]) == [])
    }

    // MARK: Triangular solves and the reference solver

    @Test func triangularSolves() {
        var rng = SeededGenerator(seed: 80)
        let n = 7
        var lower = DenseMatrix(rows: n, cols: n)
        var upper = DenseMatrix(rows: n, cols: n)
        var unitLower = DenseMatrix(rows: n, cols: n)
        for j in 0..<n {
            for i in 0..<n {
                let value = rng.uniform(in: -1...1)
                if i > j {
                    lower[i, j] = value
                    unitLower[i, j] = value
                } else if i < j {
                    upper[i, j] = value
                }
            }
            lower[j, j] = 2 + rng.uniform()
            upper[j, j] = 2 + rng.uniform()
            unitLower[j, j] = 1
        }
        let rhs = randomVector(n, &rng)

        var x = rhs
        triangularSolve(lower, &x, upper: false)
        #expect(residual(lower, x, rhs) <= 1e-12)
        x = rhs
        triangularSolve(upper, &x, upper: true)
        #expect(residual(upper, x, rhs) <= 1e-12)
        x = rhs
        triangularSolve(lower, &x, upper: false, transpose: true)
        #expect(residual(lower.transposed(), x, rhs) <= 1e-12)
        x = rhs
        triangularSolve(upper, &x, upper: true, transpose: true)
        #expect(residual(upper.transposed(), x, rhs) <= 1e-12)
        // With a unit diagonal the stored diagonal is not read.
        var poisoned = unitLower
        for j in 0..<n { poisoned[j, j] = 1e30 }
        x = rhs
        triangularSolve(poisoned, &x, upper: false, unitDiagonal: true)
        #expect(residual(unitLower, x, rhs) <= 1e-12)
        var nothing: [Double] = []
        triangularSolve(DenseMatrix(rows: 0, cols: 0), &nothing, upper: true)
        #expect(nothing.isEmpty)
    }

    @Test func theReferenceSolver() throws {
        let a = DenseMatrix(rows: 2, cols: 2, storage: [2, 1, 1, 3])       // [[2, 1], [1, 3]]
        let x = try #require(denseSolve(a, [3, 5]))
        #expect(abs(x[0] - 0.8) <= 1e-15 && abs(x[1] - 1.4) <= 1e-15)
        #expect(denseSolve(DenseMatrix(rows: 2, cols: 2, storage: [1, 2, 2, 4]), [1, 1]) == nil)
        #expect(denseSolve(DenseMatrix(rows: 0, cols: 0), []) == [])
        #expect(a.multiply(x) == [3, 5] || residual(a, x, [3, 5]) <= 1e-15)
    }

    @Test func numericalErrorsCompareByValue() {
        #expect(NumericalError.singular(positions: [1], rows: [2]) == .singular(positions: [1], rows: [2]))
        #expect(NumericalError.singular(positions: [1], rows: [2]) != .singular(positions: [], rows: []))
        #expect(NumericalError.notPositiveDefinite(3) != .notPositiveDefinite(4))
        #expect(NumericalError.unstableUpdate(pivot: 0) != .factorizationFailed("x"))
        let set: Set<NumericalError> = [.notPositiveDefinite(0), .notPositiveDefinite(0), .factorizationFailed("a")]
        #expect(set.count == 2)
    }
}
