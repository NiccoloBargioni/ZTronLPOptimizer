// The public branch-and-bound strategy (specification §9, §11.2) and its analysis (§11.3).

import ZTronLPCore
import ZTronLPInteriorPoint
import ZTronLPNumerics
import ZTronLPSimplex

/// How the branching variable is chosen (§9.5).
public enum BranchingRule: Sendable, Hashable {
    /// The integer column whose LP value is farthest from an integer.
    case mostFractional
    /// Pseudocost branching with reliability: a candidate is strong-branched until it has
    /// `reliability` pseudocost observations per direction. Probes are capped at 50 simplex
    /// iterations.
    case pseudocost(reliability: Int)
    /// Strong branching on the `candidates` most fractional columns.
    case strong(candidates: Int)
}

/// Which open node a worker takes next (§9.5).
public enum NodeSelection: Sendable, Hashable {
    /// Pure best-bound.
    case bestBound
    /// Best-bound with plunging: after a node the worker dives into one child while
    /// depth < `maxDepth` and the child bound is within 10% of the global best bound.
    case bestBoundWithPlunging(maxDepth: Int)
    /// Depth-first.
    case depthFirst
}

/// The primal heuristics that run during the search (§9.5).
public struct Heuristics: Sendable, Hashable {
    /// Simple rounding after every node LP.
    public var rounding: Bool
    /// Fractional diving at the root and every `divingInterval` nodes.
    public var diving: Bool
    public var divingInterval: Int
    public var divingMaxDepth: Int
    /// LP iterations one dive may spend.
    public var divingIterationLimit: Int
    /// Randomized rounding candidates generated per node when the `batchedActivity` kernel
    /// is available to screen them (§6.4); at most 1,024.
    public var roundingBatch: Int

    public init(
        rounding: Bool = true, diving: Bool = true, divingInterval: Int = 100, divingMaxDepth: Int = 50,
        divingIterationLimit: Int = 500, roundingBatch: Int = 128
    ) {
        self.rounding = rounding
        self.diving = diving
        self.divingInterval = Swift.max(1, divingInterval)
        self.divingMaxDepth = divingMaxDepth
        self.divingIterationLimit = divingIterationLimit
        self.roundingBatch = Swift.min(Swift.max(0, roundingBatch), KernelThresholds.batchedActivityMaxBatch)
    }

    /// Rounding after every node, diving at the root and every 100 nodes (depth ≤ 50, LP
    /// iterations ≤ 500).
    public static let `default` = Heuristics()
    /// No heuristics.
    public static let none = Heuristics(rounding: false, diving: false)
}

/// The optimality gap at which the search stops.
public struct Gap: Sendable, Hashable {
    /// (incumbent − bound) / max(1, |incumbent|).
    public var relative: Double
    /// incumbent − bound.
    public var absolute: Double

    public init(relative: Double = 1e-4, absolute: Double = 1e-6) {
        self.relative = relative
        self.absolute = absolute
    }

    /// The difference between incumbent and bound that counts as closed.
    func slack(for incumbent: Double) -> Double {
        Swift.max(absolute, relative * Swift.max(1, Swift.abs(incumbent)))
    }
}

/// One improvement of the incumbent.
public struct IncumbentEvent: Sendable, Hashable {
    /// In the model's own sense.
    public let objective: Double
    /// The node that produced it (0 is the root).
    public let node: Int
    public let seconds: Double
    /// "lp", "rounding" or "diving".
    public let source: String
}

/// The MIP result: status, incumbent, proven bound, gap, node and iteration counts and the
/// incumbent history, decorating the engine's own full analysis of the root LP (§9.6).
public struct BranchAndBoundAnalysis<RootAnalysis: SolutionAnalysis>: AnalysisDecorator, BasisProviding {
    /// MIP status, incumbent objective, proven bound.
    public let base: SolveRecord
    /// The engine's full analysis of the root LP.
    public let root: RootAnalysis
    /// The relative gap between incumbent and bound; `nil` without an incumbent.
    public let gap: Double?
    public let nodesProcessed: Int
    public let nodesOpen: Int
    public let lpIterations: Int
    public let incumbents: Int
    /// Objective, node, seconds, source.
    public let incumbentHistory: [IncumbentEvent]

    public init(
        base: SolveRecord, root: RootAnalysis, gap: Double?, nodesProcessed: Int, nodesOpen: Int,
        lpIterations: Int, incumbents: Int, incumbentHistory: [IncumbentEvent]
    ) {
        self.base = base
        self.root = root
        self.gap = gap
        self.nodesProcessed = nodesProcessed
        self.nodesOpen = nodesOpen
        self.lpIterations = lpIterations
        self.incumbents = incumbents
        self.incumbentHistory = incumbentHistory
    }

