// Event stream contract: newest 256, ordered, .finished last and unique, multiple consumers,
// no deadlock when nobody consumes, serialization of callbacks, throwing paths.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Records every callback, detects overlapping (concurrent) invocations and events after .finished.
final class CallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var finishedSeen = 0
    private(set) var afterFinished = 0
    private(set) var totalCount = 0
    let spinNs: UInt64
    init(spinNs: UInt64 = 0) { self.spinNs = spinNs }
    var total: Int { lock.lock(); defer { lock.unlock() }; return totalCount }
    var callback: @Sendable (SolverEvent) -> Void {
        { [self] event in
            lock.lock()
            inFlight += 1
            if inFlight > maxInFlight { maxInFlight = inFlight }
            totalCount += 1
            if finishedSeen > 0 { afterFinished += 1 }
            if event.isFinished { finishedSeen += 1 }
            lock.unlock()
            if spinNs > 0 {
                let t = nowNs()
                while nowNs() &- t < spinNs {}
            }
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "events=\(totalCount) maxConcurrentCallbacks=\(maxInFlight) finished=\(finishedSeen) afterFinished=\(afterFinished)"
    }
}

func drain(_ stream: AsyncStream<SolverEvent>, timeout: Double) async -> (events: [SolverEvent], ended: Bool) {
    let task = Task { () -> [SolverEvent] in
        var out: [SolverEvent] = []
        for await e in stream { out.append(e) }
        return out
    }
    let killer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); task.cancel() }
    let events = await task.value
    let ended = !task.isCancelled
    killer.cancel()
    return (events, ended)
}

func eventKey(_ e: SolverEvent) -> String { "\(e)" }

func streamSuffixCheck<S: SolverStrategy>(_ label: String, _ s: S, _ lp: CompiledLP, limit: Double) async {
    // Full record first (EventRecorder keeps all), then makeEventStream on top, never consumed during the solve.
    let recorder = EventRecorder()
    var ctx = recorder.context
    ctx.timeLimit = limit
    let stream1 = ctx.makeEventStream()
    let stream2 = ctx.makeEventStream()
    let t = nowNs()
    let res: String
    var returned: SolveStatus? = nil
    do { let st = try await s.solve(lp, context: ctx).status; returned = st; res = statusName(st) } catch { res = "threw \(error)" }
    let el = secs(t)
    let all = await recorder.finish()
    let (d1, end1) = await drain(stream1, timeout: 2)
    let (d2, end2) = await drain(stream2, timeout: 2)
    let expected = Array(all.suffix(256))
    let same1 = d1.map(eventKey) == expected.map(eventKey)
    let same2 = d2.map(eventKey) == expected.map(eventKey)
    let finishedCount = all.filter(\.isFinished).count
    let lastIsFinished = all.last?.isFinished ?? false
    let firstIsStarted: Bool = { if case .started = all.first { return true }; return false }()
    var finishedMatches = true
    if let returned, case .finished(let st, _)? = all.last { finishedMatches = (st == returned) }
    let verdict = (same1 && same2 && end1 && end2 && finishedCount == 1 && lastIsFinished && firstIsStarted && finishedMatches) ? "HELD" : "FAIL"
    print("EVENTS \(verdict) \(label): t=\(String(format: "%.2f", el)) status=\(res) total=\(all.count) stream1=\(d1.count)(ended=\(end1), suffixMatch=\(same1)) stream2=\(d2.count)(ended=\(end2), suffixMatch=\(same2)) finished=\(finishedCount) lastIsFinished=\(lastIsFinished) firstIsStarted=\(firstIsStarted) finishedStatusMatchesReturn=\(finishedMatches)")
}

func callbackCheck<S: SolverStrategy>(_ label: String, _ s: S, _ lp: CompiledLP, limit: Double, cancelAfter: Double? = nil, spinNs: UInt64 = 20_000) async {
    let probe = CallbackProbe(spinNs: spinNs)
    var ctx = SolveContext()
    ctx.timeLimit = limit
    ctx.progress = probe.callback
    let task = Task { () -> String in
        do { return statusName(try await s.solve(lp, context: ctx).status) } catch { return "threw \(error)" }
    }
    if let c = cancelAfter {
        try? await Task.sleep(nanoseconds: UInt64(c * 1e9))
        task.cancel()
    }
    let st = await task.value
    // events that arrive after solve returned
    let before = probe.total
    try? await Task.sleep(nanoseconds: 300_000_000)
    let late = probe.total - before
    print("CALLBACK \(label): status=\(st) \(probe.summary) eventsAfterReturn=\(late)")
}

