// Random-instance generators (specification §14.1, oracle 1) and a seeded generator.

import ZTronLPCore

/// SplitMix64: a small, fast generator whose stream depends only on the seed, so every test
/// that uses it is reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform in the range.
    public mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// Uniform integer in the range.
    public mutating func integer(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        uniform() < p
    }
}

/// An LP whose optimum is known by construction.
public struct ConstructedInstance: Sendable {
    public let lp: CompiledLP
    /// An optimal primal solution.
    public let primal: [Double]
    /// Optimal row duals, minimization form (`c − Aᵀy` is the reduced-cost vector).
    public let dual: [Double]
    /// The optimal objective, in the model's own sense.
    public let objective: Double
    public let seed: UInt64
}

/// The shapes of `InstanceGenerator.hilbert(order:form:integer:)`.
public enum HilbertForm: String, Sendable, CaseIterable {
    /// min cᵀx, H·x = b, x ≥ 0: one feasible point.
    case equality
    /// The same with free columns.
    case equalityFree
    /// min cᵀx, H·x ≥ b, x ≥ 0: every row active, every dual 1.
    case covering
    /// max cᵀx, H·x ≤ b, x ≥ 0.
    case packing
}

/// Options of the constructed-optimum generator.
public struct ConstructedOptions: Sendable {
    /// Fraction of stored entries per column, at least one entry per column and per row.
    public var density: Double = 0.2
    /// Make the optimal vertex primal degenerate: basic variables sitting on a bound.
    public var degenerate: Bool = false
    /// Include columns with no bounds.
    public var freeColumns: Bool = false
    /// Include rows bounded on both sides.
    public var rangeRows: Bool = false
    /// Emit a maximization model (the same problem, negated objective).
    public var maximize: Bool = false
    /// Spread the magnitudes of rows and columns over this many decades.
    public var scaleSpread: Double = 0

    public init() {}
}

public enum InstanceGenerator {
    /// Oracle 1: generate x*, y* with complementary slackness, derive the row bounds from Ax*
    /// and c = Aᵀy* + d. The optimum is then known exactly.
    ///
    /// In the minimization form with `d = c − Aᵀy`, optimality is: `d_j ≥ 0` for a column at
    /// its lower bound, `d_j ≤ 0` at its upper bound and `d_j = 0` strictly between; `y_i ≥ 0`
    /// for a row at its lower bound, `y_i ≤ 0` at its upper bound and `y_i = 0` strictly
    /// between (the dual of row i is the reduced cost of its logical column).
    public static func constructedOptimum(
        rows m: Int, columns n: Int, seed: UInt64, options: ConstructedOptions = .init()
    ) -> ConstructedInstance {
        var rng = SeededGenerator(seed: seed)

        // A: random sparse, every column and every row nonempty.
        var entries: [(row: Int, col: Int, value: Double)] = []
        var rowHasEntry = [Bool](repeating: false, count: m)
        func coefficient(_ rng: inout SeededGenerator) -> Double {
            let magnitude = rng.uniform(in: 0.5...4)
            return rng.chance(0.5) ? magnitude : -magnitude
        }
        for j in 0..<n {
            var any = false
            for i in 0..<m where rng.chance(options.density) {
                entries.append((i, j, coefficient(&rng)))
                rowHasEntry[i] = true
                any = true
            }
            if !any {
                let i = rng.integer(in: 0...(m - 1))
                entries.append((i, j, coefficient(&rng)))
                rowHasEntry[i] = true
            }
        }
        for i in 0..<m where !rowHasEntry[i] {
            entries.append((i, rng.integer(in: 0...(n - 1)), coefficient(&rng)))
        }
        if options.scaleSpread > 0 {
            let rowScale = (0..<m).map { _ in pow10(rng.uniform(in: -options.scaleSpread...options.scaleSpread)) }
            let colScale = (0..<n).map { _ in pow10(rng.uniform(in: -options.scaleSpread...options.scaleSpread)) }
            entries = entries.map { ($0.row, $0.col, $0.value * rowScale[$0.row] * colScale[$0.col]) }
        }
        let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)

        // Columns: bounds, the optimal value and the sign of the reduced cost.
        var xl = [Double](repeating: 0, count: n)
        var xu = [Double](repeating: .infinity, count: n)
        var x = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        for j in 0..<n {
            let kind = rng.uniform()
            if options.freeColumns && kind < 0.15 {
                // Free: any value, zero reduced cost.
                xl[j] = -.infinity
                xu[j] = .infinity
                x[j] = rng.uniform(in: -5...5)
                continue
            }
            let lower = rng.chance(0.7) ? 0 : rng.uniform(in: -4...4)
            let boxed = rng.chance(0.4)
            let upper = boxed ? lower + rng.uniform(in: 1...8) : Double.infinity
            xl[j] = lower
            xu[j] = upper
            let role = rng.uniform()
            if role < 0.45 {
                // Strictly inside (basic-like): zero reduced cost. A degenerate instance puts
                // some of these exactly on a bound, still with zero reduced cost.
                if options.degenerate && rng.chance(0.4) {
                    x[j] = lower
                } else {
                    x[j] = boxed ? lower + rng.uniform(in: 0.1...0.9) * (upper - lower) : lower + rng.uniform(in: 0.5...6)
                }
            } else if role < 0.8 || !boxed {
                x[j] = lower
                d[j] = rng.uniform(in: 0.2...3)
            } else {
                x[j] = upper
                d[j] = -rng.uniform(in: 0.2...3)
            }
        }

