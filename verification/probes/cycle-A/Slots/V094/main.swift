// Slot V094, cycle A: independent REPRODUCE-lens check of finding A4-02
// (branch-and-bound heuristic incumbents accepted with a feasibility test relative to the
// row bound). Models are built with the public modelling DSL (not CompiledLP by hand), and
// every answer is judged by an oracle that does not use the package: exact Int64 arithmetic
// on the returned integer point, weak duality (closed-form LP bound), brute-force
// enumeration on scaled-down copies, and metamorphic equivalents (Chvatal-Gomory tightened
// rows with the same integer feasible set).
//
// Usage: V094 core | sweep | repeat <n> | enum
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Variables

/// Two integer columns in [0, ub]; ub travels in the case so each model has its own bounds.
enum KV: LPVariable {
    case a(Double), b(Double)
    var domain: VariableDomain {
        switch self {
        case .a(let u), .b(let u): return .integer(.range(0...u))
        }
    }
}

/// x integer in [0, 1e8], z continuous in [0, 0.5].
enum MV: LPVariable {
    case x, z
    var domain: VariableDomain {
        switch self {
        case .x: return .integer(.range(0...1e8))
        case .z: return .continuous(.range(0...0.5))
        }
    }
}

/// x integer in [-1e9, 1e9], y continuous fixed at 0.
enum BV: LPVariable {
    case x, y
    var domain: VariableDomain {
        switch self {
        case .x: return .integer(.range(-1e9...1e9))
        case .y: return .continuous(.fixed(0))
        }
    }
}

// MARK: - A run

struct Outcome {
    var status: SolveStatus
    var objective: Double?
    var bound: Double?
    var primal: [Double]?
    var sources: [String]
    var nodes: Int
    var rootLP: Double?
}

func ctx(threads: Int?, metal: Bool = false) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 30
    c.threads = threads
    if !metal { c.metal = .off }
    return c
}

func bb<E: NodeLPStrategy>(_ s: BranchAndBound<E>, _ lp: CompiledLP, threads: Int?) async throws -> Outcome {
    let a = try await s.solve(lp, context: ctx(threads: threads))
    return Outcome(
        status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal,
        sources: a.incumbentHistory.map(\.source), nodes: a.nodesProcessed, rootLP: a.root.objectiveValue)
}

struct Config {
    let name: String
    let run: (CompiledLP) async throws -> Outcome
}

func bbConfigs() -> [Config] {
    [
        Config(name: "BB()") { try await bb(BranchAndBound(), $0, threads: nil) },
        Config(name: "BB(det)") { try await bb(BranchAndBound(deterministic: true), $0, threads: 1) },
        Config(name: "BB(dual,det)") { try await bb(BranchAndBound(engine: Simplex(.dual), deterministic: true), $0, threads: 1) },
        Config(name: "BB(ipm,det)") { try await bb(BranchAndBound(engine: InteriorPoint(), deterministic: true), $0, threads: 1) },
        Config(name: "BB(gap0,det)") {
            try await bb(BranchAndBound(gap: Gap(relative: 0, absolute: 0), deterministic: true), $0, threads: 1)
        },
        Config(name: "BB(noRounding,det)") {
            try await bb(BranchAndBound(heuristics: Heuristics(rounding: false, diving: true), deterministic: true), $0, threads: 1)
        },
        Config(name: "BB(none,det)") { try await bb(BranchAndBound(heuristics: .none, deterministic: true), $0, threads: 1) },
        Config(name: "Automatic") {
            let a = try await Automatic().solve($0, context: ctx(threads: nil, metal: true))
            let inner = a.unwrap(as: BranchAndBoundAnalysis<SimplexAnalysis>.self)
            return Outcome(
                status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal,
                sources: inner?.incumbentHistory.map(\.source) ?? ["?"], nodes: inner?.nodesProcessed ?? -1,
                rootLP: inner?.root.objectiveValue)
        },
    ]
}

