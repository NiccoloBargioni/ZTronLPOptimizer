// Slot V103, cycle A: independent reproduction of finding A4-05 (stop during root expansion).
// Modes: oracle | natural | cancel | deadline | big | all
// Build: swift build --product V103 -c release   Run: .build/release/V103 <mode>
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "all"

func f(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.6g", v)
}
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - Independent arithmetic (no solver involved)

/// Exact check of an integer point in Int64 arithmetic (all data of randomMILP are integral).
/// Returns the model-sense objective (profit) when the point is feasible.
func exactCheck(_ x: [Double], _ lp: CompiledLP) -> (ok: Bool, objective: Int64, why: String) {
    let n = lp.n, m = lp.m
    var xi = [Int64](repeating: 0, count: n)
    for j in 0..<n {
        let r = x[j].rounded()
        if Swift.abs(x[j] - r) > 1e-6 { return (false, 0, "x[\(j)]=\(x[j]) not integral") }
        if r < lp.xl[j] || r > lp.xu[j] { return (false, 0, "x[\(j)]=\(r) outside [\(lp.xl[j]), \(lp.xu[j])]") }
        xi[j] = Int64(r)
    }
    var act = [Int64](repeating: 0, count: m)
    for j in 0..<n where xi[j] != 0 {
        for k in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            let a = lp.a.values[k]
            precondition(a == a.rounded(), "non-integral coefficient")
            act[Int(lp.a.rowIndex[k])] += Int64(a) * xi[j]
        }
    }
    for i in 0..<m {
        if lp.ru[i].isFinite && Double(act[i]) > lp.ru[i] { return (false, 0, "row \(i): \(act[i]) > \(lp.ru[i])") }
        if lp.rl[i].isFinite && Double(act[i]) < lp.rl[i] { return (false, 0, "row \(i): \(act[i]) < \(lp.rl[i])") }
    }
    var obj: Int64 = 0
    for j in 0..<n {
        let p = -lp.c[j]  // c is the minimization form of a maximization model
        precondition(p == p.rounded(), "non-integral profit")
        obj += Int64(p) * xi[j]
    }
    return (true, obj, "ok")
}

/// Weak (Lagrangian) duality: for max pᵀx, rl ≤ Ax ≤ ru, xl ≤ x ≤ xu and ANY multipliers y,
/// pᵀx = yᵀAx + (p − Aᵀy)ᵀx ≤ Σ_i (y_i>0 ? y_i ru_i : y_i rl_i) + Σ_j (d_j>0 ? d_j xu_j : d_j xl_j).
/// Multipliers whose side is infinite are set to 0 (another choice of y, still valid).
func lagrangianUpperBound(_ yIn: [Double], _ lp: CompiledLP) -> Double {
    var y = yIn
    for i in 0..<lp.m {
        if y[i] > 0 && !lp.ru[i].isFinite { y[i] = 0 }
        if y[i] < 0 && !lp.rl[i].isFinite { y[i] = 0 }
    }
    var bound = 0.0
    for i in 0..<lp.m where y[i] != 0 { bound += y[i] > 0 ? y[i] * lp.ru[i] : y[i] * lp.rl[i] }
    for j in 0..<lp.n {
        var aty = 0.0
        for k in lp.a.colStart[j]..<lp.a.colStart[j + 1] { aty += lp.a.values[k] * y[Int(lp.a.rowIndex[k])] }
        let d = -lp.c[j] - aty
        if d > 0 { bound += d * lp.xu[j] } else if d < 0 { bound += d * lp.xl[j] }
    }
    return bound
}

/// Feasibility of an LP point (continuous) and its model-sense objective.
func lpPointCheck(_ x: [Double], _ lp: CompiledLP) -> (maxViol: Double, objective: Double) {
    var viol = 0.0
    var act = [Double](repeating: 0, count: lp.m)
    for j in 0..<lp.n {
        viol = Swift.max(viol, lp.xl[j] - x[j], x[j] - lp.xu[j])
        for k in lp.a.colStart[j]..<lp.a.colStart[j + 1] { act[Int(lp.a.rowIndex[k])] += lp.a.values[k] * x[j] }
    }
    for i in 0..<lp.m {
        if lp.ru[i].isFinite { viol = Swift.max(viol, act[i] - lp.ru[i]) }
        if lp.rl[i].isFinite { viol = Swift.max(viol, lp.rl[i] - act[i]) }
    }
    var obj = 0.0
    for j in 0..<lp.n { obj += -lp.c[j] * x[j] }
    return (viol, obj)
}

// MARK: - Runs

