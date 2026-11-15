// Search (specification §10.2, §10.3): decisions, restarts, clause database, objective.
//
//   * Decisions. VSIDS with EVSIDS decay 0.95 and phase saving; integer decisions are
//     lower-bound-first ([x ≤ lb]), bisection when the domain exceeds 1e6 values.
//   * Restarts. Luby sequence × 100 conflicts; the clause database is halved at every 20,000
//     learned clauses, keeping LBD ≤ 2 unconditionally.
//   * Objective. Linear search: each solution of value z adds obj ≤ z − 1 as a permanent
//     constraint; a contradiction at level 0 proves optimality.
//
// Liveness (§12): the loop calls `gate.tick()` once per propagation round, and forces a full
// check — cancellation, deadline, stop flag, the shared incumbent, a yield when one is due —
// at every restart and every 10,000 propagations. Every restart is bounded by its conflict
// limit, and the objective bound only ever decreases, so the search terminates (rule L3).

import Atomics
import ZTronLPCore
import ZTronLPNumerics

/// How a worker's search ended.
enum WorkerOutcome: Sendable, Hashable {
    /// Level 0 is contradictory under the worker's objective bound: no solution better than
    /// the best incumbent exists — or, without an incumbent, no solution at all.
    case exhausted
    /// A feasibility problem, and a solution was found.
    case satisfied
    /// Stopped early.
    case stopped(StopReason)
}

/// What a worker hands back when its task ends.
struct WorkerReport: Sendable {
    var index: Int
    var outcome: WorkerOutcome
    var conflicts: Int
    var decisions: Int
    var propagations: Int
    var restarts: Int
    var learnedClauses: Int
    /// Reductions of the clause database (scheduled ones and those forced by the memory allowance).
    var reductions: Int
    /// Reductions that also freed and renumbered bound literals.
    var renumberings: Int
    var recorded: [RecordedClause]
    /// LP propagator: relaxations solved, and how many of them ended in a conflict, in
    /// tightened bounds, in an integral optimum taken as a solution.
    var lpSolves = 0
    var lpConflicts = 0
    var lpTightenings = 0
    var lpSolutions = 0
}

extension CPWorker {
    // MARK: - Entry point

    /// Runs the search to completion or until the gate stops it. Never throws: a stop signal
    /// becomes the outcome, so cancellation is a result (§11.4).
    mutating func run(
        gate: inout WorkGate, shared: SharedSearchState, store: IncumbentStore, exchange: ClauseExchange?
    ) async -> WorkerReport {
        var outcome: WorkerOutcome
        do throws(StopSignal) {
            outcome = try await search(gate: &gate, shared: shared, store: store, exchange: exchange)
        } catch {
            outcome = .stopped(error.stopReason)
        }
        switch outcome {
        case .exhausted, .satisfied:
            // The answer is known: every other worker can stop.
            shared.stop.set()
        case .stopped:
            break
        }
        var report = WorkerReport(
            index: options.index, outcome: outcome, conflicts: conflicts, decisions: decisions,
            propagations: propagations, restarts: restarts, learnedClauses: learnedTotal, reductions: reductions,
            renumberings: renumberings, recorded: recorded)
        report.lpSolves = relaxation.solves
        report.lpConflicts = relaxation.conflicts
        report.lpTightenings = relaxation.tightenings
        report.lpSolutions = relaxation.solutions
        return report
    }

