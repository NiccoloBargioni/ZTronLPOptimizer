// Dense vector kernels (specification §6.1).
//
// Every floating-point kernel lives in this target; engines never call Accelerate directly.
// BLAS and LAPACK go through CLAPACKShim (legacy interface, Int32 dimensions, deprecation
// diagnostics silenced there); vDSP is called here. Buffers are `[Double]` arrays accessed
// through `withUnsafe(Mutable)BufferPointer` for the duration of one kernel call; no pointer
// escapes a kernel.

import Accelerate
import CLAPACKShim

/// A dense vector is a plain array; copy-on-write keeps per-worker copies cheap until mutated.
public typealias DenseVector = [Double]

/// Level-1 kernels on dense vectors.
public enum Vec {
    // MARK: BLAS

    /// xᵀy (`cblas_ddot`).
    @inlinable
    public static func dot(_ x: [Double], _ y: [Double]) -> Double {
        precondition(x.count == y.count, "dimension mismatch")
        if x.isEmpty { return 0 }
        return x.withUnsafeBufferPointer { xp in
            y.withUnsafeBufferPointer { yp in
                ztlp_ddot(Int32(x.count), xp.baseAddress, 1, yp.baseAddress, 1)
            }
        }
    }

    /// y ← αx + y (`cblas_daxpy`).
    @inlinable
    public static func axpy(_ alpha: Double, _ x: [Double], into y: inout [Double]) {
        precondition(x.count == y.count, "dimension mismatch")
        if x.isEmpty || alpha == 0 { return }
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeMutableBufferPointer { yp in
                ztlp_daxpy(Int32(xp.count), alpha, xp.baseAddress, 1, yp.baseAddress, 1)
            }
        }
    }

    /// x ← αx (`cblas_dscal`).
    @inlinable
    public static func scale(_ alpha: Double, _ x: inout [Double]) {
        if x.isEmpty { return }
        x.withUnsafeMutableBufferPointer { xp in
            ztlp_dscal(Int32(xp.count), alpha, xp.baseAddress, 1)
        }
    }

    /// ‖x‖₂ (`cblas_dnrm2`).
    @inlinable
    public static func norm2(_ x: [Double]) -> Double {
        if x.isEmpty { return 0 }
        return x.withUnsafeBufferPointer { xp in ztlp_dnrm2(Int32(xp.count), xp.baseAddress, 1) }
    }

    // MARK: vDSP

    /// ‖x‖∞ (`vDSP_maxmgvD`).
    @inlinable
    public static func maxAbs(_ x: [Double]) -> Double {
        if x.isEmpty { return 0 }
        var result = 0.0
        x.withUnsafeBufferPointer { xp in
            vDSP_maxmgvD(xp.baseAddress!, 1, &result, vDSP_Length(xp.count))
        }
        return result
    }

    /// result ← a + b (`vDSP_vaddD`).
    @inlinable
    public static func add(_ a: [Double], _ b: [Double], into result: inout [Double]) {
        precondition(a.count == b.count && a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                result.withUnsafeMutableBufferPointer { rp in
                    vDSP_vaddD(ap.baseAddress!, 1, bp.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
                }
            }
        }
    }

    /// result ← a − b (`vDSP_vsubD`, whose operands are in the opposite order).
    @inlinable
    public static func subtract(_ a: [Double], _ b: [Double], into result: inout [Double]) {
        precondition(a.count == b.count && a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                result.withUnsafeMutableBufferPointer { rp in
                    // vDSP_vsubD computes C = B − A.
                    vDSP_vsubD(bp.baseAddress!, 1, ap.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
                }
            }
        }
    }

    /// result ← a ⊙ b, elementwise (`vDSP_vmulD`).
    @inlinable
    public static func multiply(_ a: [Double], _ b: [Double], into result: inout [Double]) {
        precondition(a.count == b.count && a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                result.withUnsafeMutableBufferPointer { rp in
                    vDSP_vmulD(ap.baseAddress!, 1, bp.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
                }
            }
        }
    }

    /// result ← a ⊘ b, elementwise (`vDSP_vdivD`, whose operands are in the opposite order).
    @inlinable
    public static func divide(_ a: [Double], _ b: [Double], into result: inout [Double]) {
        precondition(a.count == b.count && a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                result.withUnsafeMutableBufferPointer { rp in
                    // vDSP_vdivD computes C = B / A.
                    vDSP_vdivD(bp.baseAddress!, 1, ap.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
                }
            }
        }
    }

    /// result ← scalar·a + c (`vDSP_vsmaD`).
    @inlinable
    public static func scaledAdd(_ scalar: Double, _ a: [Double], plus c: [Double], into result: inout [Double]) {
        precondition(a.count == c.count && a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        var s = scalar
        a.withUnsafeBufferPointer { ap in
            c.withUnsafeBufferPointer { cp in
                result.withUnsafeMutableBufferPointer { rp in
                    vDSP_vsmaD(ap.baseAddress!, 1, &s, cp.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
                }
            }
        }
    }

    /// x ← x + scalar·a, in place (`vDSP_vsmaD`).
    @inlinable
    public static func addScaled(_ scalar: Double, _ a: [Double], to x: inout [Double]) {
        precondition(a.count == x.count, "dimension mismatch")
        if a.isEmpty || scalar == 0 { return }
        var s = scalar
        a.withUnsafeBufferPointer { ap in
            x.withUnsafeMutableBufferPointer { xp in
                vDSP_vsmaD(ap.baseAddress!, 1, &s, xp.baseAddress!, 1, xp.baseAddress!, 1, vDSP_Length(ap.count))
            }
        }
    }

    /// result ← min(max(a, low), high), elementwise (`vDSP_vclipD`).
    @inlinable
    public static func clip(_ a: [Double], low: Double, high: Double, into result: inout [Double]) {
        precondition(a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        var lo = low
        var hi = high
        a.withUnsafeBufferPointer { ap in
            result.withUnsafeMutableBufferPointer { rp in
                vDSP_vclipD(ap.baseAddress!, 1, &lo, &hi, rp.baseAddress!, 1, vDSP_Length(ap.count))
            }
        }
    }

    /// result ← |a|, elementwise (`vDSP_vabsD`).
    @inlinable
    public static func abs(_ a: [Double], into result: inout [Double]) {
        precondition(a.count == result.count, "dimension mismatch")
        if a.isEmpty { return }
        a.withUnsafeBufferPointer { ap in
            result.withUnsafeMutableBufferPointer { rp in
                vDSP_vabsD(ap.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(ap.count))
            }
        }
    }

    /// The smallest element (`vDSP_minvD`); +∞ for an empty vector.
    @inlinable
    public static func minimum(_ x: [Double]) -> Double {
        if x.isEmpty { return .infinity }
        var result = 0.0
        x.withUnsafeBufferPointer { xp in vDSP_minvD(xp.baseAddress!, 1, &result, vDSP_Length(xp.count)) }
        return result
    }

    /// The sum of the elements (`vDSP_sveD`).
    @inlinable
    public static func sum(_ x: [Double]) -> Double {
        if x.isEmpty { return 0 }
        var result = 0.0
        x.withUnsafeBufferPointer { xp in vDSP_sveD(xp.baseAddress!, 1, &result, vDSP_Length(xp.count)) }
        return result
    }

    /// Double → single precision (`vDSP_vdpsp`), for the fp32 GPU tier.
    @inlinable
    public static func toSingle(_ x: [Double]) -> [Float] {
        var result = [Float](repeating: 0, count: x.count)
        if x.isEmpty { return result }
        x.withUnsafeBufferPointer { xp in
            result.withUnsafeMutableBufferPointer { rp in
                vDSP_vdpsp(xp.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(xp.count))
            }
        }
        return result
    }

    /// Single → double precision (`vDSP_vspdp`).
    @inlinable
    public static func toDouble(_ x: [Float]) -> [Double] {
        var result = [Double](repeating: 0, count: x.count)
        if x.isEmpty { return result }
        x.withUnsafeBufferPointer { xp in
            result.withUnsafeMutableBufferPointer { rp in
                vDSP_vspdp(xp.baseAddress!, 1, rp.baseAddress!, 1, vDSP_Length(xp.count))
            }
        }
        return result
    }
}

/// A dense vector together with the list of its nonzero positions.
///
/// Sparse-vector results (FTRAN/BTRAN outputs, pivot rows) are returned as a dense array plus
/// a nonzero index list when the density is below 10%, so downstream loops iterate only the
/// nonzeros — the "hyper-sparse" path (§6.2).
public struct IndexedVector: Sendable {
    /// Dense values.
    public var values: [Double]
    /// Positions of the nonzeros; meaningful only while `isSparse` is true.
    public var indices: [Int32]
    /// True when `indices` lists every nonzero of `values`.
    public var isSparse: Bool

    /// The density below which the index list is kept.
    public static let sparseDensity = 0.10

    public init(count: Int) {
        values = [Double](repeating: 0, count: count)
        indices = []
        isSparse = true
    }

    @inlinable public var count: Int { values.count }

    /// Rebuilds the nonzero list from `values`, zeroing entries at or below `dropTolerance`.
    /// The list is kept only when the density is below 10%.
    public mutating func reindex(dropTolerance: Double = 0) {
        indices.removeAll(keepingCapacity: true)
        // The list is kept while the density is strictly below 10%.
        let threshold = Double(values.count) * Self.sparseDensity
        var nonzeros = 0
        for i in values.indices {
            let v = values[i]
            if v == 0 { continue }
            if Swift.abs(v) <= dropTolerance {
                values[i] = 0
                continue
            }
            nonzeros += 1
            if Double(nonzeros) < threshold { indices.append(Int32(i)) }
        }
        isSparse = Double(nonzeros) < threshold || nonzeros == 0
        if !isSparse { indices.removeAll(keepingCapacity: true) }
    }

    /// Sets every entry to zero, touching only the listed nonzeros when the list is valid.
    public mutating func clear() {
        if isSparse {
            for i in indices { values[Int(i)] = 0 }
        } else {
            for i in values.indices { values[i] = 0 }
        }
        indices.removeAll(keepingCapacity: true)
        isSparse = true
    }
}
