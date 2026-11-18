// Dense containers and LAPACK wrappers (specification §6.1, §6.2).
//
// All LAPACK routines are column-major with Int32 dimensions and go through CLAPACKShim.

import CLAPACKShim
import ZTronLPCore

/// A numerical failure inside a kernel or a factorization.
public enum NumericalError: Error, Sendable, Hashable {
    /// The basis matrix is singular.
    ///
    /// `positions[k]` is a deficient basis position and `rows[k]` the row that the logical
    /// column replacing it should cover. Both lists are empty when the factorization can only
    /// tell that the matrix is singular, not where.
    case singular(positions: [Int32], rows: [Int32])
    /// The matrix is not numerically positive definite (Cholesky); the value is the order of
    /// the offending leading minor when known.
    case notPositiveDefinite(Int)
    /// A product-form update was refused because its pivot is too small.
    case unstableUpdate(pivot: Double)
    /// Anything else, with the routine's own words.
    case factorizationFailed(String)
}

/// A dense matrix in column-major order. A value type; copy-on-write keeps per-worker copies
/// cheap until mutated.
public struct DenseMatrix: Sendable, Hashable {
    public let rows: Int
    public let cols: Int
    /// `rows × cols` values, column by column.
    public var storage: [Double]

    public init(rows: Int, cols: Int) {
        precondition(rows >= 0 && cols >= 0, "negative dimension")
        self.rows = rows
        self.cols = cols
        storage = [Double](repeating: 0, count: rows * cols)
    }

    public init(rows: Int, cols: Int, storage: [Double]) {
        precondition(storage.count == rows * cols, "storage does not match the dimensions")
        self.rows = rows
        self.cols = cols
        self.storage = storage
    }

    /// The n × n identity.
    public static func identity(_ n: Int) -> DenseMatrix {
        var result = DenseMatrix(rows: n, cols: n)
        for i in 0..<n { result.storage[i * n + i] = 1 }
        return result
    }

    @inlinable
    public subscript(i: Int, j: Int) -> Double {
        get { storage[j * rows + i] }
        set { storage[j * rows + i] = newValue }
    }

    /// The dense form of a sparse matrix.
    public init(_ sparse: SparseCSC) {
        self.init(rows: Int(sparse.rows), cols: Int(sparse.cols))
        for j in 0..<cols {
            for p in sparse.colStart[j]..<sparse.colStart[j + 1] {
                storage[j * rows + Int(sparse.rowIndex[p])] = sparse.values[p]
            }
        }
    }

    /// `A·x` (`cblas_dgemv`).
    public func multiply(_ x: [Double]) -> [Double] {
        precondition(x.count == cols, "dimension mismatch")
        var y = [Double](repeating: 0, count: rows)
        if rows == 0 || cols == 0 { return y }
        storage.withUnsafeBufferPointer { ap in
            x.withUnsafeBufferPointer { xp in
                y.withUnsafeMutableBufferPointer { yp in
                    ztlp_dgemv(0, Int32(rows), Int32(cols), 1, ap.baseAddress, Int32(rows), xp.baseAddress, 1, 0, yp.baseAddress, 1)
                }
            }
        }
        return y
    }

    /// `Aᵀ·x` (`cblas_dgemv`).
    public func multiplyTranspose(_ x: [Double]) -> [Double] {
        precondition(x.count == rows, "dimension mismatch")
        var y = [Double](repeating: 0, count: cols)
        if rows == 0 || cols == 0 { return y }
        storage.withUnsafeBufferPointer { ap in
            x.withUnsafeBufferPointer { xp in
                y.withUnsafeMutableBufferPointer { yp in
                    ztlp_dgemv(1, Int32(rows), Int32(cols), 1, ap.baseAddress, Int32(rows), xp.baseAddress, 1, 0, yp.baseAddress, 1)
                }
            }
        }
        return y
    }

