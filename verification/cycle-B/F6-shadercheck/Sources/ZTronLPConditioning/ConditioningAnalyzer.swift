// ConditioningAnalyzer (specification §13).
//
// `ConditioningAnalyzer.analyze(_:basis:)` reports why a model is slow or numerically fragile
// before or after a solve: coefficient ranges, the scaling the engines would apply, structural
// defects, big-M coefficients, near-parallel rows and — when a basis is given and the problem
// has at most 4,000 rows — the 1-norm condition number of the basis and how degenerate it is.
//
// Row statistics are computed in parallel over row blocks; the basis condition number uses
// `dgetrf` + `dgecon` on the dense basis through the numerics layer.

import Foundation
import ZTronLPCore
import ZTronLPNumerics

public enum ConditioningAnalyzer {
    /// Knobs of the analysis. The thresholds of §13 are fixed; these only bound the work and
    /// the size of the report.
    public struct Options: Sendable {
        /// At most this many findings of one kind are listed. The rest are counted in
        /// `ConditioningReport.omittedFindings`, so a model with 100,000 free columns does not
        /// produce 100,000 lines.
        public var maxFindingsPerKind: Int = 100
        /// Problems with fewer rows than this compute their row statistics on the calling task.
        public var parallelRowThreshold: Int = 4_096
        /// How close to a bound a basic variable must be to count as sitting on it, relative
        /// to `1 + |bound|`.
        public var boundTolerance: Double = Tolerances.default.primalFeasibility

        public init() {}
    }

    // MARK: Thresholds (§13)

    /// Coefficient ratio above which a range is a warning, and above which it is severe.
    public static let wideRangeWarning = 1e6
    public static let wideRangeSevere = 1e9
    /// A coefficient at least this many times the row median, on a binary column, is a big-M.
    public static let bigMRatio = 1e4
    /// Rows are near-parallel when |cos| exceeds this.
    public static let parallelCosine = 1 - 1e-9
    /// A column is dense above this fraction of nonzeros.
    public static let denseColumnDensity = 0.30
    /// A basis is degenerate enough to warn about above this fraction of basics at a bound.
    public static let degenerateBasisFraction = 0.30
    /// Basis condition estimate above which the basis is a warning, and above which it is severe.
    public static let illConditionedWarning = 1e8
    public static let illConditionedSevere = 1e12
    /// The dense condition estimate is skipped above this many rows.
    public static let maxRowsForConditionEstimate = 4_000
    /// Up to this many rows the interior point factors a dense matrix anyway (§8.2), so a dense
    /// column costs nothing there and is reported as information only.
    static let denseNormalEquationsRows = 300

    // MARK: Entry points