    /// The CDCL loop.
    mutating func search(
        gate: inout WorkGate, shared: SharedSearchState, store: IncumbentStore, exchange: ClauseExchange?
    ) async throws(StopSignal) -> WorkerOutcome {
        if rootConflict { return .exhausted }
        // Rule L9: a model that does not fit the memory budget fails fast.
        if approximateBytes > options.memoryAllowance { return .stopped(.memoryBudget) }

        var restartIndex = 0
        var conflictLimit = options.restarts.conflictLimit(restart: 0)
        var conflictsThisRestart = 0
        var lastCheckpoint = 0
        var restartRequested = false
        var reportedBound = Int64.min
        var exchangeCursor = 0
        var pendingConflict: Conflict? = nil

        // A solve started in an already-cancelled task, or past its deadline, stops here
        // rather than after the gate's first full stride.
        try await gate.check()

        while true {
            try await gate.tick()

            let conflict: Conflict?
            if let pending = pendingConflict {
                conflict = pending
                pendingConflict = nil
            } else {
                conflict = propagate()
            }
            if let conflict {
                conflicts += 1
                conflictsThisRestart += 1
                guard let result = analyze(conflict) else {
                    rootConflict = true
                    return .exhausted
                }
                switch learn(result) {
                case .asserted:
                    break
                case .violated(let clause):
                    pendingConflict = .clause(clause)
                case .contradiction:
                    rootConflict = true
                    return .exhausted
                }
                decayActivities()
                // Rule L7: look at the memory allowance every few hundred learned clauses, so a
                // burst of conflicts between two checkpoints cannot overshoot it by much.
                if learnedTotal & 255 == 0, approximateBytes > options.memoryAllowance { restartRequested = true }
                continue
            }

            // An LP worker looks at the relaxation once ordinary propagation has nothing left
            // to say about the domains as they stand.
            if relaxationIsDue {
                switch try await propagateRelaxation(gate: &gate) {
                case .nothing:
                    break
                case .tightened:
                    continue
                case .conflict(let row):
                    pendingConflict = .cut(row)
                    continue
                case .solution(let values):
                    let objective = model.objectiveValue(of: values)
                    _ = await store.offer(objective: objective, values: values, worker: options.index, conflicts: conflicts)
                    guard model.hasObjective else { return .satisfied }
                    cancelUntil(0)
                    tightenObjective(below: Swift.min(objective, shared.bestObjective.load(ordering: .acquiring)))
                    continue
                }
            }

            // Level 0 at a fixed point: the objective row's minimum activity is a proven bound,
            // and so is what the relaxation proved there.
            if currentLevel == 0, model.hasObjective {
                var bound = linMinAct[model.objectiveRow]
                if relaxation.rootBound > bound { bound = relaxation.rootBound }
                if bound > reportedBound {
                    reportedBound = bound
                    await store.reportBound(bound)
                }
            }

            if propagations - lastCheckpoint >= 10_000 {
                lastCheckpoint = propagations
                try await gate.check()
                if model.hasObjective,
                   shared.bestObjective.load(ordering: .acquiring) - 1 < linRHS[model.objectiveRow] {
                    restartRequested = true   // another worker improved the incumbent
                }
                if reducibleLearned >= options.reductionInterval || approximateBytes > options.memoryAllowance {
                    restartRequested = true
                }
            }

            if restartRequested || conflictsThisRestart >= conflictLimit {
                restartRequested = false
                conflictsThisRestart = 0
                restartIndex += 1
                conflictLimit = options.restarts.conflictLimit(restart: restartIndex)
                if let outcome = try await restart(gate: &gate, shared: shared, exchange: exchange, cursor: &exchangeCursor) {
                    return outcome
                }
                continue
            }

            if !decide() {
                // Every variable is fixed and propagation found nothing wrong: a solution.
                let values = lb
                let objective = model.objectiveValue(of: values)
                assert(model.isSatisfied(by: values), "CP-SAT produced an assignment that violates the model")
                _ = await store.offer(objective: objective, values: values, worker: options.index, conflicts: conflicts)
                guard model.hasObjective else { return .satisfied }
                cancelUntil(0)
                tightenObjective(below: Swift.min(objective, shared.bestObjective.load(ordering: .acquiring)))
            }
        }
    }

    // MARK: - Learning

    enum LearnOutcome {
        /// The clause is stored and its first literal asserted.
        case asserted
        /// The clause is stored but already violated at the backjump level.
        case violated(Int32)
        /// A unit clause that is false at level 0.
        case contradiction
    }

    /// Backjumps, stores the clause `analyze` left in `learnedLiterals` and asserts its first literal.
    mutating func learn(_ result: AnalysisResult) -> LearnOutcome {
        cancelUntil(result.backjumpLevel)
        learnedTotal += 1
        let short = result.lbd <= 2 && learnedLiterals.count <= 8
        if options.recordLearnedClauses || (options.clauseSharing && short) {
            let portable = learnedLiterals.map { boundLiteral($0) }
            if options.recordLearnedClauses {
                let bound = model.hasObjective ? linRHS[model.objectiveRow] : Int64.max
                recorded.append(RecordedClause(literals: portable, objectiveBound: bound))
            }
            // Short learned clauses (LBD ≤ 2, ≤ 8 literals) go to the other workers at the next restart.
            if options.clauseSharing && short && pendingExports.count < 512 { pendingExports.append(portable) }
        }
        if learnedLiterals.count == 1 {
            return enqueueRoot(learnedLiterals[0]) ? .asserted : .contradiction
        }
        let clause = attachClause(learnedLiterals, learned: true, lbd: result.lbd, activity: clauseIncrement)
        switch value(of: learnedLiterals[0]) {
        case 0:
            assign(learnedLiterals[0], ReasonKind.clause, clause)
            return .asserted
        case 1:
            return .asserted
        default:
            return .violated(clause)
        }
    }