    /// `A·B` (`cblas_dgemm`).
    public func multiplied(by other: DenseMatrix) -> DenseMatrix {
        precondition(cols == other.rows, "dimension mismatch")
        var result = DenseMatrix(rows: rows, cols: other.cols)
        if rows == 0 || cols == 0 || other.cols == 0 { return result }
        storage.withUnsafeBufferPointer { ap in
            other.storage.withUnsafeBufferPointer { bp in
                result.storage.withUnsafeMutableBufferPointer { cp in
                    ztlp_dgemm(0, 0, Int32(rows), Int32(other.cols), Int32(cols), 1, ap.baseAddress, Int32(rows), bp.baseAddress, Int32(other.rows), 0, cp.baseAddress, Int32(rows))
                }
            }
        }
        return result
    }

    /// The lower triangle of `A·diag(d)·Aᵀ` (`cblas_dsyrk` on the scaled matrix); the upper
    /// triangle of the result is left at zero.
    public func weightedGram(_ d: [Double]) -> DenseMatrix {
        precondition(d.count == cols, "dimension mismatch")
        var scaled = storage
        for j in 0..<cols {
            let w = d[j] > 0 ? d[j].squareRoot() : 0
            for i in 0..<rows { scaled[j * rows + i] *= w }
        }
        var result = DenseMatrix(rows: rows, cols: rows)
        if rows == 0 || cols == 0 { return result }
        scaled.withUnsafeBufferPointer { ap in
            result.storage.withUnsafeMutableBufferPointer { cp in
                ztlp_dsyrk(0, 0, Int32(rows), Int32(cols), 1, ap.baseAddress, Int32(rows), 0, cp.baseAddress, Int32(rows))
            }
        }
        return result
    }

    /// ‖A‖₁, the largest absolute column sum (`dlange`).
    public func oneNorm() -> Double {
        if rows == 0 || cols == 0 { return 0 }
        return storage.withUnsafeBufferPointer { ap in
            ztlp_dlange_one(Int32(rows), Int32(cols), ap.baseAddress, Int32(rows))
        }
    }

    /// The transpose.
    public func transposed() -> DenseMatrix {
        var result = DenseMatrix(rows: cols, cols: rows)
        for j in 0..<cols {
            for i in 0..<rows { result.storage[i * cols + j] = storage[j * rows + i] }
        }
        return result
    }
}

/// LU factors with partial pivoting of a square dense matrix (`dgetrf`).
public struct DenseLU: Sendable {
    public let n: Int
    /// L and U packed as `dgetrf` leaves them.
    public private(set) var factors: [Double]
    /// One-based pivot rows.
    public private(set) var pivots: [Int32]
    /// ‖A‖₁ of the factored matrix, kept for the condition estimate.
    public let oneNorm: Double
    /// The smallest and largest |U_kk|.
    public let smallestPivot: Double
    public let largestPivot: Double

    /// Factors `matrix`. An exactly singular matrix throws `.singular` with the deficient
    /// positions; a merely ill-conditioned one factors, and `deficientPivots` lists what a
    /// caller with a tolerance may want to treat as singular.
    public init(_ matrix: DenseMatrix) throws(NumericalError) {
        precondition(matrix.rows == matrix.cols, "LU needs a square matrix")
        let n = matrix.rows
        self.n = n
        oneNorm = matrix.oneNorm()
        var a = matrix.storage
        var ipiv = [Int32](repeating: 0, count: n)
        var info: Int32 = 0
        if n > 0 {
            info = a.withUnsafeMutableBufferPointer { ap in
                ipiv.withUnsafeMutableBufferPointer { pp in
                    ztlp_dgetrf(Int32(n), Int32(n), ap.baseAddress, Int32(n), pp.baseAddress)
                }
            }
        }
        if info < 0 { throw .factorizationFailed("dgetrf: illegal argument \(-info)") }
        factors = a
        pivots = ipiv
        var smallest = Double.infinity
        var largest = 0.0
        for k in 0..<n {
            let u = Swift.abs(a[k * n + k])
            if u < smallest { smallest = u }
            if u > largest { largest = u }
        }
        smallestPivot = n == 0 ? 1 : smallest
        largestPivot = n == 0 ? 1 : largest
        if info > 0 {
            let (positions, rows) = deficientPivots(relativeTolerance: 0)
            throw .singular(positions: positions, rows: rows)
        }
    }

