// Cycle A, slot F4: gap, limits, determinism, MIPLIB and special-case probes.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Near-tie knapsack: profits p_j = w_j (1 + δ_j) with tiny δ, so many solutions lie within the
/// default gap of each other. Non-integral profits: objectiveStep is 0 and pruning uses the gap.
func nearTieKnapsack(seed: UInt64, n: Int = 14, delta: Double = 2e-5) -> CompiledLP {
    var rng = SeededGenerator(seed: seed &+ 99)
    let w = (0..<n).map { _ in Double(rng.integer(in: 20...90)) }
    let w2 = (0..<n).map { _ in Double(rng.integer(in: 1...40)) }
    let p = w.map { $0 * (1 + rng.uniform(in: 0...delta)) * 10 }
    let cap = (w.reduce(0, +) * 0.5).rounded(.down) + 0.5
    let cap2 = (w2.reduce(0, +) * 0.6).rounded(.down)
    return makeLP(
        c: p, rows: [w, w2], rl: [-INF, -INF], ru: [cap, cap2], xl: [Double](repeating: 0, count: n),
        xu: [Double](repeating: 1, count: n), integer: Array(0..<n), sense: .maximize)
}

func gapMode() async throws {
    let count = args.count > 2 ? Int(args[2])! : 30
    var defaultSub = 0, defaultOutside = 0, tightWrong = 0, badBoundDefault = 0, badBoundTight = 0, n = 0
    var lines: [String] = []
    for seed in 0..<UInt64(count) {
        let lp = nearTieKnapsack(seed: seed)
        guard let ans = enumerateMILP(lp) else { continue }
        n += 1
        let opt = -ans.internalValue // maximise
        let configs: [(String, Config)] = [
            ("default", cfg("P", BranchAndBound())),
            ("default-D-det", cfg("D-det", BranchAndBound(engine: Simplex(.dual), deterministic: true))),
            ("tight", cfg("P-tight", BranchAndBound(gap: Gap(relative: 0, absolute: 0)))),
            ("tight-D-det", cfg("D-det-tight", BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 1e-12, absolute: 1e-12), deterministic: true))),
            ("tight-I", cfg("I-tight", BranchAndBound(engine: InteriorPoint(), gap: Gap(relative: 0, absolute: 1e-9)))),
        ]
        for (kind, c) in configs {
            let r = try await c.solve(lp, c.threads, 60, false)
            guard r.status == .optimal, let obj = r.objective else {
                lines.append("seed \(seed) \(kind): status \(r.status)")
                continue
            }
            let s = slack(obj)
            let b = r.bound ?? .nan
            let boundBad = b < opt - 1e-9 * max(1, abs(opt)) // maximise: a valid bound is >= opt
            if kind.hasPrefix("default") {
                if obj < opt - s - 1e-9 { defaultOutside += 1; lines.append("seed \(seed) \(kind): OUTSIDE gap obj \(obj) opt \(opt) slack \(s)") }
                else if obj < opt - 1e-9 * opt { defaultSub += 1; lines.append("seed \(seed) \(kind): suboptimal within gap obj \(fmt(obj)) opt \(fmt(opt)) diff \(opt - obj) slack \(s) bound \(fmt(b)) nodes \(r.nodes)") }
                if boundBad { badBoundDefault += 1; lines.append("seed \(seed) \(kind): BAD BOUND \(fmt(b)) < opt \(fmt(opt)) obj \(fmt(obj))") }
            } else {
                if abs(obj - opt) > 1e-9 * max(1, abs(opt)) { tightWrong += 1; lines.append("seed \(seed) \(kind): TIGHT WRONG obj \(fmt(obj)) opt \(fmt(opt)) diff \(opt - obj) bound \(fmt(b)) nodes \(r.nodes)") }
                if boundBad { badBoundTight += 1; lines.append("seed \(seed) \(kind): BAD BOUND \(fmt(b)) < opt \(fmt(opt))") }
            }
        }
    }
    for l in lines.prefix(80) { print(l) }
    print("SUMMARY gap instances=\(n) defaultSuboptWithinGap=\(defaultSub) defaultOutsideGap=\(defaultOutside) tightWrong=\(tightWrong) badBoundDefault=\(badBoundDefault) badBoundTight=\(badBoundTight)")
}