func cpsat(_ lp: CompiledLP) async throws -> Outcome {
    let a = try await CPSAT(deterministic: true).solve(lp, context: ctx(threads: 1))
    return Outcome(status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal, sources: ["cpsat"], nodes: 0, rootLP: nil)
}

func f(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.10g", v)
}

// MARK: - Exact (package-free) checks

/// Integer value of an integral Double, or nil when it is not within 1e-6 of an integer.
func int(_ v: Double) -> Int64? {
    let r = v.rounded()
    guard abs(v - r) <= 1e-6, abs(r) < 9e15 else { return nil }
    return Int64(r)
}

/// A case: a compiled model, the exact checker of a returned point (violation in exact
/// arithmetic, objective as computed from the point), the true optimum (derived by hand,
/// checked by enumeration on scaled copies in `enum` mode) and the closed-form LP bound.
struct Case {
    let name: String
    let lp: CompiledLP
    let check: ([Double]) -> (violation: Double, objective: Double)?
    let truth: Double
    let lpBound: Double
    let sense: String
    let pureInteger: Bool
}

func knapsack(_ k: Double, tightened: Bool = false) throws -> Case {
    // maximise a + b  s.t. 3a + 3b <= 3k - 1, a, b integer in [0, k].
    // Any point (integral or not): a + b = (3a + 3b)/3 <= k - 1/3 (weak duality, y = 1/3),
    // so the integer optimum is k - 1 (attained at (k-1, 0)).
    // tightened: a + b <= k - 1, the Chvatal-Gomory rounding of the same row: same integer set.
    let a = KV.a(k), b = KV.b(k)
    let rhs = 3 * k - 1
    let model = LPModel<KV>().maximizing(1 * a + 1 * b).subjectTo {
        if tightened { (1 * a + 1 * b <= k - 1).named("cap") } else { (3 * a + 3 * b <= rhs).named("cap") }
    }
    let compiled = try model.compile()
    let ka = Int64(k)
    let check: ([Double]) -> (Double, Double)? = { x in
        let sol = Solution(analysis: AnyPoint(x), compiled: compiled)
        guard let ia = int(sol.value(of: a)), let ib = int(sol.value(of: b)) else { return nil }
        let activity = 3 * ia + 3 * ib                // exact, Int64
        let v = max(0, activity - (3 * ka - 1), -ia, -ib, ia - ka, ib - ka)
        return (Double(v), Double(ia + ib))
    }
    return Case(
        name: tightened ? "knapsack-tight k=\(f(k))" : "knapsack 3a+3b<=\(f(rhs))", lp: compiled.lp, check: check,
        truth: k - 1, lpBound: tightened ? k - 1 : rhs / 3, sense: "max", pureInteger: true)
}

func covering(_ k: Double, tightened: Bool = false) throws -> Case {
    // minimise a + b  s.t. 3a + 3b >= 3k + 1, a, b integer in [0, 2k].
    // Any point: a + b >= k + 1/3, so the integer optimum is k + 1.
    let a = KV.a(2 * k), b = KV.b(2 * k)
    let rhs = 3 * k + 1
    let model = LPModel<KV>().minimizing(1 * a + 1 * b).subjectTo {
        if tightened { (1 * a + 1 * b >= k + 1).named("cover") } else { (3 * a + 3 * b >= rhs).named("cover") }
    }
    let compiled = try model.compile()
    let ka = Int64(k)
    let check: ([Double]) -> (Double, Double)? = { x in
        let sol = Solution(analysis: AnyPoint(x), compiled: compiled)
        guard let ia = int(sol.value(of: a)), let ib = int(sol.value(of: b)) else { return nil }
        let activity = 3 * ia + 3 * ib
        let v = max(0, (3 * ka + 1) - activity, -ia, -ib, ia - 2 * ka, ib - 2 * ka)
        return (Double(v), Double(ia + ib))
    }
    return Case(
        name: tightened ? "covering-tight k=\(f(k))" : "covering 3a+3b>=\(f(rhs))", lp: compiled.lp, check: check,
        truth: k + 1, lpBound: tightened ? k + 1 : rhs / 3, sense: "min", pureInteger: true)
}

