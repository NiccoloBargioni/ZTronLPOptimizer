// Slot V124 — cycle B sceptic, REPRODUCE lens, finding B5-02 (CP-SAT data scaling).
//
// Independent of the finder's probe:
//   * models are built with the public DSL (LPModel + compile), not with CompiledLP(...) directly;
//   * ORACLE 1 enumerates every integer point of the column box and evaluates rows and objective
//     in exact dyadic arithmetic (Int128) on the very Doubles that were given — no tolerance;
//   * ORACLE 2 applies the README §2.5 rule literally (decimal digits of the shortest
//     round-trip representation -> smallest 10^k, k <= 6, scaled magnitude < 2^53);
//   * second engine: BranchAndBound(engine: Simplex(.primal)), deterministic;
//   * every CP-SAT configuration is run 3 times (deterministic, parallel, seeded, no LP).
// Run: .build/release/V124 [all|cases|sweep|portfolio]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let two48 = 281474976710656.0
let two49 = 562949953421312.0
let two50 = 1125899906842624.0
let two53 = 9007199254740992.0
let inf = Double.infinity

enum Iv: LPVariable, Hashable {
    case v(Int)
    var domain: VariableDomain { .integer }
}

struct Row { var coefs: [Double]; var lo: Double; var hi: Double }
struct Case {
    var tag: String
    var lower: [Int64]
    var upper: [Int64]
    var binary: Bool
    var rows: [Row]
    var cost: [Double]     // in the model's own sense
    var maximize: Bool
    var n: Int { lower.count }
}

func makeModel(_ c: Case) -> LPModel<Iv> {
    let n = c.n
    let objective = sum(over: 0..<n) { c.cost[$0] * Iv.v($0) }
    var m = c.maximize ? LPModel<Iv>().maximizing(objective) : LPModel<Iv>().minimizing(objective)
    for (i, r) in c.rows.enumerated() {
        let e = sum(over: 0..<n) { r.coefs[$0] * Iv.v($0) }
        let con: LinearConstraint<Iv>
        if r.lo == r.hi { con = (e == r.lo) } else if r.hi.isInfinite { con = (e >= r.lo) } else { con = (e <= r.hi) }
        m = m.subjectTo(con.named("c\(i + 1)"))
    }
    for j in 0..<n {
        if c.binary { m = m.binary(.v(j)) } else { m = m.bounding(.v(j), .range(Double(c.lower[j])...Double(c.upper[j]))) }
    }
    return m
}

// MARK: - ORACLE 1: exact enumeration in dyadic Int128 arithmetic

