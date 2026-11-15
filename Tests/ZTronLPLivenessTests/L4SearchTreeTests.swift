import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport
@testable import ZTronLPBranchAndBound

private func makeTree(selection: NodeSelection = .bestBound, deterministic: Bool = false) -> SearchTree<Int> {
    SearchTree<Int>(
        columns: 4, selection: selection, deterministic: deterministic, gap: Gap(), nodeLimit: nil,
        memoryBudget: .max, objectiveStep: 0, started: Deadline.now)
}

private func draft(bound: Double, depth: Int) -> NodeDraft<Int> {
    NodeDraft(changes: [], bound: bound, depth: depth, estimate: bound, parentState: nil, branch: nil)
}

private let rootNode = Node<Int>(id: 0, changes: [], bound: 0, depth: 0, estimate: 0, parentState: nil, branch: nil, attempt: 0)

/// Rule L4: the SearchTree cannot leak a continuation — `wake()` runs after every state change
/// and `close()` resumes all waiters (§9.3).
@Suite struct L4SearchTreeTests {
    /// Rule L4: the tree cannot leak a continuation. 10,000 random trees, with random
    /// cancellation, and every worker task completes.
    @Test func stressRandomTreesWithRandomCancellation() async {
        let trees = 10_000
        var totalProcessed = 0
        for index in 0..<trees {
            var rng = SeededGenerator(seed: UInt64(index))
            let workers = rng.integer(in: 1...6)
            let branching = rng.uniform(in: 0.2...0.75)
            let maxDepth = rng.integer(in: 1...7)
            let cancelAfter: Int? = rng.chance(0.4) ? rng.integer(in: 0...12) : nil
            let selection: NodeSelection = [.bestBound, .bestBoundWithPlunging(maxDepth: 4), .depthFirst][index % 3]
            let tree = makeTree(selection: selection, deterministic: index % 7 == 0)
            let first = await tree.begin(root: rootNode, children: [draft(bound: 1, depth: 1), draft(bound: 1, depth: 1)], iterations: 0)
            if let first { await tree.abandon(first) }

            let processed = await withTaskGroup(of: Int.self) { group -> Int in
                for worker in 0..<workers {
                    let seed = UInt64(index) &* 31 &+ UInt64(worker)
                    group.addTask {
                        var local = SeededGenerator(seed: seed)
                        var count = 0
                        var next: Node<Int>? = nil
                        while true {
                            let node: Node<Int>
                            if let diving = next {
                                node = diving
                                next = nil
                            } else if let taken = await tree.next() {
                                node = taken
                            } else {
                                break
                            }
                            count += 1
                            if local.chance(0.3) { await Task.yield() }
                            if let limit = cancelAfter, count > limit, local.chance(0.5) {
                                // A worker that is told to stop hands its node back and closes.
                                await tree.abandon(node)
                                await tree.close(.cancelled)
                                continue
                            }
                            var children: [NodeDraft<Int>] = []
                            if node.depth < maxDepth {
                                for _ in 0..<2 where local.chance(branching) {
                                    children.append(draft(bound: node.bound + local.uniform(), depth: node.depth + 1))
                                }
                            }
                            next = await tree.finish(node, children: children, iterations: 1)
                        }
                        return count
                    }
                }
                var total = 0
                for await count in group { total += count }
                return total
            }
            totalProcessed += processed
            let summary = await tree.summary()
            #expect(summary.waiters == 0, "tree \(index) left \(summary.waiters) continuation(s) parked")
            if cancelAfter == nil {
                #expect(summary.closeReason == .complete)
                #expect(summary.nodesOpen == 0)
            }
        }
        #expect(totalProcessed > trees)
    }

    @Test func closeResumesEveryWaiter() async {
        let tree = makeTree()
        // One node, taken by the first worker and never finished; the others must wait.
        _ = await tree.begin(root: rootNode, children: [draft(bound: 1, depth: 1)], iterations: 0)
        let held = await tree.next()
        #expect(held != nil)
        let waiters = (0..<5).map { _ in Task { await tree.next() } }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await tree.summary().waiters == 5)
        await tree.close(.cancelled)
        for waiter in waiters { #expect(await waiter.value == nil) }
        #expect(await tree.summary().waiters == 0)
        #expect(await tree.summary().closeReason == .cancelled)
        // Closing again keeps the first reason.
        await tree.close(.timeLimit)
        #expect(await tree.summary().closeReason == .cancelled)
        #expect(tree.stopFlag.isSet)
    }
}