    /// Analyzes a problem and, optionally, a basis of it.
    ///
    /// - Parameters:
    ///   - lp: the problem, as compiled or as an engine's scaled working copy.
    ///   - basis: a basis of `lp` (`n + m` statuses, `m` basic columns), typically the final
    ///     basis of a simplex solve. Enables the condition estimate and the degeneracy finding.
    ///   - primal: the `n` structural values of the solution the basis belongs to. When absent,
    ///     the values of the basic variables are recomputed from the basis.
    ///   - context: supplies the thread count for the row statistics and the memory budget
    ///     that the dense basis factorization must fit.
    ///   - budget: the concurrency budget to borrow row-block slots from when the analysis runs
    ///     inside a solve (rule C7). By default the analysis gets a budget of its own, sized by
    ///     `context`, in which the calling task holds one slot.
    public static func analyze(
        _ lp: CompiledLP, basis: Basis? = nil, primal: [Double]? = nil, context: SolveContext = .init(),
        options: Options = .init(), budget: ConcurrencyBudget? = nil
    ) async -> ConditioningReport {
        let m = lp.m
        let n = lp.n
        let limit = Swift.max(0, options.maxFindingsPerKind)
        var collected = [[Finding]](repeating: [], count: Finding.Kind.categoryCount)
        var omitted = 0
        func add(_ finding: Finding) {
            let category = finding.kind.category
            if collected[category].count < limit {
                collected[category].append(finding)
            } else {
                omitted += 1
            }
        }

        // MARK: Coefficient ranges

        let matrixRange = magnitudeRange(lp.a.values)
        let objectiveRange = magnitudeRange(lp.c)
        let rhsRange = magnitudeRange(lp.rl, lp.ru)
        let boundsRange = magnitudeRange(lp.xl, lp.xu)
        for (title, range) in [
            ("matrix coefficients", matrixRange), ("objective coefficients", objectiveRange),
            ("right-hand sides", rhsRange), ("bounds", boundsRange),
        ] {
            let ratio = ConditioningReport.ratio(range)
            guard ratio > wideRangeWarning else { continue }
            add(
                Finding(
                    severity: ratio > wideRangeSevere ? .severe : .warning, kind: .wideCoefficientRange(ratio: ratio),
                    message: "the \(title) span \(format(range.lowerBound)) to \(format(range.upperBound)), a ratio of \(format(ratio))"))
        }

        // MARK: Columns

        let isInteger = lp.integerMask()
        var isBinary = [Bool](repeating: false, count: n)
        for j in 0..<n where isInteger[j] && lp.xl[j] == 0 && lp.xu[j] == 1 { isBinary[j] = true }
        for j in 0..<n {
            let entries = lp.a.colStart[j + 1] - lp.a.colStart[j]
            if entries == 0 {
                // A cost that improves without bound makes the whole model unbounded (or infeasible).
                let improvesForever = (lp.c[j] > 0 && lp.xl[j] == -.infinity) || (lp.c[j] < 0 && lp.xu[j] == .infinity)
                add(
                    Finding(
                        severity: improvesForever ? .warning : .info, kind: .emptyColumn(j),
                        message: improvesForever
                            ? "column \(lp.names.column(j)) appears in no row and its cost improves without bound"
                            : "column \(lp.names.column(j)) appears in no row"))
            }
            if lp.xl[j] == -.infinity && lp.xu[j] == .infinity {
                add(Finding(severity: .info, kind: .freeColumn(j), message: "column \(lp.names.column(j)) has no bounds"))
            } else if lp.xl[j] == lp.xu[j] {
                add(
                    Finding(
                        severity: .info, kind: .fixedColumn(j),
                        message: "column \(lp.names.column(j)) is fixed at \(format(lp.xl[j]))"))
            }
            if m > 0 {
                let density = Double(entries) / Double(m)
                if density > denseColumnDensity {
                    add(
                        Finding(
                            severity: m > denseNormalEquationsRows ? .warning : .info,
                            kind: .denseColumn(j, density: density),
                            message: "column \(lp.names.column(j)) has entries in \(percent(density)) of the rows, which makes the interior point's normal equations dense"))
                }
            }
        }

        // MARK: Rows, in parallel over row blocks

        let threads = budget?.capacity ?? context.resolvedThreads
        let blocks = m >= options.parallelRowThreshold ? Swift.min(threads, 16) : 1
        // A block only runs on another task when the budget has a free slot; otherwise the
        // calling task works through the blocks itself.
        let slots = blocks > 1 ? (budget ?? ConcurrencyBudget(threads: threads)) : nil
        let binaryMask = isBinary
        let parts = await parallelBlocks(count: m, blocks: blocks, budget: slots) { range in
            rowStatistics(lp, rows: range, isBinary: binaryMask, limit: limit)
        }
        var keys: [RowKey] = []
        keys.reserveCapacity(m)
        for part in parts {
            for i in part.emptyRows {
                let infeasible = lp.rl[i] > 0 || lp.ru[i] < 0
                add(
                    Finding(
                        severity: infeasible ? .severe : .info, kind: .emptyRow(i),
                        message: infeasible
                            ? "row \(lp.names.row(i)) has no entries and its bounds exclude zero: the model is infeasible"
                            : "row \(lp.names.row(i)) has no entries"))
            }
            for i in part.singletonRows {
                add(
                    Finding(
                        severity: .info, kind: .singletonRow(i),
                        message: "row \(lp.names.row(i)) has a single entry and is really a bound"))
            }
            for big in part.bigM {
                add(
                    Finding(
                        severity: .warning, kind: .bigM(row: big.row, column: big.column, ratio: big.ratio),
                        message: "row \(lp.names.row(big.row)) has a coefficient on the binary column \(lp.names.column(big.column)) that is \(format(big.ratio)) times the row median (big-M)"))
            }
            omitted += part.omitted
            keys.append(contentsOf: part.keys)
        }

        // MARK: Near-parallel rows

        for pair in parallelRows(lp, keys: keys) {
            add(
                Finding(
                    severity: .warning, kind: .nearParallelRows(pair.first, pair.second, cosine: pair.cosine),
                    message: "rows \(lp.names.row(pair.first)) and \(lp.names.row(pair.second)) are \(pair.cosine < 0 ? "anti-parallel" : "parallel") (cosine \(String(format: "%.12f", pair.cosine)))"))
        }

        // MARK: Basis

        var conditionEstimate: Double? = nil
        var outcome = BasisAnalysisOutcome.noBasis
        if let basis {
            if !isValid(basis, for: lp) {
                outcome = .invalidBasis
            } else if m > maxRowsForConditionEstimate {
                outcome = .tooManyRows(m)
                // Without the factorization the degeneracy can still be read off a solution.
                if let primal, primal.count == n {
                    let fraction = degenerateFraction(lp, basis: basis, basicValues: nil, primal: primal, tolerance: options.boundTolerance)
                    if let finding = degeneracyFinding(fraction) { add(finding) }
                }
            } else if 16 * m * m > MemoryBudget.resolve(context) {
                outcome = .overMemoryBudget
                if let primal, primal.count == n {
                    let fraction = degenerateFraction(lp, basis: basis, basicValues: nil, primal: primal, tolerance: options.boundTolerance)
                    if let finding = degeneracyFinding(fraction) { add(finding) }
                }
            } else {
                outcome = .analyzed
                let factorization = factor(basis, lp)
                switch factorization {
                case .singular:
                    conditionEstimate = .infinity
                case .factored(let lu):
                    conditionEstimate = lu.conditionEstimate()
                }
                if let kappa = conditionEstimate, kappa > illConditionedWarning {
                    add(
                        Finding(
                            severity: kappa > illConditionedSevere ? .severe : .warning,
                            kind: .illConditionedBasis(kappa: kappa),
                            message: kappa.isInfinite
                                ? "the basis matrix is singular"
                                : "the basis matrix has a condition estimate of \(format(kappa))"))
                }
                var basicValues: [Double]? = nil
                if primal?.count != n, case .factored(let lu) = factorization {
                    basicValues = valuesOfBasics(lp, basis: basis, factorization: lu)
                }
                if primal?.count == n || basicValues != nil {
                    let fraction = degenerateFraction(
                        lp, basis: basis, basicValues: basicValues, primal: primal?.count == n ? primal : nil,
                        tolerance: options.boundTolerance)
                    if let finding = degeneracyFinding(fraction) { add(finding) }
                }
            }
        }

        // MARK: Report

        // Most severe first; equal severities in the order of the specification's list, and
        // within one kind in index order.
        var findings: [Finding] = []
        for severity in [Finding.Severity.severe, .warning, .info] {
            for category in collected {
                findings.append(contentsOf: category.filter { $0.severity == severity })
            }
        }
        // The scale vectors of §5.4. For a problem as compiled they are the factors the engines
        // would apply; for an engine's scaled working copy they are the ones it carries in
        // `CompiledLP.scaling`, i.e. the ones that were applied.
        let scaling = lp.scaling ?? Scaler.factors(for: lp, mode: .geometricEquilibration)
        return ConditioningReport(
            coefficientRange: (matrixRange, objectiveRange, rhsRange, boundsRange),
            suggestedScaling: (scaling.rows, scaling.columns), basisConditionEstimate: conditionEstimate,
            findings: findings, omittedFindings: omitted, basisAnalysis: outcome, dimensions: (m, n, lp.nnz),
            scalingIsApplied: lp.scaling != nil)
    }

