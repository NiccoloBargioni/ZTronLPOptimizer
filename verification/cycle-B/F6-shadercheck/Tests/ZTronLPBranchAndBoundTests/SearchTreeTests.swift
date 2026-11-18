import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

private func makeTree(
    selection: NodeSelection = .bestBound, deterministic: Bool = false, nodeLimit: Int? = nil,
    memoryBudget: Int = .max, objectiveStep: Double = 0, columns: Int = 4
) -> SearchTree<Int> {
    SearchTree<Int>(
        columns: columns, selection: selection, deterministic: deterministic, gap: Gap(), nodeLimit: nodeLimit,
        memoryBudget: memoryBudget, objectiveStep: objectiveStep, started: Deadline.now)
}

private func draft(bound: Double, depth: Int) -> NodeDraft<Int> {
    NodeDraft(changes: [], bound: bound, depth: depth, estimate: bound, parentState: nil, branch: nil)
}

private let rootNode = Node<Int>(id: 0, changes: [], bound: 0, depth: 0, estimate: 0, parentState: nil, branch: nil, attempt: 0)

@Suite struct SearchTreeTests {
    @Test func bestBoundOrderAndCompletion() async {
        let tree = makeTree(selection: .bestBound)
        _ = await tree.begin(
            root: rootNode, children: [draft(bound: 5, depth: 1), draft(bound: 2, depth: 1), draft(bound: 9, depth: 1)],
            iterations: 3)
        var order: [Double] = []
        while let node = await tree.next() {
            order.append(node.bound)
            #expect(await tree.finish(node, children: [], iterations: 1) == nil)
        }
        #expect(order == [2, 5, 9])
        let summary = await tree.summary()
        #expect(summary.closeReason == .complete && summary.nodesProcessed == 4 && summary.lpIterations == 6)
    }

    @Test func plungingDivesWithinTenPercentOfTheBestBound() async throws {
        let tree = makeTree(selection: .bestBoundWithPlunging(maxDepth: 5))
        // The worker starts on the first child; its sibling (bound 10) stays open.
        let first = try #require(
            await tree.begin(root: rootNode, children: [draft(bound: 10, depth: 1), draft(bound: 10, depth: 1)], iterations: 0))
        // Within 10% of the best open bound: dive.
        let second = try #require(
            await tree.finish(first, children: [draft(bound: 10.5, depth: 2), draft(bound: 10.5, depth: 2)], iterations: 0))
        #expect(second.bound == 10.5 && second.depth == 2)
        // More than 10% above the best open bound: back to the heap.
        let third = await tree.finish(second, children: [draft(bound: 12, depth: 3), draft(bound: 12, depth: 3)], iterations: 0)
        #expect(third == nil)
        #expect(await tree.next()?.bound == 10)

        // The depth limit stops a dive even when the bound allows it.
        let shallow = makeTree(selection: .bestBoundWithPlunging(maxDepth: 2))
        let start = try #require(
            await shallow.begin(root: rootNode, children: [draft(bound: 1, depth: 1), draft(bound: 1, depth: 1)], iterations: 0))
        let deeper = await shallow.finish(start, children: [draft(bound: 1, depth: 2), draft(bound: 1, depth: 2)], iterations: 0)
        #expect(deeper == nil)
    }

    @Test func nodesWorseThanTheIncumbentArePruned() async {
        let tree = makeTree(selection: .bestBound, objectiveStep: 1)
        _ = await tree.begin(
            root: rootNode, children: [draft(bound: 3, depth: 1), draft(bound: 7.5, depth: 1), draft(bound: 8, depth: 1)],
            iterations: 0)
        let events = await tree.offerIncumbent(objective: 8, x: [0], node: 0, source: "test", reportedObjective: 8)
        #expect(events == [.newIncumbent(objective: 8, node: 0, source: "test")])
        // A worse offer is refused.
        #expect(await tree.offerIncumbent(objective: 9, x: [0], node: 0, source: "test", reportedObjective: 9) == nil)
        // With an integral objective only bounds below 8 − 1 are worth solving.
        #expect(await tree.currentCutoff < 7.1)
        var seen: [Double] = []
        while let node = await tree.next() {
            seen.append(node.bound)
            _ = await tree.finish(node, children: [], iterations: 0)
        }
        #expect(seen == [3])
        #expect(await tree.incumbent.objective == 8)
        let summary = await tree.summary()
        #expect(summary.closeReason == .complete && summary.provenBound >= 7.5)
    }

    @Test func nodeLimitClosesTheTree() async {
        let tree = makeTree(nodeLimit: 3)
        _ = await tree.begin(root: rootNode, children: [draft(bound: 1, depth: 1), draft(bound: 2, depth: 1)], iterations: 0)
        var processed = 0
        while let node = await tree.next() {
            processed += 1
            _ = await tree.finish(node, children: [draft(bound: node.bound + 1, depth: node.depth + 1)], iterations: 0)
        }
        let summary = await tree.summary()
        #expect(summary.closeReason == .nodeLimit && summary.nodesProcessed == 3 && processed == 2)
        #expect(summary.nodesOpen > 0)
    }

    /// Pseudocost bookkeeping (§14.2).
    @Test func pseudocostBookkeeping() async {
        let tree = makeTree(columns: 3)
        await tree.recordPseudocost(column: 0, up: true, gainPerUnit: 4)
        await tree.recordPseudocost(column: 0, up: true, gainPerUnit: 6)
        await tree.recordPseudocost(column: 0, up: false, gainPerUnit: 1)
        await tree.recordPseudocost(column: 2, up: false, gainPerUnit: 3)
        await tree.recordPseudocost(column: 1, up: true, gainPerUnit: -.infinity)   // ignored
        await tree.recordPseudocost(column: 7, up: true, gainPerUnit: 1)            // out of range, ignored
        let snapshot = await tree.pseudocosts(for: [0, 1, 2])
        #expect(snapshot.entries[0].up == 5 && snapshot.entries[0].upCount == 2)
        #expect(snapshot.entries[0].down == 1 && snapshot.entries[0].downCount == 1)
        #expect(snapshot.entries[1].up == nil && snapshot.entries[1].down == nil)
        #expect(snapshot.entries[2].down == 3)
        #expect(snapshot.averageUp == 5 && snapshot.averageDown == 2)
    }

    @Test func objectiveStepDetection() {
        func problem(_ c: [Double], integer: [Int]) -> CompiledLP {
            denseMIP(c: c, rows: [[Double](repeating: 1, count: c.count)], rl: [0], ru: [5], integer: integer)
        }
        #expect(BranchAndBound<Simplex>.objectiveStep(of: problem([2, 4, 6], integer: [0, 1, 2])) == 2)
        #expect(BranchAndBound<Simplex>.objectiveStep(of: problem([1.5, 3], integer: [0, 1])) == 1.5)
        #expect(BranchAndBound<Simplex>.objectiveStep(of: problem([0.25, 0.5], integer: [0, 1])) == 0.25)
        // A continuous column with a cost: no integral step.
        #expect(BranchAndBound<Simplex>.objectiveStep(of: problem([2, 4, 1], integer: [0, 1])) == 0)
        #expect(BranchAndBound<Simplex>.objectiveStep(of: problem([0, 0], integer: [0, 1])) == 0)
    }
}
