// Specification §12.3 and rule L1: Deadline, StopFlag and the WorkGate every long loop calls.
//
// The suites run in parallel on a loaded machine (and under Thread Sanitizer), where a task
// that yields can wait a second or more for a thread. The assertions therefore count ticks,
// checks and amounts of work, which the gate controls, and never bound wall-clock time from
// above, which it does not control. Rule L1's latency figures (p99 ≤ 50 ms) are measured by
// the liveness suite under controlled conditions; what is pinned down here is the mechanism
// that makes them possible: a stopped loop notices at its next check, the first check is the
// first tick, a slow loop is checked on every tick, and no check is more than 64 ticks away.

import Testing
import ZTronLPCore
import ZTronLPNumerics

private let millisecond: UInt64 = 1_000_000

/// Ticks `gate` until it throws, doing `work` nanoseconds of CPU work before every tick.
/// Returns the signal and the number of ticks that completed without throwing.
private func runUntilStopped(_ gate: inout WorkGate, work: UInt64 = 0, limit: Int = .max) async -> (signal: StopSignal?, ticks: Int) {
    var ticks = 0
    do throws(StopSignal) {
        while ticks < limit {
            if work > 0 { spin(nanoseconds: work) }
            try await gate.tick()
            ticks += 1
        }
    } catch {
        return (error, ticks)
    }
    return (nil, ticks)
}

@Suite("Deadline, StopFlag and WorkGate")
struct WorkGateTests {
    // MARK: Deadline

    @Test func noDeadline() {
        #expect(Deadline.none.uptimeNanoseconds == nil)
        #expect(!Deadline.none.hasPassed)
        #expect(Deadline.none.remainingSeconds == nil)
        // nil, infinite and NaN limits all mean "no deadline".
        #expect(Deadline.after(seconds: nil) == .none)
        #expect(Deadline.after(seconds: .infinity) == .none)
        #expect(Deadline.after(seconds: .nan) == .none)
    }

    @Test func aDeadlineInTheFutureAndInThePast() {
        let hour = Deadline.after(seconds: 3_600)
        #expect(!hour.hasPassed)
        let remaining = hour.remainingSeconds ?? -1
        #expect(remaining > 3_599 && remaining <= 3_600)

        // Zero and negative limits have already passed.
        #expect(Deadline.after(seconds: 0).hasPassed)
        #expect(Deadline.after(seconds: -5).hasPassed)
        #expect(Deadline.after(seconds: 0).remainingSeconds == 0)
        #expect(Deadline(uptimeNanoseconds: 1).hasPassed)

        // A limit far beyond what nanoseconds can count does not overflow.
        let forever = Deadline.after(seconds: 1e15)
        #expect(!forever.hasPassed && (forever.remainingSeconds ?? 0) > 1e8)
        #expect(Deadline.now > 0)
        let before = Deadline.now
        #expect(Deadline.now >= before)                    // monotone
    }

    @Test func theEarlierOfTwoDeadlines() {
        let soon = Deadline(uptimeNanoseconds: 100)
        let late = Deadline(uptimeNanoseconds: 200)
        #expect(soon.earlier(late) == soon && late.earlier(soon) == soon)
        #expect(soon.earlier(.none) == soon && Deadline.none.earlier(late) == late)
        #expect(Deadline.none.earlier(.none) == .none)
        #expect(Set([soon, late, Deadline(uptimeNanoseconds: 100)]).count == 2)
    }

    @Test func stopSignalsMapToPublicReasons() {
        #expect(StopSignal.cancelled.stopReason == .cancelled)
        #expect(StopSignal.deadline.stopReason == .timeLimit)
    }

    // MARK: StopFlag

    @Test func aStopFlagIsOneWay() async {
        let flag = StopFlag()
        #expect(!flag.isSet)
        flag.set()
        #expect(flag.isSet)
        flag.set()                                         // idempotent
        #expect(flag.isSet)
        // Raised in one task, seen in others.
        let shared = StopFlag()
        let seen = await withTaskGroup(of: Bool.self) { group -> Int in
            group.addTask {
                shared.set()
                return true
            }
            for _ in 0..<4 {
                group.addTask {
                    while !shared.isSet { await Task.yield() }
                    return true
                }
            }
            var count = 0
            for await _ in group { count += 1 }
            return count
        }
        #expect(seen == 5)
    }

