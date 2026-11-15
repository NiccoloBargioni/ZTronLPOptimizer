// The conditioning analyzer (specification §13): the coefficient ranges, one test per finding
// kind and per severity threshold, the suggested scaling and the report text.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPConditioning

@Suite struct ConditioningAnalyzerTests {
    // MARK: Coefficient ranges

    @Test func rangesCoverMagnitudesWithoutZerosAndInfinities() async {
        let lp = ConditioningProblems.make(
            rows: [[1, -0.5, 0], [0, 4, 200]], c: [0, -3, 0.25], xl: [0, -.infinity, 1],
            xu: [.infinity, .infinity, 100], rl: [-.infinity, 2], ru: [10, .infinity])
        let report = await ConditioningAnalyzer.analyze(lp)
        #expect(report.coefficientRange.matrix == 0.5...200)
        #expect(report.coefficientRange.objective == 0.25...3)
        #expect(report.coefficientRange.rhs == 2...10)
        #expect(report.coefficientRange.bounds == 1...100)
        #expect(report.dimensions.rows == 2 && report.dimensions.columns == 3 && report.dimensions.nonzeros == 4)

        // A group without a single nonzero value reports 0...0, with ratio 1.
        let flat = ConditioningProblems.make(rows: [[1, 1]])
        let flatReport = await ConditioningAnalyzer.analyze(flat)
        #expect(flatReport.coefficientRange.objective == 0...0)
        #expect(flatReport.coefficientRange.rhs == 0...0)
        #expect(flatReport.coefficientRange.bounds == 0...0)
        #expect(ConditioningReport.ratio(flatReport.coefficientRange.objective) == 1)
        // Nothing to warn about: the only remarks are that both columns fill the single row.
        #expect(flatReport.kinds == [.denseColumn(0, density: 1), .denseColumn(1, density: 1)])
        #expect(flatReport.worstSeverity == .info)

        // A problem with no rows and no columns has no findings at all.
        let nothing = await ConditioningAnalyzer.analyze(ConditioningProblems.make(rows: [], columns: 0))
        #expect(nothing.findings.isEmpty)
        #expect(nothing.worstSeverity == nil)
        #expect(nothing.coefficientRange.matrix == 0...0)
    }

    // MARK: wideCoefficientRange — warning > 1e6, severe > 1e9

    @Test(arguments: [
        (1e6, nil), (1.000001e6, Finding.Severity.warning), (1e9, Finding.Severity.warning),
        (1.000001e9, Finding.Severity.severe), (1e12, Finding.Severity.severe),
    ] as [(Double, Finding.Severity?)])
    func wideMatrixRangeThresholds(_ largest: Double, _ expected: Finding.Severity?) async {
        let lp = ConditioningProblems.make(rows: [[1, largest], [1, 1]])
        let report = await ConditioningAnalyzer.analyze(lp)
        let finding = report.first { if case .wideCoefficientRange = $0 { return true } else { return false } }
        #expect(finding?.severity == expected)
        if let finding, case .wideCoefficientRange(let ratio) = finding.kind {
            #expect(ratio == largest)
            #expect(finding.message.contains("matrix coefficients"))
        }
    }

    @Test func wideRangesOfTheOtherGroupsAreReportedToo() async {
        let lp = ConditioningProblems.make(
            rows: [[1, 1], [1, -1]], c: [1e-4, 1e4], xl: [0, 0], xu: [1e-2, 1e8], rl: [1e-3, -.infinity],
            ru: [.infinity, 5e3])
        let report = await ConditioningAnalyzer.analyze(lp)
        let wide = report.findings.filter { if case .wideCoefficientRange = $0.kind { return true } else { return false } }
        // objective 1e8, right-hand sides 5e6, bounds 1e10; the matrix is fine.
        #expect(wide.count == 3)
        #expect(wide.contains { $0.message.contains("objective") && $0.severity == .warning })
        #expect(wide.contains { $0.message.contains("right-hand sides") && $0.severity == .warning })
        #expect(wide.contains { $0.message.contains("bounds") && $0.severity == .severe })
        #expect(!wide.contains { $0.message.contains("matrix") })
        // Most severe first.
        #expect(report.findings.first?.severity == .severe)
    }

    // MARK: bigM — a coefficient ≥ 1e4 × the row median on a binary column

