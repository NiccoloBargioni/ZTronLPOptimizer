import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func portfolioProbe(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "all"
    let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)

    if which == "all" || which == "worse" {
        // Two inconclusive members: a quick one with a poor incumbent and a slower one with a
        // better incumbent. "The best of what came back" should not be the worse incumbent.
        let quick = BranchAndBound(engine: Simplex(.dual), heuristics: .none, nodeLimit: 4, deterministic: true)
        let slow = BranchAndBound(engine: Simplex(.dual), nodeLimit: 3000, deterministic: true)
        let a = try! await quick.solve(mip)
        let b = try! await slow.solve(mip)
        print("members alone: quick \(a.status) obj \(String(describing: a.objectiveValue)); slow \(b.status) obj \(String(describing: b.objectiveValue))")
        for order in 0..<2 {
            let p = order == 0 ? Portfolio([quick, slow]) : Portfolio([slow, quick])
            let r = try! await p.solve(mip)
            print("Portfolio order \(order): status \(r.status) obj \(String(describing: r.objectiveValue)) winner \(r.winner) others \(r.others.map { "\($0.strategy): \($0.status)" })")
        }
    }

    if which == "all" || which == "worse2" {
        // Deterministic members (one worker, fixed seed): the same result inside the portfolio
        // as alone. Both stop at their node limit with an incumbent.
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        let quick = BranchAndBound(engine: Simplex(.dual), nodeLimit: 30, deterministic: true)
        let slow = BranchAndBound(engine: Simplex(.dual), nodeLimit: 4000, deterministic: true)
        let (a, ta) = await timed { try! await quick.solve(hard) }
        let (b, tb) = await timed { try! await slow.solve(hard) }
        print("alone: quick \(a.status) obj \(String(describing: a.objectiveValue)) bound \(String(describing: a.bound)) in \(String(format: "%.2f", ta)) s; slow \(b.status) obj \(String(describing: b.objectiveValue)) bound \(String(describing: b.bound)) in \(String(format: "%.2f", tb)) s (maximize)")
        for order in 0..<2 {
            let p = order == 0 ? Portfolio([quick, slow]) : Portfolio([slow, quick])
            let r = try! await p.solve(hard)
            print("Portfolio order \(order): \(r.status) obj \(String(describing: r.objectiveValue)) bound \(String(describing: r.bound)) winner \(r.winner) others \(r.others.map { "\($0.strategy): \($0.status)" })")
        }
    }

    if which == "all" || which == "timelimit" {
        // A natural case: both members stop at the time limit with incumbents.
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        for limit in [0.3, 0.6] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            let alone1 = try! await BranchAndBound().solve(hard, context: ctx)
            let alone2 = try! await CPSAT().solve(hard, context: ctx)
            let r = try! await Portfolio([BranchAndBound(), CPSAT()]).solve(hard, context: ctx)
            print("limit \(limit): BnB alone \(alone1.status) \(String(describing: alone1.objectiveValue)); CPSAT alone \(alone2.status) \(String(describing: alone2.objectiveValue)); Portfolio \(r.status) \(String(describing: r.objectiveValue)) winner \(r.winner); others \(r.others.map { "\($0.strategy): \($0.status)" })")
        }
    }

    if which == "all" || which == "race" {
        // First conclusive wins, others cancelled, reported winner matches, wall time.
        let lp = InstanceGenerator.transport(sources: 200, sinks: 2000, seed: 11)
        let (ipm, tIPM) = await timed { try! await InteriorPoint().solve(lp) }
        print("IPM alone: \(ipm.status) \(String(describing: ipm.objectiveValue)) in \(String(format: "%.3f", tIPM)) s")
        let (r, t) = await timed { try! await Portfolio([Simplex(.primal), InteriorPoint()]).solve(lp) }
        print("Portfolio(primal, IPM): \(r.status) \(String(describing: r.objectiveValue)) winner \(r.winner) base.engine \(r.base.engine) others \(r.others.map { "\($0.strategy): \($0.status)" }) wall \(String(format: "%.3f", t)) s, seconds field \(String(format: "%.3f", r.seconds))")
        let c0 = cpuSeconds(); await sleepSeconds(0.3); let c1 = cpuSeconds()
        print("idle CPU after portfolio: \(ms(c1 - c0)) ms")
    }

    if which == "all" || which == "empty" {
        do { _ = try await Portfolio([]).solve(mip); print("empty: did not throw") } catch { print("empty: threw \(error)") }
        let lp = try! NetlibFixtures.load("afiro")
        do { _ = try await Portfolio([CPSAT(), CPSAT(lpPropagator: false)]).solve(lp); print("all-throw: did not throw") } catch { print("all-throw: threw \(error)") }
        let r = try! await Portfolio([CPSAT(), Simplex(.dual)]).solve(lp)
        print("one throws: \(r.status) winner \(r.winner) others \(r.others.map { "\($0.strategy): \($0.status)" })")
    }

    if which == "all" || which == "cancelparent" {
        // Cancelling the portfolio: every member stops; result status.
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        let c = config("Portfolio(BnB,CPSAT)", Portfolio([BranchAndBound(), CPSAT()]), hard)
        for d in [0.0, 0.05, 0.3] {
            let s = await cancelSample(c, delay: d, idleWindow: 0.5)
            print("cancel portfolio after \(d) s: latency \(ms(s.latency)) ms status \(s.status) idleCPU \(ms(s.idleCPU)) ms")
        }
    }
}

