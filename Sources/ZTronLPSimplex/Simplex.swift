// The public simplex strategy (specification §7, §11.2) and its analysis (§11.3).

import ZTronLPCore
import ZTronLPNumerics

/// Bounded-variable revised simplex, primal or dual: one value, configured once, reusable and
/// safe to run concurrently (each run allocates its own engine).
public struct Simplex: SolverStrategy {
    /// Which method drives the solve.
    public enum Method: Sendable, Hashable { case primal, dual }

    /// How the entering column (primal) is priced (§7.1).
    public enum Pricing: Sendable, Hashable {
        /// Largest reduced cost.
        case dantzig
        /// Devex reference weights (default).
        case devex
        /// Exact steepest-edge weights; one extra solve per iteration.
        case steepestEdge
        /// Devex over one of `sections` column sections per iteration.
        case partial(sections: Int)
    }

    /// Which basis factorization strategy to use (§6.3).
    public enum Factorization: Sendable, Hashable {
        /// Dense LU up to 1,500 rows, sparse QR above.
        case automatic
        case denseLU
        case sparseQR
    }

    /// When the anti-stalling perturbation is applied (§7.3).
    public enum Perturbation: Sendable, Hashable {
        case off
        /// From the first iteration.
        case always
        /// After 1,000 iterations without progress with more than 30% of basics at a bound.
        case onStall
    }

    public let method: Method
    public let pricing: Pricing
    public let factorization: Factorization
    public let perturbation: Perturbation
    public let maxIterations: Int?
    public let presolve: Bool
    public let scaling: ScalingMode
    public let tolerances: Tolerances

    public init(
        _ method: Method = .dual,
        pricing: Pricing = .devex,
        factorization: Factorization = .automatic,
        perturbation: Perturbation = .onStall,
        maxIterations: Int? = nil,
        presolve: Bool = true,
        scaling: ScalingMode = .geometricEquilibration,
        tolerances: Tolerances = .default
    ) {
        self.method = method
        self.pricing = pricing
        self.factorization = factorization
        self.perturbation = perturbation
        self.maxIterations = maxIterations
        self.presolve = presolve
        self.scaling = scaling
        self.tolerances = tolerances
    }

    public var engineName: String {
        method == .primal ? "Simplex(.primal)" : "Simplex(.dual)"
    }

    /// The row count up to which `.automatic` picks the dense LU basis.
    public static let denseBasisLimit = 1_500

    /// The factorization strategy this configuration uses for a problem with `m` rows.
    public func makeFactorization(rows m: Int) -> any BasisFactorization {
        switch factorization {
        case .denseLU:
            return DenseLUBasis(dropTolerance: tolerances.dropZero)
        case .sparseQR:
            return SparseQRBasis(dropTolerance: tolerances.dropZero)
        case .automatic:
            if m <= Self.denseBasisLimit {
                return DenseLUBasis(dropTolerance: tolerances.dropZero)
            }
            return SparseQRBasis(dropTolerance: tolerances.dropZero)
        }
    }

    /// The iteration cap of a solve: `maxIterations`, or a bound generous enough never to bind
    /// on a healthy solve yet finite, so the engine terminates (rule L3).
    public func iterationCap(rows m: Int, columns n: Int) -> Int {
        maxIterations ?? Swift.max(50_000, 100 * (m + n))
    }

    /// A worker-owned engine for `lp`: scales the problem as configured, picks the
    /// factorization and attaches the run-level resources. No presolve — callers that solve a
    /// sequence of related problems (branch and bound) need a fixed column space.
    package func makeEngine(for lp: CompiledLP, context: SolveContext) -> SimplexEngine {
        let working = lp.scaling == nil ? Scaler.scale(lp.relaxed(), mode: scaling) : lp.relaxed()
        var engine = SimplexEngine(lp: working, strategy: self, factorization: makeFactorization(rows: working.m))
        engine.metalPolicy = context.metal
        engine.kernelProvider = context.candidateKernels
        engine.threads = context.resolvedThreads
        return engine
    }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SimplexAnalysis {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        do {
            let analysis = try await solve(problem, context: context, sink: sink, started: started)
            await sink.finish(status: analysis.status, seconds: analysis.seconds)
            return analysis
        } catch {
            // Only SolverError leaves this function; `.finished` is still the last event (L10).
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }
    }