/// Limits: nodeLimit, timeLimit, memory budget, cancellation.
func limitsMode() async throws {
    var lines: [String] = []
    var bad = 0
    // nodeLimit on enumeration-size instances that need a tree.
    for seed in 0..<UInt64(12) {
        let lp = InstanceGenerator.randomMILP(rows: 5, columns: 15, seed: 3000 + seed, upper: 1)
        let ans = enumerateMILP(lp)!
        let opt = ans.internalValue
        for L in [1, 2, 3, 5, 10, 40] {
            for (name, threads, s) in [
                ("P", 8, cfg("P", BranchAndBound(nodeLimit: L))),
                ("D-det", 1, cfg("D", BranchAndBound(engine: Simplex(.dual), nodeLimit: L, deterministic: true))),
                ("P-noheur", 4, cfg("Pn", BranchAndBound(heuristics: .none, nodeLimit: L))),
            ] {
                let r = try await s.solve(lp, threads, 30, false)
                var issue: [String] = []
                switch r.status {
                case .feasible(.nodeLimit):
                    let x = r.primal!
                    let v = lp.maxViolation(at: x)
                    if v.rows > 1e-6 || v.bounds > 1e-6 { issue.append("infeasible incumbent") }
                    let inc = -r.objective!
                    if inc < opt - 1e-6 { issue.append("incumbent better than optimum") }
                    if let b = r.bound, -b > opt + 1e-7 * (1 + abs(opt)) { issue.append("bound \(-b) above optimum \(opt)") }
                    if r.bound == nil { issue.append("no bound") }
                case .noSolution(.nodeLimit): break
                case .optimal:
                    let inc = -r.objective!
                    if inc > opt + slack(inc) { issue.append("false optimal \(inc) vs \(opt)") }
                default: issue.append("unexpected status \(r.status)")
                }
                if r.nodes > L + threads { issue.append("nodes \(r.nodes) > limit \(L) + \(threads)") }
                if !issue.isEmpty {
                    bad += 1
                    lines.append("nodeLimit seed \(seed) L \(L) \(name): \(r.status) nodes \(r.nodes): \(issue.joined(separator: "; "))")
                }
            }
        }
    }
    print("nodeLimit checks done, bad=\(bad)")
    // timeLimit on a hard instance.
    let hard = InstanceGenerator.randomMILP(rows: 30, columns: 120, seed: 77, upper: 1)
    for T in [0.0, 0.001, 0.01, 0.1, 0.5] {
        for (name, threads, s) in [
            ("P", 8, cfg("P", BranchAndBound())), ("D-det", 1, cfg("D", BranchAndBound(engine: Simplex(.dual), deterministic: true))),
            ("I", 4, cfg("I", BranchAndBound(engine: InteriorPoint()))),
        ] {
            let r = try await s.solve(hard, threads, T, false)
            var issue: [String] = []
            switch r.status {
            case .feasible(.timeLimit):
                let v = hard.maxViolation(at: r.primal!)
                if v.rows > 1e-6 || v.bounds > 1e-6 { issue.append("infeasible incumbent") }
                if let b = r.bound, b < r.objective! - 1e-9 { issue.append("bound below incumbent for max") }
            case .noSolution(.timeLimit): break
            case .optimal: break
            default: issue.append("unexpected status \(r.status)")
            }
            lines.append("timeLimit T \(T) \(name): \(r.status) wall \(String(format: "%.3f", r.wall)) nodes \(r.nodes) obj \(fmt(r.objective)) bound \(fmt(r.bound)) \(issue.joined(separator: "; "))")
            if r.wall > T + 1.0 { lines.append("  SLOW STOP: wall \(r.wall) for limit \(T)") }
            if !issue.isEmpty { bad += 1 }
        }
    }
    // Memory budget.
    let mlp = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)
    let ref = try await run(BranchAndBound(engine: Simplex(.dual)), mlp, threads: 8, timeLimit: 120)
    lines.append("memory reference: \(ref.status) obj \(fmt(ref.objective)) nodes \(ref.nodes)")
    for budget in [1, 500, 2_000, 20_000, 200_000] {
        for (name, s) in [
            ("test-config", cfg("T", BranchAndBound(nodeSelection: .bestBound, heuristics: .none))),
            ("default", cfg("P", BranchAndBound())),
            ("det", cfg("Ddet", BranchAndBound(engine: Simplex(.dual), deterministic: true))),
        ] {
            var ctx = SolveContext()
            ctx.timeLimit = 60
            ctx.memoryBudgetBytes = budget
            ctx.metal = .off
            let r: Run
            switch name {
            case "test-config": r = try await run(BranchAndBound(nodeSelection: .bestBound, heuristics: .none), mlp, timeLimit: 60, memory: budget)
            case "default": r = try await run(BranchAndBound(), mlp, timeLimit: 60, memory: budget)
            default: r = try await run(BranchAndBound(engine: Simplex(.dual), deterministic: true), mlp, timeLimit: 60, memory: budget)
            }
            _ = s
            var issue = ""
            if r.status == .optimal, let o = r.objective, let ro = ref.objective, abs(o - ro) > slack(ro) { issue = "WRONG optimal" }
            if case .feasible = r.status, let o = r.objective, let ro = ref.objective, o > ro + 1e-6 { issue = "incumbent better than optimum" }
            lines.append("memory budget \(budget) \(name): \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes) open \(r.open) \(issue)")
        }
    }
    // Cancellation.
    for delayMs in [0, 5, 50] {
        let strategy = BranchAndBound()
        let t0 = Date()
        let task = Task { () -> Run in try await run(strategy, hard, threads: 8, timeLimit: 60) }
        if delayMs > 0 { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
        let tc = Date()
        task.cancel()
        let r = try await task.value
        lines.append("cancel after \(delayMs) ms: \(r.status) latency \(String(format: "%.4f", Date().timeIntervalSince(tc))) total \(String(format: "%.3f", Date().timeIntervalSince(t0)))")
    }
    for l in lines { print(l) }
    print("SUMMARY limits bad=\(bad)")
}

