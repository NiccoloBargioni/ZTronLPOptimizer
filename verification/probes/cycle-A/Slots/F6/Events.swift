import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum Probe: LPVariable {
    case x, y
    var domain: VariableDomain { .continuous }
}

/// Consumes a stream with a timeout; returns the events and whether the stream ended.
func drain(_ stream: AsyncStream<SolverEvent>, timeout: Double, delayPerEvent: Double = 0) async -> (events: [SolverEvent], ended: Bool) {
    await withTaskGroup(of: ([SolverEvent], Bool)?.self) { group in
        group.addTask {
            var got: [SolverEvent] = []
            for await e in stream {
                got.append(e)
                if delayPerEvent > 0 { await sleepSeconds(delayPerEvent) }
            }
            return (got, true)
        }
        group.addTask {
            await sleepSeconds(timeout)
            return nil
        }
        var result: ([SolverEvent], Bool) = ([], false)
        for await r in group {
            if let r { result = r; group.cancelAll(); break }
            // timed out
            group.cancelAll()
            break
        }
        return (result.0, result.1)
    }
}

func describe(_ events: [SolverEvent]) -> String {
    let finished = events.filter(\.isFinished).count
    let startedFirst: Bool = { if case .started = events.first { return true } else { return false } }()
    return "count \(events.count), started-first \(startedFirst), finished \(finished), last-is-finished \(events.last?.isFinished ?? false)"
}

