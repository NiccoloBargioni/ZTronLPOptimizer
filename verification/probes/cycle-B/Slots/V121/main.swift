// V121 - cycle B sceptic, REPRODUCE lens, finding B5-01 (CP-SAT widens bounds >= 2^50).
//
// Independent of the finder's probe:
//   * models are built through the typed DSL (LPModel + compile), not by hand as CompiledLP;
//   * the oracle is exact Int64 enumeration of the integer feasible set (or the trivial
//     analytic optimum of a single unconstrained column), and the returned point is checked
//     in exact Int64 arithmetic - CompiledLP.maxViolation and CPSAT.violation are not used;
//   * a second engine (Automatic -> BranchAndBound) runs on the same compiled problems;
//   * every CP-SAT case runs under several configurations and repeats (seeded, deterministic,
//     parallel) to show the effect does not depend on load or randomness.
// Run: perl -e 'alarm shift; exec @ARGV' 600 .build/release/V121

import Foundation
import ZTronLPOptimizer

enum V: LPVariable { case x, y }

let P20: Int64 = 1 << 20
let P30: Int64 = 1 << 30
let P49: Int64 = 1 << 49
let P50: Int64 = 1 << 50
let P51: Int64 = 1 << 51
let P52: Int64 = 1 << 52
let P53: Int64 = 1 << 53

struct Row { var a: [Int64]; var lo: Int64?; var hi: Int64? }
enum Truth { case infeasible; case optimal(Int64, [Int64]) }

struct Case {
    let tag: String
    let lb: [Int64]
    let ub: [Int64]
    let rows: [Row]
    let cost: [Int64]          // all zero: a feasibility model with no objective
    let maximize: Bool
    let configs: [String]
    var truth: Truth? = nil            // hand-derived optimum when the domain is too wide to enumerate
    var lowerSingletons: Bool = true   // CompileOptions.lowerSingletonConstraints
}

// MARK: - Exact Int64 oracle

func mul(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.multipliedReportingOverflow(by: b)
    return o ? nil : r
}

func dot(_ a: [Int64], _ p: [Int64]) -> Int64? {
    var s: Int64 = 0
    for k in a.indices {
        guard let t = mul(a[k], p[k]) else { return nil }
        let (r, o) = s.addingReportingOverflow(t)
        if o { return nil }
        s = r
    }
    return s
}

/// Largest violation of the case's bounds and rows at p, in exact integers (0 = feasible).
func exactViolation(_ c: Case, _ p: [Int64]) -> (bounds: Int64, rows: Int64) {
    var vb: Int64 = 0
    for j in p.indices { vb = max(vb, c.lb[j] - p[j], p[j] - c.ub[j]) }
    var vr: Int64 = 0
    for r in c.rows {
        guard let act = dot(r.a, p) else { return (vb, Int64.max) }
        if let lo = r.lo { vr = max(vr, lo - act) }
        if let hi = r.hi { vr = max(vr, act - hi) }
    }
    return (vb, vr)
}

func oracle(_ c: Case) -> Truth {
    if let t = c.truth {
        // A hand-derived optimum: check that its point is exactly feasible before trusting it.
        if case .optimal(let o, let p) = t {
            let v = exactViolation(c, p)
            precondition(v.bounds == 0 && v.rows == 0 && dot(c.cost, p) == o, "hand truth not feasible")
        }
        return t
    }
    let n = c.lb.count
    var size: Int64 = 1
    for j in 0..<n { size = size.multipliedReportingOverflow(by: c.ub[j] - c.lb[j] + 1).partialValue; if size > 2_000_000 || size <= 0 { size = Int64.max; break } }
    if size == Int64.max {
        // Only used for one column, no rows: min/max of cost*x over [lb, ub] is at an end.
        precondition(n == 1 && c.rows.isEmpty)
        let wantHigh = (c.cost[0] > 0) == c.maximize
        let best = wantHigh ? c.ub[0] : c.lb[0]
        return .optimal(c.cost[0] * best, [best])
    }
    var bestObj: Int64? = nil
    var bestPt: [Int64] = []
    func consider(_ p: [Int64]) {
        let v = exactViolation(c, p)
        guard v.bounds == 0 && v.rows == 0 else { return }
        let o = dot(c.cost, p)!
        if bestObj == nil || (c.maximize ? o > bestObj! : o < bestObj!) { bestObj = o; bestPt = p }
    }
    if n == 1 {
        var x = c.lb[0]; while x <= c.ub[0] { consider([x]); x += 1 }
    } else {
        var x = c.lb[0]
        while x <= c.ub[0] {
            var y = c.lb[1]; while y <= c.ub[1] { consider([x, y]); y += 1 }
            x += 1
        }
    }
    if let o = bestObj { return .optimal(o, bestPt) }
    return .infeasible
}