func stripSeconds(_ events: [SolverEvent]) -> [SolverEvent] {
    events.map { e in
        if case .finished(let s, _) = e { return .finished(status: s, seconds: 0) }
        return e
    }
}

func detMode() async throws {
    let instances: [(String, CompiledLP)] = [
        ("randomMILP(10,40,s9)", InstanceGenerator.randomMILP(rows: 10, columns: 40, seed: 9, upper: 1)),
        ("mixed(8,30,s5)", InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 5, integerFraction: 0.5, upper: 3, integralData: false)),
        ("randomMILP(14,50,s21)", InstanceGenerator.randomMILP(rows: 14, columns: 50, seed: 21, upper: 2)),
    ]
    for (name, lp) in instances {
        for (ename, solveOne) in [
            ("P", { (th: Int) async throws -> Run in try await run(BranchAndBound(deterministic: true, seed: 7), lp, threads: th, timeLimit: 120, captureEvents: true) }),
            ("D", { (th: Int) async throws -> Run in try await run(BranchAndBound(engine: Simplex(.dual), deterministic: true, seed: 7), lp, threads: th, timeLimit: 120, captureEvents: true) }),
            ("I", { (th: Int) async throws -> Run in try await run(BranchAndBound(engine: InteriorPoint(), deterministic: true, seed: 7), lp, threads: th, timeLimit: 120, captureEvents: true) }),
        ] {
            var first: Run? = nil
            var diffs: [String] = []
            for k in 0..<8 {
                let th = [4, 4, 4, 4, 1, 8, 2, 8][k]
                let r = try await solveOne(th)
                if let f = first {
                    var d: [String] = []
                    if r.objective != f.objective { d.append("objective \(fmt(r.objective)) vs \(fmt(f.objective))") }
                    if r.nodes != f.nodes { d.append("nodes \(r.nodes) vs \(f.nodes)") }
                    if r.iterations != f.iterations { d.append("iterations \(r.iterations) vs \(f.iterations)") }
                    if r.primal != f.primal { d.append("primal differs") }
                    if r.bound != f.bound { d.append("bound \(fmt(r.bound)) vs \(fmt(f.bound))") }
                    if stripSeconds(r.events) != stripSeconds(f.events) { d.append("events differ (\(r.events.count) vs \(f.events.count))") }
                    if r.history.map(\.objective) != f.history.map(\.objective) { d.append("incumbent history differs") }
                    if !d.isEmpty { diffs.append("run \(k) threads \(th): " + d.joined(separator: ", ")) }
                } else {
                    first = r
                    print("\(name) \(ename) det first: \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes) iters \(r.iterations) events \(r.events.count)")
                }
            }
            print("\(name) \(ename) det: \(diffs.isEmpty ? "IDENTICAL over 8 runs (threads 4,4,4,4,1,8,2,8)" : diffs.joined(separator: " | "))")
        }
        // Parallel: objectives agree within the gap.
        var objs: [Double] = []
        for th in [2, 4, 8, 8, 8] {
            let r = try await run(BranchAndBound(), lp, threads: th, timeLimit: 120)
            if let o = r.objective { objs.append(o) }
        }
        let spread = (objs.max() ?? 0) - (objs.min() ?? 0)
        print("\(name) parallel objectives \(objs.map { fmt($0) }) spread \(spread) slack \(slack(objs.first ?? 0))")
    }
}

