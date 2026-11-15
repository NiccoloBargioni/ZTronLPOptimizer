// Helpers shared by the ZTronLPNumerics suites.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

let inf = Double.infinity

/// A problem whose only interesting part is its matrix: `groups` structural columns per row,
/// each with a dominant entry in "its" row (column j belongs to row j mod m) plus random
/// off-diagonal entries. Picking, for every row, either one of its columns or its logical
/// column therefore gives a basis that is safely nonsingular.
func matrixLP(rows m: Int, groups: Int = 2, density: Double, seed: UInt64) -> CompiledLP {
    var rng = SeededGenerator(seed: seed)
    let n = m * groups
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<n {
        let home = j % m
        for i in 0..<m where i != home && rng.chance(density) {
            entries.append((i, j, rng.uniform(in: -1...1)))
        }
        let dominant = rng.uniform(in: 4...9)
        entries.append((home, j, rng.chance(0.5) ? dominant : -dominant))
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 0, count: n),
        xl: [Double](repeating: 0, count: n), xu: [Double](repeating: inf, count: n),
        rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
}

/// A basis of `matrixLP`: for each row, one of the row's structural columns with probability
/// `structural`, otherwise the row's logical column.
func mixedBasis(_ lp: CompiledLP, structural: Double, seed: UInt64) -> [Int32] {
    var rng = SeededGenerator(seed: seed)
    let groups = lp.n / lp.m
    return (0..<lp.m).map { row in
        rng.chance(structural) ? Int32(row + lp.m * rng.integer(in: 0...(groups - 1))) : Int32(lp.n + row)
    }
}

/// The dense basis matrix: the columns `basic` of [A −I].
func basisMatrix(_ basic: [Int32], _ lp: CompiledLP) -> DenseMatrix {
    var b = DenseMatrix(rows: lp.m, cols: lp.m)
    for (k, column) in basic.enumerated() {
        let j = Int(column)
        if j < lp.n {
            for p in lp.a.range(ofColumn: j) { b[Int(lp.a.rowIndex[p]), k] = lp.a.values[p] }
        } else {
            b[j - lp.n, k] = -1
        }
    }
    return b
}

/// Column `q` of [A −I] as a dense vector.
func logicalFormColumn(_ q: Int, _ lp: CompiledLP) -> [Double] {
    var column = [Double](repeating: 0, count: lp.m)
    if q < lp.n {
        lp.a.scatter(column: q, into: &column)
    } else {
        column[q - lp.n] = -1
    }
    return column
}

func randomVector(_ count: Int, _ rng: inout SeededGenerator, in range: ClosedRange<Double> = -1...1) -> [Double] {
    (0..<count).map { _ in rng.uniform(in: range) }
}

/// max |aᵢ − bᵢ|.
func maxDifference(_ a: [Double], _ b: [Double]) -> Double {
    precondition(a.count == b.count)
    var worst = 0.0
    for i in a.indices { worst = max(worst, abs(a[i] - b[i])) }
    return worst
}

/// ‖M·x − rhs‖∞ for a dense matrix.
func residual(_ matrix: DenseMatrix, _ x: [Double], _ rhs: [Double]) -> Double {
    maxDifference(matrix.multiply(x), rhs)
}

/// A dense matrix with entries uniform in [−1, 1].
func randomDense(rows: Int, cols: Int, _ rng: inout SeededGenerator) -> DenseMatrix {
    var matrix = DenseMatrix(rows: rows, cols: cols)
    for k in matrix.storage.indices { matrix.storage[k] = rng.uniform(in: -1...1) }
    return matrix
}

/// Counts how many bodies run at the same time: the measurement rule C7 asks for.
actor ConcurrencyMeter {
    private var running = 0
    private(set) var peak = 0
    private(set) var entries = 0

    func enter() {
        running += 1
        entries += 1
        if running > peak { peak = running }
    }

    func leave() {
        running -= 1
    }
}

/// Burns CPU for roughly `nanoseconds` without suspending.
func spin(nanoseconds: UInt64) {
    let start = Deadline.now
    var x = 1.0
    while Deadline.now &- start < nanoseconds {
        for _ in 0..<64 { x = (x * 1.000001).squareRoot() + 0.5 }
    }
    precondition(x.isFinite)
}
