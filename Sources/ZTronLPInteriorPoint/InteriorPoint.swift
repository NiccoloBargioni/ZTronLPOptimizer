// The public interior-point strategy (specification §8, §11.2) and its analysis (§11.3).
//
// `InteriorPoint` implements Mehrotra's predictor–corrector primal-dual method on the logical
// form, factoring the normal equations with Accelerate's sparse Cholesky and reusing the
// symbolic analysis across iterations. Crossover-lite (§8.4) feeds the interior point to the
// simplex engine as a `WarmStart.primalPoint`: a crash builds a basis from the columns far
// from their bounds, primal phase 1 removes any residual infeasibility and phase 2 finishes
// at a vertex. That step is why this target imports ZTronLPSimplex.

import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex

/// Mehrotra predictor–corrector interior point, optionally followed by crossover-lite.
public struct InteriorPoint: SolverStrategy {
    /// What happens after the interior-point iterations converge (§8.4).
    public enum Crossover: Sendable, Hashable {
        /// Return the interior solution.
        case none
        /// Hand the point to the simplex engine and return a vertex with its basis.
        case lite
    }

    /// Regularization of the normal equations (§8.1, §8.2).
    public struct Regularization: Sendable, Hashable {
        /// Added to Θ⁻¹ on both halves of a split free column, so Θ stays bounded.
        public var primal: Double
        /// δ_d, added to the diagonal of AΘAᵀ after scaling by ‖M‖.
        public var dual: Double

        public init(primal: Double = 1e-8, dual: Double = 1e-10) {
            self.primal = primal
            self.dual = dual
        }

        public static let `default` = Regularization()
    }

    public let crossover: Crossover
    public let maxIterations: Int
    public let regularization: Regularization
    public let presolve: Bool
    public let scaling: ScalingMode
    public let tolerances: Tolerances

    public init(
        crossover: Crossover = .lite,
        maxIterations: Int = 200,
        regularization: Regularization = .default,
        presolve: Bool = true,
        scaling: ScalingMode = .geometricEquilibration,
        tolerances: Tolerances = .default
    ) {
        self.crossover = crossover
        self.maxIterations = maxIterations
        self.regularization = regularization
        self.presolve = presolve
        self.scaling = scaling
        self.tolerances = tolerances
    }

    public var engineName: String {
        crossover == .lite ? "InteriorPoint(crossover: .lite)" : "InteriorPoint(crossover: .none)"
    }

    /// The simplex configuration crossover-lite runs with.
    package var crossoverSimplex: Simplex {
        Simplex(.primal, presolve: false, scaling: .none, tolerances: tolerances)
    }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> InteriorPointAnalysis {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        do {
            let analysis = try await solve(problem, context: context, sink: sink, started: started)
            await sink.finish(status: analysis.status, seconds: analysis.seconds)
            return analysis
        } catch {
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }
    }

