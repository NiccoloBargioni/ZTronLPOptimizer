// Workers: node processing, branching, heuristics and reduced-cost fixing (specification
// §9.4, §9.5).

import Atomics
import ZTronLPCore
import ZTronLPNumerics

/// A failure of the search itself, reported as `.numericalFailure` (rule L5).
enum SearchFailure: Error {
    /// A node LP hit its iteration limit on the first attempt, with four times the budget,
    /// and cold from the root state.
    case iterationLimit(path: String)

    var message: String {
        switch self {
        case .iterationLimit(let path):
            return "a node LP hit its iteration limit three times, the last from the root basis; path: \(path)"
        }
    }
}

/// What processing one node produced.
struct Expansion<State: Sendable>: Sendable {
    var children: [NodeDraft<State>]
    /// LP iterations spent on the node, its probes and its heuristics.
    var iterations: Int
}

/// Per-worker scratch state.
struct WorkerScratch: Sendable {
    /// Tracks how often fp64 verification contradicts the `batchedActivity` kernel (§6.4).
    var kernelGuard = KernelDisagreementGuard()
}

/// The outcome of choosing a branching variable.
struct BranchDecision: Sendable {
    var column: Int
    var value: Double
    var downFeasible = true
    var upFeasible = true
    /// LP bounds of the children, when a probe established them.
    var downBound: Double? = nil
    var upBound: Double? = nil
    /// Expected objective degradation of each child, for the best-estimate.
    var downEstimate = 0.0
    var upEstimate = 0.0
}

/// Everything the workers of one search share. Immutable, hence `Sendable`; the mutable state
/// is in the `SearchTree` actor and in each worker's private engine.
struct TreeSearch<Engine: NodeLPStrategy>: Sendable {
    typealias State = Engine.State

    let engine: Engine
    let lp: CompiledLP
    let isInteger: [Bool]
    let branching: BranchingRule
    let heuristics: Heuristics
    let gap: Gap
    let objectiveStep: Double
    let integrality: Double
    let feasibility: Double
    let nodeIterationLimit: Int
    let tree: SearchTree<Engine.State>
    let sink: EventSink
    let deadline: Deadline
    let rootState: NodeState<Engine.State>
    let budget: ConcurrencyBudget
    let context: SolveContext
    let evaluator: (any BatchedActivityEvaluating)?
    let seed: UInt64
    /// −1 for a maximization model: reported values are the negated internal ones.
    let flip: Double

    /// Strong-branching probes are capped at 50 simplex iterations (§9.5).
    static var probeIterationLimit: Int { 50 }
    /// At most this many unreliable candidates are strong-branched at one node.
    static var maxProbedCandidates: Int { 8 }

    // MARK: - Cutoff

    /// The value a node's bound must stay below to be worth solving, for a given incumbent.
    func cutoff(for incumbent: Double) -> Double {
        guard incumbent < .infinity else { return .infinity }
        if objectiveStep > 0 {
            return incumbent - objectiveStep + 1e-9 * Swift.max(1, Swift.abs(incumbent))
        }
        return incumbent - gap.slack(for: incumbent)
    }

    /// The cutoff for the current incumbent, read lock-free (rule C5): pruning never hops to
    /// the actor.
    func currentCutoff() -> Double {
        cutoff(for: Double(bitPattern: tree.incumbentBits.load(ordering: .acquiring)))
    }

    // MARK: - Worker loop (§9.4)

    /// Takes nodes from the tree until it closes. Every node taken is handed back exactly
    /// once — `finish` on success, `abandon` on a stop signal or a failure — which is the
    /// invariant the tree's termination detection rests on.
    func workerLoop(_ worker: inout Engine.Worker, first: Node<State>?) async {
        var gate = WorkGate(deadline: deadline)
        gate.stopFlag = tree.stopFlag
        var scratch = WorkerScratch()
        var next = first
        while true {
            let node: Node<State>
            if let diving = next {
                node = diving
                next = nil
            } else if let taken = await tree.next() {
                node = taken
            } else {
                break
            }
            do {
                let expansion = try await process(node, worker: &worker, gate: &gate, scratch: &scratch)
                next = await tree.finish(node, children: expansion.children, iterations: expansion.iterations)
                for event in await tree.progressEvents(flip: flip) { await sink.emit(event) }
            } catch let signal as StopSignal {
                // If the tree raised the flag itself the closing is a no-op: the first reason wins.
                await tree.abandon(node, closing: signal == .deadline ? .timeLimit : .cancelled)
            } catch let failure as SearchFailure {
                await tree.abandon(node, closing: .numericalFailure(failure.message))
            } catch {
                await tree.abandon(node, closing: .numericalFailure("\(error)"))
            }
        }
    }

