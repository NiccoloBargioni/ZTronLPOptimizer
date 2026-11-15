// Accepted models (specification §10.1).
//
// CP-SAT works on pure integer programs in exact Int64 arithmetic:
//
//   * every column is `.integer` or `.binary` with finite bounds; an integer column without
//     finite bounds is rejected with `SolverError.unsupported` (automatic bounding from the LP
//     relaxation is post-v1);
//   * coefficients, right-hand sides and the objective must be integral. Rational data is
//     scaled per row by the smallest power of 10 ≤ 1e6 that makes every coefficient integral
//     within 1e-9; otherwise the model is rejected;
//   * activity bounds of every row must fit in Int64 (checked with overflow-reporting
//     arithmetic at load); otherwise rejected. The check keeps two bits of headroom — the
//     activities must lie within ±2⁶¹ — so that slacks and the thresholds of explanations,
//     which are sums and differences of a few activities, cannot overflow either;
//   * rows over binaries of the form Σ ℓᵢ ≥ 1 are detected and stored as clauses, not linear rows.
//
// Loading turns a `CompiledLP` into a `CPModel`: a list of `Σ aᵢxᵢ ≤ rhs` constraints (a range
// or equality row contributes two), a list of clauses over bound literals, and the objective as
// one more `≤` row whose right-hand side the linear search tightens.

import ZTronLPCore

/// A bound literal: `[x ≥ value]` when `isLower`, `[x ≤ value]` otherwise.
///
/// This is the portable form of a literal — what clauses are made of when they travel between
/// workers or are recorded for a soundness check. Inside a worker a literal is an interned
/// integer (§10.2).
struct BoundLiteral: Sendable, Hashable {
    var variable: Int32
    var isLower: Bool
    var value: Int64

    /// `¬[x ≥ v] ≡ [x ≤ v − 1]` and `¬[x ≤ v] ≡ [x ≥ v + 1]`.
    var negated: BoundLiteral {
        isLower
            ? BoundLiteral(variable: variable, isLower: false, value: value - 1)
            : BoundLiteral(variable: variable, isLower: true, value: value + 1)
    }
}

/// The exact integer form of a pure integer program.
struct CPModel: Sendable {
    /// Structural columns.
    let variableCount: Int
    /// Root domains, rounded inward to integers.
    let lower: [Int64]
    let upper: [Int64]

    /// Constraint `c` is `Σ linCoef[t]·x[linVar[t]] ≤ linRHS[c]` for `t` in
    /// `linStart[c] ..< linStart[c + 1]`. The objective row, when there is one, is the last.
    let linStart: [Int32]
    let linVar: [Int32]
    let linCoef: [Int64]
    let linRHS: [Int64]
    /// The smallest activity of each constraint over the root domains.
    let linMinActivity: [Int64]
    /// max |a|·(ub − lb) over the terms of each constraint: when the slack is at least this,
    /// the constraint cannot tighten any bound.
    let linMaxTerm: [Int64]
    /// |a|·(ub − lb) of each term over the root domains. The terms of a constraint are stored
    /// in decreasing order of this value, so propagation can stop at the first term that is
    /// too small to be tightened by the current slack.
    let linTermMax: [Int64]
    /// The index of the objective row, or −1 for a pure feasibility problem.
    let objectiveRow: Int

    /// Occurrences with a positive coefficient: these raise a constraint's minimum activity
    /// when the variable's lower bound rises. `occPosStart` has `variableCount + 1` entries.
    let occPosStart: [Int32]
    let occPosRow: [Int32]
    let occPosCoef: [Int64]
    /// Occurrences with a negative coefficient: these raise the minimum activity when the
    /// variable's upper bound falls.
    let occNegStart: [Int32]
    let occNegRow: [Int32]
    let occNegCoef: [Int64]

    /// Problem clauses over bound literals (rows of the form Σ ℓᵢ ≥ 1 over binaries).
    let clauses: [[BoundLiteral]]
    /// Per row of the problem as given: whether a side of it became a linear constraint — as
    /// opposed to a clause, or nothing at all because it can never bind. These are the rows
    /// the LP propagator relaxes.
    let rowHasLinearSide: [Bool]

    /// The integer objective is `objectiveScale` times the minimization-form objective without
    /// its constant: `cᵀx + c₀ = Z / objectiveScale + objectiveConstant`. The scale is the
    /// power of 10 that made the costs integral, divided by their common divisor.
    let objectiveScale: Double
    let objectiveConstant: Double
    /// True for a maximization model; reported values are negated back.
    let maximize: Bool
    /// For each variable, whether the objective would rather have it at its upper bound.
    let objectivePrefersUpper: [Bool]

