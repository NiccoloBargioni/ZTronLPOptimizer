// Cycle B, slot V125: contract-lens sceptic for finding B5-02 (CP-SAT data scaling / snapping).
// Every probe: tiny pure-binary or bounded-integer model, an exact oracle (dyadic data scaled by
// a power of two to Int64, enumeration of every point), CP-SAT in three configurations, and
// BranchAndBound() as the package's other engine for the same model.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)

let inf = Double.infinity
let p32 = 4294967296.0
let p48 = 281474976710656.0
let p49 = 562949953421312.0
let p50 = 1125899906842624.0
let p53 = 9007199254740992.0

struct Row { var terms: [(Int, Double)]; var lo: Double; var hi: Double }
struct Prog {
    var xl: [Double]; var xu: [Double]; var rows: [Row]; var cost: [Double]; var maximize: Bool
    var lp: CompiledLP {
        var e: [(row: Int, col: Int, value: Double)] = []
        for (i, r) in rows.enumerated() { for (j, v) in r.terms { e.append((i, j, v)) } }
        let c = maximize ? cost.map { $0 == 0 ? 0 : -$0 } : cost
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: rows.count, cols: xl.count, e), c: c,
            sense: maximize ? .maximize : .minimize, xl: xl, xu: xu,
            rl: rows.map { $0.lo }, ru: rows.map { $0.hi }, integerColumns: (0..<xl.count).map { Int32($0) })
    }
}

/// Exact oracle for dyadic data: every coefficient times `scale` (a power of two, so the
/// product is exact) must be an exact Int64; activities are summed in Int64 with overflow
/// checks and compared with ceil(lo·scale) / floor(hi·scale), which is exact for an integer
/// activity. Costs must be integers. Returns (best objective, argmax/argmin, feasible count).
func exactOracle(_ p: Prog, scale: Double) -> (best: Int64?, at: [Int64], feasible: Int) {
    let n = p.xl.count
    let lo = p.xl.map { Int64($0.rounded(.up)) }, hi = p.xu.map { Int64($0.rounded(.down)) }
    var rowsInt: [([(Int, Int64)], Int64?, Int64?)] = []
    for r in p.rows {
        let t = r.terms.map { (j, v) -> (Int, Int64) in
            guard let a = Int64(exactly: v * scale) else { fatalError("oracle: coefficient \(v) not exact at scale \(scale)") }
            return (j, a)
        }
        let l: Int64? = r.lo.isFinite ? Int64(exactly: (r.lo * scale).rounded(.up)) : nil
        let h: Int64? = r.hi.isFinite ? Int64(exactly: (r.hi * scale).rounded(.down)) : nil
        rowsInt.append((t, l, h))
    }
    let cost = p.cost.map { c -> Int64 in guard let v = Int64(exactly: c) else { fatalError("oracle: cost") }; return v }
    var best: Int64? = nil, at: [Int64] = [], count = 0
    var x = lo
    func rec(_ j: Int) {
        if j == n {
            for (t, l, h) in rowsInt {
                var act: Int64 = 0
                for (k, a) in t {
                    let (m, o1) = a.multipliedReportingOverflow(by: x[k]); precondition(!o1)
                    let (s, o2) = act.addingReportingOverflow(m); precondition(!o2)
                    act = s
                }
                if let l, act < l { return }
                if let h, act > h { return }
            }
            count += 1
            var obj: Int64 = 0
            for k in 0..<n { obj += cost[k] * x[k] }
            if best == nil || (p.maximize ? obj > best! : obj < best!) { best = obj; at = x }
            return
        }
        var v = lo[j]
        while v <= hi[j] { x[j] = v; rec(j + 1); v += 1 }
    }
    rec(0)
    return (best, at, count)
}

func context(_ t: Double = 10) -> SolveContext { var c = SolveContext(); c.timeLimit = t; return c }

func fmt(_ x: [Double]?) -> String {
    guard let x else { return "-" }
    return "(" + x.map { $0 == $0.rounded() && abs($0) < 9e18 ? String(Int64($0)) : String($0) }.joined(separator: ",") + ")"
}

