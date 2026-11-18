// Sparse kernels and Accelerate Sparse Solvers wrappers (specification §6.1).
//
// Sparse matvecs are in-tree CSC/CSR kernels, with `SparseMultiply` taking over when the
// matrix has at least 1e5 nonzeros. Row-wise products always use the CSR view (`aT`), never a
// scattered row scan (§6.2). Sparse Cholesky / LDLᵀ / QR come from Accelerate's Sparse Solvers;
// there is no sparse LU in Accelerate.

import Accelerate
import ZTronLPCore

/// The stored-entry count from which `SparseMultiply` replaces the in-tree loops.
public let sparseMultiplyThreshold = 100_000

extension SparseCSC {
    /// `y ← A·x` (or `y ← y + A·x` with `accumulate`).
    public func multiply(_ x: [Double], into y: inout [Double], accumulate: Bool = false) {
        precondition(x.count == Int(cols) && y.count == Int(rows), "dimension mismatch")
        if !accumulate {
            for i in y.indices { y[i] = 0 }
        }
        if nnz == 0 { return }
        if nnz >= sparseMultiplyThreshold {
            acceleratedMultiply(x, into: &y)
            return
        }
        colStart.withUnsafeBufferPointer { start in
            rowIndex.withUnsafeBufferPointer { index in
                values.withUnsafeBufferPointer { value in
                    x.withUnsafeBufferPointer { xp in
                        y.withUnsafeMutableBufferPointer { yp in
                            for j in 0..<xp.count {
                                let xj = xp[j]
                                if xj == 0 { continue }
                                for p in start[j]..<start[j + 1] {
                                    yp[Int(index[p])] += value[p] * xj
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `y ← Aᵀ·x`: one gather (sparse dot product) per column.
    public func multiplyTranspose(_ x: [Double], into y: inout [Double]) {
        precondition(x.count == Int(rows) && y.count == Int(cols), "dimension mismatch")
        colStart.withUnsafeBufferPointer { start in
            rowIndex.withUnsafeBufferPointer { index in
                values.withUnsafeBufferPointer { value in
                    x.withUnsafeBufferPointer { xp in
                        y.withUnsafeMutableBufferPointer { yp in
                            for j in 0..<yp.count {
                                var total = 0.0
                                for p in start[j]..<start[j + 1] {
                                    total += value[p] * xp[Int(index[p])]
                                }
                                yp[j] = total
                            }
                        }
                    }
                }
            }
        }
    }

    /// `Aᵀ·x` restricted to the columns `range`, returned as its own slice. Parallel pricing
    /// gives each child task one block and lets it produce its own output (§7.5).
    public func multiplyTranspose(_ x: [Double], columns range: Range<Int>) -> [Double] {
        precondition(x.count == Int(rows), "dimension mismatch")
        var out = [Double](repeating: 0, count: range.count)
        colStart.withUnsafeBufferPointer { start in
            rowIndex.withUnsafeBufferPointer { index in
                values.withUnsafeBufferPointer { value in
                    x.withUnsafeBufferPointer { xp in
                        out.withUnsafeMutableBufferPointer { op in
                            for (k, j) in range.enumerated() {
                                var total = 0.0
                                for p in start[j]..<start[j + 1] {
                                    total += value[p] * xp[Int(index[p])]
                                }
                                op[k] = total
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// The dot product of column `j` with a dense vector.
    @inlinable
    public func dot(column j: Int, _ x: [Double]) -> Double {
        var total = 0.0
        for p in colStart[j]..<colStart[j + 1] {
            total += values[p] * x[Int(rowIndex[p])]
        }
        return total
    }

    /// `y ← y + α · (column j)`.
    @inlinable
    public func axpy(column j: Int, _ alpha: Double, into y: inout [Double]) {
        if alpha == 0 { return }
        for p in colStart[j]..<colStart[j + 1] {
            y[Int(rowIndex[p])] += alpha * values[p]
        }
    }

    /// Column `j` scattered into a dense vector of length `rows` (which must be zero on entry).
    @inlinable
    public func scatter(column j: Int, into y: inout [Double]) {
        for p in colStart[j]..<colStart[j + 1] {
            y[Int(rowIndex[p])] = values[p]
        }
    }

    /// The largest absolute value in column `j`.
    @inlinable
    public func maxAbs(inColumn j: Int) -> Double {
        var largest = 0.0
        for p in colStart[j]..<colStart[j + 1] {
            let v = Swift.abs(values[p])
            if v > largest { largest = v }
        }
        return largest
    }

    /// The fraction of stored entries, 0…1.
    public var density: Double {
        rows == 0 || cols == 0 ? 0 : Double(nnz) / (Double(rows) * Double(cols))
    }

    /// `y ← y + A·x` through Accelerate's `SparseMultiply`.
    private func acceleratedMultiply(_ x: [Double], into y: inout [Double]) {
        colStart.withUnsafeBufferPointer { start in
            rowIndex.withUnsafeBufferPointer { index in
                values.withUnsafeBufferPointer { value in
                    x.withUnsafeBufferPointer { xp in
                        y.withUnsafeMutableBufferPointer { yp in
                            // SparseMultiply only reads the matrix and x; the API is typed with
                            // mutable pointers because the same struct serves factorizations.
                            let structure = SparseMatrixStructure(
                                rowCount: rows, columnCount: cols,
                                columnStarts: UnsafeMutablePointer(mutating: start.baseAddress!),
                                rowIndices: UnsafeMutablePointer(mutating: index.baseAddress!),
                                attributes: SparseAttributes_t(), blockSize: 1)
                            let matrix = SparseMatrix_Double(
                                structure: structure, data: UnsafeMutablePointer(mutating: value.baseAddress!))
                            let xv = DenseVector_Double(
                                count: Int32(xp.count), data: UnsafeMutablePointer(mutating: xp.baseAddress!))
                            let yv = DenseVector_Double(count: Int32(yp.count), data: yp.baseAddress!)
                            SparseMultiplyAdd(matrix, xv, yv)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Accelerate Sparse Solvers

/// Parameter errors must not trap the process: the default handler calls `__builtin_trap`.
/// Numerical failures are reported through the factorization's status, which the wrappers
/// below turn into `NumericalError`.
private let ignoreSparseParameterError: @convention(c) (UnsafePointer<CChar>) -> Void = { _ in }

private func symbolicOptions() -> SparseSymbolicFactorOptions {
    SparseSymbolicFactorOptions(
        control: SparseDefaultControl, orderMethod: SparseOrderAMD, order: nil, ignoreRowsAndColumns: nil,
        malloc: { malloc($0) }, free: { free($0) }, reportError: ignoreSparseParameterError)
}

private func numericOptions() -> SparseNumericFactorOptions {
    SparseNumericFactorOptions(
        control: SparseDefaultControl, scalingMethod: SparseScalingDefault, scaling: nil,
        pivotTolerance: 0.01, zeroTolerance: 1e-4 * Double.ulpOfOne)
}

/// Heap storage for a sparse matrix whose addresses stay fixed for as long as a factorization
/// refers to them.
private struct PinnedSparseStorage: ~Copyable {
    let columnStarts: UnsafeMutablePointer<Int>
    let rowIndices: UnsafeMutablePointer<Int32>
    let data: UnsafeMutablePointer<Double>
    let rows: Int32
    let cols: Int32
    let nnz: Int

    init(rows: Int, cols: Int, colStart: [Int], rowIndex: [Int32], values: [Double]?) {
        self.rows = Int32(rows)
        self.cols = Int32(cols)
        nnz = rowIndex.count
        columnStarts = .allocate(capacity: cols + 1)
        columnStarts.initialize(from: colStart, count: cols + 1)
        rowIndices = .allocate(capacity: Swift.max(1, nnz))
        rowIndices.initialize(from: rowIndex, count: nnz)
        data = .allocate(capacity: Swift.max(1, nnz))
        if let values {
            data.initialize(from: values, count: nnz)
        } else {
            data.initialize(repeating: 0, count: Swift.max(1, nnz))
        }
    }

    func structure(_ attributes: SparseAttributes_t) -> SparseMatrixStructure {
        SparseMatrixStructure(
            rowCount: rows, columnCount: cols, columnStarts: columnStarts, rowIndices: rowIndices,
            attributes: attributes, blockSize: 1)
    }

    deinit {
        columnStarts.deallocate()
        rowIndices.deallocate()
        data.deallocate()
    }
}

/// A sparse symmetric positive (semi)definite system solved by Accelerate's Cholesky or LDLᵀ,
/// with the symbolic analysis reused across numeric factorizations (§8.2).
///
/// The value owns Accelerate handles and is worker-private: it is non-copyable and is never
/// shared between tasks.
public struct SparseSymmetricSolver: ~Copyable {
    /// Which factorization the solver currently uses.
    public enum Kind: Sendable, Hashable { case cholesky, ldlt }

    public let n: Int
    public private(set) var kind: Kind
    /// Numeric factorizations performed so far.
    public private(set) var factorizations = 0

    private let storage: PinnedSparseStorage
    private var symbolic: SparseOpaqueSymbolicFactorization
    private var numeric: SparseOpaqueFactorization_Double?

    /// Analyses the pattern of the lower triangle of an n × n symmetric matrix (column-major;
    /// rows ≥ column within each column). AMD ordering.
    public init(n: Int, lowerColStart: [Int], lowerRowIndex: [Int32], kind: Kind = .cholesky) throws(NumericalError) {
        precondition(lowerColStart.count == n + 1, "colStart must have n + 1 entries")
        self.n = n
        self.kind = kind
        storage = PinnedSparseStorage(rows: n, cols: n, colStart: lowerColStart, rowIndex: lowerRowIndex, values: nil)
        var attributes = SparseAttributes_t()
        attributes.triangle = SparseLowerTriangle
        attributes.kind = SparseSymmetric
        symbolic = SparseFactor(
            kind == .cholesky ? SparseFactorizationCholesky : SparseFactorizationLDLT,
            storage.structure(attributes), symbolicOptions())
        numeric = nil
        if symbolic.status != SparseStatusOK {
            throw .factorizationFailed("sparse symbolic analysis failed")
        }
    }

    /// The number of stored entries of the lower triangle.
    public var nnz: Int { storage.nnz }

    /// Numerically factors the matrix whose lower-triangle values, in pattern order, are
    /// `values`. Throws `.notPositiveDefinite` when a Cholesky factorization breaks down.
    public mutating func factor(values: [Double]) throws(NumericalError) {
        precondition(values.count == storage.nnz, "values do not match the pattern")
        values.withUnsafeBufferPointer { vp in
            if let base = vp.baseAddress { storage.data.update(from: base, count: vp.count) }
        }
        var attributes = SparseAttributes_t()
        attributes.triangle = SparseLowerTriangle
        attributes.kind = SparseSymmetric
        let matrix = SparseMatrix_Double(structure: storage.structure(attributes), data: storage.data)
        if var existing = numeric {
            SparseRefactor(matrix, &existing, numericOptions())
            numeric = existing
        } else {
            numeric = SparseFactor(symbolic, matrix, numericOptions())
        }
        factorizations += 1
        guard let status = numeric?.status, status == SparseStatusOK else {
            // A failed handle cannot be refactored; start clean next time.
            if let failed = numeric { SparseCleanup(failed) }
            numeric = nil
            throw .notPositiveDefinite(0)
        }
    }

    /// Replaces the factorization kind (Cholesky → LDLᵀ after a breakdown). The pattern is
    /// analysed again for the new kind; the next `factor` call computes the factors.
    public mutating func switchKind(to newKind: Kind) throws(NumericalError) {
        if newKind == kind { return }
        if let existing = numeric { SparseCleanup(existing) }
        numeric = nil
        SparseCleanup(symbolic)
        kind = newKind
        var attributes = SparseAttributes_t()
        attributes.triangle = SparseLowerTriangle
        attributes.kind = SparseSymmetric
        symbolic = SparseFactor(
            newKind == .cholesky ? SparseFactorizationCholesky : SparseFactorizationLDLT,
            storage.structure(attributes), symbolicOptions())
        if symbolic.status != SparseStatusOK {
            throw .factorizationFailed("sparse symbolic analysis failed")
        }
    }

    /// Solves `M·x = rhs` in place with the current factors. Does nothing before the first
    /// successful `factor`.
    public func solve(_ rhs: inout [Double]) {
        precondition(rhs.count == n, "dimension mismatch")
        guard let numeric, n > 0 else { return }
        rhs.withUnsafeMutableBufferPointer { bp in
            SparseSolve(numeric, DenseVector_Double(count: Int32(bp.count), data: bp.baseAddress!))
        }
    }

    deinit {
        if let numeric { SparseCleanup(numeric) }
        SparseCleanup(symbolic)
    }
}

/// An immutable Accelerate QR factorization of a square sparse matrix, with its transpose.
///
/// The Sparse Solvers handles are C structs of raw pointers and so are not `Sendable`; this
/// box is what lets `SparseQRBasis` satisfy `BasisFactorization: Sendable` (§6.3).
// INVARIANT: immutable after init. The handles and the pinned matrix storage are created in
// `init`, never mutated or replaced afterwards, and released in `deinit`. Solves only read the
// factors (Accelerate allocates per-call workspace), so concurrent solves are safe.
final class SparseQRFactorization: @unchecked Sendable {
    let n: Int
    private let storage: PinnedSparseStorage
    private let forward: SparseOpaqueFactorization_Double
    private let transposed: SparseOpaqueFactorization_Double

    /// The largest error accepted when the fresh factors solve the probe system (see `init`).
    /// The components of the probe solution lie in [1, 2), so this is a relative error: a
    /// singular matrix misses by O(1), and 1e-4 corresponds to a condition number near 1e12.
    static let probeTolerance = 1e-4

    /// Factors the n × n matrix given in column-major form. Throws `.singular` (with no
    /// positions: QR cannot say where) for a singular or numerically singular matrix.
    init(n: Int, colStart: [Int], rowIndex: [Int32], values: [Double]) throws(NumericalError) {
        self.n = n
        let pinned = PinnedSparseStorage(rows: n, cols: n, colStart: colStart, rowIndex: rowIndex, values: values)
        let matrix = SparseMatrix_Double(structure: pinned.structure(SparseAttributes_t()), data: pinned.data)
        let factor = SparseFactor(SparseFactorizationQR, matrix, symbolicOptions(), numericOptions())
        guard factor.status == SparseStatusOK else {
            SparseCleanup(factor)
            throw .singular(positions: [], rows: [])
        }
        let transpose = SparseGetTranspose(factor)
        guard transpose.status == SparseStatusOK else {
            SparseCleanup(transpose)
            SparseCleanup(factor)
            throw .factorizationFailed("sparse QR transpose failed")
        }
        // Accelerate's QR does not reject every singular matrix: given a repeated or nearly
        // repeated column it reports success and then returns *a* solution of the singular
        // system. So the factors are probed with a system whose solution is known,
        // B·x = B·x₀; a matrix that cannot reproduce x₀ is singular for the simplex's purposes.
        if n > 0, !SparseQRFactorization.reproducesProbe(factor, n: n, colStart: colStart, rowIndex: rowIndex, values: values) {
            SparseCleanup(transpose)
            SparseCleanup(factor)
            throw .singular(positions: [], rows: [])
        }
        storage = pinned
        forward = factor
        transposed = transpose
    }

    private static func reproducesProbe(
        _ factor: SparseOpaqueFactorization_Double, n: Int, colStart: [Int], rowIndex: [Int32], values: [Double]
    ) -> Bool {
        var expected = [Double](repeating: 0, count: n)
        var probe = [Double](repeating: 0, count: n)
        for j in 0..<n {
            // Distinct, irregular components, so that no null vector is orthogonal to x₀ by accident.
            let x = 1 + (Double(j) * 0.6180339887498949).truncatingRemainder(dividingBy: 1)
            expected[j] = x
            for p in colStart[j]..<colStart[j + 1] { probe[Int(rowIndex[p])] += values[p] * x }
        }
        probe.withUnsafeMutableBufferPointer { bp in
            SparseSolve(factor, DenseVector_Double(count: Int32(bp.count), data: bp.baseAddress!))
        }
        for j in 0..<n {
            // Written so that a NaN fails the comparison.
            guard Swift.abs(probe[j] - expected[j]) <= probeTolerance else { return false }
        }
        return true
    }

    /// Solves `B·x = rhs` in place.
    func solve(_ rhs: inout [Double]) {
        guard n > 0 else { return }
        rhs.withUnsafeMutableBufferPointer { bp in
            SparseSolve(forward, DenseVector_Double(count: Int32(bp.count), data: bp.baseAddress!))
        }
    }

    /// Solves `Bᵀ·x = rhs` in place.
    func solveTranspose(_ rhs: inout [Double]) {
        guard n > 0 else { return }
        rhs.withUnsafeMutableBufferPointer { bp in
            SparseSolve(transposed, DenseVector_Double(count: Int32(bp.count), data: bp.baseAddress!))
        }
    }

    deinit {
        SparseCleanup(transposed)
        SparseCleanup(forward)
    }
}
