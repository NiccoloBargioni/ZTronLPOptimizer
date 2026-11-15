// Basis factorization strategies (specification §6.3).
//
// There is no sparse LU in Accelerate, and a Markowitz LU with Forrest–Tomlin updates is more
// than a week's work on its own. The simplex engine therefore factors the basis through a
// protocol with two concrete strategies and a product-form (eta) update between
// refactorizations. Both strategies apply the eta file as a sequence of rank-one pivots:
// `ftran` applies etas after the base solve and `btran` before it.

import ZTronLPCore

/// A factorization of the simplex basis matrix B, the columns `basic` of `[A −I]`.
public protocol BasisFactorization: Sendable {
    /// Factor B = columns `basic` of [A −I]; `basic.count == m`.
    mutating func refactor(basic: [Int32], lp: CompiledLP) throws(NumericalError)
    /// Solves B·x = rhs in place.
    func ftran(_ rhs: inout [Double])
    /// Solves Bᵀ·x = rhs in place.
    func btran(_ rhs: inout [Double])
    /// Record the pivot (entering column already transformed by ftran, leaving position r).
    mutating func update(alpha: [Double], leaving r: Int) throws(NumericalError)
    var updatesSinceRefactor: Int { get }
    /// Eta nnz, update count or growth threshold hit.
    var needsRefactor: Bool { get }
    /// 1-norm estimate; DenseLU only.
    func conditionEstimate() -> Double?
}

/// The product-form update file shared by both strategies.
///
/// A pivot that brings the ftran'd column α into basis position r turns B into B·E, where E
/// is the identity with column r replaced by α. Each eta stores α sparsely.
struct EtaFile: Sendable {
    private(set) var pivotPosition: [Int32] = []
    private(set) var pivotValue: [Double] = []
    /// Offsets into `index` / `value`; one more entry than there are etas.
    private(set) var start: [Int] = [0]
    private(set) var index: [Int32] = []
    private(set) var value: [Double] = []
    /// The largest |α_i / α_r| any update has produced: a growth indicator.
    private(set) var growth: Double = 0

    var count: Int { pivotPosition.count }
    var nnz: Int { value.count }

    mutating func removeAll() {
        pivotPosition.removeAll(keepingCapacity: true)
        pivotValue.removeAll(keepingCapacity: true)
        start.removeAll(keepingCapacity: true)
        start.append(0)
        index.removeAll(keepingCapacity: true)
        value.removeAll(keepingCapacity: true)
        growth = 0
    }

    /// Appends the eta for α entering at position r; entries at or below `dropTolerance` are dropped.
    mutating func append(alpha: [Double], r: Int, dropTolerance: Double) {
        let pivot = alpha[r]
        var largest = 0.0
        for i in alpha.indices where i != r {
            let a = alpha[i]
            if a == 0 { continue }
            let magnitude = Swift.abs(a)
            if magnitude <= dropTolerance { continue }
            index.append(Int32(i))
            value.append(a)
            if magnitude > largest { largest = magnitude }
        }
        pivotPosition.append(Int32(r))
        pivotValue.append(pivot)
        start.append(value.count)
        let ratio = largest / Swift.abs(pivot)
        if ratio > growth { growth = ratio }
    }

    /// x ← E_k⁻¹ … E_1⁻¹ x: the etas in order, after the base solve.
    func applyForward(_ x: inout [Double]) {
        if pivotPosition.isEmpty { return }
        x.withUnsafeMutableBufferPointer { xp in
            index.withUnsafeBufferPointer { ip in
                value.withUnsafeBufferPointer { vp in
                    for k in 0..<pivotPosition.count {
                        let r = Int(pivotPosition[k])
                        let xr = xp[r]
                        if xr == 0 { continue }
                        let t = xr / pivotValue[k]
                        xp[r] = t
                        for p in start[k]..<start[k + 1] {
                            xp[Int(ip[p])] -= vp[p] * t
                        }
                    }
                }
            }
        }
    }

    /// x ← E_1⁻ᵀ … E_k⁻ᵀ x: the etas in reverse order, before the base solve.
    func applyBackward(_ x: inout [Double]) {
        if pivotPosition.isEmpty { return }
        x.withUnsafeMutableBufferPointer { xp in
            index.withUnsafeBufferPointer { ip in
                value.withUnsafeBufferPointer { vp in
                    var k = pivotPosition.count - 1
                    while k >= 0 {
                        let r = Int(pivotPosition[k])
                        var s = xp[r]
                        for p in start[k]..<start[k + 1] {
                            s -= vp[p] * xp[Int(ip[p])]
                        }
                        xp[r] = s / pivotValue[k]
                        k -= 1
                    }
                }
            }
        }
    }
}

/// Dense LU with partial pivoting (`dgetrf` / `dgetrs`) plus an eta file.
///
/// Factor cost ⅔m³ flops, solve cost 2m² plus the etas. Refactor policy: every 100 updates,
/// when the eta file exceeds m² entries, when an update shows large growth, or when the
/// engine's residual check fails. Chosen when m ≤ 1,500.
public struct DenseLUBasis: BasisFactorization {
    /// Updates between refactorizations.
    public var refactorInterval: Int
    /// Entries below this are dropped from eta columns.
    public var dropTolerance: Double
    /// A pivot is treated as deficient when |U_kk| ≤ this · max|U|.
    public var singularityTolerance: Double

    private var m = 0
    private var lu: DenseLU?
    private var etas = EtaFile()

    public init(refactorInterval: Int = 100, dropTolerance: Double = 1e-14, singularityTolerance: Double = 1e-11) {
        self.refactorInterval = refactorInterval
        self.dropTolerance = dropTolerance
        self.singularityTolerance = singularityTolerance
    }

