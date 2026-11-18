// Cycle B, slot F5: directed probes (input domain, overflow, gap, limits, determinism).
import Foundation
import ZTronLPOptimizer

/// Builds a CompiledLP; `cost` is in the model's own sense.
func makeLP(
    xl: [Double], xu: [Double], rows: [(terms: [(Int, Double)], lo: Double, hi: Double)], cost: [Double],
    c0: Double = 0, maximize: Bool = false, integer: [Int]? = nil
) -> CompiledLP {
    let n = xl.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, r) in rows.enumerated() { for (j, v) in r.terms { entries.append((i, j, v)) } }
    let c = maximize ? cost.map { $0 == 0 ? 0 : -$0 } : cost
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c,
        c0: maximize ? (c0 == 0 ? 0 : -c0) : c0, sense: maximize ? .maximize : .minimize,
        xl: xl, xu: xu, rl: rows.map { $0.lo }, ru: rows.map { $0.hi },
        integerColumns: (integer ?? Array(0..<n)).map { Int32($0) })
}

func show(_ name: String, expect: String, _ o: Outcome) {
    let p = o.primal.map { $0.map { v -> String in v == v.rounded() && abs(v) < 1e18 ? String(Int64(v)) : String(v) } } ?? []
    print("[\(name)] expect: \(expect)\n    got: \(statusName(o.status)) obj=\(o.objective.map { String($0) } ?? "nil") bound=\(o.bound.map { String($0) } ?? "nil") x=\(p) \(o.error ?? "") (\(String(format: "%.3f", o.seconds)) s)")
}

let inf = Double.infinity
let p2_48 = 281474976710656.0
let p2_49 = 562949953421312.0
let p2_50 = 1125899906842624.0
let p2_52 = 4503599627370496.0
let p2_53 = 9007199254740992.0

