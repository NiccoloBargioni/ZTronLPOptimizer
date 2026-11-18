// Cycle B, slot F4: limits (nodeLimit, timeLimit, memoryBudgetBytes) and determinism.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct Truth { let lp: CompiledLP; let name: String; let opt: Double }

func validate(_ t: Truth, _ out: RunOutcome, gap: Gap = Gap()) -> [String] {
    var issues: [String] = []
    let minimize = t.lp.sense == .minimize
    let tol = 1e-6 * max(1, abs(t.opt))
    if let x = out.primal {
        let v = t.lp.maxViolation(at: x)
        var relRow = 0.0
        let act = t.lp.rowActivity(x)
        for i in 0..<t.lp.m { relRow = max(relRow, (t.lp.rl[i] - act[i]) / (1 + abs(t.lp.rl[i])), (act[i] - t.lp.ru[i]) / (1 + abs(t.lp.ru[i]))) }
        if v.bounds > 1e-6 || relRow > 1e-6 { issues.append("incumbent infeasible b=\(v.bounds) r=\(relRow)") }
        for j in t.lp.integerColumns where abs(x[Int(j)] - x[Int(j)].rounded()) > 1e-6 { issues.append("x[\(j)] fractional"); break }
    }
    if let z = out.objective {
        if minimize ? z < t.opt - tol : z > t.opt + tol { issues.append("objective \(z) better than optimum \(t.opt)") }
        if out.status == .optimal {
            let worse = minimize ? z - t.opt : t.opt - z
            if worse > max(gap.absolute, gap.relative * max(1, abs(z))) + tol { issues.append("optimal \(z) beyond gap of \(t.opt)") }
        }
    }
    if let b = out.bound, minimize ? b > t.opt + tol : b < t.opt - tol { issues.append("bound \(b) invalid vs optimum \(t.opt)") }
    switch out.status {
    case .infeasible, .unbounded, .infeasibleOrUnbounded: issues.append("false \(out.status)")
    case .numericalFailure(let s): issues.append("numericalFailure \(s)")
    default: break
    }
    if out.status.hasSolution && out.primal == nil { issues.append("hasSolution without primal") }
    return issues
}

func loadTruths(_ which: [String]) async -> [Truth] {
    var truths: [Truth] = []
    for name in which {
        if name.hasPrefix("rmilp") {
            // rmilp:<rows>:<cols>:<seed>
            let p = name.split(separator: ":").map(String.init)
            let lp = InstanceGenerator.randomMILP(rows: Int(p[1])!, columns: Int(p[2])!, seed: UInt64(p[3])!, integerFraction: 1, upper: 1, integralData: false)
            var ctx = SolveContext(); ctx.timeLimit = 600
            let exact = try! await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0), deterministic: true).solve(lp, context: ctx)
            print("truth \(name): tight-gap det BnB \(exact.status) \(exact.objectiveValue ?? .nan) nodes=\(exact.nodesProcessed)")
            truths.append(Truth(lp: lp, name: name, opt: exact.objectiveValue!))
        } else if let ref = ReferenceValues.miplib3(named: name), let lp = try? Corpora.loadMIPLIB3(name) {
            truths.append(Truth(lp: lp, name: name, opt: ref.optimalObjective))
        }
    }
    return truths
}

