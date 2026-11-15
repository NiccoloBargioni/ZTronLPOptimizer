// Turns an analysis into the short log shown under the Solve button. It answers, in order:
// did the run finish, and with which verdict; what objective and which proven bound; the
// certificate when there is no optimum; the solution and its checks; what the engine did.

import Foundation
import ZTronLPOptimizer

struct LogLine: Identifiable, Hashable, Sendable {
    enum Style: Hashable, Sendable {
        /// The engine and the size of the problem.
        case title
        /// A proven verdict.
        case success
        /// A limit or the Stop button ended the run.
        case stopped
        /// Finished without telling infeasible from unbounded.
        case undecided
        /// A numerical failure, or a model the engine refused.
        case failure
        /// A fact.
        case item
        /// A secondary fact.
        case detail
        /// A warning, or a check that failed.
        case warning
    }

    let id: Int
    let style: Style
    let text: String
}

struct RunLog: Sendable {
    enum Outcome: Sendable {
        case optimal, infeasible, unbounded, undecided, stopped, failed
    }

    let outcome: Outcome
    let lines: [LogLine]
}

struct LogBuilder {
    private(set) var lines: [LogLine] = []

    mutating func add(_ style: LogLine.Style, _ text: String) {
        lines.append(LogLine(id: lines.count, style: style, text: text))
    }
}

enum Report {
    static func make(
        _ analysis: any SolutionAnalysis, engine: String, built: BuiltExample, events: [SolverEvent]
    ) -> RunLog {
        let lp = built.lp
        var log = LogBuilder()
        log.add(.title, header(engine, lp))
        verdict(analysis, lp, &log)
        objective(analysis, lp, &log)
        certificate(analysis, lp, &log)
        solution(analysis, built, &log)
        facts(analysis, lp, engine: engine, &log)
        progress(events, analysis, &log)
        warnings(analysis, events, &log)
        return RunLog(outcome: outcome(analysis.status), lines: log.lines)
    }

    static func rejected(_ error: any Error, engine: String, lp: CompiledLP) -> RunLog {
        var log = LogBuilder()
        log.add(.title, header(engine, lp))
        log.add(.failure, "Rejected before solving")
        log.add(.item, "\(error)")
        log.add(.detail, "Engines throw only for models they cannot take; limits and numerical trouble come back as results")
        return RunLog(outcome: .failed, lines: log.lines)
    }

    static func notCompiled(_ error: any Error) -> RunLog {
        var log = LogBuilder()
        log.add(.failure, "The model did not compile")
        log.add(.item, "\(error)")
        return RunLog(outcome: .failed, lines: log.lines)
    }

    // MARK: - Sections

    private static func header(_ engine: String, _ lp: CompiledLP) -> String {
        "\(engine) on \(Format.plural(lp.m, "row")) × \(Format.plural(lp.n, "column"))"
    }

    private static func verdict(_ a: any SolutionAnalysis, _ lp: CompiledLP, _ log: inout LogBuilder) {
        let time = Format.duration(a.seconds)
        switch a.status {
        case .optimal:
            log.add(.success, "Finished in \(time): optimal, proven" + (lp.hasIntegerColumns ? " within the gap" : ""))
        case .infeasible:
            log.add(.success, "Finished in \(time): proven infeasible")
            log.add(.detail, "No point satisfies every constraint and bound")
        case .unbounded:
            log.add(.success, "Finished in \(time): proven unbounded")
            log.add(.detail, "The objective improves without limit over a non-empty feasible set")
        case .infeasibleOrUnbounded:
            log.add(.undecided, "Finished in \(time) without a verdict: infeasible or unbounded")
            log.add(.detail, "There is no optimum, but the engine cannot tell which of the two cases holds")
        case .feasible(let reason):
            log.add(.stopped, "Stopped by \(phrase(reason)) after \(time): solution found, optimality not proven")
        case .noSolution(let reason):
            log.add(.stopped, "Stopped by \(phrase(reason)) after \(time): no feasible solution found yet")
        case .numericalFailure(let message):
            log.add(.failure, "Gave up after \(time): numerical failure")
            log.add(.detail, Format.tidy(message))
        }
    }