    /// Positions k whose pivot |U_kk| is at most `relativeTolerance · max|U|` (exact zeros
    /// always count), each with the original row that elimination left at that position —
    /// the row a replacement logical column should cover.
    public func deficientPivots(relativeTolerance: Double) -> (positions: [Int32], rows: [Int32]) {
        // Row k of the permuted matrix is original row `permutation[k]`.
        var permutation = [Int32](repeating: 0, count: n)
        for i in 0..<n { permutation[i] = Int32(i) }
        for i in 0..<n {
            let swap = Int(pivots[i]) - 1
            if swap != i, swap >= 0, swap < n { permutation.swapAt(i, swap) }
        }
        let threshold = relativeTolerance * largestPivot
        var positions: [Int32] = []
        var rows: [Int32] = []
        for k in 0..<n {
            let u = Swift.abs(factors[k * n + k])
            if u == 0 || u <= threshold {
                positions.append(Int32(k))
                rows.append(permutation[k])
            }
        }
        return (positions, rows)
    }

    /// Solves `A·x = rhs` (or `Aᵀ·x = rhs`) in place.
    ///
    /// A dense right-hand side goes to `dgetrs`. The simplex solves mostly sparse ones — a
    /// column of A for FTRAN, a unit vector for BTRAN — and a triangular solve does nothing
    /// for the leading zeros of its right-hand side, so when the first nonzero is not at the
    /// top the first triangular solve runs on the trailing block only (`cblas_dtrsv`). At
    /// m = 2,000 the factors are 32 MB and a solve is bound by memory bandwidth, so skipping
    /// part of them is a direct saving.
    public func solve(_ rhs: inout [Double], transpose: Bool = false) {
        precondition(rhs.count == n, "dimension mismatch")
        if n == 0 { return }
        let size = n
        factors.withUnsafeBufferPointer { ap in
            pivots.withUnsafeBufferPointer { pp in
                rhs.withUnsafeMutableBufferPointer { bp in
                    let a = ap.baseAddress!
                    let b = bp.baseAddress!
                    if !transpose {
                        // P: the row interchanges, in order.
                        for i in 0..<size {
                            let k = Int(pp[i]) - 1
                            if k != i { bp.swapAt(i, k) }
                        }
                        var first = 0
                        while first < size && bp[first] == 0 { first += 1 }
                        if first == size { return }          // the zero vector
                        if first == 0 {
                            // Dense: undo the interchanges and let LAPACK do the whole solve.
                            var i = size - 1
                            while i >= 0 {
                                let k = Int(pp[i]) - 1
                                if k != i { bp.swapAt(i, k) }
                                i -= 1
                            }
                            _ = ztlp_dgetrs(0, Int32(size), 1, a, Int32(size), pp.baseAddress, b, Int32(size))
                            return
                        }
                        // L·y = P·b on the trailing block, then U·x = y.
                        ztlp_dtrsv(0, 0, 1, Int32(size - first), a + first * size + first, Int32(size), b + first, 1)
                        ztlp_dtrsv(1, 0, 0, Int32(size), a, Int32(size), b, 1)
                    } else {
                        var first = 0
                        while first < size && bp[first] == 0 { first += 1 }
                        if first == size { return }
                        if first == 0 {
                            _ = ztlp_dgetrs(1, Int32(size), 1, a, Int32(size), pp.baseAddress, b, Int32(size))
                            return
                        }
                        // Uᵀ·z = b on the trailing block, then Lᵀ·w = z, then x = P·w.
                        ztlp_dtrsv(1, 1, 0, Int32(size - first), a + first * size + first, Int32(size), b + first, 1)
                        ztlp_dtrsv(0, 1, 1, Int32(size), a, Int32(size), b, 1)
                        var i = size - 1
                        while i >= 0 {
                            let k = Int(pp[i]) - 1
                            if k != i { bp.swapAt(i, k) }
                            i -= 1
                        }
                    }
                }
            }
        }
    }