    // MARK: - Decisions

    /// Picks the unfixed variable with the highest activity and splits its domain. Returns
    /// false when every variable is fixed.
    mutating func decide() -> Bool {
        // An LP worker with an optimum of the relaxation in hand branches on it.
        if decideOnRelaxation() { return true }
        var chosen = -1
        while let x = heap.removeMax(activity) {
            if lb[x] < ub[x] {
                chosen = x
                break
            }
        }
        guard chosen >= 0 else { return false }
        let x = chosen
        decisions += 1
        newDecisionLevel()
        let lo = lb[x]
        let hi = ub[x]
        var towardUpper: Bool
        switch options.phase {
        case .lowerBoundFirst: towardUpper = false
        case .random: towardUpper = random.next() & 1 == 1
        case .objective: towardUpper = model.objectivePrefersUpper[x]
        }
        let usesSavedPhase = options.phase != .random && hasSavedValue[x]
        if hi - lo >= 1_000_000 {
            // More than 1e6 values: bisect.
            let middle = lo + (hi - lo) / 2
            if usesSavedPhase { towardUpper = savedValue[x] > middle }
            if towardUpper {
                setLower(x, middle + 1, ReasonKind.none, -1)
            } else {
                setUpper(x, middle, ReasonKind.none, -1)
            }
        } else if usesSavedPhase {
            // Phase saving: head for the value the variable had last time.
            let saved = savedValue[x]
            if saved <= lo {
                setUpper(x, lo, ReasonKind.none, -1)
            } else if saved >= hi {
                setLower(x, hi, ReasonKind.none, -1)
            } else {
                setUpper(x, saved, ReasonKind.none, -1)
            }
        } else if towardUpper {
            setLower(x, hi, ReasonKind.none, -1)
        } else {
            // Lower-bound-first: [x ≤ lb].
            setUpper(x, lo, ReasonKind.none, -1)
        }
        if lb[x] < ub[x] { heap.insert(x, activity) }
        return true
    }

    // MARK: - Objective

    /// Adds `objective ≤ value − 1`. Level 0 only.
    mutating func tightenObjective(below value: Int64) {
        guard model.hasObjective, value < Int64.max else { return }
        let row = model.objectiveRow
        let bound = value - 1
        guard bound < linRHS[row] else { return }
        linRHS[row] = bound
        if !linQueued[row] {
            linQueued[row] = true
            linQueue.append(Int32(row))
        }
        // The relaxation has a new cutoff: what it said about these domains is out of date.
        relaxation.attempted = false
        relaxation.fresh = false
    }

    // MARK: - Restarts

    /// Returns to level 0 and does everything that is only safe there: imports the incumbent's
    /// bound, exchanges short clauses with the other workers, reduces the clause database and
    /// enforces the memory allowance. Returns an outcome when the search is over.
    mutating func restart(
        gate: inout WorkGate, shared: SharedSearchState, exchange: ClauseExchange?, cursor: inout Int
    ) async throws(StopSignal) -> WorkerOutcome? {
        cancelUntil(0)
        restarts += 1
        try await gate.check()
        tightenObjective(below: shared.bestObjective.load(ordering: .acquiring))

        if let exchange {
            let outgoing = pendingExports
            pendingExports.removeAll(keepingCapacity: true)
            let (incoming, next) = await exchange.exchange(from: options.index, outgoing: outgoing, cursor: cursor)
            cursor = next
            for clause in incoming {
                // An imported clause was short and of LBD ≤ 2 where it was learned; here it has
                // no LBD of its own, so it is stored as an ordinary learned clause that the
                // next reductions may drop if it turns out not to be used.
                if !addRootClause(clause, learned: true, lbd: 3, activity: clauseIncrement) {
                    rootConflict = true
                    return .exhausted
                }
            }
        }

        // §10.2: the database is halved at every 20,000 learned clauses, keeping LBD ≤ 2
        // unconditionally. The count is of the clauses a reduction can remove, so a database
        // that is mostly protected clauses does not trigger a reduction at every restart.
        if reducibleLearned >= options.reductionInterval {
            try await reduceLearnedClauses(keeping: 0.5, protectingLowLBD: true, gate: &gate)
        }
        // Rule L7: over the allowance, forget clauses; if that is not enough, stop.
        if approximateBytes > options.memoryAllowance {
            try await reduceLearnedClauses(keeping: 0.5, protectingLowLBD: true, gate: &gate)
            if approximateBytes > options.memoryAllowance {
                try await reduceLearnedClauses(keeping: 0, protectingLowLBD: false, gate: &gate)
            }
            if approximateBytes > options.memoryAllowance { return .stopped(.memoryBudget) }
        }
        return rootConflict ? .exhausted : nil
    }

