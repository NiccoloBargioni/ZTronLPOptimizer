// Cycle A, slot V106: sceptic of finding A4-06 (deterministic: true depends on SolveContext.threads).
// Independent of the finder's F4 probe: exact bit-pattern fingerprints, grouping by fingerprint
// (not comparison to a first run), repeated threads-1 runs, the default thread count (nil), and a
// causal check that toggles the strong-branching candidate count across the borrow threshold (4).
// Build: swift build --product V106 -c release   Run: .build/release/V106 <mode>
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func bits(_ d: Double?) -> String { d.map { String($0.bitPattern, radix: 16) } ?? "nil" }

func describe(_ e: SolverEvent) -> String {
    switch e {
    case .finished(let s, _): return "finished(\(s))"
    case .newIncumbent(let o, let n, let src): return "newIncumbent(\(o)[\(bits(o))],node \(n),\(src))"
    case .boundImproved(let b, let g): return "boundImproved(\(b)[\(bits(b))],gap \(g)[\(bits(g))])"
    case .simplexIteration(let i, let o, let inf, let p): return "spx(\(i),\(bits(o)),\(bits(inf)),\(p))"
    case .ipmIteration(let i, let mu, let pr, let dr): return "ipm(\(i),\(bits(mu)),\(bits(pr)),\(bits(dr)))"
    default: return "\(e)"
    }
}

struct FP {
    var status: String
    var objective: String
    var bound: String
    var gap: String
    var nodes: Int
    var open: Int
    var iterations: Int
    var primal: [String]
    var history: [String]
    var events: [String]
    var wall: Double
    var objValue: Double?

    func diff(_ o: FP) -> [String] {
        var d: [String] = []
        if status != o.status { d.append("status \(status)/\(o.status)") }
        if objective != o.objective { d.append("objective bits") }
        if bound != o.bound { d.append("bound bits") }
        if gap != o.gap { d.append("gap bits") }
        if nodes != o.nodes { d.append("nodes \(nodes)/\(o.nodes)") }
        if open != o.open { d.append("open \(open)/\(o.open)") }
        if iterations != o.iterations { d.append("lpIterations \(iterations)/\(o.iterations)") }
        if primal != o.primal {
            let k = zip(primal, o.primal).filter { $0 != $1 }.count
            d.append("primal (\(k) entries)")
        }
        if history != o.history { d.append("incumbentHistory (\(history.count)/\(o.history.count))") }
        if events != o.events {
            let first = zip(events, o.events).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? Swift.min(events.count, o.events.count)
            let a = first < events.count ? events[first] : "<end>"
            let b = first < o.events.count ? o.events[first] : "<end>"
            d.append("events (\(events.count)/\(o.events.count)) first diff #\(first): \(a) vs \(b)")
        }
        return d
    }
    var key: String {
        ([status, objective, bound, gap, "\(nodes)", "\(open)", "\(iterations)"] + primal + ["|"] + history + ["|"] + events)
            .joined(separator: ";")
    }
}

func solveOnce<E: NodeLPStrategy>(_ s: BranchAndBound<E>, _ lp: CompiledLP, threads: Int?) async throws -> FP {
    var ctx = SolveContext()
    ctx.timeLimit = 120
    ctx.threads = threads
    ctx.metal = .off
    let log = Log()
    ctx.progress = { e in log.add(describe(e)) }
    let t0 = Date()
    let a = try await s.solve(lp, context: ctx)
    let wall = Date().timeIntervalSince(t0)
    return FP(
        status: "\(a.status)", objective: bits(a.objectiveValue), bound: bits(a.bound), gap: bits(a.gap),
        nodes: a.nodesProcessed, open: a.nodesOpen, iterations: a.lpIterations,
        primal: (a.primal ?? []).map { bits($0) },
        history: a.incumbentHistory.map { "\(bits($0.objective))@\($0.node)/\($0.source)" },
        events: log.all, wall: wall, objValue: a.objectiveValue)
}

