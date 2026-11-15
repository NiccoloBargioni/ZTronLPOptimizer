// CP-SAT subset (specification §10, §11.2, §11.3).
//
// `CPSAT` is a conflict-driven (CDCL) solver over Boolean and bounded-integer variables with
// lazily generated bound literals, linear propagation, restarts and a parallel portfolio — the
// core of OR-Tools' CP-SAT, without its global constraints, presolve, cuts and core-based
// optimization. In v1 it solves pure integer/Boolean models; a model with continuous columns
// is rejected with `SolverError.unsupported` and belongs to branch and bound.
//
// Not in v1 (§10.4): no_overlap, cumulative, all_different, element, table, integer
// multiplication and division, reified constraints beyond clauses, symmetry breaking,
// probing/presolve beyond unit propagation and bound tightening at load, core-based and
// LB-tree objective search, continuous variables.
//
// The LP propagator, the hook §10.4 leaves in the API as `CPSAT(lpPropagator:)`, is
// implemented for the models v1 accepts (LPRelaxation.swift) and is on by default — the
// specification's initializer has `false`: with it, every other worker propagates with the
// linear relaxation of the model's linear rows, solved by the simplex engine. A model with
// continuous columns is rejected with or without it.

import Foundation
import ZTronLPCore
import ZTronLPNumerics

/// When a CP-SAT worker abandons its current search path and starts again from level 0.
public enum RestartPolicy: Sendable, Hashable {
    /// The Luby sequence 1, 1, 2, 1, 1, 2, 4, … times `unit` conflicts. The default is
    /// `.luby(unit: 100)`.
    case luby(unit: Int)
    /// `first`, `first·factor`, `first·factor²`, … conflicts.
    case geometric(first: Int, factor: Double)
    /// No restarts driven by conflicts. A worker still returns to level 0 when it finds a
    /// solution, when the incumbent improves, and to reduce its clause database.
    case never

    /// The i-th term (i ≥ 0) of the Luby sequence 1, 1, 2, 1, 1, 2, 4, 1, …
    public static func lubyTerm(_ i: Int) -> Int {
        // Find the finite subsequence that contains index i, then its position in it.
        var size = 1
        var exponent = 0
        while size < i + 1 {
            exponent += 1
            size = 2 * size + 1
        }
        var index = i
        while size - 1 != index {
            size = (size - 1) >> 1
            exponent -= 1
            index %= size
        }
        return 1 << exponent
    }

    /// The number of conflicts allowed in restart number `index` (0-based).
    func conflictLimit(restart index: Int) -> Int {
        switch self {
        case .luby(let unit):
            let (product, overflow) = Swift.max(1, unit).multipliedReportingOverflow(by: Self.lubyTerm(index))
            return overflow ? Int.max : product
        case .geometric(let first, let factor):
            let value = Double(Swift.max(1, first)) * Foundation.pow(Swift.max(1, factor), Double(index))
            return value >= 1e18 ? Int.max : Int(value)
        case .never:
            return Int.max
        }
    }
}