func automaticProbe(_ args: [String]) async {
    func lpWith(rows m: Int, denseCount: Int, integer: Bool = false) -> CompiledLP {
        // m rows, m columns identity plus one column with `denseCount` entries.
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<m { entries.append((i, i, 1)) }
        for i in 0..<denseCount { entries.append((i, m, 1)) }
        let n = m + 1
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: [Double](repeating: 1, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 10, count: n),
            rl: [Double](repeating: 1, count: m), ru: [Double](repeating: 5, count: m),
            integerColumns: integer ? [0] : [])
    }
    let cases: [(String, CompiledLP, String)] = [
        ("m=4000", lpWith(rows: 4000, denseCount: 0), "dualSimplex"),
        ("m=4001", lpWith(rows: 4001, denseCount: 0), "interiorPoint"),
        ("m=10000 dense 50%", lpWith(rows: 10000, denseCount: 5000), "interiorPoint"),
        ("m=10001 dense 30% exactly (3000.3 limit, 3001 entries)", lpWith(rows: 10001, denseCount: 3001), "sparseSimplex"),
        ("m=10001 3000 entries (not >30%)", lpWith(rows: 10001, denseCount: 3000), "interiorPoint"),
        ("m=10001 no dense", lpWith(rows: 10001, denseCount: 0), "interiorPoint"),
        ("m=5000 integer", lpWith(rows: 5000, denseCount: 0, integer: true), "branchAndBound"),
        ("m=3 integer", lpWith(rows: 3, denseCount: 0, integer: true), "branchAndBound"),
    ]
    for (label, lp, expected) in cases {
        let choice = Automatic.choice(for: lp)
        print("\(label): choice \(choice) expected \(expected) \("\(choice)" == expected ? "OK" : "MISMATCH")")
    }
    if args.count > 2 && args[2] == "limit10000" {
        let lp = lpWith(rows: 10000, denseCount: 5000)
        for limit in [0.5, 1.0] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            let (r, t) = await timed { try? await Automatic().solve(lp, context: ctx) }
            print("Automatic m=10000 dense column, timeLimit \(limit): engine \(r?.engine ?? "-") status \(String(describing: r?.status)) elapsed \(String(format: "%.3f", t)) s")
        }
        let c = config("Automatic", Automatic(), lp)
        for d in [0.3, 0.8] {
            let s = await cancelSample(c, delay: d, idleWindow: 0.3)
            print("cancel after \(d) s: latency \(ms(s.latency)) ms status \(s.status)")
        }
        return
    }
    // Dispatch: the engine name of the analysis matches the choice.
    for (label, lp, _) in cases where lp.m <= 10001 {
        var ctx = SolveContext(); ctx.timeLimit = 20
        let (r, t) = await timed { try? await Automatic().solve(lp, context: ctx) }
        print("solve \(label): engine \(r?.engine ?? "threw") status \(String(describing: r?.status)) obj \(String(describing: r?.objectiveValue)) \(String(format: "%.2f", t)) s")
    }
}