func domainProbes() async {
    let det = CPSAT(lpPropagator: false, deterministic: true)
    let detLP = CPSAT(deterministic: true)
    let par = CPSAT(workers: 4)

    // D1: 1e-6 data (exactly the documented limit), knapsack.
    do {
        let w = [3, 5, 7, 9, 11].map { Double($0) * 1e-6 }
        let v = [4, 6, 9, 11, 13].map { Double($0) * 1e-6 }
        let lp = makeLP(xl: [0, 0, 0, 0, 0], xu: [1, 1, 1, 1, 1], rows: [(Array(zip(0..<5, w)), -inf, 20e-6)], cost: v, maximize: true)
        // enumerate: best value subject to weight <= 20
        var best = 0
        for mask in 0..<32 {
            var ww = 0, vv = 0
            for j in 0..<5 where (mask >> j) & 1 == 1 { ww += [3, 5, 7, 9, 11][j]; vv += [4, 6, 9, 11, 13][j] }
            if ww <= 20 { best = max(best, vv) }
        }
        for (nm, s) in [("det", det), ("detLP", detLP), ("par", par)] {
            show("D1 1e-6 knapsack \(nm)", expect: "optimal \(Double(best) * 1e-6)", await runCP(lp, s))
        }
    }
    // D2: data beyond 1e6 must be rejected.
    for (nm, a) in [("1e-7", 1e-7), ("1.0000001", 1.0000001), ("1e-10", 1e-10), ("5e-10", 5e-10), ("3+5e-10", 3 + 5e-10)] {
        // row a*x >= a, min x : true optimum x = 1 (objective 1)
        let lp = makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, a), (1, a)], a, inf)], cost: [1, 1])
        show("D2 coef \(nm): a*x0 + a*x1 >= a, min x0+x1", expect: "unsupported, or optimal 1", await runCP(lp, det))
    }
    // D2b: tiny perturbation of a coefficient within 1e-9 on a large domain
    do {
        let lp = makeLP(xl: [0, 1e6], xu: [2e6, 1e6], rows: [([(0, 1), (1, -1.0000000009)], 0, inf)], cost: [1, 0])
        show("D2b x - 1.0000000009 y >= 0, y = 1e6, min x", expect: "unsupported or optimal 1000001", await runCP(lp, det))
    }
    // D3: continuous column and infinite bounds.
    do {
        let lp = makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, 1), (1, 1)], 1, inf)], cost: [1, 1], integer: [0])
        show("D3 continuous column", expect: "unsupported", await runCP(lp, det))
        for (nm, lo, hi) in [("[0,inf)", 0.0, inf), ("(-inf,0]", -inf, 0.0), ("free", -inf, inf)] {
            let lp2 = makeLP(xl: [lo, 0], xu: [hi, 1], rows: [([(0, 1), (1, 1)], 1, 5)], cost: [1, 1])
            show("D3 bounds \(nm)", expect: "unsupported", await runCP(lp2, det))
        }
    }
    // D4: bounds near 2^53.
    do {
        let b = p2_53 - 1
        let lp = makeLP(xl: [-b], xu: [b], rows: [], cost: [1])
        show("D4a x in [-(2^53-1), 2^53-1], min x", expect: "optimal -9007199254740991", await runCP(lp, det))
        let lpm = makeLP(xl: [-b], xu: [b], rows: [], cost: [1], maximize: true)
        show("D4b same, max x", expect: "optimal 9007199254740991", await runCP(lpm, det))
        let lp2 = makeLP(xl: [0], xu: [p2_53], rows: [], cost: [1])
        show("D4c ub = 2^53", expect: "unsupported (too large)", await runCP(lp2, det))
        // integer lower bound 2^52 + 1 (exact Double): min x must be 4503599627370497
        let lp3 = makeLP(xl: [p2_52 + 1], xu: [p2_52 + 10], rows: [], cost: [1])
        show("D4d x in [2^52+1, 2^52+10], min x", expect: "optimal 4503599627370497", await runCP(lp3, det))
        let lp3m = makeLP(xl: [p2_52 + 1], xu: [p2_52 + 10], rows: [], cost: [1], maximize: true)
        show("D4e same, max x", expect: "optimal 4503599627370506", await runCP(lp3m, det))
        let lp4 = makeLP(xl: [p2_50 + 3], xu: [p2_50 + 8], rows: [], cost: [1])
        show("D4f x in [2^50+3, 2^50+8], min x", expect: "optimal 1125899906842627", await runCP(lp4, det))
        // row bound at 2^50 + 5 with x free in a wider domain
        let lp5 = makeLP(xl: [0], xu: [p2_50 + 100], rows: [([(0, 1)], -inf, p2_50 + 5)], cost: [1], maximize: true)
        show("D4g max x s.t. x <= 2^50+5", expect: "optimal 1125899906842629", await runCP(lp5, det))
        let lp5b = makeLP(xl: [0], xu: [p2_50 + 100], rows: [([(0, 1)], -inf, p2_50 + 5)], cost: [1], maximize: true)
        show("D4g' same with LP propagator", expect: "optimal 1125899906842629", await runCP(lp5b, detLP))
        // two-variable equality, exact: x - y = 2^52 + 1, x <= 2^52+3, y in [0, 10], min y -> y = 0? x = 2^52+1
        let lp6 = makeLP(xl: [0, 0], xu: [p2_52 + 3, 10], rows: [([(0, 1), (1, -1)], p2_52 + 1, p2_52 + 1)], cost: [1, 0])
        show("D4h x - y = 2^52+1, y in [0,10], x <= 2^52+3, min x", expect: "optimal 4503599627370497 (y=0)", await runCP(lp6, det))
    }
    // D5: large fractional data that only 10^k (k<=6) makes integral, beyond 2^53 after scaling.
    do {
        let a = p2_48 + 0.1875
        let lp = makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, a), (1, -p2_48)], -inf, 0)], cost: [1, 0], maximize: true)
        show("D5a (2^48+0.1875)x - 2^48 y <= 0, max x", expect: "unsupported, or optimal 0 (x=1 infeasible: activity 0.1875)", await runCP(lp, det))
        let a2 = p2_49 + 0.375
        let c2 = -(p2_50 + 0.75)
        let lp2 = makeLP(xl: [0, 0, 0], xu: [1, 1, 1], rows: [([(0, a2), (1, a2), (2, c2)], 0, 0)], cost: [1, 1, 1], maximize: true)
        show("D5b (2^49+.375)(x+y) - (2^50+.75) z = 0, max x+y+z", expect: "unsupported, or optimal 3 (1,1,1 is exactly feasible)", await runCP(lp2, det))
        show("D5b' same, par4 lp", expect: "unsupported, or optimal 3", await runCP(lp2, par))
        let lp3 = makeLP(xl: [0, 0, 0], xu: [1, 1, 1], rows: [([(0, a2), (1, a2), (2, c2)], 0, 0)], cost: [1, 1, 1])
        show("D5c same row, min x+y+z", expect: "optimal 0", await runCP(lp3, det))
        // objective with fraction at 2^49: cost 2^49+0.5, x in {0,1}: max -> objective 562949953421312.5
        let lp4 = makeLP(xl: [0], xu: [1], rows: [], cost: [p2_49 + 0.5], maximize: true)
        show("D5d max (2^49+0.5)x", expect: "unsupported, or optimal 562949953421312.5", await runCP(lp4, det))
    }
    // D6: empty and degenerate models.
    do {
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: 0, cols: 0, []), c: [], c0: 5, xl: [], xu: [], rl: [], ru: [])
        show("D6a n=0 m=0 c0=5", expect: "optimal 5", await runCP(lp, det))
        let lp2 = CompiledLP(a: SparseCSC.fromTriplets(rows: 1, cols: 0, []), c: [], c0: 0, xl: [], xu: [], rl: [1], ru: [inf])
        show("D6b n=0, empty row >= 1", expect: "infeasible", await runCP(lp2, det))
        let lp3 = makeLP(xl: [0.5], xu: [0.5], rows: [], cost: [1])
        show("D6c x fixed at 0.5 (integer)", expect: "infeasible", await runCP(lp3, det))
        let lp4 = makeLP(xl: [0.2, 0], xu: [2.7, 1], rows: [], cost: [1, 1], maximize: true)
        show("D6d x in [0.2,2.7], max x + y", expect: "optimal 3 (x=2,y=1)", await runCP(lp4, det))
        let lp5 = makeLP(xl: [0, 0], xu: [3, 3], rows: [([(0, 2), (1, 4)], 3, 3)], cost: [1, 1])
        show("D6e 2x + 4y = 3", expect: "infeasible", await runCP(lp5, det))
        let lp6 = makeLP(xl: [3, 0], xu: [1, 1], rows: [], cost: [1, 1])
        show("D6f xl > xu", expect: "infeasible", await runCP(lp6, det))
        let lp7 = makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, 1), (1, 1)], 1, 1), ([(0, 1), (1, 1)], 1, 1), ([(0, 2), (1, 2)], 2, 2)], cost: [3, 2])
        show("D6g duplicate/redundant equality rows, min 3x+2y, x+y=1", expect: "optimal 2", await runCP(lp7, detLP))
        let lp8 = makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, 1), (1, 1)], -inf, .nan)], cost: [-1, -1])
        show("D6h row upper NaN (invalid data)", expect: "rejected (unsupported/invalid)", await runCP(lp8, det))
    }
    // D7: activities near 2^61.
    do {
        let big = 511.0
        let lp = makeLP(xl: [0], xu: [p2_52], rows: [([(0, big)], -inf, big * (p2_52 - 7))], cost: [big], maximize: true)
        show("D7a 511 x <= 511(2^52-7), x<=2^52, max 511x (act ~2^61-2^52)", expect: "optimal \(Int64(511) * (Int64(1) << 52 - 7))", await runCP(lp, det))
        show("D7a' with LP", expect: "same", await runCP(lp, detLP))
        let lp2 = makeLP(xl: [0], xu: [p2_52], rows: [([(0, 512)], -inf, 1e18)], cost: [1])
        show("D7b 512 x, x<=2^52 (act 2^61)", expect: "unsupported (activity)", await runCP(lp2, det))
        let lp3 = makeLP(xl: [-p2_52, -p2_52], xu: [p2_52, p2_52], rows: [([(0, 255), (1, -255)], 1, inf)], cost: [1, 1])
        show("D7c 255x - 255y >= 1 over +-2^52 (range 2^62-ish)", expect: "unsupported (activity range)", await runCP(lp3, det))
        // just inside: 127x - 127y >= 1, x,y in [-2^52, 2^52] -> range 4*127*2^52 = 2^61 - 2^54 -> accepted
        let lp4 = makeLP(xl: [-p2_52, -p2_52], xu: [p2_52, p2_52], rows: [([(0, 127), (1, -125)], 1, inf)], cost: [1, 1])
        show("D7d 127x - 125y >= 1, x,y in [-2^52,2^52], min x+y", expect: "optimal (finite) without trap; true opt computed by hand below", await runCP(lp4, det))
        show("D7d' with LP par4", expect: "same", await runCP(lp4, par))
    }
}

