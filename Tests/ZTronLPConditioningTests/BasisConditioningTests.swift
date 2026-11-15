// The basis half of the conditioning analyzer (specification §13): the 1-norm condition
// estimate, its thresholds and its 4,000-row limit, the degeneracy finding, the report text
// and the `ConditionedAnalysis` decorator (§11.3).

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPConditioning

@Suite struct BasisConditioningTests {
    private static func isIllConditioned(_ kind: Finding.Kind) -> Bool {
        if case .illConditionedBasis = kind { return true }
        return false
    }

    private static func isDegenerate(_ kind: Finding.Kind) -> Bool {
        if case .degenerateBasis = kind { return true }
        return false
    }

    // MARK: Condition estimate

    @Test func theEstimateOfADiagonalBasisIsItsConditionNumber() async throws {
        // κ₁(diag(d)) = max|d| / min|d| = 4 / 1e-3.
        let lp = ConditioningProblems.diagonal([1, -2, 0.5, 4, 1e-3])
        let report = await ConditioningAnalyzer.analyze(lp, basis: ConditioningProblems.structuralBasis(lp))
        #expect(report.basisAnalysis == .analyzed)
        let kappa = try #require(report.basisConditionEstimate)
        #expect(abs(kappa - 4_000) <= 1e-9 * 4_000)
        #expect(!report.kinds.contains(where: Self.isIllConditioned))

        // The all-logical basis is −I: perfectly conditioned.
        let logical = await ConditioningAnalyzer.analyze(lp, basis: .allLogical(for: lp))
        #expect(abs(try #require(logical.basisConditionEstimate) - 1) <= 1e-12)
    }

    @Test func theEstimateAgreesWithTheExplicitInverse() async throws {
        // A mixed basis of a random problem: five structural columns and three logical ones.
        let m = 8
        var rng = SeededGenerator(seed: 41)
        var rows = [[Double]](repeating: [Double](repeating: 0, count: 6), count: m)
        for i in 0..<m {
            for j in 0..<6 { rows[i][j] = rng.uniform(in: -2...2) }
        }
        let lp = ConditioningProblems.make(rows: rows)
        var status = [BasisStatus](repeating: .atLower, count: lp.n + lp.m)
        let basic: [Int32] = [0, 1, 2, 3, 4, Int32(lp.n + 5), Int32(lp.n + 6), Int32(lp.n + 7)]
        for column in basic { status[Int(column)] = .basic }
        let report = await ConditioningAnalyzer.analyze(lp, basis: Basis(status: status, basic: basic))
        let estimate = try #require(report.basisConditionEstimate)

        // κ₁(B) = ‖B‖₁ · ‖B⁻¹‖₁ with the inverse computed column by column.
        var b = DenseMatrix(rows: m, cols: m)
        for (k, column) in basic.enumerated() {
            let j = Int(column)
            if j < lp.n {
                for i in 0..<m { b[i, k] = rows[i][j] }
            } else {
                b[j - lp.n, k] = -1
            }
        }
        var inverseNorm = 0.0
        for k in 0..<m {
            var unit = [Double](repeating: 0, count: m)
            unit[k] = 1
            let column = try #require(denseSolve(b, unit))
            inverseNorm = max(inverseNorm, column.reduce(0) { $0 + abs($1) })
        }
        let exact = b.oneNorm() * inverseNorm
        // dgecon estimates ‖B⁻¹‖₁ from below, and is rarely off by more than a small factor.
        #expect(estimate <= exact * (1 + 1e-9))
        #expect(estimate >= exact / 10)
    }

    // MARK: illConditionedBasis — warning > 1e8, severe > 1e12

    @Test(arguments: [
        (5e7, nil), (5e8, Finding.Severity.warning), (5e11, Finding.Severity.warning),
        (5e12, Finding.Severity.severe), (5e15, Finding.Severity.severe),
    ] as [(Double, Finding.Severity?)])
    func illConditionedBasisThresholds(_ kappa: Double, _ expected: Finding.Severity?) async throws {
        let lp = ConditioningProblems.diagonal([1, 1, 1 / kappa, 1])
        let report = await ConditioningAnalyzer.analyze(lp, basis: ConditioningProblems.structuralBasis(lp))
        let estimate = try #require(report.basisConditionEstimate)
        #expect(abs(estimate - kappa) <= 1e-6 * kappa)
        let finding = report.findings.first { Self.isIllConditioned($0.kind) }
        #expect(finding?.severity == expected)
        if let finding, case .illConditionedBasis(let reported) = finding.kind {
            #expect(reported == estimate)
        }
        // The thresholds themselves.
        #expect(ConditioningAnalyzer.illConditionedWarning == 1e8)
        #expect(ConditioningAnalyzer.illConditionedSevere == 1e12)
    }