/// CPU seconds / wall seconds of one solve.
func parallelism(_ body: () async -> Void) async -> (cpu: Double, wall: Double) {
    let c0 = cpuSeconds(); let w0 = uptime()
    await body()
    return (cpuSeconds() - c0, uptime() - w0)
}

func threadsProbe(_ args: [String]) async {
    if args.count > 2 && args[2] == "lp" {
        let lp = InstanceGenerator.transport(sources: 200, sinks: 2000, seed: 11)
        let lp1500 = InstanceGenerator.transport(sources: 150, sinks: 1350, seed: 9)
        for threads in [1, 8] {
            var ctx = SolveContext(); ctx.threads = threads; ctx.timeLimit = 4
            let i = await parallelism { _ = try? await InteriorPoint().solve(lp, context: ctx) }
            let d = await parallelism { _ = try? await Simplex(.dual).solve(lp, context: ctx) }
            let q = await parallelism { _ = try? await Simplex(.primal).solve(lp1500, context: ctx) }
            print(String(format: "threads %d: IPM cpu/wall %.2f (wall %.2f s); Simplex(.dual) sparseQR m=2200 %.2f (wall %.2f s); Simplex(.primal) denseLU m=1500 %.2f (wall %.2f s)", threads, i.cpu / i.wall, i.wall, d.cpu / d.wall, d.wall, q.cpu / q.wall, q.wall))
        }
        return
    }
    let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
    let lp = InstanceGenerator.transport(sources: 200, sinks: 2000, seed: 11)
    for threads in [1, 2, 4] {
        var ctx = SolveContext(); ctx.timeLimit = 2; ctx.threads = threads
        let b = await parallelism { _ = try? await BranchAndBound().solve(hard, context: ctx) }
        let s = await parallelism { _ = try? await CPSAT().solve(hard, context: ctx) }
        let p = await parallelism { _ = try? await Portfolio([BranchAndBound(), CPSAT(), BranchAndBound(engine: Simplex(.dual))]).solve(hard, context: ctx) }
        var ctx2 = SolveContext(); ctx2.threads = threads
        let i = await parallelism { _ = try? await InteriorPoint().solve(lp, context: ctx2) }
        print(String(format: "threads %d: BnB cpu/wall %.2f; CPSAT %.2f; Portfolio(3) %.2f; IPM %.2f", threads, b.cpu / b.wall, s.cpu / s.wall, p.cpu / p.wall, i.cpu / i.wall))
    }
}