func runAll(_ tag: String, _ p: Prog, truth: String) async {
    let lp = p.lp
    print("[\(tag)]")
    print("  truth: \(truth)")
    let strategies: [(String, CPSAT)] = [
        ("CPSAT()", CPSAT()),
        ("CPSAT(deterministic: true)", CPSAT(deterministic: true)),
        ("CPSAT(lpPropagator: false, deterministic: true)", CPSAT(lpPropagator: false, deterministic: true)),
    ]
    for (name, s) in strategies {
        do {
            let r = try await s.solve(lp, context: context())
            let v = r.primal.map { lp.maxViolation(at: $0) }
            print("  \(name): \(r.status) obj=\(r.objectiveValue.map { String($0) } ?? "nil") bound=\(r.bound.map { String($0) } ?? "nil") x=\(fmt(r.primal)) maxViolation=\(v.map { "(\($0.bounds), \($0.rows))" } ?? "-")")
        } catch {
            print("  \(name): THROWS \(error)")
        }
    }
    do {
        let r = try await BranchAndBound().solve(lp, context: context())
        let v = r.primal.map { lp.maxViolation(at: $0) }
        print("  BranchAndBound(): \(r.status) obj=\(r.objectiveValue.map { String($0) } ?? "nil") x=\(fmt(r.primal)) maxViolation=\(v.map { "(\($0.bounds), \($0.rows))" } ?? "-")")
    } catch {
        print("  BranchAndBound(): THROWS \(error)")
    }
}