    /// The root LP's basis, when the engine's analysis has one.
    public var finalBasis: Basis? { (root as? any BasisProviding)?.finalBasis }
}

/// Parallel branch and bound. The node LP engine is a `NodeLPStrategy`: `Simplex(.primal)` by
/// default, `Simplex(.dual)`, `InteriorPoint` or a user-defined engine.
///
/// On the default: the dual simplex is the textbook fit for branch and bound — after a bound
/// change the parent basis stays dual feasible, so the dual method restarts with no phase 1,
/// and its iterates give valid lower bounds that allow a cutoff before optimality. The primal
/// default remains correct (`.incremental` warm starts run the composite phase 1 from the
/// parent basis) but node LPs cannot stop early on cutoff. The specification expects 1.5–3×
/// fewer node iterations with `BranchAndBound(engine: Simplex(.dual))`; on the MIPLIB 3 set
/// the primal engine took 0.60–1.65× the dual's (README, measured performance).
public struct BranchAndBound<Engine: NodeLPStrategy>: SolverStrategy {
    public let engine: Engine
    public let branching: BranchingRule
    public let nodeSelection: NodeSelection
    public let heuristics: Heuristics
    public let gap: Gap
    public let nodeLimit: Int?
    /// Single worker, depth-first with best-bound restarts every 1,000 nodes: identical
    /// results and identical event sequences across runs (rule C9).
    public let deterministic: Bool
    public let seed: UInt64

    public init(
        engine: Engine,
        branching: BranchingRule = .pseudocost(reliability: 4),
        nodeSelection: NodeSelection = .bestBoundWithPlunging(maxDepth: 32),
        heuristics: Heuristics = .default,
        gap: Gap = Gap(relative: 1e-4, absolute: 1e-6),
        nodeLimit: Int? = nil,
        deterministic: Bool = false,
        seed: UInt64 = 0
    ) {
        self.engine = engine
        self.branching = branching
        self.nodeSelection = nodeSelection
        self.heuristics = heuristics
        self.gap = gap
        self.nodeLimit = nodeLimit
        self.deterministic = deterministic
        self.seed = seed
    }