func runEvents(_ args: [String]) async {
    let which = args.first ?? "all"
    let lp = Problems.lpTransport()
    let mip = Problems.mipHard()
    let degen = Problems.lpDegen2()
    if which == "all" || which == "stream" {
        await streamSuffixCheck("Simplex(.primal)/transport", Simplex(.primal), lp, limit: 20)
        await streamSuffixCheck("InteriorPoint/degen2", InteriorPoint(), degen, limit: 20)
        await streamSuffixCheck("BranchAndBound/mipHard", BranchAndBound(), mip, limit: 1.5)
        await streamSuffixCheck("CPSAT/mipHard", CPSAT(), mip, limit: 1.5)
        await streamSuffixCheck("Automatic/mipHard", Automatic(), mip, limit: 1.0)
        await streamSuffixCheck("Portfolio(bnb,cpsat)/mipHard", Portfolio([BranchAndBound(), CPSAT()]), mip, limit: 1.5)
        await streamSuffixCheck("Conditioned(bnb)/mipHard", Conditioned(BranchAndBound()), mip, limit: 1.0)
        // throwing paths
        await streamSuffixCheck("CPSAT/transport(continuous: throws)", CPSAT(), lp, limit: 5)
        await streamSuffixCheck("Conditioned(CPSAT)/transport(throws)", Conditioned(CPSAT()), lp, limit: 5)
        await streamSuffixCheck("Portfolio([])/transport(throws)", Portfolio([]), lp, limit: 5)
        await streamSuffixCheck("Portfolio([CPSAT,CPSAT])/transport(all throw)", Portfolio([CPSAT(), CPSAT(lpPropagator: false)]), lp, limit: 5)
        await streamSuffixCheck("Automatic/transport-with-CPSAT? (LP)", Automatic(), degen, limit: 5)
    }
    if which == "all" || which == "callback" {
        await callbackCheck("BranchAndBound(8 workers)/mipHard", BranchAndBound(), mip, limit: 1.5)
        await callbackCheck("CPSAT/mipHard", CPSAT(), mip, limit: 1.5)
        await callbackCheck("Portfolio(bnb,cpsat,bnb-dual)/mipHard", Portfolio([BranchAndBound(), CPSAT(), BranchAndBound(engine: Simplex(.dual))]), mip, limit: 1.5)
        await callbackCheck("Portfolio(primal,dual,ipm)/transport", Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()]), lp, limit: 20)
        await callbackCheck("Portfolio(bnb,cpsat)/mipHard cancelled@0.4", Portfolio([BranchAndBound(), CPSAT()]), mip, limit: 10, cancelAfter: 0.4)
        await callbackCheck("Conditioned(bnb)/mipHard cancelled@0.3", Conditioned(BranchAndBound()), mip, limit: 10, cancelAfter: 0.3)
        await callbackCheck("Automatic/mipHard cancelled@0.3", Automatic(), mip, limit: 10, cancelAfter: 0.3)
    }
    if which == "concurrency" {
        let mip = Problems.mipHard()
        for run in 0..<3 {
            await callbackCheck("run\(run) Portfolio([BnB(primal), BnB(dual)])/mipHard", Portfolio([BranchAndBound(), BranchAndBound(engine: Simplex(.dual))]), mip, limit: 1.0)
            await callbackCheck("run\(run) BnB(primal) alone/mipHard", BranchAndBound(), mip, limit: 1.0)
        }
    }
    if which == "nested" {
        let mip = Problems.mipHard()
        await streamSuffixCheck("BnB(engine: IPM)/mipHard", BranchAndBound(engine: InteriorPoint()), mip, limit: 1.0)
        await streamSuffixCheck("Conditioned(Portfolio(bnb,cpsat))/mipHard", Conditioned(Portfolio([BranchAndBound(), CPSAT()])), mip, limit: 1.0)
        await streamSuffixCheck("Portfolio(Conditioned(bnb), Automatic)/mipHard", Portfolio([Conditioned(BranchAndBound()), Automatic()]), mip, limit: 1.0)
        await streamSuffixCheck("Portfolio(Portfolio(bnb), cpsat)/mipHard", Portfolio([Portfolio([BranchAndBound()]), CPSAT()]), mip, limit: 1.0)
        await streamSuffixCheck("InteriorPoint/transport", InteriorPoint(), Problems.lpTransport(), limit: 20)
    }
    if which == "all" || which == "flood" {
        // Nobody consumes: no deadlock, bounded memory (we can only observe that the solve returns).
        var ctx = SolveContext()
        ctx.timeLimit = 3
        let stream = ctx.makeEventStream()
        let t = nowNs()
        let a = try? await BranchAndBound().solve(mip, context: ctx)
        print("FLOOD unconsumed stream: solve returned after \(String(format: "%.2f", secs(t))) s status=\(a.map { statusName($0.status) } ?? "threw")")
        let (d, ended) = await drain(stream, timeout: 2)
        print("FLOOD drained afterwards: \(d.count) events ended=\(ended) last=\(d.last.map(eventKey) ?? "-")")
    }
}