func eventsProbe(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "all"

    if which == "all" || which == "synthetic" {
        // 1. Newest 256 kept, .finished kept, events after .finished dropped, order kept.
        var ctx = SolveContext()
        let stream = ctx.makeEventStream()
        for i in 0..<1000 { ctx.progress!(.nodes(processed: i, open: 0)) }
        ctx.progress!(.finished(status: .optimal, seconds: 0))
        ctx.progress!(.nodes(processed: 99_999, open: 0))
        let (got, ended) = await drain(stream, timeout: 2)
        var ordered = true
        var previous = -1
        for e in got { if case .nodes(let p, _) = e { if p <= previous { ordered = false }; previous = p } }
        let firstNode: Int = { if case .nodes(let p, _) = got.first { return p } else { return -1 } }()
        print("synthetic: \(describe(got)), ended \(ended), first node \(firstNode), ordered \(ordered)")
    }

    if which == "all" || which == "two" {
        // 2. Two streams on one context; both must see every event and end.
        var ctx = SolveContext()
        let s1 = ctx.makeEventStream()
        let s2 = ctx.makeEventStream()
        let mip = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)
        async let a = drain(s1, timeout: 30)
        async let b = drain(s2, timeout: 30)
        let r = try? await BranchAndBound().solve(mip, context: ctx)
        let (ea, eb) = await (a, b)
        print("two streams: solve \(String(describing: r?.status)); s1 \(describe(ea.events)) ended \(ea.ended); s2 \(describe(eb.events)) ended \(eb.ended); equal \(ea.events == eb.events)")
    }

    if which == "all" || which == "noconsumer" {
        // 3. Nobody consumes: the solve must return, memory bounded.
        var ctx = SolveContext()
        ctx.timeLimit = 2
        let stream = ctx.makeEventStream()
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        let (r, t) = await timed { try? await BranchAndBound(deterministic: true).solve(mip, context: ctx) }
        let (late, ended) = await drain(stream, timeout: 2)
        print("no consumer: solve \(String(describing: r?.status)) in \(String(format: "%.3f", t)) s; late drain \(describe(late)) ended \(ended)")
    }

    if which == "all" || which == "slow" {
        // 4. A slow consumer on a real solve that emits many events: loses old ones, never .finished.
        var ctx = SolveContext()
        ctx.timeLimit = 5
        let recorder = EventRecorder(context: ctx)
        var listening = recorder.context
        let stream = listening.makeEventStream()
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        async let slow = drain(stream, timeout: 60, delayPerEvent: 0.002)
        let r = try? await BranchAndBound(deterministic: true).solve(mip, context: listening)
        let all = await recorder.finish()
        let got = await slow
        let tailMatches = got.events == Array(all.suffix(got.events.count))
        print("slow consumer: solve \(String(describing: r?.status)); recorder \(describe(all)); stream \(describe(got.events)) ended \(got.ended); stream is a suffix of all: \(tailMatches)")
    }

    if which == "all" || which == "facades" {
        // 5. Event order of facades and nested solves.
        let lp = try! NetlibFixtures.load("share2b")
        let mip = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)
        func check<S: SolverStrategy>(_ label: String, _ s: S, _ p: CompiledLP, _ ctx: SolveContext = .init()) async {
            let (events, result) = await LivenessHarness.recordEvents(s, problem: p, context: ctx)
            let starts = events.filter { if case .started = $0 { return true } else { return false } }.count
            var status = "threw"
            if case .success(let a) = result { status = "\(a.status)" }
            if case .failure(let e) = result { status = "threw \(e)" }
            print("\(label): \(describe(events)), started events \(starts), status \(status), L10 \(LivenessHarness.finishesExactlyOnce(events))")
        }
        await check("Automatic/lp", Automatic(), lp)
        await check("Automatic/mip", Automatic(), mip)
        await check("Portfolio(primal,dual,IPM)/lp", Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()]), lp)
        await check("Portfolio(CPSAT,BnB)/lp (CPSAT throws)", Portfolio([CPSAT(), BranchAndBound()]), lp)
        await check("Portfolio(CPSAT)/lp (all throw)", Portfolio([CPSAT()]), lp)
        await check("Conditioned(Portfolio(BnB,CPSAT))/mip", Conditioned(Portfolio([BranchAndBound(), CPSAT()])), mip)
        await check("Conditioned(CPSAT)/lp (inner throws)", Conditioned(CPSAT()), lp)
        await check("Portfolio(Portfolio(BnB),CPSAT)/mip", Portfolio([Portfolio([BranchAndBound()]), CPSAT()]), mip)
        var zero = SolveContext(); zero.timeLimit = 0
        await check("Portfolio(BnB,CPSAT)/mip timeLimit 0", Portfolio([BranchAndBound(), CPSAT()]), mip, zero)
        await check("Conditioned(BnB)/mip timeLimit 0", Conditioned(BranchAndBound()), mip, zero)
    }

    if which == "all" || which == "model-throw" {
        // 6. The LPModel form whose compile throws: is .finished delivered, does the stream end?
        var ctx = SolveContext()
        let stream = ctx.makeEventStream()
        let model = LPModel<Probe>()
            .minimizing(1.0 * Probe.x + Double.nan * Probe.y)
            .subjectTo { (1.0 * Probe.x + 1.0 * Probe.y >= 1).named("r") }
        var threw = "no"
        do { _ = try await Simplex(.dual).solve(model, context: ctx) } catch { threw = "\(error)" }
        ctx = SolveContext()   // drop the context that holds the continuation
        let (got, ended) = await drain(stream, timeout: 2)
        print("model compile throws: threw \(threw); stream \(describe(got)) ended within 2 s: \(ended)")
    }
}

/// events-model: control (valid model) vs compile error, same consumer pattern as an app.
final class EndFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int? = nil
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int? { lock.lock(); defer { lock.unlock() }; return value }
}

func eventsModel(_ args: [String]) async {
    for valid in [true, false] {
        var ctx = SolveContext()
        let stream = ctx.makeEventStream()
        let flag = EndFlag()
        let consumer = Task.detached {
            var count = 0
            for await _ in stream { count += 1 }
            flag.set(count)
        }
        let c: Double = valid ? 2.0 : .nan
        let model = LPModel<Probe>()
            .minimizing(1.0 * Probe.x + c * Probe.y)
            .subjectTo { (1.0 * Probe.x + 1.0 * Probe.y >= 1).named("r") }
        var outcome = ""
        do { let s = try await Automatic().solve(model, context: ctx); outcome = "\(s.status)" } catch { outcome = "threw \(error)" }
        ctx = SolveContext()
        var waited = 0.0
        while flag.get() == nil && waited < 5 { await sleepSeconds(0.05); waited += 0.05 }
        let ended = flag.get()
        print("valid \(valid): solve \(outcome); consumer ended within 5 s: \(ended.map { "yes, \($0) events" } ?? "NO (still waiting)")")
        consumer.cancel()
        await sleepSeconds(0.2)
        print("  after cancelling the consumer task: ended \(flag.get() != nil)")
    }
}