        // Rows: activity at x*, bounds around it and the sign of the dual.
        let activity = a.multiply(x)
        var rl = [Double](repeating: 0, count: m)
        var ru = [Double](repeating: 0, count: m)
        var y = [Double](repeating: 0, count: m)
        for i in 0..<m {
            let s = activity[i]
            let role = rng.uniform()
            let slack = rng.uniform(in: 0.5...5)
            let dual = rng.uniform(in: 0.2...3)
            let ranged = options.rangeRows && rng.chance(0.3)
            if role < 0.25 {
                // Equality: the dual has either sign.
                rl[i] = s
                ru[i] = s
                y[i] = rng.chance(0.5) ? dual : -dual
            } else if role < 0.5 {
                // Active at the lower bound: y ≥ 0.
                rl[i] = s
                ru[i] = ranged ? s + slack : .infinity
                y[i] = options.degenerate && rng.chance(0.3) ? 0 : dual
            } else if role < 0.75 {
                // Active at the upper bound: y ≤ 0.
                ru[i] = s
                rl[i] = ranged ? s - slack : -.infinity
                y[i] = options.degenerate && rng.chance(0.3) ? 0 : -dual
            } else {
                // Inactive: y = 0.
                if rng.chance(0.5) {
                    rl[i] = s - slack
                    ru[i] = ranged ? s + slack : .infinity
                } else {
                    ru[i] = s + slack
                    rl[i] = ranged ? s - slack : -.infinity
                }
            }
        }

        // c = Aᵀy + d makes (x, y) a primal-dual optimal pair.
        var c = a.multiplyTranspose(y)
        for j in 0..<n { c[j] += d[j] }
        var objective = 0.0
        for j in 0..<n { objective += c[j] * x[j] }