    @Test func aSingularBasisIsSevere() async {
        // Column 1 is empty, so the all-structural basis is singular.
        let lp = ConditioningProblems.make(rows: [[1, 0], [0, 0]])
        let report = await ConditioningAnalyzer.analyze(lp, basis: ConditioningProblems.structuralBasis(lp))
        #expect(report.basisAnalysis == .analyzed)
        #expect(report.basisConditionEstimate == .infinity)
        let finding = report.findings.first { Self.isIllConditioned($0.kind) }
        #expect(finding?.severity == .severe)
        #expect(finding?.message.contains("singular") == true)
    }

    // MARK: Limits of the dense estimate

    @Test func theEstimateIsSkippedAboveFourThousandRows() async {
        #expect(ConditioningAnalyzer.maxRowsForConditionEstimate == 4_000)
        let m = 4_001
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { entries.append((i, i, 1e-10)) }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: [Double](repeating: 0, count: m),
            xl: [Double](repeating: 0, count: m), xu: [Double](repeating: 10, count: m),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
        // The all-structural basis would be badly scaled, but nobody factors 4,001 × 4,001.
        let basis = ConditioningProblems.structuralBasis(lp)
        let report = await ConditioningAnalyzer.analyze(lp, basis: basis)
        #expect(report.basisAnalysis == .tooManyRows(m))
        #expect(report.basisConditionEstimate == nil)
        #expect(!report.kinds.contains(where: Self.isIllConditioned))
        #expect(report.markdown.contains("4,000-row limit"))

        // The degeneracy can still be read off a solution: every basic column sits at zero.
        let solved = await ConditioningAnalyzer.analyze(lp, basis: basis, primal: [Double](repeating: 0, count: m))
        #expect(solved.kinds.contains(.degenerateBasis(fraction: 1)))
    }