func probeLimits(_ which: [String]) async {
    for t in await loadTruths(which) {
        print("== \(t.name) opt=\(t.opt) sense=\(t.lp.sense)")
        var prevObj: Double? = nil, prevBound: Double? = nil
        for limit in [0, 1, 2, 3, 5, 10, 25, 100, 400] {
            for (mode, s) in [("det", BranchAndBound(nodeLimit: limit, deterministic: true)), ("par", BranchAndBound(nodeLimit: limit))] {
                let out = await runBnB(s, t.lp, timeLimit: 120)
                var issues = validate(t, out)
                if mode == "det" {
                    // a deterministic search with a larger node limit is an extension of the smaller one
                    let minimize = t.lp.sense == .minimize
                    if let p = prevObj, let z = out.objective, minimize ? z > p + 1e-9 : z < p - 1e-9 { issues.append("det incumbent got worse with a larger nodeLimit: \(p) -> \(z)") }
                    if let p = prevBound, let b = out.bound, minimize ? b < p - 1e-9 : b > p + 1e-9 { issues.append("det bound got weaker with a larger nodeLimit: \(p) -> \(b)") }
                    prevObj = out.objective ?? prevObj
                    prevBound = out.bound ?? prevBound
                }
                print("  nodeLimit=\(limit) [\(mode)] status=\(out.status) obj=\(out.objective.map { String($0) } ?? "nil") bound=\(out.bound.map { String($0) } ?? "nil") nodes=\(out.nodes) \(issues.isEmpty ? "OK" : "ISSUES: " + issues.joined(separator: "; "))")
            }
        }
        for tl in [0.0, 0.01, 0.1, 0.5, 2.0] {
            for (mode, s) in [("det", BranchAndBound(deterministic: true)), ("par", BranchAndBound()), ("dual-par", BranchAndBound(engine: Simplex(.dual)))] as [(String, any SolverStrategy)] {
                let t0 = Date()
                let out: RunOutcome
                if let b = s as? BranchAndBound<Simplex> { out = await runBnB(b, t.lp, timeLimit: tl) } else { continue }
                let wall = Date().timeIntervalSince(t0)
                let issues = validate(t, out)
                print("  timeLimit=\(tl) [\(mode)] wall=\(String(format: "%.3f", wall)) status=\(out.status) obj=\(out.objective.map { String($0) } ?? "nil") bound=\(out.bound.map { String($0) } ?? "nil") nodes=\(out.nodes) \(issues.isEmpty ? "OK" : "ISSUES: " + issues.joined(separator: "; "))")
            }
        }
        for mem in [1, 1_000, 20_000, 200_000, 2_000_000] {
            for (mode, s) in [("det", BranchAndBound(deterministic: true)), ("par", BranchAndBound())] {
                let out = await runBnB(s, t.lp, timeLimit: 120, memory: mem)
                let issues = validate(t, out)
                print("  memoryBudgetBytes=\(mem) [\(mode)] status=\(out.status) obj=\(out.objective.map { String($0) } ?? "nil") bound=\(out.bound.map { String($0) } ?? "nil") nodes=\(out.nodes) warnings=\(out.warnings.prefix(2)) \(issues.isEmpty ? "OK" : "ISSUES: " + issues.joined(separator: "; "))")
            }
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ e: SolverEvent) {
        var text: String
        switch e {
        case .finished(let status, _): text = "finished(\(status))"
        default: text = "\(e)"
        }
        lock.lock(); events.append(text); lock.unlock()
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

func fingerprint<E: NodeLPStrategy>(_ s: BranchAndBound<E>, _ lp: CompiledLP, threads: Int? = nil) async -> (String, [String]) {
    let log = EventLog()
    var ctx = SolveContext()
    ctx.timeLimit = 600
    ctx.threads = threads
    ctx.progress = { log.add($0) }
    let a = try! await s.solve(lp, context: ctx)
    let hist = a.incumbentHistory.map { "\($0.objective.bitPattern)@\($0.node)/\($0.source)" }.joined(separator: ",")
    let x = (a.primal ?? []).map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
    let fp = "status=\(a.status) obj=\(a.objectiveValue.map { String($0) } ?? "nil") bound=\(a.bound.map { String($0) } ?? "nil") nodes=\(a.nodesProcessed) open=\(a.nodesOpen) lpIter=\(a.lpIterations) hist=[\(hist)] xhash=\(x.hashValue)"
    return (fp, log.all)
}

func probeDeterminism(_ which: [String], runs: Int) async {
    for t in await loadTruths(which) {
        print("== \(t.name)")
        for (name, s) in [("primal-det", BranchAndBound(deterministic: true)), ("dual-det", BranchAndBound(engine: Simplex(.dual), deterministic: true))] {
            var prints: [String] = []
            var logs: [[String]] = []
            for _ in 0..<runs {
                let (fp, ev) = await fingerprint(s, t.lp)
                prints.append(fp); logs.append(ev)
            }
            let same = Set(prints).count == 1
            let sameEvents = Set(logs.map { $0.joined(separator: "|") }).count == 1
            print("  [\(name)] runs=\(runs) identicalResults=\(same) identicalEvents=\(sameEvents) events=\(logs[0].count) \(prints[0].prefix(160))")
            if !same { for p in Set(prints) { print("     variant: \(p.prefix(300))") } }
            if !sameEvents {
                // first divergence
                let a = logs[0]
                for l in logs.dropFirst() where l != a {
                    let k = (0..<min(a.count, l.count)).first(where: { a[$0] != l[$0] }) ?? min(a.count, l.count)
                    print("     events diverge at \(k): \(k < a.count ? a[k] : "end") vs \(k < l.count ? l[k] : "end") (counts \(a.count) vs \(l.count))")
                    break
                }
            }
            // same deterministic search with one thread (probes cannot borrow)
            let (fp1, _) = await fingerprint(s, t.lp, threads: 1)
            print("  [\(name) threads=1] sameAsDefaultThreads=\(fp1 == prints[0]) \(fp1 == prints[0] ? "" : String(fp1.prefix(200)))")
        }
        // parallel: objective agreement within the gap
        var objs: [Double] = []
        for _ in 0..<runs { let o = await runBnB(BranchAndBound(), t.lp, timeLimit: 600); objs.append(o.objective ?? .nan) }
        let spread = (objs.max() ?? 0) - (objs.min() ?? 0)
        print("  [par] objectives=\(objs) spread=\(spread) withinGap=\(spread <= max(1e-6, 1e-4 * max(1, abs(t.opt))))")
    }
}

func probeDetThreads(_ which: [String]) async {
    for t in await loadTruths(which) {
        for th in [1, 2, 3, 4, 8, 16] {
            let (fp, _) = await fingerprint(BranchAndBound(deterministic: true), t.lp, threads: th)
            let (fp2, _) = await fingerprint(BranchAndBound(deterministic: true), t.lp, threads: th)
            print("\(t.name) threads=\(th) repeatable=\(fp == fp2) \(fp.prefix(150))")
        }
    }
}

/// Concurrency and tree invariants on medium random MILPs: incumbent history strictly improving,
/// last entry equals the reported objective, boundImproved events monotone and never past the
/// optimum, node count events monotone, objective agrees with a tight-gap deterministic reference.
func probeInvariants(seeds: Range<UInt64>, cols: Int) async {
    var bad = 0
    for s in seeds {
        let lp = InstanceGenerator.randomMILP(rows: 6, columns: cols, seed: s, integerFraction: 0.8, upper: 2, integralData: s % 2 == 0)
        var ctx = SolveContext(); ctx.timeLimit = 120
        let ref = try! await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0), deterministic: true).solve(lp, context: ctx)
        guard ref.status == .optimal, let opt = ref.objectiveValue else { print("seed \(s): reference \(ref.status)"); continue }
        for th in [2, 8, 16] {
            let log = EventLog()
            var c = SolveContext(); c.timeLimit = 120; c.threads = th
            c.progress = { log.add($0) }
            let a = try! await BranchAndBound(nodeSelection: s % 3 == 0 ? .bestBound : .bestBoundWithPlunging(maxDepth: 32)).solve(lp, context: c)
            var issues: [String] = []
            let h = a.incumbentHistory.map(\.objective)   // maximization: strictly increasing
            for k in 1..<max(1, h.count) where h[k] <= h[k - 1] { issues.append("history not improving at \(k): \(h[k-1]) -> \(h[k])") }
            if let last = h.last, last != a.objectiveValue { issues.append("last history \(last) != objective \(String(describing: a.objectiveValue))") }
            if a.incumbents != h.count { issues.append("incumbents \(a.incumbents) != history \(h.count)") }
            if let z = a.objectiveValue, opt - z > max(1e-6, 1e-4 * max(1, abs(z))) + 1e-9 { issues.append("objective \(z) beyond gap of \(opt)") }
            if let z = a.objectiveValue, z > opt + 1e-6 * max(1, abs(opt)) { issues.append("objective \(z) above optimum \(opt)") }
            if let b = a.bound, b < opt - 1e-6 * max(1, abs(opt)) { issues.append("bound \(b) below optimum \(opt)") }
            var lastBound = Double.infinity
            var lastNodes = -1
            var finishedCount = 0
            for e in log.all {
                if e.hasPrefix("boundImproved") {
                    // parse bound: boundImproved(bound: X, gap: Y)
                    let v = Double(e.split(separator: ":")[1].split(separator: ",")[0].trimmingCharacters(in: .whitespaces)) ?? .nan
                    if v > lastBound + 1e-9 { issues.append("boundImproved not monotone: \(lastBound) -> \(v)") }
                    if v < opt - 1e-6 * max(1, abs(opt)) { issues.append("boundImproved \(v) below optimum \(opt) (invalid upper bound)") }
                    lastBound = v
                }
                if e.hasPrefix("nodes(") {
                    let v = Int(e.split(separator: ":")[1].split(separator: ",")[0].trimmingCharacters(in: .whitespaces)) ?? -1
                    if v < lastNodes { issues.append("nodes event decreased \(lastNodes) -> \(v)") }
                    lastNodes = v
                }
                if e.hasPrefix("finished") { finishedCount += 1 }
            }
            if finishedCount != 1 || !(log.all.last ?? "").hasPrefix("finished") { issues.append("finished events \(finishedCount), last=\(log.all.last ?? "-")") }
            if !issues.isEmpty { bad += 1; print("seed \(s) threads \(th): \(a.status) obj=\(String(describing: a.objectiveValue)) opt=\(opt) :: \(issues.prefix(4).joined(separator: " | "))") }
        }
    }
    print("INVARIANTS seeds=\(seeds) cols=\(cols) bad=\(bad)")
}

func probeBoundSeed(_ s: UInt64, cols: Int) async {
    let lp = InstanceGenerator.randomMILP(rows: 6, columns: cols, seed: s, integerFraction: 0.8, upper: 2, integralData: s % 2 == 0)
    var ctx = SolveContext(); ctx.timeLimit = 120
    let ref = try! await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0), deterministic: true).solve(lp, context: ctx)
    let x = ref.primal!
    let v = lp.maxViolation(at: x)
    var intErr = 0.0
    for j in lp.integerColumns { intErr = max(intErr, abs(x[Int(j)] - x[Int(j)].rounded())) }
    print("randomMILP(rows: 6, columns: \(cols), seed: \(s), integerFraction: 0.8, upper: 2, integralData: \(s % 2 == 0)) ints=\(lp.integerColumns.count)/\(lp.n)")
    print("  reference Gap(0,0) det dual: \(ref.status) objective=\(ref.objectiveValue!) objective(at:x)=\(lp.objective(at: x)) violation(bounds: \(v.bounds), rows: \(v.rows)) intErr=\(intErr)")
    for (name, cfg) in [("BranchAndBound()", BranchAndBound()), ("BranchAndBound(deterministic: true)", BranchAndBound(deterministic: true))] {
        let a = try! await cfg.solve(lp, context: ctx)
        print("  \(name): \(a.status) objective=\(a.objectiveValue!) bound=\(a.bound!) gap=\(a.gap!) nodes=\(a.nodesProcessed) -> bound below a feasible objective by \(lp.objective(at: x) - a.bound!)")
    }
}