func gapProbes() async {
    // G1: integral costs, objective ~1e5 (documented inexact above 1e4), deterministic with a hint.
    do {
        let lp = makeLP(xl: [100_000], xu: [100_010], rows: [], cost: [1])
        var ctx = SolveContext(); ctx.timeLimit = 10; ctx.warmStart = .primalPoint([100_005])
        let r = try? await CPSAT(lpPropagator: false, deterministic: true).solve(lp, context: ctx)
        print("[G1 min y, y in [1e5,1e5+10], hint 1e5+5] expect optimal 100000; got \(statusName(r?.status)) obj \(String(describing: r?.objectiveValue)) bound \(String(describing: r?.bound))")
    }
    // G2: fine-step costs, small objective, no hint: min sum j*1e-6 x_j, sum x_j >= 1.
    for n in [5, 20, 50] {
        let cost = (1...n).map { Double($0) * 1e-6 }
        let lp = makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
                        rows: [(Array(zip(0..<n, [Double](repeating: 1, count: n))), 1, inf)], cost: cost)
        for (nm, s) in [("det-nolp", CPSAT(lpPropagator: false, deterministic: true)), ("det-lp", CPSAT(deterministic: true)), ("par8", CPSAT(workers: 8)), ("default", CPSAT())] {
            let o = await runCP(lp, s)
            print("[G2 n=\(n) \(nm)] min sum j*1e-6 x_j s.t. sum x >= 1; expect optimal 1e-06; got \(statusName(o.status)) obj \(String(describing: o.objective)) bound \(String(describing: o.bound))")
        }
    }
    // G2b: same with a row that is not a clause (2 x_j sum >= 2 is a clause after gcd; use x_j + 2 x_k)
    do {
        let n = 30
        var terms: [(Int, Double)] = []
        for j in 0..<n { terms.append((j, Double(1 + j % 2))) }
        let cost = (1...n).map { Double($0) * 1e-6 }
        let lp = makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rows: [(terms, 2, inf)], cost: cost)
        // optimum: x_1 (weight 2, cost 2e-6) alone, or x_0 + x_2 (1+1, cost 1e-6+3e-6 = 4e-6) -> 2e-6
        for (nm, s) in [("det-nolp", CPSAT(lpPropagator: false, deterministic: true)), ("det-lp", CPSAT(deterministic: true)), ("default", CPSAT())] {
            let o = await runCP(lp, s)
            print("[G2b n=\(n) \(nm)] expect optimal 2e-06; got \(statusName(o.status)) obj \(String(describing: o.objective)) bound \(String(describing: o.bound)) x=\(o.primal.map { $0.enumerated().filter { $0.element > 0 }.map { $0.offset } } ?? [])")
        }
    }
    // G3: 1e-4 step, one step off with a hint.
    do {
        let lp = makeLP(xl: [0, 0], xu: [1, 1], rows: [], cost: [0.0001, 0.0001])
        var ctx = SolveContext(); ctx.timeLimit = 10; ctx.warmStart = .primalPoint([1, 0])
        let r = try? await CPSAT(lpPropagator: false, deterministic: true).solve(lp, context: ctx)
        print("[G3 min 1e-4(x+y), hint (1,0)] expect optimal 0; got \(statusName(r?.status)) obj \(String(describing: r?.objectiveValue)) bound \(String(describing: r?.bound))")
    }
    // G4: integral costs, large constant.
    do {
        let n = 20
        let cost = (1...n).map { Double($0) }
        let lp = makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
                        rows: [(Array(zip(0..<n, [Double](repeating: 1, count: n))), 1, inf)], cost: cost, c0: 1e6)
        for (nm, s) in [("det-nolp", CPSAT(lpPropagator: false, deterministic: true)), ("default", CPSAT())] {
            let o = await runCP(lp, s)
            print("[G4 c0=1e6 \(nm)] min 1e6 + sum j x_j, sum x >= 1; expect 1000001; got \(statusName(o.status)) obj \(String(describing: o.objective)) bound \(String(describing: o.bound))")
        }
    }
    // G5: integral costs, objective just below 1e4: must be exact.
    do {
        let n = 20
        let cost = (1...n).map { Double($0) }
        let lp = makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
                        rows: [(Array(zip(0..<n, [Double](repeating: 1, count: n))), 1, inf)], cost: cost, c0: 9000)
        for (nm, s) in [("det-nolp", CPSAT(lpPropagator: false, deterministic: true)), ("default", CPSAT())] {
            let o = await runCP(lp, s)
            print("[G5 c0=9000 \(nm)] expect 9001; got \(statusName(o.status)) obj \(String(describing: o.objective)) bound \(String(describing: o.bound))")
        }
    }
}