// MARK: - DSL model

func build(_ c: Case) -> LPModel<V> {
    let vars: [V] = c.lb.count == 1 ? [.x] : [.x, .y]
    var model = LPModel<V>()
    for (k, v) in vars.enumerated() {
        model = model.integer(v).bounding(v, Bounds(lower: Double(c.lb[k]), upper: Double(c.ub[k])))
    }
    if c.cost.contains(where: { $0 != 0 }) {
        var e = LinearExpr<V>()
        for (k, v) in vars.enumerated() where c.cost[k] != 0 { e.add(v, Double(c.cost[k])) }
        model = c.maximize ? model.maximizing(e) : model.minimizing(e)
    }
    if c.tag.hasPrefix("E1") {
        var e = LinearExpr<V>()
        e.add(.x, 0.5); e.add(.y, 0.5)
        let rhs = Double(P49) + 2.5
        precondition(rhs * 2 == Double(P50 + 5))
        model = model.subjectTo(e <= rhs)
    }
    // E1: the solver gets 0.5x + 0.5y <= 2^49+2.5; the oracle checks the same set as x + y <= 2^50+5 (exact).
    for r in c.rows where !c.tag.hasPrefix("E1") {
        var e = LinearExpr<V>()
        for (k, v) in vars.enumerated() where r.a[k] != 0 { e.add(v, Double(r.a[k])) }
        let con: LinearConstraint<V>
        if let lo = r.lo, let hi = r.hi, lo == hi {
            con = (e == Double(lo))
        } else if let hi = r.hi {
            precondition(r.lo == nil)
            con = (e <= Double(hi))
        } else {
            con = (e >= Double(r.lo!))
        }
        model = model.subjectTo(con)
    }
    return model
}

func strategy(_ name: String) -> CPSAT {
    switch name {
    case "default": return CPSAT()
    case "det": return CPSAT(deterministic: true)
    case "det-nolp": return CPSAT(lpPropagator: false, deterministic: true)
    case "w4-nolp-s7": return CPSAT(workers: 4, lpPropagator: false, seed: 7)
    case "w8-s99": return CPSAT(workers: 8, seed: 99)
    default: fatalError(name)
    }
}

func fmt(_ v: Int64) -> String {
    // Express v as 2^k + d for readability when close to a power of two.
    for k in [49, 50, 51, 52, 53] {
        let p = Int64(1) << Int64(k)
        if abs(v - p) <= 64 { return "\(v) (2^\(k)\(v - p >= 0 ? "+" : "")\(v - p))" }
        if abs(v + p) <= 64 { return "\(v) (-2^\(k)\(v + p >= 0 ? "+" : "")\(v + p))" }
    }
    return "\(v)"
}

func exactPoint(_ primal: [Double]?, _ cm: CompiledModel<V>, _ n: Int) -> [Int64]? {
    guard let primal else { return nil }
    let vars: [V] = n == 1 ? [.x] : [.x, .y]
    var p: [Int64] = []
    for v in vars {
        guard let j = cm.column[v], j < primal.count, let iv = Int64(exactly: primal[j]) else { return nil }
        p.append(iv)
    }
    return p
}