final class Probe: @unchecked Sendable {
    let lock = NSLock()
    let t0 = nowNs()
    var task: Task<BranchAndBoundAnalysis<SimplexAnalysis>, Error>? = nil
    var ready = false
    var log: [String] = []
    var trigger: (@Sendable (SolverEvent, Probe) -> Bool)? = nil  // returns true when it acted
    var acted: String? = nil
    var blockSeconds: Double = 0

    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func setTask(_ t: Task<BranchAndBoundAnalysis<SimplexAnalysis>, Error>) {
        lock.lock(); task = t; ready = true; lock.unlock()
    }
    func onEvent(_ e: SolverEvent) {
        let ms = Double(nowNs() - t0) / 1e6
        lock.lock()
        switch e {
        case .newIncumbent, .boundImproved, .nodes, .finished: log.append(String(format: "%.3fms ", ms) + "\(e)")
        default: break
        }
        var fire = false
        if acted == nil, let trigger, trigger(e, self) {
            acted = String(format: "%.3fms ", ms) + "\(e)"
            fire = true
        }
        let t = task
        let block = blockSeconds
        lock.unlock()
        if fire {
            if block > 0 { Thread.sleep(forTimeInterval: block) } else { t?.cancel() }
        }
    }
}

func solveBB(
    _ lp: CompiledLP, timeLimit: Double, threads: Int, engine: Simplex.Method = .primal,
    probe: Probe? = nil, nodeLimit: Int? = nil
) async throws -> BranchAndBoundAnalysis<SimplexAnalysis> {
    let probe = probe ?? Probe()
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    ctx.threads = threads
    ctx.metal = .off
    ctx.progress = { e in probe.onEvent(e) }
    let strategy = BranchAndBound(engine: Simplex(engine), nodeLimit: nodeLimit)
    let task = Task { () async throws -> BranchAndBoundAnalysis<SimplexAnalysis> in
        while !probe.isReady() { await Task.yield() }
        return try await strategy.solve(lp, context: ctx)
    }
    probe.setTask(task)
    return try await task.value
}

func line(_ a: BranchAndBoundAnalysis<SimplexAnalysis>) -> String {
    "\(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) nodes \(a.nodesProcessed) open \(a.nodesOpen) rootLP \(f(a.root.objectiveValue)) inc \(a.incumbentHistory.map { "\($0.source)@\($0.node)" })"
}

/// Classify a result against an independently verified feasible objective L (max model):
/// a valid proven bound must satisfy bound >= L.
func classify(_ a: BranchAndBoundAnalysis<SimplexAnalysis>, L: Double) -> String {
    switch a.status {
    case .noSolution: return "noSolution"
    case .optimal: return (a.objectiveValue ?? 0) >= L - 1e-6 ? "optimal-ok" : "optimal-WRONG"
    case .feasible:
        guard let b = a.bound else { return "feasible-nilBound" }
        if b >= L - 1e-6 { return "feasible-validBound" }
        if a.nodesProcessed == 1 && a.nodesOpen == 0 && Swift.abs(b - (a.objectiveValue ?? .nan)) < 1e-9 && (a.gap ?? -1) == 0 {
            return "feasible-ROOTLOST(bound=obj,gap0)"
        }
        return "feasible-INVALIDBOUND-other"
    default: return "\(a.status)"
    }
}

let lp = InstanceGenerator.randomMILP(rows: 30, columns: 120, seed: 77, upper: 1)