func smallestPowerOfTenMakingIntegral(_ v: [Double]) -> (Double, [Double])? {
    for s in [1.0, 10, 100, 1_000, 10_000, 100_000, 1_000_000] {
        let scaled = v.map { $0 * s }
        if scaled.allSatisfy({ $0 == $0.rounded() }) { return (s, scaled) }
    }
    return nil
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

if mode == "all" || mode == "m3" {
    // M3 of the finder: out of the documented domain (0.375 needs 10^3, and 10^3 * 2^49 > 2^53).
    let a = p49 + 0.375, c = -(p50 + 0.75)
    let p = Prog(xl: [0, 0, 0], xu: [1, 1, 1], rows: [Row(terms: [(0, a), (1, a), (2, c)], lo: 0, hi: 0)], cost: [1, 1, 1], maximize: true)
    let o = exactOracle(p, scale: 8)
    print("M3 data exact? a=\(String(format: "%.3f", a)) c=\(String(format: "%.3f", c)) 2a+c=\(2 * a + c); decimal scale making exact-integral: \(smallestPowerOfTenMakingIntegral([a, c]).map { "\($0.0) -> \($0.1)" } ?? "none <= 1e6") (2^53=\(p53))")
    print("  maxViolation at (1,1,1) = \(p.lp.maxViolation(at: [1, 1, 1]))")
    await runAll("M3 (2^49+.375)x + (2^49+.375)y - (2^50+.75)z = 0, binaries, max x+y+z", p,
                 truth: "exact oracle: optimum \(o.best.map { String($0) } ?? "infeasible") at \(o.at), \(o.feasible) feasible points; README: .unsupported")
}

if mode == "all" || mode == "dsl" {
    // The same M3 through the modelling DSL (compile -> CompiledLP -> CPSAT), the user path.
    enum B: LPVariable, CaseIterable { case x, y, z; var domain: VariableDomain { .binary } }
    let a = p49 + 0.375, c = p50 + 0.75
    let model = LPModel<B>()
        .maximizing(B.x + B.y + B.z)
        .subjectTo { (a * B.x + a * B.y - c * B.z == 0).named("r") }
    do {
        let s = try await CPSAT().solve(model, context: context())
        print("[M3 via DSL] CPSAT(): \(s.status) obj=\(s.objectiveValue.map { String($0) } ?? "nil") x=\(s.value(of: .x)) y=\(s.value(of: .y)) z=\(s.value(of: .z))")
    } catch { print("[M3 via DSL] CPSAT(): THROWS \(error)") }
}

if mode == "all" || mode == "indomain" {
    // IN the documented domain: 10 makes every coefficient exactly integral, the scaled
    // coefficients 5629499534213125 and 5629499534213140 are below 2^53, binaries, activities
    // within +-2^61. a = 2^49 + 0.5 is exact in binary.
    let a = p49 + 0.5, c = p49 + 2
    let p = Prog(xl: [0, 0], xu: [1, 1], rows: [Row(terms: [(0, a), (1, -c)], lo: -inf, hi: -1.25)], cost: [1, 1], maximize: true)
    let o = exactOracle(p, scale: 4)
    let sc = smallestPowerOfTenMakingIntegral([a, -c])
    print("IN-DOMAIN data: a=\(String(format: "%.3f", a)) c=\(String(format: "%.1f", c)); smallest power of 10 making the row exactly integral: \(sc.map { "\($0.0) -> \($0.1.map { String(format: "%.0f", $0) }), below 2^53: \($0.1.allSatisfy { abs($0) < p53 })" } ?? "none")")
    print("  activity at (1,1) = a - c = \(a - c) (<= -1.25 holds), maxViolation at (1,1) = \(p.lp.maxViolation(at: [1, 1]))")
    await runAll("IN1 (2^49+0.5)x - (2^49+2)y <= -1.25, binaries, max x+y", p,
                 truth: "exact oracle: optimum \(o.best.map { String($0) } ?? "infeasible") at \(o.at), \(o.feasible) feasible points")

    // Six decimals near 2^32 (README: 10^6 allowed; 10^6 * 4.29e9 = 4.29e15 < 2^53).
    let a6 = p32 + 0.000003          // stored as 2^32 + 3*2^-20 = 4294967296.00000286102294921875
    let c6 = p32 + 1
    let p6 = Prog(xl: [0, 0], xu: [1, 1], rows: [Row(terms: [(0, a6), (1, -c6)], lo: -0.999999, hi: inf)], cost: [1, 1], maximize: true)
    let o6 = exactOracle(p6, scale: 1_048_576)
    print("IN-DOMAIN 6 decimals: a6=\(String(format: "%.20f", a6)) a6*1e6=\(String(format: "%.3f", a6 * 1e6)) integral in double: \((a6 * 1e6) == (a6 * 1e6).rounded()), below 2^53: \(a6 * 1e6 < p53)")
    print("  activity at (1,1) = \(a6 - c6) (>= -0.999999 holds with slack \(a6 - c6 + 0.999999)), maxViolation at (1,1) = \(p6.lp.maxViolation(at: [1, 1]))")
    await runAll("IN2 (2^32+0.000003)x - (2^32+1)y >= -0.999999, binaries, max x+y", p6,
                 truth: "exact oracle: optimum \(o6.best.map { String($0) } ?? "infeasible") at \(o6.at), \(o6.feasible) feasible points")
}

if mode == "all" || mode == "tol" {
    // M4: a 1e-10 row. Exact optimum 1; the point (0,0) violates by 1e-10 < 1e-7 primal tolerance.
    let p4 = Prog(xl: [0, 0], xu: [1, 1], rows: [Row(terms: [(0, 1e-10), (1, 1e-10)], lo: 1e-10, hi: inf)], cost: [1, 1], maximize: false)
    await runAll("M4 1e-10 x0 + 1e-10 x1 >= 1e-10, binaries, min x0+x1", p4,
                 truth: "exact optimum 1; (0,0) violates by 1e-10, below Tolerances.primalFeasibility 1e-7")
    // Objective rounding of (2^49 + 0.5) x: relative error 9e-16, far inside the 1e-4 MIP gap.
    let po = Prog(xl: [0], xu: [1], rows: [], cost: [p49 + 0.5], maximize: true)
    do {
        let r = try await CPSAT().solve(po.lp, context: context())
        let truthV = p49 + 0.5
        print("[OBJ max (2^49+0.5)x] CPSAT(): \(r.status) obj=\(String(format: "%.3f", r.objectiveValue ?? .nan)) truth=\(String(format: "%.3f", truthV)) relErr=\(abs((r.objectiveValue ?? 0) - truthV) / truthV) allowed gap=max(1e-6,1e-4*|obj|)=\(1e-4 * truthV)")
    } catch { print("[OBJ] THROWS \(error)") }
}

if mode == "all" || mode == "ii" {
    // M7, M7b: user data -> SolverError.internalInconsistency ("never caused by user data").
    let p7 = Prog(xl: [0, 1e6], xu: [2e6, 1e6], rows: [Row(terms: [(0, 1), (1, -1.0000000009)], lo: 0, hi: inf)], cost: [1, 0], maximize: false)
    await runAll("M7 x - 1.0000000009 y >= 0, y = 1e6, x in [0,2e6], min x", p7,
                 truth: "x >= 1000000.0009 -> optimum 1000001; README: .unsupported (needs 10^10)")
    let p7b = Prog(xl: [0, 0], xu: [1, 1], rows: [Row(terms: [(0, p48 + 0.1875), (1, -p48)], lo: -inf, hi: 0)], cost: [1, 0], maximize: true)
    let o7b = exactOracle(p7b, scale: 16)
    await runAll("M7b (2^48+0.1875)x - 2^48 y <= 0, binaries, max x", p7b,
                 truth: "exact oracle: optimum \(o7b.best.map { String($0) } ?? "infeasible") at \(o7b.at); README: .unsupported (needs 10^4 -> 2.8e18 > 2^53)")
    // Same 1e-9 snap, but a fractional row bound: a false optimum instead of the safety net.
    let p9 = Prog(xl: [1e6, 1e6, 0], xu: [1e6, 1e6, 1], rows: [Row(terms: [(0, 1.0000000009), (1, -1), (2, -1)], lo: -0.9995, hi: inf)], cost: [0, 0, 1], maximize: true)
    await runAll("S9 1.0000000009 x - y - z >= -0.9995, x = y = 1e6, z binary, max z", p9,
                 truth: "z = 1: activity 1000000.0009 - 1000000 - 1 = -0.9991 >= -0.9995 (slack 4e-4) -> optimum 1; README: .unsupported (needs 10^10)")
}