    // MARK: WorkGate — stopping

    @Test func aCancelledTaskStopsAtItsFirstTick() async {
        let task = Task { () -> (StopSignal?, Int, Int) in
            var gate = WorkGate(deadline: .none)
            while !Task.isCancelled { await Task.yield() }
            let outcome = await runUntilStopped(&gate)
            return (outcome.signal, outcome.ticks, gate.checks)
        }
        task.cancel()
        let (signal, ticks, checks) = await task.value
        #expect(signal == .cancelled)
        #expect(ticks == 0 && checks == 1)                 // the very first tick checks
    }

    @Test func cancellationInterruptsARunningLoop() async throws {
        let task = Task { () -> (StopSignal?, Int) in
            var gate = WorkGate(deadline: .none)
            let outcome = await runUntilStopped(&gate)
            return (outcome.signal, outcome.ticks)
        }
        try await Task.sleep(nanoseconds: 10 * millisecond)
        task.cancel()
        let (signal, ticks) = await task.value            // returns at all: the loop was interrupted
        #expect(signal == .cancelled)
        #expect(ticks > 0)                                 // it really was running when cancelled
    }

    @Test func theDeadlineStopsTheLoop() async {
        var gate = WorkGate(deadline: .after(seconds: 0.03))
        #expect(gate.currentDeadline.uptimeNanoseconds != nil)
        let outcome = await runUntilStopped(&gate)
        #expect(outcome.signal == .deadline)
        #expect(outcome.ticks > 0)
        // Never early. (How late depends on when the task next gets a thread.)
        let elapsed = gate.elapsedNanoseconds
        #expect(elapsed >= 29 * millisecond)
        #expect(gate.elapsedSeconds >= Double(elapsed) / 1e9)

        // A deadline that has already passed stops the first tick.
        var late = WorkGate(deadline: .after(seconds: 0))
        let immediate = await runUntilStopped(&late)
        #expect(immediate.signal == .deadline && immediate.ticks == 0)
    }

    @Test func aRaisedStopFlagStopsTheLoopLikeACancellation() async throws {
        let flag = StopFlag()
        let task = Task { () -> (StopSignal?, Bool) in
            var gate = WorkGate(deadline: .none)
            gate.stopFlag = flag
            let outcome = await runUntilStopped(&gate)
            return (outcome.signal, Task.isCancelled)
        }
        try await Task.sleep(nanoseconds: 5 * millisecond)
        flag.set()
        let (signal, wasCancelled) = await task.value
        #expect(signal == .cancelled)
        #expect(!wasCancelled)                             // the task itself was never cancelled

        // A flag that is already raised stops the first tick; without a flag nothing stops.
        var gate = WorkGate(deadline: .none)
        gate.stopFlag = flag
        let immediate = await runUntilStopped(&gate)
        #expect(immediate.signal == .cancelled && immediate.ticks == 0)
        var free = WorkGate(deadline: .none)
        let unstopped = await runUntilStopped(&free, limit: 10_000)
        #expect(unstopped.signal == nil && unstopped.ticks == 10_000)
    }

    @Test func aDirectCheckForcesTheSlowPath() async throws {
        var gate = WorkGate(deadline: .none)
        for _ in 0..<5 { try await gate.check() }
        #expect(gate.checks == 5)
        let flag = StopFlag()
        gate.stopFlag = flag
        flag.set()
        var signal: StopSignal?
        do throws(StopSignal) {
            try await gate.check()
        } catch {
            signal = error
        }
        #expect(signal == .cancelled)
    }

    // MARK: WorkGate — the stride

    @Test func aFastLoopIsCheckedAtLeastEverySixtyFourTicksAndNotMuchMoreOften() async {
        var gate = WorkGate(deadline: .none)
        let ticks = 400_000
        let outcome = await runUntilStopped(&gate, limit: ticks)
        #expect(outcome.signal == nil)
        // At least every 64 ticks …
        #expect(gate.checks >= ticks / 64)
        // … and, once ticks have proved cheap, close to that: the fast path is a counter.
        #expect(gate.checks <= ticks / 8)
    }