func mixedCase() throws -> Case {
    // minimise x  s.t. 2x - z >= 20,000,001, x integer in [0, 1e8], z in [0, 0.5].
    // Any point: x >= (20,000,001 + z)/2 >= 10,000,000.5, so the integer optimum is 10,000,001.
    let model = LPModel<MV>().minimizing(1 * MV.x).subjectTo { (2 * MV.x - 1 * MV.z >= 20_000_001).named("r") }
    let compiled = try model.compile()
    let check: ([Double]) -> (Double, Double)? = { p in
        let sol = Solution(analysis: AnyPoint(p), compiled: compiled)
        guard let ix = int(sol.value(of: .x)) else { return nil }
        let z = sol.value(of: .z)
        // 2*ix is an exact integer; z in [0, 0.5] is exact in Double; the difference is exact.
        let v = max(0, 20_000_001 - (Double(2 * ix) - z), -z, z - 0.5, Double(-ix))
        return (v, Double(ix))
    }
    return Case(name: "mixed 2x-z>=20000001", lp: compiled.lp, check: check, truth: 10_000_001, lpBound: 10_000_000.5, sense: "min", pureInteger: false)
}

func bigCase() throws -> Case {
    // minimise x  s.t. 3x + y >= 1e9 + 1, y fixed 0, x integer in [-1e9, 1e9].
    // Any point: x >= (1e9 + 1)/3 = 333,333,333.67, so the integer optimum is 333,333,334.
    let model = LPModel<BV>().minimizing(1 * BV.x).subjectTo { (3 * BV.x + 1 * BV.y >= 1_000_000_001).named("r") }
    let compiled = try model.compile()
    let check: ([Double]) -> (Double, Double)? = { p in
        let sol = Solution(analysis: AnyPoint(p), compiled: compiled)
        guard let ix = int(sol.value(of: .x)) else { return nil }
        let y = sol.value(of: .y)
        let v = max(0, 1_000_000_001 - (Double(3 * ix) + y), abs(y))
        return (v, Double(ix))
    }
    return Case(name: "big 3x+y>=1e9+1 (y=0)", lp: compiled.lp, check: check, truth: 333_333_334, lpBound: (1e9 + 1) / 3, sense: "min", pureInteger: false)
}

/// A minimal analysis that only carries a point, so `Solution.value(of:)` maps columns.
struct AnyPoint: SolutionAnalysis {
    let x: [Double]
    init(_ x: [Double]) { self.x = x }
    var status: SolveStatus { .optimal }
    var objectiveValue: Double? { nil }
    var bound: Double? { nil }
    var primal: [Double]? { x }
    var dual: [Double]? { nil }
    var reducedCosts: [Double]? { nil }
    var seconds: Double { 0 }
    var warnings: [String] { [] }
}

/// One line per run: what came back, what the exact oracle says about it.
func judge(_ c: Case, _ name: String, _ o: Outcome) -> (line: String, wrong: Bool) {
    var s = "  \(name): \(o.status) obj=\(f(o.objective)) bound=\(f(o.bound)) rootLP=\(f(o.rootLP)) nodes=\(o.nodes) src=\(o.sources)"
    var wrong = false
    if let x = o.primal, let r = c.check(x) {
        let mv = c.lp.maxViolation(at: x)
        s += " | exact: viol=\(f(r.violation)) obj(point)=\(f(r.objective)) maxViolation.rows=\(f(mv.rows))"
        let beyondLP = c.sense == "max" ? r.objective > c.lpBound + 1e-9 : r.objective < c.lpBound - 1e-9
        if beyondLP { s += " BEYOND-LP-BOUND(\(f(c.lpBound)))" }
        if o.status.isOptimal && (r.violation > 0 || r.objective != c.truth) {
            wrong = true
            s += " => WRONG (truth \(f(c.truth)))"
        } else if o.status.isOptimal {
            s += " => ok"
        }
    } else if let x = o.primal {
        s += " | point not integral: \(x)"
        wrong = o.status.isOptimal
    }
    return (s, wrong)
}

