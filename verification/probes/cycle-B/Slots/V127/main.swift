// Cycle B, slot V127: independent reproduction of finding B5-03 (CP-SAT stop rule with
// fine-step decimal costs and |objective| < 1). Oracles: hand derivation, exhaustive
// enumeration in integer arithmetic, the same model with integral (x10^e) costs, and
// BranchAndBound with a zero gap. Usage: V127 hand | step | rand [models] [seed]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Integer models and their exact optimum

/// A pure integer model with integer data; the objective is k / 10^e.
struct IntIP {
    var lb: [Int]
    var ub: [Int]
    var rows: [(a: [Int], lo: Int?, hi: Int?)]
    var k: [Int]          // integer costs in the model's own sense
    var maximize: Bool

    var n: Int { lb.count }

    func feasible(_ x: [Int]) -> Bool {
        for j in 0..<n where x[j] < lb[j] || x[j] > ub[j] { return false }
        for r in rows {
            var s = 0
            for j in 0..<n { s += r.a[j] * x[j] }
            if let lo = r.lo, s < lo { return false }
            if let hi = r.hi, s > hi { return false }
        }
        return true
    }

    func value(_ x: [Int]) -> Int { (0..<n).reduce(0) { $0 + k[$1] * x[$1] } }

    /// Exhaustive enumeration: best integer objective in the model's sense, and how many points.
    func brute() -> (best: Int?, points: Int, argbest: [Int]?) {
        var x = lb
        var best: Int? = nil
        var arg: [Int]? = nil
        var points = 0
        while true {
            points += 1
            if feasible(x) {
                let v = value(x)
                if best == nil || (maximize ? v > best! : v < best!) { best = v; arg = x }
            }
            var j = 0
            while j < n {
                if x[j] < ub[j] { x[j] += 1; break }
                x[j] = lb[j]
                j += 1
            }
            if j == n { break }
        }
        return (best, points, arg)
    }

    /// The model with costs k_j / 10^e, as a CompiledLP (c in minimization form).
    func compiled(costExponent e: Int) -> CompiledLP {
        let p = Foundation.pow(10.0, Double(e))
        let cost = k.map { Double($0) / p }
        var entries: [(row: Int, col: Int, value: Double)] = []
        for (i, r) in rows.enumerated() {
            for j in 0..<n where r.a[j] != 0 { entries.append((row: i, col: j, value: Double(r.a[j]))) }
        }
        let c = maximize ? cost.map { $0 == 0 ? 0 : -$0 } : cost
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c, c0: 0,
            sense: maximize ? .maximize : .minimize,
            xl: lb.map(Double.init), xu: ub.map(Double.init),
            rl: rows.map { $0.lo.map(Double.init) ?? -.infinity }, ru: rows.map { $0.hi.map(Double.init) ?? .infinity },
            integerColumns: (0..<n).map { Int32($0) })
    }

    /// The objective step k-gcd / 10^e.
    func step(costExponent e: Int) -> Double {
        var g = 0
        for v in k where v != 0 {
            var a = abs(v), b = g
            while b != 0 { (a, b) = (b, a % b) }
            g = a
        }
        return Double(g) / Foundation.pow(10.0, Double(e))
    }
}

// MARK: - Running engines

struct Out {
    var status: SolveStatus?
    var obj: Double?
    var bound: Double?
    var x: [Double]?
    var err: String?
    var conflicts: Int?
    var secs: Double
}

func st(_ s: SolveStatus?) -> String { s.map { "\($0)" } ?? "THROW" }
func isOptimal(_ s: SolveStatus?) -> Bool { if case .optimal? = s { return true } else { return false } }

func runCP(_ lp: CompiledLP, _ s: CPSAT, limit: Double = 10) async -> Out {
    var ctx = SolveContext()
    ctx.timeLimit = limit
    let t0 = Date()
    do {
        let r = try await s.solve(lp, context: ctx)
        return Out(status: r.status, obj: r.objectiveValue, bound: r.bound, x: r.primal, err: nil,
                   conflicts: r.conflicts, secs: Date().timeIntervalSince(t0))
    } catch {
        return Out(status: nil, obj: nil, bound: nil, x: nil, err: "\(error)", conflicts: nil, secs: Date().timeIntervalSince(t0))
    }
}