    // MARK: - Clause database

    /// Forgets all but `fraction` of the learned clauses; with `protectingLowLBD`, clauses of
    /// LBD ≤ 2 are never candidates. Level 0 only.
    ///
    /// A large database takes a while to go through, so the work ticks the gate. A stop
    /// signal may therefore leave the database half rebuilt; that is harmless, because the
    /// search ends with the signal and the worker is not used again.
    mutating func reduceLearnedClauses(
        keeping fraction: Double, protectingLowLBD: Bool, gate: inout WorkGate
    ) async throws(StopSignal) {
        precondition(currentLevel == 0, "the clause database is only reduced at level 0")
        reductions += 1
        // One sortable key per candidate, worst first: the least active clauses (ties: the
        // higher LBD), or with LBD-only retention simply the highest LBD.
        var candidates: [(key: UInt64, clause: Int32)] = []
        for c in 0..<clauseStart.count where clauseLearned[c] && (!protectingLowLBD || clauseLBD[c] > 2) {
            let lbdRank = UInt64(0xFFFF - Swift.min(Int(clauseLBD[c]), 0xFFFF))
            // Activities are non-negative, so their bit patterns sort like their values.
            let key = options.lbdOnlyRetention ? lbdRank : UInt64(clauseActivity[c].bitPattern) << 16 | lbdRank
            candidates.append((key, Int32(c)))
        }
        candidates.sort { $0.key != $1.key ? $0.key < $1.key : $0.clause < $1.clause }
        let removeCount = Int((Double(candidates.count) * (1 - fraction)).rounded(.up))
        var remove = [Bool](repeating: false, count: clauseStart.count)
        for candidate in candidates.prefix(removeCount) { remove[Int(candidate.clause)] = true }
        try await compactDatabase(removing: remove, gate: &gate)
    }