@available(macOS 15.0, *)
enum Exact {
    /// d == m * 2^e exactly, m odd (or 0).
    static func split(_ d: Double) -> (m: Int128, e: Int) {
        if d == 0 { return (0, 0) }
        precondition(d.isFinite && d.isNormal)
        var m = Int128(d.significandBitPattern | (UInt64(1) << 52))
        var e = Int(d.exponent) - 52
        while m & 1 == 0 { m >>= 1; e += 1 }
        return (d.sign == .minus ? -m : m, e)
    }
    /// values[i] == ints[i] * 2^minE exactly.
    static func common(_ values: [Double]) -> (ints: [Int128], minE: Int) {
        let parts = values.map(split)
        let minE = parts.filter { $0.m != 0 }.map(\.e).min() ?? 0
        let ints = parts.map { p -> Int128 in
            guard p.m != 0 else { return 0 }
            let s = p.e - minE
            precondition(s <= 66, "exponent spread too large")
            return p.m << s
        }
        return (ints, minE)
    }
    static func dot(_ a: [Int128], _ x: [Int64]) -> Int128 {
        var t: Int128 = 0
        for k in a.indices where a[k] != 0 {
            let (p, o1) = a[k].multipliedReportingOverflow(by: Int128(x[k]))
            let (s, o2) = t.addingReportingOverflow(p)
            precondition(!o1 && !o2, "Int128 overflow")
            t = s
        }
        return t
    }
    struct ExactRow { var a: [Int128]; var lo: Int128?; var hi: Int128? }
    static func rows(_ c: Case) -> [ExactRow] {
        c.rows.map { r in
            var vals = r.coefs
            if r.lo.isFinite { vals.append(r.lo) }
            if r.hi.isFinite { vals.append(r.hi) }
            let (ints, _) = common(vals)
            var k = c.n
            var lo: Int128? = nil, hi: Int128? = nil
            if r.lo.isFinite { lo = ints[k]; k += 1 }
            if r.hi.isFinite { hi = ints[k] }
            return ExactRow(a: Array(ints[0..<c.n]), lo: lo, hi: hi)
        }
    }
    static func feasible(_ x: [Int64], _ rows: [ExactRow], _ c: Case) -> Bool {
        for j in 0..<c.n where x[j] < c.lower[j] || x[j] > c.upper[j] { return false }
        for r in rows {
            let act = dot(r.a, x)
            if let lo = r.lo, act < lo { return false }
            if let hi = r.hi, act > hi { return false }
        }
        return true
    }
    struct Result { var feasibleCount: Int; var points: Int; var bestNum: Int128?; var bestX: [Int64]?; var optimaCount: Int; var objE: Int; var objC: [Int128] }
    static func enumerate(_ c: Case) -> Result {
        let rows = rows(c)
        let (cInts, cE) = common(c.cost)
        var x = c.lower
        var res = Result(feasibleCount: 0, points: 0, bestNum: nil, bestX: nil, optimaCount: 0, objE: cE, objC: cInts)
        while true {
            res.points += 1
            if feasible(x, rows, c) {
                res.feasibleCount += 1
                let num = dot(cInts, x)
                if let b = res.bestNum {
                    let better = c.maximize ? num > b : num < b
                    if better { res.bestNum = num; res.bestX = x; res.optimaCount = 1 } else if num == b { res.optimaCount += 1 }
                } else { res.bestNum = num; res.bestX = x; res.optimaCount = 1 }
            }
            var j = 0
            while j < c.n {
                if x[j] < c.upper[j] { x[j] += 1; break }
                x[j] = c.lower[j]; j += 1
            }
            if j == c.n { break }
        }
        return res
    }
    static func value(_ num: Int128, _ e: Int) -> String {
        // exact value num * 2^e; printed as a Double (exact when |num| < 2^53) and as the fraction
        let d = Double(num) * pow(2.0, Double(e))
        let exact = Int128(Double(num)) == num
        return "\(String(format: "%.6f", d))\(exact ? "" : " (inexact print)") [= \(num)*2^\(e)]"
    }
}

// MARK: - ORACLE 2: the README §2.5 rule, read on decimal digits

func decimalPlaces(_ d: Double) -> Int {
    let s = "\(d)"
    var mant = Substring(s)
    var exp = 0
    if let i = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mant = s[..<i]
        exp = Int(s[s.index(after: i)...]) ?? 0
    }
    var frac = 0
    if let dot = mant.firstIndex(of: ".") {
        let f = mant[mant.index(after: dot)...]
        frac = String(f.reversed().drop(while: { $0 == "0" })).count
    }
    return Swift.max(0, frac - exp)
}

func readmeRule(_ values: [Double]) -> String {
    let nz = values.filter { $0 != 0 }
    guard !nz.isEmpty else { return "no data" }
    let k = nz.map(decimalPlaces).max()!
    if k > 6 { return "REJECT (needs 10^\(k) > 10^6)" }
    let scale = pow(10.0, Double(k))
    let mx = nz.map { Swift.abs($0) * scale }.max()!
    if mx >= two53 { return "REJECT (needs 10^\(k); max |scaled| = \(String(format: "%.4g", mx)) >= 2^53)" }
    return "accept at 10^\(k) (max |scaled| = \(String(format: "%.4g", mx)))"
}

// MARK: - Running strategies

struct Outcome: Equatable { var status: String; var obj: String; var bound: String; var x: [Int64]?; var error: String? }

func fmt(_ d: Double?) -> String { d.map { String(format: "%.6f", $0) } ?? "nil" }

func run<S: SolverStrategy>(_ s: S, _ lp: CompiledLP, cols: [Int]) async -> Outcome {
    var ctx = SolveContext()
    ctx.timeLimit = 10
    do {
        let r = try await s.solve(lp, context: ctx)
        return Outcome(status: "\(r.status)", obj: fmt(r.objectiveValue), bound: fmt(r.bound),
                       x: r.primal.map { p in cols.map { Int64(p[$0].rounded()) } }, error: nil)
    } catch {
        return Outcome(status: "THROW", obj: "nil", bound: "nil", x: nil, error: "\(error)")
    }
}

func describe(_ o: Outcome) -> String {
    if let e = o.error { return "THROW \(e)" }
    let xs = o.x.map { "(" + $0.map(String.init).joined(separator: ",") + ")" } ?? "-"
    return "\(o.status) obj=\(o.obj) bound=\(o.bound) x=\(xs)"
}