/// Independent check of a returned point against the CompiledLP data (own loops, Double, tight tolerance).
func pointCheck(_ lp: CompiledLP, _ x: [Double]) -> String {
    var worstBound = 0.0, worstRow = 0.0
    var nonInt = 0
    let isInt = Set(lp.integerColumns.map { Int($0) })
    for j in 0..<lp.n {
        worstBound = max(worstBound, lp.xl[j] - x[j], x[j] - lp.xu[j])
        if isInt.contains(j) && x[j] != x[j].rounded() { nonInt += 1 }
    }
    var act = [Double](repeating: 0, count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { act[Int(lp.a.rowIndex[p])] += lp.a.values[p] * x[j] }
    }
    for i in 0..<lp.m { worstRow = max(worstRow, lp.rl[i] - act[i], act[i] - lp.ru[i]) }
    var obj = lp.c0
    for j in 0..<lp.n { obj += lp.c[j] * x[j] }
    if lp.sense == .maximize { obj = -obj }
    return "boundViol \(worstBound) rowViol \(worstRow) nonIntegral \(nonInt) objRecomputed \(obj)"
}

func miplib(_ path: String, _ cfg: String, _ limit: Double) async {
    let url = URL(fileURLWithPath: path)
    let lp: CompiledLP
    do { lp = try MPSFormat.read(contentsOf: url) } catch { print("read error \(error)"); return }
    let s: CPSAT
    switch cfg {
    case "nolp": s = CPSAT(lpPropagator: false)
    case "det": s = CPSAT(deterministic: true)
    case "detnolp": s = CPSAT(lpPropagator: false, deterministic: true)
    default: s = CPSAT()
    }
    let o = await runCP(lp, s, timeLimit: limit)
    let name = url.deletingPathExtension().lastPathComponent
    print("\(name) m=\(lp.m) n=\(lp.n) int=\(lp.integerColumns.count) cfg=\(cfg): \(statusName(o.status)) obj=\(o.objective.map { String($0) } ?? "nil") bound=\(o.bound.map { String($0) } ?? "nil") conflicts=\(o.conflicts) \(String(format: "%.2f", o.seconds)) s \(o.error ?? "")")
    if let x = o.primal { print("   check: \(pointCheck(lp, x))") }
}

func knapsackLP(n: Int, m: Int, seed: UInt64, costScale: Double = 1) -> CompiledLP {
    var rng = RNG(seed)
    var rows: [(terms: [(Int, Double)], lo: Double, hi: Double)] = []
    for _ in 0..<m {
        var terms: [(Int, Double)] = []
        var total = 0
        for j in 0..<n { let w = rng.int(1, 100); total += w; terms.append((j, Double(w))) }
        rows.append((terms, -inf, Double(total / 2)))
    }
    let v = (0..<n).map { _ in Double(rng.int(1, 100)) * costScale }
    return makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rows: rows, cost: v, maximize: true)
}

