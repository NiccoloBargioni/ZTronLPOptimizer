// Cycle A, slot V101: contract sceptic for finding A4-04 (bound := incumbent on a completed
// search that pruned by the gap). Independent of the finder's probe: own instances, own
// brute-force oracle, every solve under SolveContext.timeLimit.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let INF = Double.infinity
let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "all"

/// Maximisation knapsack-style model built from dense rows; `p` in the model's own sense.
/// Columns listed in `continuous` are not integer.
func model(p: [Double], rows: [[Double]], ru: [Double], xu: [Double], continuous: Set<Int> = []) -> CompiledLP {
    let n = p.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() { for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) } }
    let ints = (0..<n).filter { !continuous.contains($0) }.map { Int32($0) }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: p.map { -$0 }, sense: .maximize,
        xl: [Double](repeating: 0, count: n), xu: xu, rl: [Double](repeating: -INF, count: rows.count), ru: ru,
        integerColumns: ints)
}

/// Brute force over 0/1 integer columns; a continuous column with zero row coefficients and
/// a positive profit is simply set to its upper bound (only that shape is used here).
func bruteMax(p: [Double], rows: [[Double]], ru: [Double], xu: [Double], continuous: Set<Int> = []) -> (Double, [Double]) {
    let n = p.count
    let ints = (0..<n).filter { !continuous.contains($0) }
    var best = -INF
    var bestX: [Double] = []
    for mask in 0..<(1 << ints.count) {
        var x = [Double](repeating: 0, count: n)
        for (t, j) in ints.enumerated() where mask & (1 << t) != 0 { x[j] = 1 }
        for j in continuous {
            precondition(rows.allSatisfy { $0[j] == 0 } && p[j] >= 0)
            x[j] = xu[j]
        }
        var ok = true
        for (i, row) in rows.enumerated() {
            var s = 0.0
            for j in 0..<n { s += row[j] * x[j] }
            if s > ru[i] + 1e-9 { ok = false; break }
        }
        guard ok else { continue }
        var v = 0.0
        for j in 0..<n { v += p[j] * x[j] }
        if v > best { best = v; bestX = x }
    }
    return (best, bestX)
}

func f(_ v: Double?) -> String { v.map { String(format: "%.9g", $0) } ?? "nil" }

func ctx(_ threads: Int? = nil) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 30
    c.threads = threads
    return c
}

struct Line { var status: SolveStatus; var obj: Double?; var bound: Double?; var gap: Double?; var nodes: Int; var open: Int; var hist: [String] }

func report(_ label: String, _ a: some SolutionAnalysis, gap: Double?, nodes: Int, open: Int, hist: [IncumbentEvent], opt: Double, rel: Double, abs absGap: Double) -> Bool {
    let obj = a.objectiveValue ?? .nan
    let b = a.bound ?? .nan
    let slack = max(absGap, rel * max(1, Swift.abs(obj)))
    // Maximisation: a valid (proven) bound is >= the true optimum.
    let boundValid = b >= opt - 1e-9 * max(1, Swift.abs(opt))
    let trueGap = (opt - obj) / max(1, Swift.abs(obj))
    let withinGap = opt - obj <= slack + 1e-9
    print("  \(label): status \(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(gap)) | opt \(f(opt)) trueRelGap \(String(format: "%.3e", trueGap)) incumbentWithinGap \(withinGap) boundValid \(boundValid) nodes \(nodes) open \(open) hist \(hist.map { "\($0.source)@\($0.node):\(f($0.objective))" })")
    return boundValid
}

