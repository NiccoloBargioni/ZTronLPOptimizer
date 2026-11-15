import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

/// Records what the stub engine was asked to do.
actor NodeCallLog {
    private(set) var nodeCalls: [(limit: Int, parent: Int, changes: Int)] = []

    func node(limit: Int, parent: Int, changes: Int) {
        nodeCalls.append((limit, parent, changes))
    }
}

/// A user-defined node engine (§9.1) whose root LP is fractional and whose node LPs always
/// hit their iteration limit.
struct AlwaysLimitEngine: NodeLPStrategy {
    typealias State = Int
    struct Worker {
        var solves = 0
    }

    let log: NodeCallLog

    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SolveRecord {
        SolveRecord(status: .noSolution(stoppedBy: .cancelled))
    }

    func makeWorker(lp: CompiledLP, context: SolveContext) -> Worker { Worker() }

    func solveRoot(_ w: inout Worker, gate: inout WorkGate) async throws -> NodeLPResult<Int> {
        w.solves += 1
        // x0 = 0.5 is fractional, so the root branches.
        return NodeLPResult(
            outcome: .optimal(objective: 1, x: [0.5, 0], reducedCosts: [0, 0, 0]), state: 100, iterations: 2)
    }

    func solveNode(
        _ w: inout Worker, changes: [BoundChange], parent: Int, cutoff: Double?, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> NodeLPResult<Int> {
        w.solves += 1
        await log.node(limit: iterationLimit, parent: parent, changes: changes.count)
        return NodeLPResult(outcome: .limit, state: parent + 1, iterations: iterationLimit)
    }

    func rootAnalysis(_ result: NodeLPResult<Int>, worker: borrowing Worker) -> SolveRecord {
        SolveRecord(status: .optimal, objectiveValue: 1)
    }
}

/// Rule L5: a node LP that hits its iteration limit is retried with a 4× budget, then
/// cold-started, then reported as a numerical failure on that path; it never loops.
@Suite struct L5LimitRetryTests {
    static let problem = CompiledLP(
        a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1), (0, 1, 1)]), c: [1, 1], xl: [0, 0], xu: [5, 5],
        rl: [0.5], ru: [10], integerColumns: [0])

    /// Rule L5: a node LP that hits its iteration limit is retried with a 4× budget, then
    /// cold-started from the root state, then reported as a numerical failure on that path.
    /// It never loops.
    @Test func aNodeThatAlwaysHitsItsLimitEndsInNumericalFailure() async throws {
        let log = NodeCallLog()
        var context = SolveContext()
        context.threads = 1
        let strategy = BranchAndBound(
            engine: AlwaysLimitEngine(log: log), branching: .mostFractional, nodeSelection: .depthFirst,
            heuristics: .none)
        let analysis = try await strategy.solve(Self.problem, context: context)
        guard case .numericalFailure(let message) = analysis.status else {
            Issue.record("expected a numerical failure, got \(analysis.status)")
            return
        }
        #expect(message.contains("three times") && message.contains("path"))
        let calls = await log.nodeCalls
        // The first child: budget, budget × 4 warm from the parent, budget × 4 cold from the root.
        #expect(calls.count == 3)
        let budget = calls[0].limit
        #expect(calls.map(\.limit) == [budget, 4 * budget, 4 * budget])
        #expect(calls.map(\.parent) == [100, 100, 100])
        #expect(analysis.root.status == .optimal)
        // The root's two iterations plus the two attempts that were handed back to the tree.
        #expect(analysis.lpIterations >= 2 + 5 * budget)
    }

    @Test func theLimitPathDoesNotHangWithManyWorkers() async throws {
        let log = NodeCallLog()
        var context = SolveContext()
        context.threads = 8
        let analysis = try await BranchAndBound(engine: AlwaysLimitEngine(log: log), heuristics: .none)
            .solve(Self.problem, context: context)
        guard case .numericalFailure = analysis.status else {
            Issue.record("expected a numerical failure, got \(analysis.status)")
            return
        }
        // The default branching rule strong-branches the root's one candidate first: a probe per
        // direction, capped at 50 iterations, which this engine answers through `solveNode`
        // (the default `probe`). Then two children, at most three attempts each: the node whose
        // third attempt fails closes the tree as it is handed back, so no other worker repeats
        // it. How many of the other child's attempts run before that is a race between two
        // workers, so each kind of call has its own bound rather than one total.
        let calls = await log.nodeCalls
        let retryBudget = calls.map(\.limit).max() ?? 0        // four times the node budget
        let nodeBudget = retryBudget / 4
        let probes = calls.filter { $0.limit < nodeBudget }
        let attempts = calls.filter { $0.limit >= nodeBudget }
        #expect(probes.count <= 2, "\(probes.count) probe calls: \(calls.map(\.limit))")
        #expect((3...6).contains(attempts.count), "\(attempts.count) node attempts: \(calls.map(\.limit))")
        // Per child: one attempt on the node budget, at most two on four times as much.
        #expect(attempts.filter { $0.limit == nodeBudget }.count <= 2, "\(calls.map(\.limit))")
        #expect(attempts.filter { $0.limit == retryBudget }.count <= 4, "\(calls.map(\.limit))")
    }
}
