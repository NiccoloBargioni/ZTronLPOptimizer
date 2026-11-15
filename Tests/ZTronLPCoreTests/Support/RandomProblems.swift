// Random problems that exercise every representable shape of row and column, for the
// reader/writer round trips and the scaling tests.

import ZTronLPCore
import ZTronLPTestSupport

enum RandomProblems {
    /// A problem with every kind of row (≤, ≥, =, range) and column (default, free, fixed,
    /// boxed, lower-only, upper-only incl. negative upper, integer with several bound shapes),
    /// an objective constant and either sense. Values are "ugly" doubles on purpose, so a
    /// round trip only succeeds with exact number formatting.
    static func everyShape(rows m: Int, columns n: Int, seed: UInt64, freeRows: Bool = false) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        func ugly(_ range: ClosedRange<Double>) -> Double {
            rng.chance(0.25) ? (rng.uniform(in: range)).rounded() : rng.uniform(in: range)
        }
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<n {
            // A few columns stay empty on purpose.
            if rng.chance(0.08) { continue }
            for i in 0..<m where rng.chance(0.35) {
                var value = ugly(-9...9)
                if value == 0 { value = 1 }
                entries.append((i, j, value))
            }
        }
        let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)

        var xl = [Double](repeating: 0, count: n)
        var xu = [Double](repeating: .infinity, count: n)
        var integerColumns: [Int32] = []
        for j in 0..<n {
            switch rng.integer(in: 0...11) {
            case 0:                                   // free
                xl[j] = -.infinity
            case 1:                                   // fixed
                xl[j] = ugly(-5...5)
                xu[j] = xl[j]
            case 2:                                   // boxed
                xl[j] = ugly(-5...5)
                xu[j] = xl[j] + rng.uniform(in: 0.001...7)
            case 3:                                   // lower only, nonzero
                xl[j] = ugly(-5...5)
            case 4:                                   // upper only, positive
                xl[j] = -.infinity
                xu[j] = rng.uniform(in: 0.5...9)
            case 5:                                   // upper only, negative
                xl[j] = -.infinity
                xu[j] = -rng.uniform(in: 0.5...9)
            case 6:                                   // [0, u]
                xu[j] = rng.uniform(in: 0.5...9)
            case 7:                                   // binary
                xu[j] = 1
                integerColumns.append(Int32(j))
            case 8:                                   // integer, x ≥ 0
                integerColumns.append(Int32(j))
            case 9:                                   // integer, general box
                xl[j] = Double(rng.integer(in: -6...3))
                xu[j] = xl[j] + Double(rng.integer(in: 0...9))
                integerColumns.append(Int32(j))
            case 10:                                  // integer, free
                xl[j] = -.infinity
                integerColumns.append(Int32(j))
            default:                                  // the default x ≥ 0
                break
            }
        }

        var rl = [Double](repeating: 0, count: m)
        var ru = [Double](repeating: 0, count: m)
        for i in 0..<m {
            let b = ugly(-20...20)
            switch rng.integer(in: 0...(freeRows ? 5 : 4)) {
            case 0:
                rl[i] = -.infinity
                ru[i] = b
            case 1:
                rl[i] = b
                ru[i] = .infinity
            case 2:
                rl[i] = b
                ru[i] = b
            case 3, 4:                                // range rows, with awkward magnitudes too
                rl[i] = b
                ru[i] = b + (rng.chance(0.3) ? rng.uniform(in: 1e-6...1e-3) : rng.uniform(in: 0.01...1e4))
            default:
                rl[i] = -.infinity
                ru[i] = .infinity
            }
        }

        var c = [Double](repeating: 0, count: n)
        for j in 0..<n where rng.chance(0.7) { c[j] = ugly(-12...12) }
        let c0 = rng.chance(0.5) ? ugly(-30...30) : 0
        let sense: ObjectiveSense = rng.chance(0.5) ? .minimize : .maximize
        return CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integerColumns)
    }
}