    public var engineName: String { "BranchAndBound<\(engine.engineName)>" }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> BranchAndBoundAnalysis<Engine.Analysis> {
        let started = Deadline.now
        let sink = EventSink(context.progress)
        await sink.emit(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        do {
            let analysis = try await search(problem, context: context, sink: sink, started: started)
            await sink.finish(status: analysis.status, seconds: analysis.seconds)
            return analysis
        } catch {
            await sink.finish(status: .numericalFailure("\(error)"), seconds: secondsSince(started))
            throw error
        }
    }

    // MARK: - The search

    private func search(
        _ problem: CompiledLP, context: SolveContext, sink: EventSink, started: UInt64
    ) async throws -> BranchAndBoundAnalysis<Engine.Analysis> {
        let deadline = Deadline.after(seconds: context.timeLimit)
        let nested = context.nested()
        var warnings: [String] = []

        // Bound-only presolve: integer bounds rounded inward and singleton rows turned into
        // bounds, with every row and column kept so that node LPs, bases and bound changes
        // all live in the original column space (and the root analysis describes the
        // problem as given).
        let tolerances = Tolerances.default
        let pre = Presolve.run(problem, tolerances: tolerances, mode: .boundsOnly)
        var presolveInfeasible: String? = nil
        if case .infeasible(let reason) = pre.outcome { presolveInfeasible = reason }
        let lp = presolveInfeasible == nil ? pre.reduced : problem

        let threads = context.resolvedThreads
        let workerCount = deterministic ? 1 : threads
        let tree = SearchTree<Engine.State>(
            columns: lp.n, selection: nodeSelection, deterministic: deterministic, gap: gap,
            nodeLimit: nodeLimit, memoryBudget: MemoryBudget.resolve(context),
            objectiveStep: Self.objectiveStep(of: lp), started: started)

        func finished(
            _ status: SolveStatus, root: Engine.Analysis, objective: Double? = nil, bound: Double? = nil,
            primal: [Double]? = nil, gap: Double? = nil, summary: TreeSummary? = nil
        ) -> BranchAndBoundAnalysis<Engine.Analysis> {
            BranchAndBoundAnalysis(
                base: SolveRecord(
                    status: status, objectiveValue: objective, bound: bound, primal: primal,
                    seconds: secondsSince(started), warnings: warnings + (summary?.warnings ?? [])),
                root: root, gap: gap, nodesProcessed: summary?.nodesProcessed ?? 0,
                nodesOpen: summary?.nodesOpen ?? 0, lpIterations: summary?.lpIterations ?? 0,
                incumbents: summary?.incumbentHistory.count ?? 0,
                incumbentHistory: summary?.incumbentHistory ?? [])
        }

        // MARK: Root LP

        var worker = engine.makeWorker(lp: lp, context: nested)
        var gate = WorkGate(deadline: deadline)
        gate.stopFlag = tree.stopFlag
        let rootResult: NodeLPResult<Engine.State>
        do {
            rootResult = try await engine.solveRoot(&worker, gate: &gate)
        } catch let signal as StopSignal {
            // Stopped before the root LP finished. The engine, run as a plain strategy under
            // the same stop condition, returns at once with the matching status; that is the
            // root analysis.
            var stopped = nested.silenced()
            if signal == .deadline { stopped.timeLimit = 0 }
            let root = try await engine.solve(lp, context: stopped)
            return finished(.noSolution(stoppedBy: signal.stopReason), root: root)
        }
        let rootAnalysis = engine.rootAnalysis(rootResult, worker: worker)
        let rootIterations = rootResult.iterations

        if let reason = presolveInfeasible {
            warnings.append("bound tightening found the model infeasible: \(reason)")
            return finished(.infeasible, root: rootAnalysis)
        }
        let rootObjective: Double
        let rootX: [Double]
        let rootReducedCosts: [Double]
        switch rootResult.outcome {
        case .infeasible:
            return finished(.infeasible, root: rootAnalysis)
        case .unbounded:
            // An unbounded relaxation leaves the integer problem either unbounded or infeasible.
            if lp.hasIntegerColumns {
                warnings.append("the LP relaxation is unbounded")
                return finished(.infeasibleOrUnbounded, root: rootAnalysis)
            }
            return finished(.unbounded, root: rootAnalysis)
        case .limit, .cutoff:
            return finished(.numericalFailure("the root LP did not finish within its iteration limit"), root: rootAnalysis)
        case .optimal(let objective, let x, let reducedCosts):
            rootObjective = objective
            rootX = x
            rootReducedCosts = reducedCosts
        }

        if !lp.hasIntegerColumns {
            // A pure LP: the root is the answer.
            let objective = lp.reportedObjective(rootObjective)
            var only = TreeSummary(
                closeReason: .complete, incumbent: Incumbent(objective: rootObjective, x: rootX),
                provenBound: rootObjective, relativeGap: 0, nodesProcessed: 1, nodesOpen: 0,
                lpIterations: rootIterations, incumbentHistory: [], warnings: [], waiters: 0)
            only = only.with(history: [IncumbentEvent(objective: objective, node: 0, seconds: secondsSince(started), source: "lp")])
            await sink.emit(.newIncumbent(objective: objective, node: 0, source: "lp"))
            return finished(.optimal, root: rootAnalysis, objective: objective, bound: objective, primal: rootX, gap: 0, summary: only)
        }

        // MARK: Tree search

        let rootState = NodeState(
            state: rootResult.state, objective: rootObjective,
            reducedCosts: Array(rootReducedCosts.prefix(lp.n)), values: rootX)
        var evaluator: (any BatchedActivityEvaluating)? = nil
        if heuristics.rounding, let provider = context.candidateKernels {
            evaluator = await provider.activityEvaluator(for: lp, policy: context.metal)
        }
        let search = TreeSearch(
            engine: engine, lp: lp, isInteger: lp.integerMask(), branching: branching, heuristics: heuristics,
            gap: gap, objectiveStep: Self.objectiveStep(of: lp), integrality: tolerances.integrality,
            feasibility: tolerances.primalFeasibility, nodeIterationLimit: Swift.max(1_000, 10 * (lp.m + lp.n)),
            tree: tree, sink: sink, deadline: deadline, rootState: rootState,
            budget: ConcurrencyBudget(threads: threads, occupied: workerCount), context: nested,
            evaluator: evaluator, seed: seed, flip: lp.sense == .maximize ? -1 : 1)

        // The root is node 0.
        let rootNode = Node<Engine.State>(
            id: 0, changes: [], bound: rootObjective, depth: 0, estimate: rootObjective, parentState: nil,
            branch: nil, attempt: 0)
        var rootIterationsTotal = rootIterations
        var rootChildren: [NodeDraft<Engine.State>] = []
        var stoppedAtRoot: StopSignal? = nil
        var rootScratch = WorkerScratch()
        do {
            let expansion = try await search.expand(
                node: rootNode, changes: [], objective: rootObjective, x: rootX, reducedCosts: rootReducedCosts,
                state: rootResult.state, worker: &worker, gate: &gate, scratch: &rootScratch)
            rootChildren = expansion.children
            rootIterationsTotal += expansion.iterations
        } catch let signal as StopSignal {
            stoppedAtRoot = signal
        } catch let failure as SearchFailure {
            await tree.close(.numericalFailure(failure.message))
        }
        let first = await tree.begin(root: rootNode, children: rootChildren, iterations: rootIterationsTotal)
        for event in await tree.progressEvents(flip: search.flip) { await sink.emit(event) }
        if let signal = stoppedAtRoot {
            await tree.close(signal == .deadline ? .timeLimit : .cancelled)
        }

        if workerCount == 1 {
            // One worker: reuse the root engine, whose basis is the root's.
            await search.workerLoop(&worker, first: first)
        } else {
            if let first { await tree.abandon(first) }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        // Private engine, private buffers.
                        var own = search.engine.makeWorker(lp: search.lp, context: search.context)
                        await search.workerLoop(&own, first: nil)
                    }
                }
                await group.waitForAll()
            }
        }

        // MARK: Result

        let summary = await tree.summary()
        let incumbent = summary.incumbent
        let hasIncumbent = incumbent.x != nil
        let objective = hasIncumbent ? lp.reportedObjective(incumbent.objective) : nil
        var boundValue = summary.provenBound
        let status: SolveStatus
        switch summary.closeReason {
        case .complete:
            status = hasIncumbent ? .optimal : .infeasible
            if hasIncumbent { boundValue = incumbent.objective }
        case .gapReached:
            status = .optimal
        case .nodeLimit:
            status = hasIncumbent ? .feasible(stoppedBy: .nodeLimit) : .noSolution(stoppedBy: .nodeLimit)
        case .timeLimit:
            status = hasIncumbent ? .feasible(stoppedBy: .timeLimit) : .noSolution(stoppedBy: .timeLimit)
        case .cancelled:
            status = hasIncumbent ? .feasible(stoppedBy: .cancelled) : .noSolution(stoppedBy: .cancelled)
        case .memoryBudget:
            status = hasIncumbent ? .feasible(stoppedBy: .memoryBudget) : .noSolution(stoppedBy: .memoryBudget)
        case .numericalFailure(let message):
            status = .numericalFailure(message)
        }
        let bound: Double? = boundValue.isFinite ? lp.reportedObjective(boundValue) : nil
        var relativeGap: Double? = nil
        if hasIncumbent {
            relativeGap = boundValue.isFinite
                ? Swift.max(0, incumbent.objective - boundValue) / Swift.max(1, Swift.abs(incumbent.objective))
                : .infinity
        }
        return finished(
            status, root: rootAnalysis, objective: objective, bound: bound, primal: incumbent.x,
            gap: relativeGap, summary: summary)
    }

    /// The smallest amount by which the objective can improve when every column with a
    /// nonzero cost is integer and the costs share a common divisor; 0 otherwise.
    static func objectiveStep(of lp: CompiledLP) -> Double {
        let isInteger = lp.integerMask()
        var costs: [Double] = []
        for j in 0..<lp.n where lp.c[j] != 0 {
            guard isInteger[j] else { return 0 }
            costs.append(Swift.abs(lp.c[j]))
        }
        guard !costs.isEmpty else { return 0 }
        var scale = 1.0
        for _ in 0...6 {
            var integral = true
            var divisor: Int64 = 0
            for cost in costs {
                let scaled = cost * scale
                let rounded = scaled.rounded()
                guard Swift.abs(scaled - rounded) <= 1e-9 * Swift.max(1, scaled), rounded < 9e15 else {
                    integral = false
                    break
                }
                var a = Int64(rounded)
                var b = divisor
                while b != 0 { (a, b) = (b, a % b) }
                divisor = a
            }
            if integral, divisor > 0 { return Double(divisor) / scale }
            scale *= 10
        }
        return 0
    }
}

extension BranchAndBound where Engine == Simplex {
    /// The required default: `Simplex(.primal)` at every node; the other parameters as above.
    public init(
        branching: BranchingRule = .pseudocost(reliability: 4),
        nodeSelection: NodeSelection = .bestBoundWithPlunging(maxDepth: 32),
        heuristics: Heuristics = .default,
        gap: Gap = Gap(relative: 1e-4, absolute: 1e-6),
        nodeLimit: Int? = nil,
        deterministic: Bool = false,
        seed: UInt64 = 0
    ) {
        self.init(
            engine: Simplex(.primal), branching: branching, nodeSelection: nodeSelection, heuristics: heuristics,
            gap: gap, nodeLimit: nodeLimit, deterministic: deterministic, seed: seed)
    }
}

extension TreeSummary {
    func with(history: [IncumbentEvent]) -> TreeSummary {
        TreeSummary(
            closeReason: closeReason, incumbent: incumbent, provenBound: provenBound, relativeGap: relativeGap,
            nodesProcessed: nodesProcessed, nodesOpen: nodesOpen, lpIterations: lpIterations,
            incumbentHistory: history, warnings: warnings, waiters: waiters)
    }
}