    /// The reciprocal 1-norm condition number estimate (`dgecon`); `nil` when the routine fails.
    public func reciprocalCondition() -> Double? {
        if n == 0 { return 1 }
        var rcond = 0.0
        var work = [Double](repeating: 0, count: 4 * n)
        var iwork = [Int32](repeating: 0, count: n)
        let info = factors.withUnsafeBufferPointer { ap in
            work.withUnsafeMutableBufferPointer { wp in
                iwork.withUnsafeMutableBufferPointer { ip in
                    ztlp_dgecon(Int32(n), ap.baseAddress, Int32(n), oneNorm, &rcond, wp.baseAddress, ip.baseAddress)
                }
            }
        }
        return info == 0 ? rcond : nil
    }

    /// The 1-norm condition number estimate κ₁(A) ≈ 1 / rcond; +∞ for a singular matrix.
    public func conditionEstimate() -> Double? {
        guard let rcond = reciprocalCondition() else { return nil }
        return rcond > 0 ? 1 / rcond : .infinity
    }
}

/// Cholesky factor of a symmetric positive definite dense matrix (`dpotrf`), lower triangle.
public struct DenseCholesky: Sendable {
    public let n: Int
    public private(set) var factor: [Double]

    /// Factors the matrix whose lower triangle is stored in `matrix`. Throws
    /// `.notPositiveDefinite(k)` when the leading minor of order k is not positive definite.
    public init(lowerTriangleOf matrix: DenseMatrix) throws(NumericalError) {
        precondition(matrix.rows == matrix.cols, "Cholesky needs a square matrix")
        let n = matrix.rows
        self.n = n
        var a = matrix.storage
        var info: Int32 = 0
        if n > 0 {
            info = a.withUnsafeMutableBufferPointer { ap in
                ztlp_dpotrf(0, Int32(n), ap.baseAddress, Int32(n))
            }
        }
        if info > 0 { throw .notPositiveDefinite(Int(info)) }
        if info < 0 { throw .factorizationFailed("dpotrf: illegal argument \(-info)") }
        factor = a
    }

    /// Solves `A·x = rhs` in place (`dpotrs`).
    public func solve(_ rhs: inout [Double]) {
        precondition(rhs.count == n, "dimension mismatch")
        if n == 0 { return }
        factor.withUnsafeBufferPointer { ap in
            rhs.withUnsafeMutableBufferPointer { bp in
                _ = ztlp_dpotrs(0, Int32(n), 1, ap.baseAddress, Int32(n), bp.baseAddress, Int32(n))
            }
        }
    }
}

/// Householder QR of a dense matrix with at least as many rows as columns (`dgeqrf`); used
/// for rank checks in the crash basis.
public struct DenseQR: Sendable {
    public let rows: Int
    public let cols: Int
    public private(set) var factors: [Double]
    public private(set) var tau: [Double]

    public init(_ matrix: DenseMatrix) throws(NumericalError) {
        precondition(matrix.rows >= matrix.cols, "QR needs rows >= cols")
        let rows = matrix.rows
        let cols = matrix.cols
        self.rows = rows
        self.cols = cols
        var a = matrix.storage
        var t = [Double](repeating: 0, count: Swift.max(1, cols))
        var info: Int32 = 0
        if rows > 0 && cols > 0 {
            // Workspace query, then the factorization.
            var query = [0.0]
            info = a.withUnsafeMutableBufferPointer { ap in
                t.withUnsafeMutableBufferPointer { tp in
                    ztlp_dgeqrf(Int32(rows), Int32(cols), ap.baseAddress, Int32(rows), tp.baseAddress, &query, -1)
                }
            }
            if info == 0 {
                var work = [Double](repeating: 0, count: Swift.max(cols, Int(query[0])))
                info = a.withUnsafeMutableBufferPointer { ap in
                    t.withUnsafeMutableBufferPointer { tp in
                        work.withUnsafeMutableBufferPointer { wp in
                            ztlp_dgeqrf(Int32(rows), Int32(cols), ap.baseAddress, Int32(rows), tp.baseAddress, wp.baseAddress, Int32(wp.count))
                        }
                    }
                }
            }
        }
        if info != 0 { throw .factorizationFailed("dgeqrf: info \(info)") }
        factors = a
        tau = t
    }

