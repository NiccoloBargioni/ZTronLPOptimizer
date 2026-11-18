// Probe slot V124 of cycle A: sceptic for A5-02 (CP-SAT, area F5).
// Claim under test: a coefficient that no power of 10 up to 1e6 makes integral (|a| <= 1e-9)
// is zeroed at load instead of rejected with .unsupported.
// Build: swift build --product V124 -c release   Run: .build/release/V124
// Env: V124_LIMIT (CP-SAT time limit, s; default 3), V124_ONLY (comma list of case ids).
//
// Oracle (independent of the finder): the exact optimum over the integers, found by a binary
// search on each monotone row with an error-free evaluation of Σ a·x − r (TwoProduct by fma plus
// TwoSum, i.e. the exact sign for these one- and two-term rows), cross-checked by a different
// engine (BranchAndBound with the simplex, which never scales coefficients to integers).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let limit = Double(ProcessInfo.processInfo.environment["V124_LIMIT"] ?? "3")!
let only = (ProcessInfo.processInfo.environment["V124_ONLY"] ?? "").split(separator: ",").map(String.init)

func ctx(_ t: Double) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = t
    return c
}

func f(_ v: Double?) -> String { v.map { String(format: "%.17g", $0) } ?? "nil" }

// MARK: - Exact evaluation

/// Σ a_k·x_k − r with the products' rounding errors kept (double-double): the sign is exact
/// for the short rows used here.
func exactResidual(_ terms: [(Double, Double)], minus r: Double) -> Double {
    var hi = -r
    var lo = 0.0
    for (a, x) in terms {
        let p = a * x
        let pe = fma(a, x, -p)
        let s = hi + p
        let bp = s - hi
        let err = (hi - (s - bp)) + (p - bp)
        hi = s
        lo += err + pe
    }
    return hi + lo
}

/// Largest integer x in [lo, hi] with pred(x) true, for pred true on a prefix; nil if none.
func largestTrue(_ lo: Double, _ hi: Double, _ pred: (Double) -> Bool) -> Double? {
    guard pred(lo) else { return nil }
    var a = lo, b = hi
    if pred(b) { return b }
    while b - a > 1 {
        let m = ((a + b) / 2).rounded(.down)
        if pred(m) { a = m } else { b = m }
    }
    return a
}

/// Smallest integer x in [lo, hi] with pred(x) true, for pred true on a suffix; nil if none.
func smallestTrue(_ lo: Double, _ hi: Double, _ pred: (Double) -> Bool) -> Double? {
    guard pred(hi) else { return nil }
    var a = lo, b = hi
    if pred(a) { return a }
    while b - a > 1 {
        let m = ((a + b) / 2).rounded(.down)
        if pred(m) { b = m } else { a = m }
    }
    return b
}

// MARK: - Models

func makeLP(
    n: Int, rows: [[(Int, Double)]], rl: [Double], ru: [Double], cost: [Double], maximize: Bool,
    xl: [Double], xu: [Double]
) -> CompiledLP {
    var e: [(row: Int, col: Int, value: Double)] = []
    for (i, r) in rows.enumerated() { for (j, a) in r { e.append((i, j, a)) } }
    // CompiledLP keeps the minimization form: a maximization model has its costs negated.
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, e), c: maximize ? cost.map { -$0 } : cost,
        sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru,
        integerColumns: (0..<n).map { Int32($0) })
}

/// The DSL path a user takes: x integer in [0, 1e9], y binary.
enum V1: LPVariable {
    case x, y
    var domain: VariableDomain {
        switch self {
        case .x: return .integer(.range(0...1e9))
        case .y: return .binary
        }
    }
}

/// The DSL path: z integer in [0, 2e10].
enum V3: LPVariable {
    case z
    var domain: VariableDomain { .integer(.range(0...2e10)) }
}

let configs: [(String, CPSAT)] = [
    ("det", CPSAT(deterministic: true)),
    ("par", CPSAT()),
    ("detnolp", CPSAT(lpPropagator: false, deterministic: true)),
    ("nolp", CPSAT(lpPropagator: false)),
]

func describe(_ a: CPSATAnalysis, _ lp: CompiledLP) -> String {
    var s = "status=\(a.status) obj=\(f(a.objectiveValue)) bound=\(f(a.bound))"
    if let x = a.primal {
        let v = lp.maxViolation(at: x)
        s += " x=[\(x.map { String(format: "%.0f", $0) }.joined(separator: ","))] maxViolation(bounds=\(v.bounds), rows=\(v.rows))"
    }
    return s
}