    /// Set when loading already proved the model infeasible; the string says why.
    let infeasibleReason: String?
    /// Approximate bytes this value holds; shared by every worker.
    let approximateBytes: Int

    var hasObjective: Bool { objectiveRow >= 0 }
    var constraintCount: Int { linRHS.count }

    /// Converts an integer objective value to the model's own sense.
    func reportedObjective(_ value: Int64) -> Double {
        let minimization = Double(value) / objectiveScale + objectiveConstant
        return maximize ? -minimization : minimization
    }

    // MARK: - Loading

    /// The largest scale the specification allows: 10⁶.
    private static let scaleCandidates: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

    /// How close to an integer a scaled value must be to count as that integer: 1e-9, or the
    /// floating-point resolution of the value when that is coarser (four units in the last
    /// place), so that noise in large data is not mistaken for a fraction.
    static func snapTolerance(_ value: Double) -> Double {
        Swift.max(1e-9, 4 * value.ulp)
    }

    /// The smallest power of 10 ≤ 1e6 that makes every value integral within 1e-9, or `nil`.
    static func integralScale(for values: some Sequence<Double>) -> Double? {
        let all = Array(values)
        for scale in scaleCandidates {
            var integral = true
            for v in all {
                let scaled = v * scale
                // Beyond 2⁵³ a Double has no fractional bits left to check, and the integer
                // would not survive the conversion to Int64 arithmetic with headroom anyway.
                guard Swift.abs(scaled) < 9.007_199_254_740_992e15 else { return nil }
                if Swift.abs(scaled - scaled.rounded()) > snapTolerance(scaled) {
                    integral = false
                    break
                }
            }
            if integral { return scale }
        }
        return nil
    }

    /// The greatest common divisor of the magnitudes; 1 for an empty list.
    static func commonDivisor(_ values: [Int64]) -> Int64 {
        var g: Int64 = 0
        for v in values {
            var a = g
            var b = v < 0 ? -v : v
            while b != 0 { (a, b) = (b, a % b) }
            g = a
            if g == 1 { break }
        }
        return g == 0 ? 1 : g
    }