    @Test func theCheckIntervalIsConfigurable() async {
        var frequent = WorkGate(deadline: .none, checkEvery: 4)
        _ = await runUntilStopped(&frequent, limit: 10_000)
        #expect(frequent.checks >= 10_000 / 4)
        // Zero and negative intervals mean "every tick".
        var always = WorkGate(deadline: .none, checkEvery: 0)
        _ = await runUntilStopped(&always, limit: 500)
        #expect(always.checks == 500)
    }

    @Test func aSlowLoopIsCheckedOnEveryTick() async {
        // Each tick follows 3 ms of work. Sixty-four of them would be 190 ms: the gate must
        // not wait that long for its first check, nor for any later one.
        var gate = WorkGate(deadline: .after(seconds: 0.02))
        let outcome = await runUntilStopped(&gate, work: 3 * millisecond)
        #expect(outcome.signal == .deadline)
        #expect(gate.checks == outcome.ticks + 1)          // one check per tick, the last one threw
        #expect(outcome.ticks <= 7)                        // 20 ms of 3 ms ticks
    }

    @Test func afterARegimeChangeTheNextCheckIsAtMostSixtyFourTicksAway() async {
        // Warm up with cheap ticks until the stride is long, then make every tick expensive
        // and raise the stop flag: the gate notices within its maximum stride.
        var gate = WorkGate(deadline: .none)
        _ = await runUntilStopped(&gate, limit: 200_000)
        let flag = StopFlag()
        gate.stopFlag = flag
        flag.set()
        let outcome = await runUntilStopped(&gate, work: 100_000)
        #expect(outcome.signal == .cancelled)
        #expect(outcome.ticks < 64)
    }

    // MARK: WorkGate — yielding

    @Test func theGateYieldsAtLeastEveryTenMillisecondsOfWork() async {
        // 800 ticks with 0.2 ms of work before each: 160 ms of work. The amount of work done
        // is recorded every time the yield counter moves, so time the task spends waiting for
        // a thread after a yield does not count against the gate.
        var gate = WorkGate(deadline: .none)
        let workPerTick = 0.2
        var workAtYield: [Double] = [0]
        var seen = 0
        for tick in 1...800 {
            spin(nanoseconds: 200_000)
            try? await gate.tick()
            if gate.yields != seen {
                seen = gate.yields
                workAtYield.append(Double(tick) * workPerTick)
            }
        }
        workAtYield.append(800 * workPerTick)
        var longestStretch = 0.0
        for k in 1..<workAtYield.count { longestStretch = max(longestStretch, workAtYield[k] - workAtYield[k - 1]) }
        // Ten milliseconds, plus at most one check interval and one tick.
        #expect(longestStretch <= 12, "longest stretch of work without a yield: \(longestStretch) ms")
        #expect(gate.yields >= 13)
    }

    @Test func theYieldIntervalIsConfigurable() async {
        var eager = WorkGate(deadline: .none, yieldEvery: 2 * millisecond)
        var lazy = WorkGate(deadline: .none, yieldEvery: 60_000 * millisecond)
        for _ in 0..<300 {                                 // 60 ms of work
            spin(nanoseconds: 200_000)
            try? await eager.tick()
            try? await lazy.tick()
        }
        #expect(eager.yields >= 20)
        #expect(lazy.yields == 0)
    }

    @Test func yieldingLetsOtherTasksRun() async {
        // A CPU-bound loop on the cooperative pool must not starve its neighbours (rule L8):
        // while one task spins behind a gate, a second task keeps making progress.
        let ticker = Task { () -> Int in
            var beats = 0
            while !Task.isCancelled {
                beats += 1
                await Task.yield()
            }
            return beats
        }
        var gate = WorkGate(deadline: .none)
        _ = await runUntilStopped(&gate, work: 100_000, limit: 600)      // 60 ms of work
        ticker.cancel()
        #expect(await ticker.value > 0)
        #expect(gate.yields >= 4)
    }

    @Test func aGateIsAValue() async {
        requireSendableGate(WorkGate.self)
        var original = WorkGate(deadline: .none)
        _ = await runUntilStopped(&original, limit: 100)
        var copy = original
        _ = await runUntilStopped(&copy, limit: 10_000)
        #expect(copy.checks > original.checks)             // the copy counts on its own
    }
}

private func requireSendableGate<T: Sendable>(_: T.Type) {}
