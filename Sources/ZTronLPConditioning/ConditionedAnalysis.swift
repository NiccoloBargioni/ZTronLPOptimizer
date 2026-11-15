// ConditionedAnalysis (specification §11.3).
//
// The decorator the `Conditioned` strategy returns: the wrapped strategy's own analysis with a
// `ConditioningReport` attached. Every `SolutionAnalysis` property is forwarded by the
// `AnalysisDecorator` extension, so a caller reads status, objective and primal values exactly
// as on the wrapped analysis, and reaches the engine's details through `base`.

import ZTronLPCore

/// An analysis decorated with a conditioning report.
public struct ConditionedAnalysis<Inner: SolutionAnalysis>: AnalysisDecorator {
    /// The wrapped strategy's analysis.
    public let base: Inner
    /// The conditioning report of the problem that was solved (§13).
    public let report: ConditioningReport

    public init(base: Inner, report: ConditioningReport) {
        self.base = base
        self.report = report
    }
}

/// A conditioned analysis can supply a basis whenever the analysis it wraps can.
extension ConditionedAnalysis: BasisProviding where Inner: BasisProviding {
    public var finalBasis: Basis? { base.finalBasis }
}