func isSuccess(_ s: SolveStatus) -> Bool {
    switch s {
    case .optimal, .feasible: return true
    default: return false
    }
}

var wrongCount = 0
var totalCP = 0

// MARK: - Root-cause arithmetic (replicates the expression at CPModel.swift:173-174 for display only)

print("== snap arithmetic: v, ulp(v), tol=max(1e-9,4ulp), ceil(v-tol), floor(v+tol)")
for v in [P49 + 3, P50 + 3, P50 + 5, P51 + 3, P52, P52 + 1, P52 + 10, P53 - 5, -(P52 + 1)] {
    let d = Double(v)
    precondition(Int64(exactly: d) == v, "not exact in Double")
    let tol = max(1e-9, 4 * d.ulp)
    print("  \(fmt(v)): ulp \(d.ulp) tol \(tol) -> lower \(fmt(Int64((d - tol).rounded(.up)))) upper \(fmt(Int64((d + tol).rounded(.down))))")
}

// MARK: - Cases

let cpAll = ["default", "default", "default", "det", "det", "det-nolp", "w4-nolp-s7", "w8-s99"]
let cpNoClimb = ["default", "default", "default", "det", "det", "w4-nolp-s7", "w8-s99"]

let cases: [Case] = [
    Case(tag: "A0 control x in [2^49+3, 2^49+8], min x", lb: [P49 + 3], ub: [P49 + 8], rows: [], cost: [1], maximize: false, configs: cpAll),
    Case(tag: "A1 x in [2^50+3, 2^50+8], min x", lb: [P50 + 3], ub: [P50 + 8], rows: [], cost: [1], maximize: false, configs: cpAll),
    Case(tag: "A2 x in [2^51+3, 2^51+8], min x", lb: [P51 + 3], ub: [P51 + 8], rows: [], cost: [1], maximize: false, configs: cpAll),
    Case(tag: "A3 x in [2^52+1, 2^52+10], min x", lb: [P52 + 1], ub: [P52 + 10], rows: [], cost: [1], maximize: false, configs: cpAll),
    Case(tag: "A4 x in [0, 2^53-5], max x", lb: [0], ub: [P53 - 5], rows: [], cost: [1], maximize: true, configs: cpNoClimb),
    Case(tag: "A5 x in [-(2^52+10), -(2^52+1)], max x", lb: [-(P52 + 10)], ub: [-(P52 + 1)], rows: [], cost: [1], maximize: true, configs: cpAll),
    Case(tag: "B1 x in [2^52+1,2^52+10], y in [0,5], x + y <= 2^52 (no objective; truly infeasible)",
         lb: [P52 + 1, 0], ub: [P52 + 10, 5], rows: [Row(a: [1, 1], lo: nil, hi: P52)], cost: [0, 0], maximize: false, configs: cpAll),
    Case(tag: "B5 x in [2^50+3,2^50+8], y in [0,5], x + y <= 2^50+2 (no objective; truly infeasible)",
         lb: [P50 + 3, 0], ub: [P50 + 8, 5], rows: [Row(a: [1, 1], lo: nil, hi: P50 + 2)], cost: [0, 0], maximize: false, configs: cpAll),
    Case(tag: "B2 x in [2^52+1,2^52+10], y in [0,100], x - y = 2^52, min y (true optimum 1)",
         lb: [P52 + 1, 0], ub: [P52 + 10, 100], rows: [Row(a: [1, -1], lo: P52, hi: P52)], cost: [0, 1], maximize: false, configs: cpAll),
    Case(tag: "B3 x in [2^50+3,2^50+8], y in [0,100], x - y = 2^50, min y (true optimum 3)",
         lb: [P50 + 3, 0], ub: [P50 + 8, 100], rows: [Row(a: [1, -1], lo: P50, hi: P50)], cost: [0, 1], maximize: false, configs: cpAll),
    Case(tag: "B4 x in [2^20,2^20+1], y in [0,100], 2^30 x + y <= 2^50+5, max y (small bounds; only the row is large; true optimum 5)",
         lb: [P20, 0], ub: [P20 + 1, 100], rows: [Row(a: [P30, 1], lo: nil, hi: P50 + 5)], cost: [0, 1], maximize: true, configs: cpAll),
    // The finder's M2b, with a hand oracle: x = 2^52+1+y and x <= 2^52+3 force y in [0,2]; min x = 2^52+1 at y = 0.
    Case(tag: "C1 (finder M2b) x in [0,2^52+3], y in [0,10], x - y = 2^52+1, min x",
         lb: [0, 0], ub: [P52 + 3, 10], rows: [Row(a: [1, -1], lo: P52 + 1, hi: P52 + 1)], cost: [1, 0], maximize: false,
         configs: cpAll, truth: .optimal(P52 + 1, [P52 + 1, 0])),
    // The finder's D4g': a singleton ROW (not lowered to a bound), max x.
    Case(tag: "C2 (finder D4g') x in [2^50, 2^50+10], row x <= 2^50+5 kept as a row, max x",
         lb: [P50], ub: [P50 + 10], rows: [Row(a: [1], lo: nil, hi: P50 + 5)], cost: [1], maximize: true,
         configs: cpAll, truth: .optimal(P50 + 5, [P50 + 5]), lowerSingletons: false),
    // The finder's 127x - 125y >= 1 over [-2^52, 2^52]; min y = -2^52 (x = 2^52 satisfies the row).
    Case(tag: "C3 (finder) x,y in [-2^52, 2^52], 127x - 125y >= 1, min y",
         lb: [-P52, -P52], ub: [P52, P52], rows: [Row(a: [127, -125], lo: 1, hi: nil)], cost: [0, 1], maximize: false,
         configs: cpAll, truth: .optimal(-P52, [P52, -P52])),
    // Scope probes beyond the finder's: a row bound reached only through per-row scaling, and a row bound in [2^53, 2^61].
    Case(tag: "E1 x in [2^50-8, 2^50-1], y in [0,100], 0.5x + 0.5y <= 2^49+2.5 (scaled rhs 2^50+5), max y (true 13)",
         lb: [P50 - 8, 0], ub: [P50 - 1, 100], rows: [Row(a: [1, 1], lo: nil, hi: P50 + 5)], cost: [0, 1], maximize: true, configs: cpAll),
    Case(tag: "E2 x in [2^40, 2^40+1], y in [0,100], 2^20 x + y <= 2^60 (activity within 2^61), max y (true 0)",
         lb: [1 << 40, 0], ub: [(1 << 40) + 1, 100], rows: [Row(a: [1 << 20, 1], lo: nil, hi: 1 << 60)], cost: [0, 1], maximize: true, configs: cpAll),
    // README: only magnitudes of 2^53 or more are rejected. 2^53-1 is below that.
    Case(tag: "D1 x in [0, 2^53-1], min x (README: accepted, below 2^53)", lb: [0], ub: [P53 - 1], rows: [], cost: [1], maximize: false,
         configs: ["det"], truth: .optimal(0, [0])),
]

