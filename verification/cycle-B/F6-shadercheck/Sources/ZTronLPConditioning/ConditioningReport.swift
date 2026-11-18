// ConditioningReport and Finding (specification §13).
//
// The report says why a model is slow or numerically fragile, before or after a solve. It is
// also what `SolverEvent.warning` quotes when a solve ends in `.numericalFailure`
// (`summary` is the one-line form for that).

import Foundation
import ZTronLPCore

/// One observation about a model or a basis.
public struct Finding: Sendable, Hashable {
    /// How much the observation matters.
    public enum Severity: Int, Sendable, Hashable, Comparable {
        case info, warning, severe

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: Sendable, Hashable {
        /// The largest and smallest magnitudes of one group of coefficients are far apart:
        /// warning > 1e6, severe > 1e9.
        case wideCoefficientRange(ratio: Double)
        /// A coefficient ≥ 1e4 × the row median on a binary column.
        case bigM(row: Int, column: Int, ratio: Double)
        /// A row with no entries.
        case emptyRow(Int)
        /// A column with no entries.
        case emptyColumn(Int)
        /// A row with one entry: a bound written as a constraint.
        case singletonRow(Int)
        /// Two rows with |cos| > 1 − 1e-9 after normalization, found by hashing scaled rows.
        case nearParallelRows(Int, Int, cosine: Double)
        /// A column with no bounds.
        case freeColumn(Int)
        /// A column whose bounds coincide.
        case fixedColumn(Int)
        /// A column with more than 30% nonzeros, relevant to the interior point (§8.3).
        case denseColumn(Int, density: Double)
        /// Basics at a bound after a solve; warning > 30%.
        case degenerateBasis(fraction: Double)
        /// The 1-norm condition estimate of the basis: warning > 1e8, severe > 1e12.
        case illConditionedBasis(kappa: Double)
    }

    public let severity: Severity
    public let kind: Kind
    public let message: String

    public init(severity: Severity, kind: Kind, message: String) {
        self.severity = severity
        self.kind = kind
        self.message = message
    }
}

extension Finding.Kind {
    /// The position of the case in the specification's list; findings of equal severity are
    /// reported in this order.
    var category: Int {
        switch self {
        case .wideCoefficientRange: return 0
        case .bigM: return 1
        case .emptyRow: return 2
        case .emptyColumn: return 3
        case .singletonRow: return 4
        case .nearParallelRows: return 5
        case .freeColumn: return 6
        case .fixedColumn: return 7
        case .denseColumn: return 8
        case .degenerateBasis: return 9
        case .illConditionedBasis: return 10
        }
    }

    static let categoryCount = 11
}

/// What the analyzer did with the basis it was given.
public enum BasisAnalysisOutcome: Sendable, Hashable {
    /// No basis was supplied.
    case noBasis
    /// The basis does not fit the problem (wrong sizes or indices out of range).
    case invalidBasis
    /// More than 4,000 rows: the dense factorization is skipped.
    case tooManyRows(Int)
    /// The dense factorization would not fit the memory budget.
    case overMemoryBudget
    /// The basis was factored and its condition number estimated.
    case analyzed
}

/// Why a model is slow or numerically fragile.
public struct ConditioningReport: Sendable {
    /// Smallest and largest magnitude per group, zeros (and infinite bounds) excluded. A group
    /// with no nonzero value at all reports `0...0`.
    public let coefficientRange: (
        matrix: ClosedRange<Double>, objective: ClosedRange<Double>, rhs: ClosedRange<Double>,
        bounds: ClosedRange<Double>
    )
    /// The scale vectors of §5.4, every one a power of two. For a problem as compiled these
    /// are the geometric-mean plus equilibration factors the engines would apply; for an
    /// engine's scaled working copy they are the factors stored in `CompiledLP.scaling`, the
    /// ones that were applied (`scalingIsApplied`).
    public let suggestedScaling: (rows: [Double], columns: [Double])
    /// 1-norm κ(B) from `dgecon`, when a basis is given and m ≤ 4,000.
    public let basisConditionEstimate: Double?
    /// Most severe first; within one severity in the order of the specification's list.
    public let findings: [Finding]

    /// Findings that exist but are not listed, because one kind had more than the analyzer's
    /// per-kind limit.
    public let omittedFindings: Int
    /// What happened to the basis analysis.
    public let basisAnalysis: BasisAnalysisOutcome
    /// The size of the analyzed problem.
    public let dimensions: (rows: Int, columns: Int, nonzeros: Int)
    /// True when the analyzed problem was a scaled working copy, so `suggestedScaling` holds
    /// the factors already applied to it rather than a suggestion.
    public let scalingIsApplied: Bool

    public init(
        coefficientRange: (
            matrix: ClosedRange<Double>, objective: ClosedRange<Double>, rhs: ClosedRange<Double>,
            bounds: ClosedRange<Double>
        ),
        suggestedScaling: (rows: [Double], columns: [Double]), basisConditionEstimate: Double?,
        findings: [Finding], omittedFindings: Int = 0, basisAnalysis: BasisAnalysisOutcome = .noBasis,
        dimensions: (rows: Int, columns: Int, nonzeros: Int) = (0, 0, 0), scalingIsApplied: Bool = false
    ) {
        self.coefficientRange = coefficientRange
        self.suggestedScaling = suggestedScaling
        self.basisConditionEstimate = basisConditionEstimate
        self.findings = findings
        self.omittedFindings = omittedFindings
        self.basisAnalysis = basisAnalysis
        self.dimensions = dimensions
        self.scalingIsApplied = scalingIsApplied
    }