func probeTime(_ which: [String], limits: [Double]) async {
    for t in await loadTruths(which) {
        for tl in limits {
            for (mode, s) in [("par", BranchAndBound()), ("det", BranchAndBound(deterministic: true))] {
                let t0 = Date()
                let out = await runBnB(s, t.lp, timeLimit: tl)
                let wall = Date().timeIntervalSince(t0)
                let issues = validate(t, out)
                print("\(t.name) timeLimit=\(tl) [\(mode)] wall=\(String(format: "%.3f", wall)) overshoot=\(String(format: "%.3f", wall - tl)) status=\(out.status) obj=\(out.objective.map { String($0) } ?? "nil") bound=\(out.bound.map { String($0) } ?? "nil") nodes=\(out.nodes) \(issues.isEmpty ? "OK" : "ISSUES: " + issues.joined(separator: "; "))")
            }
            let t1 = Date()
            let d = await runBnB(BranchAndBound(engine: Simplex(.dual)), t.lp, timeLimit: tl)
            print("\(t.name) timeLimit=\(tl) [dual-par] wall=\(String(format: "%.3f", Date().timeIntervalSince(t1))) status=\(d.status) \(validate(t, d))")
            let t2 = Date()
            let i = await runBnB(BranchAndBound(engine: InteriorPoint()), t.lp, timeLimit: tl)
            print("\(t.name) timeLimit=\(tl) [ipm-par] wall=\(String(format: "%.3f", Date().timeIntervalSince(t2))) status=\(i.status) obj=\(i.objective.map { String($0) } ?? "nil") \(validate(t, i))")
        }
    }
}

