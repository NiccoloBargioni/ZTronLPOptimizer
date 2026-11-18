// Cycle A, slot F4 (branch and bound) probes. Usage: F4 <mode> [args]
//   enum <family|all> <count> [firstSeed]   random MILPs vs exhaustive enumeration, 11 configurations
//   bigm                                    integrality-tolerance rounding of LP-integral points
//   special                                 hand-built infeasible / unbounded / edge cases
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "enum"

func enumMode() async throws {
    let fam = args.count > 2 ? args[2] : "all"
    let count = args.count > 3 ? Int(args[3])! : 20
    let first = args.count > 4 ? UInt64(args[4])! : 0
    let families = fam == "all" ? Family.allCases : [Family(rawValue: fam)!]
    let configs = standardConfigs()
    var total = 0, fails = 0, subopt = 0, badBound = 0, infeasibleInst = 0, weak = 0
    var failLines: [String] = []
    for family in families {
        for seed in first..<(first + UInt64(count)) {
            let lp = generate(family, seed: seed)
            let ans = enumerateMILP(lp)
            if ans == nil { infeasibleInst += 1 }
            for c in configs {
                total += 1
                let r: Run
                do { r = try await c.solve(lp, c.threads, 30, false) } catch {
                    fails += 1
                    failLines.append("THROW \(family) seed \(seed) \(c.name): \(error)")
                    continue
                }
                let v = check(r, lp, ans)
                if !v.ok {
                    fails += 1
                    failLines.append("FAIL \(family) seed \(seed) \(c.name): \(v.note) [nodes \(r.nodes) bound \(fmt(r.bound))]")
                }
                if v.note.hasPrefix("weak") { weak += 1 }
                if v.subopt { subopt += 1 }
                if v.badBound {
                    badBound += 1
                    failLines.append("BADBOUND \(family) seed \(seed) \(c.name): \(v.note) status \(r.status)")
                }
            }
        }
    }
    for l in failLines.prefix(60) { print(l) }
    print("SUMMARY enum fam=\(fam) instances=\(count * families.count) runs=\(total) fails=\(fails) badBound=\(badBound) suboptWithinGap=\(subopt) infeasibleInstances=\(infeasibleInst) weakStatus=\(weak)")
}

func bigM() async throws {
    // Fixed charge: min 100 y + x  s.t.  x >= 0.5 (two-column row, so presolve keeps it),
    // x - 1e6 y <= 0, y binary, x in [0, 10]. The LP puts y = 5e-7, within the integrality
    // tolerance of 0. True MILP optimum: y = 1, x = 0.5, objective 100.5.
    let lp = makeLP(
        c: [100, 1, 0], rows: [[0, 1, 1], [-1e6, 1, 0]], rl: [0.5, -INF], ru: [INF, 0],
        xl: [0, 0, 0], xu: [1, 10, 0], integer: [0], sense: .minimize)
    let ans = enumerateMILP(lp)!
    print("oracle optimum \(ans.internalValue) at \(ans.point)")
    for c in standardConfigs() {
        let r = try await c.solve(lp, c.threads, 30, false)
        let viol = r.primal.map { lp.maxViolation(at: $0) }
        print("\(c.name): status \(r.status) obj \(fmt(r.objective)) bound \(fmt(r.bound)) x \(r.primal ?? []) viol \(String(describing: viol)) c.x \(r.primal.map { lp.objective(at: $0) } ?? .nan) src \(r.history.map(\.source))")
    }
    // Second shape: 1e7 x1 + 1e7 x2 >= 5, min x1 + x2, x integer in [0,10].
    let lp2 = makeLP(c: [1, 1], rows: [[1e7, 1e7]], rl: [5], ru: [INF], xl: [0, 0], xu: [10, 10], integer: [0, 1], sense: .minimize)
    let ans2 = enumerateMILP(lp2)!
    print("oracle2 optimum \(ans2.internalValue) at \(ans2.point)")
    for c in standardConfigs().prefix(3) {
        let r = try await c.solve(lp2, c.threads, 30, false)
        print("\(c.name): status \(r.status) obj \(fmt(r.objective)) x \(r.primal ?? []) viol \(String(describing: r.primal.map { lp2.maxViolation(at: $0) }))")
    }
}