func miplibMode() async throws {
    let names = args.count > 2 && args[2] != "all" ? args[2].split(separator: ",").map(String.init) : ReferenceValues.miplib3.map(\.name)
    let engines = args.count > 3 ? args[3].split(separator: ",").map(String.init) : ["P", "D"]
    let limit = args.count > 4 ? Double(args[4])! : 300
    for name in names {
        guard let ref = ReferenceValues.miplib3(named: name), let lp = try Corpora.loadMIPLIB3(name) else {
            print("\(name): MISSING")
            continue
        }
        for e in engines {
            let r: Run
            switch e {
            case "P": r = try await run(BranchAndBound(), lp, timeLimit: limit, captureEvents: true)
            case "D": r = try await run(BranchAndBound(engine: Simplex(.dual)), lp, timeLimit: limit, captureEvents: true)
            case "I": r = try await run(BranchAndBound(engine: InteriorPoint()), lp, timeLimit: limit, captureEvents: true)
            case "Pdet": r = try await run(BranchAndBound(deterministic: true), lp, timeLimit: limit, captureEvents: true)
            case "Ddet": r = try await run(BranchAndBound(engine: Simplex(.dual), deterministic: true), lp, timeLimit: limit, captureEvents: true)
            default: fatalError("engine \(e)")
            }
            var notes: [String] = []
            if let o = r.objective {
                let err = abs(o - ref.optimalObjective) / max(1, abs(ref.optimalObjective))
                notes.append("relerr \(String(format: "%.2e", err))")
                if let x = r.primal {
                    let v = lp.maxViolation(at: x)
                    notes.append("viol rows \(String(format: "%.1e", v.rows)) bounds \(String(format: "%.1e", v.bounds))")
                    let cx = lp.objective(at: x)
                    if abs(cx - o) > 1e-6 * max(1, abs(o)) { notes.append("OBJ != c.x (\(cx))") }
                    for j in lp.integerColumns where abs(x[Int(j)] - x[Int(j)].rounded()) > 1e-9 { notes.append("nonint"); break }
                }
            }
            if let b = r.bound {
                // All MIPLIB 3 instances here are minimisation.
                if b > ref.optimalObjective + 1e-6 * max(1, abs(ref.optimalObjective)) { notes.append("BOUND \(b) > optimum") }
            }
            // Bound events monotone and valid.
            let bounds = r.events.compactMap { ev -> Double? in if case .boundImproved(let b, _) = ev { return b }; return nil }
            if bounds != bounds.sorted() { notes.append("boundImproved not monotone") }
            if let mb = bounds.max(), mb > ref.optimalObjective + 1e-6 * max(1, abs(ref.optimalObjective)) { notes.append("boundImproved \(mb) > optimum") }
            let incs = r.events.compactMap { ev -> Double? in if case .newIncumbent(let o, _, _) = ev { return o }; return nil }
            if incs != incs.sorted(by: >) { notes.append("incumbents not decreasing") }
            print("\(name) \(e): \(r.status) obj \(fmt(r.objective)) ref \(ref.optimalObjective) bound \(fmt(r.bound)) nodes \(r.nodes) iters \(r.iterations) wall \(String(format: "%.2f", r.wall)) \(notes.joined(separator: ", "))")
        }
    }
}