    /// The number of diagonal entries of R larger than `relativeTolerance · max|R_kk|`.
    public func rank(relativeTolerance: Double = 1e-11) -> Int {
        var largest = 0.0
        for k in 0..<cols { largest = Swift.max(largest, Swift.abs(factors[k * rows + k])) }
        if largest == 0 { return 0 }
        var count = 0
        for k in 0..<cols where Swift.abs(factors[k * rows + k]) > relativeTolerance * largest { count += 1 }
        return count
    }

    /// The least-squares solution of `A·x ≈ rhs` (`dormqr` then `dtrtrs`); `nil` when R is
    /// exactly singular.
    public func solveLeastSquares(_ rhs: [Double]) -> [Double]? {
        precondition(rhs.count == rows, "dimension mismatch")
        if cols == 0 { return [] }
        var b = rhs
        var work = [Double](repeating: 0, count: Swift.max(1, 64 * cols))
        var info = factors.withUnsafeBufferPointer { ap in
            tau.withUnsafeBufferPointer { tp in
                b.withUnsafeMutableBufferPointer { bp in
                    work.withUnsafeMutableBufferPointer { wp in
                        ztlp_dormqr(1, 1, Int32(rows), 1, Int32(cols), ap.baseAddress, Int32(rows), tp.baseAddress, bp.baseAddress, Int32(rows), wp.baseAddress, Int32(wp.count))
                    }
                }
            }
        }
        guard info == 0 else { return nil }
        info = factors.withUnsafeBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                ztlp_dtrtrs(1, 0, 0, Int32(cols), 1, ap.baseAddress, Int32(rows), bp.baseAddress, Int32(rows))
            }
        }
        guard info == 0 else { return nil }
        return Array(b[0..<cols])
    }
}

/// Reference dense solve (`dgesv`): factors a copy of `matrix` and solves `A·x = rhs`.
/// Returns `nil` for a singular matrix. The tests check the basis factorizations against it.
public func denseSolve(_ matrix: DenseMatrix, _ rhs: [Double]) -> [Double]? {
    precondition(matrix.rows == matrix.cols && rhs.count == matrix.rows, "dimension mismatch")
    let n = matrix.rows
    if n == 0 { return [] }
    var a = matrix.storage
    var b = rhs
    var ipiv = [Int32](repeating: 0, count: n)
    let info = a.withUnsafeMutableBufferPointer { ap in
        ipiv.withUnsafeMutableBufferPointer { pp in
            b.withUnsafeMutableBufferPointer { bp in
                ztlp_dgesv(Int32(n), 1, ap.baseAddress, Int32(n), pp.baseAddress, bp.baseAddress, Int32(n))
            }
        }
    }
    return info == 0 ? b : nil
}

/// Solves `op(T)·x = rhs` in place for a dense triangular matrix (`cblas_dtrsv`).
public func triangularSolve(_ matrix: DenseMatrix, _ rhs: inout [Double], upper: Bool, transpose: Bool = false, unitDiagonal: Bool = false) {
    precondition(matrix.rows == matrix.cols && rhs.count == matrix.rows, "dimension mismatch")
    if matrix.rows == 0 { return }
    matrix.storage.withUnsafeBufferPointer { ap in
        rhs.withUnsafeMutableBufferPointer { bp in
            ztlp_dtrsv(upper ? 1 : 0, transpose ? 1 : 0, unitDiagonal ? 1 : 0, Int32(matrix.rows), ap.baseAddress, Int32(matrix.rows), bp.baseAddress, 1)
        }
    }
}
