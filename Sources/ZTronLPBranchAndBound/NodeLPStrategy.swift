// The Strategy interface of the node LP (specification §9.1).
//
// `BranchAndBound<Engine>` is the GoF Strategy pattern applied to the node LP: the tree search
// is the Context, `NodeLPStrategy` is the Strategy interface, and `Simplex` and `InteriorPoint`
// are the concrete strategies. A user-defined engine conforms to the same protocol.
//
// Conventions shared by every method: `lp` is the problem branch and bound hands to
// `makeWorker` (its own working copy, in the original column space), objectives and cutoffs
// are values of that problem's minimization form `cᵀx + c₀`, primal values are its n
// structural columns, reduced costs its n + m columns, and bound changes are absolute bounds
// on its columns. When the gate stops a solve, the method throws the gate's `StopSignal`.

import ZTronLPCore
import ZTronLPInteriorPoint
import ZTronLPNumerics
import ZTronLPSimplex

/// What solving one node's LP produced.
public struct NodeLPResult<State: Sendable>: Sendable {
    public enum Outcome: Sendable {
        case optimal(objective: Double, x: [Double], reducedCosts: [Double])
        case infeasible
        /// Bound proven ≥ cutoff before optimality (dual only).
        case cutoff
        case unbounded
        /// Iteration limit hit; node is re-queued.
        case limit
    }

    public let outcome: Outcome
    /// Warm-start state shared by the node's children.
    public let state: State
    public let iterations: Int

    public init(outcome: Outcome, state: State, iterations: Int) {
        self.outcome = outcome
        self.state = state
        self.iterations = iterations
    }
}

/// The Strategy interface: a SolverStrategy that can also solve one node at a time from a
/// parent's state.
public protocol NodeLPStrategy: SolverStrategy {
    associatedtype State: Sendable
    associatedtype Worker: ~Copyable

    /// Called once per worker task; returns the worker-private engine (buffers are never shared).
    func makeWorker(lp: CompiledLP, context: SolveContext) -> Worker

    func solveRoot(_ w: inout Worker, gate: inout WorkGate) async throws -> NodeLPResult<State>

    func solveNode(
        _ w: inout Worker, changes: [BoundChange], parent: State, cutoff: Double?,
        iterationLimit: Int, gate: inout WorkGate
    ) async throws -> NodeLPResult<State>

    /// Strong-branching probe with a small iteration budget; default implementation calls
    /// solveNode.
    ///
    /// Returns a lower bound on the child's LP optimum: `.infinity` when the child is proven
    /// infeasible, `nil` when the probe ran out of budget without a valid bound.
    func probe(
        _ w: inout Worker, changes: [BoundChange], parent: State, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> Double?

    /// The engine's own Analysis of the root solve, which BranchAndBoundAnalysis carries as `root`.
    func rootAnalysis(_ result: NodeLPResult<State>, worker: borrowing Worker) -> Analysis
}

extension NodeLPStrategy {
    public func probe(
        _ w: inout Worker, changes: [BoundChange], parent: State, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> Double? {
        let result = try await solveNode(
            &w, changes: changes, parent: parent, cutoff: nil, iterationLimit: iterationLimit, gate: &gate)
        switch result.outcome {
        case .optimal(let objective, _, _): return objective
        case .infeasible: return .infinity
        case .cutoff, .unbounded, .limit: return nil
        }
    }
}

/// A warm-start state that can say how much memory it holds, so the node pool can enforce the
/// memory budget (§9.2). States that do not conform are counted by their inline size.
public protocol NodeStateSizing {
    var approximateBytes: Int { get }
}

extension Basis: NodeStateSizing {
    public var approximateBytes: Int {
        status.count * MemoryLayout<BasisStatus>.stride + basic.count * MemoryLayout<Int32>.stride + 64
    }
}

// MARK: - Simplex

/// Maps an engine outcome to a node result; a stop signal is rethrown, and a numerical failure
/// counts as `.limit` so the tree retries the node and, failing that, reports the path (rule L5).
func nodeResult(_ outcome: SimplexOutcome) throws -> NodeLPResult<Basis> {
    let result: NodeLPResult<Basis>.Outcome
    switch outcome.status {
    case .optimal: result = .optimal(objective: outcome.objective, x: outcome.x, reducedCosts: outcome.d)
    case .infeasible: result = .infeasible
    case .unbounded: result = .unbounded
    case .cutoff: result = .cutoff
    case .iterationLimit, .numericalFailure: result = .limit
    case .stopped(let signal): throw signal
    }
    return NodeLPResult(outcome: result, state: outcome.basis, iterations: outcome.iterations)
}

/// A strong-branching probe on a simplex engine. Probes always use the dual method: the
/// parent's basis is dual feasible after a bound change, so even an unfinished probe yields a
/// valid lower bound, which the primal method cannot give.
func simplexProbe(
    _ engine: inout SimplexEngine, changes: [BoundChange], parent: Basis, iterationLimit: Int,
    gate: inout WorkGate
) async throws -> Double? {
    let outcome = try await engine.run(
        method: .dual, warmStart: .incremental(parent: parent, changes: changes), cutoff: nil,
        iterationLimit: iterationLimit, gate: &gate)
    switch outcome.status {
    case .optimal: return outcome.objective
    case .infeasible: return .infinity
    case .iterationLimit, .cutoff: return outcome.dualBound
    case .unbounded, .numericalFailure: return nil
    case .stopped(let signal): throw signal
    }
}

extension Simplex: NodeLPStrategy {
    public typealias State = Basis
    public typealias Worker = SimplexEngine

    public func makeWorker(lp: CompiledLP, context: SolveContext) -> SimplexEngine {
        makeEngine(for: lp, context: context)
    }