    public mutating func refactor(basic: [Int32], lp: CompiledLP) throws(NumericalError) {
        let m = lp.m
        precondition(basic.count == m, "the basis must have m columns")
        self.m = m
        etas.removeAll()
        // Release the old factors before assembling the new matrix: at m = 4,000 each is 128 MB.
        lu = nil
        var matrix = DenseMatrix(rows: m, cols: m)
        let n = lp.n
        let a = lp.a
        matrix.storage.withUnsafeMutableBufferPointer { bp in
            for (k, column) in basic.enumerated() {
                let j = Int(column)
                if j < n {
                    for p in a.colStart[j]..<a.colStart[j + 1] {
                        bp[k * m + Int(a.rowIndex[p])] = a.values[p]
                    }
                } else {
                    bp[k * m + (j - n)] = -1
                }
            }
        }
        let factors = try DenseLU(matrix)
        let deficient = factors.deficientPivots(relativeTolerance: singularityTolerance)
        if !deficient.positions.isEmpty {
            throw .singular(positions: deficient.positions, rows: deficient.rows)
        }
        lu = factors
    }

    public func ftran(_ rhs: inout [Double]) {
        guard let lu else { return }
        lu.solve(&rhs)
        etas.applyForward(&rhs)
    }

    public func btran(_ rhs: inout [Double]) {
        guard let lu else { return }
        etas.applyBackward(&rhs)
        lu.solve(&rhs, transpose: true)
    }

    public mutating func update(alpha: [Double], leaving r: Int) throws(NumericalError) {
        let pivot = alpha[r]
        guard pivot != 0, pivot.isFinite else { throw .unstableUpdate(pivot: pivot) }
        etas.append(alpha: alpha, r: r, dropTolerance: dropTolerance)
    }

    public var updatesSinceRefactor: Int { etas.count }

    public var needsRefactor: Bool {
        etas.count >= refactorInterval || etas.nnz > m * m || etas.growth > 1e7
    }

    /// κ₁ of the matrix factored at the last refactorization (`dgecon`).
    public func conditionEstimate() -> Double? {
        lu?.conditionEstimate()
    }
}

/// Accelerate sparse QR plus an eta file.
///
/// Factor cost depends on fill-in; a solve is two sparse triangular solves plus the etas.
/// Refactor policy: every 50 updates or when the engine's residual check fails. Chosen when
/// m > 1,500 or the basis density is below 2%.
///
/// A singular or numerically singular basis is rejected with `.singular` whose position lists
/// are empty: Accelerate's QR can tell that a basis is deficient (and only after the factors
/// are probed, see `SparseQRFactorization`), not which of its columns to replace.
public struct SparseQRBasis: BasisFactorization {
    /// Updates between refactorizations.
    public var refactorInterval: Int
    /// Entries below this are dropped from eta columns.
    public var dropTolerance: Double

    private var m = 0
    private var factorization: SparseQRFactorization?
    private var etas = EtaFile()

    public init(refactorInterval: Int = 50, dropTolerance: Double = 1e-14) {
        self.refactorInterval = refactorInterval
        self.dropTolerance = dropTolerance
    }

    public mutating func refactor(basic: [Int32], lp: CompiledLP) throws(NumericalError) {
        let m = lp.m
        precondition(basic.count == m, "the basis must have m columns")
        self.m = m
        etas.removeAll()
        factorization = nil
        // A problem with no rows has an empty basis: nothing to factor, every solve is a no-op.
        if m == 0 { return }
        let n = lp.n
        let a = lp.a
        var colStart = [Int](repeating: 0, count: m + 1)
        var rowIndex: [Int32] = []
        var values: [Double] = []
        for (k, column) in basic.enumerated() {
            let j = Int(column)
            if j < n {
                for p in a.colStart[j]..<a.colStart[j + 1] {
                    rowIndex.append(a.rowIndex[p])
                    values.append(a.values[p])
                }
            } else {
                rowIndex.append(Int32(j - n))
                values.append(-1)
            }
            colStart[k + 1] = values.count
        }
        factorization = try SparseQRFactorization(n: m, colStart: colStart, rowIndex: rowIndex, values: values)
    }

    public func ftran(_ rhs: inout [Double]) {
        guard let factorization else { return }
        factorization.solve(&rhs)
        etas.applyForward(&rhs)
    }

    public func btran(_ rhs: inout [Double]) {
        guard let factorization else { return }
        etas.applyBackward(&rhs)
        factorization.solveTranspose(&rhs)
    }

    public mutating func update(alpha: [Double], leaving r: Int) throws(NumericalError) {
        let pivot = alpha[r]
        guard pivot != 0, pivot.isFinite else { throw .unstableUpdate(pivot: pivot) }
        etas.append(alpha: alpha, r: r, dropTolerance: dropTolerance)
    }

    public var updatesSinceRefactor: Int { etas.count }

    public var needsRefactor: Bool {
        etas.count >= refactorInterval || etas.growth > 1e7
    }

    /// Not available: Accelerate's sparse QR exposes no condition estimate.
    public func conditionEstimate() -> Double? { nil }
}

/// The density of a basis: stored entries of the basic columns over m².
public func basisDensity(basic: [Int32], lp: CompiledLP) -> Double {
    guard lp.m > 0 else { return 0 }
    var entries = 0
    for column in basic {
        let j = Int(column)
        entries += j < lp.n ? lp.a.colStart[j + 1] - lp.a.colStart[j] : 1
    }
    return Double(entries) / (Double(lp.m) * Double(lp.m))
}