    private func solve(
        _ problem: CompiledLP, context: SolveContext, sink: EventSink, started: UInt64
    ) async throws -> SimplexAnalysis {
        var warnings: [String] = []
        func warn(_ text: String) async {
            warnings.append(text)
            await sink.warn(text)
        }
        if problem.hasIntegerColumns {
            await warn("the model has integer columns; the simplex engine solves its LP relaxation")
        }

        // A branch-and-bound style warm start names bound changes: they are part of the problem.
        var original = problem.relaxed()
        var warmStart = context.warmStart
        if case .incremental(let parent, let changes) = warmStart {
            original = original.applying(changes)
            warmStart = .basis(parent)
        }

        let deadline = Deadline.after(seconds: context.timeLimit)
        let pre = Presolve.run(original, tolerances: tolerances, mode: presolve ? .full : .off)
        if presolve {
            await sink.emit(
                .presolved(
                    rows: pre.reduced.m, columns: pre.reduced.n, removedRows: pre.removedRows,
                    removedColumns: pre.removedColumns))
        }

        switch pre.outcome {
        case .infeasible(let reason):
            // Presolve has no certificate of its own. The unpresolved problem gives one, and
            // settles the status independently of the presolve's tolerance.
            await warn("presolve found the model infeasible (\(reason)); solving without presolve for the certificate")
            return try await solveReduced(
                original: original, pre: .identity(original), warmStart: warmStart, context: context,
                sink: sink, started: started, deadline: deadline, warnings: warnings)
        case .solved:
            let x = pre.expandPrimal([])
            let y = pre.expandDual([])
            if let column = pre.unboundedColumn {
                var ray = [Double](repeating: 0, count: original.n)
                ray[column] = pre.unboundedDirection
                return SimplexAnalysis(
                    base: SolveRecord(status: .unbounded, primal: x, seconds: secondsSince(started), warnings: warnings),
                    method: method, basis: pre.expandBasis(Basis(status: [], basic: [])), iterations: 0,
                    phase1Iterations: 0, refactorizations: 0, degeneracy: 0, primalRay: ray, dualRay: nil)
            }
            let objective = original.objective(at: x)
            let flip: Double = original.sense == .maximize ? -1 : 1
            let d = original.reducedCosts(forDuals: y)
            return SimplexAnalysis(
                base: SolveRecord(
                    status: .optimal, objectiveValue: objective, bound: objective, primal: x,
                    dual: y.map { flip * $0 }, reducedCosts: d.map { flip * $0 },
                    seconds: secondsSince(started), warnings: warnings),
                method: method, basis: pre.expandBasis(Basis(status: [], basic: [])), iterations: 0,
                phase1Iterations: 0, refactorizations: 0, degeneracy: 0, primalRay: nil, dualRay: nil)
        case .reduced:
            return try await solveReduced(
                original: original, pre: pre, warmStart: warmStart, context: context, sink: sink,
                started: started, deadline: deadline, warnings: warnings)
        }
    }

    /// Scales and solves the presolved problem, then maps everything back to `original`.
    private func solveReduced(
        original: CompiledLP, pre: Presolve, warmStart: WarmStart, context: SolveContext,
        sink: EventSink, started: UInt64, deadline: Deadline, warnings: [String]
    ) async throws -> SimplexAnalysis {
        var warnings = warnings
        let reduced = pre.reduced
        let scaled = Scaler.scale(reduced, mode: scaling)
        var engine = SimplexEngine(lp: scaled, strategy: self, factorization: makeFactorization(rows: scaled.m))
        engine.metalPolicy = context.metal
        engine.kernelProvider = context.candidateKernels
        engine.threads = context.resolvedThreads
        engine.budget = ConcurrencyBudget(threads: context.resolvedThreads)
        engine.eventSink = sink

        // Map the warm start into the reduced problem's space.
        let mapped: WarmStart
        switch warmStart {
        case .none, .crash:
            mapped = warmStart
        case .basis(let basis):
            if basis.status.count == original.n + original.m {
                mapped = .basis(pre.reduceBasis(basis))
            } else {
                warnings.append("the warm-start basis does not fit the problem and was ignored")
                mapped = .none
            }
        case .primalPoint(let point):
            if point.count == original.n {
                mapped = .primalPoint(pre.reducePrimal(point))
            } else {
                warnings.append("the warm-start point does not fit the problem and was ignored")
                mapped = .none
            }
        case .incremental:
            mapped = .none   // rewritten to .basis by the caller
        }

        var gate = WorkGate(deadline: deadline)
        let outcome = try await engine.run(
            method: method, warmStart: mapped, cutoff: nil, iterationLimit: nil, gate: &gate)
        return Self.postsolved(
            outcome, presolve: pre, original: original, seconds: secondsSince(started), warnings: warnings)
    }

