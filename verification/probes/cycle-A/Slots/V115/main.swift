// V115 — sceptic for finding A4-09 (cycle A): are the .boundImproved events of a parallel
// branch-and-bound search delivered out of order?
//
// Independent oracle (not the finder's adjacent-drop count):
//  * contract view: each delivered .boundImproved must improve on the best bound delivered
//    before it (running maximum, internal minimisation sense), counted strictly and with the
//    package's own 1e-9 relative emission threshold; plus the number of inverted pairs;
//  * cause view: the delivered values, sorted, must form a sequence the tree could have
//    produced (each above the previous by > 1e-9 max(1,|b|)); if so, a drop in delivery order
//    is a re-ordering of a valid production sequence, not a bound that regressed in the tree;
//  * controls: a single worker (threads: 1) and deterministic: true (one worker, 8 threads)
//    must show no stale event at all;
//  * validity: every delivered bound must stay at or below the published optimum.
// Build: swift build --product V115 -c release   Run: .build/release/V115 repro|control [runs]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SolverEvent] = []
    func add(_ e: SolverEvent) { lock.lock(); items.append(e); lock.unlock() }
    var events: [SolverEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

struct Stats {
    var label = ""
    var status = ""
    var objective: Double? = nil
    var finalBound: Double? = nil
    var wall = 0.0
    var nBound = 0
    var stale = 0          // delivered bound strictly below the running max of earlier ones
    var staleThr = 0       // not above the running max by the package's 1e-9 threshold
    var inversions = 0     // pairs i < j with b_j < b_i
    var permOK = true      // sorted values strictly increasing by the emission threshold
    var maxDisplacement = 0
    var worstDrop = 0.0    // largest (running max - stale bound)
    var invalid = 0        // bound above the reference optimum (minimisation sense)
    var staleGapUp = 0     // stale events whose gap field exceeds the running-max event's gap
    var nodesEvents = 0
    var nodesDrops = 0     // .nodes(processed:) going backwards in delivery order
    var incEvents = 0
    var incNonImproving = 0
    var finishedOK = true
    var details: [String] = []
}

func analyse(_ events: [SolverEvent], flip: Double, reference: Double?) -> Stats {
    var s = Stats()
    var bounds: [Double] = []
    var gaps: [Double] = []
    var nodes: [Int] = []
    var incs: [Double] = []
    for e in events {
        switch e {
        case .boundImproved(let b, let g): bounds.append(flip * b); gaps.append(g)
        case .nodes(let p, _): nodes.append(p)
        case .newIncumbent(let o, _, _): incs.append(flip * o)
        default: break
        }
    }
    s.nBound = bounds.count
    s.nodesEvents = nodes.count
    s.incEvents = incs.count
    s.finishedOK = events.filter(\.isFinished).count == 1 && events.last?.isFinished == true
    // Running maximum (contract: every event names an improvement).
    var runMax = -Double.infinity
    var runMaxGap = Double.infinity
    var runMaxIndex = -1
    for (i, b) in bounds.enumerated() {
        let thr = 1e-9 * max(1, abs(b))
        if i > 0 {
            if b < runMax {
                s.stale += 1
                s.worstDrop = max(s.worstDrop, runMax - b)
                if gaps[i] > runMaxGap { s.staleGapUp += 1 }
                if s.details.count < 4 {
                    s.details.append(String(
                        format: "    stale event #%d: bound %.12g gap %.6g after #%d bound %.12g gap %.6g (drop %.3g)",
                        i, b, gaps[i], runMaxIndex, runMax, runMaxGap, runMax - b))
                }
            }
            if !(b > runMax + thr) { s.staleThr += 1 }
        }
        if b > runMax { runMax = b; runMaxGap = gaps[i]; runMaxIndex = i }
        if let reference, b > reference + 1e-6 * max(1, abs(reference)) { s.invalid += 1 }
    }
    // Inverted pairs.
    if bounds.count > 1 {
        for i in 0..<(bounds.count - 1) {
            let bi = bounds[i]
            for j in (i + 1)..<bounds.count where bounds[j] < bi { s.inversions += 1 }
        }
    }
    // Could the tree have produced this multiset? (strictly increasing by its own threshold)
    let sorted = bounds.sorted()
    for k in 0..<max(0, sorted.count - 1) where !(sorted[k + 1] > sorted[k] + 1e-9 * max(1, abs(sorted[k + 1]))) {
        s.permOK = false
    }
    var rank: [Double: Int] = [:]
    for (k, v) in sorted.enumerated() { rank[v] = k }
    for (i, b) in bounds.enumerated() { s.maxDisplacement = max(s.maxDisplacement, abs(i - (rank[b] ?? i))) }
    for k in 0..<max(0, nodes.count - 1) where nodes[k + 1] < nodes[k] { s.nodesDrops += 1 }
    for k in 0..<max(0, incs.count - 1) where !(incs[k + 1] < incs[k]) { s.incNonImproving += 1 }
    return s
}

func solveOnce<E: NodeLPStrategy>(_ strategy: BranchAndBound<E>, _ lp: CompiledLP, threads: Int, reference: Double?) async throws -> Stats {
    var ctx = SolveContext()
    ctx.timeLimit = 90
    ctx.threads = threads
    ctx.metal = .off
    let rec = Recorder()
    ctx.progress = { e in rec.add(e) }
    let t0 = Date()
    let a = try await strategy.solve(lp, context: ctx)
    let flip: Double = lp.sense == .maximize ? -1 : 1
    var s = analyse(rec.events, flip: flip, reference: reference.map { flip * $0 })
    s.wall = Date().timeIntervalSince(t0)
    s.status = "\(a.status)"
    s.objective = a.objectiveValue
    s.finalBound = a.bound
    return s
}

/// Contrast: CP-SAT's shared store drains its events in acceptance order (Portfolio.swift).
func solveCP(_ lp: CompiledLP, workers: Int, reference: Double?) async throws -> Stats {
    var ctx = SolveContext()
    ctx.timeLimit = 90
    ctx.threads = workers
    ctx.metal = .off
    let rec = Recorder()
    ctx.progress = { e in rec.add(e) }
    let t0 = Date()
    let a = try await CPSAT(workers: workers).solve(lp, context: ctx)
    let flip: Double = lp.sense == .maximize ? -1 : 1
    var s = analyse(rec.events, flip: flip, reference: reference.map { flip * $0 })
    s.wall = Date().timeIntervalSince(t0)
    s.status = "\(a.status)"
    s.objective = a.objectiveValue
    s.finalBound = a.bound
    return s
}

func line(_ s: Stats) -> String {
    String(
        format: "%@ status %@ obj %@ bound %@ wall %.2fs | bound events %d stale %d staleThr %d inversions %d maxDisp %d worstDrop %.3g permOK %@ invalid %d staleGapUp %d | nodes ev %d drops %d | inc ev %d nonImp %d | finishedOK %@",
        s.label, s.status, s.objective.map { String(format: "%.10g", $0) } ?? "nil",
        s.finalBound.map { String(format: "%.10g", $0) } ?? "nil", s.wall, s.nBound, s.stale, s.staleThr,
        s.inversions, s.maxDisplacement, s.worstDrop, s.permOK ? "yes" : "NO", s.invalid, s.staleGapUp,
        s.nodesEvents, s.nodesDrops, s.incEvents, s.incNonImproving, s.finishedOK ? "yes" : "NO")
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "repro"
let runs = args.count > 2 ? Int(args[2]) ?? 6 : 6
let names = args.count > 3 ? args[3].split(separator: ",").map(String.init) : ["lseu", "mod008", "p0201", "misc03"]

var cases: [(String, CompiledLP, Double?)] = []
for n in names {
    if let lp = try Corpora.loadMIPLIB3(n) {
        cases.append((n, lp, ReferenceValues.miplib3(named: n)?.optimalObjective))
    } else {
        print("missing corpus file \(n)")
    }
}

struct Totals { var runs = 0; var runsWithStale = 0; var staleEvents = 0; var boundEvents = 0; var permBad = 0; var invalid = 0; var nodesDropRuns = 0; var incBad = 0; var finBad = 0; var wrongObj = 0 }
var totals: [String: Totals] = [:]

func record(_ key: String, _ s: Stats, reference: Double?) {
    var t = totals[key] ?? Totals()
    t.runs += 1
    if s.stale > 0 || s.staleThr > 0 { t.runsWithStale += 1 }
    t.staleEvents += s.staleThr
    t.boundEvents += s.nBound
    if !s.permOK { t.permBad += 1 }
    t.invalid += s.invalid
    if s.nodesDrops > 0 { t.nodesDropRuns += 1 }
    if s.incNonImproving > 0 { t.incBad += 1 }
    if !s.finishedOK { t.finBad += 1 }
    if let reference, let o = s.objective, abs(o - reference) > max(1e-6, 1e-4 * max(1, abs(reference))) { t.wrongObj += 1 }
    totals[key] = t
}

for (name, lp, ref) in cases {
    var configs: [(String, Int, (CompiledLP, Int) async throws -> Stats)] = []
    switch mode {
    case "cpsat":
        configs = [("CPSAT-workers8", 8, { lp, th in try await solveCP(lp, workers: th, reference: ref) })]
    case "control":
        configs = [
            ("P-threads1", 1, { lp, th in try await solveOnce(BranchAndBound(), lp, threads: th, reference: ref) }),
            ("P-det-threads8", 8, { lp, th in try await solveOnce(BranchAndBound(deterministic: true), lp, threads: th, reference: ref) }),
            ("D-threads1", 1, { lp, th in try await solveOnce(BranchAndBound(engine: Simplex(.dual)), lp, threads: th, reference: ref) }),
        ]
    default:
        let t = args.count > 4 ? Int(args[4]) ?? 8 : 8
        configs = [
            ("P-threads\(t)", t, { lp, th in try await solveOnce(BranchAndBound(), lp, threads: th, reference: ref) }),
            ("D-threads\(t)", t, { lp, th in try await solveOnce(BranchAndBound(engine: Simplex(.dual)), lp, threads: th, reference: ref) }),
        ]
    }
    for (cname, th, f) in configs {
        for k in 0..<runs {
            var s = try await f(lp, th)
            s.label = "\(name) \(cname) run \(k):"
            record(cname, s, reference: ref)
            print(line(s))
            for d in s.details { print(d) }
            fflush(stdout)
        }
    }
}
for (key, t) in totals.sorted(by: { $0.key < $1.key }) {
    print("SUMMARY \(mode) \(key): runs \(t.runs) runsWithStaleBound \(t.runsWithStale) staleEvents \(t.staleEvents) of \(t.boundEvents) boundEvents; permutationOfValidSequenceFailed \(t.permBad); boundsAboveOptimum \(t.invalid); runsWithNodesDrop \(t.nodesDropRuns); runsIncNonImproving \(t.incBad); finishedBad \(t.finBad); wrongObjective \(t.wrongObj)")
}