@available(macOS 15.0, *)
func judge(_ o: Outcome, _ c: Case, _ oracle: Exact.Result) -> String {
    guard o.error == nil else { return "no point" }
    guard let x = o.x else { return "no point" }
    let rows = Exact.rows(c)
    let feas = Exact.feasible(x, rows, c)
    let num = Exact.dot(oracle.objC, x)
    let eqOpt = oracle.bestNum.map { $0 == num } ?? false
    return "point exactly feasible=\(feas); its exact objective \(Exact.value(num, oracle.objE)); equals exact optimum: \(eqOpt)"
}

@available(macOS 15.0, *)
func study(_ c: Case, repeats: Int = 3, secondEngine: Bool = true) async {
    print("\n==== \(c.tag)")
    let model = makeModel(c)
    let compiled: CompiledModel<Iv>
    do { compiled = try model.compile() } catch { print("compile threw \(error)"); return }
    let lp = compiled.lp
    let cols = (0..<c.n).map { compiled.column[.v($0)]! }
    // What CP-SAT receives: the row coefficients of the compiled problem, printed exactly.
    for i in 0..<lp.m {
        let r = lp.aT.colStart[i]..<lp.aT.colStart[i + 1]
        let vals = r.map { lp.aT.values[$0] }
        let parts = vals.map { v -> String in
            let s = Exact.split(v)
            return "\(String(format: "%.10f", v)) [m=\(s.m) e=\(s.e); |v-round(v)|=\(Swift.abs(v - v.rounded())), 4ulp=\(4 * v.ulp)]"
        }
        print("  compiled row \(i) [\(lp.rl[i]), \(lp.ru[i])]: " + parts.joined(separator: " ; "))
        print("  README rule on row \(i) coefficients: \(readmeRule(vals))")
    }
    if lp.c.contains(where: { $0 != 0 }) { print("  README rule on objective: \(readmeRule(lp.c))") }
    let t0 = Date()
    let oracle = Exact.enumerate(c)
    let bestS = oracle.bestNum.map { Exact.value($0, oracle.objE) } ?? "INFEASIBLE"
    print("  ORACLE exact enumeration: \(oracle.points) points, \(oracle.feasibleCount) feasible; optimum \(bestS) at \(oracle.bestX.map { "\($0)" } ?? "-") (\(oracle.optimaCount) optimal points) [\(String(format: "%.2f", Date().timeIntervalSince(t0))) s]")
    let configs: [(String, CPSAT)] = [
        ("CPSAT()", CPSAT()),
        ("CPSAT(deterministic: true)", CPSAT(deterministic: true)),
        ("CPSAT(lpPropagator: false, deterministic: true)", CPSAT(lpPropagator: false, deterministic: true)),
        ("CPSAT(workers: 4, seed: 7)", CPSAT(workers: 4, seed: 7)),
        ("CPSAT(workers: 2, lpPropagator: false, seed: 12345)", CPSAT(workers: 2, lpPropagator: false, seed: 12345)),
    ]
    for (name, s) in configs {
        var outs: [Outcome] = []
        for _ in 0..<repeats { outs.append(await run(s, lp, cols: cols)) }
        let same = outs.allSatisfy { $0 == outs[0] }
        print("  \(name) x\(repeats) \(same ? "identical" : "DIFFER"): \(describe(outs[0]))")
        if !same { for o in outs.dropFirst() { print("      also: \(describe(o))") } }
        print("      exact check: \(judge(outs[0], c, oracle))")
    }
    // The LPModel form of the same call (compile inside solve), as a user would write it.
    do {
        var ctx = SolveContext()
        ctx.timeLimit = 10
        let sol = try await CPSAT().solve(model, context: ctx)
        let xs = (0..<c.n).map { String(Int64(sol.value(of: .v($0)).rounded())) }.joined(separator: ",")
        print("  CPSAT().solve(LPModel): \(sol.status) obj=\(fmt(sol.objectiveValue)) x=(\(xs))")
    } catch { print("  CPSAT().solve(LPModel): THROW \(error)") }
    if secondEngine {
        let b = await run(BranchAndBound(engine: Simplex(.primal), deterministic: true), lp, cols: cols)
        print("  second engine BranchAndBound(engine: Simplex(.primal), deterministic: true): \(describe(b))")
        print("      exact check: \(judge(b, c, oracle))")
    }
}

