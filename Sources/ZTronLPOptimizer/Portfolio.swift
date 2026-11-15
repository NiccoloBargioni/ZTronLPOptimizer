// The `Portfolio` composite strategy (specification §11.2, §11.3).

import ZTronLPCore
import ZTronLPMetal
import ZTronLPNumerics

/// Composite: runs every strategy concurrently on the same problem, returns the first to
/// finish, cancels the rest.
///
/// "Finish" means reach a conclusion: `.optimal`, `.infeasible` or `.unbounded`. A strategy
/// that merely stops (a limit, a numerical failure, a model it does not support) does not win
/// while another one is still working; if none concludes, the best of what came back is
/// returned. The threads and the memory budget of the run are split evenly between the
/// strategies.
///
/// Events: the portfolio reports one `.started` and one `.finished`. Everything else the
/// strategies report is forwarded as it comes, interleaved; `.finished` is delivered after
/// every strategy has returned, so it is the last event (rule L10).
public struct Portfolio: SolverStrategy {
    public let strategies: [any SolverStrategy]

    public init(_ strategies: [any SolverStrategy]) {
        self.strategies = strategies
    }

    public var engineName: String {
        "Portfolio(" + strategies.map { $0.engineName }.joined(separator: ", ") + ")"
    }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> PortfolioAnalysis {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        guard !strategies.isEmpty else {
            // A thrown error is an exit path too: `.finished` still closes the event sequence.
            let error = SolverError.unsupported("a portfolio needs at least one strategy")
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }

        // Each strategy is a nested solve: same listener, without its own start and finish.
        var child = context.attachingMetal().nested()
        let count = strategies.count
        child.threads = Swift.max(1, context.resolvedThreads / count)
        child.memoryBudgetBytes = MemoryBudget.resolve(context) / count

        /// What one strategy produced: its analysis, or the error it threw.
        enum Entry: Sendable {
            case analysis(AnySolutionAnalysis)
            case failure(String, SolverError?)
        }
        func run<S: SolverStrategy>(_ strategy: S, _ context: SolveContext) async -> Entry {
            do {
                return .analysis(AnySolutionAnalysis(try await strategy.solve(problem, context: context), engine: strategy.engineName))
            } catch let error as SolverError {
                return .failure(strategy.engineName, error)
            } catch {
                return .failure(strategy.engineName, nil)
            }
        }
        func isConclusive(_ status: SolveStatus) -> Bool {
            switch status {
            case .optimal, .infeasible, .unbounded: return true
            default: return false
            }
        }
        /// Lower is better among inconclusive results.
        func rank(_ status: SolveStatus) -> Int {
            switch status {
            case .optimal, .infeasible, .unbounded: return 0
            case .feasible: return 1
            case .infeasibleOrUnbounded: return 2
            case .noSolution: return 3
            case .numericalFailure: return 4
            }
        }

        let childContext = child
        let all = strategies
        let entries: [(index: Int, entry: Entry)] = await withTaskGroup(of: (Int, Entry).self) { group in
            for (index, strategy) in all.enumerated() {
                group.addTask { (index, await run(strategy, childContext)) }
            }
            var collected: [(index: Int, entry: Entry)] = []
            var decided = false
            for await (index, entry) in group {
                collected.append((index, entry))
                if !decided, case .analysis(let analysis) = entry, isConclusive(analysis.status) {
                    // The winner: everyone else is told to stop, and returns with what it has.
                    decided = true
                    group.cancelAll()
                }
            }
            return collected
        }

        // The first conclusive result in order of arrival; otherwise the best-ranked one.
        var winnerPosition: Int? = nil
        for (position, item) in entries.enumerated() {
            if case .analysis(let analysis) = item.entry, isConclusive(analysis.status) {
                winnerPosition = position
                break
            }
        }
        if winnerPosition == nil {
            var bestRank = Int.max
            for (position, item) in entries.enumerated() {
                if case .analysis(let analysis) = item.entry, rank(analysis.status) < bestRank {
                    bestRank = rank(analysis.status)
                    winnerPosition = position
                }
            }
        }
        guard let position = winnerPosition, case .analysis(let winner) = entries[position].entry else {
            // Nobody produced an analysis: every strategy threw. Report the first error.
            let seconds = secondsSince(started)
            var first: SolverError = .unsupported("no strategy of the portfolio could run")
            for item in entries.sorted(by: { $0.index < $1.index }) {
                if case .failure(_, let error?) = item.entry {
                    first = error
                    break
                }
            }
            await sink.finish(status: .numericalFailure("\(first)"), seconds: seconds)
            throw first
        }

        var others: [(strategy: String, status: SolveStatus)] = []
        for (other, item) in entries.enumerated().sorted(by: { $0.element.index < $1.element.index }) where other != position {
            switch item.entry {
            case .analysis(let analysis): others.append((analysis.engine, analysis.status))
            case .failure(let name, let error):
                others.append((name, .numericalFailure(error.map { "\($0)" } ?? "the strategy failed")))
            }
        }
        let analysis = PortfolioAnalysis(base: winner, winner: winner.engine, others: others, seconds: secondsSince(started))
        await sink.finish(status: analysis.status, seconds: analysis.seconds)
        return analysis
    }
}

/// The analysis of a portfolio: the winner's analysis plus the losers' statuses.
public struct PortfolioAnalysis: AnalysisDecorator, BasisProviding {
    /// The winner.
    public let base: AnySolutionAnalysis
    public let winner: String
    public let others: [(strategy: String, status: SolveStatus)]
    private let totalSeconds: Double

    public init(base: AnySolutionAnalysis, winner: String, others: [(strategy: String, status: SolveStatus)], seconds: Double) {
        self.base = base
        self.winner = winner
        self.others = others
        totalSeconds = seconds
    }

    /// The wall-clock time of the whole portfolio, which overrides the winner's own.
    public var seconds: Double { totalSeconds }

    public var finalBasis: Basis? { base.finalBasis }
}