    private func solve(
        _ problem: CompiledLP, context: SolveContext, sink: EventSink, started: UInt64
    ) async throws -> InteriorPointAnalysis {
        var warnings: [String] = []
        if problem.hasIntegerColumns {
            let text = "the model has integer columns; the interior-point engine solves its LP relaxation"
            warnings.append(text)
            await sink.warn(text)
        }
        let original = problem.relaxed()
        let deadline = Deadline.after(seconds: context.timeLimit)
        let pre = Presolve.run(original, tolerances: tolerances, mode: presolve ? .full : .off)
        if presolve {
            await sink.emit(
                .presolved(
                    rows: pre.reduced.m, columns: pre.reduced.n, removedRows: pre.removedRows,
                    removedColumns: pre.removedColumns))
        }
        let flip: Double = original.sense == .maximize ? -1 : 1

        func plain(_ status: SolveStatus, iterations: Int = 0, mu: Double = 0, primal: Double = 0, dual: Double = 0) -> InteriorPointAnalysis {
            InteriorPointAnalysis(
                base: SolveRecord(status: status, seconds: secondsSince(started), warnings: warnings),
                iterations: iterations, finalMu: mu, primalResidual: primal, dualResidual: dual, crossover: nil)
        }

        switch pre.outcome {
        case .infeasible(let reason):
            warnings.append("presolve found the model infeasible: \(reason)")
            return plain(.infeasible)

        case .solved:
            let x = pre.expandPrimal([])
            if pre.unboundedColumn != nil {
                return InteriorPointAnalysis(
                    base: SolveRecord(status: .unbounded, primal: x, seconds: secondsSince(started), warnings: warnings),
                    iterations: 0, finalMu: 0, primalResidual: 0, dualResidual: 0, crossover: nil)
            }
            let y = pre.expandDual([])
            let objective = original.objective(at: x)
            return InteriorPointAnalysis(
                base: SolveRecord(
                    status: .optimal, objectiveValue: objective, bound: objective, primal: x,
                    dual: y.map { flip * $0 }, reducedCosts: original.reducedCosts(forDuals: y).map { flip * $0 },
                    seconds: secondsSince(started), warnings: warnings),
                iterations: 0, finalMu: 0, primalResidual: 0, dualResidual: 0, crossover: nil)

        case .reduced:
            break
        }

        let scaled = Scaler.scale(pre.reduced, mode: scaling)
        var gate = WorkGate(deadline: deadline)
        let outcome = try await runInteriorPoint(on: scaled, context: context, sink: sink, gate: &gate)
        warnings.append(contentsOf: outcome.warnings)

        switch outcome.status {
        case .converged:
            break
        case .iterationLimit:
            return plain(.noSolution(stoppedBy: .iterationLimit), iterations: outcome.iterations, mu: outcome.mu, primal: outcome.primalResidual, dual: outcome.dualResidual)
        case .infeasibleOrUnbounded:
            return plain(.infeasibleOrUnbounded, iterations: outcome.iterations, mu: outcome.mu, primal: outcome.primalResidual, dual: outcome.dualResidual)
        case .stalled:
            // The iterations stopped making progress close to a solution: an ill-conditioned
            // problem, on which the normal equations lose the digits the residual needs. That
            // decides nothing about the problem. The simplex engine does, from the last
            // iterate, and whatever it concludes is the answer — a vertex, or a certificate.
            let residuals = "primal residual \(outcome.primalResidual), dual residual \(outcome.dualResidual), tolerance \(tolerances.ipmResidual)"
            guard crossover == .lite else {
                return plain(
                    .numericalFailure(
                        "the interior point stalled (\(residuals)): the problem is ill-conditioned; the simplex, or crossover: .lite, decides it"),
                    iterations: outcome.iterations, mu: outcome.mu, primal: outcome.primalResidual, dual: outcome.dualResidual)
            }
            let text = "the interior point stalled (\(residuals)): the problem is ill-conditioned; the simplex finished from its last iterate"
            warnings.append(text)
            await sink.warn(text)
            let finished = try await runCrossover(
                on: scaled, outcome: outcome, presolve: pre, original: original, context: context, sink: sink,
                gate: &gate)
            var base = finished.base
            base.warnings = warnings + finished.warnings.filter { !warnings.contains($0) }
            base.seconds = secondsSince(started)
            return InteriorPointAnalysis(
                base: base, iterations: outcome.iterations, finalMu: outcome.mu,
                primalResidual: outcome.primalResidual, dualResidual: outcome.dualResidual, crossover: finished)
        case .stopped(let signal):
            return plain(.noSolution(stoppedBy: signal.stopReason), iterations: outcome.iterations, mu: outcome.mu, primal: outcome.primalResidual, dual: outcome.dualResidual)
        case .numericalFailure(let message):
            return plain(.numericalFailure(message), iterations: outcome.iterations, mu: outcome.mu, primal: outcome.primalResidual, dual: outcome.dualResidual)
        }

        // Converged. An empty column that improves forever makes the model unbounded (§5.3).
        if pre.unboundedColumn != nil {
            return InteriorPointAnalysis(
                base: SolveRecord(
                    status: .unbounded, primal: pre.expandPrimal(outcome.x), seconds: secondsSince(started),
                    warnings: warnings),
                iterations: outcome.iterations, finalMu: outcome.mu, primalResidual: outcome.primalResidual,
                dualResidual: outcome.dualResidual, crossover: nil)
        }

        // The interior solution, mapped back to the original problem.
        let interiorX = pre.expandPrimal(outcome.x)
        let interiorY = pre.expandDual(outcome.y)
        let interiorObjective = original.objective(at: interiorX)
        let interior = SolveRecord(
            status: .optimal, objectiveValue: interiorObjective, bound: interiorObjective, primal: interiorX,
            dual: interiorY.map { flip * $0 },
            reducedCosts: original.reducedCosts(forDuals: interiorY).map { flip * $0 },
            seconds: secondsSince(started), warnings: warnings)

        guard crossover == .lite else {
            return InteriorPointAnalysis(
                base: interior, iterations: outcome.iterations, finalMu: outcome.mu,
                primalResidual: outcome.primalResidual, dualResidual: outcome.dualResidual, crossover: nil)
        }

        // Crossover-lite (§8.4).
        let crossed = try await runCrossover(
            on: scaled, outcome: outcome, presolve: pre, original: original, context: context, sink: sink,
            gate: &gate)
        var base = interior
        if crossed.status == .optimal {
            // The vertex replaces the interior point; the record keeps this solve's warnings.
            base = crossed.base
            base.warnings = warnings + crossed.warnings.filter { !warnings.contains($0) }
        } else {
            let text = "crossover-lite ended with \(crossed.status); returning the interior solution"
            base.warnings.append(text)
            await sink.warn(text)
        }
        base.seconds = secondsSince(started)
        return InteriorPointAnalysis(
            base: base, iterations: outcome.iterations, finalMu: outcome.mu,
            primalResidual: outcome.primalResidual, dualResidual: outcome.dualResidual, crossover: crossed)
    }