/// Test-integrity probes: the package's own BranchAndBoundLimitsTests instances.
func probeTestIntegrity() async {
    let hard = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)
    var ctx = SolveContext(); ctx.timeLimit = 300
    ctx.memoryBudgetBytes = 2_000
    let m = try! await BranchAndBound(nodeSelection: .bestBound, heuristics: .none).solve(hard, context: ctx)
    print("memoryBudgetDegradesThenStops instance, budget 2000: status=\(m.status) nodes=\(m.nodesProcessed) warnings=\(m.warnings)")
    ctx.memoryBudgetBytes = nil
    print("hardInstance objective step: costs integral = \(hard.c.allSatisfy { $0 == $0.rounded() })")
    // aLooseGapStopsEarlyAndReportsIt on the same generator with fractional data (objective step 0)
    for integral in [true, false] {
        let lp = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1, integralData: integral)
        let exact = try! await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0)).solve(lp, context: ctx)
        let loose = try! await BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0.2, absolute: 1e-6)).solve(lp, context: ctx)
        print("integralData=\(integral): exact(Gap 0) \(exact.status) \(exact.objectiveValue!) | loose(0.2) \(loose.status) objective=\(loose.objectiveValue!) bound=\(loose.bound!) gap=\(loose.gap!) nodes=\(loose.nodesProcessed) -> bound >= optimum? \(loose.bound! >= exact.objectiveValue! - 1e-6)")
    }
}