    /// Processes a node: reduced-cost fixing from the parent, the node LP, pruning, and the
    /// expansion of what is left.
    func process(
        _ node: Node<State>, worker: inout Engine.Worker, gate: inout WorkGate, scratch: inout WorkerScratch
    ) async throws -> Expansion<State> {
        try await gate.tick()
        let cut = currentCutoff()
        if node.bound >= cut { return Expansion(children: [], iterations: 0) }

        var changes = node.changes
        if cut < .infinity, let parent = node.parentState {
            applyReducedCostFixing(parent, into: &changes, cutoff: cut, skipping: node.branch?.column)
        }

        // Rule L5: first attempt, then the budget × 4, then cold from the root state.
        let parentState = node.attempt >= 2 ? rootState.state : (node.parentState?.state ?? rootState.state)
        let limit = node.attempt >= 1 ? nodeIterationLimit * 4 : nodeIterationLimit
        let result = try await engine.solveNode(
            &worker, changes: changes, parent: parentState, cutoff: cut < .infinity ? cut : nil,
            iterationLimit: limit, gate: &gate)

        switch result.outcome {
        case .infeasible, .cutoff:
            return Expansion(children: [], iterations: result.iterations)

        case .unbounded:
            await tree.addWarning("a node LP was unbounded although the root LP was not; the node was dropped")
            return Expansion(children: [], iterations: result.iterations)

        case .limit:
            if node.attempt >= 2 {
                throw SearchFailure.iterationLimit(path: describe(node.changes))
            }
            let retry = NodeDraft(
                changes: node.changes, bound: node.bound, depth: node.depth, estimate: node.estimate,
                parentState: node.attempt == 0 ? node.parentState : nil, branch: node.branch,
                attempt: node.attempt + 1)
            return Expansion(children: [retry], iterations: result.iterations)

        case .optimal(let objective, let x, let reducedCosts):
            if let branch = node.branch, objective.isFinite, node.attempt == 0 {
                await tree.recordPseudocost(
                    column: Int(branch.column), up: branch.up,
                    gainPerUnit: Swift.max(0, objective - node.bound) / Swift.max(branch.fraction, 1e-9))
            }
            if objective >= currentCutoff() {
                return Expansion(children: [], iterations: result.iterations)
            }
            var expansion = try await expand(
                node: node, changes: changes, objective: objective, x: x, reducedCosts: reducedCosts,
                state: result.state, worker: &worker, gate: &gate, scratch: &scratch)
            expansion.iterations += result.iterations
            return expansion
        }
    }

    /// What follows an optimal node LP: an integral solution becomes the incumbent; otherwise
    /// the heuristics run, a branching variable is chosen and two children are created.
    func expand(
        node: Node<State>, changes: [BoundChange], objective: Double, x: [Double], reducedCosts: [Double],
        state: State, worker: inout Engine.Worker, gate: inout WorkGate, scratch: inout WorkerScratch
    ) async throws -> Expansion<State> {
        var iterations = 0
        var fractional: [(column: Int32, value: Double)] = []
        for column in lp.integerColumns {
            let v = x[Int(column)]
            if Swift.abs(v - v.rounded()) > integrality { fractional.append((column, v)) }
        }
        if fractional.isEmpty {
            var solution = x
            for column in lp.integerColumns { solution[Int(column)] = solution[Int(column)].rounded() }
            await offer(objective: objective, x: solution, node: node.id, source: "lp")
            return Expansion(children: [], iterations: 0)
        }

        if heuristics.rounding {
            await roundingHeuristic(x: x, node: node, scratch: &scratch)
        }
        if heuristics.diving, node.id % heuristics.divingInterval == 0 {
            iterations += try await dive(
                node: node, changes: changes, x: x, state: state, worker: &worker, gate: &gate)
        }
        if objective >= currentCutoff() {
            return Expansion(children: [], iterations: iterations)
        }

        guard let decision = try await chooseBranch(
            fractional: fractional, changes: changes, objective: objective, state: state, worker: &worker,
            gate: &gate, iterations: &iterations)
        else {
            // Both sides of some candidate are infeasible: so is the node.
            return Expansion(children: [], iterations: iterations)
        }

        let nodeState = NodeState(
            state: state, objective: objective, reducedCosts: Array(reducedCosts.prefix(lp.n)), values: x)
        let (lower, upper) = bounds(of: decision.column, in: changes)
        let down = decision.value.rounded(.down)
        func child(up: Bool) -> NodeDraft<State> {
            var childChanges = changes
            merge(
                BoundChange(column: Int32(decision.column), lower: up ? down + 1 : lower, upper: up ? upper : down),
                into: &childChanges)
            let probed = up ? decision.upBound : decision.downBound
            return NodeDraft(
                changes: childChanges, bound: Swift.max(objective, probed ?? objective), depth: node.depth + 1,
                estimate: objective + (up ? decision.upEstimate : decision.downEstimate), parentState: nodeState,
                branch: BranchRecord(
                    column: Int32(decision.column), up: up,
                    fraction: up ? down + 1 - decision.value : decision.value - down),
                attempt: 0)
        }
        var children: [NodeDraft<State>] = []
        if decision.downFeasible && decision.upFeasible {
            // Child order: the side nearer the LP value first.
            let downFirst = decision.value - down <= 0.5
            children = downFirst ? [child(up: false), child(up: true)] : [child(up: true), child(up: false)]
        } else if decision.downFeasible {
            children = [child(up: false)]
        } else if decision.upFeasible {
            children = [child(up: true)]
        }
        return Expansion(children: children, iterations: iterations)
    }