    /// Loads a compiled problem. Throws `SolverError.unsupported` for a model outside §10.1.
    init(_ lp: CompiledLP) throws {
        let n = lp.n
        let m = lp.m

        // Columns: all integer, all finitely bounded.
        let isInteger = lp.integerMask()
        var lower = [Int64](repeating: 0, count: n)
        var upper = [Int64](repeating: 0, count: n)
        var infeasible: String? = nil
        for j in 0..<n {
            guard isInteger[j] else {
                throw SolverError.unsupported(
                    "CP-SAT accepts pure integer models: column \(lp.names.column(j)) is continuous (route the model to branch and bound)")
            }
            guard lp.xl[j].isFinite, lp.xu[j].isFinite else {
                throw SolverError.unsupported(
                    "CP-SAT needs finite bounds on every column: integer column \(lp.names.column(j)) is unbounded")
            }
            let lo = (lp.xl[j] - Self.snapTolerance(lp.xl[j])).rounded(.up)
            let hi = (lp.xu[j] + Self.snapTolerance(lp.xu[j])).rounded(.down)
            guard Swift.abs(lo) < 9.007_199_254_740_992e15, Swift.abs(hi) < 9.007_199_254_740_992e15,
                  let lowerBound = Int64(exactly: lo), let upperBound = Int64(exactly: hi)
            else {
                throw SolverError.unsupported(
                    "the bounds of column \(lp.names.column(j)) are too large for exact integer arithmetic")
            }
            lower[j] = lowerBound
            upper[j] = upperBound
            if lowerBound > upperBound && infeasible == nil {
                infeasible = "column \(lp.names.column(j)) has no integer value between its bounds"
            }
        }
        // An empty domain makes the activity computations below meaningless; keep going with a
        // harmless domain so that the unsupported checks still run, and report infeasibility.
        if infeasible != nil {
            for j in 0..<n where lower[j] > upper[j] { upper[j] = lower[j] }
        }

        var linStart: [Int32] = [0]
        var linVar: [Int32] = []
        var linCoef: [Int64] = []
        var linRHS: [Int64] = []
        var linMinActivity: [Int64] = []
        var linMaxTerm: [Int64] = []
        var linTermMax: [Int64] = []
        var clauses: [[BoundLiteral]] = []
        var rowHasLinearSide = [Bool](repeating: false, count: m)

        /// Appends one stored constraint, its terms sorted by decreasing |a|·(ub − lb).
        func store(_ vars: [Int32], _ coefs: [Int64], rhs: Int64, bounds: (min: Int64, max: Int64, maxTerm: Int64)) {
            let spans = zip(vars, coefs).map { v, a in (a < 0 ? -a : a) * (upper[Int(v)] - lower[Int(v)]) }
            let order = vars.indices.sorted { spans[$0] != spans[$1] ? spans[$0] > spans[$1] : vars[$0] < vars[$1] }
            for k in order {
                linVar.append(vars[k])
                linCoef.append(coefs[k])
                linTermMax.append(spans[k])
            }
            linStart.append(Int32(linVar.count))
            linRHS.append(rhs)
            linMinActivity.append(bounds.min)
            linMaxTerm.append(bounds.maxTerm)
        }

        /// Smallest and largest activity of Σ aᵢxᵢ over the root domains, with every
        /// intermediate result checked for overflow.
        func activityBounds(_ vars: [Int32], _ coefs: [Int64]) -> (min: Int64, max: Int64, maxTerm: Int64)? {
            var lo: Int64 = 0
            var hi: Int64 = 0
            var largestTerm: Int64 = 0
            for (v, a) in zip(vars, coefs) {
                let x = Int(v)
                let (atLower, overflowLower) = a.multipliedReportingOverflow(by: lower[x])
                let (atUpper, overflowUpper) = a.multipliedReportingOverflow(by: upper[x])
                if overflowLower || overflowUpper { return nil }
                let termMin = Swift.min(atLower, atUpper)
                let termMax = Swift.max(atLower, atUpper)
                let (span, overflowSpan) = termMax.subtractingReportingOverflow(termMin)
                if overflowSpan { return nil }
                if span > largestTerm { largestTerm = span }
                let (newLo, overflowLo) = lo.addingReportingOverflow(termMin)
                let (newHi, overflowHi) = hi.addingReportingOverflow(termMax)
                if overflowLo || overflowHi { return nil }
                lo = newLo
                hi = newHi
            }
            // Slacks are differences of activities; they must be representable too, with room
            // for the "+ 1" of the explanation thresholds.
            let (range, overflowRange) = hi.subtractingReportingOverflow(lo)
            if overflowRange || range > Int64.max / 4 || lo < Int64.min / 4 || hi > Int64.max / 4 { return nil }
            return (lo, hi, largestTerm)
        }

        /// Adds `Σ coefs·vars ≤ rhs`, as a clause when it is one.
        func addLessEqual(_ vars: [Int32], _ coefs: [Int64], rhs: Int64, bounds: (min: Int64, max: Int64, maxTerm: Int64), row: Int) {
            if rhs >= bounds.max { return }   // never binding
            if rhs < bounds.min {
                if infeasible == nil {
                    infeasible = "row \(lp.names.row(row)) cannot be satisfied within the column bounds"
                }
                return
            }
            // A clause: unit coefficients over binaries, forbidding exactly the one assignment
            // that reaches the maximum activity (all positive terms at 1, all negative at 0).
            var isClause = !vars.isEmpty
            var positives: Int64 = 0
            for (v, a) in zip(vars, coefs) {
                let x = Int(v)
                guard (a == 1 || a == -1), lower[x] == 0, upper[x] == 1 else {
                    isClause = false
                    break
                }
                if a == 1 { positives += 1 }
            }
            if isClause && rhs == positives - 1 {
                // ∨ over positive terms of [x ≤ 0], over negative terms of [x ≥ 1].
                clauses.append(zip(vars, coefs).map { v, a in
                    a == 1
                        ? BoundLiteral(variable: v, isLower: false, value: 0)
                        : BoundLiteral(variable: v, isLower: true, value: 1)
                })
                return
            }
            rowHasLinearSide[row] = true
            store(vars, coefs, rhs: rhs, bounds: bounds)
        }

        // Rows.
        let aT = lp.aT
        var rowVars: [Int32] = []
        var rowCoefs: [Int64] = []
        for i in 0..<m {
            let range = aT.colStart[i]..<aT.colStart[i + 1]
            let rl = lp.rl[i]
            let ru = lp.ru[i]
            if range.isEmpty {
                if (rl > 1e-9 || ru < -1e-9) && infeasible == nil {
                    infeasible = "row \(lp.names.row(i)) has no variables and its bounds exclude zero"
                }
                continue
            }
            guard let scale = Self.integralScale(for: range.lazy.map { aT.values[$0] }) else {
                throw SolverError.unsupported(
                    "row \(lp.names.row(i)) has coefficients that no power of 10 up to 1e6 makes integral")
            }
            rowVars.removeAll(keepingCapacity: true)
            rowCoefs.removeAll(keepingCapacity: true)
            for p in range {
                guard let a = Int64(exactly: (aT.values[p] * scale).rounded()) else {
                    throw SolverError.unsupported("a coefficient of row \(lp.names.row(i)) is too large for exact integer arithmetic")
                }
                if a == 0 { continue }
                rowVars.append(aT.rowIndex[p])
                rowCoefs.append(a)
            }
            if rowVars.isEmpty {
                if (rl > 1e-9 || ru < -1e-9) && infeasible == nil {
                    infeasible = "row \(lp.names.row(i)) has no variables and its bounds exclude zero"
                }
                continue
            }
            // The activity is a multiple of the coefficients' common divisor: divide it out.
            // The row bounds are divided with it and then rounded inward, which is what makes
            // 2x + 2y ≥ 3 the stronger x + y ≥ 2, and a scaled clause a clause again.
            let divisor = Self.commonDivisor(rowCoefs)
            if divisor > 1 {
                for k in rowCoefs.indices { rowCoefs[k] /= divisor }
            }
            let rowScale = scale / Double(divisor)
            guard let bounds = activityBounds(rowVars, rowCoefs) else {
                throw SolverError.unsupported("the activity bounds of row \(lp.names.row(i)) do not fit in Int64")
            }
            // The activity is an integer, so fractional row bounds round inward. Bounds beyond
            // the reachable activities are either redundant or infeasible and never converted.
            let scaledUpper = ru * rowScale
            if scaledUpper < Double(bounds.max) {
                if scaledUpper < Double(bounds.min) - 0.5 {
                    if infeasible == nil {
                        infeasible = "row \(lp.names.row(i)) cannot be satisfied within the column bounds"
                    }
                } else {
                    let rhs = Int64((scaledUpper + Self.snapTolerance(scaledUpper)).rounded(.down))
                    addLessEqual(rowVars, rowCoefs, rhs: rhs, bounds: bounds, row: i)
                }
            }
            let scaledLower = rl * rowScale
            if scaledLower > Double(bounds.min) {
                if scaledLower > Double(bounds.max) + 0.5 {
                    if infeasible == nil {
                        infeasible = "row \(lp.names.row(i)) cannot be satisfied within the column bounds"
                    }
                } else {
                    // Σ a·x ≥ L  ⇔  Σ (−a)·x ≤ −L.
                    let bound = Int64((scaledLower - Self.snapTolerance(scaledLower)).rounded(.up))
                    addLessEqual(
                        rowVars, rowCoefs.map { -$0 }, rhs: -bound,
                        bounds: (-bounds.max, -bounds.min, bounds.maxTerm), row: i)
                }
            }
        }

        // Objective, in the minimization form; the constant stays outside the integer row.
        var objectiveRow = -1
        var objectiveScale = 1.0
        var prefersUpper = [Bool](repeating: false, count: n)
        if lp.c.contains(where: { $0 != 0 }) {
            guard let scale = Self.integralScale(for: lp.c) else {
                throw SolverError.unsupported("the objective has coefficients that no power of 10 up to 1e6 makes integral")
            }
            var vars: [Int32] = []
            var coefs: [Int64] = []
            for j in 0..<n where lp.c[j] != 0 {
                guard let c = Int64(exactly: (lp.c[j] * scale).rounded()) else {
                    throw SolverError.unsupported("an objective coefficient is too large for exact integer arithmetic")
                }
                if c == 0 { continue }
                vars.append(Int32(j))
                coefs.append(c)
                prefersUpper[j] = c < 0
            }
            if !vars.isEmpty {
                // Dividing out the common divisor makes "objective ≤ z − 1" the smallest
                // improvement that exists, so the linear search takes no empty steps.
                let divisor = Self.commonDivisor(coefs)
                if divisor > 1 {
                    for k in coefs.indices { coefs[k] /= divisor }
                }
                guard let bounds = activityBounds(vars, coefs) else {
                    throw SolverError.unsupported("the range of the objective does not fit in Int64")
                }
                objectiveScale = scale / Double(divisor)
                objectiveRow = linRHS.count
                // No incumbent yet: the row starts out non-binding.
                store(vars, coefs, rhs: bounds.max, bounds: bounds)
            }
        }

        // Occurrence lists, split by coefficient sign.
        var posCount = [Int32](repeating: 0, count: n + 1)
        var negCount = [Int32](repeating: 0, count: n + 1)
        for t in linVar.indices {
            if linCoef[t] > 0 { posCount[Int(linVar[t]) + 1] += 1 } else { negCount[Int(linVar[t]) + 1] += 1 }
        }
        for j in 0..<n {
            posCount[j + 1] += posCount[j]
            negCount[j + 1] += negCount[j]
        }
        var occPosRow = [Int32](repeating: 0, count: Int(posCount[n]))
        var occPosCoef = [Int64](repeating: 0, count: Int(posCount[n]))
        var occNegRow = [Int32](repeating: 0, count: Int(negCount[n]))
        var occNegCoef = [Int64](repeating: 0, count: Int(negCount[n]))
        var nextPos = posCount
        var nextNeg = negCount
        for c in 0..<linRHS.count {
            for t in Int(linStart[c])..<Int(linStart[c + 1]) {
                let x = Int(linVar[t])
                if linCoef[t] > 0 {
                    let q = Int(nextPos[x])
                    nextPos[x] += 1
                    occPosRow[q] = Int32(c)
                    occPosCoef[q] = linCoef[t]
                } else {
                    let q = Int(nextNeg[x])
                    nextNeg[x] += 1
                    occNegRow[q] = Int32(c)
                    occNegCoef[q] = linCoef[t]
                }
            }
        }

        self.variableCount = n
        self.lower = lower
        self.upper = upper
        self.linStart = linStart
        self.linVar = linVar
        self.linCoef = linCoef
        self.linRHS = linRHS
        self.linMinActivity = linMinActivity
        self.linMaxTerm = linMaxTerm
        self.linTermMax = linTermMax
        self.objectiveRow = objectiveRow
        self.occPosStart = posCount
        self.occPosRow = occPosRow
        self.occPosCoef = occPosCoef
        self.occNegStart = negCount
        self.occNegRow = occNegRow
        self.occNegCoef = occNegCoef
        self.clauses = clauses
        self.rowHasLinearSide = rowHasLinearSide
        self.objectiveScale = objectiveScale
        self.objectiveConstant = lp.c0
        self.maximize = lp.sense == .maximize
        self.objectivePrefersUpper = prefersUpper
        self.infeasibleReason = infeasible
        let clauseLiterals = clauses.reduce(0) { $0 + $1.count }
        self.approximateBytes =
            n * (2 * MemoryLayout<Int64>.size + 1 + 2 * MemoryLayout<Int32>.size)
            + linVar.count * (2 * (MemoryLayout<Int32>.size + MemoryLayout<Int64>.size) + MemoryLayout<Int64>.size)
            + linRHS.count * (3 * MemoryLayout<Int64>.size + MemoryLayout<Int32>.size)
            + clauseLiterals * MemoryLayout<BoundLiteral>.stride + clauses.count * 32 + m
    }

    /// The integer objective `Σ cᵢxᵢ` of an assignment; 0 for a feasibility problem.
    func objectiveValue(of values: [Int64]) -> Int64 {
        guard objectiveRow >= 0 else { return 0 }
        var total: Int64 = 0
        for t in Int(linStart[objectiveRow])..<Int(linStart[objectiveRow + 1]) {
            total += linCoef[t] * values[Int(linVar[t])]
        }
        return total
    }

    /// Whether an assignment satisfies every constraint and clause of the model, the objective
    /// row excepted. Used by the tests and by debug assertions.
    func isSatisfied(by values: [Int64]) -> Bool {
        for j in 0..<variableCount where values[j] < lower[j] || values[j] > upper[j] { return false }
        for c in 0..<linRHS.count where c != objectiveRow {
            var activity: Int64 = 0
            for t in Int(linStart[c])..<Int(linStart[c + 1]) {
                activity += linCoef[t] * values[Int(linVar[t])]
            }
            if activity > linRHS[c] { return false }
        }
        for clause in clauses {
            let satisfied = clause.contains { literal in
                let v = values[Int(literal.variable)]
                return literal.isLower ? v >= literal.value : v <= literal.value
            }
            if !satisfied { return false }
        }
        return true
    }
}