/// The CP-SAT strategy: configured once, reusable, safe to run concurrently. Each run
/// allocates its own workers.
///
/// What a run reads from its `SolveContext`:
///   * `timeLimit` and task cancellation end the search with the best incumbent
///     (`.feasible(stoppedBy:)`) or with `.noSolution(stoppedBy:)`; neither throws.
///   * `threads` is the number of portfolio workers unless `workers` is given.
///   * `memoryBudgetBytes` bounds the learned clauses: over the budget a worker forgets
///     clauses, and if that is not enough the search stops with `.memoryBudget` (rule L7).
///     With `lpPropagator`, a budget that cannot hold a simplex engine per LP worker makes
///     the solve run without the propagator, with a warning.
///   * `warmStart: .primalPoint` steers the first decisions toward the given point; the other
///     kinds are ignored. `metal` is ignored: CDCL is pointer-chasing, not SIMD (§6.4).
///   * `progress` receives `.started`, `.newIncumbent` (its `node` is the number of conflicts
///     the finding worker had seen, its `source` is `cpsat[<worker>]`), `.boundImproved` and
///     `.finished`.
///
/// The search stops as soon as the incumbent is within the MIP gap of §6.5 (relative 1e-4,
/// absolute 1e-6) of the proven bound, and reports `.optimal`. Objective values are multiples
/// of a fixed step (1 for integral costs), so this is an exact proof whenever
/// 1e-4·|objective| is smaller than that step — for integral costs, below 10⁴.
///
/// The objective is improved by linear search, one incumbent at a time (§10.2). That is
/// thorough but not fast when good solutions are far from where the decisions start: a
/// single lower-bound-first worker without the LP propagator — `deterministic: true` with
/// `lpPropagator: false` — climbs a wide integer range one step per incumbent. The
/// relaxation's optimum, and the portfolio's objective-directed workers, do not have that
/// problem; core-based and LB-tree objective search are post-v1 (§10.4).
public struct CPSAT: SolverStrategy {
    /// The number of portfolio workers; `nil` → `context.threads`.
    public let workers: Int?
    public let restarts: RestartPolicy
    /// Whether workers exchange short learned clauses (LBD ≤ 2, ≤ 8 literals) at restarts.
    public let clauseSharing: Bool
    /// Whether every other worker, starting with the first, also propagates with the linear
    /// relaxation of the model (the hook of §10.4). The default is `true`; `false` runs the
    /// subset of §10.2 on its own, which is what the specification's initializer defaults to.
    ///
    /// Such a worker solves the relaxation over its current domains with the dual simplex
    /// whenever ordinary propagation is at a fixed point. An infeasible relaxation, or one
    /// whose optimum the incumbent rules out, is a conflict; reduced costs tighten bounds; an
    /// integral optimum is a solution; a fractional one names the variable to branch on. This
    /// is what closes models whose difficulty is a bound over several rows at once, which
    /// propagating one row at a time cannot produce; where the relaxation is weak the other
    /// half of the portfolio still runs as pure CDCL. Whatever the engine returns is
    /// re-derived in exact integer arithmetic before it is used, so the flag changes how much
    /// work a proof takes and never what is proven.
    ///
    /// The relaxation holds the rows that are linear constraints; rows that are clauses
    /// (§10.1) stay out of it. A model made of clauses therefore has no relaxation and is
    /// searched exactly as with `false`, and a worker whose relaxation keeps proving nothing
    /// looks at it less and less often. What the flag costs is one simplex engine per LP
    /// worker — a dense basis of the relaxed rows up to 1,500 of them — and, on a large
    /// model, the simplex iterations of the first looks.
    public let lpPropagator: Bool
    /// The base seed; worker w uses a seed derived from it and w.
    public let seed: UInt64
    /// One worker, fixed seed, no clause exchange: identical results and identical event
    /// sequences across runs (§10.3, rule C9).
    public let deterministic: Bool

    public init(
        workers: Int? = nil,                    // nil → context.threads
        restarts: RestartPolicy = .luby(unit: 100),
        clauseSharing: Bool = true,
        lpPropagator: Bool = true,              // the hook of §10.4; §11.2 has `false`
        seed: UInt64 = 0,
        deterministic: Bool = false
    ) {
        self.workers = workers
        self.restarts = restarts
        self.clauseSharing = clauseSharing
        self.lpPropagator = lpPropagator
        self.seed = seed
        self.deterministic = deterministic
    }

    /// Solves a pure integer problem.
    ///
    /// Throws `SolverError.unsupported` for a model outside §10.1 — a continuous column, an
    /// integer column without finite bounds, data that no power of 10 up to 1e6 makes
    /// integral, activity bounds that do not fit in Int64.
    /// A rejected model reports `.started` and `.finished` and then throws. Every other exit
    /// is a result: `.finished` is delivered exactly once, last, and cancellation or a time
    /// limit return `.feasible(stoppedBy:)` or `.noSolution(stoppedBy:)` with whatever exists.
    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> CPSATAnalysis {
        try await run(problem, context: context, recordLearnedClauses: false).analysis
    }

