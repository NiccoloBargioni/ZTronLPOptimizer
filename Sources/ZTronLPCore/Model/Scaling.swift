// Scaling (specification §5.4).
//
// Scaling runs after presolve and is undone on every reported value: geometric-mean row/column
// scaling for up to 20 passes (stop when the max/min coefficient ratio improves by less than
// 10%), then equilibration so each row and column has ‖·‖∞ ≈ 1. All scale factors are rounded
// to powers of two, so scaling introduces no rounding error. Scaling applies to A, c, bounds
// and row ranges; integrality is unaffected because integer columns are given scale factor 1
// (a scaled integer column would break branching).

import Foundation

/// Computes and applies scale factors.
public enum Scaler {
    /// The scale factors `mode` assigns to `lp`.
    ///
    /// With `A' = diag(rows)·A·diag(columns)`, the scaled problem's variables are
    /// `x' = x / columns` and its row activities are `rows · (A·x)`.
    public static func factors(for lp: CompiledLP, mode: ScalingMode) -> Scaling {
        let m = lp.m
        let n = lp.n
        var rows = [Double](repeating: 1, count: m)
        var columns = [Double](repeating: 1, count: n)
        guard mode != .none, lp.nnz > 0 else { return Scaling(rows: rows, columns: columns) }
        let a = lp.a
        let isInteger = lp.integerMask()

        /// max |a_ij|·r_i·c_j / min |a_ij|·r_i·c_j over the stored entries.
        func ratio() -> Double {
            var largest = 0.0
            var smallest = Double.infinity
            for j in 0..<n {
                for p in a.colStart[j]..<a.colStart[j + 1] {
                    let v = Swift.abs(a.values[p]) * rows[Int(a.rowIndex[p])] * columns[j]
                    if v == 0 { continue }
                    if v > largest { largest = v }
                    if v < smallest { smallest = v }
                }
            }
            return smallest.isFinite && smallest > 0 ? largest / smallest : 1
        }

        if mode == .geometricEquilibration {
            var rowMin = [Double](repeating: 0, count: m)
            var rowMax = [Double](repeating: 0, count: m)
            var previous = ratio()
            for _ in 0..<20 {
                if previous <= 1 { break }
                let savedRows = rows
                let savedColumns = columns
                // Rows: r_i = 1 / sqrt(min_j |a_ij c_j| · max_j |a_ij c_j|).
                for i in 0..<m {
                    rowMin[i] = .infinity
                    rowMax[i] = 0
                }
                for j in 0..<n {
                    for p in a.colStart[j]..<a.colStart[j + 1] {
                        let v = Swift.abs(a.values[p]) * columns[j]
                        if v == 0 { continue }
                        let i = Int(a.rowIndex[p])
                        if v < rowMin[i] { rowMin[i] = v }
                        if v > rowMax[i] { rowMax[i] = v }
                    }
                }
                for i in 0..<m where rowMax[i] > 0 {
                    rows[i] = 1 / (rowMin[i] * rowMax[i]).squareRoot()
                }
                // Columns: c_j = 1 / sqrt(min_i |r_i a_ij| · max_i |r_i a_ij|); integer columns stay at 1.
                for j in 0..<n where !isInteger[j] {
                    var smallest = Double.infinity
                    var largest = 0.0
                    for p in a.colStart[j]..<a.colStart[j + 1] {
                        let v = Swift.abs(a.values[p]) * rows[Int(a.rowIndex[p])]
                        if v == 0 { continue }
                        if v < smallest { smallest = v }
                        if v > largest { largest = v }
                    }
                    if largest > 0 { columns[j] = 1 / (smallest * largest).squareRoot() }
                }
                let current = ratio()
                if current >= previous {
                    // The pass made things worse: undo it and stop.
                    rows = savedRows
                    columns = savedColumns
                    break
                }
                let improvement = (previous - current) / previous
                previous = current
                if improvement < 0.1 { break }
            }
        }

        // Equilibration: rows to ‖·‖∞ = 1, then columns.
        var rowMax = [Double](repeating: 0, count: m)
        for j in 0..<n {
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let i = Int(a.rowIndex[p])
                let v = Swift.abs(a.values[p]) * rows[i] * columns[j]
                if v > rowMax[i] { rowMax[i] = v }
            }
        }
        for i in 0..<m where rowMax[i] > 0 { rows[i] /= rowMax[i] }
        for j in 0..<n where !isInteger[j] {
            var largest = 0.0
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let v = Swift.abs(a.values[p]) * rows[Int(a.rowIndex[p])] * columns[j]
                if v > largest { largest = v }
            }
            if largest > 0 { columns[j] /= largest }
        }

        // Powers of two only: multiplying by them is exact.
        for i in 0..<m { rows[i] = powerOfTwo(nearest: rows[i]) }
        for j in 0..<n { columns[j] = isInteger[j] ? 1 : powerOfTwo(nearest: columns[j]) }
        return Scaling(rows: rows, columns: columns)
    }

    /// The power of two nearest to `value` on a logarithmic scale; 1 for unusable input.
    public static func powerOfTwo(nearest value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exponent = Foundation.log2(value).rounded()
        // Keep the factor well inside the representable range.
        let clamped = Swift.min(Swift.max(exponent, -500), 500)
        return Foundation.scalbn(1.0, Int(clamped))
    }

    /// Applies scale factors to a problem. The result carries them in `scaling`.
    ///
    /// If `lp` is itself a scaled problem the factors compose, so `scaling` always maps the
    /// result back to the unscaled problem.
    public static func apply(_ scaling: Scaling, to lp: CompiledLP) -> CompiledLP {
        precondition(scaling.rows.count == lp.m && scaling.columns.count == lp.n, "scale vectors do not fit the problem")
        let a = lp.a
        let r = scaling.rows
        let s = scaling.columns
        var values = a.values
        for j in 0..<lp.n {
            for p in a.colStart[j]..<a.colStart[j + 1] {
                values[p] = a.values[p] * r[Int(a.rowIndex[p])] * s[j]
            }
        }
        let scaledA = SparseCSC(rows: a.rows, cols: a.cols, colStart: a.colStart, rowIndex: a.rowIndex, values: values)
        var c = lp.c
        var xl = lp.xl
        var xu = lp.xu
        for j in 0..<lp.n {
            c[j] = lp.c[j] * s[j]
            xl[j] = lp.xl[j] / s[j]
            xu[j] = lp.xu[j] / s[j]
        }
        var rl = lp.rl
        var ru = lp.ru
        for i in 0..<lp.m {
            rl[i] = lp.rl[i] * r[i]
            ru[i] = lp.ru[i] * r[i]
        }
        let combined: Scaling
        if let previous = lp.scaling {
            combined = Scaling(
                rows: zip(previous.rows, r).map { $0 * $1 }, columns: zip(previous.columns, s).map { $0 * $1 })
        } else {
            combined = scaling
        }
        return CompiledLP(
            a: scaledA, c: c, c0: lp.c0, sense: lp.sense, xl: xl, xu: xu, rl: rl, ru: ru,
            integerColumns: lp.integerColumns, names: lp.names, scaling: combined)
    }

    /// Computes the factors for `mode` and applies them.
    public static func scale(_ lp: CompiledLP, mode: ScalingMode) -> CompiledLP {
        apply(factors(for: lp, mode: mode), to: lp)
    }
}