    /// Maps an engine outcome on a presolved problem back to the original problem: primal and
    /// dual values, reduced costs, basis and certificates, in the model's own sense (§5.3, §6.5).
    package static func postsolved(
        _ outcome: SimplexOutcome, presolve pre: Presolve, original: CompiledLP, seconds: Double,
        warnings: [String]
    ) -> SimplexAnalysis {
        var warnings = warnings
        warnings.append(contentsOf: outcome.warnings)

        // All engine values are already unscaled and in the minimization form.
        let flip: Double = original.sense == .maximize ? -1 : 1
        let basis = pre.expandBasis(outcome.basis)
        var status = outcome.publicStatus
        var primal: [Double]? = nil
        var dual: [Double]? = nil
        var reducedCosts: [Double]? = nil
        var objective: Double? = nil
        var bound: Double? = nil
        var primalRay: [Double]? = outcome.primalRay.map { pre.expandPrimalRay($0) }
        let dualRay: [Double]? = outcome.dualRay.map { pre.expandDual($0, objective: false) }

        if outcome.hasPrimalPoint {
            let x = pre.expandPrimal(outcome.x)
            primal = x
            if outcome.primalFeasible { objective = original.objective(at: x) }
        }
        if outcome.hasDualPoint {
            let y = pre.expandDual(outcome.y)
            dual = y.map { flip * $0 }
            reducedCosts = original.reducedCosts(forDuals: y).map { flip * $0 }
        }
        if case .optimal = status {
            bound = objective
        } else if let dualBound = outcome.dualBound {
            bound = original.reportedObjective(dualBound)
        }

        // An empty column that improves forever makes a feasible model unbounded (§5.3 rule 4).
        if let column = pre.unboundedColumn, outcome.primalFeasible || outcome.isUnbounded {
            var ray = [Double](repeating: 0, count: original.n)
            ray[column] = pre.unboundedDirection
            primalRay = ray
            status = .unbounded
            objective = nil
            bound = nil
            dual = nil
            reducedCosts = nil
        }

        return SimplexAnalysis(
            base: SolveRecord(
                status: status, objectiveValue: objective, bound: bound, primal: primal, dual: dual,
                reducedCosts: reducedCosts, seconds: seconds, warnings: warnings),
            method: outcome.finalMethod, basis: basis, iterations: outcome.iterations,
            phase1Iterations: outcome.phase1Iterations, refactorizations: outcome.refactorizations,
            degeneracy: outcome.degeneracy, primalRay: primalRay, dualRay: dualRay)
    }
}

extension Tolerances {
    /// The tolerances as the engine uses them: the feasibility tolerances as given, the other
    /// two kept in the proportion to them that the defaults have.
    ///
    /// The Harris ratio test lets a basic variable pass its bound by `harris`; that slack has
    /// to stay well inside the feasibility tolerance (two decades) or every such step looks
    /// like a new infeasibility. A ratio test skips entries below `pivot` (relative), and a
    /// step then moves the variables it skipped by up to that much; with a pivot tolerance
    /// above the feasibility tolerance the method keeps breaking the feasibility it has just
    /// restored. So a caller who lowers the feasibility tolerances and leaves the other two
    /// alone gets them lowered as well.
    var consistent: Tolerances {
        var result = self
        let feasibility = Swift.min(primalFeasibility, dualFeasibility)
        result.harris = Swift.min(harris, 0.01 * feasibility)
        result.pivot = Swift.min(pivot, feasibility)
        return result
    }

    /// The tolerances of the engine's refinement pass: the two feasibility tolerances lowered
    /// to the given levels and pivots as small as `pivot` (relative) allowed.
    static func refined(from base: Tolerances, primal: Double, dual: Double, pivot: Double) -> Tolerances {
        var strict = base
        strict.primalFeasibility = Swift.min(base.primalFeasibility, primal)
        strict.dualFeasibility = Swift.min(base.dualFeasibility, dual)
        strict.pivot = Swift.min(base.pivot, pivot)
        return strict.consistent
    }
}

/// The analysis both simplex methods return: the base record decorated with the method used,
/// the final basis, iteration counts by phase, refactorizations, the degeneracy fraction, and
/// the primal or dual ray when the problem is unbounded or infeasible (§7.6).
public struct SimplexAnalysis: AnalysisDecorator, BasisProviding {
    public let base: SolveRecord
    public let method: Simplex.Method
    /// Reusable as `WarmStart.basis`.
    public let basis: Basis
    public let iterations: Int
    public let phase1Iterations: Int
    public let refactorizations: Int
    /// Fraction of basic variables at a bound.
    public let degeneracy: Double
    /// When unbounded: a direction that stays feasible and improves the objective forever.
    public let primalRay: [Double]?
    /// When infeasible: a Farkas certificate over the rows.
    public let dualRay: [Double]?

    public init(
        base: SolveRecord, method: Simplex.Method, basis: Basis, iterations: Int, phase1Iterations: Int,
        refactorizations: Int, degeneracy: Double, primalRay: [Double]?, dualRay: [Double]?
    ) {
        self.base = base
        self.method = method
        self.basis = basis
        self.iterations = iterations
        self.phase1Iterations = phase1Iterations
        self.refactorizations = refactorizations
        self.degeneracy = degeneracy
        self.primalRay = primalRay
        self.dualRay = dualRay
    }

    public var finalBasis: Basis? { basis }
}
