// Node and tree data, the search tree actor and termination detection (specification §9.2, §9.3).

import Atomics
import HeapModule
import ZTronLPCore
import ZTronLPNumerics

/// The parent's warm-start state and LP facts, shared by the parent's children.
///
/// Immutable: every stored property is a `let` of a `Sendable` type, so the class is
/// `Sendable` without any unchecked conformance. A processed node yields at most two children
/// that reference one `NodeState`, so the tree holds one basis per processed node with open
/// children, not one per open node.
final class NodeState<State: Sendable>: Sendable {
    let state: State
    /// The parent's LP objective (minimization form).
    let objective: Double
    /// The parent's structural reduced costs, for reduced-cost fixing at the children.
    let reducedCosts: [Double]
    /// The parent's structural LP values; fixing needs to know which bound a column sat on.
    let values: [Double]
    let approximateBytes: Int

    init(state: State, objective: Double, reducedCosts: [Double], values: [Double]) {
        self.state = state
        self.objective = objective
        self.reducedCosts = reducedCosts
        self.values = values
        let stateBytes = (state as? any NodeStateSizing)?.approximateBytes ?? MemoryLayout<State>.stride
        approximateBytes = stateBytes + (reducedCosts.count + values.count) * MemoryLayout<Double>.stride + 64
    }
}

/// The branching decision that created a node; the node's LP turns it into a pseudocost
/// observation.
struct BranchRecord: Sendable, Hashable {
    let column: Int32
    let up: Bool
    /// The distance the branched variable had to move to satisfy the branch, in (0, 1).
    let fraction: Double
}

/// A node of the search tree.
struct Node<State: Sendable>: Sendable {
    let id: Int
    /// Full path from the root, one entry per changed column, length ≤ depth plus the fixings.
    let changes: [BoundChange]
    /// Parent LP objective (valid lower bound for min).
    let bound: Double
    let depth: Int
    /// Pseudocost-based best-estimate.
    let estimate: Double
    /// Immutable class holding the parent's state; shared by siblings. `nil` warm-starts from
    /// the root state instead.
    let parentState: NodeState<State>?
    let branch: BranchRecord?
    /// 0 for a first attempt, 1 after one iteration-limit retry (budget × 4), 2 for the cold
    /// attempt from the root state (rule L5).
    let attempt: Int

    var approximateBytes: Int {
        changes.count * MemoryLayout<BoundChange>.stride + 96 + (parentState?.approximateBytes ?? 0)
    }
}

/// A node as a worker creates it; the tree assigns the id.
struct NodeDraft<State: Sendable>: Sendable {
    var changes: [BoundChange]
    var bound: Double
    var depth: Int
    var estimate: Double
    var parentState: NodeState<State>?
    var branch: BranchRecord?
    var attempt: Int = 0
}

/// Heap entry: nodes ordered by a two-part key chosen by the node selection rule.
struct OpenNode<State: Sendable>: Comparable, Sendable {
    let primary: Double
    let secondary: Int
    let node: Node<State>

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.primary != rhs.primary ? lhs.primary < rhs.primary : lhs.secondary < rhs.secondary
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
    }
}

/// The incumbent: the best integral solution found so far (minimization form).
struct Incumbent: Sendable {
    var objective: Double
    var x: [Double]?
}

/// Why the tree stopped handing out nodes.
enum CloseReason: Sendable, Equatable {
    /// Every node was processed or pruned.
    case complete
    /// The gap between the incumbent and the proven bound is within tolerance.
    case gapReached
    case nodeLimit
    case timeLimit
    case cancelled
    case memoryBudget
    case numericalFailure(String)
}

/// One pseudocost table row: the average objective gain per unit of fractionality removed, in
/// each direction, with the number of observations behind it.
struct Pseudocost: Sendable {
    var downSum = 0.0
    var downCount = 0
    var upSum = 0.0
    var upCount = 0

    var down: Double? { downCount > 0 ? downSum / Double(downCount) : nil }
    var up: Double? { upCount > 0 ? upSum / Double(upCount) : nil }
}