extension Scaling {
    /// `x = columns · x'`: scaled primal values back to the unscaled problem.
    public func unscalePrimal(_ x: [Double]) -> [Double] {
        var result = x
        for j in 0..<Swift.min(x.count, columns.count) { result[j] = x[j] * columns[j] }
        return result
    }

    /// `x' = x / columns`: unscaled primal values into the scaled problem.
    public func scalePrimal(_ x: [Double]) -> [Double] {
        var result = x
        for j in 0..<Swift.min(x.count, columns.count) { result[j] = x[j] / columns[j] }
        return result
    }

    /// `y = rows · y'`: scaled row duals back to the unscaled problem.
    public func unscaleDual(_ y: [Double]) -> [Double] {
        var result = y
        for i in 0..<Swift.min(y.count, rows.count) { result[i] = y[i] * rows[i] }
        return result
    }

    /// `d = d' / columns` for the structural entries and `d = rows · d'` for the logical ones
    /// (a logical reduced cost is the row's dual).
    public func unscaleReducedCosts(_ d: [Double]) -> [Double] {
        var result = d
        let n = columns.count
        for j in 0..<Swift.min(d.count, n) { result[j] = d[j] / columns[j] }
        if d.count > n {
            for i in 0..<Swift.min(d.count - n, rows.count) { result[n + i] = d[n + i] * rows[i] }
        }
        return result
    }

    /// Row activities `s = s' / rows` back to the unscaled problem.
    public func unscaleRowActivity(_ s: [Double]) -> [Double] {
        var result = s
        for i in 0..<Swift.min(s.count, rows.count) { result[i] = s[i] / rows[i] }
        return result
    }
}