    private static func objective(_ a: any SolutionAnalysis, _ lp: CompiledLP, _ log: inout LogBuilder) {
        switch a.status {
        case .infeasible, .unbounded, .infeasibleOrUnbounded:
            // The last point the engine visited is no answer; the certificate below is.
            return
        default:
            break
        }
        let side = lp.sense == .minimize ? "lower" : "upper"
        switch (a.objectiveValue, a.bound) {
        case let (value?, bound?):
            let gap = abs(value - bound) / max(1, abs(value))
            if gap <= 1e-9 {
                log.add(.item, "Objective \(Format.number(value)), equal to the proven \(side) bound")
            } else {
                log.add(
                    .item,
                    "Objective \(Format.number(value)); proven \(side) bound \(Format.number(bound)); gap \(Format.percent(gap))")
            }
        case let (value?, nil):
            log.add(.item, "Objective \(Format.number(value)); no bound proven")
        case let (nil, bound?):
            log.add(.item, "No solution yet; proven \(side) bound \(Format.number(bound))")
        case (nil, nil):
            log.add(.item, "No objective value and no bound")
        }
    }

    private static func certificate(_ a: any SolutionAnalysis, _ lp: CompiledLP, _ log: inout LogBuilder) {
        switch a.status {
        case .unbounded:
            guard let ray = simplex(in: a)?.primalRay, ray.count >= lp.n else {
                log.add(.detail, "No ray accompanies this result")
                return
            }
            let direction = Array(ray.prefix(lp.n))
            let zero = [Double](repeating: 0, count: lp.n)
            let rate = lp.objective(at: direction) - lp.objective(at: zero)
            if let text = Format.assignments(names: lp.names.column, values: direction) {
                log.add(.item, "Ray: \(text)")
                log.add(.detail, "Every step along the ray stays feasible and changes the objective by \(Format.number(rate))")
            }
        case .infeasible:
            if let ray = simplex(in: a)?.dualRay, ray.count >= lp.m,
               let text = Format.assignments(names: lp.names.row, values: Array(ray.prefix(lp.m))) {
                log.add(.item, "Farkas certificate: \(text)")
                log.add(.detail, "These row multipliers combine the constraints into a contradiction")
            } else if tree(in: a) != nil {
                log.add(.detail, "Proven by search: every branch of the tree was closed")
            } else if a is CPSATAnalysis {
                log.add(.detail, "Refuted by propagation and clause learning (CP-SAT returns no certificate)")
            }
        default:
            break
        }
    }

    private static func solution(_ a: any SolutionAnalysis, _ built: BuiltExample, _ log: inout LogBuilder) {
        let lp = built.lp
        guard a.status.hasSolution, let x = a.primal, x.count == lp.n else { return }
        let binary = lp.integerColumns.count == lp.n && (0..<lp.n).allSatisfy { lp.xl[$0] >= 0 && lp.xu[$0] <= 1 }
        if binary {
            let chosen = (0..<lp.n).filter { x[$0] > 0.5 }
            var names = chosen.prefix(6).map { lp.names.column($0) }
            if chosen.count > 6 { names.append("… \(chosen.count - 6) more") }
            log.add(.item, "Set to 1 (\(chosen.count) of \(lp.n)): " + (names.isEmpty ? "none" : names.joined(separator: ", ")))
        } else if let text = Format.assignments(names: lp.names.column, values: x) {
            log.add(.item, "Solution: \(text)")
        } else {
            log.add(.item, "Solution: every variable is 0")
        }
        if a.status.isOptimal, let duals = a.dual, duals.count == lp.m {
            let text = Format.assignments(names: lp.names.row, values: duals, limit: 6) ?? "all 0"
            log.add(.item, "Shadow prices: \(text)")
        }

        let violation = lp.maxViolation(at: x)
        let worstViolation = max(violation.bounds, violation.rows)
        var check = "Check: worst constraint violation \(Format.sci(worstViolation))"
        var worstFraction = 0.0
        if lp.hasIntegerColumns {
            worstFraction = lp.integerColumns.map { j in abs(x[Int(j)] - x[Int(j)].rounded()) }.max() ?? 0
            check += ", worst distance from an integer \(Format.sci(worstFraction))"
        }
        log.add(max(worstViolation, worstFraction) > 1e-6 ? .warning : .detail, check)
        for line in built.check?(x) ?? [] {
            switch line {
            case .info(let text): log.add(.item, text)
            case .problem(let text): log.add(.warning, text)
            }
        }
    }