    // MARK: - Bound bookkeeping

    /// The bounds of a column at a node: the node's change for it, or the problem's bounds.
    func bounds(of column: Int, in changes: [BoundChange]) -> (lower: Double, upper: Double) {
        for change in changes where Int(change.column) == column { return (change.lower, change.upper) }
        return (lp.xl[column], lp.xu[column])
    }

    /// Adds a change, replacing an earlier one on the same column, so a path holds one entry
    /// per column.
    func merge(_ change: BoundChange, into changes: inout [BoundChange]) {
        if let index = changes.firstIndex(where: { $0.column == change.column }) {
            changes[index] = change
        } else {
            changes.append(change)
        }
    }

    func describe(_ changes: [BoundChange]) -> String {
        if changes.isEmpty { return "root" }
        let names = lp.names
        return changes.prefix(12).map { "\(names.column(Int($0.column))) in [\($0.lower), \($0.upper)]" }
            .joined(separator: ", ") + (changes.count > 12 ? ", … (\(changes.count) changes)" : "")
    }

    /// Reduced-cost fixing (§9.5): a column that was nonbasic at its lower bound in the
    /// parent LP, with reduced cost d_j > 0, cannot rise by more than (cutoff − z_LP)/d_j in
    /// any solution worth having; symmetric at the upper bound. For a binary column that
    /// fixes it; for a general integer it tightens the bound.
    func applyReducedCostFixing(
        _ parent: NodeState<State>, into changes: inout [BoundChange], cutoff: Double, skipping: Int32?
    ) {
        let slack = cutoff - parent.objective
        guard slack >= 0, slack.isFinite, parent.reducedCosts.count == lp.n, parent.values.count == lp.n else { return }
        var current: [Int32: (Double, Double)] = [:]
        for change in changes { current[change.column] = (change.lower, change.upper) }
        for column in lp.integerColumns where column != skipping {
            let j = Int(column)
            let d = parent.reducedCosts[j]
            if Swift.abs(d) <= 1e-9 { continue }
            let (lower, upper) = current[column] ?? (lp.xl[j], lp.xu[j])
            guard lower < upper else { continue }
            let value = parent.values[j]
            if d > 0, Swift.abs(value - lower) <= integrality {
                let room = (slack / d + 1e-9).rounded(.down)
                if lower + room < upper {
                    merge(BoundChange(column: column, lower: lower, upper: lower + room), into: &changes)
                }
            } else if d < 0, Swift.abs(value - upper) <= integrality {
                let room = (slack / -d + 1e-9).rounded(.down)
                if upper - room > lower {
                    merge(BoundChange(column: column, lower: upper - room, upper: upper), into: &changes)
                }
            }
        }
    }

    // MARK: - Incumbents

    /// Offers a solution to the tree and reports it when it is a new incumbent.
    func offer(objective: Double, x: [Double], node: Int, source: String) async {
        guard let events = await tree.offerIncumbent(
            objective: objective, x: x, node: node, source: source, reportedObjective: flip * objective)
        else { return }
        for event in events { await sink.emit(event) }
    }