    /// The whole solve, with the hooks the tests need.
    func run(
        _ problem: CompiledLP, context: SolveContext, recordLearnedClauses: Bool, reductionInterval: Int = 20_000
    ) async throws -> (analysis: CPSATAnalysis, model: CPModel, reports: [WorkerReport]) {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        let model: CPModel
        do {
            model = try CPModel(problem)
        } catch {
            // A rejected model is an exit path too: `.finished` still closes the event
            // sequence, exactly once (rule L10), before the error is thrown.
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }

        let workerCount = deterministic ? 1 : Swift.max(1, workers ?? context.resolvedThreads)
        let deadline = Deadline.after(seconds: context.timeLimit)
        let shared = SharedSearchState()
        let tolerances = Tolerances.default
        let store = IncumbentStore(
            model: model, shared: shared, sink: sink, relativeGap: tolerances.mipRelativeGap,
            absoluteGap: tolerances.mipAbsoluteGap)
        let sharing = clauseSharing && workerCount > 1
        let exchange: ClauseExchange? = sharing ? ClauseExchange() : nil
        // Rule L7: the model is shared by every worker; what is left of the budget is split.
        let budget = MemoryBudget.resolve(context)
        let allowance = Swift.max(0, budget - model.approximateBytes) / workerCount

        // The LP propagator: the relaxation and its exact rows are built once and shared; each
        // LP worker owns an engine. A worker whose share of the memory budget cannot hold one
        // runs as a plain CDCL worker instead (rules L7, L9).
        var relaxationData: RelaxationData? = nil
        if lpPropagator, model.infeasibleReason == nil {
            // No relaxation (a model of clauses, or one without rows) is not worth a word.
            if let data = RelaxationData(problem: problem, model: model) {
                if data.engineBytes <= allowance / 2 {
                    relaxationData = data
                } else {
                    await sink.warn("the LP propagator needs more memory per worker than the budget leaves; running without it")
                }
            }
        }
        let relaxation = relaxationData

        // A warm start's primal point steers the first decisions (other kinds are ignored).
        var hints: [Int64]? = nil
        if case .primalPoint(let point) = context.warmStart, point.count == model.variableCount,
           point.allSatisfy({ $0.isFinite && Swift.abs($0) < 9e15 }) {
            hints = point.map { Int64($0.rounded()) }
        }

        var reports: [WorkerReport] = []
        if model.infeasibleReason == nil {
            let restartPolicy = restarts
            let baseSeed = seed
            let phaseHints = hints
            reports = await withTaskGroup(of: WorkerReport.self) { group in
                for index in 0..<workerCount {
                    group.addTask {
                        var options = WorkerOptions()
                        options.index = index
                        options.seed = baseSeed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
                        // §10.3: VSIDS lower-bound-first, VSIDS random phase, VSIDS with
                        // LBD-only clause retention. The third and a fourth worker take their
                        // first phase from the objective, which is what finds good incumbents
                        // when the objective wants variables at their upper bounds; further
                        // workers repeat the cycle with their own seeds.
                        switch index % 4 {
                        case 0: options.phase = .lowerBoundFirst
                        case 1: options.phase = .random
                        case 2:
                            options.phase = .objective
                            options.lbdOnlyRetention = true
                        default: options.phase = .objective
                        }
                        options.restarts = restartPolicy
                        options.clauseSharing = sharing
                        options.memoryAllowance = allowance
                        options.recordLearnedClauses = recordLearnedClauses
                        options.hints = phaseHints
                        options.reductionInterval = reductionInterval
                        // Every other worker, starting with the first — the one a
                        // deterministic run consists of — propagates with the relaxation; the
                        // rest stay pure CDCL, which is what wins where the relaxation is weak.
                        if index % 2 == 0 { options.relaxation = relaxation }
                        // The engine is created inside its task and never leaves it (rule C4).
                        var worker = CPWorker(model: model, options: options)
                        var gate = WorkGate(deadline: deadline)
                        gate.stopFlag = shared.stop
                        return await worker.run(gate: &gate, shared: shared, store: store, exchange: exchange)
                    }
                }
                var collected: [WorkerReport] = []
                for await report in group { collected.append(report) }
                return collected.sorted { $0.index < $1.index }
            }
        }

        // Assemble the result.
        let best = await store.snapshot()
        let prover = reports.first { $0.outcome == .exhausted || $0.outcome == .satisfied }
        let status: SolveStatus
        if model.infeasibleReason != nil {
            status = .infeasible
        } else if reports.contains(where: { $0.outcome == .exhausted }) {
            // No solution better than the store's best exists; with an empty store, none at all.
            status = best.values != nil ? .optimal : .infeasible
        } else if best.values != nil, best.gapReached || reports.contains(where: { $0.outcome == .satisfied }) {
            status = .optimal
        } else {
            let reason: StopReason
            if reports.contains(where: { $0.outcome == .stopped(.timeLimit) }) {
                reason = .timeLimit
            } else if Task.isCancelled {
                reason = .cancelled
            } else if reports.contains(where: { $0.outcome == .stopped(.memoryBudget) }) {
                reason = .memoryBudget
            } else {
                reason = .cancelled
            }
            status = best.values != nil ? .feasible(stoppedBy: reason) : .noSolution(stoppedBy: reason)
        }

        var primal: [Double]? = nil
        var objectiveValue: Double? = nil
        if let values = best.values, let objective = best.objective {
            let point = values.map { Double($0) }
            if let violation = Self.violation(of: point, in: problem) {
                // A bug, never a property of the model. `.finished` still goes out, once and
                // last (rule L10), before the error does.
                await sink.finish(status: .numericalFailure(violation), seconds: secondsSince(started))
                throw SolverError.internalInconsistency(violation)
            }
            primal = point
            objectiveValue = model.reportedObjective(objective)
        }
        let bound: Double?
        switch status {
        case .optimal:
            // Proven, or within the MIP gap: report the proven bound when it is the tighter
            // statement, the objective otherwise.
            if best.gapReached, !reports.contains(where: { $0.outcome == .exhausted }), best.lowerBound > .min {
                bound = model.reportedObjective(best.lowerBound)
            } else {
                bound = objectiveValue
            }
        case .infeasible:
            bound = nil
        default:
            // The propagated lower bound of the objective row (§10.2).
            if best.lowerBound > .min {
                bound = model.reportedObjective(best.lowerBound)
            } else if model.hasObjective {
                bound = model.reportedObjective(model.linMinActivity[model.objectiveRow])
            } else {
                bound = model.reportedObjective(0)
            }
        }

        let seconds = secondsSince(started)
        let warnings = await sink.warnings
        let record = SolveRecord(
            status: status, objectiveValue: objectiveValue, bound: bound, primal: primal, dual: nil,
            reducedCosts: nil, seconds: seconds, warnings: warnings)
        let analysis = CPSATAnalysis(
            base: record,
            conflicts: reports.reduce(0) { $0 + $1.conflicts },
            decisions: reports.reduce(0) { $0 + $1.decisions },
            propagations: reports.reduce(0) { $0 + $1.propagations },
            restarts: reports.reduce(0) { $0 + $1.restarts },
            learnedClauses: reports.reduce(0) { $0 + $1.learnedClauses },
            workers: workerCount,
            winningWorker: prover?.index ?? best.worker,
            lpSolves: reports.reduce(0) { $0 + $1.lpSolves })
        await sink.finish(status: status, seconds: seconds)
        return (analysis, model, reports)
    }