func specialMode() async throws {
    struct Case { let name: String; let lp: CompiledLP; let expect: String }
    var cases: [Case] = []
    cases.append(Case(name: "milp-unbounded", lp: makeLP(c: [-1, -1], rows: [[1, -1]], rl: [-INF], ru: [1], xl: [0, 0], xu: [INF, INF], integer: [0, 1], sense: .minimize), expect: "unbounded|infeasibleOrUnbounded"))
    cases.append(Case(name: "lp-unbounded-milp-infeasible", lp: makeLP(c: [-1, 0], rows: [[2, -2]], rl: [1], ru: [1], xl: [0, 0], xu: [INF, INF], integer: [0, 1], sense: .minimize), expect: "infeasible|infeasibleOrUnbounded"))
    cases.append(Case(name: "mixed-unbounded-continuous", lp: makeLP(c: [0, 1], rows: [[-2, 1]], rl: [0], ru: [INF], xl: [0, 0], xu: [3, INF], integer: [0], sense: .maximize), expect: "unbounded|infeasibleOrUnbounded"))
    cases.append(Case(name: "free-integer-bounded-objective (opt -2)", lp: makeLP(c: [1, 0], rows: [[1, 1]], rl: [-2.5], ru: [INF], xl: [-INF, 0], xu: [INF, 0.1], integer: [0], sense: .minimize), expect: "optimal -2"))
    cases.append(Case(name: "no-rows (opt -3+... )", lp: makeLP(c: [1, -2, 3], rows: [], rl: [], ru: [], xl: [-1.5, 0, 2], xu: [4, 3.7, 5], integer: [0, 1, 2], sense: .minimize), expect: "optimal -1-6+6=-1"))
    cases.append(Case(name: "all-fixed (opt 2*3-1*2+c0 5 = 9)", lp: makeLP(c: [2, -1], c0: 5, rows: [[1, 1]], rl: [-INF], ru: [10], xl: [3, 2], xu: [3, 2], integer: [0, 1], sense: .maximize), expect: "optimal 9"))
    cases.append(Case(name: "maximize-with-constant (opt 3+3+10 =16)", lp: makeLP(c: [1, 1], c0: 10, rows: [[1, 1]], rl: [-INF], ru: [6.5], xl: [0, 0], xu: [3, 3.5], integer: [0, 1], sense: .maximize), expect: "optimal 16"))
    cases.append(Case(name: "parity-infeasible", lp: makeLP(c: [1, 1, 1, 1], rows: [[2, 2, 2, 2]], rl: [7], ru: [7], xl: [0, 0, 0, 0], xu: [10, 10, 10, 10], integer: [0, 1, 2, 3], sense: .minimize), expect: "infeasible"))
    cases.append(Case(name: "half-bounds-only-zero (opt 0)", lp: makeLP(c: [-1, 1], rows: [[1, 1]], rl: [-INF], ru: [5], xl: [-0.5, 0], xu: [0.5, 2], integer: [0], sense: .minimize), expect: "optimal 0"))
    cases.append(Case(name: "huge-integer-bounds (opt 333333334)", lp: makeLP(c: [1, 0], rows: [[3, 1]], rl: [1e9 + 1], ru: [INF], xl: [-1e9, 0], xu: [1e9, 0], integer: [0], sense: .minimize), expect: "optimal 333333334"))
    cases.append(Case(name: "infeasible-lp", lp: makeLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-INF, 3], ru: [1, INF], xl: [0, 0], xu: [5, 5], integer: [0, 1], sense: .minimize), expect: "infeasible"))
    cases.append(Case(name: "integer-empty-range", lp: makeLP(c: [1, 1], rows: [[1, 1]], rl: [1], ru: [INF], xl: [0.2, 0], xu: [0.8, 5], integer: [0], sense: .minimize), expect: "infeasible"))
    for k in cases {
        var line = "\(k.name) [expect \(k.expect)]:"
        for c in standardConfigs() {
            do {
                let r = try await c.solve(k.lp, c.threads, 20, false)
                var extra = ""
                if let x = r.primal { let v = k.lp.maxViolation(at: x); if v.rows > 1e-6 || v.bounds > 1e-6 { extra = " VIOL\(v)" } }
                line += " \(c.name)=\(r.status)/\(fmt(r.objective))\(extra)"
            } catch { line += " \(c.name)=THROW(\(error))" }
        }
        print(line)
    }
}

