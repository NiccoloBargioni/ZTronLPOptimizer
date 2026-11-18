// Parallel portfolio (specification §10.3).
//
// `threads` workers run the core with different seeds and strategies. They share, through
// actors, the incumbent (`IncumbentStore`) and short learned clauses (`ClauseExchange`, LBD ≤ 2
// and ≤ 8 literals, polled at every restart). The only state workers read without hopping to
// an actor is the incumbent's objective and the stop flag, both atomics (rule C5).
//
// Why sharing is sound under linear search. A worker derives its clauses from the constraints
// plus its current objective bound `obj ≤ z − 1`, where z is an incumbent that the store
// already holds. Such a clause may cut off solutions, but only solutions of value ≥ z, which
// cannot beat the store's incumbent. So when any worker reaches a contradiction at level 0,
// no solution better than the store's best exists — the store's best is optimal, and if the
// store is empty the model is infeasible — whatever mix of bounds the clauses came from.

import Atomics
import ZTronLPCore
import ZTronLPNumerics

/// What the workers of one solve read on their hot path.
final class SharedSearchState: Sendable {
    /// Raised when the answer is known (a proof, a feasibility solution, the gap closed).
    let stop = StopFlag()
    /// The integer objective of the best incumbent; `Int64.max` while there is none.
    let bestObjective = ManagedAtomic<Int64>(Int64.max)

    init() {}
}

/// The best solution found so far, the best proven bound, and the order of the events that
/// announce them.
actor IncumbentStore {
    struct Snapshot: Sendable {
        var objective: Int64?
        var values: [Int64]?
        var worker: Int?
        var incumbents: Int
        var lowerBound: Int64
        var gapReached: Bool
    }

    private let model: CPModel
    private let shared: SharedSearchState
    private let sink: EventSink
    private let relativeGap: Double
    private let absoluteGap: Double

    private var bestObjective: Int64? = nil
    private var bestValues: [Int64]? = nil
    private var bestWorker: Int? = nil
    private var incumbents = 0
    private var lowerBound = Int64.min
    private var gapReached = false

    /// Events wait here until the one task that is draining the queue delivers them, so they
    /// reach the sink in the order the store accepted them even though `offer` suspends.
    private var pendingEvents: [SolverEvent] = []
    private var draining = false

    init(model: CPModel, shared: SharedSearchState, sink: EventSink, relativeGap: Double, absoluteGap: Double) {
        self.model = model
        self.shared = shared
        self.sink = sink
        self.relativeGap = relativeGap
        self.absoluteGap = absoluteGap
    }

    /// Offers a solution. Returns true when it became the incumbent.
    func offer(objective: Int64, values: [Int64], worker: Int, conflicts: Int) async -> Bool {
        if let best = bestObjective, objective >= best { return false }
        bestObjective = objective
        bestValues = values
        bestWorker = worker
        incumbents += 1
        shared.bestObjective.store(objective, ordering: .releasing)
        pendingEvents.append(
            .newIncumbent(objective: model.reportedObjective(objective), node: conflicts, source: "cpsat[\(worker)]"))
        checkGap()
        await drain()
        return true
    }

    /// Reports a proven lower bound on the integer objective.
    func reportBound(_ bound: Int64) async {
        guard bound > lowerBound else { return }
        lowerBound = bound
        pendingEvents.append(.boundImproved(bound: model.reportedObjective(bound), gap: currentRelativeGap()))
        checkGap()
        await drain()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            objective: bestObjective, values: bestValues, worker: bestWorker, incumbents: incumbents,
            lowerBound: lowerBound, gapReached: gapReached)
    }

    /// (incumbent − bound) / max(1, |incumbent|) in the model's own units; +∞ without both.
    private func currentRelativeGap() -> Double {
        guard let best = bestObjective, lowerBound > .min else { return .infinity }
        let difference = Double(best - lowerBound) / model.objectiveScale
        return difference / Swift.max(1, Swift.abs(model.reportedObjective(best)))
    }

    /// The gap criterion of §6.5: stop when the incumbent is within the absolute or the
    /// relative MIP gap of the proven bound.
    private func checkGap() {
        guard !gapReached, let best = bestObjective, lowerBound > .min else { return }
        let difference = Double(best - lowerBound) / model.objectiveScale
        let allowed = Swift.max(absoluteGap, relativeGap * Swift.max(1, Swift.abs(model.reportedObjective(best))))
        if difference <= allowed {
            gapReached = true
            shared.stop.set()
        }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            await sink.emit(event)
        }
        draining = false
    }
}

/// A bounded buffer of short learned clauses, in the portable bound-literal form.
actor ClauseExchange {
    private var clauses: [(origin: Int, literals: [BoundLiteral])] = []
    /// The sequence number of `clauses[0]`.
    private var firstSequence = 0
    private let capacity: Int

    init(capacity: Int = 4_096) {
        self.capacity = Swift.max(16, capacity)
    }

    /// Publishes a worker's new clauses and returns the ones other workers published since
    /// `cursor`, with the cursor to pass next time. One hop per restart.
    func exchange(
        from worker: Int, outgoing: [[BoundLiteral]], cursor: Int
    ) -> (incoming: [[BoundLiteral]], cursor: Int) {
        var incoming: [[BoundLiteral]] = []
        let begin = Swift.max(cursor, firstSequence) - firstSequence
        if begin < clauses.count {
            for k in begin..<clauses.count where clauses[k].origin != worker {
                incoming.append(clauses[k].literals)
            }
        }
        for literals in outgoing { clauses.append((worker, literals)) }
        let next = firstSequence + clauses.count
        // Drop the oldest half once the buffer is full; a worker that has not polled them yet
        // simply never sees them.
        if clauses.count > capacity {
            let dropped = clauses.count - capacity / 2
            clauses.removeFirst(dropped)
            firstSequence += dropped
        }
        return (incoming, next)
    }
}