    @Test func bigMOnABinaryColumnIsReported() async {
        // Column 2 is binary; x0 + x1 − 1e5·y ≤ 0.
        let lp = ConditioningProblems.make(
            rows: [[1, 1, -1e5], [1, 2, 3]], xu: [.infinity, .infinity, 1], integer: [2])
        let report = await ConditioningAnalyzer.analyze(lp)
        let finding = report.first { if case .bigM = $0 { return true } else { return false } }
        #expect(finding?.severity == .warning)
        guard let finding, case .bigM(let row, let column, let ratio) = finding.kind else {
            Issue.record("no big-M finding")
            return
        }
        #expect(row == 0 && column == 2 && ratio == 1e5)
    }

    @Test func bigMUsesTheLowerMedianAndTheExactThreshold() async {
        // The commonest big-M row has two entries: x − M·y ≤ 0. Exactly 1e4 counts; 9999 does not.
        let atThreshold = ConditioningProblems.make(rows: [[1, -1e4], [1, 1]], xu: [.infinity, 1], integer: [1])
        let below = ConditioningProblems.make(rows: [[1, -9999], [1, 1]], xu: [.infinity, 1], integer: [1])
        let isBigM: (Finding.Kind) -> Bool = { if case .bigM = $0 { return true } else { return false } }
        let hit = await ConditioningAnalyzer.analyze(atThreshold)
        #expect(hit.kinds.filter(isBigM) == [.bigM(row: 0, column: 1, ratio: 1e4)])
        let miss = await ConditioningAnalyzer.analyze(below)
        #expect(miss.kinds.filter(isBigM).isEmpty)
    }

    @Test func bigMNeedsABinaryColumn() async {
        let isBigM: (Finding.Kind) -> Bool = { if case .bigM = $0 { return true } else { return false } }
        // The same coefficient on a general integer column, and on a continuous one in [0, 1].
        let general = ConditioningProblems.make(rows: [[1, -1e6], [1, 1]], xu: [.infinity, 5], integer: [1])
        #expect(await ConditioningAnalyzer.analyze(general).kinds.filter(isBigM).isEmpty)
        let continuous = ConditioningProblems.make(rows: [[1, -1e6], [1, 1]], xu: [.infinity, 1])
        #expect(await ConditioningAnalyzer.analyze(continuous).kinds.filter(isBigM).isEmpty)
        // A large coefficient on the binary column of a row whose other coefficients are just
        // as large is not a big-M.
        let uniform = ConditioningProblems.make(rows: [[1e6, -1e6, 2e6], [1, 1, 1]], xu: [.infinity, 1, .infinity], integer: [1])
        #expect(await ConditioningAnalyzer.analyze(uniform).kinds.filter(isBigM).isEmpty)
    }

    // MARK: emptyRow, emptyColumn, singletonRow

    @Test func structuralDefectsAreReportedWithTheirIndices() async {
        // Row 1 is empty, row 2 has one entry, column 2 is empty.
        let lp = ConditioningProblems.make(
            rows: [[1, 2, 0, 1], [0, 0, 0, 0], [0, 3, 0, 0], [2, 1, 0, 5]], rl: [0, -1, 0, 0], ru: [9, 1, 9, 9])
        let report = await ConditioningAnalyzer.analyze(lp)
        #expect(report.kinds.contains(.emptyRow(1)))
        #expect(report.kinds.contains(.singletonRow(2)))
        #expect(report.kinds.contains(.emptyColumn(2)))
        #expect(report.findings.allSatisfy { $0.severity == .info })
        #expect(!report.kinds.contains(.emptyRow(0)) && !report.kinds.contains(.singletonRow(0)))
        // Names appear in the messages.
        #expect(report.first { $0 == .emptyRow(1) }?.message.contains("c2") == true)
        #expect(report.first { $0 == .emptyColumn(2) }?.message.contains("x3") == true)
    }

    @Test func anEmptyRowThatExcludesZeroIsSevere() async {
        let lp = ConditioningProblems.make(rows: [[1, 1], [0, 0]], rl: [0, 1], ru: [5, 2])
        let report = await ConditioningAnalyzer.analyze(lp)
        let finding = report.first { $0 == .emptyRow(1) }
        #expect(finding?.severity == .severe)
        #expect(finding?.message.contains("infeasible") == true)
        #expect(report.worstSeverity == .severe)
    }

    @Test func anEmptyColumnWhoseCostImprovesForeverIsAWarning() async {
        // Column 1 is empty with cost −1 and no upper bound (minimization).
        let lp = ConditioningProblems.make(rows: [[1, 0], [2, 0]], c: [1, -1])
        let report = await ConditioningAnalyzer.analyze(lp)
        #expect(report.first { $0 == .emptyColumn(1) }?.severity == .warning)
        // With an upper bound it is only a structural remark.
        let bounded = ConditioningProblems.make(rows: [[1, 0], [2, 0]], c: [1, -1], xu: [.infinity, 4])
        #expect(await ConditioningAnalyzer.analyze(bounded).first { $0 == .emptyColumn(1) }?.severity == .info)
    }