func gapLooseMode() async throws {
    // Loose user gaps: does the reported bound/gap still say how far the incumbent may be from the optimum?
    for seed in [UInt64(15), 18, 20, 26] {
        let lp = nearTieKnapsack(seed: seed)
        let opt = -enumerateMILP(lp)!.internalValue
        for rel in [1e-4, 1e-3, 1e-2, 5e-2] {
            for (name, s) in [("P", cfg("P", BranchAndBound(gap: Gap(relative: rel, absolute: 1e-6)))),
                              ("D-det", cfg("D", BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: rel, absolute: 1e-6), deterministic: true)))] {
                let r = try await s.solve(lp, nil, 60, false)
                let a = try await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: rel, absolute: 1e-6), deterministic: true).solve(lp)
                _ = a
                print("seed \(seed) rel \(rel) \(name): \(r.status) obj \(fmt(r.objective)) bound \(fmt(r.bound)) gap \(fmt(r.gap)) opt \(fmt(opt)) trueRelGap \(String(format: "%.3e", (opt - (r.objective ?? .nan)) / opt)) boundValid \((r.bound ?? -INF) >= opt - 1e-9 * opt) nodes \(r.nodes)")
            }
        }
    }
    // Same shape with a near-tie knapsack whose profits are integral (objectiveStep > 0).
    for seed in [UInt64(15), 18] {
        var rng = SeededGenerator(seed: seed &+ 99)
        let n = 14
        let w = (0..<n).map { _ in Double(rng.integer(in: 20...90)) }
        let w2 = (0..<n).map { _ in Double(rng.integer(in: 1...40)) }
        let p = w.map { $0 * 100 + Double(rng.integer(in: 0...1)) }
        let lp = makeLP(c: p, rows: [w, w2], rl: [-INF, -INF], ru: [(w.reduce(0, +) * 0.5).rounded(.down) + 0.5, (w2.reduce(0, +) * 0.6).rounded(.down)], xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), integer: Array(0..<n), sense: .maximize)
        let opt = -enumerateMILP(lp)!.internalValue
        for rel in [1e-4, 1e-2] {
            let r = try await run(BranchAndBound(gap: Gap(relative: rel, absolute: 1e-6)), lp, timeLimit: 60)
            print("integral seed \(seed) rel \(rel): \(r.status) obj \(fmt(r.objective)) bound \(fmt(r.bound)) gap \(fmt(r.gap)) opt \(fmt(opt)) boundValid \((r.bound ?? -INF) >= opt - 1e-9 * opt)")
        }
    }
}

func rootStopMode() async throws {
    // A stop (time limit / cancellation) that lands while the root is being expanded.
    let lp = InstanceGenerator.randomMILP(rows: 30, columns: 120, seed: 77, upper: 1)
    let long = try await run(BranchAndBound(engine: Simplex(.dual)), lp, threads: 8, timeLimit: 120)
    print("reference (120 s, dual): \(long.status) obj \(fmt(long.objective)) bound \(fmt(long.bound)) nodes \(long.nodes)")
    for T in [0.0005, 0.001, 0.002, 0.003, 0.005] {
        for (name, threads) in [("P", 8), ("P-t1", 1)] {
            var ctx = SolveContext(); ctx.timeLimit = T; ctx.threads = threads; ctx.metal = .off
            let a = try await BranchAndBound().solve(lp, context: ctx)
            let valid = (a.bound ?? .infinity) >= (long.bound ?? long.objective ?? 0) - 1e-6
            print("T \(T) \(name): \(a.status) obj \(fmt(a.objectiveValue)) bound \(fmt(a.bound)) gap \(fmt(a.gap)) nodes \(a.nodesProcessed) open \(a.nodesOpen) rootLP \(fmt(a.root.objectiveValue)) boundValid(>= proven optimum bound) \(valid) incumbents \(a.incumbentHistory.map { "\($0.source)@\($0.node)" })")
        }
    }
    // Cancellation shortly after start.
    for delay in [UInt64(200_000), 500_000, 1_000_000, 2_000_000] {
        let task = Task { () -> BranchAndBoundAnalysis<SimplexAnalysis> in
            var ctx = SolveContext(); ctx.timeLimit = 60; ctx.metal = .off
            return try await BranchAndBound().solve(lp, context: ctx)
        }
        try await Task.sleep(nanoseconds: delay)
        task.cancel()
        let a = try await task.value
        print("cancel after \(Double(delay) / 1e6) ms: \(a.status) obj \(fmt(a.objectiveValue)) bound \(fmt(a.bound)) gap \(fmt(a.gap)) nodes \(a.nodesProcessed) rootLP \(fmt(a.root.objectiveValue))")
    }
}