func pigeonholeLP(holes: Int) -> CompiledLP {
    let pigeons = holes + 1
    var rows: [(terms: [(Int, Double)], lo: Double, hi: Double)] = []
    for p in 0..<pigeons { rows.append(((0..<holes).map { (p * holes + $0, 1.0) }, 1, inf)) }
    for h in 0..<holes { rows.append(((0..<pigeons).map { ($0 * holes + h, 1.0) }, -inf, 1)) }
    let n = pigeons * holes
    return makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rows: rows, cost: [Double](repeating: 0, count: n))
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SolverEvent] = []
    func add(_ e: SolverEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [SolverEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

func solveRecorded(_ lp: CompiledLP, _ s: CPSAT, limit: Double?, threads: Int? = nil, budget: Int? = nil) async -> (CPSATAnalysis?, String?, [SolverEvent], Double) {
    let rec = Recorder()
    var ctx = SolveContext()
    ctx.timeLimit = limit
    ctx.threads = threads
    ctx.memoryBudgetBytes = budget
    ctx.progress = { rec.add($0) }
    let t0 = Date()
    do {
        let r = try await s.solve(lp, context: ctx)
        return (r, nil, rec.all, Date().timeIntervalSince(t0))
    } catch {
        return (nil, "\(error)", rec.all, Date().timeIntervalSince(t0))
    }
}

func normalizedEvents(_ ev: [SolverEvent]) -> [String] {
    ev.map { e in
        if case .finished(let st, _) = e { return "finished(\(statusName(st)))" }
        return "\(e)"
    }
}

func limitProbes() async {
    // L1: time limits on a hard infeasible instance.
    let php = pigeonholeLP(holes: 11)
    for (nm, s, lim) in [("default", CPSAT(), 1.0), ("det", CPSAT(deterministic: true), 1.0), ("nolp8", CPSAT(workers: 8, lpPropagator: false), 2.0), ("default", CPSAT(), 0.0), ("default", CPSAT(), -5.0)] {
        let (r, err, ev, wall) = await solveRecorded(php, s, limit: lim)
        let fin = ev.filter { $0.isFinished }.count
        print("[L1 php11 \(nm) limit \(lim)] status \(statusName(r?.status)) \(err ?? "") wall \(String(format: "%.3f", wall)) s, finished events \(fin), first \(ev.first.map { "\($0)" }?.prefix(20) ?? "-")")
    }
    // L2: cancellation.
    do {
        let s = CPSAT()
        let t0 = Date()
        let task = Task { () -> (CPSATAnalysis?, String?, [SolverEvent], Double) in await solveRecorded(php, s, limit: 30) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let tc = Date()
        task.cancel()
        let (r, err, ev, _) = await task.value
        print("[L2 cancel after 0.3 s] status \(statusName(r?.status)) \(err ?? "") returned \(String(format: "%.3f", Date().timeIntervalSince(tc))) s after cancel (total \(String(format: "%.3f", Date().timeIntervalSince(t0)))), finished events \(ev.filter { $0.isFinished }.count)")
    }
    // L3: determinism, completed runs.
    for (seed, n, m) in [(UInt64(5), 30, 4), (UInt64(6), 40, 3)] {
        let lp = knapsackLP(n: n, m: m, seed: seed)
        for (nm, s) in [("det-lp", CPSAT(deterministic: true)), ("det-nolp", CPSAT(lpPropagator: false, deterministic: true)), ("det-w8", CPSAT(workers: 8, seed: 99, deterministic: true))] {
            var sigs: [String] = []
            var evs: [[String]] = []
            for _ in 0..<3 {
                let (r, err, ev, wall) = await solveRecorded(lp, s, limit: 60)
                guard let r else { sigs.append("error \(err ?? "")"); continue }
                sigs.append("\(statusName(r.status)) obj \(r.objectiveValue ?? .nan) conf \(r.conflicts) dec \(r.decisions) workers \(r.workers) x \(r.primal?.map { Int($0) } ?? []) wall \(String(format: "%.2f", wall))")
                evs.append(normalizedEvents(ev))
            }
            let same = Set(sigs.map { $0.components(separatedBy: " wall")[0] }).count == 1
            let sameEv = Set(evs.map { $0.joined(separator: "|") }).count == 1
            print("[L3 knap seed \(seed) n\(n) m\(m) \(nm)] identical results \(same), identical events \(sameEv): \(sigs[0])")
            if !same { for s in sigs { print("     \(s)") } }
        }
    }
    // L4: portfolio returns the best incumbent it announced; parallel agreement.
    for seed in UInt64(20)..<UInt64(26) {
        let lp = knapsackLP(n: 60, m: 5, seed: seed)
        for lim in [0.3, 3.0] {
            let (r, err, ev, _) = await solveRecorded(lp, CPSAT(workers: 8), limit: lim)
            guard let r else { print("[L4] error \(err ?? "")"); continue }
            var bestEvent = -Double.infinity
            var bestSource = ""
            for e in ev { if case .newIncumbent(let o, _, let src) = e, o > bestEvent { bestEvent = o; bestSource = src } }
            let ok = r.objectiveValue == nil ? bestEvent == -.infinity : (r.objectiveValue! == bestEvent)
            let x = r.primal ?? []
            let check = x.isEmpty ? "-" : pointCheck(lp, x)
            print("[L4 knap60 seed \(seed) limit \(lim)] \(statusName(r.status)) obj \(r.objectiveValue ?? .nan) bound \(r.bound ?? .nan) bestEvent \(bestEvent) from \(bestSource) winning \(r.winningWorker.map { String($0) } ?? "nil") -> \(ok ? "OK" : "MISMATCH") | \(check)")
        }
    }
    // L5: monotone in the time limit for a deterministic run.
    do {
        let lp = knapsackLP(n: 80, m: 6, seed: 31)
        var prev = -Double.infinity
        for lim in [0.1, 0.3, 1.0, 3.0] {
            let (r, err, _, wall) = await solveRecorded(lp, CPSAT(lpPropagator: false, deterministic: true), limit: lim)
            let o = r?.objectiveValue ?? -.infinity
            print("[L5 det-nolp knap80 limit \(lim)] \(statusName(r?.status)) \(err ?? "") obj \(o) bound \(r?.bound ?? .nan) conflicts \(r?.conflicts ?? -1) wall \(String(format: "%.2f", wall)) \(o < prev ? "NOT MONOTONE" : "")")
            prev = max(prev, o)
        }
    }
    // L6: memory budget.
    for b in [1, 50_000, 2_000_000] {
        let (r, err, _, wall) = await solveRecorded(php, CPSAT(workers: 2), limit: 5, budget: b)
        print("[L6 php11 budget \(b)] \(statusName(r?.status)) \(err ?? "") warnings \(r?.warnings ?? []) wall \(String(format: "%.2f", wall))")
    }
    // L7: rejection path keeps the event contract.
    do {
        let lp = makeLP(xl: [0], xu: [inf], rows: [], cost: [1])
        let (_, err, ev, _) = await solveRecorded(lp, CPSAT(), limit: 5)
        print("[L7 rejected model] error \(err ?? "none") events \(normalizedEvents(ev))")
    }
}

// MARK: - Diophantine oracle over wide domains (bisection path)

func egcd(_ a: Int, _ b: Int) -> (Int, Int, Int) {
    if b == 0 { return (a, 1, 0) }
    let (g, x1, y1) = egcd(b, a % b)
    return (g, y1, x1 - (a / b) * y1)
}

/// min x s.t. a x - b y = c, 0 <= x, y <= U (a, b > 0). nil when infeasible.
func diophantineMin(a: Int, b: Int, c: Int, U: Int) -> Int? {
    let (g, s, _) = egcd(a, b)
    if c % g != 0 { return nil }
    let a1 = a / g, b1 = b / g, c1 = c / g
    // a1 x ≡ c1 (mod b1)
    var x0 = 0
    if b1 > 1 {
        let inv = ((s % b1) + b1) % b1
        x0 = (((c1 % b1) + b1) % b1) * inv % b1
    }
    // y = (a1 x - c1) / b1 >= 0  ->  x >= c1 / a1
    var lo = 0
    if c1 > 0 { lo = (c1 + a1 - 1) / a1 }
    var x = x0
    if x < lo { x += ((lo - x + b1 - 1) / b1) * b1 }
    if x > U { return nil }
    let y = (a1 * x - c1) / b1
    if y < 0 || y > U { return nil }
    precondition(a * x - b * y == c)
    return x
}

func diophantineProbes(count: Int, seed: UInt64, verbose: Bool = false, onlyIndex: Int? = nil) async {
    var rng = RNG(seed)
    var fails = 0, limits = 0, exact = 0, gapRegime = 0
    for k in 0..<count {
        let a = rng.int(2, 3000), b = rng.int(2, 3000)
        let c = rng.int(-2000, 2000)
        let U = [1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000][rng.int(0, 3)]
        let truth = diophantineMin(a: a, b: b, c: c, U: U)
        let lp = makeLP(xl: [0, 0], xu: [Double(U), Double(U)], rows: [([(0, Double(a)), (1, Double(-b))], Double(c), Double(c))], cost: [1, 0])
        let (cname, s) = [("default", CPSAT()), ("det-lp", CPSAT(deterministic: true)), ("par4-nolp", CPSAT(workers: 4, lpPropagator: false))][k % 3]
        if verbose { print("solving #\(k) \(cname): \(a)x - \(b)y = \(c), x,y in [0,\(U)], min x; truth \(truth.map { String($0) } ?? "infeasible")") }
        if let only = onlyIndex, only != k { continue }
        if truth == nil && U >= 100_000_000 { print("skip #\(k): infeasible with U=\(U) (B5-04 propagation hang)"); continue }
        let o = await runCP(lp, s, timeLimit: 5)
        if o.seconds > 7 { print("SLOW #\(k) \(cname): \(a)x - \(b)y = \(c), U=\(U): \(String(format: "%.2f", o.seconds)) s with timeLimit 5, status \(statusName(o.status))") }
        if verbose { print("#\(k) \(cname) U=\(U) \(statusName(o.status)) \(String(format: "%.2f", o.seconds)) s") }
        var msg = ""
        switch o.status {
        case .infeasible?:
            if let t = truth { msg = "FALSE INFEASIBLE (x=\(t))" }
        case .optimal?, .feasible?:
            guard let x = o.primal else { msg = "no primal"; break }
            let xi = Int(x[0]), yi = Int(x[1])
            if a * xi - b * yi != c || xi < 0 || yi < 0 || xi > U || yi > U { msg = "INFEASIBLE POINT \(xi),\(yi)"; break }
            guard let t = truth else { msg = "oracle says infeasible but point feasible?!"; break }
            if case .optimal? = o.status, xi != t {
                if Double(t) >= 1e4 { gapRegime += 1 } else { msg = "NON-OPTIMAL .optimal x=\(xi) true \(t)" }
            }
            if let bd = o.bound, bd > Double(t) + 1e-9 { msg += " INVALID BOUND \(bd) > \(t)" }
            if case .feasible? = o.status { limits += 1 }
            if case .optimal? = o.status, xi == t { exact += 1 }
        case .noSolution?:
            limits += 1
        default:
            msg = "status \(statusName(o.status)) \(o.error ?? "")"
        }
        if !msg.isEmpty {
            fails += 1
            print("FAIL #\(k) \(cname): \(a)x - \(b)y = \(c), U=\(U): \(msg)")
        }
    }
    print("dioph seed \(seed): \(count) models, \(exact) exact optimal, \(gapRegime) inexact-in-gap-regime(opt>=1e4), \(limits) limit hits, \(fails) failures")
}

// MARK: - Invariance on medium instances

func invarianceProbes(count: Int, seed: UInt64) async {
    var rng = RNG(seed)
    var fails = 0
    for k in 0..<count {
        let n = rng.int(20, 40), m = rng.int(2, 6)
        // covering/packing mix with general-integer columns, objective < 1e4
        var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: 1, count: n)
        for j in 0..<n where rng.chance(0.3) { xl[j] = Double(rng.int(-3, 0)); xu[j] = xl[j] + Double(rng.int(1, 4)) }
        var rows: [(terms: [(Int, Double)], lo: Double, hi: Double)] = []
        for _ in 0..<m {
            var terms: [(Int, Double)] = []
            var maxAct = 0.0, minAct = 0.0
            for j in 0..<n where rng.chance(0.5) {
                let w = Double(rng.int(-20, 40)); if w == 0 { continue }
                terms.append((j, w))
                maxAct += max(w * xl[j], w * xu[j]); minAct += min(w * xl[j], w * xu[j])
            }
            if terms.isEmpty { continue }
            let mid = (minAct + maxAct) / 2
            switch rng.int(0, 2) {
            case 0: rows.append((terms, -inf, (mid).rounded()))
            case 1: rows.append((terms, (mid * 0.8).rounded(), inf))
            default: rows.append((terms, (mid - 10).rounded(), (mid + 10).rounded()))
            }
        }
        let cost = (0..<n).map { _ in Double(rng.int(-30, 60)) }
        let maximize = rng.chance(0.5)
        let base = makeLP(xl: xl, xu: xu, rows: rows, cost: cost, maximize: maximize)
        // variants
        var variants: [(String, CompiledLP, Bool)] = []   // name, lp, negated objective sense
        let pc = (0..<n).shuffledDet(&rng)
        let pr = (0..<rows.count).shuffledDet(&rng)
        var inv = [Int](repeating: 0, count: n); for (newJ, oldJ) in pc.enumerated() { inv[oldJ] = newJ }
        let prow = pr.map { i in (terms: rows[i].terms.map { (inv[$0.0], $0.1) }, lo: rows[i].lo, hi: rows[i].hi) }
        variants.append(("perm", makeLP(xl: pc.map { xl[$0] }, xu: pc.map { xu[$0] }, rows: prow, cost: pc.map { cost[$0] }, maximize: maximize), false))
        variants.append(("flipsense", makeLP(xl: xl, xu: xu, rows: rows, cost: cost.map { -$0 }, maximize: !maximize), true))
        let scaled = rows.enumerated().map { (i, r) -> (terms: [(Int, Double)], lo: Double, hi: Double) in
            let f = [0.001, 0.01, 0.1, 10.0, 1000.0][i % 5]
            return (r.terms.map { ($0.0, $0.1 * f) }, r.lo * f, r.hi * f)
        }
        variants.append(("rowscale", makeLP(xl: xl, xu: xu, rows: scaled, cost: cost, maximize: maximize), false))
        var redundant = rows
        if rows.count >= 1 { redundant.append(rows[0]); redundant.append((rows[0].terms.map { ($0.0, $0.1 * 2) }, rows[0].lo * 2, rows[0].hi * 2)) }
        variants.append(("duprows", makeLP(xl: xl, xu: xu, rows: redundant, cost: cost, maximize: maximize), false))
        let ref = await runCP(base, CPSAT(), timeLimit: 20)
        guard case .optimal? = ref.status, let refObj = ref.objective else {
            print("#\(k) base: \(statusName(ref.status)) \(ref.error ?? "")")
            if case .infeasible? = ref.status {} else { continue }
            continue
        }
        if abs(refObj) >= 1e4 { continue }
        for (vn, lp, neg) in variants {
            for (cn, s) in [("default", CPSAT()), ("det-lp", CPSAT(deterministic: true))] {
                let o = await runCP(lp, s, timeLimit: 20)
                guard case .optimal? = o.status, let ob = o.objective else {
                    if case .feasible? = o.status { print("limit #\(k) \(vn) \(cn): \(statusName(o.status))"); continue }
                    fails += 1; print("FAIL #\(k) \(vn) \(cn): \(statusName(o.status)) \(o.error ?? "") vs base optimal \(refObj)"); continue
                }
                let expect = neg ? -refObj : refObj
                if abs(ob - expect) > 1e-9 * max(1, abs(expect)) { fails += 1; print("FAIL #\(k) \(vn) \(cn): obj \(ob) vs base \(expect)") }
                if let x = o.primal { let chk = pointCheck(lp, x); if !chk.hasPrefix("boundViol 0.0 rowViol 0.0") && !chk.contains("rowViol -") { print("  point check #\(k) \(vn) \(cn): \(chk)") } }
            }
        }
    }
    print("invariance seed \(seed): \(count) models, \(fails) failures")
}

extension Range where Bound == Int {
    func shuffledDet(_ rng: inout RNG) -> [Int] {
        var a = Array(self)
        if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(0, i)) } }
        return a
    }
}