// MARK: - Modes

func coreMode() async throws {
    let cases = [try knapsack(1e7), try mixedCase(), try bigCase(), try covering(333_333_333)]
    for c in cases {
        print("\(c.name)  [truth \(f(c.truth)), closed-form LP bound \(f(c.lpBound)), rows=\(c.lp.m) cols=\(c.lp.n) rl=\(c.lp.rl) ru=\(c.lp.ru) xl=\(c.lp.xl) xu=\(c.lp.xu)]")
        // Independent LP relaxation value from a plain LP engine.
        let relax = try await Simplex(.dual).solve(c.lp.relaxed(), context: ctx(threads: 1))
        print("  LP relaxation (Simplex .dual on relaxed()): \(relax.status) \(f(relax.objectiveValue))")
        var wrongCount = 0
        for cfg in bbConfigs() {
            let (line, wrong) = judge(c, cfg.name, try await cfg.run(c.lp))
            if wrong { wrongCount += 1 }
            print(line)
        }
        if c.pureInteger {
            do {
                let (line, _) = judge(c, "CPSAT(det)", try await cpsat(c.lp))
                print(line)
            } catch { print("  CPSAT(det): THROWS \(error)") }
        }
        print("  wrong .optimal answers among B&B/Automatic configs: \(wrongCount)/\(bbConfigs().count)")
    }
    // Metamorphic: the same integer feasible sets, written with the CG-rounded row.
    for c in [try knapsack(1e7, tightened: true), try covering(333_333_333, tightened: true)] {
        print("\(c.name)  [truth \(f(c.truth)), equivalent integer set]")
        for cfg in bbConfigs().prefix(2) {
            print(judge(c, cfg.name, try await cfg.run(c.lp)).line)
        }
    }
}

func sweepMode() async throws {
    // Predicted from TreeSearch.isFeasible: the nearest/floor rounding of the root LP point
    // violates the row by exactly 1; it is accepted iff 1 <= 1e-7 * (1 + |rhs|).
    let ks: [Double] = [10, 1_000, 100_000, 1_000_000, 3_000_000, 3_333_332, 3_333_333, 3_333_334, 3_400_000, 10_000_000, 100_000_000]
    for family in ["knapsack", "covering"] {
        print("\(family): k | rhs | predicted(tol>=1) | BB(det) | BB() | BB(none,det)")
        for k in ks {
            let c = family == "knapsack" ? try knapsack(k) : try covering(k)
            let rhs = family == "knapsack" ? 3 * k - 1 : 3 * k + 1
            let tol = 1e-7 * (1 + abs(rhs))
            var row = "  k=\(f(k)) rhs=\(f(rhs)) tol=\(String(format: "%.9f", tol)) predictedWrong=\(tol >= 1)"
            for (name, run) in [("det", bbConfigs()[1].run), ("par", bbConfigs()[0].run), ("none", bbConfigs()[6].run)] {
                let o = try await run(c.lp)
                let r = o.primal.flatMap { c.check($0) }
                let wrong = o.status.isOptimal && (r == nil || r!.violation > 0 || r!.objective != c.truth)
                row += " | \(name): \(o.status) \(f(o.objective)) viol=\(f(r?.violation)) \(wrong ? "WRONG" : "ok")"
            }
            print(row)
        }
    }
}