    /// Runs the interior-point iterations on a presolved, scaled problem.
    package func runInteriorPoint(
        on scaled: CompiledLP, context: SolveContext, sink: EventSink?, gate: inout WorkGate
    ) async throws -> IPMOutcome {
        var worker = try IPMWorker(lp: scaled, config: self)
        worker.threads = context.resolvedThreads
        worker.budget = ConcurrencyBudget(threads: context.resolvedThreads)
        worker.eventSink = sink
        return try await worker.run(gate: &gate)
    }

    /// Crossover-lite: the simplex engine, started from a crash on the interior point, on the
    /// same scaled problem; the result is postsolved to `original`.
    ///
    /// An interior-point method converges to the middle of the optimal face, which on a
    /// degenerate problem is not a vertex. A crash from there followed by phase 1 can land on
    /// a vertex off that face and leave phase 2 a long way to walk back. The duals say which
    /// columns rest on a bound in every optimal solution, so the crash first works on the
    /// problem with those columns held there — any vertex of that face is optimal. The basis
    /// of that vertex need not be dual feasible, so the interior-point duals, which are, are
    /// then pushed onto it (at most one pivot per held column in the basis). The run on the
    /// real bounds that ends the crossover costs a few iterations when the identification
    /// was right and is still correct when it was not.
    package func runCrossover(
        on scaled: CompiledLP, outcome ipm: IPMOutcome, presolve pre: Presolve, original: CompiledLP,
        context: SolveContext, sink: EventSink?, gate: inout WorkGate
    ) async throws -> SimplexAnalysis {
        let point = ipm.x
        let reduced = pre.reduced
        var face: [BoundChange] = []
        face.reserveCapacity(ipm.restingAtLower.count + ipm.restingAtUpper.count)
        for column in ipm.restingAtLower {
            let j = Int(column)
            let bound = j < reduced.n ? reduced.xl[j] : reduced.rl[j - reduced.n]
            if bound.isFinite { face.append(BoundChange(column: column, lower: bound, upper: bound)) }
        }
        for column in ipm.restingAtUpper {
            let j = Int(column)
            let bound = j < reduced.n ? reduced.xu[j] : reduced.ru[j - reduced.n]
            if bound.isFinite { face.append(BoundChange(column: column, lower: bound, upper: bound)) }
        }
        let started = Deadline.now
        let strategy = crossoverSimplex
        var engine = SimplexEngine(lp: scaled, strategy: strategy, factorization: strategy.makeFactorization(rows: scaled.m))
        engine.metalPolicy = context.metal
        engine.kernelProvider = context.candidateKernels
        engine.threads = context.resolvedThreads
        engine.budget = ConcurrencyBudget(threads: context.resolvedThreads)
        engine.eventSink = sink
        let outcome = try await engine.run(
            method: .primal, warmStart: .primalPoint(point), cutoff: nil, iterationLimit: nil, gate: &gate,
            face: face, faceDuals: ipm.y)
        return Simplex.postsolved(outcome, presolve: pre, original: original, seconds: secondsSince(started), warnings: [])
    }
}

/// The analysis of an interior-point solve (§11.3).
public struct InteriorPointAnalysis: AnalysisDecorator, BasisProviding {
    public let base: SolveRecord
    /// Interior-point iterations.
    public let iterations: Int
    public let finalMu: Double
    /// Relative primal residual at the last iterate.
    public let primalResidual: Double
    /// Relative dual residual at the last iterate.
    public let dualResidual: Double
    /// When crossover ran; its basis is what branch and bound reuses.
    public let crossover: SimplexAnalysis?

    public init(
        base: SolveRecord, iterations: Int, finalMu: Double, primalResidual: Double, dualResidual: Double,
        crossover: SimplexAnalysis?
    ) {
        self.base = base
        self.iterations = iterations
        self.finalMu = finalMu
        self.primalResidual = primalResidual
        self.dualResidual = dualResidual
        self.crossover = crossover
    }

    public var finalBasis: Basis? { crossover?.basis }
}
