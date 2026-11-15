// Specification §6.1: the in-tree sparse kernels on both sides of the 1e5-nonzero switch to
// Accelerate's SparseMultiply, and the sparse symmetric solver (Cholesky / LDLᵀ with symbolic
// reuse) the interior-point method relies on.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

/// A random sparse matrix with about `density` of its entries stored.
private func randomSparse(rows: Int, cols: Int, density: Double, seed: UInt64) -> SparseCSC {
    var rng = SeededGenerator(seed: seed)
    var colStart = [0]
    var rowIndex: [Int32] = []
    var values: [Double] = []
    for _ in 0..<cols {
        for i in 0..<rows where rng.chance(density) {
            rowIndex.append(Int32(i))
            values.append(rng.uniform(in: -2...2))
        }
        colStart.append(values.count)
    }
    return SparseCSC(rows: Int32(rows), cols: Int32(cols), colStart: colStart, rowIndex: rowIndex, values: values)
}

/// A symmetric matrix as the lower-triangle pattern and values the solver takes, plus its
/// dense form for residual checks.
private struct SymmetricSystem {
    let n: Int
    var colStart: [Int] = [0]
    var rowIndex: [Int32] = []
    var values: [Double] = []
    var dense: DenseMatrix

    /// G·Gᵀ + shift·I for a random sparse G: positive definite for shift > 0.
    init(n: Int, density: Double, shift: Double, seed: UInt64) {
        self.n = n
        let g = DenseMatrix(randomSparse(rows: n, cols: n + 2, density: density, seed: seed))
        var m = DenseMatrix(rows: n, cols: n)
        for i in 0..<n {
            for j in 0...i {
                var total = i == j ? shift : 0
                for k in 0..<g.cols { total += g[i, k] * g[j, k] }
                m[i, j] = total
                m[j, i] = total
            }
        }
        dense = m
        for j in 0..<n {
            for i in j..<n where m[i, j] != 0 || i == j {
                rowIndex.append(Int32(i))
                values.append(m[i, j])
            }
            colStart.append(values.count)
        }
    }

    /// The values of the pattern for a different dense matrix with the same pattern.
    func values(of matrix: DenseMatrix) -> [Double] {
        var out: [Double] = []
        for j in 0..<n {
            for p in colStart[j]..<colStart[j + 1] { out.append(matrix[Int(rowIndex[p]), j]) }
        }
        return out
    }
}

@Suite("Sparse kernels and solvers")
struct SparseTests {
    // MARK: Matrix-vector products

    @Test(arguments: [
        (30, 50, 0.2),          // small: the in-tree loops
        (200, 300, 0.05),
        (1, 40, 0.5),
        (40, 1, 0.5),
        (420, 520, 0.5),        // about 109,000 nonzeros: Accelerate's SparseMultiply
        (700, 300, 0.6),        // about 126,000 nonzeros
    ])
    func productsMatchTheDenseReference(_ rows: Int, _ cols: Int, _ density: Double) {
        let a = randomSparse(rows: rows, cols: cols, density: density, seed: UInt64(rows * 7 + cols))
        var rng = SeededGenerator(seed: 5)
        var x = randomVector(cols, &rng)
        if cols > 3 { x[1] = 0; x[cols - 1] = 0 }             // zero entries take the skip path
        let y = randomVector(rows, &rng)

        // A·x against the pure-Swift reference of the model layer.
        let reference = a.multiply(x)
        var ax = [Double](repeating: .nan, count: rows)       // must be overwritten, not accumulated into
        a.multiply(x, into: &ax)
        #expect(maxDifference(ax, reference) <= 1e-11 * (1 + Vec.maxAbs(reference)))
        // … accumulating into an existing vector.
        var accumulated = y
        a.multiply(x, into: &accumulated, accumulate: true)
        #expect(maxDifference(accumulated, zip(y, reference).map { $0 + $1 }) <= 1e-11 * (1 + Vec.maxAbs(reference)))

        // Aᵀ·y, whole and in blocks.
        let referenceT = a.multiplyTranspose(y)
        var aty = [Double](repeating: .nan, count: cols)
        a.multiplyTranspose(y, into: &aty)
        #expect(maxDifference(aty, referenceT) <= 1e-11 * (1 + Vec.maxAbs(referenceT)))
        var blocks: [Double] = []
        let cut = cols / 3
        blocks += a.multiplyTranspose(y, columns: 0..<cut)
        blocks += a.multiplyTranspose(y, columns: cut..<cols)
        #expect(blocks == aty)                                // the same loop, column by column
        #expect(a.multiplyTranspose(y, columns: 0..<0).isEmpty)
    }