    // MARK: - Engine facts

    /// `engine` names the strategy that produced `a`, as configured.
    private static func facts(_ a: any SolutionAnalysis, _ lp: CompiledLP, engine: String, _ log: inout LogBuilder) {
        switch a {
        case let s as SimplexAnalysis:
            simplexFacts(s, requested: engine, &log)
        case let i as InteriorPointAnalysis:
            interiorFacts(i, &log)
        case let b as BranchAndBoundAnalysis<SimplexAnalysis>:
            treeFacts(b, &log)
        case let b as BranchAndBoundAnalysis<InteriorPointAnalysis>:
            treeFacts(b, &log)
        case let c as CPSATAnalysis:
            cpsatFacts(c, &log)
        case let erased as AnySolutionAnalysis:
            log.add(.item, "Automatic chose \(erased.engine)")
            if let inner = unwrap(erased) { facts(inner, lp, engine: erased.engine, &log) }
        case let p as PortfolioAnalysis:
            log.add(.item, "Winner: \(p.winner)")
            for other in p.others {
                log.add(.detail, "\(other.strategy): \(raceResult(other.status))")
            }
            if let inner = unwrap(p.base) { facts(inner, lp, engine: p.winner, &log) }
        case let c as ConditionedAnalysis<AnySolutionAnalysis>:
            facts(c.base, lp, engine: engine, &log)
            conditioning(c.report, lp, &log)
        default:
            break
        }
    }

    private static func simplexFacts(_ s: SimplexAnalysis, requested engine: String, _ log: inout LogBuilder) {
        // `method` is the method that made the last pivots, not necessarily the one requested.
        let method = s.method == .dual ? "dual" : "primal"
        log.add(
            .item,
            "Simplex: \(Format.plural(s.iterations, "pivot")) (\(s.phase1Iterations) in phase 1), "
                + "\(Format.plural(s.refactorizations, "refactorization")), finished by the \(method) method")
        if s.method == .primal, engine.contains(".dual") {
            log.add(.detail, "The dual method hands over to the primal method when the start is not dual feasible")
        }
        if s.degeneracy > 0 {
            log.add(.detail, "\(Format.percent(s.degeneracy)) of the basic variables sit at a bound (degenerate basis)")
        }
    }

    private static func interiorFacts(_ i: InteriorPointAnalysis, _ log: inout LogBuilder) {
        log.add(
            .item,
            "Interior point: \(Format.plural(i.iterations, "iteration")), final μ \(Format.sci(i.finalMu)), "
                + "residuals \(Format.sci(i.primalResidual)) primal, \(Format.sci(i.dualResidual)) dual")
        if let crossover = i.crossover {
            log.add(.item, "Crossover-lite: \(Format.plural(crossover.iterations, "simplex pivot")) to reach a vertex")
        } else if i.status.isOptimal {
            log.add(.detail, "No crossover: the answer is an interior point, not a vertex, and has no basis")
        }
    }

