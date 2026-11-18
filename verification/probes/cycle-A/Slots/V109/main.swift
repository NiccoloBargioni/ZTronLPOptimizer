// Cycle A, slot V109: sceptic of finding A4-07 (lpIterations adds 25 estimated pivots per
// strong-branched candidate instead of the probes' real pivots).
//
// Independent oracle: a NodeLPStrategy wrapper that delegates every call to `Simplex`
// unchanged (same arguments, same return values, so the search is the same) and records the
// real pivots of every root, node and probe run. A probe's real pivot count is read from the
// engine's analysis of its last run (`Simplex.rootAnalysis(_:worker:)` describes
// `worker.lastOutcome`, which the probe's run has just set).
//
// Usage: V109 tiny
//        V109 miplib <det|par> [instance ...]     (default: the nine instances other than stein45)
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "tiny"

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var rootRuns = 0, rootIters = 0
    private var nodeRuns = 0, nodeIters = 0
    private var probeRuns = 0, probeIters = 0, probeCapped = 0, probeMax = 0
    private var probeHist: [Int: Int] = [:]

    func root(_ k: Int) { lock.lock(); rootRuns += 1; rootIters += k; lock.unlock() }
    func node(_ k: Int) { lock.lock(); nodeRuns += 1; nodeIters += k; lock.unlock() }
    func probe(_ k: Int, cap: Int) {
        lock.lock()
        probeRuns += 1; probeIters += k
        if k >= cap { probeCapped += 1 }
        probeMax = Swift.max(probeMax, k)
        probeHist[k, default: 0] += 1
        lock.unlock()
    }
    struct Snapshot {
        var rootRuns = 0, rootIters = 0, nodeRuns = 0, nodeIters = 0
        var probeRuns = 0, probeIters = 0, probeCapped = 0, probeMax = 0
        var probeHist: [Int: Int] = [:]
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            rootRuns: rootRuns, rootIters: rootIters, nodeRuns: nodeRuns, nodeIters: nodeIters,
            probeRuns: probeRuns, probeIters: probeIters, probeCapped: probeCapped, probeMax: probeMax,
            probeHist: probeHist)
    }
}

struct CountingSimplex: NodeLPStrategy {
    typealias State = Basis
    typealias Worker = SimplexEngine
    typealias Analysis = SimplexAnalysis
    let inner: Simplex
    let tally: Tally

    var engineName: String { "Counting<\(inner.engineName)>" }

    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SimplexAnalysis {
        try await inner.solve(problem, context: context)
    }
    func makeWorker(lp: CompiledLP, context: SolveContext) -> SimplexEngine {
        inner.makeWorker(lp: lp, context: context)
    }
    func solveRoot(_ w: inout SimplexEngine, gate: inout WorkGate) async throws -> NodeLPResult<Basis> {
        let r = try await inner.solveRoot(&w, gate: &gate)
        tally.root(r.iterations)
        return r
    }
    func solveNode(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, cutoff: Double?,
        iterationLimit: Int, gate: inout WorkGate
    ) async throws -> NodeLPResult<Basis> {
        let r = try await inner.solveNode(
            &w, changes: changes, parent: parent, cutoff: cutoff, iterationLimit: iterationLimit, gate: &gate)
        tally.node(r.iterations)
        return r
    }
    func probe(
        _ w: inout SimplexEngine, changes: [BoundChange], parent: Basis, iterationLimit: Int,
        gate: inout WorkGate
    ) async throws -> Double? {
        let bound = try await inner.probe(&w, changes: changes, parent: parent, iterationLimit: iterationLimit, gate: &gate)
        // The engine's own analysis of its last run, which is this probe's.
        let last = inner.rootAnalysis(NodeLPResult(outcome: .limit, state: parent, iterations: -1), worker: w)
        tally.probe(last.iterations, cap: iterationLimit)
        return bound
    }
    func rootAnalysis(_ result: NodeLPResult<Basis>, worker: borrowing SimplexEngine) -> SimplexAnalysis {
        inner.rootAnalysis(result, worker: worker)
    }
}