func miscMode() async throws {
    // 1. objectiveStep treats |c| <= 1e-9 as an integral 0: pruning by a whole step.
    // min x1 + 1e-9 x2, x1 in {0,1}, x2 integer in [0, 1e9], x1 + (1e-9/1.5) x2 >= 0.5.
    // Integer optimum: x1 = 0, x2 = 7.5e8, objective 0.75. x1 = 1, x2 = 0 gives 1.
    let a = 1e-9 / 1.5
    let lp = makeLP(c: [1, 1e-9], rows: [[1, a]], rl: [0.5], ru: [INF], xl: [0, 0], xu: [1, 1e9], integer: [0, 1], sense: .minimize)
    for c in standardConfigs() {
        let r = try await c.solve(lp, c.threads, 30, false)
        print("tinycost \(c.name): \(r.status) obj \(fmt(r.objective)) bound \(fmt(r.bound)) x \(r.primal ?? []) nodes \(r.nodes) src \(r.history.map(\.source))")
    }
    // Check the point x1=0, x2=7.5e8 is feasible for the model as given.
    print("check point (0, 7.5e8): viol \(lp.maxViolation(at: [0, 7.5e8])) obj \(lp.objective(at: [0, 7.5e8]))")
    // 2. Root LP that hits its iteration cap -> .numericalFailure (README 2.5).
    let hard = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)
    for cap in [1, 3, 10] {
        let r = try await run(BranchAndBound(engine: Simplex(.primal, maxIterations: cap)), hard, timeLimit: 30)
        print("maxIterations \(cap): \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes) warnings \(r.warnings.prefix(2))")
    }
    // 3. deterministic: true searches depth-first whatever nodeSelection says.
    let lp3 = InstanceGenerator.randomMILP(rows: 10, columns: 40, seed: 9, upper: 1)
    var sigs: [String] = []
    for sel in [NodeSelection.bestBound, .depthFirst, .bestBoundWithPlunging(maxDepth: 32), .bestBoundWithPlunging(maxDepth: 2)] {
        let r = try await run(BranchAndBound(nodeSelection: sel, deterministic: true), lp3, threads: 4, timeLimit: 60, captureEvents: true)
        sigs.append("\(r.objective!)/\(r.nodes)/\(r.iterations)/\(stripSeconds(r.events).count)/\(r.history.map(\.node))")
    }
    print("det nodeSelection signatures: \(sigs) allEqual \(Set(sigs).count == 1)")
}