func runBB(_ lp: CompiledLP, gap: Gap, limit: Double = 10) async -> Out {
    var ctx = SolveContext()
    ctx.timeLimit = limit
    let t0 = Date()
    do {
        let r = try await BranchAndBound(gap: gap, deterministic: true).solve(lp, context: ctx)
        return Out(status: r.status, obj: r.objectiveValue, bound: r.bound, x: r.primal, err: nil,
                   conflicts: nil, secs: Date().timeIntervalSince(t0))
    } catch {
        return Out(status: nil, obj: nil, bound: nil, x: nil, err: "\(error)", conflicts: nil, secs: Date().timeIntervalSince(t0))
    }
}

func fmt(_ o: Out) -> String {
    let xs = o.x.map { v in v.enumerated().filter { $0.element != 0 }.map { "x\($0.offset)=\(Int($0.element))" }.joined(separator: ",") } ?? "-"
    return "\(st(o.status)) obj=\(o.obj.map { "\($0)" } ?? "nil") bound=\(o.bound.map { "\($0)" } ?? "nil") nz[\(xs)]\(o.err.map { " ERR \($0)" } ?? "")"
}

let configs: [(String, CPSAT)] = [
    ("CPSAT()", CPSAT()),
    ("det", CPSAT(deterministic: true)),
    ("det-noLP", CPSAT(lpPropagator: false, deterministic: true)),
    ("workers4", CPSAT(workers: 4)),
    ("w1-seed7", CPSAT(workers: 1, seed: 7)),
]

// MARK: - Hand-derived cases

/// max x/10^e, x in Z ∩ [0, 50]: optimum 50/10^e at x = 50 (no rows).
let boxMax = IntIP(lb: [0], ub: [50], rows: [], k: [1], maximize: true)
/// min Σ_{j=1..50} j x_j / 10^e, Σ x_j ≥ 1, binary: optimum 1/10^e (x_1 alone).
let cover50 = IntIP(lb: [Int](repeating: 0, count: 50), ub: [Int](repeating: 1, count: 50),
                    rows: [(a: [Int](repeating: 1, count: 50), lo: 1, hi: nil)], k: Array(1...50), maximize: false)
/// A 6-item knapsack of my own: max v·x, w·x ≤ 13, binary.
let knap6 = IntIP(lb: [Int](repeating: 0, count: 6), ub: [Int](repeating: 1, count: 6),
                  rows: [(a: [2, 3, 4, 5, 6, 7], lo: nil, hi: 13)], k: [3, 4, 6, 7, 8, 10], maximize: true)

func hand(repeats: Int) async {
    for (name, m) in [("boxMax", boxMax), ("cover50", cover50), ("knap6", knap6)] {
        let truthInt: Int
        if name == "cover50" {
            truthInt = 1  // by hand: every feasible point has some x_j = 1, cost ≥ j ≥ 1; x_1 alone attains 1
        } else {
            let b = m.brute()
            truthInt = b.best!
            print("[\(name)] enumeration: \(b.points) points, best integer objective \(b.best!) at \(b.argbest!)")
        }
        for e in [0, 6] {
            let lp = m.compiled(costExponent: e)
            let truth = Double(truthInt) / Foundation.pow(10.0, Double(e))
            print("[\(name) e=\(e)] step \(m.step(costExponent: e)) truth \(truth)")
            for (cn, s) in configs {
                var seen: [String: Int] = [:]
                for _ in 0..<repeats {
                    let o = await runCP(lp, s)
                    let tag = fmt(o) + ((o.obj.map { abs($0 - truth) > 0.5 * m.step(costExponent: e) } ?? false) ? "  <-- != truth" : "")
                    seen[tag, default: 0] += 1
                }
                for (k, v) in seen.sorted(by: { $0.key < $1.key }) { print("    \(cn) x\(v): \(k)") }
            }
            let bbExact = await runBB(lp, gap: Gap(relative: 0, absolute: 0))
            print("    BranchAndBound(gap 0): \(fmt(bbExact))")
            let bbDefault = await runBB(lp, gap: Gap())
            print("    BranchAndBound(default gap): \(fmt(bbDefault))")
        }
    }
}