    /// Analyzes a problem after a solve, taking the basis and the solution from the analysis
    /// when it has them.
    public static func analyze(
        _ lp: CompiledLP, after analysis: some SolutionAnalysis, context: SolveContext = .init(),
        options: Options = .init(), budget: ConcurrencyBudget? = nil
    ) async -> ConditioningReport {
        let basis = (analysis as? any BasisProviding)?.finalBasis
        return await analyze(
            lp, basis: basis, primal: analysis.primal, context: context, options: options, budget: budget)
    }

    // MARK: - Ranges

    /// The smallest and largest magnitude among the finite nonzero values; `0...0` when there
    /// is none.
    static func magnitudeRange(_ groups: [Double]...) -> ClosedRange<Double> {
        var smallest = Double.infinity
        var largest = 0.0
        for values in groups {
            for value in values {
                let magnitude = Swift.abs(value)
                guard magnitude > 0, magnitude.isFinite else { continue }
                if magnitude < smallest { smallest = magnitude }
                if magnitude > largest { largest = magnitude }
            }
        }
        return largest > 0 ? smallest...largest : 0...0
    }

    // MARK: - Row statistics

    /// What the hash of a scaled row is built from, kept for the exact confirmation.
    struct RowKey: Sendable {
        let row: Int
        /// Hashes of the row scaled to unit length with a positive leading entry, quantized on
        /// two grids half a step apart, so that two nearly equal rows share at least one key
        /// unless different entries straddle a cell boundary on both grids.
        let first: UInt64
        let second: UInt64
        let norm: Double
    }