func eventsMode() async throws {
    var cases: [(String, CompiledLP)] = []
    for name in ["mod008", "p0201", "misc03", "lseu"] { if let lp = try Corpora.loadMIPLIB3(name) { cases.append((name, lp)) } }
    cases.append(("randomMILP(14,50,s21)", InstanceGenerator.randomMILP(rows: 14, columns: 50, seed: 21, upper: 2)))
    var totals = (runs: 0, boundNonMono: 0, incNonMono: 0, lastIncWrong: 0, countWrong: 0, finishBad: 0)
    for (name, lp) in cases {
        let flip: Double = lp.sense == .maximize ? -1 : 1
        for k in 0..<4 {
            let r = k % 2 == 0 ? try await run(BranchAndBound(), lp, threads: 8, timeLimit: 120, captureEvents: true)
                               : try await run(BranchAndBound(engine: Simplex(.dual)), lp, threads: 8, timeLimit: 120, captureEvents: true)
            totals.runs += 1
            let bounds = r.events.compactMap { e -> Double? in if case .boundImproved(let b, _) = e { return flip * b }; return nil }
            let incs = r.events.compactMap { e -> Double? in if case .newIncumbent(let o, _, _) = e { return flip * o }; return nil }
            var drops = 0
            for i in 1..<max(1, bounds.count) where bounds[i] < bounds[i - 1] { drops += 1 }
            var worse = 0
            for i in 1..<max(1, incs.count) where incs[i] >= incs[i - 1] { worse += 1 }
            let lastOK = incs.last.map { abs($0 - flip * (r.objective ?? .nan)) <= 1e-9 * max(1, abs($0)) } ?? false
            let fin = r.events.filter(\.isFinished).count == 1 && r.events.last?.isFinished == true
            if drops > 0 { totals.boundNonMono += 1 }
            if worse > 0 { totals.incNonMono += 1 }
            if !lastOK { totals.lastIncWrong += 1 }
            if incs.count != r.history.count { totals.countWrong += 1 }
            if !fin { totals.finishBad += 1 }
            if drops > 0 || worse > 0 || !lastOK {
                print("\(name) run \(k): bound events \(bounds.count) drops \(drops); incumbent events \(incs.count) non-improving \(worse); last event \(fmt(incs.last.map { flip * $0 })) final \(fmt(r.objective)); history monotone \(r.history.map(\.objective) == r.history.map(\.objective).sorted(by: lp.sense == .maximize ? (<) : (>)))")
            }
        }
    }
    print("SUMMARY events runs=\(totals.runs) boundNonMonotone=\(totals.boundNonMono) incumbentNonImproving=\(totals.incNonMono) lastIncumbentEventNotFinal=\(totals.lastIncWrong) incumbentEventCount!=history=\(totals.countWrong) finishedNotLastOrDup=\(totals.finishBad)")
}

func relViolMode() async throws {
    // Rows with large bounds: the heuristics accept points violating by up to 1e-7 (1 + |bound|).
    let shapes: [(String, CompiledLP, Double)] = [
        ("3x+y>=1e9+1 (y fixed 0)", makeLP(c: [1, 0], rows: [[3, 1]], rl: [1e9 + 1], ru: [INF], xl: [-1e9, 0], xu: [1e9, 0], integer: [0], sense: .minimize), 333333334),
        ("2x-z>=2e7+1, z in [0,0.5]", makeLP(c: [1, 0], rows: [[2, -1]], rl: [20_000_001], ru: [INF], xl: [0, 0], xu: [1e8, 0.5], integer: [0], sense: .minimize), 10_000_001),
        ("knapsack cents: max sum x s.t. 3x1+3x2 <= 3e7-1 ... ", makeLP(c: [1, 1], rows: [[3, 3]], rl: [-INF], ru: [29_999_999], xl: [0, 0], xu: [1e7, 1e7], integer: [0, 1], sense: .maximize), 9_999_999),
    ]
    for (name, lp, expected) in shapes {
        var line = "\(name) [true optimum \(expected)]:"
        for c in standardConfigs() {
            let r = try await c.solve(lp, c.threads, 30, false)
            let v = r.primal.map { lp.maxViolation(at: $0) }
            line += " \(c.name)=\(r.status)/\(fmt(r.objective))/rowviol \(v.map { fmt($0.rows) } ?? "-")/\(r.history.map(\.source))"
        }
        print(line)
    }
}