// MARK: - Minimal reproductions of the findings, with the package's own violation measure

func minimalRepros() async {
    func report(_ tag: String, _ lp: CompiledLP, _ s: CPSAT, truth: String) async {
        let o = await runCP(lp, s, timeLimit: 10)
        var viol = ""
        if let x = o.primal { let v = lp.maxViolation(at: x); viol = "maxViolation(bounds \(v.bounds), rows \(v.rows))" }
        let xs = o.primal.map { $0.map { String(Int64($0)) }.joined(separator: ",") } ?? "-"
        print("[\(tag)] \(statusName(o.status)) obj=\(o.objective.map { String($0) } ?? "nil") bound=\(o.bound.map { String($0) } ?? "nil") x=(\(xs)) \(viol) \(o.error ?? "")\n    truth: \(truth)")
    }
    await report("M1 x in [2^52+1, 2^52+10], min x, CPSAT()", makeLP(xl: [p2_52 + 1], xu: [p2_52 + 10], rows: [], cost: [1]), CPSAT(),
                 truth: "optimal 4503599627370497")
    await report("M1b x in [2^50+3, 2^50+8], min x, CPSAT()", makeLP(xl: [p2_50 + 3], xu: [p2_50 + 8], rows: [], cost: [1]), CPSAT(),
                 truth: "optimal 1125899906842627")
    await report("M2 max x s.t. x <= 2^50+5, x in [0, 2^50+100], CPSAT()", makeLP(xl: [0], xu: [p2_50 + 100], rows: [([(0, 1)], -inf, p2_50 + 5)], cost: [1], maximize: true), CPSAT(),
                 truth: "optimal 1125899906842629")
    await report("M2b x - y = 2^52+1, x in [0,2^52+3], y in [0,10], min x, CPSAT()", makeLP(xl: [0, 0], xu: [p2_52 + 3, 10], rows: [([(0, 1), (1, -1)], p2_52 + 1, p2_52 + 1)], cost: [1, 0]), CPSAT(),
                 truth: "optimal 4503599627370497 (x=2^52+1, y=0)")
    let a2 = p2_49 + 0.375, c2 = -(p2_50 + 0.75)
    let lp3 = makeLP(xl: [0, 0, 0], xu: [1, 1, 1], rows: [([(0, a2), (1, a2), (2, c2)], 0, 0)], cost: [1, 1, 1], maximize: true)
    let v111 = lp3.maxViolation(at: [1, 1, 1])
    await report("M3 (2^49+.375)x + (2^49+.375)y - (2^50+.75)z = 0, binaries, max x+y+z, CPSAT()", lp3, CPSAT(),
                 truth: "optimal 3 at (1,1,1); maxViolation at (1,1,1) = (bounds \(v111.bounds), rows \(v111.rows))")
    await report("M4 1e-10 x0 + 1e-10 x1 >= 1e-10, binaries, min x0+x1, CPSAT()", makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, 1e-10), (1, 1e-10)], 1e-10, inf)], cost: [1, 1]), CPSAT(),
                 truth: "optimal 1, or SolverError.unsupported (README: data no power of 10 <= 1e6 makes integral)")
    let n = 50
    let g2 = makeLP(xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
                    rows: [(Array(zip(0..<n, [Double](repeating: 1, count: n))), 1, inf)], cost: (1...n).map { Double($0) * 1e-6 })
    await report("M5 min sum_{j=1..50} j*1e-6 x_j s.t. sum x_j >= 1, CPSAT()", g2, CPSAT(), truth: "optimal 1e-06 (x_1 = 1)")
    await report("M5b same, CPSAT(deterministic: true)", g2, CPSAT(deterministic: true), truth: "optimal 1e-06")
    await report("M6 max 1e-6*x, x in [0,50], CPSAT(deterministic: true)", makeLP(xl: [0], xu: [50], rows: [], cost: [1e-6], maximize: true), CPSAT(deterministic: true),
                 truth: "optimal 5e-05 (x = 50)")
    await report("M6b same, CPSAT()", makeLP(xl: [0], xu: [50], rows: [], cost: [1e-6], maximize: true), CPSAT(), truth: "optimal 5e-05")
    let w = [3, 5, 7, 9, 11].map { Double($0) * 1e-6 }, v = [4, 6, 9, 11, 13].map { Double($0) * 1e-6 }
    await report("M6c knapsack w=[3,5,7,9,11]e-6 <= 20e-6, max [4,6,9,11,13]e-6 . x, CPSAT(workers: 4)", makeLP(xl: [0, 0, 0, 0, 0], xu: [1, 1, 1, 1, 1], rows: [(Array(zip(0..<5, w)), -inf, 20e-6)], cost: v, maximize: true), CPSAT(workers: 4),
                 truth: "optimal 2.4e-05")
    await report("M7 x - 1.0000000009 y >= 0, y = 1e6, x in [0,2e6], min x, CPSAT()", makeLP(xl: [0, 1e6], xu: [2e6, 1e6], rows: [([(0, 1), (1, -1.0000000009)], 0, inf)], cost: [1, 0]), CPSAT(),
                 truth: "SolverError.unsupported (needs 10^10), or optimal 1000001")
    await report("M7b (2^48+0.1875)x - 2^48 y <= 0, binaries, max x, CPSAT()", makeLP(xl: [0, 0], xu: [1, 1], rows: [([(0, p2_48 + 0.1875), (1, -p2_48)], -inf, 0)], cost: [1, 0], maximize: true), CPSAT(),
                 truth: "SolverError.unsupported (10^4 scaling exceeds 2^53), or optimal 0")
    await report("M8 x in [0, 2^53-1], max x, CPSAT()", makeLP(xl: [0], xu: [p2_53 - 1], rows: [], cost: [1], maximize: true), CPSAT(),
                 truth: "README 2.5: rejected only for magnitude 2^53 or more -> accepted; optimal 9007199254740991")
    await report("M8b x in [0, 2^53-5], max x, CPSAT()", makeLP(xl: [0], xu: [p2_53 - 5], rows: [], cost: [1], maximize: true), CPSAT(),
                 truth: "accepted; optimal 9007199254740987")
}

/// One equality a x - b y = c over [0, U]^2 with a chosen configuration and time limit.
func pingPong(a: Double, b: Double, c: Double, U: Double, cfg: String, limit: Double, budget: Int?) async {
    let lp = makeLP(xl: [0, 0], xu: [U, U], rows: [([(0, a), (1, -b)], c, c)], cost: [1, 0])
    let s: CPSAT
    switch cfg {
    case "default": s = CPSAT()
    case "det": s = CPSAT(deterministic: true)
    case "detnolp": s = CPSAT(lpPropagator: false, deterministic: true)
    case "nolp4": s = CPSAT(workers: 4, lpPropagator: false)
    default: s = CPSAT(workers: Int(cfg) ?? 1)
    }
    let (r, err, ev, wall) = await solveRecorded(lp, s, limit: limit, budget: budget)
    print("[pingpong \(a)x - \(b)y = \(c), U=\(U), cfg \(cfg), timeLimit \(limit), budget \(budget.map { String($0) } ?? "default")] \(statusName(r?.status)) \(err ?? "") wall \(String(format: "%.2f", wall)) s, conflicts \(r?.conflicts ?? -1), propagations \(r?.propagations ?? -1), events \(ev.count)")
}