    struct RowBlock: Sendable {
        var emptyRows: [Int] = []
        var singletonRows: [Int] = []
        var bigM: [(row: Int, column: Int, ratio: Double)] = []
        var keys: [RowKey] = []
        /// Findings of this block beyond the per-kind limit.
        var omitted = 0
    }

    /// The statistics of one block of rows, read from the CSR view of A.
    static func rowStatistics(_ lp: CompiledLP, rows: Range<Int>, isBinary: [Bool], limit: Int) -> RowBlock {
        var block = RowBlock()
        let aT = lp.aT
        var magnitudes: [Double] = []
        for i in rows {
            let start = aT.colStart[i]
            let end = aT.colStart[i + 1]
            let count = end - start
            if count == 0 {
                if block.emptyRows.count < limit { block.emptyRows.append(i) } else { block.omitted += 1 }
                continue
            }
            if count == 1 {
                if block.singletonRows.count < limit { block.singletonRows.append(i) } else { block.omitted += 1 }
                continue
            }

            // Big-M: only rows that touch a binary column need their median.
            var touchesBinary = false
            for p in start..<end where isBinary[Int(aT.rowIndex[p])] {
                touchesBinary = true
                break
            }
            if touchesBinary {
                magnitudes.removeAll(keepingCapacity: true)
                for p in start..<end { magnitudes.append(Swift.abs(aT.values[p])) }
                magnitudes.sort()
                // The lower median: with an even number of entries the mean of the two middle
                // ones would hide the commonest big-M row of all, `x − M·y ≤ 0`.
                let median = magnitudes[(count - 1) / 2]
                if median > 0 {
                    for p in start..<end {
                        let column = Int(aT.rowIndex[p])
                        guard isBinary[column] else { continue }
                        let ratio = Swift.abs(aT.values[p]) / median
                        if ratio >= bigMRatio {
                            if block.bigM.count < limit {
                                block.bigM.append((i, column, ratio))
                            } else {
                                block.omitted += 1
                            }
                        }
                    }
                }
            }

            // Hash of the scaled row, for the parallel-row search.
            var squares = 0.0
            for p in start..<end { squares += aT.values[p] * aT.values[p] }
            let norm = squares.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            let sign: Double = aT.values[start] < 0 ? -1 : 1
            var first: UInt64 = 0x9E37_79B9_7F4A_7C15
            var second: UInt64 = 0xC2B2_AE3D_27D4_EB4F
            for p in start..<end {
                let scaled = sign * aT.values[p] / norm * 64
                let column = UInt64(truncatingIfNeeded: Int(aT.rowIndex[p]))
                first = mix(mix(first, column), UInt64(bitPattern: Int64(scaled.rounded(.down))))
                second = mix(mix(second, column), UInt64(bitPattern: Int64((scaled + 0.5).rounded(.down))))
            }
            block.keys.append(RowKey(row: i, first: first, second: second, norm: norm))
        }
        return block
    }