// MARK: - Step regime: where exactness breaks

func stepRegime() async {
    for (name, m, truthInt) in [("boxMax", boxMax, 50), ("cover50", cover50, 1)] {
        for e in 0...6 {
            let lp = m.compiled(costExponent: e)
            let p = Foundation.pow(10.0, Double(e))
            let truth = Double(truthInt) / p
            let stepV = m.step(costExponent: e)
            var line = "[\(name) e=\(e) step=\(stepV) truth=\(truth) doc-exact=\(1e-4 * abs(truth) < stepV)]"
            for (cn, s) in configs.prefix(3) {
                let o = await runCP(lp, s)
                let off = o.obj.map { abs($0 - truth) / stepV } ?? .nan
                line += " \(cn): \(st(o.status)) obj=\(o.obj.map { "\($0)" } ?? "nil") (\(Int(off.rounded())) steps off)"
            }
            print(line)
        }
    }
}

// MARK: - Random small models against exhaustive enumeration

struct SplitMix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
}

func randomIP(_ g: inout SplitMix) -> IntIP {
    let n = g.int(2, 5)
    var lb: [Int] = [], ub: [Int] = []
    for _ in 0..<n {
        let l = g.int(-2, 0)
        lb.append(l)
        ub.append(l + g.int(1, 4))
    }
    // A random point of the box stays feasible, so every model has a solution.
    let x0 = (0..<n).map { g.int(lb[$0], ub[$0]) }
    var rows: [(a: [Int], lo: Int?, hi: Int?)] = []
    for _ in 0..<g.int(0, 3) {
        let a = (0..<n).map { _ in g.int(0, 9) < 7 ? g.int(-6, 6) : 0 }
        let s0 = (0..<n).reduce(0) { $0 + a[$1] * x0[$1] }
        switch g.int(0, 2) {
        case 0: rows.append((a: a, lo: nil, hi: s0 + g.int(0, 3)))
        case 1: rows.append((a: a, lo: s0 - g.int(0, 3), hi: nil))
        default: rows.append((a: a, lo: s0 - g.int(0, 2), hi: s0 + g.int(0, 2)))
        }
    }
    var k = (0..<n).map { _ in g.int(-9, 9) }
    if k.allSatisfy({ $0 == 0 }) { k[0] = 1 }
    return IntIP(lb: lb, ub: ub, rows: rows, k: k, maximize: g.int(0, 1) == 1)
}