    public func solveRoot(_ w: inout SimplexEngine, gate: inout WorkGate) async throws -> NodeLPResult<Basis> {
        try nodeResult(
            try await w.run(method: method, warmStart: .none, cutoff: nil, iterationLimit: nil, gate: &gate))
    }

    public func solveNode(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, cutoff: Double?,
        iterationLimit: Int, gate: inout WorkGate
    ) async throws -> NodeLPResult<Basis> {
        // `.incremental` hot start: with `.dual` the parent basis is still dual feasible and
        // the dual method starts directly, stopping early on the cutoff; with `.primal` the
        // composite phase 1 starts from the parent basis and there is no early stop.
        try nodeResult(
            try await w.run(
                method: method, warmStart: .incremental(parent: parent, changes: changes),
                cutoff: method == .dual ? cutoff : nil, iterationLimit: iterationLimit, gate: &gate))
    }

    public func probe(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> Double? {
        try await simplexProbe(&w, changes: changes, parent: parent, iterationLimit: iterationLimit, gate: &gate)
    }

    public func rootAnalysis(_ result: NodeLPResult<Basis>, worker: borrowing SimplexEngine) -> SimplexAnalysis {
        if let outcome = worker.lastOutcome {
            return worker.analysis(from: outcome, seconds: worker.lastRunSeconds)
        }
        return SimplexAnalysis(
            base: SolveRecord(status: .noSolution(stoppedBy: .cancelled)), method: method, basis: result.state,
            iterations: result.iterations, phase1Iterations: 0, refactorizations: 0, degeneracy: 0,
            primalRay: nil, dualRay: nil)
    }
}

// MARK: - Interior point

/// The worker of `InteriorPoint` as a node engine: the interior-point method solves the root,
/// crossover-lite turns its solution into a basis, and a dual simplex engine warm-started from
/// that basis solves every other node.
public struct InteriorPointNodeWorker: ~Copyable {
    var engine: SimplexEngine
    let lp: CompiledLP
    let context: SolveContext
    var root: InteriorPointAnalysis? = nil
    var rootSeconds = 0.0
}

extension InteriorPoint: NodeLPStrategy {
    public typealias State = Basis
    public typealias Worker = InteriorPointNodeWorker

    /// The dual simplex configuration used at every node after the root.
    var nodeSimplex: Simplex {
        Simplex(.dual, presolve: false, scaling: scaling, tolerances: tolerances)
    }

    public func makeWorker(lp: CompiledLP, context: SolveContext) -> InteriorPointNodeWorker {
        InteriorPointNodeWorker(engine: nodeSimplex.makeEngine(for: lp, context: context), lp: lp, context: context)
    }

    public func solveRoot(_ w: inout InteriorPointNodeWorker, gate: inout WorkGate) async throws -> NodeLPResult<Basis> {
        // The interior-point solve, as a nested solve of the enclosing one: same listener,
        // without its own start and finish events, inside what is left of the time limit.
        let started = Deadline.now
        var nested = w.context.nested()
        if let remaining = gate.currentDeadline.remainingSeconds { nested.timeLimit = remaining }
        nested.warmStart = .none
        let analysis = try await InteriorPoint(
            crossover: .lite, maxIterations: maxIterations, regularization: regularization, presolve: presolve,
            scaling: scaling, tolerances: tolerances
        ).solve(w.lp, context: nested)
        w.root = analysis
        // Put the node engine on the crossover's basis; this normally takes no iterations.
        // Without a basis (the interior point did not converge) the dual simplex solves the
        // root itself, which also settles "infeasible or unbounded".
        let warm: WarmStart = analysis.finalBasis.map { .basis($0) } ?? .none
        let outcome = try await w.engine.run(method: .dual, warmStart: warm, cutoff: nil, iterationLimit: nil, gate: &gate)
        w.rootSeconds = secondsSince(started)
        return try nodeResult(outcome)
    }

    public func solveNode(
        _ w: inout InteriorPointNodeWorker, changes: [BoundChange], parent: Basis, cutoff: Double?,
        iterationLimit: Int, gate: inout WorkGate
    ) async throws -> NodeLPResult<Basis> {
        try nodeResult(
            try await w.engine.run(
                method: .dual, warmStart: .incremental(parent: parent, changes: changes), cutoff: cutoff,
                iterationLimit: iterationLimit, gate: &gate))
    }

    public func probe(
        _ w: inout InteriorPointNodeWorker, changes: [BoundChange], parent: Basis, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> Double? {
        try await simplexProbe(&w.engine, changes: changes, parent: parent, iterationLimit: iterationLimit, gate: &gate)
    }

    public func rootAnalysis(_ result: NodeLPResult<Basis>, worker: borrowing InteriorPointNodeWorker) -> InteriorPointAnalysis {
        if let root = worker.root, root.status == .optimal { return root }
        // The interior point did not deliver the root; describe what the dual simplex found.
        var record = SolveRecord(status: .noSolution(stoppedBy: .iterationLimit), seconds: worker.rootSeconds)
        var crossover: SimplexAnalysis? = nil
        if let outcome = worker.engine.lastOutcome {
            let simplex = worker.engine.analysis(from: outcome, seconds: worker.rootSeconds)
            record = simplex.base
            crossover = simplex
        }
        if let root = worker.root {
            record.warnings.append("the interior point ended with \(root.status); the root was solved by the dual simplex")
        }
        return InteriorPointAnalysis(
            base: record, iterations: worker.root?.iterations ?? 0, finalMu: worker.root?.finalMu ?? 0,
            primalResidual: worker.root?.primalResidual ?? 0, dualResidual: worker.root?.dualResidual ?? 0,
            crossover: crossover)
    }
}