/// The independent oracle: certified LP relaxation value and a certified feasible integer point.
func oracle(_ lp: CompiledLP, longLimit: Double) async throws -> (L: Double, rootUB: Double) {
    print("== ORACLE  m \(lp.m) n \(lp.n) nnz \(lp.a.nnz) sense \(lp.sense) integer \(lp.integerColumns.count) c0 \(lp.c0)")
    var ctx = SolveContext(); ctx.timeLimit = 60; ctx.metal = .off; ctx.threads = 1
    var bestUB = Double.infinity
    // LP relaxation by three engines; certify each by its own primal point and a weak-duality bound.
    for (name, solve) in [
        ("Simplex(.primal)", { () async throws -> any SolutionAnalysis in try await Simplex(.primal).solve(lp, context: ctx) }),
        ("Simplex(.dual)", { () async throws -> any SolutionAnalysis in try await Simplex(.dual).solve(lp, context: ctx) }),
        ("InteriorPoint(.none)", { () async throws -> any SolutionAnalysis in try await InteriorPoint(crossover: .none).solve(lp, context: ctx) }),
    ] as [(String, () async throws -> any SolutionAnalysis)] {
        let r = try await solve()
        var primalInfo = "no primal"
        if let x = r.primal {
            let (v, o) = lpPointCheck(x, lp)
            primalInfo = "my pᵀx \(String(format: "%.9f", o)) maxViol \(f(v))"
        }
        var ubInfo = "no duals"
        if let y = r.dual {
            let u1 = lagrangianUpperBound(y, lp)
            let u2 = lagrangianUpperBound(y.map { -$0 }, lp)
            let u = Swift.min(u1, u2)
            bestUB = Swift.min(bestUB, u)
            ubInfo = "my weak-duality UB(y) \(String(format: "%.9f", u1)) UB(-y) \(f(u2))"
        }
        print("LP \(name): \(r.status) reported \(f(r.objectiveValue)) | \(primalInfo) | \(ubInfo)")
    }
    // Trivial bound for scale: all profits.
    let total = lp.c.reduce(0) { $0 - $1 }
    print("sum of all profits (trivial UB) \(total)")
    // Feasible integer points from two different engines; each verified exactly by my own code.
    var L = -Double.infinity
    var ctxL = SolveContext(); ctxL.timeLimit = longLimit; ctxL.metal = .off
    let t1 = nowNs()
    let bb = try await BranchAndBound().solve(lp, context: ctxL)  // default primal engine (the finder used .dual)
    let bbS = Double(nowNs() - t1) / 1e9
    if let x = bb.primal {
        let e = exactCheck(x, lp)
        print("BranchAndBound(primal) \(longLimit)s: \(bb.status) obj \(f(bb.objectiveValue)) bound \(f(bb.bound)) nodes \(bb.nodesProcessed) \(String(format: "%.1f", bbS))s | exact check: \(e.ok) \(e.why) objective \(e.objective)")
        if e.ok { L = Swift.max(L, Double(e.objective)) }
    }
    let t2 = nowNs()
    let cp = try await CPSAT().solve(lp, context: ctxL)
    let cpS = Double(nowNs() - t2) / 1e9
    if let x = cp.primal {
        let e = exactCheck(x, lp)
        print("CPSAT \(longLimit)s: \(cp.status) obj \(f(cp.objectiveValue)) bound \(f(cp.bound)) conflicts \(cp.conflicts) \(String(format: "%.1f", cpS))s | exact check: \(e.ok) \(e.why) objective \(e.objective)")
        if e.ok { L = Swift.max(L, Double(e.objective)) }
    }
    print("ORACLE: certified LP relaxation UB (weak duality) \(String(format: "%.6f", bestUB)); certified feasible integer objective L = \(L)")
    return (L, bestUB)
}

func naturalSweep(_ lp: CompiledLP, L: Double, reps: Int) async throws {
    print("== NATURAL time-limit sweep (\(reps) reps each)")
    for T in [0.0005, 0.001, 0.002, 0.003, 0.005, 0.01, 0.02, 0.05] {
        for threads in [1, 8] {
            var counts: [String: Int] = [:]
            var example: [String: String] = [:]
            for _ in 0..<reps {
                let a = try await solveBB(lp, timeLimit: T, threads: threads)
                let k = classify(a, L: L)
                counts[k, default: 0] += 1
                if example[k] == nil { example[k] = line(a) }
            }
            print("T \(T) t\(threads): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            for (k, v) in example.sorted(by: { $0.key < $1.key }) where k.contains("ROOTLOST") || k.contains("INVALID") || k.contains("valid") {
                print("   e.g. \(k): \(v)")
            }
        }
    }
}