enum Eng: String, CaseIterable { case P, D, I }

func solve(_ eng: Eng, _ br: BranchingRule, _ lp: CompiledLP, threads: Int?, seed: UInt64 = 7) async throws -> FP {
    switch eng {
    case .P: return try await solveOnce(BranchAndBound(branching: br, deterministic: true, seed: seed), lp, threads: threads)
    case .D: return try await solveOnce(BranchAndBound(engine: Simplex(.dual), branching: br, deterministic: true, seed: seed), lp, threads: threads)
    case .I: return try await solveOnce(BranchAndBound(engine: InteriorPoint(), branching: br, deterministic: true, seed: seed), lp, threads: threads)
    }
}

func label(_ t: Int?) -> String { t.map { "t\($0)" } ?? "tnil" }

/// Runs one configuration at every thread count, groups the runs by exact fingerprint, prints
/// the groups and how each differs from the group of the first run.
@discardableResult
func groupRun(_ title: String, _ eng: Eng, _ br: BranchingRule, _ lp: CompiledLP, threads: [Int?]) async throws -> Int {
    var groups: [(key: String, fp: FP, members: [String])] = []
    var walls: [String] = []
    for t in threads {
        let fp = try await solve(eng, br, lp, threads: t)
        walls.append(String(format: "%@=%.2fs", label(t), fp.wall))
        if let g = groups.firstIndex(where: { $0.key == fp.key }) {
            groups[g].members.append(label(t))
        } else {
            groups.append((fp.key, fp, [label(t)]))
        }
    }
    let f = groups[0].fp
    print("\(title) \(eng.rawValue) \(br): \(f.status) obj \(f.objValue.map { "\($0)" } ?? "nil") nodes \(f.nodes) iters \(f.iterations) events \(f.events.count) hist \(f.history.count) | groups \(groups.count): " +
          groups.enumerated().map { "\(Character(UnicodeScalar(65 + $0.offset)!))=[\($0.element.members.joined(separator: ","))]" }.joined(separator: " "))
    for (k, g) in groups.enumerated().dropFirst() {
        print("    group \(Character(UnicodeScalar(65 + k)!)) vs A: " + g.fp.diff(f).joined(separator: "; "))
    }
    print("    walls: \(walls.joined(separator: " "))")
    return groups.count
}