    /// Whether a point satisfies every column and row bound, in Double.
    func isFeasible(_ point: [Double]) -> Bool {
        for j in 0..<lp.n {
            let v = point[j]
            if v < lp.xl[j] - feasibility * (1 + Swift.abs(lp.xl[j])) || v > lp.xu[j] + feasibility * (1 + Swift.abs(lp.xu[j])) {
                return false
            }
        }
        let activity = lp.a.multiply(point)
        for i in 0..<lp.m {
            let s = activity[i]
            if s < lp.rl[i] - feasibility * (1 + Swift.abs(lp.rl[i])) || s > lp.ru[i] + feasibility * (1 + Swift.abs(lp.ru[i])) {
                return false
            }
        }
        return true
    }

    // MARK: - Heuristics (§9.5)

    /// Simple rounding after every node LP: the nearest, the floor and the ceiling rounding
    /// of the integer columns. When the `batchedActivity` kernel is available a batch of
    /// randomized roundings goes to the GPU first, and the CPU re-evaluates every point it
    /// flags feasible in Double before that point becomes an incumbent (§6.4).
    func roundingHeuristic(x: [Double], node: Node<State>, scratch: inout WorkerScratch) async {
        func rounded(_ rule: (Double) -> Double) -> [Double] {
            var point = x
            for column in lp.integerColumns {
                let j = Int(column)
                point[j] = Swift.min(Swift.max(rule(x[j]), lp.xl[j].rounded(.up)), lp.xu[j].rounded(.down))
            }
            return point
        }
        var candidates: [[Double]] = [
            rounded { $0.rounded() },
            rounded { ($0 + integrality).rounded(.down) },
            rounded { ($0 - integrality).rounded(.up) },
        ]
        var best: (objective: Double, x: [Double])? = nil
        func consider(_ point: [Double]) {
            guard isFeasible(point) else { return }
            let objective = lp.internalObjective(at: point)
            if objective < (best?.objective ?? .infinity) { best = (objective, point) }
        }

        var screened = false
        let batch = heuristics.roundingBatch
        if let evaluator, !scratch.kernelGuard.isDisabled,
           KernelThresholds.allowsBatchedActivity(points: batch, nonzeros: lp.nnz, policy: context.metal) {
            // Randomized roundings: each integer column rounds up with probability equal to
            // its fractional part. The generator is seeded by the node, so the batch does not
            // depend on timing.
            var generator = seed ^ (UInt64(truncatingIfNeeded: node.id) &* 0x9E37_79B9_7F4A_7C15)
            func nextUniform() -> Double {
                generator &+= 0x9E37_79B9_7F4A_7C15
                var z = generator
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
            }
            while candidates.count < batch {
                candidates.append(rounded { value in
                    let floor = value.rounded(.down)
                    return value - floor > nextUniform() ? floor + 1 : floor
                })
            }
            var flat: [Double] = []
            flat.reserveCapacity(candidates.count * lp.n)
            for candidate in candidates { flat.append(contentsOf: candidate) }
            if let flags = await evaluator.evaluate(points: flat, count: candidates.count, tolerance: feasibility),
               flags.count == candidates.count {
                screened = true
                var flagged = 0
                var disagreements = 0
                for (k, flag) in flags.enumerated() where flag {
                    flagged += 1
                    let before = best?.objective
                    consider(candidates[k])
                    if !isFeasible(candidates[k]) { disagreements += 1 }
                    _ = before
                }
                if scratch.kernelGuard.record(candidates: flagged, disagreements: disagreements) {
                    let rate = Int((scratch.kernelGuard.disagreementRate * 100).rounded())
                    let text = "the batchedActivity kernel disagreed with fp64 verification on \(rate)% of the points it flagged and was disabled for this solve"
                    await tree.addWarning(text)
                    await sink.warn(text)
                }
            }
        }
        if !screened {
            for candidate in candidates.prefix(3) { consider(candidate) }
        }
        if let best, best.objective < currentCutoff() {
            await offer(objective: best.objective, x: best.x, node: node.id, source: "rounding")
        }
    }

