import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func standardConfigs() throws -> [Config] {
    let lp = try NetlibFixtures.load("degen2")
    let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
    return [
        config("Simplex(.primal)", Simplex(.primal), lp),
        config("Simplex(.dual)", Simplex(.dual), lp),
        config("InteriorPoint()", InteriorPoint(), lp),
        config("BranchAndBound()", BranchAndBound(), mip),
        config("CPSAT()", CPSAT(), mip),
        config("CPSAT(lpPropagator:false)", CPSAT(lpPropagator: false), mip),
        config("Automatic()/mip", Automatic(), mip),
        config("Automatic()/lp", Automatic(), lp),
        config("Portfolio(BnB,CPSAT)/mip", Portfolio([BranchAndBound(), CPSAT()]), mip),
        config("Portfolio(primal,IPM)/lp", Portfolio([Simplex(.primal), InteriorPoint()]), lp),
        config("Conditioned(Simplex(.dual))/lp", Conditioned(Simplex(.dual)), lp),
        config("Conditioned(BnB)/mip", Conditioned(BranchAndBound()), mip),
        config("Conditioned(Automatic)/mip", Conditioned(Automatic()), mip),
    ]
}

/// cancel [reps] [filter]: cancellation latency, status and idle CPU after return for every strategy.
func cancelAll(_ args: [String]) async {
    let reps = args.count > 2 ? Int(args[2]) ?? 15 : 15
    let filter = args.count > 3 ? args[3] : ""
    let configs: [Config]
    do { configs = try standardConfigs() } catch { print("load failed \(error)"); return }
    // Baseline idle CPU of the process.
    let c0 = cpuSeconds(); await sleepSeconds(0.3); let c1 = cpuSeconds()
    print("baseline idle CPU over 300 ms: \(ms(c1 - c0)) ms")
    var rng = SeededGenerator(seed: 606)
    for c in configs where filter.isEmpty || c.name.contains(filter) {
        var limited = SolveContext()
        limited.timeLimit = 3
        let (_, window) = await timed { _ = try? await c.run(c.problem, limited) }
        var latencies: [Double] = []
        var interrupted = 0
        var bad: [String] = []
        var idle: [Double] = []
        for _ in 0..<reps {
            let delay = rng.uniform(in: 0...min(window, 1.0))
            let s = await cancelSample(c, delay: delay)
            latencies.append(s.latency)
            idle.append(s.idleCPU)
            if s.stopReason == .cancelled { interrupted += 1 }
            if s.threw || !(s.status == "optimal" || s.stopReason == .cancelled) { bad.append(s.status) }
        }
        print("\(c.name): window \(ms(window)) ms, interrupted \(interrupted)/\(reps), p50 \(ms(quantile(latencies, 0.5))) ms, p99 \(ms(quantile(latencies, 0.99))) ms, max \(ms(latencies.max() ?? 0)) ms, idleCPU max \(ms(idle.max() ?? 0)) ms, unexpected: \(bad)")
    }
}

/// cancel-large <case> [delay]: cancellation latency on larger problems where a single
/// uninterruptible step (presolve/scaling, a dense factorization, the conditioning analyzer)
/// may be long.
func cancelLarge(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "ipmdense"
    let delay = args.count > 3 ? Double(args[3]) ?? 0.5 : 0.5
    let reps = args.count > 4 ? Int(args[4]) ?? 3 : 3
    let size = args.count > 5 ? Int(args[5]) ?? 0 : 0
    let problem: CompiledLP
    let c: Config
    switch which {
    case "ipmdense":
        // m = 4,500 > 4,000: Automatic routes to the interior point; one column has an entry in
        // every row, so the normal equations are dense (4,500 x 4,500 Cholesky per iteration).
        problem = transportWithDenseColumn(sources: 50, sinks: size > 0 ? size - 50 : 4450, seed: 1)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz) choice=\(Automatic.choice(for: problem))")
        c = config("Automatic()", Automatic(), problem)
    case "ipmdense-direct":
        problem = transportWithDenseColumn(sources: 50, sinks: 4450, seed: 1)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("InteriorPoint()", InteriorPoint(), problem)
    case "presolve":
        problem = InstanceGenerator.transport(sources: 400, sinks: 5000, seed: 3)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("Simplex(.dual)", Simplex(.dual), problem)
    case "presolve-ipm":
        problem = InstanceGenerator.transport(sources: 400, sinks: 5000, seed: 3)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("InteriorPoint()", InteriorPoint(), problem)
    case "conditioned":
        // m = 4,000 rows: Simplex(.dual) on sparse QR, then the analyzer's dense LU of the basis.
        problem = InstanceGenerator.transport(sources: 400, sinks: 3600, seed: 5)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("Conditioned(Simplex(.dual))", Conditioned(Simplex(.dual)), problem)
    case "conditioned-inner":
        problem = InstanceGenerator.transport(sources: 400, sinks: 3600, seed: 5)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("Simplex(.dual)", Simplex(.dual), problem)
    case "analyzer":
        problem = InstanceGenerator.transport(sources: 400, sinks: 3600, seed: 5)
        var ctx = SolveContext(); ctx.timeLimit = 0.5
        let inner = try! await Simplex(.dual).solve(problem, context: ctx)
        let (report, t) = await timed { await ConditioningAnalyzer.analyze(problem, after: inner, context: SolveContext()) }
        print("inner \(inner.status), basis \(inner.finalBasis != nil); analyzer alone: \(String(format: "%.3f", t)) s, estimate \(String(describing: report.basisConditionEstimate))")
        return
    case "conditioned-limit":
        problem = InstanceGenerator.transport(sources: 400, sinks: 3600, seed: 5)
        for limit in [0.5, 1.0] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            let (r, t) = await timed { try! await Conditioned(Simplex(.dual)).solve(problem, context: ctx) }
            let (r2, t2) = await timed { try! await Conditioned(Automatic()).solve(problem, context: ctx) }
            print("timeLimit \(limit): Conditioned(Simplex(.dual)) \(r.status) elapsed \(String(format: "%.3f", t)) s; Conditioned(Automatic) \(r2.status) elapsed \(String(format: "%.3f", t2)) s")
        }
        return
    case "conditioned-auto":
        problem = InstanceGenerator.transport(sources: 400, sinks: 3600, seed: 5)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz) choice=\(Automatic.choice(for: problem))")
        c = config("Conditioned(Automatic())", Conditioned(Automatic()), problem)
    case "dense1500":
        problem = InstanceGenerator.transport(sources: 150, sinks: 1350, seed: 9)
        print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz)")
        c = config("Simplex(.primal)", Simplex(.primal), problem)
    default:
        print("unknown case"); return
    }
    for r in 0..<reps {
        let s = await cancelSample(c, delay: delay, idleWindow: 0.5)
        print("\(c.name) rep \(r): cancel after \(delay) s -> latency \(ms(s.latency)) ms, status \(s.status), finishedFirst \(s.finishedFirst), idleCPU \(ms(s.idleCPU)) ms")
    }
}