    /// A 64-bit mixing step (SplitMix64's finalizer); deterministic across runs, unlike `Hasher`.
    private static func mix(_ state: UInt64, _ value: UInt64) -> UInt64 {
        var z = (state ^ value) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Near-parallel rows

    /// Pairs of rows whose cosine exceeds the threshold in magnitude. Rows that share a hash
    /// are candidates; each candidate is confirmed with the exact cosine against the
    /// representatives of its bucket, so a group of k mutually parallel rows yields k − 1
    /// pairs, each with the group's first row.
    static func parallelRows(_ lp: CompiledLP, keys: [RowKey]) -> [(first: Int, second: Int, cosine: Double)] {
        var pairs: [(first: Int, second: Int, cosine: Double)] = []
        var representatives: [UInt64: [Int]] = [:]
        representatives.reserveCapacity(keys.count)
        var norms: [Int: Double] = [:]
        let aT = lp.aT
        /// Rows in one bucket that are not parallel to each other; beyond this the bucket is
        /// a hash accident or a pathological model, and the search stops growing it.
        let bucketLimit = 32

        func cosine(_ i: Int, _ j: Int, _ normI: Double, _ normJ: Double) -> Double {
            var p = aT.colStart[i]
            var q = aT.colStart[j]
            let endP = aT.colStart[i + 1]
            let endQ = aT.colStart[j + 1]
            var dot = 0.0
            while p < endP && q < endQ {
                let a = aT.rowIndex[p]
                let b = aT.rowIndex[q]
                if a == b {
                    dot += aT.values[p] * aT.values[q]
                    p += 1
                    q += 1
                } else if a < b {
                    p += 1
                } else {
                    q += 1
                }
            }
            return dot / (normI * normJ)
        }

        for key in keys {
            var matched = false
            var checked: [Int] = []
            for hash in [key.first, key.second] {
                guard let bucket = representatives[hash] else { continue }
                for other in bucket where !checked.contains(other) {
                    checked.append(other)
                    guard let otherNorm = norms[other] else { continue }
                    let c = cosine(other, key.row, otherNorm, key.norm)
                    if Swift.abs(c) > parallelCosine {
                        pairs.append((other, key.row, c))
                        matched = true
                        break
                    }
                }
                if matched { break }
            }
            guard !matched else { continue }
            norms[key.row] = key.norm
            for hash in key.first == key.second ? [key.first] : [key.first, key.second] {
                if (representatives[hash]?.count ?? 0) < bucketLimit {
                    representatives[hash, default: []].append(key.row)
                }
            }
        }
        return pairs
    }

    // MARK: - Basis

    /// True when the basis has `n + m` statuses and `m` distinct basic columns in range.
    static func isValid(_ basis: Basis, for lp: CompiledLP) -> Bool {
        guard basis.status.count == lp.n + lp.m, basis.basic.count == lp.m else { return false }
        var seen = Set<Int32>()
        for column in basis.basic {
            guard column >= 0, Int(column) < lp.n + lp.m, seen.insert(column).inserted else { return false }
        }
        return true
    }

    enum BasisFactors {
        case singular
        case factored(DenseLU)
    }

    /// The dense basis matrix — the columns `basic` of `[A −I]` — factored with `dgetrf`.
    static func factor(_ basis: Basis, _ lp: CompiledLP) -> BasisFactors {
        let m = lp.m
        let n = lp.n
        var matrix = DenseMatrix(rows: m, cols: m)
        for (k, column) in basis.basic.enumerated() {
            let j = Int(column)
            if j < n {
                for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                    matrix.storage[k * m + Int(lp.a.rowIndex[p])] = lp.a.values[p]
                }
            } else {
                matrix.storage[k * m + (j - n)] = -1
            }
        }
        do {
            return .factored(try DenseLU(matrix))
        } catch {
            return .singular
        }
    }