    // MARK: nearParallelRows — |cos| > 1 − 1e-9

    @Test func parallelAndAntiParallelRowsAreFound() async {
        let lp = ConditioningProblems.make(rows: [
            [1, 2, 3, 0],                 // 0
            [3, 6, 9, 0],                 // 1: 3 × row 0
            [-2, -4, -6, 0],              // 2: −2 × row 0
            [1, 2, 3.001, 0],             // 3: 1 − cos ≈ 2e-8, not near enough
            [1, 2, 0, 3],                 // 4: another pattern
            [1, 2, 3 * (1 + 1e-7), 0],    // 5: 1 − cos ≈ 1e-15
            [0, 0, 5, 0],                 // 6: singleton rows are bounds, not candidates
            [0, 0, 7, 0],                 // 7
        ])
        let report = await ConditioningAnalyzer.analyze(lp)
        var pairs: [[Int]] = []
        for finding in report.findings {
            guard case .nearParallelRows(let i, let j, let cosine) = finding.kind else { continue }
            pairs.append([i, j])
            #expect(finding.severity == .warning)
            #expect(abs(cosine) > 1 - 1e-9)
            if j == 2 {
                #expect(cosine < 0)
                #expect(finding.message.contains("anti-parallel"))
            } else {
                #expect(cosine > 0)
            }
        }
        // Each row of the group is paired with the group's first row.
        #expect(pairs == [[0, 1], [0, 2], [0, 5]])
    }

    @Test func rowsThatOnlyShareAPatternAreNotParallel() async {
        var rng = SeededGenerator(seed: 5)
        let rows = (0..<200).map { _ in (0..<6).map { _ in rng.uniform(in: 1...2) } }
        let report = await ConditioningAnalyzer.analyze(ConditioningProblems.make(rows: rows))
        #expect(!report.kinds.contains { if case .nearParallelRows = $0 { return true } else { return false } })
    }

    // MARK: freeColumn, fixedColumn

    @Test func freeAndFixedColumnsAreReported() async {
        let lp = ConditioningProblems.make(
            rows: [[1, 1, 1, 1], [1, 2, 3, 4]], xl: [-.infinity, 2, 0, -.infinity],
            xu: [.infinity, 2, 7, 3])
        let report = await ConditioningAnalyzer.analyze(lp)
        #expect(report.kinds.contains(.freeColumn(0)))
        #expect(report.kinds.contains(.fixedColumn(1)))
        // A column bounded on one side or boxed is neither.
        #expect(!report.kinds.contains(.freeColumn(3)) && !report.kinds.contains(.fixedColumn(2)))
        #expect(report.first { $0 == .fixedColumn(1) }?.message.contains("2") == true)
    }

    // MARK: denseColumn — more than 30% nonzeros

    @Test func denseColumnsAreReportedAboveThirtyPercent() async {
        // Ten rows: column 0 has 4 entries (40%), column 1 has 3 (30%, not above), column 2 has 1.
        var rows = [[Double]](repeating: [0, 0, 0], count: 10)
        for i in 0..<4 { rows[i][0] = 1 }
        for i in 4..<7 { rows[i][1] = 1 }
        rows[9][2] = 1
        let report = await ConditioningAnalyzer.analyze(ConditioningProblems.make(rows: rows))
        let dense = report.findings.filter { if case .denseColumn = $0.kind { return true } else { return false } }
        #expect(dense.count == 1)
        #expect(dense.first?.kind == .denseColumn(0, density: 0.4))
        // Up to 300 rows the interior point factors a dense matrix anyway: information only.
        #expect(dense.first?.severity == .info)
    }

    @Test func aDenseColumnOfALargerProblemIsAWarning() async {
        // 400 rows, each with its own column; column 0 is in 150 of them (37.5%).
        let m = 400
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { entries.append((i, i + 1, 1)) }
        for i in 0..<150 { entries.append((i, 0, 2)) }
        let n = m + 1
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 0, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
        let report = await ConditioningAnalyzer.analyze(lp)
        let finding = report.first { if case .denseColumn = $0 { return true } else { return false } }
        #expect(finding?.kind == .denseColumn(0, density: 0.375))
        #expect(finding?.severity == .warning)
    }

    // MARK: Suggested scaling