let args = CommandLine.arguments
var selected = cases
if args.count >= 4 && args[1] == "repeat" {
    // repeat <tag prefix> <config> <N>: one case, one configuration, N runs.
    let n = Int(args.count >= 5 ? args[4] : "20") ?? 20
    selected = cases.filter { $0.tag.hasPrefix(args[2]) }.map { c in
        Case(tag: c.tag, lb: c.lb, ub: c.ub, rows: c.rows, cost: c.cost, maximize: c.maximize,
             configs: Array(repeating: args[3], count: n), truth: c.truth, lowerSingletons: c.lowerSingletons)
    }
}
for c in selected {
    print("\n== \(c.tag)")
    let truth = oracle(c)
    switch truth {
    case .infeasible: print("  exact oracle (enumeration): INFEASIBLE")
    case .optimal(let o, let p): print("  exact oracle: optimal obj \(fmt(o)) at \(p.map(fmt))")
    }
    let model = build(c)
    let cm: CompiledModel<V>
    var opts = CompileOptions()
    opts.lowerSingletonConstraints = c.lowerSingletons
    do { cm = try model.compile(options: opts) } catch { print("  compile threw: \(error)"); continue }
    let lp = cm.lp
    let exactIn = lp.xl.allSatisfy { Int64(exactly: $0) != nil } && lp.xu.allSatisfy { Int64(exactly: $0) != nil }
    print("  compiled: n=\(lp.n) m=\(lp.m) xl=\(lp.xl.map { Int64(exactly: $0).map(fmt) ?? "\($0)" }) xu=\(lp.xu.map { Int64(exactly: $0).map(fmt) ?? "\($0)" }) rl=\(lp.rl) ru=\(lp.ru) exactIntegers=\(exactIn)")

    var seen: [String: Int] = [:]
    for name in c.configs + ["Automatic"] {
        var ctx = SolveContext()
        ctx.timeLimit = 10
        let t0 = Date()
        var status: SolveStatus? = nil
        var primal: [Double]? = nil
        var obj: Double? = nil
        var err: String? = nil
        do {
            if name == "Automatic" {
                let r = try await Automatic().solve(lp, context: ctx)
                status = r.status; primal = r.primal; obj = r.objectiveValue
            } else {
                let r = try await strategy(name).solve(lp, context: ctx)
                status = r.status; primal = r.primal; obj = r.objectiveValue
            }
        } catch { err = "\(error)" }
        let secs = Date().timeIntervalSince(t0)
        var line = "  [\(name)] "
        var key = ""
        var wrong = false
        if let err { line += "THREW \(err)" } else if let status {
            line += "status \(status)"
            key = "\(status)"
            if let p = exactPoint(primal, cm, c.lb.count) {
                key += " \(p)"
                let v = exactViolation(c, p)
                line += " x=\(p.map(fmt)) obj=\(obj.map { String(format: "%.1f", $0) } ?? "nil") exactViolation(bounds \(v.bounds), rows \(v.rows))"
                if isSuccess(status) && (v.bounds > 0 || v.rows > 0) { wrong = true; line += " <- INFEASIBLE POINT" }
                if case .optimal = status, case .optimal(let to, _) = truth, let obj, obj != Double(to) {
                    // Documented MIP gap (README Gap / CPSAT doc): relative 1e-4, absolute 1e-6.
                    let better = c.maximize ? obj > Double(to) : obj < Double(to)
                    let diff = abs(obj - Double(to))
                    if better && diff > 1e-6 {
                        wrong = true; line += " <- SUPER-OPTIMAL objective \(obj) vs exact optimum \(to)"
                    } else if !better && diff > max(1e-6, 1e-4 * max(abs(obj), abs(Double(to)))) {
                        wrong = true; line += " <- objective \(obj) beyond the MIP gap of exact optimum \(to)"
                    } else {
                        line += " (objective \(diff) short of the exact optimum: within the documented gap)"
                    }
                }
                if isSuccess(status), case .infeasible = truth { wrong = true; line += " <- model is infeasible" }
            } else if let primal {
                line += " primal (non-integral) \(primal)"
            } else {
                line += " (no point)"
                if case .optimal = truth, case .infeasible = status { wrong = true; line += " <- false infeasible" }
            }
        }
        line += String(format: " (%.2f s)", secs)
        print(line)
        if name != "Automatic" {
            totalCP += 1
            if wrong { wrongCount += 1 }
            if err != nil { key = "threw" }
            seen[key, default: 0] += 1
        }
    }
    print("  distinct CP-SAT outcomes across configs/repeats: \(seen.count) \(seen)")
}
print("\n== CP-SAT runs judged wrong by the exact oracle: \(wrongCount) of \(totalCP)")