        let lp: CompiledLP
        if options.maximize {
            // The model "maximize −cᵀx" is stored as "minimize cᵀx"; its reported optimum is −cᵀx*.
            lp = CompiledLP(a: a, c: c, c0: 0, sense: .maximize, xl: xl, xu: xu, rl: rl, ru: ru)
            objective = -objective
        } else {
            lp = CompiledLP(a: a, c: c, c0: 0, sense: .minimize, xl: xl, xu: xu, rl: rl, ru: ru)
        }
        return ConstructedInstance(lp: lp, primal: x, dual: y, objective: objective, seed: seed)
    }

    /// The oracle-1 mix of §14.1: about 10% degenerate, 10% with free columns and 10% with
    /// range rows, sizes drawn between `minSize` and `maxSize`.
    public static func constructedSuite(
        count: Int, seed: UInt64, minSize: (rows: Int, columns: Int) = (5, 5),
        maxSize: (rows: Int, columns: Int) = (60, 120)
    ) -> [ConstructedInstance] {
        var rng = SeededGenerator(seed: seed)
        var result: [ConstructedInstance] = []
        result.reserveCapacity(count)
        for k in 0..<count {
            let m = rng.integer(in: minSize.rows...maxSize.rows)
            let n = rng.integer(in: Swift.max(minSize.columns, m / 2)...maxSize.columns)
            var options = ConstructedOptions()
            options.density = Swift.max(0.02, Swift.min(0.5, 6.0 / Double(m)))
            switch k % 10 {
            case 3: options.degenerate = true
            case 5: options.freeColumns = true
            case 7: options.rangeRows = true
            case 9: options.maximize = true
            default: break
            }
            result.append(constructedOptimum(rows: m, columns: n, seed: rng.next(), options: options))
        }
        return result
    }

    /// A random transportation problem: `sources × sinks` shipping columns, one supply row per
    /// source and one demand row per sink, total supply slightly above total demand so the
    /// problem is feasible and bounded.
    public static func transport(sources: Int, sinks: Int, seed: UInt64) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        let n = sources * sinks
        let m = sources + sinks
        var entries: [(row: Int, col: Int, value: Double)] = []
        entries.reserveCapacity(2 * n)
        var c = [Double](repeating: 0, count: n)
        for s in 0..<sources {
            for t in 0..<sinks {
                let j = s * sinks + t
                entries.append((s, j, 1))
                entries.append((sources + t, j, 1))
                c[j] = (rng.uniform(in: 1...100)).rounded()
            }
        }
        let demand = (0..<sinks).map { _ in (rng.uniform(in: 5...50)).rounded() }
        let totalDemand = demand.reduce(0, +)
        var supply = (0..<sources).map { _ in rng.uniform(in: 1...2) }
        let weight = supply.reduce(0, +)
        supply = supply.map { ($0 / weight * totalDemand * 1.2).rounded(.up) }
        var rl = [Double](repeating: -.infinity, count: m)
        var ru = [Double](repeating: .infinity, count: m)
        for s in 0..<sources { ru[s] = supply[s] }
        for t in 0..<sinks { rl[sources + t] = demand[t] }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: c,
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n), rl: rl, ru: ru)
    }

    /// An LP on the n × n Hilbert matrix H, h_ij = 1/(i + j − 1), whose only optimum is
    /// x = (1, …, 1), with the objective c = Hᵀ·1 and the right-hand side b = H·1.
    ///
    /// The Hilbert matrix is the textbook ill-conditioned matrix: its condition number grows
    /// like e^(3.5·n) — 1.5e7 at n = 6, 1.5e10 at n = 8, 1.6e13 at n = 10 — so these
    /// problems test what an engine does when feasibility and optimality within the usual
    /// tolerances no longer pin the solution down. Up to n = 8 a solve in double precision
    /// can recover x to about 1e-6; beyond that it cannot, and the most an engine can do is
    /// say so.
    public static func hilbert(order n: Int, form: HilbertForm, integer: Bool = false) -> ConstructedInstance {
        var entries: [(row: Int, col: Int, value: Double)] = []
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n {
                let value = 1 / Double(i + j + 1)
                entries.append((i, j, value))
                b[i] += value
                c[j] += value
            }
        }
        let a = SparseCSC.fromTriplets(rows: n, cols: n, entries)
        let zero = [Double](repeating: 0, count: n)
        let infinite = [Double](repeating: .infinity, count: n)
        let unbounded = [Double](repeating: -.infinity, count: n)
        let integerColumns: [Int32] = integer ? (0..<n).map { Int32($0) } : []
        let upper = integer ? [Double](repeating: 10, count: n) : infinite
        let lp: CompiledLP
        var dual = [Double](repeating: 1, count: n)
        switch form {
        case .equality:
            lp = CompiledLP(a: a, c: c, xl: zero, xu: upper, rl: b, ru: b, integerColumns: integerColumns)
        case .equalityFree:
            lp = CompiledLP(
                a: a, c: c, xl: integer ? zero : unbounded, xu: upper, rl: b, ru: b, integerColumns: integerColumns)
        case .covering:
            lp = CompiledLP(a: a, c: c, xl: zero, xu: upper, rl: b, ru: infinite, integerColumns: integerColumns)
        case .packing:
            // maximize cᵀx subject to H·x ≤ b: the minimization form has costs −c and duals −1.
            lp = CompiledLP(
                a: a, c: c.map { -$0 }, sense: .maximize, xl: zero, xu: upper, rl: unbounded, ru: b,
                integerColumns: integerColumns)
            dual = [Double](repeating: -1, count: n)
        }
        var objective = 0.0
        for value in b { objective += value }
        return ConstructedInstance(
            lp: lp, primal: [Double](repeating: 1, count: n), dual: dual, objective: objective, seed: UInt64(n))
    }

    /// A random bounded MILP: knapsack-style rows with nonnegative coefficients over integer
    /// columns in `[0, upper]`, optionally mixed with continuous columns. Maximization, always
    /// feasible (x = 0) and bounded.
    public static func randomMILP(
        rows m: Int, columns n: Int, seed: UInt64, integerFraction: Double = 1, upper: Int = 1,
        integralData: Bool = true
    ) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        var entries: [(row: Int, col: Int, value: Double)] = []
        var rowSum = [Double](repeating: 0, count: m)
        for j in 0..<n {
            var any = false
            for i in 0..<m where rng.chance(0.5) {
                let v = integralData ? Double(rng.integer(in: 1...20)) : rng.uniform(in: 1...20)
                entries.append((i, j, v))
                rowSum[i] += v * Double(upper)
                any = true
            }
            if !any {
                let i = rng.integer(in: 0...(m - 1))
                let v = integralData ? Double(rng.integer(in: 1...20)) : rng.uniform(in: 1...20)
                entries.append((i, j, v))
                rowSum[i] += v * Double(upper)
            }
        }
        let profit = (0..<n).map { _ in integralData ? Double(rng.integer(in: 1...30)) : rng.uniform(in: 1...30) }
        var integerColumns: [Int32] = []
        for j in 0..<n where rng.uniform() < integerFraction { integerColumns.append(Int32(j)) }
        let ru = rowSum.map { integralData ? ($0 * 0.4).rounded(.down) : $0 * 0.4 }
        // Maximize profit: stored as minimize −profit.
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: profit.map { -$0 }, sense: .maximize,
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: Double(upper), count: n),
            rl: [Double](repeating: -.infinity, count: m), ru: ru, integerColumns: integerColumns)
    }

    private static func pow10(_ exponent: Double) -> Double {
        var result = 1.0
        let whole = Int(exponent.rounded(.towardZero))
        if whole >= 0 {
            for _ in 0..<whole { result *= 10 }
        } else {
            for _ in 0..<(-whole) { result /= 10 }
        }
        return result
    }
}