func instances(_ names: [String]) throws -> [(String, CompiledLP)] {
    var out: [(String, CompiledLP)] = []
    for n in names {
        switch n {
        case "r10": out.append(("randomMILP(10,40,s9,u1)", InstanceGenerator.randomMILP(rows: 10, columns: 40, seed: 9, upper: 1)))
        case "m8": out.append(("mixed(8,30,s5,f.5,u3,real)", InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 5, integerFraction: 0.5, upper: 3, integralData: false)))
        case "r14": out.append(("randomMILP(14,50,s21,u2)", InstanceGenerator.randomMILP(rows: 14, columns: 50, seed: 21, upper: 2)))
        default:
            if let lp = try Corpora.loadMIPLIB3(n) { out.append((n, lp)) } else { print("missing \(n)") }
        }
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "repro"
let threadList: [Int?] = [1, 1, 2, 3, 4, 8, nil, 1]
print("activeProcessorCount \(ProcessInfo.processInfo.activeProcessorCount)")

switch mode {
case "repro":
    // repro <engines e.g. PDI> <instances...>
    let engs = (args.count > 1 ? Array(args[1]) : ["P", "D", "I"]).compactMap { Eng(rawValue: String($0)) }
    let names = args.count > 2 ? Array(args[2...]) : ["r10", "m8", "r14"]
    for (name, lp) in try instances(names) {
        for e in engs { try await groupRun(name, e, .pseudocost(reliability: 4), lp, threads: threadList) }
    }
case "mech":
    // mech <engine> <instances...>: branching rules on either side of the borrow threshold.
    let eng = Eng(rawValue: args.count > 1 ? args[1] : "P") ?? .P
    let names = args.count > 2 ? Array(args[2...]) : ["r10", "m8"]
    let rules: [BranchingRule] = [.mostFractional, .strong(candidates: 3), .strong(candidates: 4), .strong(candidates: 8), .pseudocost(reliability: 4)]
    for (name, lp) in try instances(names) {
        for br in rules { try await groupRun(name, eng, br, lp, threads: [1, 1, 2, 4, 4, 8]) }
    }
case "scan":
    // scan <engine> <count>: random MILPs, threads 1 vs 4 vs nil; counts which fields differ.
    let eng = Eng(rawValue: args.count > 1 ? args[1] : "P") ?? .P
    let count = args.count > 2 ? Int(args[2]) ?? 20 : 20
    var tally: [String: Int] = [:]
    var anyDiff = 0
    for s in 0..<count {
        let lp = s % 2 == 0
            ? InstanceGenerator.randomMILP(rows: 8 + s % 5, columns: 30 + 2 * (s % 7), seed: UInt64(100 + s), upper: 1 + s % 3)
            : InstanceGenerator.randomMILP(rows: 8 + s % 5, columns: 28 + 2 * (s % 7), seed: UInt64(100 + s), integerFraction: 0.6, upper: 2, integralData: false)
        let a = try await solve(eng, .pseudocost(reliability: 4), lp, threads: 1)
        let b = try await solve(eng, .pseudocost(reliability: 4), lp, threads: 4)
        let c = try await solve(eng, .pseudocost(reliability: 4), lp, threads: nil)
        let d = b.diff(a)
        let dc = c.diff(b)
        for item in d { let k = String(item.prefix(while: { $0 != " " })); tally[k, default: 0] += 1 }
        if !d.isEmpty { anyDiff += 1 }
        print("seed \(100 + s) \(a.status) obj \(a.objValue.map { "\($0)" } ?? "nil") nodes \(a.nodes) | t4 vs t1: \(d.isEmpty ? "same" : d.joined(separator: "; ")) | tnil vs t4: \(dc.isEmpty ? "same" : dc.joined(separator: "; "))")
    }
    print("scan \(eng.rawValue): \(anyDiff)/\(count) instances differ between threads 1 and 4; field tally \(tally.sorted { $0.key < $1.key })")
case "detail":
    // detail <engine> <s>: the scan's instance s at threads 1 and 4, primal entries side by side.
    let eng = Eng(rawValue: args.count > 1 ? args[1] : "P") ?? .P
    let s = args.count > 2 ? Int(args[2]) ?? 19 : 19
    let lp = s % 2 == 0
        ? InstanceGenerator.randomMILP(rows: 8 + s % 5, columns: 30 + 2 * (s % 7), seed: UInt64(100 + s), upper: 1 + s % 3)
        : InstanceGenerator.randomMILP(rows: 8 + s % 5, columns: 28 + 2 * (s % 7), seed: UInt64(100 + s), integerFraction: 0.6, upper: 2, integralData: false)
    let mask = lp.integerMask()
    for t in [1, 1, 4, 4] as [Int?] {
        let fp = try await solve(eng, .pseudocost(reliability: 4), lp, threads: t)
        print("\(label(t)): obj \(fp.objValue!) [\(fp.objective)] bound [\(fp.bound)] nodes \(fp.nodes) iters \(fp.iterations) hist \(fp.history)")
    }
    var ctx1 = SolveContext(); ctx1.threads = 1; ctx1.timeLimit = 60; ctx1.metal = .off
    var ctx4 = SolveContext(); ctx4.threads = 4; ctx4.timeLimit = 60; ctx4.metal = .off
    let a1 = try await BranchAndBound(deterministic: true, seed: 7).solve(lp, context: ctx1)
    let a4 = try await BranchAndBound(deterministic: true, seed: 7).solve(lp, context: ctx4)
    if eng == .P, let x1 = a1.primal, let x4 = a4.primal {
        var maxd = 0.0
        for j in 0..<x1.count where x1[j] != x4[j] {
            maxd = Swift.max(maxd, abs(x1[j] - x4[j]))
            print("  col \(j) \(mask[j] ? "int " : "cont") t1 \(x1[j]) t4 \(x4[j]) diff \(x1[j] - x4[j])")
        }
        let intSame = (0..<x1.count).allSatisfy { !mask[$0] || x1[$0] == x4[$0] }
        print("  max |x1-x4| = \(maxd); integer columns identical: \(intSame); objective diff \(a1.objectiveValue! - a4.objectiveValue!)")
    }
case "mdetail":
    // mdetail <engine> <miplib names...>: threads 1 vs 4, differing primal entries, and an own
    // check of each point (CSC data walked here, not the package's maxViolation/objective).
    let eng = Eng(rawValue: args.count > 1 ? args[1] : "P") ?? .P
    for name in args.dropFirst(2) {
        guard let lp = try Corpora.loadMIPLIB3(name) else { print("missing \(name)"); continue }
        let mask = lp.integerMask()
        func check(_ x: [Double]) -> (obj: Double, rowViol: Double, boundViol: Double, intViol: Double) {
            var act = [Double](repeating: 0, count: lp.m)
            for j in 0..<lp.n {
                for k in lp.a.colStart[j]..<lp.a.colStart[j + 1] { act[Int(lp.a.rowIndex[k])] += lp.a.values[k] * x[j] }
            }
            var rv = 0.0, bv = 0.0, iv = 0.0, obj = lp.c0
            for i in 0..<lp.m { rv = Swift.max(rv, lp.rl[i] - act[i], act[i] - lp.ru[i]) }
            for j in 0..<lp.n {
                bv = Swift.max(bv, lp.xl[j] - x[j], x[j] - lp.xu[j])
                if mask[j] { iv = Swift.max(iv, abs(x[j] - x[j].rounded())) }
                obj += lp.c[j] * x[j]
            }
            return (obj, rv, bv, iv)
        }
        var runs: [(Int, BranchAndBoundAnalysis<Simplex.Analysis>)] = []
        for t in [1, 4] {
            var ctx = SolveContext(); ctx.threads = t; ctx.timeLimit = 120; ctx.metal = .off
            let a = eng == .D
                ? try await BranchAndBound(engine: Simplex(.dual), deterministic: true, seed: 7).solve(lp, context: ctx)
                : try await BranchAndBound(deterministic: true, seed: 7).solve(lp, context: ctx)
            runs.append((t, a))
            let ck = check(a.primal ?? [])
            print("\(name) \(eng.rawValue) t\(t): \(a.status) obj \(a.objectiveValue ?? .nan) nodes \(a.nodesProcessed) iters \(a.lpIterations) | own check: c.x+c0 \(ck.obj) rowViol \(ck.rowViol) boundViol \(ck.boundViol) intViol \(ck.intViol) | published \(ReferenceValues.miplib3(named: name)?.optimalObjective ?? .nan)")
        }
        if let x1 = runs[0].1.primal, let x4 = runs[1].1.primal {
            let diff = (0..<lp.n).filter { x1[$0] != x4[$0] }
            let big = diff.filter { abs(x1[$0] - x4[$0]) > 0.5 }
            print("  differing entries \(diff.count), of which |diff| > 0.5: \(big.count) (integer: \(big.filter { mask[$0] }.count))")
            for j in diff.prefix(12) { print("    \(lp.names.column(j)) t1 \(x1[j]) t4 \(x4[j])") }
        }
    }
default:
    print("modes: repro [engines] [instances], mech [engine] [instances], scan [engine] [count], detail [engine] [s], mdetail [engine] [names]")
}