    @Test func theEstimateRespectsTheMemoryBudget() async {
        let m = 600
        var d = [Double](repeating: 1, count: m)
        d[7] = 1e-10
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { entries.append((i, i, d[i])) }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: [Double](repeating: 0, count: m),
            xl: [Double](repeating: 0, count: m), xu: [Double](repeating: 10, count: m),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 1, count: m))
        let basis = ConditioningProblems.structuralBasis(lp)
        // Factoring needs two m × m matrices: 5.76 MB. A 1 MB budget degrades to "no estimate".
        var tight = SolveContext()
        tight.memoryBudgetBytes = 1 << 20
        let skipped = await ConditioningAnalyzer.analyze(lp, basis: basis, context: tight)
        #expect(skipped.basisAnalysis == .overMemoryBudget)
        #expect(skipped.basisConditionEstimate == nil)
        // With room, the same call estimates κ = 1e10.
        var roomy = SolveContext()
        roomy.memoryBudgetBytes = 64 << 20
        let analyzed = await ConditioningAnalyzer.analyze(lp, basis: basis, context: roomy)
        #expect(analyzed.basisAnalysis == .analyzed)
        #expect(analyzed.findings.first { Self.isIllConditioned($0.kind) }?.severity == .warning)
    }

    @Test func aBasisThatDoesNotFitTheProblemIsIgnored() async {
        let lp = ConditioningProblems.diagonal([1, 2, 3])
        let good = ConditioningProblems.structuralBasis(lp)
        let tooShort = Basis(status: Array(good.status.dropLast()), basic: good.basic)
        let tooFew = Basis(status: good.status, basic: [0, 1])
        let repeated = Basis(status: good.status, basic: [0, 1, 1])
        let outOfRange = Basis(status: good.status, basic: [0, 1, 6])
        for basis in [tooShort, tooFew, repeated, outOfRange] {
            let report = await ConditioningAnalyzer.analyze(lp, basis: basis)
            #expect(report.basisAnalysis == .invalidBasis)
            #expect(report.basisConditionEstimate == nil)
        }
        #expect(await ConditioningAnalyzer.analyze(lp).basisAnalysis == .noBasis)
    }

    // MARK: degenerateBasis — warning > 30%

    @Test func degenerateBasisFromASolution() async {
        // x ∈ [0, 10]⁴ with the identity as constraint matrix; every structural column is basic.
        let lp = ConditioningProblems.make(
            rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], xu: [10, 10, 10, 10])
        let cases: [(x: [Double], fraction: Double, severity: Finding.Severity?)] = [
            ([0, 0, 5, 5], 0.5, .warning),      // two of four on their lower bound
            ([0, 3, 5, 5], 0.25, .info),        // one of four: reported, not yet a warning
            ([1, 3, 5, 5], 0, nil),             // none: no finding at all
            ([0, 0, 0, 10], 1, .warning),       // upper bounds count as well
        ]
        for (x, fraction, severity) in cases {
            let report = await ConditioningAnalyzer.analyze(
                lp, basis: ConditioningProblems.structuralBasis(lp), primal: x)
            let finding = report.findings.first { Self.isDegenerate($0.kind) }
            #expect(finding?.severity == severity, "x = \(x)")
            if let finding { #expect(finding.kind == .degenerateBasis(fraction: fraction)) }
        }
    }

    @Test func degenerateBasisIsRecomputedFromTheBasisWithoutASolution() async {
        // The logicals rest on the row lower bounds, so x_B = B⁻¹·r_l = (0, 0, 5, 5): two of
        // the four basic columns sit on their lower bound 0.
        let lp = ConditioningProblems.make(
            rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], xu: [10, 10, 10, 10],
            rl: [0, 0, 5, 5])
        let report = await ConditioningAnalyzer.analyze(lp, basis: ConditioningProblems.structuralBasis(lp))
        #expect(report.kinds.contains(.degenerateBasis(fraction: 0.5)))

        // Basic logicals count as well: at x = 0 the first row's activity is on its lower bound.
        let rows = ConditioningProblems.make(rows: [[1, 1], [1, -1]], rl: [0, -5], ru: [4, 5])
        let logical = await ConditioningAnalyzer.analyze(rows, basis: .allLogical(for: rows))
        #expect(logical.kinds.contains(.degenerateBasis(fraction: 0.5)))
    }

    @Test func exactlyThirtyPercentIsNotYetAWarning() async {
        let n = 10
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { rows[i][i] = 1 }
        let lp = ConditioningProblems.make(rows: rows, xu: [Double](repeating: 10, count: n))
        var x = [Double](repeating: 4, count: n)
        for j in 0..<3 { x[j] = 0 }
        let basis = ConditioningProblems.structuralBasis(lp)
        let three = await ConditioningAnalyzer.analyze(lp, basis: basis, primal: x)
        #expect(three.findings.first { Self.isDegenerate($0.kind) }?.severity == .info)
        x[3] = 10
        let four = await ConditioningAnalyzer.analyze(lp, basis: basis, primal: x)
        #expect(four.findings.first { Self.isDegenerate($0.kind) }?.severity == .warning)
        #expect(ConditioningAnalyzer.degenerateBasisFraction == 0.30)
    }

    // MARK: After a solve

    @Test func analyzeAfterTakesTheBasisAndTheSolutionFromTheAnalysis() async {
        let lp = ConditioningProblems.make(
            rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], xu: [10, 10, 10, 10])
        let record = SolveRecord(status: .optimal, objectiveValue: 0, bound: 0, primal: [0, 0, 5, 5])
        let simplexLike = BasisCarryingAnalysis(base: record, basis: ConditioningProblems.structuralBasis(lp))
        let withBasis = await ConditioningAnalyzer.analyze(lp, after: simplexLike)
        #expect(withBasis.basisAnalysis == .analyzed)
        #expect(withBasis.kinds.contains(.degenerateBasis(fraction: 0.5)))

        // An analysis that has no basis to offer (a CP-SAT result, a failed solve).
        let withoutBasis = await ConditioningAnalyzer.analyze(lp, after: PlainAnalysis(base: record))
        #expect(withoutBasis.basisAnalysis == .noBasis)
        #expect(withoutBasis.basisConditionEstimate == nil)
        // Through the type erasure of `Automatic` the basis is still found.
        let erased = AnySolutionAnalysis(simplexLike, engine: "Simplex")
        #expect(await ConditioningAnalyzer.analyze(lp, after: erased).basisAnalysis == .analyzed)
    }

    // MARK: Report text

    @Test func markdownHasEverySection() async {
        let lp = ConditioningProblems.make(
            rows: [[1, -0.5, 0], [0, 4, 200], [1e-9, 0, 1]], c: [0, -3, 0.25], xl: [0, -.infinity, 1],
            xu: [.infinity, .infinity, 100], rl: [-.infinity, 2, 0], ru: [10, .infinity, 1])
        var status = [BasisStatus](repeating: .atLower, count: 6)
        let basic: [Int32] = [0, 1, 2]
        for column in basic { status[Int(column)] = .basic }
        let report = await ConditioningAnalyzer.analyze(lp, basis: Basis(status: status, basic: basic))
        let text = report.markdown
        #expect(text.hasPrefix("# Conditioning report\n"))
        #expect(text.contains("Problem: 3 rows × 3 columns, 6 nonzeros."))
        #expect(text.contains("## Coefficient ranges"))
        #expect(text.contains("| Quantity | Smallest | Largest | Ratio |"))
        #expect(text.contains("| Matrix coefficients | 1e-09 | 200 | 2e+11 |"))
        #expect(text.contains("| Objective coefficients | 0.25 | 3 | 12 |"))
        #expect(text.contains("| Right-hand sides | 1 | 10 | 10 |"))
        #expect(text.contains("| Bounds | 1 | 100 | 100 |"))
        #expect(text.contains("## Suggested scaling"))
        #expect(text.contains("## Basis"))
        #expect(text.contains("κ₁(B) ≈"))
        #expect(text.contains("## Findings"))
        #expect(text.contains("- **severe** — the matrix coefficients span 1e-09 to 200, a ratio of 2e+11"))
        #expect(text.contains("- **info** — column x2 has no bounds"))
        #expect(text.hasSuffix("\n"))
        // Every finding is listed, most severe first.
        let listed = text.split(separator: "\n").filter { $0.hasPrefix("- **") }
        #expect(listed.count == report.findings.count)
        #expect(listed.first?.hasPrefix("- **severe**") == true)

        // The one-line form quoted by SolverEvent.warning.
        #expect(report.summary.contains("matrix coefficients span 1e-09 to 200 (ratio 2e+11)"))
        #expect(report.summary.contains("basis condition estimate"))
        #expect(report.summary.contains("worst: the matrix coefficients span"))
        #expect(!report.summary.contains("\n"))
    }

    @Test func markdownOfACleanProblem() async {
        let lp = ConditioningProblems.make(rows: [[1, 2], [3, 1]], c: [1, 1], rl: [1, 1], ru: [4, 4])
        let report = await ConditioningAnalyzer.analyze(lp)
        #expect(report.markdown.contains("No basis was supplied."))
        #expect(report.findings.allSatisfy { $0.severity == .info })
        #expect(report.summary.contains("no warnings"))
        // Without any finding at all the section says so.
        let empty = ConditioningReport(
            coefficientRange: (1...2, 0...0, 0...0, 0...0), suggestedScaling: ([1], [1]), basisConditionEstimate: nil,
            findings: [])
        #expect(empty.markdown.contains("## Findings\n\nNone.\n"))
        #expect(empty.markdown.contains("| Objective coefficients | — | — | — |"))
    }

    // MARK: ConditionedAnalysis (§11.3)

    @Test func conditionedAnalysisForwardsTheWrappedAnalysis() async {
        let lp = ConditioningProblems.diagonal([1, 2])
        let basis = ConditioningProblems.structuralBasis(lp)
        let record = SolveRecord(
            status: .feasible(stoppedBy: .timeLimit), objectiveValue: 3, bound: 2.5, primal: [1, 2], dual: [0.5, 0],
            reducedCosts: [0, 0, 0.5, 0], seconds: 0.25, warnings: ["slow"])
        let report = await ConditioningAnalyzer.analyze(lp, basis: basis)
        let conditioned = ConditionedAnalysis(base: BasisCarryingAnalysis(base: record, basis: basis), report: report)

        // Every SolutionAnalysis property reads exactly as on the wrapped analysis.
        #expect(conditioned.status == .feasible(stoppedBy: .timeLimit))
        #expect(conditioned.objectiveValue == 3)
        #expect(conditioned.bound == 2.5)
        #expect(conditioned.primal == [1, 2])
        #expect(conditioned.dual == [0.5, 0])
        #expect(conditioned.reducedCosts == [0, 0, 0.5, 0])
        #expect(conditioned.seconds == 0.25)
        #expect(conditioned.warnings == ["slow"])
        // The engine's own details stay reachable, and so does the report.
        #expect(conditioned.base.basis == basis)
        #expect(conditioned.report.basisAnalysis == .analyzed)

        // The basis is forwarded when the wrapped analysis has one …
        #expect(conditioned.finalBasis == basis)
        let erased = AnySolutionAnalysis(conditioned, engine: "Conditioned")
        #expect(erased.finalBasis == basis)
        #expect(erased.unwrap(as: ConditionedAnalysis<BasisCarryingAnalysis>.self)?.report.dimensions.rows == 2)
        // … and only then.
        let plain = ConditionedAnalysis(base: PlainAnalysis(base: record), report: report)
        #expect(!((plain as Any) is any BasisProviding))
        #expect(AnySolutionAnalysis(plain, engine: "Conditioned").finalBasis == nil)
        #expect(plain.status == record.status)
    }
}
