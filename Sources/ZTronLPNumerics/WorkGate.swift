// Deadline, StopFlag and WorkGate (specification §12.3).
//
// iOS 15 has no `Clock` or `Duration`, so deadlines are absolute `DispatchTime` uptimes.

import Atomics
import Dispatch
import ZTronLPCore

/// An absolute point in time after which a solve must stop, or none.
public struct Deadline: Sendable, Hashable {
    /// Uptime in nanoseconds (`DispatchTime.now().uptimeNanoseconds`); `nil` means no deadline.
    public let uptimeNanoseconds: UInt64?

    public init(uptimeNanoseconds: UInt64?) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// No deadline.
    public static let none = Deadline(uptimeNanoseconds: nil)

    /// A deadline `seconds` from now; `nil` or a non-finite value means no deadline.
    public static func after(seconds: Double?) -> Deadline {
        guard let seconds, seconds.isFinite else { return .none }
        let clamped = Swift.max(0, seconds)
        let delta = clamped >= 1e9 ? UInt64.max / 4 : UInt64(clamped * 1e9)
        return Deadline(uptimeNanoseconds: now &+ delta)
    }

    /// The current uptime in nanoseconds.
    @inlinable
    public static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// True once the deadline has passed.
    public var hasPassed: Bool {
        guard let uptimeNanoseconds else { return false }
        return Self.now >= uptimeNanoseconds
    }

    /// Seconds left; `nil` without a deadline, 0 once it has passed.
    public var remainingSeconds: Double? {
        guard let uptimeNanoseconds else { return nil }
        let current = Self.now
        return current >= uptimeNanoseconds ? 0 : Double(uptimeNanoseconds - current) / 1e9
    }

    /// The earlier of two deadlines.
    public func earlier(_ other: Deadline) -> Deadline {
        switch (uptimeNanoseconds, other.uptimeNanoseconds) {
        case (nil, _): return other
        case (_, nil): return self
        case (let a?, let b?): return Deadline(uptimeNanoseconds: Swift.min(a, b))
        }
    }
}

/// The internal signals `WorkGate.tick()` throws. Engines map them to a `StopReason` at their
/// boundary; they are never surfaced to the caller as errors.
public enum StopSignal: Error, Sendable, Hashable {
    case cancelled, deadline
}

/// A one-way flag that tells every worker of a solve to stop: set by the search tree when it
/// closes, by a portfolio when one strategy has won. Hot-path cross-task reads go through a
/// `ManagedAtomic` (rule C5).
public final class StopFlag: Sendable {
    private let raised = ManagedAtomic<Bool>(false)

    public init() {}

    /// Raises the flag. Idempotent.
    public func set() {
        raised.store(true, ordering: .releasing)
    }

    public var isSet: Bool {
        raised.load(ordering: .acquiring)
    }
}

/// The liveness gate every long loop calls (rule L1).
///
/// `tick()` is a counter decrement on the fast path. When the counter runs out the gate
/// checks `Task.isCancelled`, the stop flag and the deadline, and yields the cooperative pool
/// if at least `yieldEvery` nanoseconds have passed since the last yield. Checks happen at
/// least every `checkEvery` ticks; when single iterations are slow the gate shortens its own
/// stride so that a check still happens every millisecond or so, which keeps cancellation
/// latency bounded regardless of problem size.
public struct WorkGate: Sendable {
    @usableFromInline let deadline: Deadline
    @usableFromInline let maxStride: Int
    @usableFromInline let yieldInterval: UInt64
    @usableFromInline let started: UInt64
    @usableFromInline var stride: Int
    @usableFromInline var countdown: Int
    @usableFromInline var lastCheck: UInt64
    @usableFromInline var lastYield: UInt64

    /// When set, a raised flag stops the loop exactly like a task cancellation.
    public var stopFlag: StopFlag?

    /// The number of times the slow path has run; for the liveness tests.
    public private(set) var checks = 0
    /// The number of times the gate has yielded; for the liveness tests.
    public private(set) var yields = 0

    public init(deadline: Deadline, checkEvery: Int = 64, yieldEvery nanoseconds: UInt64 = 10_000_000) {
        self.deadline = deadline
        maxStride = Swift.max(1, checkEvery)
        yieldInterval = nanoseconds
        let now = Deadline.now
        started = now
        // Start by checking on every tick and lengthen the stride only once ticks prove to be
        // cheap: a loop whose single iteration takes milliseconds must not wait 64 of them
        // for its first check.
        stride = 1
        countdown = 1
        lastCheck = now
        lastYield = now
        stopFlag = nil
    }

    /// Call in every long loop. Throws `StopSignal.cancelled` or `StopSignal.deadline`
    /// (internal signals, mapped to a StopReason at the engine boundary, never surfaced to the
    /// caller as errors).
    @inlinable
    public mutating func tick() async throws(StopSignal) {
        countdown &-= 1
        if countdown <= 0 { try await check() }
    }

    /// The slow path of `tick()`; also callable directly at natural boundaries (a restart, a
    /// node) to force a check.
    public mutating func check() async throws(StopSignal) {
        let now = Deadline.now
        // Aim for a check roughly every millisecond. When the last interval took more than
        // two, shrink the stride in proportion, so a loop whose iterations suddenly became
        // expensive is back to prompt checks after one interval rather than after several
        // halvings; when it took less than a quarter, double it (up to `checkEvery`).
        let elapsed = now &- lastCheck
        if elapsed > 2_000_000 {
            stride = Swift.max(1, Swift.min(stride / 2, Int(Double(stride) * 1_000_000 / Double(elapsed))))
        } else if elapsed < 250_000 {
            stride = Swift.min(maxStride, stride &* 2)
        }
        lastCheck = now
        countdown = stride
        checks &+= 1
        if Task.isCancelled { throw .cancelled }
        if let stopFlag, stopFlag.isSet { throw .cancelled }
        if let limit = deadline.uptimeNanoseconds, now >= limit { throw .deadline }
        if now &- lastYield >= yieldInterval {
            yields &+= 1
            await Task.yield()
            // Time spent suspended is not CPU time of this loop.
            let resumed = Deadline.now
            lastYield = resumed
            lastCheck = resumed
            if Task.isCancelled { throw .cancelled }
            if let stopFlag, stopFlag.isSet { throw .cancelled }
        }
    }

    /// Nanoseconds since the gate was created.
    public var elapsedNanoseconds: UInt64 {
        Deadline.now &- started
    }

    /// Seconds since the gate was created.
    public var elapsedSeconds: Double {
        Double(elapsedNanoseconds) / 1e9
    }

    /// The deadline this gate enforces.
    public var currentDeadline: Deadline { deadline }
}

extension StopSignal {
    /// The public reason an engine reports for this signal.
    public var stopReason: StopReason {
        switch self {
        case .cancelled: return .cancelled
        case .deadline: return .timeLimit
        }
    }
}