    /// The most severe finding's severity; `nil` when there are no findings.
    public var worstSeverity: Finding.Severity? {
        findings.map(\.severity).max()
    }

    /// The findings of one severity.
    public func findings(of severity: Finding.Severity) -> [Finding] {
        findings.filter { $0.severity == severity }
    }

    /// `max / min` of a range; 1 for the empty range `0...0`.
    public static func ratio(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound > 0 ? range.upperBound / range.lowerBound : 1
    }

    /// One line for logs and for `SolverEvent.warning`.
    public var summary: String {
        var parts: [String] = []
        let matrix = coefficientRange.matrix
        if matrix.upperBound > 0 {
            parts.append(
                "matrix coefficients span \(Self.format(matrix.lowerBound)) to \(Self.format(matrix.upperBound)) (ratio \(Self.format(Self.ratio(matrix))))")
        }
        if let kappa = basisConditionEstimate {
            parts.append("basis condition estimate \(Self.format(kappa))")
        }
        let severe = findings(of: .severe).count
        let warnings = findings(of: .warning).count
        if severe + warnings > 0 {
            parts.append("\(severe) severe and \(warnings) warning finding\(severe + warnings == 1 ? "" : "s")")
        } else {
            parts.append("no warnings")
        }
        if let first = findings.first, first.severity >= .warning {
            parts.append("worst: \(first.message)")
        }
        return parts.joined(separator: "; ")
    }

    /// The report as Markdown.
    public var markdown: String {
        var lines: [String] = []
        lines.append("# Conditioning report")
        lines.append("")
        lines.append("Problem: \(dimensions.rows) rows × \(dimensions.columns) columns, \(dimensions.nonzeros) nonzeros.")
        lines.append("")
        lines.append("## Coefficient ranges")
        lines.append("")
        lines.append("| Quantity | Smallest | Largest | Ratio |")
        lines.append("| --- | --- | --- | --- |")
        func row(_ title: String, _ range: ClosedRange<Double>) -> String {
            guard range.upperBound > 0 else { return "| \(title) | — | — | — |" }
            return "| \(title) | \(Self.format(range.lowerBound)) | \(Self.format(range.upperBound)) | \(Self.format(Self.ratio(range))) |"
        }
        lines.append(row("Matrix coefficients", coefficientRange.matrix))
        lines.append(row("Objective coefficients", coefficientRange.objective))
        lines.append(row("Right-hand sides", coefficientRange.rhs))
        lines.append(row("Bounds", coefficientRange.bounds))
        lines.append("")
        lines.append(scalingIsApplied ? "## Applied scaling" : "## Suggested scaling")
        lines.append("")
        lines.append(
            scalingIsApplied
                ? "This is a scaled working copy; the factors applied to it (powers of two, §5.4):"
                : "Geometric-mean scaling followed by equilibration, rounded to powers of two (§5.4):")
        lines.append("row factors \(Self.span(suggestedScaling.rows)), column factors \(Self.span(suggestedScaling.columns)).")
        lines.append("")
        lines.append("## Basis")
        lines.append("")
        switch basisAnalysis {
        case .noBasis:
            lines.append("No basis was supplied.")
        case .invalidBasis:
            lines.append("The supplied basis does not fit the problem and was ignored.")
        case .tooManyRows(let rows):
            lines.append("Skipped: \(rows) rows is above the 4,000-row limit of the dense condition estimate.")
        case .overMemoryBudget:
            lines.append("Skipped: the dense factorization of the basis does not fit the memory budget.")
        case .analyzed:
            if let kappa = basisConditionEstimate {
                lines.append("1-norm condition estimate κ₁(B) ≈ \(Self.format(kappa)).")
            } else {
                lines.append("The basis was factored but its condition number could not be estimated.")
            }
        }
        lines.append("")
        lines.append("## Findings")
        lines.append("")
        if findings.isEmpty {
            lines.append("None.")
        } else {
            let counts = [Finding.Severity.severe, .warning, .info].map { severity in
                "\(findings(of: severity).count) \(Self.name(severity))"
            }
            lines.append(counts.joined(separator: ", ") + ".")
            lines.append("")
            for finding in findings {
                lines.append("- **\(Self.name(finding.severity))** — \(finding.message)")
            }
        }
        if omittedFindings > 0 {
            lines.append("")
            lines.append("… and \(omittedFindings) more finding\(omittedFindings == 1 ? "" : "s") of kinds already listed.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func name(_ severity: Finding.Severity) -> String {
        switch severity {
        case .info: return "info"
        case .warning: return "warning"
        case .severe: return "severe"
        }
    }

    /// Three significant digits, scientific for very large and very small magnitudes.
    static func format(_ value: Double) -> String {
        if value.isInfinite { return value > 0 ? "∞" : "−∞" }
        if value.isNaN { return "NaN" }
        return String(format: "%.3g", value)
    }

    /// The smallest and largest factor of a scale vector, as powers of two.
    private static func span(_ factors: [Double]) -> String {
        guard let smallest = factors.min(), let largest = factors.max() else { return "(none)" }
        func power(_ value: Double) -> String {
            guard value > 0, value.isFinite else { return format(value) }
            let exponent = Int(log2(value).rounded())
            return exponent == 0 ? "1" : "2^\(exponent)"
        }
        return smallest == largest ? power(smallest) : "\(power(smallest)) … \(power(largest))"
    }
}