func randomCampaign(models: Int, seed: UInt64) async {
    var g = SplitMix(s: seed)
    let exps = [0, 3, 4, 5, 6]
    let cfgs = Array(configs.prefix(3))
    // [exp][cfg] counters
    var solves = [[Int]](repeating: [Int](repeating: 0, count: cfgs.count), count: exps.count)
    var optimal = solves, wrong = solves, wrongWithinFormula = solves, wrongDocExact = solves, other = solves, better = solves
    var boundEqObj = solves, boundInvalid = solves
    var examples: [String] = []
    var perExp: [Int: Int] = [:]
    for mi in 0..<models {
        let m = randomIP(&g)
        let b = m.brute()
        guard let bestInt = b.best else { continue }
        for (ei, e) in exps.enumerated() {
            let lp = m.compiled(costExponent: e)
            let p = Foundation.pow(10.0, Double(e))
            let truth = Double(bestInt) / p
            let stepV = m.step(costExponent: e)
            for (ci, (cn, s)) in cfgs.enumerated() {
                let o = await runCP(lp, s)
                solves[ei][ci] += 1
                guard isOptimal(o.status), let obj = o.obj else { other[ei][ci] += 1; continue }
                optimal[ei][ci] += 1
                if let bd = o.bound, bd == obj { boundEqObj[ei][ci] += 1 }
                // Bound validity (model sense): a max bound must be ≥ truth, a min bound ≤ truth.
                if let bd = o.bound, (m.maximize ? bd < truth - 0.5 * stepV : bd > truth + 0.5 * stepV) { boundInvalid[ei][ci] += 1 }
                // Point check in integers.
                if let x = o.x {
                    let xi = x.map { Int($0.rounded()) }
                    if !m.feasible(xi) || m.value(xi) != Int((obj * p).rounded()) {
                        examples.append("POINT MISMATCH model \(mi) e=\(e) \(cn): \(fmt(o))")
                    }
                }
                let worse = m.maximize ? obj < truth - 0.5 * stepV : obj > truth + 0.5 * stepV
                let improves = m.maximize ? obj > truth + 0.5 * stepV : obj < truth - 0.5 * stepV
                if improves { better[ei][ci] += 1; examples.append("BETTER THAN TRUTH model \(mi) e=\(e) \(cn): \(fmt(o)) truth \(truth)") }
                if worse {
                    wrong[ei][ci] += 1
                    // README risk 10 formula, model units: |incumbent − truth| ≤ max(1e-6, 1e-4·max(1,|incumbent|)).
                    if abs(obj - truth) <= max(1e-6, 1e-4 * max(1, abs(obj))) * (1 + 1e-12) { wrongWithinFormula[ei][ci] += 1 }
                    // CPSAT doc: exact whenever 1e-4·|objective| < step (checked at both the reported and the true value).
                    if 1e-4 * max(abs(obj), abs(truth)) < stepV { wrongDocExact[ei][ci] += 1 }
                    perExp[e, default: 0] += 1
                    if perExp[e]! <= 3 {
                        examples.append("model \(mi) e=\(e) \(cn): \(fmt(o)) truth \(truth) (\(Int((abs(obj - truth) / stepV).rounded())) steps) step \(stepV) \(m.maximize ? "max" : "min") k=\(m.k)")
                    }
                }
            }
        }
    }
    print("random campaign: \(models) models, seed \(seed)")
    for (ei, e) in exps.enumerated() {
        for (ci, (cn, _)) in cfgs.enumerated() {
            print("  e=\(e) \(cn): solves \(solves[ei][ci]) optimal \(optimal[ei][ci]) NON-OPTIMAL-.optimal \(wrong[ei][ci]) (within README formula \(wrongWithinFormula[ei][ci]); where doc says exact \(wrongDocExact[ei][ci])) better-than-truth \(better[ei][ci]) not-optimal-status \(other[ei][ci]) bound==obj \(boundEqObj[ei][ci]) invalid-bound \(boundInvalid[ei][ci])")
        }
    }
    for x in examples { print("  " + x) }
}

// MARK: - Threshold: max x/1e6, x in [0, U]; the first incumbent x = 1 is accepted iff (U − 1)·1e-6 ≤ 1e-4

func threshold() async {
    for u in [50, 100, 101, 102, 103, 150, 1000, 1_000_000] {
        let m = IntIP(lb: [0], ub: [u], rows: [], k: [1], maximize: true)
        let lp = m.compiled(costExponent: 6)
        var line = "[max x/1e6, x in [0,\(u)]] truth \(Double(u) / 1e6) range-minus-step \(Double(u - 1) / 1e6) <= 1e-4: \(Double(u - 1) / 1e6 <= 1e-4)"
        for (cn, s) in configs.prefix(3) {
            let o = await runCP(lp, s)
            line += " | \(cn): \(st(o.status)) obj=\(o.obj.map { "\($0)" } ?? "nil") bound=\(o.bound.map { "\($0)" } ?? "nil")"
        }
        print(line)
    }
}

// MARK: - Entry

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "hand"
switch mode {
case "hand": await hand(repeats: args.count > 2 ? Int(args[2]) ?? 3 : 3)
case "step": await stepRegime()
case "thresh": await threshold()
case "rand": await randomCampaign(models: args.count > 2 ? Int(args[2]) ?? 200 : 200, seed: args.count > 3 ? UInt64(args[3]) ?? 1 : 1)
default: print("usage: V127 hand [repeats] | step | rand [models] [seed]")
}