/// timelimit [limit] [filter]: time limits on problems that take longer than the limit.
func timeLimits(_ args: [String]) async {
    let limit = args.count > 2 ? Double(args[2]) ?? 0.3 : 0.3
    let filter = args.count > 3 ? args[3] : ""
    let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
    let bigLP = InstanceGenerator.transport(sources: 200, sinks: 2000, seed: 11)
    let configs: [Config] = [
        config("Simplex(.primal)/bigLP", Simplex(.primal), bigLP),
        config("Simplex(.dual)/bigLP", Simplex(.dual), bigLP),
        config("InteriorPoint()/bigLP", InteriorPoint(), bigLP),
        config("InteriorPoint(crossover:.none)/bigLP", InteriorPoint(crossover: .none), bigLP),
        config("BranchAndBound()/mip", BranchAndBound(), mip),
        config("BranchAndBound(engine:IPM)/mip", BranchAndBound(engine: InteriorPoint()), mip),
        config("CPSAT()/mip", CPSAT(), mip),
        config("CPSAT(lpPropagator:false)/mip", CPSAT(lpPropagator: false), mip),
        config("Automatic()/mip", Automatic(), mip),
        config("Automatic()/bigLP", Automatic(), bigLP),
        config("Portfolio(BnB,CPSAT)/mip", Portfolio([BranchAndBound(), CPSAT()]), mip),
        config("Portfolio(dual,IPM)/bigLP", Portfolio([Simplex(.dual), InteriorPoint()]), bigLP),
        config("Conditioned(BnB)/mip", Conditioned(BranchAndBound()), mip),
        config("Conditioned(Simplex(.dual))/bigLP", Conditioned(Simplex(.dual)), bigLP),
    ]
    for c in configs where filter.isEmpty || c.name.contains(filter) {
        var context = SolveContext()
        context.timeLimit = limit
        let t0 = uptime()
        var line = ""
        do {
            let r = try await c.run(c.problem, context)
            line = "status \(r.status) objective \(r.objective.map { String($0) } ?? "nil")"
        } catch {
            line = "THREW \(error)"
        }
        let elapsed = uptime() - t0
        print("\(c.name): limit \(limit) s, elapsed \(String(format: "%.3f", elapsed)) s (overshoot \(ms(elapsed - limit)) ms), \(line)")
    }
}

/// dense-detail <m> <limit>: per-iteration timing of the interior point on the dense-column LP,
/// and the time-limit overshoot.
func denseDetail(_ args: [String]) async {
    let m = args.count > 2 ? Int(args[2]) ?? 6500 : 6500
    let limit = args.count > 3 ? Double(args[3]) ?? 1.0 : 1.0
    let problem = transportWithDenseColumn(sources: 50, sinks: m - 50, seed: 1)
    print("problem m=\(problem.m) n=\(problem.n) nnz=\(problem.nnz) choice=\(Automatic.choice(for: problem))")
    final class Box: @unchecked Sendable { var times: [(Double, String)] = []; let lock = NSLock() }
    let box = Box()
    var ctx = SolveContext()
    let t0 = uptime()
    ctx.progress = { e in
        box.lock.lock(); box.times.append((uptime() - t0, "\(e)".prefix(60).description)); box.lock.unlock()
    }
    ctx.timeLimit = limit
    let (r, t) = await timed { try? await Automatic().solve(problem, context: ctx) }
    print("timeLimit \(limit): elapsed \(String(format: "%.3f", t)) s, overshoot \(ms(t - limit)) ms, status \(String(describing: r?.status)) engine \(r?.engine ?? "-")")
    var last = 0.0
    for (time, text) in box.times {
        print(String(format: "  +%.3f s (gap %.0f ms) ", time, (time - last) * 1000) + text)
        last = time
    }
}