    @Test func suggestedScalingIsTheEnginesScaling() async {
        let instance = InstanceGenerator.constructedOptimum(rows: 30, columns: 45, seed: 3)
        var options = ConstructedOptions()
        options.scaleSpread = 3
        let spread = InstanceGenerator.constructedOptimum(rows: 30, columns: 45, seed: 4, options: options)
        for lp in [instance.lp, spread.lp] {
            let report = await ConditioningAnalyzer.analyze(lp)
            let expected = Scaler.factors(for: lp, mode: .geometricEquilibration)
            #expect(report.suggestedScaling.rows == expected.rows)
            #expect(report.suggestedScaling.columns == expected.columns)
            // Powers of two only.
            for factor in report.suggestedScaling.rows + report.suggestedScaling.columns {
                #expect(factor > 0 && factor.significand == 1)
            }
        }
    }

    @Test func aScaledWorkingCopyCanBeAnalyzedToo() async {
        var options = ConstructedOptions()
        options.scaleSpread = 4
        let lp = InstanceGenerator.constructedOptimum(rows: 40, columns: 60, seed: 8, options: options).lp
        let before = await ConditioningAnalyzer.analyze(lp)
        let scaled = Scaler.scale(lp, mode: .geometricEquilibration)
        let after = await ConditioningAnalyzer.analyze(scaled)
        // Scaling is what the report recommends, and it does narrow the matrix range.
        #expect(ConditioningReport.ratio(after.coefficientRange.matrix) < ConditioningReport.ratio(before.coefficientRange.matrix))
        #expect(after.coefficientRange.matrix.upperBound <= 2)
        // For the working copy the report shows the scale vectors it carries (§5.4): the
        // factors that were applied, which are the ones suggested for the original.
        #expect(!before.scalingIsApplied && after.scalingIsApplied)
        #expect(after.suggestedScaling.rows == scaled.scaling?.rows)
        #expect(after.suggestedScaling.columns == scaled.scaling?.columns)
        #expect(after.suggestedScaling.rows == before.suggestedScaling.rows)
        #expect(after.suggestedScaling.columns == before.suggestedScaling.columns)
        #expect(before.markdown.contains("## Suggested scaling"))
        #expect(after.markdown.contains("## Applied scaling"))
    }

    // MARK: Limits and ordering

    @Test func findingsOfOneKindAreCapped() async {
        // 250 free columns.
        let n = 250
        let lp = ConditioningProblems.make(
            rows: [[Double](repeating: 1, count: n), (0..<n).map { Double($0 + 1) }],
            xl: [Double](repeating: -.infinity, count: n))
        var options = ConditioningAnalyzer.Options()
        options.maxFindingsPerKind = 100
        let report = await ConditioningAnalyzer.analyze(lp, options: options)
        let free = report.kinds.filter { if case .freeColumn = $0 { return true } else { return false } }
        // The first hundred, in index order; the rest are counted, not dropped silently.
        #expect(free == (0..<100).map { Finding.Kind.freeColumn($0) })
        // 150 free columns beyond the limit, plus the dense columns beyond it (every column
        // is in both rows).
        #expect(report.omittedFindings == 150 + 150)
        #expect(report.markdown.contains("… and 300 more findings"))

        options.maxFindingsPerKind = 1_000
        let full = await ConditioningAnalyzer.analyze(lp, options: options)
        #expect(full.omittedFindings == 0)
        #expect(full.kinds.filter { if case .freeColumn = $0 { return true } else { return false } }.count == 250)
    }

    @Test func findingsAreOrderedBySeverityThenByKind() async {
        // severe: an empty row excluding zero; warning: a big-M; info: a free column and a singleton row.
        let lp = ConditioningProblems.make(
            rows: [[1, -1e6, 0], [0, 0, 0], [0, 0, 4], [1, 1, 1]], xl: [0, 0, -.infinity],
            xu: [.infinity, 1, .infinity], rl: [-.infinity, 3, 0, 0], ru: [0, 4, 9, 9], integer: [1])
        let report = await ConditioningAnalyzer.analyze(lp)
        let severities = report.findings.map(\.severity)
        #expect(severities == severities.sorted(by: >))
        #expect(report.findings.first?.kind == .emptyRow(1))
        #expect(report.worstSeverity == .severe)
        // Within the info findings: singleton row before free column, as in the specification's list.
        let info = report.findings(of: .info).map(\.kind)
        let singleton = info.firstIndex(of: .singletonRow(2))
        let free = info.firstIndex(of: .freeColumn(2))
        #expect(singleton != nil && free != nil && singleton! < free!)
    }

    // MARK: Parallel row statistics