func cancelDeterministic(_ lp: CompiledLP, L: Double, reps: Int) async throws {
    print("== CANCEL from the progress callback at the root's first incumbent (node 0), \(reps) reps")
    for threads in [1, 8] {
        var counts: [String: Int] = [:]
        var example: [String: String] = [:]
        for _ in 0..<reps {
            let p = Probe()
            p.trigger = { e, _ in if case .newIncumbent(_, let node, _) = e, node == 0 { return true }; return false }
            let a = try await solveBB(lp, timeLimit: 60, threads: threads, probe: p)
            let k = classify(a, L: L)
            counts[k, default: 0] += 1
            if example[k] == nil { example[k] = line(a) + " | cancelled at \(p.acted ?? "never")" }
        }
        print("t\(threads): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for (k, v) in example.sorted(by: { $0.key < $1.key }) { print("   e.g. \(k): \(v)") }
    }
    print("== CONTROL: cancel at the first boundImproved event (emitted after the root is in the tree), \(reps) reps")
    for threads in [1, 8] {
        var counts: [String: Int] = [:]
        var example: [String: String] = [:]
        for _ in 0..<reps {
            let p = Probe()
            p.trigger = { e, _ in if case .boundImproved = e { return true }; return false }
            let a = try await solveBB(lp, timeLimit: 60, threads: threads, probe: p)
            let k = classify(a, L: L)
            counts[k, default: 0] += 1
            if example[k] == nil { example[k] = line(a) + " | cancelled at \(p.acted ?? "never")" }
        }
        print("t\(threads): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for (k, v) in example.sorted(by: { $0.key < $1.key }) { print("   e.g. \(k): \(v)") }
    }
    print("== CONTROL: nodeLimit 1 and nodeLimit 2 (no stop signal)")
    for limit in [1, 2] {
        let a = try await solveBB(lp, timeLimit: 60, threads: 1, nodeLimit: limit)
        print("nodeLimit \(limit): \(classify(a, L: L)) \(line(a))")
    }
}

func deadlineDeterministic(_ lp: CompiledLP, L: Double, reps: Int) async throws {
    print("== DEADLINE: timeLimit 1 s; the progress callback blocks 1.2 s at the root's first incumbent, \(reps) reps")
    for threads in [1, 8] {
        var counts: [String: Int] = [:]
        var example: [String: String] = [:]
        for _ in 0..<reps {
            let p = Probe()
            p.blockSeconds = 1.2
            p.trigger = { e, _ in if case .newIncumbent(_, let node, _) = e, node == 0 { return true }; return false }
            let a = try await solveBB(lp, timeLimit: 1.0, threads: threads, probe: p)
            let k = classify(a, L: L)
            counts[k, default: 0] += 1
            if example[k] == nil { example[k] = line(a) + " | blocked at \(p.acted ?? "never") | events \(p.log.suffix(4))" }
        }
        print("t\(threads): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for (k, v) in example.sorted(by: { $0.key < $1.key }) { print("   e.g. \(k): \(v)") }
    }
}

/// A larger model, where the root expansion (rounding, dive, strong-branching probes) takes long
/// enough for an ordinary time limit to land in it.
func bigWindow() async throws {
    let rows = args.count > 2 ? Int(args[2])! : 120
    let cols = args.count > 3 ? Int(args[3])! : 1200
    let seed = args.count > 4 ? UInt64(args[4])! : 5
    let big = InstanceGenerator.randomMILP(rows: rows, columns: cols, seed: seed, upper: 1)
    print("== BIG randomMILP(rows \(rows), columns \(cols), seed \(seed), upper 1)")
    // Measure the window: first incumbent at node 0 .. first boundImproved (root children queued).
    let p = Probe()
    p.trigger = { e, _ in if case .boundImproved = e { return true }; return false }
    let a = try await solveBB(big, timeLimit: 120, threads: 8, probe: p)
    print("window run (cancelled at first boundImproved): \(line(a))")
    for e in p.log.prefix(6) { print("   \(e)") }
    // An exactly verified point from that run gives L for the big model.
    var L = -Double.infinity
    if let x = a.primal { let e = exactCheck(x, big); print("   exact check of its incumbent: \(e.ok) \(e.objective)"); if e.ok { L = Double(e.objective) } }
    let first0 = p.log.first { $0.contains("newIncumbent") }
    let bi = p.log.first { $0.contains("boundImproved") }
    func ms(_ s: String?) -> Double? { s.flatMap { Double($0.split(separator: "m").first ?? "") } }
    guard let lo = ms(first0), let hi = ms(bi), hi > lo else { print("no window measured"); return }
    print(String(format: "root window: first incumbent at %.1f ms, root children queued at %.1f ms", lo, hi))
    // Time limits inside the window (as seconds from solve start).
    for frac in [0.3, 0.6, 0.9] {
        let T = (lo + frac * (hi - lo)) / 1000
        for _ in 0..<2 {
            let r = try await solveBB(big, timeLimit: T, threads: 8)
            // L from the window run plus anything better any run found (all exactly verified).
            if let x = r.primal { let e = exactCheck(x, big); if e.ok { L = Swift.max(L, Double(e.objective)) } }
            print(String(format: "T %.4f s: ", T) + "\(line(r))")
        }
    }
    let ref = try await solveBB(big, timeLimit: 20, threads: 8)
    if let x = ref.primal { let e = exactCheck(x, big); print("20 s reference: \(line(ref)) | exact check \(e.ok) \(e.objective)") }
}

switch mode {
case "oracle":
    _ = try await oracle(lp, longLimit: 120)
case "natural":
    try await naturalSweep(lp, L: Double(args.count > 2 ? args[2] : "1097")!, reps: 5)
case "cancel":
    try await cancelDeterministic(lp, L: Double(args.count > 2 ? args[2] : "1097")!, reps: 10)
case "deadline":
    try await deadlineDeterministic(lp, L: Double(args.count > 2 ? args[2] : "1097")!, reps: 3)
case "big":
    try await bigWindow()
case "all":
    let (L, _) = try await oracle(lp, longLimit: 120)
    try await naturalSweep(lp, L: L, reps: 5)
    try await cancelDeterministic(lp, L: L, reps: 10)
    try await deadlineDeterministic(lp, L: L, reps: 3)
default:
    print("unknown mode \(mode)")
}
