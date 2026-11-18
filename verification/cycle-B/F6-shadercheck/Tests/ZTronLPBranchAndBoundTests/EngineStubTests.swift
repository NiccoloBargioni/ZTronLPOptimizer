import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

/// Records what a stub engine was asked to do.
actor CallLog {
    private(set) var nodeCalls: [(limit: Int, parent: Int, changes: Int)] = []
    private(set) var running = 0
    private(set) var peak = 0

    func node(limit: Int, parent: Int, changes: Int) {
        nodeCalls.append((limit, parent, changes))
    }

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() {
        running -= 1
    }
}

/// A node engine that wraps the dual simplex and counts how many of its solves overlap.
struct CountingEngine: NodeLPStrategy {
    typealias State = Basis
    typealias Worker = SimplexEngine

    let inner = Simplex(.dual)
    let log: CallLog

    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SimplexAnalysis {
        try await inner.solve(problem, context: context)
    }

    func makeWorker(lp: CompiledLP, context: SolveContext) -> SimplexEngine { inner.makeWorker(lp: lp, context: context) }

    func solveRoot(_ w: inout SimplexEngine, gate: inout WorkGate) async throws -> NodeLPResult<Basis> {
        try await inner.solveRoot(&w, gate: &gate)
    }

    func solveNode(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, cutoff: Double?, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> NodeLPResult<Basis> {
        await log.enter()
        // Give overlapping solves every chance to overlap.
        await Task.yield()
        let result = try await inner.solveNode(
            &w, changes: changes, parent: parent, cutoff: cutoff, iterationLimit: iterationLimit, gate: &gate)
        await log.leave()
        return result
    }

    func probe(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, iterationLimit: Int, gate: inout WorkGate
    ) async throws -> Double? {
        await log.enter()
        await Task.yield()
        let result = try await inner.probe(&w, changes: changes, parent: parent, iterationLimit: iterationLimit, gate: &gate)
        await log.leave()
        return result
    }

    func rootAnalysis(_ result: NodeLPResult<Basis>, worker: borrowing SimplexEngine) -> SimplexAnalysis {
        inner.rootAnalysis(result, worker: worker)
    }
}

@Suite struct ConcurrencyBudgetTests {
    /// Rule C7: nested parallel regions (workers × strong-branching probes) borrow slots from
    /// the ConcurrencyBudget, so with threads = 2 the peak concurrency is at most 2.
    @Test(arguments: [false, true])
    func peakConcurrencyStaysWithinThreads(_ deterministic: Bool) async throws {
        let lp = InstanceGenerator.randomMILP(rows: 10, columns: 40, seed: 31, upper: 1)
        let log = CallLog()
        var context = SolveContext()
        context.threads = 2
        let analysis = try await BranchAndBound(
            engine: CountingEngine(log: log), branching: .strong(candidates: 8), deterministic: deterministic
        ).solve(lp, context: context)
        #expect(analysis.status == .optimal)
        let peak = await log.peak
        #expect(peak >= 1 && peak <= 2, "peak concurrency \(peak)")
        #expect(await log.running == 0)
    }
}

@Suite struct ReducedCostFixingTests {
    /// Reduced-cost fixing must never cut off the optimum: with and without it (and with an
    /// incumbent available early, from the heuristics) the optimal value is the same.
    @Test func fixingIsValid() async throws {
        for seed in 0..<25 {
            // Small enough to enumerate: 2¹² or 4⁶ points.
            let general = seed % 3 == 0
            let lp = InstanceGenerator.randomMILP(
                rows: 5, columns: general ? 6 : 12, seed: UInt64(300 + seed), upper: general ? 3 : 1)
            let expected = try #require(bruteForce(lp))
            for strategy in [
                BranchAndBound(engine: Simplex(.dual), nodeSelection: .depthFirst),
                BranchAndBound(engine: Simplex(.primal), nodeSelection: .bestBound, heuristics: .none),
            ] {
                let analysis = try await strategy.solve(lp)
                #expect(analysis.status == .optimal)
                #expect(abs(analysis.objectiveValue! - expected) <= 1e-6, "seed \(seed): \(analysis.objectiveValue!) vs \(expected)")
            }
        }
    }

    @Test func fixingTightensOnlyWhatTheBoundAllows() async throws {
        // Parent LP: z = 10, column 0 at its lower bound 0 with d = 4, column 1 at its upper
        // bound 6 with d = −2.5, column 2 basic. Cutoff 15 leaves a slack of 5.
        let lp = denseMIP(
            c: [4, -2.5, 0], rows: [[1, 1, 1]], rl: [0], ru: [100], xu: [9, 6, 9], integer: [0, 1, 2])
        let tree = SearchTree<Basis>(
            columns: 3, selection: .bestBound, deterministic: false, gap: Gap(), nodeLimit: nil,
            memoryBudget: .max, objectiveStep: 0, started: Deadline.now)
        let state = NodeState(
            state: Basis(status: [], basic: []), objective: 10, reducedCosts: [4, -2.5, 0], values: [0, 6, 3])
        let search = TreeSearch(
            engine: Simplex(.dual), lp: lp, isInteger: lp.integerMask(), branching: .mostFractional,
            heuristics: .none, gap: Gap(), objectiveStep: 0, integrality: 1e-6, feasibility: 1e-7,
            nodeIterationLimit: 100, tree: tree, sink: EventSink(nil), deadline: .none, rootState: state,
            budget: ConcurrencyBudget(threads: 1), context: SolveContext(), evaluator: nil, seed: 0, flip: 1)
        var changes: [BoundChange] = []
        search.applyReducedCostFixing(state, into: &changes, cutoff: 15, skipping: nil)
        // Column 0 can rise by at most ⌊5 / 4⌋ = 1; column 1 can fall by at most ⌊5 / 2.5⌋ = 2.
        #expect(changes.contains(BoundChange(column: 0, lower: 0, upper: 1)))
        #expect(changes.contains(BoundChange(column: 1, lower: 4, upper: 6)))
        #expect(!changes.contains { $0.column == 2 })
        // The branching column is left alone.
        var skipped: [BoundChange] = []
        search.applyReducedCostFixing(state, into: &skipped, cutoff: 15, skipping: 0)
        #expect(!skipped.contains { $0.column == 0 })
        // A slack that allows the whole range changes nothing.
        var loose: [BoundChange] = []
        search.applyReducedCostFixing(state, into: &loose, cutoff: 1_000, skipping: nil)
        #expect(loose.isEmpty)
    }
}