/// The shared state of one branch-and-bound search (rule C2: shared mutable state lives in
/// actors).
///
/// Invariant (§9.3): every `next()` that returns a node is paired with exactly one `finish`
/// or `abandon`. Consequently `inFlight == 0 && open.isEmpty` holds if and only if the search
/// is complete, and a waiter is resumed either with a node or with `nil` under that condition
/// or after `close()`. No continuation can leak: `wake()` runs after every state change, and
/// on `close()` every waiter is resumed (rule L4).
actor SearchTree<State: Sendable> {
    // MARK: Configuration

    let selection: NodeSelection
    let deterministic: Bool
    let gap: Gap
    let nodeLimit: Int?
    let memoryBudget: Int
    /// Smallest possible improvement of the objective, when the objective is integral on
    /// integer columns; 0 otherwise.
    let objectiveStep: Double
    let started: UInt64

    // MARK: Shared, lock-free (rule C5)

    /// The incumbent objective as a bit pattern, read by workers without hopping to the actor.
    nonisolated let incumbentBits: ManagedAtomic<UInt64>
    /// Raised when the tree closes, so workers in the middle of an LP stop within one tick.
    nonisolated let stopFlag: StopFlag

    // MARK: State

    private var open = Heap<OpenNode<State>>()
    private var inFlight = 0
    private var inFlightBounds: [Int: Double] = [:]
    private var waiters: [CheckedContinuation<Node<State>?, Never>] = []
    private var closed = false
    private(set) var closeReason: CloseReason? = nil
    private(set) var incumbent = Incumbent(objective: .infinity, x: nil)

    private var nextID = 1
    private var openBytes = 0
    private var pseudocosts: [Pseudocost]
    private(set) var nodesProcessed = 0
    private(set) var lpIterations = 0
    private(set) var incumbentHistory: [IncumbentEvent] = []
    private(set) var warnings: [String] = []
    private var lastBound = -Double.infinity
    private var lastNodeReport: UInt64
    private var nodesSinceRestart = 0
    /// The bound of nodes that were pruned or dropped without being fully explored; the
    /// proven bound can never exceed it.
    private var prunedBound = Double.infinity

    init(
        columns: Int, selection: NodeSelection, deterministic: Bool, gap: Gap, nodeLimit: Int?,
        memoryBudget: Int, objectiveStep: Double, started: UInt64
    ) {
        self.selection = selection
        self.deterministic = deterministic
        self.gap = gap
        self.nodeLimit = nodeLimit
        self.memoryBudget = memoryBudget
        self.objectiveStep = objectiveStep
        self.started = started
        incumbentBits = ManagedAtomic<UInt64>(Double.infinity.bitPattern)
        stopFlag = StopFlag()
        pseudocosts = [Pseudocost](repeating: Pseudocost(), count: columns)
        lastNodeReport = started
    }

    // MARK: - The §9.3 protocol

    /// The next node to process, or `nil` when the search is over. Suspends while other
    /// workers may still produce nodes.
    func next() async -> Node<State>? {
        if let n = pop() {
            inFlight += 1
            inFlightBounds[n.id] = n.bound
            return n
        }
        if inFlight == 0 || closed {
            if !closed { close(.complete) }
            return nil
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Called exactly once per `next()` that returned a node. Pushes the children and returns
    /// the one the worker should dive into, if plunging applies; that child stays in flight.
    func finish(_ node: Node<State>, children: [NodeDraft<State>], iterations: Int) -> Node<State>? {
        inFlight -= 1
        inFlightBounds[node.id] = nil
        return absorb(children: children, iterations: iterations)
    }

    /// Records the root (node 0), which is solved before any worker asks for a node, and
    /// queues its children. Returns the child a single worker should start with, in flight.
    func begin(root: Node<State>, children: [NodeDraft<State>], iterations: Int) -> Node<State>? {
        absorb(children: children, iterations: iterations)
    }

    private func absorb(children: [NodeDraft<State>], iterations: Int) -> Node<State>? {
        nodesProcessed += 1
        nodesSinceRestart += 1
        lpIterations += iterations

        var created: [Node<State>] = []
        created.reserveCapacity(children.count)
        for draft in children {
            created.append(
                Node(
                    id: nextID, changes: draft.changes, bound: draft.bound, depth: draft.depth,
                    estimate: draft.estimate, parentState: draft.parentState, branch: draft.branch,
                    attempt: draft.attempt))
            nextID += 1
        }

        var dive: Node<State>? = nil
        if !closed, let first = created.first, shouldDive(into: first) {
            dive = first
            created.removeFirst()
        }
        created.forEach(push)
        if let dive {
            inFlight += 1
            inFlightBounds[dive.id] = dive.bound
        }
        if let limit = nodeLimit, nodesProcessed >= limit, !closed { close(.nodeLimit) }
        if !closed { checkGapAndMemory() }
        if closed, let abandoned = dive {
            // The tree closed while deciding: the dive never starts.
            inFlight -= 1
            inFlightBounds[abandoned.id] = nil
            push(abandoned)
            dive = nil
        }
        wake()
        return dive
    }

    /// Returns an interrupted node to the pool. Pairs with `next()` like `finish` does.
    func abandon(_ node: Node<State>, iterations: Int = 0) {
        inFlight -= 1
        inFlightBounds[node.id] = nil
        lpIterations += iterations
        push(node)
        wake()
    }

    /// Stops the search because of what happened on `node` — a stop signal, a failure — and
    /// returns the node to the pool, in one step.
    ///
    /// Closing first matters: `abandon` alone wakes a waiting worker with the node it was
    /// just given, and that worker would repeat the work that failed before a separate
    /// `close` could stop it. A closed tree hands out nothing.
    func abandon(_ node: Node<State>, closing reason: CloseReason, iterations: Int = 0) {
        close(reason)
        abandon(node, iterations: iterations)
    }

    /// Stops the search: cancellation, limits, the gap. The first reason wins; every waiter is
    /// resumed and every worker's gate sees the stop flag.
    func close(_ reason: CloseReason) {
        if !closed {
            closed = true
            closeReason = reason
            stopFlag.set()
        }
        wake()
    }

    private func wake() {
        while let w = waiters.popLast() {
            if let n = pop() {
                inFlight += 1
                inFlightBounds[n.id] = n.bound
                w.resume(returning: n)
            } else if inFlight == 0 || closed {
                if !closed { close(.complete) }
                w.resume(returning: nil)
            } else {
                waiters.append(w)
                return
            }
        }
    }

    // MARK: - Pool

    /// The value a node's bound must stay below to be worth solving.
    private var cutoff: Double {
        guard incumbent.objective < .infinity else { return .infinity }
        if objectiveStep > 0 {
            // Any better solution improves by at least one step of the integral objective.
            return incumbent.objective - objectiveStep + 1e-9 * Swift.max(1, Swift.abs(incumbent.objective))
        }
        return incumbent.objective - gap.slack(for: incumbent.objective)
    }

    private func key(for node: Node<State>) -> (Double, Int) {
        switch effectiveSelection {
        case .depthFirst:
            // Deepest first, newest first.
            return (-Double(node.depth), -node.id)
        case .bestBound, .bestBoundWithPlunging:
            // Best bound first; among equals the deeper node, then the older one.
            return (node.bound, -node.depth * 1_000_000 + node.id % 1_000_000)
        }
    }

    /// Deterministic mode searches depth-first (with best-bound restarts); otherwise the
    /// configured rule applies.
    private var effectiveSelection: NodeSelection {
        deterministic ? .depthFirst : selection
    }

    private func push(_ node: Node<State>) {
        if node.bound >= cutoff {
            prunedBound = Swift.min(prunedBound, node.bound)
            return
        }
        let (primary, secondary) = key(for: node)
        open.insert(OpenNode(primary: primary, secondary: secondary, node: node))
        openBytes += node.approximateBytes
    }

    private func pop() -> Node<State>? {
        guard !closed else { return nil }
        // Deterministic mode: every 1,000 nodes restart from the best-bound node.
        if deterministic, nodesSinceRestart >= 1_000, open.count > 1 {
            nodesSinceRestart = 0
            if let best = removeBestBound() { return best }
        }
        while let entry = open.popMin() {
            openBytes -= entry.node.approximateBytes
            if entry.node.bound >= cutoff {
                // Pruned by an incumbent found after the node was queued.
                prunedBound = Swift.min(prunedBound, entry.node.bound)
                continue
            }
            return entry.node
        }
        return nil
    }

    /// Removes and returns the open node with the smallest bound, whatever the heap order is.
    private func removeBestBound() -> Node<State>? {
        var entries = Array(open.unordered)
        guard let index = entries.indices.min(by: { entries[$0].node.bound < entries[$1].node.bound }) else {
            return nil
        }
        let best = entries.remove(at: index)
        open = Heap(entries)
        openBytes -= best.node.approximateBytes
        if best.node.bound >= cutoff {
            prunedBound = Swift.min(prunedBound, best.node.bound)
            return nil
        }
        return best.node
    }

    private func shouldDive(into child: Node<State>) -> Bool {
        guard child.bound < cutoff else { return false }
        switch effectiveSelection {
        case .depthFirst:
            return true
        case .bestBound:
            return false
        case .bestBoundWithPlunging(let maxDepth):
            // Dive while depth < maxDepth and the child bound is within 10% of the global best bound.
            guard child.depth < maxDepth else { return false }
            let best = Swift.min(open.min?.node.bound ?? .infinity, inFlightBounds.values.min() ?? .infinity, child.bound)
            return child.bound <= best + 0.1 * Swift.max(Swift.abs(best), 1e-9)
        }
    }

    // MARK: - Bounds, gap, memory

    /// The proven lower bound: the smallest bound of any node that is still open or in
    /// flight, never above the incumbent.
    var provenBound: Double {
        var bound = Swift.min(prunedBound, incumbent.objective)
        if let top = bestOpenBound() { bound = Swift.min(bound, top) }
        if let flying = inFlightBounds.values.min() { bound = Swift.min(bound, flying) }
        return bound
    }

    private func bestOpenBound() -> Double? {
        switch effectiveSelection {
        case .bestBound, .bestBoundWithPlunging:
            return open.min?.node.bound
        case .depthFirst:
            return open.unordered.lazy.map(\.node.bound).min()
        }
    }

    var nodesOpen: Int { open.count + inFlight }

    /// The relative gap between the incumbent and the proven bound; `nil` without an incumbent.
    var relativeGap: Double? {
        guard incumbent.objective < .infinity else { return nil }
        let bound = provenBound
        guard bound > -.infinity else { return .infinity }
        return Swift.max(0, incumbent.objective - bound) / Swift.max(1, Swift.abs(incumbent.objective))
    }

    private func checkGapAndMemory() {
        if incumbent.objective < .infinity, open.count + inFlight > 0 {
            let bound = provenBound
            if incumbent.objective - bound <= gap.slack(for: incumbent.objective) {
                close(.gapReached)
                return
            }
        }
        guard openBytes > memoryBudget else { return }
        // Over budget (rule L7): the lowest-priority open nodes drop their parent state and
        // will warm-start from the root state instead.
        var entries = Array(open.unordered).sorted()
        var index = entries.count - 1
        var bytes = openBytes
        var dropped = false
        while bytes > memoryBudget && index >= 0 {
            let entry = entries[index]
            if entry.node.parentState != nil {
                let node = entry.node
                let stripped = Node<State>(
                    id: node.id, changes: node.changes, bound: node.bound, depth: node.depth,
                    estimate: node.estimate, parentState: nil, branch: node.branch, attempt: node.attempt)
                bytes -= node.approximateBytes - stripped.approximateBytes
                entries[index] = OpenNode(primary: entry.primary, secondary: entry.secondary, node: stripped)
                dropped = true
            }
            index -= 1
        }
        if dropped {
            open = Heap(entries)
            openBytes = bytes
        }
        // Still over with nothing left to drop: stop, keeping the incumbent.
        if openBytes > memoryBudget { close(.memoryBudget) }
    }

    // MARK: - Incumbent

    /// Offers a feasible integral solution. Returns the events to report when it improves on
    /// the incumbent, or `nil` when it does not.
    func offerIncumbent(objective: Double, x: [Double], node: Int, source: String, reportedObjective: Double) -> [SolverEvent]? {
        guard incumbent.x == nil || objective < incumbent.objective - 1e-9 * Swift.max(1, Swift.abs(objective)) else {
            return nil
        }
        incumbent = Incumbent(objective: objective, x: x)
        incumbentBits.store(objective.bitPattern, ordering: .releasing)
        let seconds = secondsSince(started)
        incumbentHistory.append(IncumbentEvent(objective: reportedObjective, node: node, seconds: seconds, source: source))
        let events: [SolverEvent] = [.newIncumbent(objective: reportedObjective, node: node, source: source)]
        if !closed { checkGapAndMemory() }
        wake()
        return events
    }

    /// The pruning threshold for the workers' own checks.
    var currentCutoff: Double { cutoff }

    // MARK: - Pseudocosts

    func recordPseudocost(column: Int, up: Bool, gainPerUnit: Double) {
        guard column >= 0, column < pseudocosts.count, gainPerUnit.isFinite, gainPerUnit >= 0 else { return }
        if up {
            pseudocosts[column].upSum += gainPerUnit
            pseudocosts[column].upCount += 1
        } else {
            pseudocosts[column].downSum += gainPerUnit
            pseudocosts[column].downCount += 1
        }
    }

    /// The pseudocosts of the given columns, plus the averages over every column with
    /// observations (the stand-in for a column that has none).
    func pseudocosts(for columns: [Int32]) -> (entries: [Pseudocost], averageDown: Double, averageUp: Double) {
        var downTotal = 0.0
        var downCount = 0
        var upTotal = 0.0
        var upCount = 0
        for entry in pseudocosts {
            if let down = entry.down {
                downTotal += down
                downCount += 1
            }
            if let up = entry.up {
                upTotal += up
                upCount += 1
            }
        }
        return (
            columns.map { pseudocosts[Int($0)] }, downCount > 0 ? downTotal / Double(downCount) : 1,
            upCount > 0 ? upTotal / Double(upCount) : 1
        )
    }

    // MARK: - Reporting

    func addWarning(_ text: String) {
        warnings.append(text)
    }

    /// Events due after a node: an improved bound, and node counts at most every 100 ms
    /// (every 100 nodes in deterministic mode, so the event sequence does not depend on timing).
    ///
    /// `flip` is −1 for a maximization model, whose reported bound is the negated internal one.
    func progressEvents(flip: Double) -> [SolverEvent] {
        var events: [SolverEvent] = []
        let bound = provenBound
        if bound > lastBound + 1e-9 * Swift.max(1, Swift.abs(bound)), bound.isFinite {
            lastBound = bound
            events.append(.boundImproved(bound: flip * bound, gap: relativeGap ?? .infinity))
        }
        if deterministic {
            if nodesProcessed % 100 == 0 { events.append(.nodes(processed: nodesProcessed, open: nodesOpen)) }
        } else {
            let now = Deadline.now
            if now &- lastNodeReport >= 100_000_000 {
                lastNodeReport = now
                events.append(.nodes(processed: nodesProcessed, open: nodesOpen))
            }
        }
        return events
    }

    /// Everything the final analysis needs, read in one hop.
    func summary() -> TreeSummary {
        TreeSummary(
            closeReason: closeReason ?? .complete, incumbent: incumbent, provenBound: provenBound,
            relativeGap: relativeGap, nodesProcessed: nodesProcessed, nodesOpen: nodesOpen,
            lpIterations: lpIterations, incumbentHistory: incumbentHistory, warnings: warnings,
            waiters: waiters.count)
    }
}

/// A snapshot of the tree at the end of a search.
struct TreeSummary: Sendable {
    let closeReason: CloseReason
    let incumbent: Incumbent
    let provenBound: Double
    let relativeGap: Double?
    let nodesProcessed: Int
    let nodesOpen: Int
    let lpIterations: Int
    let incumbentHistory: [IncumbentEvent]
    let warnings: [String]
    /// Continuations still parked; always 0 after the search (rule L4).
    let waiters: Int
}