func edgeParamsMode() async throws {
    let lp = InstanceGenerator.randomMILP(rows: 6, columns: 18, seed: 31, upper: 2)
    let ref = try await run(BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0)), lp, timeLimit: 60)
    print("reference \(ref.status) \(fmt(ref.objective))")
    let cases: [(String, Config)] = [
        ("nodeLimit 0", cfg("a", BranchAndBound(nodeLimit: 0))),
        ("nodeLimit -1", cfg("b", BranchAndBound(nodeLimit: -1))),
        ("heur weird", cfg("c", BranchAndBound(heuristics: Heuristics(rounding: true, diving: true, divingInterval: 0, divingMaxDepth: -1, divingIterationLimit: 0, roundingBatch: 5000)))),
        ("strong 0", cfg("d", BranchAndBound(branching: .strong(candidates: 0)))),
        ("strong 1000", cfg("d2", BranchAndBound(branching: .strong(candidates: 1000)))),
        ("pseudocost -5", cfg("e", BranchAndBound(branching: .pseudocost(reliability: -5)))),
        ("pseudocost 1000", cfg("e2", BranchAndBound(branching: .pseudocost(reliability: 1000)))),
        ("plunge -1", cfg("f", BranchAndBound(nodeSelection: .bestBoundWithPlunging(maxDepth: -1)))),
        ("gap negative", cfg("g", BranchAndBound(gap: Gap(relative: -1, absolute: -1)))),
        ("gap nan", cfg("h", BranchAndBound(gap: Gap(relative: .nan, absolute: .nan)))),
        ("gap huge", cfg("i", BranchAndBound(gap: Gap(relative: 1e9, absolute: 1e9)))),
        ("threads 0", cfg("j", threads: 0, BranchAndBound())),
        ("threads -3", cfg("k", threads: -3, BranchAndBound())),
        ("threads 64", cfg("l", threads: 64, BranchAndBound())),
        ("seed max det", cfg("m", BranchAndBound(deterministic: true, seed: UInt64.max))),
    ]
    for (name, c) in cases {
        let t0 = Date()
        do {
            let r = try await c.solve(lp, c.threads, 60, false)
            print("\(name): \(r.status) obj \(fmt(r.objective)) bound \(fmt(r.bound)) gap \(fmt(r.gap)) nodes \(r.nodes) wall \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
        } catch { print("\(name): THROW \(error)") }
    }
    for (name, budget, tl) in [("memory 0", 0, 60.0), ("memory -1", -1, 60.0), ("time -1", 1 << 40, -1.0), ("time nan", 1 << 40, Double.nan), ("time inf", 1 << 40, Double.infinity)] {
        let r = try await run(BranchAndBound(), lp, timeLimit: tl, memory: budget)
        print("\(name): \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes)")
    }
}

func itersMode() async throws {
    // A two-column model: one integer column, root + at most two children; every LP needs a pivot or two.
    let lp = makeLP(c: [-1, -0.1], rows: [[2, 1]], rl: [-INF], ru: [1], xl: [0, 0], xu: [1, 1], integer: [0], sense: .minimize)
    for (name, br) in [("mostFractional", BranchingRule.mostFractional), ("strong(1)", .strong(candidates: 1)), ("pseudocost(4)", .pseudocost(reliability: 4))] {
        for eng in ["P", "D"] {
            let r = eng == "P" ? try await run(BranchAndBound(branching: br, heuristics: .none, deterministic: true), lp, threads: 1, timeLimit: 10)
                               : try await run(BranchAndBound(engine: Simplex(.dual), branching: br, heuristics: .none, deterministic: true), lp, threads: 1, timeLimit: 10)
            var ctx = SolveContext(); ctx.metal = .off
            let rootOnly = try await Simplex(eng == "P" ? .primal : .dual).solve(lp.relaxed(), context: ctx)
            print("\(name) \(eng): \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes) lpIterations \(r.iterations) (root LP alone: \(rootOnly.iterations) pivots)")
        }
    }
}

switch mode {
case "enum": try await enumMode()
case "bigm": try await bigM()
case "special": try await specialMode()
case "gap": try await gapMode()
case "iters": try await itersMode()
case "edge": try await edgeParamsMode()
case "relviol": try await relViolMode()
case "events": try await eventsMode()
case "misc": try await miscMode()
case "rootstop": try await rootStopMode()
case "gaploose": try await gapLooseMode()
case "limits": try await limitsMode()
case "det": try await detMode()
case "miplib": try await miplibMode()
default: print("unknown mode \(mode)")
}