func runCPSAT(_ id: String, _ lp: CompiledLP) async {
    for (name, s) in configs {
        let t0 = Date()
        do {
            let a = try await s.solve(lp, context: ctx(limit))
            print("  [\(id) \(name)] \(describe(a, lp)) t=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        } catch {
            print("  [\(id) \(name)] THROW \(error) t=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        }
    }
}

func runBnB(_ id: String, _ lp: CompiledLP) async {
    let t0 = Date()
    do {
        let a = try await BranchAndBound(deterministic: true).solve(lp, context: ctx(10))
        var s = "status=\(a.status) obj=\(f(a.objectiveValue))"
        if let x = a.primal { s += " x=[\(x.map { String(format: "%.6f", $0) }.joined(separator: ","))]" }
        print("  [\(id) oracle2 BranchAndBound] \(s) t=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    } catch {
        print("  [\(id) oracle2 BranchAndBound] THROW \(error)")
    }
}

func want(_ id: String) -> Bool { only.isEmpty || only.contains(id) }

let a10 = 1e-10
print("Double(1e-10) = \(String(format: "%.30g", a10)); 1e-10 * 10^k for k = 0...6: \((0...6).map { String(format: "%.3g", a10 * pow(10, Double($0))) })")

// C1: the finder's D3, built with the DSL. max x + y s.t. 1e-10 x + y <= 1, x in [0,1e9], y binary.
if want("C1") {
    print("C1  max x + y  s.t. 1e-10 x + y <= 1, x in [0,1e9] integer, y binary  (DSL; README: .unsupported)")
    // Oracle 1: for each y the largest x with 1e-10 x + y - 1 <= 0, exactly.
    var best: (Double, Double, Double)? = nil
    for y in [0.0, 1.0] {
        if let x = largestTrue(0, 1e9, { exactResidual([(a10, $0), (1, y)], minus: 1) <= 0 }) {
            if best == nil || x + y > best!.2 { best = (x, y, x + y) }
        }
    }
    print("  [C1 oracle1 exact] optimum x=\(f(best?.0)) y=\(f(best?.1)) obj=\(f(best?.2)); point x=1e9,y=1 residual=\(exactResidual([(a10, 1e9), (1, 1)], minus: 1)) (> 0: infeasible)")
    let model = LPModel<V1>().maximizing(V1.x + V1.y).subjectTo { (a10 * V1.x + V1.y <= 1).named("c1") }
    let lp = try! model.compile().lp
    await runBnB("C1", lp)
    for (name, s) in configs {
        do {
            let sol = try await s.solve(model, context: ctx(limit))
            print("  [C1 \(name) typed] status=\(sol.status) obj=\(f(sol.objectiveValue)) x=\(sol.value(of: .x)) y=\(sol.value(of: .y))")
        } catch {
            print("  [C1 \(name) typed] THROW \(error)")
        }
    }
}

// C2: the finder's D3b. max x s.t. 1e-10 x <= 0.05, x in [0,1e9].
if want("C2") {
    print("C2  max x  s.t. 1e-10 x <= 0.05, x in [0,1e9] integer  (README: .unsupported)")
    let x = largestTrue(0, 1e9) { exactResidual([(a10, $0)], minus: 0.05) <= 0 }
    print("  [C2 oracle1 exact] optimum x=\(f(x))")
    let lp = makeLP(n: 1, rows: [[(0, a10)]], rl: [-.infinity], ru: [0.05], cost: [1], maximize: true, xl: [0], xu: [1e9])
    await runBnB("C2", lp)
    await runCPSAT("C2", lp)
}

// C3: a feasible one-row model with a nonzero optimum. min z s.t. 1e-10 z >= 1, z in [0, 2e10].
if want("C3") {
    print("C3  min z  s.t. 1e-10 z >= 1, z in [0,2e10] integer  (DSL; README: .unsupported; feasible, so .infeasible is false)")
    let z = smallestTrue(0, 2e10) { exactResidual([(a10, $0)], minus: 1) >= 0 }
    print("  [C3 oracle1 exact] optimum z=\(f(z)); residual at z=1e10: \(exactResidual([(a10, 1e10)], minus: 1)), at 1e10-1: \(exactResidual([(a10, 1e10 - 1)], minus: 1))")
    let model = LPModel<V3>().minimizing(V3.z.linearExpr).subjectTo { (a10 * V3.z >= 1).named("c1") }
    let lp = try! model.compile().lp
    if let z { print("  [C3 package check] lp.maxViolation(at: [\(f(z))]) = \(lp.maxViolation(at: [z]))") }
    await runBnB("C3", lp)
    await runCPSAT("C3", lp)
}

// C4: a wrong optimum that the final self-check cannot see. max y s.t. 1e-10 x - y >= 0,
// x in [0, 2e10], y binary. The optimum is y = 1 (x >= 1e10).
if want("C4") {
    print("C4  max y  s.t. 1e-10 x - y >= 0, x in [0,2e10] integer, y binary  (README: .unsupported; true optimum 1)")
    var best: Double? = nil
    for y in [0.0, 1.0] where exactResidual([(a10, 2e10), (-1, y)], minus: 0) >= 0 { best = max(best ?? -1, y) }
    print("  [C4 oracle1 exact] optimum obj=\(f(best)) (y=1 at x=2e10: residual \(exactResidual([(a10, 2e10), (-1, 1)], minus: 0)))")
    let lp = makeLP(n: 2, rows: [[(0, a10), (1, -1)]], rl: [0], ru: [.infinity], cost: [0, 1], maximize: true, xl: [0, 0], xu: [2e10, 1])
    print("  [C4 package check] lp.maxViolation(at: [1e10, 1]) = \(lp.maxViolation(at: [1e10, 1]))")
    await runBnB("C4", lp)
    await runCPSAT("C4", lp)
}

// C5: control. The same row as C1 with a small column range: the dropped term is below the
// documented feasibility tolerance (1e-7), so zeroing is harmless here.
if want("C5") {
    print("C5  max x + y  s.t. 1e-10 x + y <= 1, x in [0,10], y binary  (control: drop effect 1e-9)")
    var best: (Double, Double, Double)? = nil
    for y in [0.0, 1.0] {
        if let x = largestTrue(0, 10, { exactResidual([(a10, $0), (1, y)], minus: 1) <= 0 }) {
            if best == nil || x + y > best!.2 { best = (x, y, x + y) }
        }
    }
    print("  [C5 oracle1 exact] optimum x=\(f(best?.0)) y=\(f(best?.1)) obj=\(f(best?.2))")
    let lp = makeLP(n: 2, rows: [[(0, a10), (1, 1)]], rl: [-.infinity], ru: [1], cost: [1, 1], maximize: true, xl: [0, 0], xu: [10, 1])
    await runCPSAT("C5", lp)
}

// C6: where the line between zeroing and rejecting lies. Row a x + y <= 1, x in [0,10], y binary.
if want("C6") {
    print("C6  boundary: a x + y <= 1, x in [0,10], y binary; which a are rejected?")
    for a in [1e-12, 1e-10, 5e-10, 1e-9, 1.0000001e-9, 1.5e-9, 2e-9, 1e-8, 1e-7, 1e-6] {
        let integralAtSomeScale = (0...6).contains { k in
            let v = a * pow(10, Double(k))
            return v == v.rounded() && v != 0
        }
        let lp = makeLP(n: 2, rows: [[(0, a), (1, 1)]], rl: [-.infinity], ru: [1], cost: [1, 1], maximize: true, xl: [0, 0], xu: [10, 1])
        do {
            let r = try await CPSAT(deterministic: true).solve(lp, context: ctx(limit))
            print("  a=\(a) (nonzero integral at some 10^k<=1e6: \(integralAtSomeScale)) -> ACCEPTED \(describe(r, lp))")
        } catch {
            print("  a=\(a) (nonzero integral at some 10^k<=1e6: \(integralAtSomeScale)) -> THROW \(error)")
        }
    }
}

// C3 above went through the DSL, which lowers a one-variable constraint to a column bound
// (Compile.swift, §5.3 rule 5), so CP-SAT never saw the coefficient. The same model built as a
// CompiledLP (what the MPS and LP readers produce) reaches the CP-SAT loader.
if want("C3b") {
    print("C3b min z  s.t. 1e-10 z >= 1, z in [0,2e10] integer  (CompiledLP; true optimum 1e10)")
    let lp = makeLP(n: 1, rows: [[(0, a10)]], rl: [1], ru: [.infinity], cost: [1], maximize: false, xl: [0], xu: [2e10])
    print("  [C3b package check] lp.maxViolation(at: [1e10]) = \(lp.maxViolation(at: [1e10]))")
    await runBnB("C3b", lp)
    await runCPSAT("C3b", lp)
}

/// DSL with a two-term row, which stays a row: z integer in [0, 2e10], w binary.
enum V4: LPVariable {
    case z, w
    var domain: VariableDomain {
        switch self {
        case .z: return .integer(.range(0...2e10))
        case .w: return .binary
        }
    }
}

// C3c: DSL, two terms. min z + w s.t. 1e-10 z - w >= 1. Optimum z = 1e10, w = 0 (obj 1e10).
if want("C3c") {
    print("C3c min z + w  s.t. 1e-10 z - w >= 1, z in [0,2e10] integer, w binary  (DSL; true optimum 1e10)")
    let zmin = smallestTrue(0, 2e10) { exactResidual([(a10, $0), (-1, 0)], minus: 1) >= 0 }
    print("  [C3c oracle1 exact] w=0: smallest z=\(f(zmin)); w=1 needs 1e-10 z >= 2: z >= 2e10 -> \(exactResidual([(a10, 2e10), (-1, 1)], minus: 1) >= 0 ? "feasible at 2e10" : "infeasible")")
    let model = LPModel<V4>().minimizing(V4.z + V4.w).subjectTo { (a10 * V4.z - V4.w >= 1).named("c1") }
    let lp = try! model.compile().lp
    print("  [C3c compiled] m=\(lp.m) n=\(lp.n) nnz=\(lp.nnz) xl=\(lp.xl) xu=\(lp.xu) rl=\(lp.rl) ru=\(lp.ru)")
    await runBnB("C3c", lp)
    for (name, s) in configs {
        do {
            let sol = try await s.solve(model, context: ctx(limit))
            print("  [C3c \(name) typed] status=\(sol.status) obj=\(f(sol.objectiveValue)) z=\(sol.value(of: .z)) w=\(sol.value(of: .w))")
        } catch {
            print("  [C3c \(name) typed] THROW \(error)")
        }
    }
}

// C4d: C4 through the DSL. max w s.t. 1e-10 z - w >= 0. Optimum 1.
if want("C4d") {
    print("C4d max w  s.t. 1e-10 z - w >= 0, z in [0,2e10] integer, w binary  (DSL; true optimum 1)")
    let model = LPModel<V4>().maximizing(V4.w.linearExpr).subjectTo { (a10 * V4.z - V4.w >= 0).named("c1") }
    let lp = try! model.compile().lp
    let compiled = try! model.compile()
    var pt = [Double](repeating: 0, count: lp.n)
    pt[compiled.column[.z]!] = 1e10
    pt[compiled.column[.w]!] = 1
    print("  [C4d compiled] m=\(lp.m) n=\(lp.n) nnz=\(lp.nnz) xl=\(lp.xl) xu=\(lp.xu) rl=\(lp.rl) ru=\(lp.ru); maxViolation(at: z=1e10, w=1 -> \(pt)) = \(lp.maxViolation(at: pt))")
    await runBnB("C4d", lp)
    for (name, s) in configs {
        do {
            let sol = try await s.solve(model, context: ctx(limit))
            print("  [C4d \(name) typed] status=\(sol.status) obj=\(f(sol.objectiveValue)) z=\(sol.value(of: .z)) w=\(sol.value(of: .w))")
        } catch {
            print("  [C4d \(name) typed] THROW \(error)")
        }
    }
}

// C4f: C4 read from an LP file with the package's own reader.
if want("C4f") {
    let text = """
    Maximize
     obj: y
    Subject To
     c1: 1e-10 x - y >= 0
    Bounds
     0 <= x <= 20000000000
    Generals
     x
    Binaries
     y
    End
    """
    print("C4f the C4 model read by LPFormat.read (true optimum 1)")
    do {
        let lp = try LPFormat.read(text)
        print("  [C4f read] m=\(lp.m) n=\(lp.n) sense=\(lp.sense) c=\(lp.c) integer=\(lp.integerColumns) xu=\(lp.xu)")
        await runBnB("C4f", lp)
        await runCPSAT("C4f", lp)
    } catch {
        print("  [C4f read] THROW \(error)")
    }
}

// C7: the objective goes through the same integralScale. min y - 1e-10 x s.t. x - 3e10 y <= 0,
// x in [0,3e10], y binary. Optimum y = 1, x = 3e10: objective 1 - 3 = -2 (y = 0 gives 0).
if want("C7") {
    print("C7  min y - 1e-10 x  s.t. x - 3e10 y <= 0, x in [0,3e10] integer, y binary  (objective path; true optimum -2)")
    let lp = makeLP(n: 2, rows: [[(0, 1), (1, -3e10)]], rl: [-.infinity], ru: [0], cost: [-a10, 1], maximize: false, xl: [0, 0], xu: [3e10, 1])
    print("  [C7 oracle1 exact] objective at (3e10, 1) = \(lp.objective(at: [3e10, 1])), at (0, 0) = \(lp.objective(at: [0, 0])); maxViolation(at: [3e10, 1]) = \(lp.maxViolation(at: [3e10, 1]))")
    await runBnB("C7", lp)
    for (name, s) in configs {
        do {
            let a = try await s.solve(lp, context: ctx(limit))
            let trueObj = a.primal.map { lp.objective(at: $0) }
            print("  [C7 \(name)] \(describe(a, lp)) objectiveRecomputedAtPoint=\(f(trueObj))")
        } catch {
            print("  [C7 \(name)] THROW \(error)")
        }
    }
}