    /// The values of the basic variables, by basis position, implied by the nonbasic variables
    /// resting where their statuses say: B·x_B = −N·x_N for the logical form `Ax − s = 0`.
    static func valuesOfBasics(_ lp: CompiledLP, basis: Basis, factorization: DenseLU) -> [Double] {
        let n = lp.n
        let m = lp.m
        func resting(_ status: BasisStatus, _ lower: Double, _ upper: Double) -> Double {
            switch status {
            case .atLower, .fixed: return lower.isFinite ? lower : (upper.isFinite ? upper : 0)
            case .atUpper: return upper.isFinite ? upper : (lower.isFinite ? lower : 0)
            case .free, .basic: return 0
            }
        }
        var rhs = [Double](repeating: 0, count: m)
        for j in 0..<n where basis.status[j] != .basic {
            let value = resting(basis.status[j], lp.xl[j], lp.xu[j])
            if value == 0 { continue }
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                rhs[Int(lp.a.rowIndex[p])] -= lp.a.values[p] * value
            }
        }
        // A logical column is −e_i, so a nonbasic logical contributes +s_i to row i.
        for i in 0..<m where basis.status[n + i] != .basic {
            rhs[i] += resting(basis.status[n + i], lp.rl[i], lp.ru[i])
        }
        factorization.solve(&rhs)
        return rhs
    }

    /// The fraction of basic variables that sit on one of their bounds.
    static func degenerateFraction(
        _ lp: CompiledLP, basis: Basis, basicValues: [Double]?, primal: [Double]?, tolerance: Double
    ) -> Double {
        let n = lp.n
        let m = lp.m
        guard m > 0 else { return 0 }
        let activity = primal.map { lp.rowActivity($0) }
        func onBound(_ value: Double, _ lower: Double, _ upper: Double) -> Bool {
            (lower.isFinite && Swift.abs(value - lower) <= tolerance * (1 + Swift.abs(lower)))
                || (upper.isFinite && Swift.abs(value - upper) <= tolerance * (1 + Swift.abs(upper)))
        }
        var count = 0
        for (k, column) in basis.basic.enumerated() {
            let j = Int(column)
            let value: Double
            if let primal, let activity {
                value = j < n ? primal[j] : activity[j - n]
            } else if let basicValues {
                value = basicValues[k]
            } else {
                continue
            }
            if j < n {
                if onBound(value, lp.xl[j], lp.xu[j]) { count += 1 }
            } else if onBound(value, lp.rl[j - n], lp.ru[j - n]) {
                count += 1
            }
        }
        return Double(count) / Double(m)
    }

    static func degeneracyFinding(_ fraction: Double) -> Finding? {
        guard fraction > 0 else { return nil }
        return Finding(
            severity: fraction > degenerateBasisFraction ? .warning : .info, kind: .degenerateBasis(fraction: fraction),
            message: "\(percent(fraction)) of the basic variables sit on a bound (degenerate basis)")
    }

    // MARK: - Formatting

    private static func format(_ value: Double) -> String {
        ConditioningReport.format(value)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