    /// Fractional diving: repeatedly fix the integer column closest to an integer at that
    /// integer and re-solve, down to `divingMaxDepth` levels or `divingIterationLimit` LP
    /// iterations. Returns the LP iterations spent.
    func dive(
        node: Node<State>, changes: [BoundChange], x: [Double], state: State,
        worker: inout Engine.Worker, gate: inout WorkGate
    ) async throws -> Int {
        var used = 0
        var current = changes
        var point = x
        var parent = state
        var depth = 0
        while depth < heuristics.divingMaxDepth && used < heuristics.divingIterationLimit {
            var target = -1
            var smallest = Double.infinity
            for column in lp.integerColumns {
                let v = point[Int(column)]
                let distance = Swift.abs(v - v.rounded())
                if distance > integrality && distance < smallest {
                    smallest = distance
                    target = Int(column)
                }
            }
            if target < 0 {
                var solution = point
                for column in lp.integerColumns { solution[Int(column)] = solution[Int(column)].rounded() }
                if isFeasible(solution) {
                    await offer(objective: lp.internalObjective(at: solution), x: solution, node: node.id, source: "diving")
                }
                break
            }
            let (lower, upper) = bounds(of: target, in: current)
            let fixed = Swift.min(Swift.max(point[target].rounded(), lower), upper)
            merge(BoundChange(column: Int32(target), lower: fixed, upper: fixed), into: &current)
            let cut = currentCutoff()
            let result = try await engine.solveNode(
                &worker, changes: current, parent: parent, cutoff: cut < .infinity ? cut : nil,
                iterationLimit: Swift.max(1, heuristics.divingIterationLimit - used), gate: &gate)
            used += result.iterations
            guard case .optimal(let objective, let next, _) = result.outcome, objective < cut else { break }
            point = next
            parent = result.state
            depth += 1
        }
        return used
    }

    // MARK: - Branching (§9.5)

    /// Chooses the branching variable. Returns nil when a probe proves the node infeasible.
    func chooseBranch(
        fractional: [(column: Int32, value: Double)], changes: [BoundChange], objective: Double, state: State,
        worker: inout Engine.Worker, gate: inout WorkGate, iterations: inout Int
    ) async throws -> BranchDecision? {
        func fractionality(_ value: Double) -> Double {
            let down = value - value.rounded(.down)
            return Swift.min(down, 1 - down)
        }
        // Candidate order: most fractional first, ties to the lower column index.
        let order = fractional.indices.sorted {
            let (a, b) = (fractionality(fractional[$0].value), fractionality(fractional[$1].value))
            return a != b ? a > b : fractional[$0].column < fractional[$1].column
        }

        let reliability: Int
        let probeCount: Int
        switch branching {
        case .mostFractional:
            let pick = fractional[order[0]]
            return BranchDecision(column: Int(pick.column), value: pick.value)
        case .strong(let candidates):
            reliability = Int.max
            probeCount = Swift.max(1, candidates)
        case .pseudocost(let required):
            reliability = Swift.max(0, required)
            probeCount = Self.maxProbedCandidates
        }

        let snapshot = await tree.pseudocosts(for: fractional.map(\.column))
        // Candidates without enough observations in both directions are strong-branched.
        var toProbe: [Int] = []
        for index in order where toProbe.count < probeCount {
            let entry = snapshot.entries[index]
            if Swift.min(entry.downCount, entry.upCount) < reliability { toProbe.append(index) }
        }
        var probed = [(down: Double?, up: Double?)?](repeating: nil, count: fractional.count)
        if !toProbe.isEmpty {
            let results = try await runProbes(
                toProbe.map { fractional[$0] }, changes: changes, state: state, worker: &worker, gate: &gate)
            iterations += results.iterations
            for (k, index) in toProbe.enumerated() { probed[index] = results.bounds[k] }
        }

        var best: BranchDecision? = nil
        var bestScore = -Double.infinity
        for index in order {
            let candidate = fractional[index]
            let downFraction = candidate.value - candidate.value.rounded(.down)
            let upFraction = 1 - downFraction
            let entry = snapshot.entries[index]
            var decision = BranchDecision(column: Int(candidate.column), value: candidate.value)
            var downGain = (entry.down ?? snapshot.averageDown) * downFraction
            var upGain = (entry.up ?? snapshot.averageUp) * upFraction
            if let probe = probed[index] {
                if let bound = probe.down {
                    if bound == .infinity {
                        decision.downFeasible = false
                    } else {
                        downGain = Swift.max(0, bound - objective)
                        decision.downBound = bound
                        await tree.recordPseudocost(column: Int(candidate.column), up: false, gainPerUnit: downGain / downFraction)
                    }
                }
                if let bound = probe.up {
                    if bound == .infinity {
                        decision.upFeasible = false
                    } else {
                        upGain = Swift.max(0, bound - objective)
                        decision.upBound = bound
                        await tree.recordPseudocost(column: Int(candidate.column), up: true, gainPerUnit: upGain / upFraction)
                    }
                }
            }
            decision.downEstimate = downGain
            decision.upEstimate = upGain
            if !decision.downFeasible && !decision.upFeasible { return nil }
            if !decision.downFeasible || !decision.upFeasible {
                // One side is proven infeasible: branching here is a fixing, take it at once.
                return decision
            }
            let score = Swift.max(downGain, 1e-6) * Swift.max(upGain, 1e-6)
            if score > bestScore {
                bestScore = score
                best = decision
            }
        }
        return best
    }