    private static func treeFacts<Root>(_ b: BranchAndBoundAnalysis<Root>, _ log: inout LogBuilder) {
        log.add(
            .item,
            "Search: \(Format.plural(b.nodesProcessed, "node")) processed, \(Format.count(b.nodesOpen)) open, "
                + Format.plural(b.lpIterations, "LP iteration"))
        if b.root.status.isOptimal, let value = b.root.objectiveValue {
            log.add(.item, "Root relaxation: \(Format.number(value)), the first bound")
        } else {
            log.add(.item, "Root relaxation: \(short(b.root.status))")
        }
        let history = b.incumbentHistory
        if !history.isEmpty {
            func step(_ e: IncumbentEvent) -> String { "\(Format.number(e.objective)) (\(e.source), node \(e.node))" }
            let shown = history.count <= 4
                ? history.map(step)
                : history.prefix(2).map(step) + ["…", step(history[history.count - 1])]
            log.add(.item, "Incumbents: " + shown.joined(separator: " → "))
        }
    }

    private static func cpsatFacts(_ c: CPSATAnalysis, _ log: inout LogBuilder) {
        log.add(
            .item,
            "CP-SAT: \(Format.plural(c.conflicts, "conflict")), \(Format.plural(c.decisions, "decision")), "
                + "\(Format.plural(c.restarts, "restart")), \(Format.plural(c.learnedClauses, "learned clause"))")
        var detail = Format.plural(c.workers, "worker")
        detail += c.lpSolves > 0 ? ", \(Format.plural(c.lpSolves, "LP relaxation")) solved" : ", no LP relaxation solved"
        if let winner = c.winningWorker { detail += ", worker \(winner) ended the search" }
        log.add(.detail, detail)
    }

    private static func conditioning(_ report: ConditioningReport, _ lp: CompiledLP, _ log: inout LogBuilder) {
        let ranges = report.coefficientRange
        log.add(
            .item,
            "Coefficients: matrix \(span(ranges.matrix)), objective \(span(ranges.objective)), "
                + "right-hand sides \(span(ranges.rhs))")
        switch report.basisAnalysis {
        case .analyzed:
            if let kappa = report.basisConditionEstimate {
                log.add(.item, "Basis condition estimate κ₁ ≈ \(Format.sci(kappa))")
            }
        case .noBasis: log.add(.detail, "No basis to analyze")
        case .invalidBasis: log.add(.detail, "The basis did not fit the problem")
        case .tooManyRows(let rows): log.add(.detail, "Basis analysis skipped at \(rows) rows")
        case .overMemoryBudget: log.add(.detail, "Basis analysis skipped: over the memory budget")
        }
        guard !report.findings.isEmpty else {
            log.add(.item, "Findings: none")
            return
        }
        let severe = report.findings(of: .severe).count
        let warning = report.findings(of: .warning).count
        let info = report.findings(of: .info).count
        log.add(.item, "Findings: \(severe) severe, \(Format.plural(warning, "warning")), \(info) info")
        // Findings of one kind are listed together, so twelve big-M rows read as one line.
        var groups: [[Finding]] = []
        for finding in report.findings {
            if let i = groups.firstIndex(where: { $0[0].severity == finding.severity && sameKind($0[0].kind, finding.kind) }) {
                groups[i].append(finding)
            } else {
                groups.append([finding])
            }
        }
        for group in groups.prefix(6) {
            let style: LogLine.Style = group[0].severity == .info ? .detail : .warning
            log.add(style, "\(name(group[0].severity)): " + describe(group, lp))
        }
        if groups.count > 6 { log.add(.detail, "… \(groups.count - 6) more kinds of findings") }
        if report.omittedFindings > 0 {
            log.add(.detail, "\(Format.plural(report.omittedFindings, "further finding")) not listed by the analyzer")
        }
    }

    /// Whether two findings report the same kind of issue at different places in the model.
    private static func sameKind(_ a: Finding.Kind, _ b: Finding.Kind) -> Bool {
        switch (a, b) {
        case (.bigM, .bigM), (.emptyRow, .emptyRow), (.emptyColumn, .emptyColumn), (.singletonRow, .singletonRow),
            (.nearParallelRows, .nearParallelRows), (.freeColumn, .freeColumn), (.fixedColumn, .fixedColumn),
            (.denseColumn, .denseColumn):
            return true
        default:
            return false
        }
    }