    @Test func theSwitchToSparseMultiplyHappensAtOneHundredThousandNonzeros() {
        #expect(sparseMultiplyThreshold == 100_000)
        // Just below and just above the threshold give the same product.
        for density in [0.38, 0.42] {
            let a = randomSparse(rows: 500, cols: 500, density: density, seed: 9)
            #expect((a.nnz < sparseMultiplyThreshold) == (density < 0.4))
            var rng = SeededGenerator(seed: 1)
            let x = randomVector(500, &rng)
            var out = [Double](repeating: 0, count: 500)
            a.multiply(x, into: &out)
            #expect(maxDifference(out, a.multiply(x)) <= 1e-10)
        }
    }

    @Test func columnKernels() {
        let a = randomSparse(rows: 25, cols: 18, density: 0.3, seed: 12)
        let dense = DenseMatrix(a)
        var rng = SeededGenerator(seed: 13)
        let v = randomVector(25, &rng)
        for j in 0..<18 {
            var dot = 0.0
            var largest = 0.0
            for i in 0..<25 {
                dot += dense[i, j] * v[i]
                largest = max(largest, abs(dense[i, j]))
            }
            #expect(abs(a.dot(column: j, v) - dot) <= 1e-13)
            #expect(a.maxAbs(inColumn: j) == largest)

            var y = v
            a.axpy(column: j, -2.5, into: &y)
            for i in 0..<25 { #expect(abs(y[i] - (v[i] - 2.5 * dense[i, j])) <= 1e-13) }
            var unchanged = v
            a.axpy(column: j, 0, into: &unchanged)
            #expect(unchanged == v)

            var scattered = [Double](repeating: 0, count: 25)
            a.scatter(column: j, into: &scattered)
            #expect(scattered == (0..<25).map { dense[$0, j] })
        }
        #expect(abs(a.density - Double(a.nnz) / (25 * 18)) <= 1e-15)
        #expect(SparseCSC(rows: 0, cols: 0).density == 0)
        #expect(SparseCSC(rows: 3, cols: 4).density == 0)
    }

    @Test func emptyMatricesMultiply() {
        let empty = SparseCSC(rows: 3, cols: 2)
        var y = [1.0, 2, 3]
        empty.multiply([4, 5], into: &y)
        #expect(y == [0, 0, 0])
        y = [1, 2, 3]
        empty.multiply([4, 5], into: &y, accumulate: true)
        #expect(y == [1, 2, 3])
        var t = [9.0, 9]
        empty.multiplyTranspose([1, 1, 1], into: &t)
        #expect(t == [0, 0])
    }

    // MARK: Sparse symmetric solver

    @Test(arguments: [(1, 1.0), (8, 0.5), (60, 0.1), (250, 0.02)])
    func choleskySolvesAndReusesItsSymbolicAnalysis(_ n: Int, _ density: Double) throws {
        let system = SymmetricSystem(n: n, density: density, shift: 1, seed: UInt64(n))
        var solver = try SparseSymmetricSolver(n: n, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex)
        // (The solver is non-copyable, so its properties are read into locals for `#expect`.)
        let (size, initialKind, storedEntries, initialCount) = (solver.n, solver.kind, solver.nnz, solver.factorizations)
        #expect(size == n && initialKind == .cholesky && storedEntries == system.values.count)
        #expect(initialCount == 0)

        // Before the first factorization a solve does nothing.
        var untouched = [Double](repeating: 1, count: n)
        solver.solve(&untouched)
        #expect(untouched == [Double](repeating: 1, count: n))

        var rng = SeededGenerator(seed: UInt64(n) &+ 1)
        let rhs = randomVector(n, &rng)
        try solver.factor(values: system.values)
        var x = rhs
        solver.solve(&x)
        #expect(residual(system.dense, x, rhs) <= 1e-9 * (1 + Vec.maxAbs(x)))

        // New values on the same pattern: a numeric refactorization, no new analysis.
        for round in 1...3 {
            var shifted = system.dense
            for i in 0..<n { shifted[i, i] += Double(round) * 2.5 }
            try solver.factor(values: system.values(of: shifted))
            let count = solver.factorizations
            #expect(count == round + 1)
            var y = rhs
            solver.solve(&y)
            #expect(residual(shifted, y, rhs) <= 1e-9 * (1 + Vec.maxAbs(y)), "round \(round)")
        }
        // And back to the first matrix.
        try solver.factor(values: system.values)
        var again = rhs
        solver.solve(&again)
        #expect(maxDifference(again, x) <= 1e-10 * (1 + Vec.maxAbs(x)))
    }

    @Test func anIndefiniteMatrixFailsCholeskyWithoutTrapping() throws {
        let system = SymmetricSystem(n: 30, density: 0.15, shift: 1, seed: 3)
        var solver = try SparseSymmetricSolver(n: 30, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex)
        try solver.factor(values: system.values)

        // Make the matrix indefinite: a large negative entry on the diagonal.
        var indefinite = system.dense
        indefinite[4, 4] = -50
        do {
            try solver.factor(values: system.values(of: indefinite))
            Issue.record("an indefinite matrix factored with Cholesky")
        } catch {
            #expect(error == .notPositiveDefinite(0))
        }
        // The failed factors are gone: solving does nothing rather than use stale ones.
        var rhs = [Double](repeating: 1, count: 30)
        solver.solve(&rhs)
        #expect(rhs == [Double](repeating: 1, count: 30))

        // The solver recovers with good values, still as Cholesky.
        try solver.factor(values: system.values)
        let kind = solver.kind
        #expect(kind == .cholesky)
        var x = [Double](repeating: 1, count: 30)
        solver.solve(&x)
        #expect(residual(system.dense, x, [Double](repeating: 1, count: 30)) <= 1e-9)
    }

    @Test func ldltHandlesWhatCholeskyCannot() throws {
        let system = SymmetricSystem(n: 30, density: 0.15, shift: 1, seed: 4)
        var indefinite = system.dense
        indefinite[4, 4] = -50
        indefinite[17, 17] = -3
        let values = system.values(of: indefinite)

        var solver = try SparseSymmetricSolver(n: 30, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex)
        do {
            try solver.factor(values: values)
            Issue.record("an indefinite matrix factored with Cholesky")
        } catch {
            #expect(error == .notPositiveDefinite(0))
        }
        try solver.switchKind(to: .ldlt)
        let kind = solver.kind
        #expect(kind == .ldlt)
        try solver.factor(values: values)
        var rng = SeededGenerator(seed: 6)
        let rhs = randomVector(30, &rng)
        var x = rhs
        solver.solve(&x)
        #expect(residual(indefinite, x, rhs) <= 1e-8 * (1 + Vec.maxAbs(x)))

        // Switching to the kind already in use is a no-op that keeps the factors.
        try solver.switchKind(to: .ldlt)
        var again = rhs
        solver.solve(&again)
        #expect(again == x)

        // LDLᵀ from the start, on a positive definite matrix, agrees with Cholesky.
        var ldlt = try SparseSymmetricSolver(n: 30, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex, kind: .ldlt)
        var cholesky = try SparseSymmetricSolver(n: 30, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex)
        try ldlt.factor(values: system.values)
        try cholesky.factor(values: system.values)
        var a = rhs
        var b = rhs
        ldlt.solve(&a)
        cholesky.solve(&b)
        #expect(maxDifference(a, b) <= 1e-10 * (1 + Vec.maxAbs(b)))
    }

    @Test func aDiagonalSystem() throws {
        // The smallest pattern there is: only the diagonal.
        let n = 6
        var solver = try SparseSymmetricSolver(n: n, lowerColStart: Array(0...n), lowerRowIndex: (0..<n).map { Int32($0) })
        try solver.factor(values: [1, 2, 4, 8, 16, 32])
        var x = [Double](repeating: 32, count: n)
        solver.solve(&x)
        #expect(maxDifference(x, [32, 16, 8, 4, 2, 1]) <= 1e-13)     // square roots are not exact
    }

    @Test func manySolversCoexistAndReleaseTheirHandles() throws {
        // Create, use and drop solvers in a loop: the handles are released in deinit.
        let system = SymmetricSystem(n: 20, density: 0.2, shift: 1, seed: 8)
        let rhs = [Double](repeating: 1, count: 20)
        var reference: [Double]? = nil
        for _ in 0..<200 {
            var solver = try SparseSymmetricSolver(n: 20, lowerColStart: system.colStart, lowerRowIndex: system.rowIndex)
            try solver.factor(values: system.values)
            var x = rhs
            solver.solve(&x)
            if let reference { #expect(x == reference) } else { reference = x }
        }
    }
}