    /// Rewrites the clause database in place without the removed clauses. On the way every
    /// clause is simplified against the level-0 domains — literals that are false for good are
    /// dropped, clauses that are true for good disappear — and the atoms that no clause
    /// mentions any more are freed. Level 0 only.
    mutating func compactDatabase(removing remove: [Bool], gate: inout WorkGate) async throws(StopSignal) {
        let clauseCount = clauseStart.count
        var write = 0
        var kept = 0
        var units: [BoundLiteral] = []
        for c in 0..<clauseCount {
            if c & 255 == 255 { try await gate.tick() }
            if remove[c] { continue }
            let start = Int(clauseStart[c])
            let size = Int(clauseSize[c])
            // The compacted clause never starts after the original one, so reading ahead of
            // the write position is safe.
            let base = write + 2
            var newSize = 0
            var satisfied = false
            for k in start..<(start + size) {
                let literal = literals[k]
                let truth = literalValue[Int(literal)]
                if truth == 1 {
                    satisfied = true
                    break
                }
                if truth == -1 { continue }
                literals[base + newSize] = literal
                newSize += 1
            }
            if satisfied { continue }
            if newSize == 0 {
                rootConflict = true
                continue
            }
            if newSize == 1 {
                units.append(boundLiteral(literals[base]))
                continue
            }
            literals[write] = Int32(kept)
            literals[write + 1] = Int32(newSize)
            clauseStart[kept] = Int32(base)
            clauseSize[kept] = Int32(newSize)
            clauseLBD[kept] = clauseLBD[c]
            clauseLearned[kept] = clauseLearned[c]
            clauseActivity[kept] = clauseActivity[c]
            kept += 1
            write = base + newSize
        }
        literals.removeSubrange(write...)
        // Give the memory back when most of the arena is gone (rule L7 counts capacity).
        if literals.capacity > 2 * write + 4_096 {
            var compact: [Int32] = []
            compact.reserveCapacity(write)
            compact.append(contentsOf: literals)
            literals = compact
        }
        clauseStart.removeSubrange(kept...)
        clauseSize.removeSubrange(kept...)
        clauseLBD.removeSubrange(kept...)
        clauseLearned.removeSubrange(kept...)
        clauseActivity.removeSubrange(kept...)

        // Atoms that no surviving clause mentions are garbage. Renumber when there is enough
        // of it to matter; the interned ids of the survivors change, their meaning does not.
        let atomCount = atomVariable.count
        var used = [Bool](repeating: false, count: atomCount)
        var usedCount = 0
        for c in 0..<kept {
            if c & 255 == 255 { try await gate.tick() }
            let start = Int(clauseStart[c])
            for k in start..<(start + Int(clauseSize[c])) {
                let atom = Int(literals[k] >> 1)
                if !used[atom] {
                    used[atom] = true
                    usedCount += 1
                }
            }
        }
        if atomCount > 64 && usedCount < atomCount - atomCount / 4 {
            renumberings += 1
            var newID = [Int32](repeating: -1, count: atomCount)
            var newVariable: [Int32] = []
            var newValue: [Int64] = []
            var newTruth: [Int8] = []
            newVariable.reserveCapacity(usedCount)
            newValue.reserveCapacity(usedCount)
            newTruth.reserveCapacity(2 * usedCount)
            for x in 0..<model.variableCount where !atomIDsOf[x].isEmpty {
                var values: [Int64] = []
                var ids: [Int32] = []
                for (k, atom) in atomIDsOf[x].enumerated() where used[Int(atom)] {
                    let id = Int32(newVariable.count)
                    newID[Int(atom)] = id
                    newVariable.append(Int32(x))
                    newValue.append(atomValuesOf[x][k])
                    newTruth.append(literalValue[Int(atom) << 1])
                    newTruth.append(literalValue[Int(atom) << 1 | 1])
                    values.append(atomValuesOf[x][k])
                    ids.append(id)
                }
                atomValuesOf[x] = values
                atomIDsOf[x] = ids
            }
            atomVariable = newVariable
            atomValue = newValue
            literalValue = newTruth
            for c in 0..<kept {
                if c & 255 == 255 { try await gate.tick() }
                let start = Int(clauseStart[c])
                for k in start..<(start + Int(clauseSize[c])) {
                    let literal = literals[k]
                    literals[k] = newID[Int(literal >> 1)] << 1 | (literal & 1)
                }
            }
            watches = [[Watcher]](repeating: [], count: 2 * newVariable.count)
        } else {
            for i in watches.indices { watches[i].removeAll(keepingCapacity: true) }
        }

        // Watch the first two literals of every clause again; all of them are undecided.
        liveLearned = 0
        reducibleLearned = 0
        for c in 0..<kept {
            let reference = clauseStart[c]
            let start = Int(reference)
            watches[Int(literals[start])].append(Watcher(clause: reference, blocker: literals[start + 1]))
            watches[Int(literals[start + 1])].append(Watcher(clause: reference, blocker: literals[start]))
            if clauseLearned[c] {
                liveLearned += 1
                if clauseLBD[c] > 2 { reducibleLearned += 1 }
            }
        }
        // Only level-0 entries are on the trail; their reasons are never consulted again, and
        // the clause references they held no longer mean anything.
        for i in trail.indices {
            trail[i].flags &= 1
            trail[i].reason = -1
        }
        // Clauses that shrank to one literal are facts of level 0. Asserting them after the
        // watch lists are rebuilt lets ordinary propagation pick up their consequences.
        for unit in units where !rootConflict {
            let x = Int(unit.variable)
            if unit.isLower {
                if unit.value > ub[x] {
                    rootConflict = true
                } else if unit.value > lb[x] {
                    setLower(x, unit.value, ReasonKind.none, -1)
                }
            } else {
                if unit.value < lb[x] {
                    rootConflict = true
                } else if unit.value < ub[x] {
                    setUpper(x, unit.value, ReasonKind.none, -1)
                }
            }
        }
    }
}
