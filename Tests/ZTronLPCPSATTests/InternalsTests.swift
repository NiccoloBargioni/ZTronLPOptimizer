// The parts of the core (specification §10.2, §10.3), one at a time: literals and their
// interning, the two propagators, conflict analysis, restarts, the activity heap and the two
// actors the portfolio shares.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

@Suite struct InternalsTests {
    /// A model from rows given as (coefficients, lower, upper) over columns with the given bounds.
    private func model(
        rows: [([Double], Double, Double)], lower: [Double], upper: [Double], cost: [Double]? = nil
    ) throws -> CPModel {
        let n = lower.count
        var entries: [(row: Int, col: Int, value: Double)] = []
        for (i, row) in rows.enumerated() {
            for (j, a) in row.0.enumerated() where a != 0 { entries.append((i, j, a)) }
        }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: cost ?? [Double](repeating: 0, count: n),
            xl: lower, xu: upper, rl: rows.map { $0.1 }, ru: rows.map { $0.2 }, integerColumns: (0..<n).map { Int32($0) })
        return try CPModel(lp)
    }

    // MARK: Restarts

    @Test func lubySequence() {
        #expect((0..<15).map { RestartPolicy.lubyTerm($0) } == [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8])
        #expect(RestartPolicy.lubyTerm(62) == 32)
    }

    @Test func restartLimits() {
        let luby = RestartPolicy.luby(unit: 100)
        #expect((0..<7).map { luby.conflictLimit(restart: $0) } == [100, 100, 200, 100, 100, 200, 400])
        let geometric = RestartPolicy.geometric(first: 10, factor: 2)
        #expect((0..<4).map { geometric.conflictLimit(restart: $0) } == [10, 20, 40, 80])
        #expect(RestartPolicy.never.conflictLimit(restart: 5) == Int.max)
        // Degenerate parameters are clamped rather than trusted.
        #expect(RestartPolicy.luby(unit: 0).conflictLimit(restart: 0) == 1)
        #expect(RestartPolicy.geometric(first: 0, factor: 0.5).conflictLimit(restart: 9) == 1)
        #expect(RestartPolicy.geometric(first: 100, factor: 10).conflictLimit(restart: 400) == Int.max)
    }

    // MARK: Decisions

    @Test func activityHeapOrdersByActivityThenIndex() {
        var activity: [Double] = [0, 3, 1, 3, 2]
        var heap = ActivityHeap(capacity: 5)
        for x in 0..<5 { heap.insert(x, activity) }
        heap.insert(2, activity)          // inserting twice is a no-op
        #expect(heap.removeMax(activity) == 1)     // ties go to the lower index
        #expect(heap.removeMax(activity) == 3)
        activity[0] = 10
        heap.increased(0, activity)
        #expect(heap.removeMax(activity) == 0)
        #expect(heap.contains(4) && !heap.contains(0))
        #expect(heap.removeMax(activity) == 4)
        #expect(heap.removeMax(activity) == 2)
        #expect(heap.removeMax(activity) == nil)
        #expect(heap.isEmpty)
    }

    @Test func workerRandomDependsOnlyOnTheSeed() {
        var a = WorkerRandom(seed: 17)
        var b = WorkerRandom(seed: 17)
        var c = WorkerRandom(seed: 18)
        let first = (0..<8).map { _ in a.next() }
        #expect(first == (0..<8).map { _ in b.next() })
        #expect(first != (0..<8).map { _ in c.next() })
        var d = WorkerRandom(seed: 1)
        for _ in 0..<1_000 {
            let u = d.uniform()
            #expect(u >= 0 && u < 1)
        }
    }

    // MARK: Literals

    /// Bound literals are created on demand, interned per (variable, value), and their truth
    /// follows the bounds: ¬[x ≥ v] ≡ [x ≤ v − 1].
    @Test func boundLiteralsAreInternedAndFollowTheBounds() throws {
        let m = try model(rows: [], lower: [0, 0], upper: [9, 1])
        var worker = CPWorker(model: m, options: WorkerOptions())
        let atLeast5 = worker.intern(0, 5)
        let again = worker.intern(0, 5)
        #expect(again == atLeast5)                           // interned once
        let atLeast3 = worker.intern(0, 3)
        let atLeast8 = worker.intern(0, 8)
        #expect(Set([atLeast5, atLeast3, atLeast8]).count == 3)
        #expect(worker.atomValuesOf[0] == [3, 5, 8])         // kept sorted by value
        let positive = worker.boundLiteral(atLeast5 << 1)
        let negative = worker.boundLiteral(atLeast5 << 1 | 1)
        #expect(positive == BoundLiteral(variable: 0, isLower: true, value: 5))
        #expect(negative == BoundLiteral(variable: 0, isLower: false, value: 4))

        // Nothing decided yet.
        for atom in [atLeast3, atLeast5, atLeast8] { #expect(worker.value(of: atom << 1) == 0) }
        // lb = 5: [x ≥ 3] and [x ≥ 5] hold, [x ≥ 8] is open.
        worker.newDecisionLevel()
        worker.setLower(0, 5, ReasonKind.none, -1)
        #expect(worker.value(of: atLeast3 << 1) == 1 && worker.value(of: atLeast3 << 1 | 1) == -1)
        #expect(worker.value(of: atLeast5 << 1) == 1)
        #expect(worker.value(of: atLeast8 << 1) == 0)
        // ub = 6: [x ≥ 8] is false, so its negation [x ≤ 7] is true.
        worker.setUpper(0, 6, ReasonKind.none, -1)
        #expect(worker.value(of: atLeast8 << 1) == -1 && worker.value(of: atLeast8 << 1 | 1) == 1)
        // An atom interned now takes its value from the bounds in force.
        let atLeast6 = worker.intern(0, 6)
        #expect(worker.value(of: atLeast6 << 1) == 0)
        let atLeast7 = worker.intern(0, 7)
        #expect(worker.value(of: atLeast7 << 1) == -1)
        // Backtracking undoes all of it.
        worker.cancelUntil(0)
        for atom in [atLeast3, atLeast5, atLeast6, atLeast7, atLeast8] {
            #expect(worker.value(of: atom << 1) == 0 && worker.value(of: atom << 1 | 1) == 0)
        }
        #expect(worker.lb[0] == 0 && worker.ub[0] == 9)
        #expect(worker.trail.isEmpty)
    }

    // MARK: Propagators

    /// Bounds consistency on Σ aᵢxᵢ ≤ rhs, with the minimum activity kept incrementally.
    @Test func linearPropagationTightensBounds() throws {
        // 2x + 3y − z ≤ 6 and x + y ≥ 3, with x, y ∈ [0, 5], z ∈ [0, 2].
        let m = try model(rows: [([2, 3, -1], -.infinity, 6), ([1, 1, 0], 3, .infinity)], lower: [0, 0, 0], upper: [5, 5, 2])
        var worker = CPWorker(model: m, options: WorkerOptions())
        let quiet1 = worker.propagate()
        #expect(quiet1 == nil)
        // From the first row with z ≤ 2: 2x ≤ 8, 3y ≤ 8.
        #expect(worker.ub[0] == 4 && worker.ub[1] == 2)
        // From the second with y ≤ 2: x ≥ 1.
        #expect(worker.lb[0] == 1)
        // Then 3y ≤ 6 + 2 − 2·1 = 6 keeps y ≤ 2, and the fixed point is reached at level 0.
        #expect(worker.currentLevel == 0)
        #expect(worker.rootLower[0] == 1 && worker.rootUpper[1] == 2)
        // The incremental minimum activity equals a recomputation from the bounds.
        for c in 0..<m.constraintCount {
            var recomputed: Int64 = 0
            for t in Int(m.linStart[c])..<Int(m.linStart[c + 1]) {
                let x = Int(m.linVar[t])
                recomputed += m.linCoef[t] * (m.linCoef[t] > 0 ? worker.lb[x] : worker.ub[x])
            }
            #expect(worker.linMinAct[c] == recomputed)
        }
        // Deciding x = 4 forces 3y − z ≤ −2: y = 0 and z = 2 … but x + y ≥ 3 is still fine.
        worker.newDecisionLevel()
        worker.setLower(0, 4, ReasonKind.none, -1)
        let quiet2 = worker.propagate()
        #expect(quiet2 == nil)
        #expect(worker.ub[1] == 0 && worker.lb[2] == 2)
        // Undoing the decision restores the activities as well as the bounds.
        worker.cancelUntil(0)
        #expect(worker.ub[1] == 2 && worker.lb[2] == 0)
        for c in 0..<m.constraintCount {
            var recomputed: Int64 = 0
            for t in Int(m.linStart[c])..<Int(m.linStart[c + 1]) {
                let x = Int(m.linVar[t])
                recomputed += m.linCoef[t] * (m.linCoef[t] > 0 ? worker.lb[x] : worker.ub[x])
            }
            #expect(worker.linMinAct[c] == recomputed)
        }
    }

    /// Two watched literals: a clause propagates when all but one literal are false and
    /// conflicts when all are.
    @Test func clausePropagationAndConflict() throws {
        // (a ∨ b ∨ c) ∧ (¬a ∨ b) ∧ (¬b ∨ c) ∧ (¬c ∨ ¬a)
        let m = try CPModel(CNFFormula(variables: 3, clauses: [[1, 2, 3], [-1, 2], [-2, 3], [-3, -1]]).compiled())
        #expect(m.clauses.count == 4)
        var worker = CPWorker(model: m, options: WorkerOptions())
        let quiet3 = worker.propagate()
        #expect(quiet3 == nil)
        // a = 1 implies b, then c, then contradicts ¬c ∨ ¬a.
        worker.newDecisionLevel()
        worker.setLower(0, 1, ReasonKind.none, -1)
        // (The engine is non-copyable, so its calls are made outside the expectation macros.)
        guard let conflict = worker.propagate(), case .clause = conflict else {
            Issue.record("expected a clause conflict")
            return
        }
        // The analysis learns ¬a, a unit clause that sends the search back to level 0.
        guard let result = worker.analyze(conflict) else {
            Issue.record("the conflict was not analysed")
            return
        }
        #expect(result.backjumpLevel == 0)
        #expect(worker.learnedLiterals.count == 1)
        let unit = worker.boundLiteral(worker.learnedLiterals[0])
        #expect(unit == BoundLiteral(variable: 0, isLower: false, value: 0))
        guard case .asserted = worker.learn(result) else {
            Issue.record("the unit clause was not asserted")
            return
        }
        let quiet4 = worker.propagate()
        #expect(quiet4 == nil)
        #expect(worker.ub[0] == 0)                 // a is false for good
        #expect(worker.currentLevel == 0)
    }

    /// A conflict of a linear constraint is explained by bound literals, relaxed as far as the
    /// constraint allows, and the learned clause is asserting after the backjump.
    @Test func linearConflictsAreExplainedAndLearned() throws {
        // x + y + z ≥ 7 with x, y, z ∈ [0, 3]: at most one variable may fall below 3 … by 2.
        let m = try model(rows: [([1, 1, 1], 7, .infinity)], lower: [0, 0, 0], upper: [3, 3, 3])
        var worker = CPWorker(model: m, options: WorkerOptions())
        let quiet5 = worker.propagate()
        #expect(quiet5 == nil)
        #expect(worker.lb == [1, 1, 1])
        worker.newDecisionLevel()
        worker.setUpper(0, 1, ReasonKind.none, -1)          // x ≤ 1 forces y = z = 3
        let quiet6 = worker.propagate()
        #expect(quiet6 == nil)
        #expect(worker.lb[1] == 3 && worker.lb[2] == 3)
        worker.cancelUntil(0)
        // Two decisions that cannot both hold: x ≤ 2 and y ≤ 1 leave x + y + z ≤ 6. They are
        // taken back to back — propagating after the first would already force y ≥ 2 — so the
        // conflict shows up on the second and has one literal on each level.
        worker.newDecisionLevel()
        worker.setUpper(0, 2, ReasonKind.none, -1)
        worker.newDecisionLevel()
        worker.setUpper(1, 1, ReasonKind.none, -1)
        guard let conflict = worker.propagate(), case .linear = conflict else {
            Issue.record("expected a linear conflict")
            return
        }
        guard let result = worker.analyze(conflict) else {
            Issue.record("the conflict was not analysed")
            return
        }
        // The clause mentions the two decisions, negated: [x ≥ 3] ∨ [y ≥ 2].
        let learned = Set(worker.learnedLiterals.map { worker.boundLiteral($0) })
        #expect(learned == [
            BoundLiteral(variable: 0, isLower: true, value: 3),
            BoundLiteral(variable: 1, isLower: true, value: 2),
        ])
        #expect(result.backjumpLevel == 1)
        #expect(result.lbd == 2)
        guard case .asserted = worker.learn(result) else {
            Issue.record("the learned clause was not asserted")
            return
        }
        // Back at level 1 with x ≤ 2, the clause asserts y ≥ 2.
        #expect(worker.currentLevel == 1)
        let quiet7 = worker.propagate()
        #expect(quiet7 == nil)
        #expect(worker.lb[1] == 2)
    }

    /// Unit propagation and bound tightening at load are all the presolve there is (§10.4):
    /// a contradiction among them is found before any decision.
    @Test func contradictionsAtLevelZeroAreFoundAtLoad() throws {
        // x + y ≥ 2 and x + y ≤ 1 over binaries.
        let m = try model(rows: [([1, 1], 2, .infinity), ([1, 1], -.infinity, 1)], lower: [0, 0], upper: [1, 1])
        var worker = CPWorker(model: m, options: WorkerOptions())
        let propagated = worker.propagate()
        let conflicted = worker.rootConflict || propagated != nil
        #expect(conflicted)
    }

    // MARK: Portfolio actors

    @Test func clauseExchangeDeliversOtherWorkersClausesOnce() async {
        let exchange = ClauseExchange(capacity: 16)
        func clause(_ v: Int32) -> [BoundLiteral] { [BoundLiteral(variable: v, isLower: true, value: 1)] }
        // Worker 0 publishes two clauses; it gets nothing back.
        var result = await exchange.exchange(from: 0, outgoing: [clause(1), clause(2)], cursor: 0)
        #expect(result.incoming.isEmpty)
        let cursor0 = result.cursor
        // Worker 1 sees both, and publishes one of its own.
        result = await exchange.exchange(from: 1, outgoing: [clause(3)], cursor: 0)
        #expect(result.incoming == [clause(1), clause(2)])
        let cursor1 = result.cursor
        // Worker 0 now sees only worker 1's clause; worker 1 sees nothing new.
        result = await exchange.exchange(from: 0, outgoing: [], cursor: cursor0)
        #expect(result.incoming == [clause(3)])
        result = await exchange.exchange(from: 1, outgoing: [], cursor: cursor1)
        #expect(result.incoming.isEmpty)
        // The buffer is bounded: a flood drops the oldest clauses, and a slow reader gets the
        // ones that are left without an error.
        _ = await exchange.exchange(from: 0, outgoing: (10..<60).map { clause($0) }, cursor: 0)
        result = await exchange.exchange(from: 2, outgoing: [], cursor: 0)
        #expect(!result.incoming.isEmpty && result.incoming.count <= 16)
        #expect(result.incoming.last == clause(59))
    }

    @Test func incumbentStoreKeepsTheBestAndOrdersItsEvents() async throws {
        // minimize 2x + y over x, y ∈ [0, 5]; the integer objective is the objective itself.
        let m = try model(rows: [], lower: [0, 0], upper: [5, 5], cost: [2, 1])
        let recorder = EventRecorder()
        let sink = EventSink(recorder.callback)
        let shared = SharedSearchState()
        let store = IncumbentStore(model: m, shared: shared, sink: sink, relativeGap: 1e-4, absoluteGap: 1e-6)
        #expect(shared.bestObjective.load(ordering: .acquiring) == Int64.max)

        #expect(await store.offer(objective: 9, values: [4, 1], worker: 1, conflicts: 3))
        #expect(await store.offer(objective: 12, values: [5, 2], worker: 0, conflicts: 4) == false)     // worse
        #expect(await store.offer(objective: 9, values: [3, 3], worker: 2, conflicts: 5) == false)      // not better
        #expect(await store.offer(objective: 4, values: [1, 2], worker: 2, conflicts: 9))
        #expect(shared.bestObjective.load(ordering: .acquiring) == 4)
        var snapshot = await store.snapshot()
        #expect(snapshot.objective == 4 && snapshot.values == [1, 2] && snapshot.worker == 2 && snapshot.incumbents == 2)
        #expect(!snapshot.gapReached && !shared.stop.isSet)

        // Bounds only ever improve.
        await store.reportBound(1)
        await store.reportBound(0)
        snapshot = await store.snapshot()
        #expect(snapshot.lowerBound == 1 && !snapshot.gapReached)
        // A bound that meets the incumbent closes the gap and raises the stop flag.
        await store.reportBound(4)
        snapshot = await store.snapshot()
        #expect(snapshot.gapReached && shared.stop.isSet)

        let events = await recorder.finish()
        #expect(events == [
            .newIncumbent(objective: 9, node: 3, source: "cpsat[1]"),
            .newIncumbent(objective: 4, node: 9, source: "cpsat[2]"),
            .boundImproved(bound: 1, gap: 0.75),
            .boundImproved(bound: 4, gap: 0),
        ])
    }

    /// Offers racing from many tasks: the store ends with the best one and the incumbent
    /// events come out strictly improving, whatever the interleaving.
    @Test func concurrentOffersAreSerialized() async throws {
        let m = try model(rows: [], lower: [0], upper: [100_000], cost: [1])
        let recorder = EventRecorder()
        let sink = EventSink(recorder.callback)
        let shared = SharedSearchState()
        let store = IncumbentStore(model: m, shared: shared, sink: sink, relativeGap: 0, absoluteGap: 0)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var random = WorkerRandom(seed: UInt64(worker))
                    for _ in 0..<200 {
                        let objective = Int64(random.next() % 100_000)
                        _ = await store.offer(objective: objective, values: [objective], worker: worker, conflicts: 0)
                    }
                }
            }
        }
        let snapshot = await store.snapshot()
        let objectives = await recorder.finish().compactMap { event -> Double? in
            if case .newIncumbent(let objective, _, _) = event { return objective }
            return nil
        }
        #expect(objectives.count == snapshot.incumbents)
        for (previous, next) in zip(objectives, objectives.dropFirst()) { #expect(next < previous) }
        #expect(objectives.last == snapshot.objective.map { Double($0) })
        #expect(shared.bestObjective.load(ordering: .acquiring) == snapshot.objective)
    }
}