// MARK: - Cases (written from the finding's description)

let M3 = Case(tag: "M3: (2^49+0.375)x + (2^49+0.375)y - (2^50+0.75)z = 0, binaries, max x+y+z",
              lower: [0, 0, 0], upper: [1, 1, 1], binary: true,
              rows: [Row(coefs: [two49 + 0.375, two49 + 0.375, -(two50 + 0.75)], lo: 0, hi: 0)],
              cost: [1, 1, 1], maximize: true)
let M3control = Case(tag: "M3-control: same row at 2^40 (4ulp = 9e-4 < 0.375; needs 10^3 -> 1.1e15 < 2^53)",
              lower: [0, 0, 0], upper: [1, 1, 1], binary: true,
              rows: [Row(coefs: [1099511627776.0 + 0.375, 1099511627776.0 + 0.375, -(2199023255552.0 + 0.75)], lo: 0, hi: 0)],
              cost: [1, 1, 1], maximize: true)
let M4 = Case(tag: "M4: 1e-10 x0 + 1e-10 x1 >= 1e-10, binaries, min x0+x1",
              lower: [0, 0], upper: [1, 1], binary: true,
              rows: [Row(coefs: [1e-10, 1e-10], lo: 1e-10, hi: inf)], cost: [1, 1], maximize: false)
let M4control = Case(tag: "M4-control: 1e-7 x0 + 1e-7 x1 >= 1e-7 (README: reject)",
              lower: [0, 0], upper: [1, 1], binary: true,
              rows: [Row(coefs: [1e-7, 1e-7], lo: 1e-7, hi: inf)], cost: [1, 1], maximize: false)
let M7 = Case(tag: "M7: x - 1.0000000009 y >= 0, y = 1e6 fixed, x in [0, 2e6], min x",
              lower: [0, 1_000_000], upper: [2_000_000, 1_000_000], binary: false,
              rows: [Row(coefs: [1, -1.0000000009], lo: 0, hi: inf)], cost: [1, 0], maximize: false)
let M7control = Case(tag: "M7-control: x - 1.000000002 y >= 0, y = 1e6 fixed (|frac| 2e-9 > 1e-9)",
              lower: [0, 1_000_000], upper: [2_000_000, 1_000_000], binary: false,
              rows: [Row(coefs: [1, -1.000000002], lo: 0, hi: inf)], cost: [1, 0], maximize: false)
let M7b = Case(tag: "M7b/D5a: (2^48+0.1875)x - 2^48 y <= 0, binaries, max x",
              lower: [0, 0], upper: [1, 1], binary: true,
              rows: [Row(coefs: [two48 + 0.1875, -two48], lo: -inf, hi: 0)], cost: [1, 0], maximize: true)
let D5d = Case(tag: "D5d: max (2^49+0.5)x, x binary, no rows",
              lower: [0], upper: [1], binary: true, rows: [], cost: [two49 + 0.5], maximize: true)

func sweepCase(_ k: Int) -> Case {
    Case(tag: "SWEEP k=\(k): (2^48 + \(Double(k) / 16))x - 2^48 y <= 0, binaries, max x   [fraction = \(k) ulp of 2^48]",
         lower: [0, 0], upper: [1, 1], binary: true,
         rows: [Row(coefs: [two48 + Double(k) / 16, -two48], lo: -inf, hi: 0)], cost: [1, 0], maximize: true)
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
if #available(macOS 15.0, *) {
    if mode == "all" || mode == "cases" {
        for c in [M3, M3control, M4, M4control, M7, M7control, M7b, D5d] { await study(c) }
    }
    if mode == "all" || mode == "sweep" {
        for k in 1...8 { await study(sweepCase(k), repeats: 2, secondEngine: false) }
    }
    if mode == "all" || mode == "portfolio" {
        // Reachability through a facade: CPSAT raced against branch and bound on M3.
        let compiled = try makeModel(M3).compile()
        let cols = (0..<3).map { compiled.column[.v($0)]! }
        print("\n==== Portfolio([CPSAT(), BranchAndBound(engine: Simplex(.primal))]) on M3, 6 runs")
        for _ in 0..<6 {
            let o = await run(Portfolio([CPSAT(), BranchAndBound(engine: Simplex(.primal))]), compiled.lp, cols: cols)
            print("  \(describe(o))")
        }
    }
} else {
    print("needs macOS 15 for Int128")
}