func runAll(_ name: String, _ lp: CompiledLP, opt: Double, rel: Double, absGap: Double = 1e-6) async throws -> (valid: Int, invalid: Int) {
    print("[\(name)] Gap(relative: \(rel), absolute: \(absGap)) enumerated optimum \(f(opt))")
    var valid = 0, invalid = 0
    let g = Gap(relative: rel, absolute: absGap)
    func tally(_ ok: Bool) { if ok { valid += 1 } else { invalid += 1 } }
    let p = try await BranchAndBound(gap: g).solve(lp, context: ctx())
    tally(report("P default", p, gap: p.gap, nodes: p.nodesProcessed, open: p.nodesOpen, hist: p.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    let p1 = try await BranchAndBound(gap: g).solve(lp, context: ctx(1))
    tally(report("P 1 thread", p1, gap: p1.gap, nodes: p1.nodesProcessed, open: p1.nodesOpen, hist: p1.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    let d = try await BranchAndBound(engine: Simplex(.dual), gap: g, deterministic: true).solve(lp, context: ctx())
    tally(report("D det", d, gap: d.gap, nodes: d.nodesProcessed, open: d.nodesOpen, hist: d.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    let i = try await BranchAndBound(engine: InteriorPoint(), gap: g).solve(lp, context: ctx())
    tally(report("IPM", i, gap: i.gap, nodes: i.nodesProcessed, open: i.nodesOpen, hist: i.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    let n = try await BranchAndBound(heuristics: .none, gap: g).solve(lp, context: ctx())
    tally(report("P no heuristics", n, gap: n.gap, nodes: n.nodesProcessed, open: n.nodesOpen, hist: n.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    let s = try await BranchAndBound(branching: .mostFractional, nodeSelection: .bestBound, heuristics: Heuristics(rounding: true, diving: false), gap: g).solve(lp, context: ctx())
    tally(report("P mostFractional/bestBound/rounding only", s, gap: s.gap, nodes: s.nodesProcessed, open: s.nodesOpen, hist: s.incumbentHistory, opt: opt, rel: rel, abs: absGap))
    return (valid, invalid)
}

// Hand-made 3-item knapsack: A(w 10), B(w 10), C(w 11), capacity 21. Root LP takes A, B and
// 1/11 of C; rounding gives A+B; the optimum is A+C.
let rows3: [[Double]] = [[10, 10, 11]]
let ru3: [Double] = [21]
let xu3: [Double] = [1, 1, 1]

if mode == "all" || mode == "tiny" {
    // (1) Non-decimal profits: objectiveStep = 0, pruning uses the gap's slack.
    let pND = [10.5 + 1e-7 * 2.0.squareRoot(), 10.4 + 1e-7 * 3.0.squareRoot(), 11.0 + 1e-7 * 5.0.squareRoot()]
    let (o1, x1) = bruteMax(p: pND, rows: rows3, ru: ru3, xu: xu3)
    print("tiny non-decimal: optimum \(f(o1)) at \(x1)")
    let lp1 = model(p: pND, rows: rows3, ru: ru3, xu: xu3)
    for rel in [0.05, 0.03, 0.01] { _ = try await runAll("tiny non-decimal", lp1, opt: o1, rel: rel) }

    // (2) Same knapsack, integral profits 105/104/110, plus one continuous column y in [0,1]
    // with profit 0.5 and no row entries: an ordinary MILP with a continuous objective term.
    let pC = [105.0, 104, 110, 0.5]
    let rowsC: [[Double]] = [[10, 10, 11, 0]]
    let xuC: [Double] = [1, 1, 1, 1]
    let (o2, x2) = bruteMax(p: pC, rows: rowsC, ru: ru3, xu: xuC, continuous: [3])
    print("tiny integral + continuous column: optimum \(f(o2)) at \(x2)")
    let lp2 = model(p: pC, rows: rowsC, ru: ru3, xu: xuC, continuous: [3])
    _ = try await runAll("tiny integral+continuous", lp2, opt: o2, rel: 0.05)

    // (3) Control: integral profits only (objectiveStep > 0): which close reason, which bound?
    let pI = [105.0, 104, 110]
    let (o3, _) = bruteMax(p: pI, rows: rows3, ru: ru3, xu: xu3)
    let lp3 = model(p: pI, rows: rows3, ru: ru3, xu: xu3)
    _ = try await runAll("tiny integral (control)", lp3, opt: o3, rel: 0.05)
}

// The finder's near-tie family, re-implemented here (same generator calls), with an own
// brute-force oracle.
func nearTie(seed: UInt64, n: Int = 14, delta: Double = 2e-5) -> (CompiledLP, [Double], [[Double]], [Double]) {
    var rng = SeededGenerator(seed: seed &+ 99)
    let w = (0..<n).map { _ in Double(rng.integer(in: 20...90)) }
    let w2 = (0..<n).map { _ in Double(rng.integer(in: 1...40)) }
    let p = w.map { $0 * (1 + rng.uniform(in: 0...delta)) * 10 }
    let cap = (w.reduce(0, +) * 0.5).rounded(.down) + 0.5
    let cap2 = (w2.reduce(0, +) * 0.6).rounded(.down)
    let rows = [w, w2]
    let ru = [cap, cap2]
    return (model(p: p, rows: rows, ru: ru, xu: [Double](repeating: 1, count: n)), p, rows, ru)
}

if mode == "all" || mode == "neartie" {
    let (lp, p, rows, ru) = nearTie(seed: 15)
    let (opt, _) = bruteMax(p: p, rows: rows, ru: ru, xu: [Double](repeating: 1, count: p.count))
    _ = try await runAll("near-tie seed 15", lp, opt: opt, rel: 0.05)
    _ = try await runAll("near-tie seed 15", lp, opt: opt, rel: 1e-4)
}

if mode == "all" || mode == "count" {
    // Default BranchAndBound() over 30 seeds: how often is the reported bound below the optimum?
    var invalid = 0, runs = 0, zeroGapWrong = 0, outside = 0
    for seed in 0..<UInt64(30) {
        let (lp, p, rows, ru) = nearTie(seed: seed)
        let (opt, _) = bruteMax(p: p, rows: rows, ru: ru, xu: [Double](repeating: 1, count: p.count))
        for threads in [nil, 1] as [Int?] {
            let a = try await BranchAndBound().solve(lp, context: ctx(threads))
            runs += 1
            guard let obj = a.objectiveValue, let b = a.bound else { print("seed \(seed): \(a.status)"); continue }
            let slack = max(1e-6, 1e-4 * max(1, abs(obj)))
            if opt - obj > slack + 1e-9 { outside += 1 }
            if b < opt - 1e-9 * max(1, abs(opt)) {
                invalid += 1
                if (a.gap ?? 1) == 0 { zeroGapWrong += 1 }
                if invalid <= 6 { print("seed \(seed) threads \(threads.map(String.init) ?? "auto"): \(a.status) obj \(f(obj)) bound \(f(b)) gap \(f(a.gap)) opt \(f(opt)) diff \(opt - obj) nodes \(a.nodesProcessed)") }
            }
        }
    }
    print("COUNT default gap: runs \(runs) boundBelowOptimum \(invalid) (with gap==0: \(zeroGapWrong)) incumbentOutsideGap \(outside)")
}
