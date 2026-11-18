// Sparse storage (specification §5.1).

/// An immutable sparse matrix in compressed sparse column form.
///
/// Row indices are `Int32` because LAPACK and Accelerate's sparse solvers index with 32 bits;
/// `colStart` is `Int` because the number of nonzeros can exceed 2³¹ on macOS. The layout is
/// exactly Accelerate's `SparseMatrixStructure`, so the numerics layer can hand the buffers to
/// the sparse solvers without copying.
public struct SparseCSC: Sendable, Hashable {
    public let rows: Int32
    public let cols: Int32
    /// `cols + 1` entries; column `j` occupies `colStart[j] ..< colStart[j + 1]`.
    public let colStart: [Int]
    /// `nnz` entries, sorted within a column.
    public let rowIndex: [Int32]
    public let values: [Double]

    public init(rows: Int32, cols: Int32, colStart: [Int], rowIndex: [Int32], values: [Double]) {
        precondition(rows >= 0 && cols >= 0, "negative dimension")
        precondition(colStart.count == Int(cols) + 1, "colStart must have cols + 1 entries")
        precondition(rowIndex.count == values.count, "rowIndex and values differ in length")
        precondition(colStart.first == 0 && colStart.last == values.count, "colStart does not span the data")
        self.rows = rows
        self.cols = cols
        self.colStart = colStart
        self.rowIndex = rowIndex
        self.values = values
    }

    /// An empty `rows × cols` matrix.
    public init(rows: Int, cols: Int) {
        self.init(
            rows: Int32(rows), cols: Int32(cols), colStart: [Int](repeating: 0, count: cols + 1),
            rowIndex: [], values: [])
    }

    /// The number of stored entries.
    @inlinable public var nnz: Int { values.count }

    /// The storage range of column `j`.
    @inlinable
    public func range(ofColumn j: Int) -> Range<Int> {
        colStart[j]..<colStart[j + 1]
    }

    /// The number of stored entries in column `j`.
    @inlinable
    public func count(inColumn j: Int) -> Int {
        colStart[j + 1] - colStart[j]
    }

    /// The transpose, also in column-major form. Applied to `A` this yields the CSR view of
    /// `A`: column `i` of the result is row `i` of `A`, with ascending column indices.
    public func transposed() -> SparseCSC {
        let m = Int(rows)
        let n = Int(cols)
        var start = [Int](repeating: 0, count: m + 1)
        for r in rowIndex { start[Int(r) + 1] += 1 }
        for i in 0..<m { start[i + 1] += start[i] }
        var next = start
        var index = [Int32](repeating: 0, count: values.count)
        var data = [Double](repeating: 0, count: values.count)
        for j in 0..<n {
            for p in colStart[j]..<colStart[j + 1] {
                let i = Int(rowIndex[p])
                let q = next[i]
                next[i] += 1
                index[q] = Int32(j)
                data[q] = values[p]
            }
        }
        return SparseCSC(rows: cols, cols: rows, colStart: start, rowIndex: index, values: data)
    }

    /// Builds a matrix from coordinate entries. Duplicate positions are summed; exact zeros
    /// are kept out; rows are sorted within each column.
    public static func fromTriplets(
        rows: Int, cols: Int, _ entries: [(row: Int, col: Int, value: Double)]
    ) -> SparseCSC {
        var count = [Int](repeating: 0, count: cols + 1)
        for e in entries {
            precondition(e.row >= 0 && e.row < rows && e.col >= 0 && e.col < cols, "entry out of range")
            count[e.col + 1] += 1
        }
        for j in 0..<cols { count[j + 1] += count[j] }
        var next = count
        var rowBuffer = [Int32](repeating: 0, count: entries.count)
        var valueBuffer = [Double](repeating: 0, count: entries.count)
        for e in entries {
            let q = next[e.col]
            next[e.col] += 1
            rowBuffer[q] = Int32(e.row)
            valueBuffer[q] = e.value
        }
        var colStart = [Int](repeating: 0, count: cols + 1)
        var rowIndex: [Int32] = []
        var values: [Double] = []
        rowIndex.reserveCapacity(entries.count)
        values.reserveCapacity(entries.count)
        for j in 0..<cols {
            let lo = count[j]
            let hi = count[j + 1]
            // Sort this column's entries by row, stably, then merge duplicates.
            let order = (lo..<hi).sorted { rowBuffer[$0] < rowBuffer[$1] }
            var k = 0
            while k < order.count {
                let row = rowBuffer[order[k]]
                var total = 0.0
                while k < order.count && rowBuffer[order[k]] == row {
                    total += valueBuffer[order[k]]
                    k += 1
                }
                if total != 0 {
                    rowIndex.append(row)
                    values.append(total)
                }
            }
            colStart[j + 1] = values.count
        }
        return SparseCSC(
            rows: Int32(rows), cols: Int32(cols), colStart: colStart, rowIndex: rowIndex, values: values)
    }

    /// The entry at `(i, j)`; 0 when not stored. Binary search within the column.
    public subscript(i: Int, j: Int) -> Double {
        var lo = colStart[j]
        var hi = colStart[j + 1]
        let target = Int32(i)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if rowIndex[mid] < target {
                lo = mid + 1
            } else if rowIndex[mid] > target {
                hi = mid
            } else {
                return values[mid]
            }
        }
        return 0
    }

    /// `y = A·x`. A reference implementation for model-level code; the engines use the
    /// kernels of the numerics layer.
    public func multiply(_ x: [Double]) -> [Double] {
        precondition(x.count == Int(cols), "dimension mismatch")
        var y = [Double](repeating: 0, count: Int(rows))
        for j in 0..<Int(cols) {
            let xj = x[j]
            if xj == 0 { continue }
            for p in colStart[j]..<colStart[j + 1] {
                y[Int(rowIndex[p])] += values[p] * xj
            }
        }
        return y
    }

    /// `y = Aᵀ·x`.
    public func multiplyTranspose(_ x: [Double]) -> [Double] {
        precondition(x.count == Int(rows), "dimension mismatch")
        var y = [Double](repeating: 0, count: Int(cols))
        for j in 0..<Int(cols) {
            var total = 0.0
            for p in colStart[j]..<colStart[j + 1] {
                total += values[p] * x[Int(rowIndex[p])]
            }
            y[j] = total
        }
        return y
    }
}
