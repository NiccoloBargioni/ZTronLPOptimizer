// The `Conditioned` decorator strategy (specification §11.2, §13).

import ZTronLPConditioning
import ZTronLPCore
import ZTronLPMetal
import ZTronLPNumerics

/// Decorator strategy: runs the wrapped strategy, then attaches a ConditioningReport (§13) to
/// its analysis.
///
/// The report says why a model is slow or numerically fragile: coefficient ranges, a
/// suggested scaling, structural findings (big-M rows, near-parallel rows, dense columns, …)
/// and, when the wrapped analysis has a basis, its condition number and degeneracy. When the
/// wrapped solve ends in `.numericalFailure`, the report's summary is also reported as a
/// `SolverEvent.warning` before `.finished`.
public struct Conditioned<Inner: SolverStrategy>: SolverStrategy {
    public let inner: Inner

    public init(_ inner: Inner) {
        self.inner = inner
    }

    public var engineName: String { "Conditioned<\(inner.engineName)>" }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> ConditionedAnalysis<Inner.Analysis> {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        // The wrapped strategy is a nested solve: `.finished` belongs to this one, which still
        // has the report to produce (rule L10).
        let nested = context.attachingMetal().nested()
        let analysis: Inner.Analysis
        do {
            analysis = try await inner.solve(problem, context: nested)
        } catch {
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }
        let report = await ConditioningAnalyzer.analyze(problem, after: analysis, context: context.silenced())
        if case .numericalFailure = analysis.status {
            await sink.warn(report.summary)
        }
        await sink.finish(status: analysis.status, seconds: secondsSince(started))
        return ConditionedAnalysis(base: analysis, report: report)
    }
}