func repeatMode(_ n: Int) async throws {
    let cases = [try knapsack(1e7), try mixedCase()]
    for c in cases {
        var tally: [String: Int] = [:]
        for _ in 0..<n {
            for (name, threads) in [("par-default", nil), ("par-2", 2), ("par-8", 8)] as [(String, Int?)] {
                let o = try await bb(BranchAndBound(), c.lp, threads: threads)
                tally["\(name) \(o.status) \(f(o.objective))", default: 0] += 1
            }
            let d = try await bb(BranchAndBound(deterministic: true, seed: UInt64.random(in: 0...1000)), c.lp, threads: 1)
            tally["det(random seed) \(d.status) \(f(d.objective))", default: 0] += 1
        }
        print("\(c.name) over \(n) repetitions:")
        for (k, v) in tally.sorted(by: { $0.key < $1.key }) { print("  \(v)x  \(k)") }
    }
}

func enumMode() {
    // Brute force on scaled-down copies: the closed forms k - 1 (knapsack) and k + 1
    // (covering), and ceil((2m+1)/2) for 2x - z >= 2m + 1 with z in [0, 0.5].
    var bad = 0
    for k in [1, 2, 3, 5, 10, 33, 100, 333] {
        var best = Int.min
        for a in 0...k { for b in 0...k where 3 * a + 3 * b <= 3 * k - 1 { best = max(best, a + b) } }
        if best != k - 1 { bad += 1; print("knapsack k=\(k): enum \(best) vs closed form \(k - 1)") }
        var low = Int.max
        for a in 0...(2 * k) { for b in 0...(2 * k) where 3 * a + 3 * b >= 3 * k + 1 { low = min(low, a + b) } }
        if low != k + 1 { bad += 1; print("covering k=\(k): enum \(low) vs closed form \(k + 1)") }
        // mixed: x integer; the best z for feasibility is 0 (it only lowers 2x - z).
        var lx = Int.max
        for x in 0...(4 * k + 4) where 2 * x - 0 >= 2 * k + 1 { lx = min(lx, x) }
        if lx != k + 1 { bad += 1; print("mixed m=\(k): enum \(lx) vs closed form \(k + 1)") }
        // big: 3x >= 3k + 1 -> k + 1
        var bx = Int.max
        for x in -(4 * k)...(4 * k + 4) where 3 * x >= 3 * k + 1 { bx = min(bx, x) }
        if bx != k + 1 { bad += 1; print("big k=\(k): enum \(bx) vs closed form \(k + 1)") }
    }
    print("enumeration vs closed forms: mismatches=\(bad)")
    // Exact checks at full size (Int64): the finder's claimed answers are infeasible, the
    // claimed truths feasible.
    let K: Int64 = 10_000_000
    print("knapsack: 3*(1e7)=\(3 * K) vs rhs \(3 * K - 1) -> violation \(3 * K - (3 * K - 1)); 3*(1e7-1)=\(3 * (K - 1)) feasible=\(3 * (K - 1) <= 3 * K - 1)")
    print("mixed: 2*10000000=\(2 * 10_000_000) < 20000001 (violation >= 1); 2*10000001=\(2 * 10_000_001) >= 20000001")
    print("big: 3*333333333=\(3 * 333_333_333 as Int64) vs 1000000001 -> violation \(1_000_000_001 - 3 * 333_333_333 as Int64); 3*333333334=\(3 * 333_333_334 as Int64) feasible")
}

func extraMode() async throws {
    // The finder's one passing configuration (dual, mostFractional, no heuristics, parallel),
    // on the knapsack and the covering case.
    for c in [try knapsack(1e7), try covering(333_333_333)] {
        let o = try await bb(BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none), c.lp, threads: nil)
        print(judge(c, "\(c.name) BB(dual,mostFractional,none,par)", o).line)
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "core" {
case "extra": try await extraMode()
case "core": try await coreMode()
case "sweep": try await sweepMode()
case "repeat": try await repeatMode(args.count > 2 ? Int(args[2]) ?? 5 : 5)
case "enum": enumMode()
default: print("modes: core | sweep | repeat <n> | enum")
}