/// nodeLimit equal to the node count the deterministic search needs.
func probeExactNodeLimit(_ name: String) async {
    guard let t = await loadTruths([name]).first else { return }
    let full = await runBnB(BranchAndBound(deterministic: true), t.lp, timeLimit: 300)
    print("\(name) det full: \(full.status) nodes=\(full.nodes) obj=\(String(describing: full.objective))")
    for k in [full.nodes - 1, full.nodes, full.nodes + 1] {
        let o = await runBnB(BranchAndBound(nodeLimit: k, deterministic: true), t.lp, timeLimit: 300)
        print("  nodeLimit=\(k): status=\(o.status) obj=\(String(describing: o.objective)) bound=\(String(describing: o.bound)) nodes=\(o.nodes)")
    }
}

func probeDetSelection(_ which: [String]) async {
    for t in await loadTruths(which) {
        var prints: [String] = []
        for sel in [NodeSelection.bestBoundWithPlunging(maxDepth: 32), .bestBound, .depthFirst, .bestBoundWithPlunging(maxDepth: 2)] {
            let (fp, _) = await fingerprint(BranchAndBound(nodeSelection: sel, deterministic: true), t.lp)
            prints.append(fp)
            print("\(t.name) det nodeSelection=\(sel): \(fp.prefix(120))")
        }
        print("\(t.name) identical across nodeSelection: \(Set(prints).count == 1)")
    }
}