struct Measured {
    var status: String
    var objective: Double?
    var nodes: Int
    var reported: Int
    var t: Tally.Snapshot
    var seconds: Double
    var candidates: Int { t.probeRuns / 2 }
    var realNodeWork: Int { t.rootIters + t.nodeIters }
    var formula: Int { realNodeWork + candidates * 2 * 50 / 4 }  // what TreeSearch.runProbes adds
    var realTotal: Int { realNodeWork + t.probeIters }
}

func measure(
    _ lp: CompiledLP, method: Simplex.Method, branching: BranchingRule = .pseudocost(reliability: 4),
    heuristics: Heuristics = .default, deterministic: Bool, threads: Int? = nil, timeLimit: Double
) async throws -> Measured {
    let tally = Tally()
    let engine = CountingSimplex(inner: Simplex(method), tally: tally)
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    if let threads { ctx.threads = threads }
    let started = Date()
    let a = try await BranchAndBound(
        engine: engine, branching: branching, heuristics: heuristics, deterministic: deterministic
    ).solve(lp, context: ctx)
    return Measured(
        status: "\(a.status)", objective: a.objectiveValue, nodes: a.nodesProcessed, reported: a.lpIterations,
        t: tally.snapshot(), seconds: Date().timeIntervalSince(started))
}

func tiny() async throws {
    // min -x - 0.1 y  s.t.  2x + y <= 1,  x in {0,1},  y in [0,1].
    // Hand derivation (oracle): root LP x = 0.5, y = 0, objective -0.5 (one pivot: x enters).
    // Strong branching on x from the root basis with the dual method:
    //   down (x <= 0): x leaves above its bound; ratios d_y/|alpha| = 0.4/0.5 = 0.8 and
    //                  d_s/|alpha| = 0.5/0.5 = 1, so y enters: 1 pivot, y = 1, objective -0.1.
    //   up   (x >= 1): x must rise, which needs y or the slack to fall below 0: no entering
    //                  column, infeasible after 0 pivots.
    // So the strong-branching probes of this model cost 1 real pivot in total.
    let entries: [(row: Int, col: Int, value: Double)] = [(0, 0, 2), (0, 1, 1)]
    let lp = CompiledLP(
        a: SparseCSC.fromTriplets(rows: 1, cols: 2, entries), c: [-1, -0.1], sense: .minimize,
        xl: [0, 0], xu: [1, 1], rl: [-.infinity], ru: [1], integerColumns: [0])
    print("tiny model: min -x - 0.1y, 2x + y <= 1, x binary, y in [0,1]; hand-derived probe pivots: down 1, up 0")
    for (name, rule) in [
        ("mostFractional", BranchingRule.mostFractional), ("strong(1)", .strong(candidates: 1)),
        ("pseudocost(4)", .pseudocost(reliability: 4)),
    ] {
        for method in [Simplex.Method.primal, .dual] {
            let r = try await measure(
                lp, method: method, branching: rule, heuristics: .none, deterministic: true, threads: 1, timeLimit: 10)
            print(
                "\(name) \(method == .primal ? "P" : "D"): \(r.status) obj \(r.objective.map { "\($0)" } ?? "-") nodes \(r.nodes)"
                    + " | reported lpIterations \(r.reported)"
                    + " | real: root \(r.t.rootIters) (\(r.t.rootRuns) run) + nodes \(r.t.nodeIters) (\(r.t.nodeRuns) runs)"
                    + " + probes \(r.t.probeIters) (\(r.t.probeRuns) runs, hist \(r.t.probeHist.sorted { $0.key < $1.key }))"
                    + " = \(r.realTotal)"
                    + " | real nodes + 25 x \(r.candidates) candidates = \(r.formula)"
                    + " | reported == formula: \(r.reported == r.formula), reported == real: \(r.reported == r.realTotal)")
        }
    }
}