    /// Strong-branching probes for a set of candidates, both directions each.
    ///
    /// Evaluated in parallel across candidates inside a nested task group governed by the
    /// `ConcurrencyBudget` (rule C7): when the budget grants slots, the candidates are spread
    /// over that many child tasks plus one, each with a private engine, while this task waits
    /// (its own slot is the "plus one"); when it grants none, the probes run inline.
    func runProbes(
        _ candidates: [(column: Int32, value: Double)], changes: [BoundChange], state: State,
        worker: inout Engine.Worker, gate: inout WorkGate
    ) async throws -> (bounds: [(down: Double?, up: Double?)], iterations: Int) {
        let limit = Self.probeIterationLimit
        func childChanges(_ candidate: (column: Int32, value: Double), up: Bool) -> [BoundChange] {
            var result = changes
            let (lower, upper) = bounds(of: Int(candidate.column), in: changes)
            let down = candidate.value.rounded(.down)
            merge(
                BoundChange(column: candidate.column, lower: up ? down + 1 : lower, upper: up ? upper : down),
                into: &result)
            return result
        }

        var extra = 0
        if candidates.count >= 4 {
            extra = await budget.borrow(upTo: Swift.min(candidates.count, 8) - 1)
        }
        if extra == 0 {
            var results: [(down: Double?, up: Double?)] = []
            results.reserveCapacity(candidates.count)
            for candidate in candidates {
                let down = try await engine.probe(
                    &worker, changes: childChanges(candidate, up: false), parent: state, iterationLimit: limit, gate: &gate)
                let up = try await engine.probe(
                    &worker, changes: childChanges(candidate, up: true), parent: state, iterationLimit: limit, gate: &gate)
                results.append((down, up))
            }
            // Probe iterations are bounded by the cap; count the cap's worth at most.
            return (results, candidates.count * 2 * limit / 4)
        }

        let tasks = extra + 1
        let plans: [[(index: Int, down: [BoundChange], up: [BoundChange])]] = (0..<tasks).map { task in
            stride(from: task, to: candidates.count, by: tasks).map {
                ($0, childChanges(candidates[$0], up: false), childChanges(candidates[$0], up: true))
            }
        }
        let search = self
        let gathered: [(Int, Double?, Double?)]
        do {
            gathered = try await withThrowingTaskGroup(of: [(Int, Double?, Double?)].self) { group in
                for plan in plans {
                    group.addTask {
                        var own = search.engine.makeWorker(lp: search.lp, context: search.context)
                        var ownGate = WorkGate(deadline: search.deadline)
                        ownGate.stopFlag = search.tree.stopFlag
                        var part: [(Int, Double?, Double?)] = []
                        for item in plan {
                            let down = try await search.engine.probe(
                                &own, changes: item.down, parent: state, iterationLimit: limit, gate: &ownGate)
                            let up = try await search.engine.probe(
                                &own, changes: item.up, parent: state, iterationLimit: limit, gate: &ownGate)
                            part.append((item.index, down, up))
                        }
                        return part
                    }
                }
                var all: [(Int, Double?, Double?)] = []
                for try await part in group { all.append(contentsOf: part) }
                return all
            }
        } catch {
            await budget.giveBack(extra)
            throw error
        }
        await budget.giveBack(extra)
        var results = [(down: Double?, up: Double?)](repeating: (nil, nil), count: candidates.count)
        for (index, down, up) in gathered { results[index] = (down, up) }
        return (results, candidates.count * 2 * limit / 4)
    }
}