func memoryProbe(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "lp"
    func maxRSS() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576
    }
    switch which {
    case "lp":
        // Defect 3: Simplex and InteriorPoint never return .memoryBudget.
        let lp = try! NetlibFixtures.load("degen2")
        var ctx = SolveContext(); ctx.memoryBudgetBytes = 1
        let s = try! await Simplex(.dual).solve(lp, context: ctx)
        let i = try! await InteriorPoint().solve(lp, context: ctx)
        let a = try! await Automatic().solve(lp, context: ctx)
        let c = try! await Conditioned(Simplex(.dual)).solve(lp, context: ctx)
        print("budget 1 byte: Simplex \(s.status); IPM \(i.status); Automatic \(a.status); Conditioned \(c.status) report findings \(c.report.findings.count) estimate \(String(describing: c.report.basisConditionEstimate))")
    case "bnb-budget", "bnb-free":
        // Peak RSS of a best-bound search with a 16 MB budget vs. none (run each in its own process).
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        var ctx = SolveContext(); ctx.timeLimit = Double(args.count > 3 ? args[3] : "20") ?? 20
        if which == "bnb-budget" { ctx.memoryBudgetBytes = 16 << 20 }
        let before = maxRSS()
        let r = try! await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(hard, context: ctx)
        print("\(which): status \(r.status) nodes \(r.nodesProcessed) open \(r.nodesOpen) maxRSS before \(String(format: "%.1f", before)) MB after \(String(format: "%.1f", maxRSS())) MB")
    case "bnb-trace":
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        var ctx = SolveContext(); ctx.timeLimit = Double(args.count > 3 ? args[3] : "6") ?? 6
        ctx.memoryBudgetBytes = Int(args.count > 4 ? args[4] : "16777216") ?? (16 << 20)
        let t0 = uptime()
        let flag = EndFlag()
        ctx.progress = { e in
            switch e {
            case .nodes(let p, let o):
                if (flag.get() ?? -1) < Int((uptime() - t0) * 2) { flag.set(Int((uptime() - t0) * 2)); print(String(format: "  %.2f s nodes processed %d open %d", uptime() - t0, p, o)) }
            case .warning(let w): print(String(format: "  %.2f s warning: ", uptime() - t0) + w)
            case .newIncumbent(let obj, _, let src): print(String(format: "  %.2f s incumbent %.1f ", uptime() - t0, obj) + src)
            default: break
            }
        }
        let r = try! await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(hard, context: ctx)
        print("trace: status \(r.status) nodes \(r.nodesProcessed) open \(r.nodesOpen) gap \(String(describing: r.gap)) lpIterations \(r.lpIterations) maxRSS \(String(format: "%.1f", maxRSS())) MB")
    case "l7":
        // The L7 test's configuration: does the 16 MB budget ever bind?
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        for budget in [16 << 20, Int.max / 2] {
            var ctx = SolveContext(); ctx.memoryBudgetBytes = budget; ctx.timeLimit = 60
            let maxOpen = EndFlag()
            ctx.progress = { e in if case .nodes(_, let o) = e, o > (maxOpen.get() ?? 0) { maxOpen.set(o) } }
            let r = try! await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(mip, context: ctx)
            print("budget \(budget): \(r.status) obj \(String(describing: r.objectiveValue)) nodes \(r.nodesProcessed) max open seen \(maxOpen.get() ?? 0) (x ~1.4 KB/node = \(String(format: "%.1f", Double(maxOpen.get() ?? 0) * 1.4 / 1024)) MB)")
        }
    case "cpsat-budget":
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        for budget in [0, 4096, 1 << 20] {
            var ctx = SolveContext(); ctx.timeLimit = 2; ctx.memoryBudgetBytes = budget
            let r = try! await CPSAT().solve(hard, context: ctx)
            print("CPSAT budget \(budget): \(r.status) obj \(String(describing: r.objectiveValue)) learned \(r.learnedClauses)")
        }
    case "portfolio-budget":
        let hard = InstanceGenerator.randomMILP(rows: 30, columns: 200, seed: 99, upper: 1)
        var ctx = SolveContext(); ctx.timeLimit = 2; ctx.memoryBudgetBytes = 4096
        let r = try! await Portfolio([BranchAndBound(heuristics: .none), BranchAndBound(engine: Simplex(.dual), heuristics: .none)]).solve(hard, context: ctx)
        print("Portfolio budget 4096: \(r.status) winner \(r.winner) others \(r.others.map { "\($0.strategy): \($0.status)" })")
    default:
        print("unknown")
    }
}