    /// Checks a solution against the problem as it was given, in Double, and describes the
    /// first violation; `nil` when the point is feasible. A violation is a bug in the solver,
    /// never a property of the model.
    static func violation(of x: [Double], in lp: CompiledLP) -> String? {
        for j in 0..<lp.n {
            let tolerance = 1e-6 * Swift.max(1, Swift.abs(x[j]))
            if x[j] < lp.xl[j] - tolerance || x[j] > lp.xu[j] + tolerance {
                return "CP-SAT returned a value outside the bounds of column \(lp.names.column(j))"
            }
        }
        let activity = lp.rowActivity(x)
        for i in 0..<lp.m {
            let tolerance = 1e-6 * Swift.max(1, Swift.abs(activity[i]))
            if activity[i] < lp.rl[i] - tolerance || activity[i] > lp.ru[i] + tolerance {
                return "CP-SAT returned a point that violates row \(lp.names.row(i))"
            }
        }
        return nil
    }
}

/// The result of a CP-SAT solve (§11.3).
///
/// `primal` holds the n integer values as Doubles; `dual` and `reducedCosts` are `nil`.
/// `objectiveValue` and `bound` are in the model's own sense; `bound` is the propagated bound
/// of the objective row, and equals `objectiveValue` once optimality is proven. The counters
/// are totals over all workers.
public struct CPSATAnalysis: AnalysisDecorator {
    public let base: SolveRecord
    public let conflicts: Int
    public let decisions: Int
    public let propagations: Int
    public let restarts: Int
    public let learnedClauses: Int
    /// The number of portfolio workers that ran.
    public let workers: Int
    /// The worker that ended the search — the one that completed the proof (or, for a
    /// feasibility problem, found the solution); otherwise the one that found the reported
    /// incumbent; `nil` when there is neither.
    public let winningWorker: Int?
    /// Relaxations solved by the LP propagator; 0 without `CPSAT(lpPropagator: true)`.
    public let lpSolves: Int

    public init(
        base: SolveRecord, conflicts: Int, decisions: Int, propagations: Int, restarts: Int,
        learnedClauses: Int, workers: Int, winningWorker: Int?, lpSolves: Int = 0
    ) {
        self.base = base
        self.conflicts = conflicts
        self.decisions = decisions
        self.propagations = propagations
        self.restarts = restarts
        self.learnedClauses = learnedClauses
        self.workers = workers
        self.winningWorker = winningWorker
        self.lpSolves = lpSolves
    }
}