    /// One line for a group of findings of one kind.
    private static func describe(_ group: [Finding], _ lp: CompiledLP) -> String {
        guard group.count > 1 else { return group[0].message }
        func list(_ names: [String]) -> String {
            names.count <= 3
                ? names.joined(separator: ", ")
                : names.prefix(3).joined(separator: ", ") + ", … \(names.count - 3) more"
        }
        var rows: [String] = [], columns: [String] = [], pairs: [String] = []
        var ratio = 0.0, density = 0.0
        for finding in group {
            switch finding.kind {
            case let .bigM(row, _, r):
                rows.append(lp.names.row(row))
                ratio = max(ratio, r)
            case let .emptyRow(i), let .singletonRow(i):
                rows.append(lp.names.row(i))
            case let .emptyColumn(j), let .freeColumn(j), let .fixedColumn(j):
                columns.append(lp.names.column(j))
            case let .denseColumn(j, d):
                columns.append(lp.names.column(j))
                density = max(density, d)
            case let .nearParallelRows(i, k, _):
                pairs.append("\(lp.names.row(i)) ∥ \(lp.names.row(k))")
            case .wideCoefficientRange, .degenerateBasis, .illConditionedBasis:
                break
            }
        }
        let n = group.count
        switch group[0].kind {
        case .bigM:
            return "\(n) rows put a big-M coefficient, up to \(Format.sci(ratio)) × the row median, "
                + "on a binary column: \(list(rows))"
        case .emptyRow: return "\(n) rows have no entries: \(list(rows))"
        case .singletonRow: return "\(n) rows hold a single entry, bounds written as constraints: \(list(rows))"
        case .emptyColumn: return "\(n) columns have no entries: \(list(columns))"
        case .freeColumn: return "\(n) columns have no bounds: \(list(columns))"
        case .fixedColumn: return "\(n) columns are fixed by their bounds: \(list(columns))"
        case .denseColumn:
            return "\(n) columns have entries in up to \(String(format: "%.0f%%", density * 100)) of the rows, "
                + "which makes the interior point's normal equations dense: \(list(columns))"
        case .nearParallelRows: return "\(n) pairs of rows are nearly parallel: \(list(pairs))"
        case .wideCoefficientRange, .degenerateBasis, .illConditionedBasis: return group[0].message
        }
    }

    private static func progress(_ events: [SolverEvent], _ a: any SolutionAnalysis, _ log: inout LogBuilder) {
        for case let .presolved(rows, columns, removedRows, removedColumns) in events
        where removedRows + removedColumns > 0 {
            log.add(
                .detail,
                "Presolve removed \(Format.plural(removedRows, "row")) and \(Format.plural(removedColumns, "column")), "
                    + "leaving \(rows) × \(columns)")
            break
        }
        guard a is CPSATAnalysis else { return }
        let found = events.compactMap { event -> Double? in
            if case .newIncumbent(let objective, _, _) = event { return objective }
            return nil
        }
        if let first = found.first, let last = found.last {
            log.add(
                .detail,
                "\(Format.plural(found.count, "improving solution")) reported: first \(Format.number(first)), "
                    + "last \(Format.number(last))")
        }
    }

    private static func warnings(_ a: any SolutionAnalysis, _ events: [SolverEvent], _ log: inout LogBuilder) {
        var seen = Set<String>()
        var all: [String] = []
        let fromEvents = events.compactMap { event -> String? in
            if case .warning(let text) = event { return text }
            return nil
        }
        for text in a.warnings + fromEvents where seen.insert(text).inserted {
            all.append(text)
        }
        for text in all.prefix(4) { log.add(.warning, "Warning: \(Format.tidy(text))") }
        if all.count > 4 { log.add(.detail, "… \(Format.plural(all.count - 4, "more warning"))") }
    }

    // MARK: - Helpers

    private static func outcome(_ status: SolveStatus) -> RunLog.Outcome {
        switch status {
        case .optimal: return .optimal
        case .infeasible: return .infeasible
        case .unbounded: return .unbounded
        case .infeasibleOrUnbounded: return .undecided
        case .feasible, .noSolution: return .stopped
        case .numericalFailure: return .failed
        }
    }