func miplib() async throws {
    let det = args.count > 2 && args[2] == "det"
    var names = Array(args.dropFirst(3))
    if names.isEmpty { names = ["p0033", "stein27", "enigma", "lseu", "mod008", "flugpl", "egout", "misc03", "p0201"] }
    print("MIPLIB 3, default BranchAndBound (pseudocost(4), plunging, default heuristics), \(det ? "deterministic" : "parallel (as the benchmark)")")
    print("cols: instance engine status nodes | reported lpIterations | real root+node | candidates x25 | real probe pivots (runs, capped at 50, max) | real total | reported - formula | estimate share of reported | reported/real")
    var sums: [String: (rep: Int, real: Int)] = [:]
    var ratios: [(String, Double, Double)] = []
    for name in names {
        guard let lp = try Corpora.loadMIPLIB3(name) else { print("\(name): not fetched"); continue }
        var pair: [Simplex.Method: Measured] = [:]
        for method in [Simplex.Method.primal, .dual] {
            let r = try await measure(lp, method: method, deterministic: det, timeLimit: 120)
            pair[method] = r
            let tag = method == .primal ? "P" : "D"
            let est = r.candidates * 25
            print(
                "\(name) \(tag) \(r.status) obj \(r.objective.map { String(format: "%.4f", $0) } ?? "-") nodes \(r.nodes)"
                    + " | rep \(r.reported) | realNodes \(r.realNodeWork) | cand \(r.candidates) x25 = \(est)"
                    + " | probes \(r.t.probeIters) (\(r.t.probeRuns) runs, \(r.t.probeCapped) capped, max \(r.t.probeMax), mean/cand \(r.candidates > 0 ? String(format: "%.2f", Double(r.t.probeIters) / Double(r.candidates)) : "-"))"
                    + " | realTotal \(r.realTotal) | rep-formula \(r.reported - r.formula)"
                    + " | est share \(String(format: "%.1f%%", 100 * Double(est) / Double(max(1, r.reported))))"
                    + " | rep/real \(String(format: "%.3f", Double(r.reported) / Double(max(1, r.realTotal))))"
                    + " | \(String(format: "%.2f", r.seconds)) s")
            var s = sums[tag] ?? (0, 0)
            s.rep += r.reported; s.real += r.realTotal
            sums[tag] = s
        }
        if let p = pair[.primal], let d = pair[.dual] {
            let rep = Double(p.reported) / Double(max(1, d.reported))
            let real = Double(p.realTotal) / Double(max(1, d.realTotal))
            ratios.append((name, rep, real))
            print("\(name) ratio P/D: reported \(String(format: "%.2f", rep)), real pivots \(String(format: "%.2f", real))")
        }
    }
    for (tag, s) in sums.sorted(by: { $0.key < $1.key }) {
        print("SUM \(tag): reported \(s.rep), real \(s.real), reported/real \(String(format: "%.3f", Double(s.rep) / Double(max(1, s.real))))")
    }
    if !ratios.isEmpty {
        let rep = ratios.map(\.1), real = ratios.map(\.2)
        print("RATIO RANGE P/D: reported \(String(format: "%.2f", rep.min()!))-\(String(format: "%.2f", rep.max()!)), real \(String(format: "%.2f", real.min()!))-\(String(format: "%.2f", real.max()!))")
    }
}

/// Sanity check: plain `Simplex` engines, deterministic, so nodes and lpIterations can be
/// compared with the wrapped runs of `miplib det` (the wrapper must not change the search).
func plain() async throws {
    for name in args.dropFirst(2) {
        guard let lp = try Corpora.loadMIPLIB3(name) else { print("\(name): not fetched"); continue }
        var ctx = SolveContext()
        ctx.timeLimit = 120
        let p = try await BranchAndBound(deterministic: true).solve(lp, context: ctx)
        let d = try await BranchAndBound(engine: Simplex(.dual), deterministic: true).solve(lp, context: ctx)
        print("\(name) plain det: P \(p.status) nodes \(p.nodesProcessed) lpIterations \(p.lpIterations) | D \(d.status) nodes \(d.nodesProcessed) lpIterations \(d.lpIterations)")
    }
}

switch mode {
case "tiny": try await tiny()
case "miplib": try await miplib()
case "plain": try await plain()
default: print("unknown mode \(mode)")
}
