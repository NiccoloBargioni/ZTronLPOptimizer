// ConcurrencyBudget and the memory budget (specification §2, §12.1 rule C7, §12.2 rule L7).

import Foundation
import ZTronLPCore

#if canImport(os)
import os
#endif

/// The slots of one solve's CPU budget (rule C7).
///
/// Nested parallel regions — branch-and-bound workers × strong-branching probes, interior-point
/// row blocks, simplex pricing blocks — borrow slots here so that the total number of in-flight
/// CPU tasks never exceeds `threads`. A borrow that cannot be satisfied is not queued: the
/// caller gets fewer slots (possibly none) and runs that part of the work inline rather than
/// waiting.
public actor ConcurrencyBudget {
    /// The total number of slots.
    public nonisolated let capacity: Int
    private var inUse: Int
    private var peak: Int

    /// - Parameters:
    ///   - threads: the total number of CPU tasks the solve may run at once.
    ///   - occupied: slots already taken when the budget is created; the task that starts the
    ///     solve is itself running, so the default is 1.
    public init(threads: Int, occupied: Int = 1) {
        capacity = Swift.max(1, threads)
        inUse = Swift.min(Swift.max(0, occupied), Swift.max(1, threads))
        peak = inUse
    }

    /// Takes up to `count` free slots and returns how many were granted; never waits.
    public func borrow(upTo count: Int) -> Int {
        let granted = Swift.max(0, Swift.min(count, capacity - inUse))
        inUse += granted
        if inUse > peak { peak = inUse }
        return granted
    }

    /// Returns slots taken with `borrow`.
    public func giveBack(_ count: Int) {
        inUse = Swift.max(0, inUse - Swift.max(0, count))
    }

    /// Slots currently taken.
    public var slotsInUse: Int { inUse }

    /// The largest number of slots that were ever taken at once.
    public var peakInUse: Int { peak }
}

/// Runs `body` over `blocks` contiguous pieces of `0..<count`, using the calling task plus as
/// many slots as the budget grants, and returns the results in block order.
///
/// Each child produces its own value, so nothing is shared between tasks. With no budget, a
/// single block or no free slot, everything runs inline on the calling task.
public func parallelBlocks<T: Sendable>(
    count: Int, blocks requested: Int, budget: ConcurrencyBudget?,
    _ body: @escaping @Sendable (Range<Int>) async -> T
) async -> [T] {
    let blocks = Swift.max(1, Swift.min(requested, count))
    func range(_ k: Int) -> Range<Int> {
        (count * k / blocks)..<(count * (k + 1) / blocks)
    }
    guard blocks > 1, let budget else {
        var results: [T] = []
        results.reserveCapacity(blocks)
        for k in 0..<blocks { results.append(await body(range(k))) }
        return results
    }
    let extra = await budget.borrow(upTo: blocks - 1)
    if extra == 0 {
        var results: [T] = []
        results.reserveCapacity(blocks)
        for k in 0..<blocks { results.append(await body(range(k))) }
        return results
    }
    // `extra + 1` tasks share the blocks: the children take a block each as they become free,
    // in a fixed assignment so the outcome does not depend on timing.
    let tasks = extra + 1
    let results = await withTaskGroup(of: [(Int, T)].self) { group -> [T?] in
        for t in 1..<tasks {
            group.addTask {
                var mine: [(Int, T)] = []
                var k = t
                while k < blocks {
                    mine.append((k, await body(range(k))))
                    k += tasks
                }
                return mine
            }
        }
        var collected = [T?](repeating: nil, count: blocks)
        // The calling task works too; it holds the slot the budget already counts for it.
        var k = 0
        while k < blocks {
            collected[k] = await body(range(k))
            k += tasks
        }
        for await part in group {
            for (index, value) in part { collected[index] = value }
        }
        return collected
    }
    await budget.giveBack(extra)
    return results.compactMap { $0 }
}

/// Memory available to the process and the default solver budget (§2).
public enum MemoryBudget {
    /// Bytes the process may still allocate: `os_proc_available_memory()` where the system
    /// enforces a per-process limit (iOS, tvOS, watchOS, visionOS), physical memory elsewhere.
    public static func availableBytes() -> Int {
        #if os(macOS)
        return Int(clamping: ProcessInfo.processInfo.physicalMemory)
        #elseif canImport(os)
        let available = os_proc_available_memory()
        // Mac Catalyst has no per-process limit and reports 0.
        return available > 0 ? available : Int(clamping: ProcessInfo.processInfo.physicalMemory)
        #else
        return Int(clamping: ProcessInfo.processInfo.physicalMemory)
        #endif
    }

    /// The budget of a run: `context.memoryBudgetBytes`, or 25% of the available memory.
    public static func resolve(_ context: SolveContext) -> Int {
        if let explicit = context.memoryBudgetBytes { return Swift.max(0, explicit) }
        return availableBytes() / 4
    }
}

/// Wall-clock seconds since `start` (an uptime from `Deadline.now`).
@inlinable
public func secondsSince(_ start: UInt64) -> Double {
    Double(Deadline.now &- start) / 1e9
}