    private static func phrase(_ reason: StopReason) -> String {
        switch reason {
        case .timeLimit: return "the time limit"
        case .iterationLimit: return "the iteration limit"
        case .nodeLimit: return "the node limit"
        case .cancelled: return "the Stop button"
        case .gapReached: return "reaching the gap"
        case .memoryBudget: return "the memory budget"
        }
    }

    /// The result of a strategy that lost a portfolio race.
    private static func raceResult(_ status: SolveStatus) -> String {
        switch status {
        case .noSolution(.cancelled): return "cancelled when the winner finished, no solution yet"
        case .feasible(.cancelled): return "cancelled when the winner finished, holding a solution"
        default: return short(status)
        }
    }

    static func short(_ status: SolveStatus) -> String {
        switch status {
        case .optimal: return "optimal"
        case .infeasible: return "infeasible"
        case .unbounded: return "unbounded"
        case .infeasibleOrUnbounded: return "infeasible or unbounded"
        case .feasible(let reason): return "feasible, stopped by \(phrase(reason))"
        case .noSolution(let reason): return "no solution, stopped by \(phrase(reason))"
        case .numericalFailure(let message): return "failed (\(Format.tidy(message)))"
        }
    }

    private static func name(_ severity: Finding.Severity) -> String {
        switch severity {
        case .info: return "Info"
        case .warning: return "Warning"
        case .severe: return "Severe"
        }
    }

    private static func span(_ range: ClosedRange<Double>) -> String {
        guard range.upperBound > 0 else { return "—" }
        let ratio = ConditioningReport.ratio(range)
        return "\(Format.number(range.lowerBound)) … \(Format.number(range.upperBound)) (ratio \(Format.sci(ratio)))"
    }

    /// The concrete analysis behind a type-erased one, for the engines this demo runs.
    private static func unwrap(_ erased: AnySolutionAnalysis) -> (any SolutionAnalysis)? {
        if let a = erased.unwrap(as: SimplexAnalysis.self) { return a }
        if let a = erased.unwrap(as: InteriorPointAnalysis.self) { return a }
        if let a = erased.unwrap(as: BranchAndBoundAnalysis<SimplexAnalysis>.self) { return a }
        if let a = erased.unwrap(as: BranchAndBoundAnalysis<InteriorPointAnalysis>.self) { return a }
        if let a = erased.unwrap(as: CPSATAnalysis.self) { return a }
        return nil
    }

    /// The simplex analysis that carries the rays, wherever it sits in the decorators.
    private static func simplex(in a: any SolutionAnalysis) -> SimplexAnalysis? {
        switch a {
        case let s as SimplexAnalysis: return s
        case let i as InteriorPointAnalysis: return i.crossover
        case let b as BranchAndBoundAnalysis<SimplexAnalysis>: return b.root
        case let b as BranchAndBoundAnalysis<InteriorPointAnalysis>: return b.root.crossover
        case let erased as AnySolutionAnalysis: return unwrap(erased).flatMap(simplex(in:))
        case let p as PortfolioAnalysis: return unwrap(p.base).flatMap(simplex(in:))
        case let c as ConditionedAnalysis<AnySolutionAnalysis>: return simplex(in: c.base)
        default: return nil
        }
    }

    /// Whether a branch-and-bound search produced the analysis.
    private static func tree(in a: any SolutionAnalysis) -> (any SolutionAnalysis)? {
        switch a {
        case is BranchAndBoundAnalysis<SimplexAnalysis>, is BranchAndBoundAnalysis<InteriorPointAnalysis>: return a
        case let erased as AnySolutionAnalysis: return unwrap(erased).flatMap(tree(in:))
        case let p as PortfolioAnalysis: return unwrap(p.base).flatMap(tree(in:))
        case let c as ConditionedAnalysis<AnySolutionAnalysis>: return tree(in: c.base)
        default: return nil
        }
    }
}