    @Test func parallelRowStatisticsMatchTheSequentialOnes() async {
        // 20,000 rows with planted defects: empty rows, singleton rows, big-M rows, parallel pairs.
        var rng = SeededGenerator(seed: 17)
        let m = 20_000
        let n = 400
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m {
            switch i % 97 {
            case 0:
                continue                                              // empty
            case 1:
                entries.append((i, rng.integer(in: 0...(n - 1)), 2))  // singleton
            case 2:
                // big-M on the binary column 0
                entries.append((i, 0, -1e5))
                entries.append((i, 1 + rng.integer(in: 0...(n - 2)), 1))
            case 3, 4:
                // rows 97k+3 and 97k+4 are multiples of each other
                let base = (i / 97) % (n - 3) + 1
                let scale = i % 97 == 3 ? 1.0 : -2.5
                entries.append((i, base, 1 * scale))
                entries.append((i, base + 1, 3 * scale))
                entries.append((i, base + 2, -2 * scale))
            default:
                for _ in 0..<4 { entries.append((i, 1 + rng.integer(in: 0...(n - 2)), rng.uniform(in: 0.5...2))) }
            }
        }
        var xu = [Double](repeating: .infinity, count: n)
        xu[0] = 1
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 0, count: n),
            xl: [Double](repeating: 0, count: n), xu: xu, rl: [Double](repeating: 0, count: m),
            ru: [Double](repeating: 10, count: m), integerColumns: [0])

        var options = ConditioningAnalyzer.Options()
        options.maxFindingsPerKind = 10_000
        var sequentialContext = SolveContext()
        sequentialContext.threads = 1
        let sequential = await ConditioningAnalyzer.analyze(lp, context: sequentialContext, options: options)
        var parallelContext = SolveContext()
        parallelContext.threads = 8
        let parallel = await ConditioningAnalyzer.analyze(lp, context: parallelContext, options: options)

        // Same findings, in the same order, whatever the number of threads.
        #expect(parallel.findings == sequential.findings)
        #expect(parallel.omittedFindings == sequential.omittedFindings)

        let planted = m / 97 + 1            // residues 0…4 each occur 207 times in 0..<20,000
        func count(_ predicate: (Finding.Kind) -> Bool) -> Int { sequential.kinds.filter(predicate).count }
        #expect(count { if case .emptyRow = $0 { return true } else { return false } } == planted)
        #expect(count { if case .singletonRow = $0 { return true } else { return false } } == planted)
        #expect(count { if case .bigM = $0 { return true } else { return false } } == planted)
        // Every planted pair is found; rows 3 and 4 of different groups can coincide in
        // direction too (the pattern repeats), so there are at least `planted` pairs.
        #expect(count { if case .nearParallelRows = $0 { return true } else { return false } } >= planted)
    }

    @Test func rowBlocksStayWithinTheConcurrencyBudget() async {
        // Rule C7: with threads = 2 at most two tasks are ever in flight, and every borrowed
        // slot is given back.
        let m = 16_000
        var rng = SeededGenerator(seed: 23)
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m {
            for _ in 0..<3 { entries.append((i, rng.integer(in: 0...199), rng.uniform(in: 0.5...2))) }
        }
        let n = 200
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 0, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 5, count: n),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 10, count: m))
        let budget = ConcurrencyBudget(threads: 2)
        let shared = await ConditioningAnalyzer.analyze(lp, budget: budget)
        #expect(await budget.peakInUse == 2)
        #expect(await budget.slotsInUse == 1)

        // A budget with no free slot runs every block on the calling task, with the same result.
        let full = ConcurrencyBudget(threads: 4, occupied: 4)
        let inline = await ConditioningAnalyzer.analyze(lp, budget: full)
        #expect(await full.peakInUse == 4)
        #expect(await full.slotsInUse == 4)
        #expect(inline.findings == shared.findings)
    }

    @Test func thePerKindLimitHoldsAcrossRowBlocks() async {
        // 12,000 singleton rows analyzed in parallel blocks: 50 are listed, the rest are counted.
        let m = 12_000
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { entries.append((i, i % 30, 1)) }
        let n = 30
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 0, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 5, count: n),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 10, count: m))
        var options = ConditioningAnalyzer.Options()
        options.maxFindingsPerKind = 50
        var context = SolveContext()
        context.threads = 6
        let report = await ConditioningAnalyzer.analyze(lp, context: context, options: options)
        let singletons = report.kinds.filter { if case .singletonRow = $0 { return true } else { return false } }
        #expect(singletons == (0..<50).map { Finding.Kind.singletonRow($0) })
        // 11,950 singleton rows are not listed. Nothing else is omitted: each column is in
        // 400 of the 12,000 rows (3.3%), far from dense.
        #expect(report.omittedFindings == m - 50)
    }
}
