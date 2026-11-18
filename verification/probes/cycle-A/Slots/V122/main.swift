// Probe V122 (cycle A): contract sceptic for finding A5-01 (CP-SAT snap tolerance at |v| >= 2^49).
// Builds the models through the public DSL (LPModel -> compile) and solves them with CP-SAT in three
// configurations, plus BranchAndBound for context. Exact optima are computed independently in Int64.
// Build: swift build --product V122 -c release   Run: .build/release/V122
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let p48 = Double(Int64(1) << 48)
let p49 = Double(Int64(1) << 49)
let p50 = Double(Int64(1) << 50)
let p52 = Double(Int64(1) << 52)
let p53 = Double(Int64(1) << 53)

func f(_ v: Double?) -> String { v.map { String(format: "%.17g", $0) } ?? "nil" }

func st(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infeasibleOrUnbounded"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let m): return "numericalFailure(\(m))"
    }
}

func ctx() -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 5
    return c
}

// Two-variable family; per-case domains are passed through a global the domain reads.
nonisolated(unsafe) var domX = VariableDomain.integer(.range(0...1))
nonisolated(unsafe) var domY = VariableDomain.integer(.range(0...1))
enum V: LPVariable {
    case x, y
    var domain: VariableDomain { self == .x ? domX : domY }
}

func run<S: SolverStrategy>(_ label: String, _ model: LPModel<V>, _ strategy: S, exact: String) async {
    do {
        let s = try await strategy.solve(model, context: ctx())
        var line = "\(label) [\(strategy.engineName)]: \(st(s.status)) obj=\(f(s.objectiveValue)) x=\(f(s.value(of: .x))) y=\(f(s.value(of: .y)))"
        if let p = s.analysis.primal {
            let v = s.compiled.lp.maxViolation(at: p)
            line += " maxViolation(bounds=\(v.bounds), rows=\(v.rows))"
        }
        print(line + " | exact: \(exact)")
    } catch {
        print("\(label) [\(strategy.engineName)]: THROW \(error) | exact: \(exact)")
    }
}

func allEngines(_ label: String, _ model: LPModel<V>, exact: String, bnb: Bool = true) async {
    await run(label + " det", model, CPSAT(deterministic: true), exact: exact)
    await run(label + " par", model, CPSAT(), exact: exact)
    await run(label + " det-noLP", model, CPSAT(lpPropagator: false, deterministic: true), exact: exact)
    if bnb { await run(label + " (context)", model, BranchAndBound(), exact: exact) }
}

// Exact optimum of: x fixed at b, y in [0,10], x + y <= b, maximize y  (Int64 enumeration)
func exactA(_ b: Int64) -> String {
    var best: Int64? = nil
    for y in Int64(0)...10 where b + y <= b { best = max(best ?? y, y) }
    return "max y = \(best.map(String.init) ?? "infeasible")"
}

// --- A: fixed column and row side at 2^52+1, 2^50+1, 2^48+1 (control) -----------------------------
for (name, b) in [("A52", p52 + 1), ("A50", p50 + 1), ("A48-control", p48 + 1)] {
    domX = .integer(.fixed(b))
    domY = .integer(.range(0...10))
    let m = LPModel<V>()
        .maximizing(1.0 * V.y)
        .subjectTo { (V.x + V.y <= b).named("r") }
    await allEngines("\(name) x=\(f(b)) fixed, x+y<=\(f(b)), max y", m, exact: exactA(Int64(b)))
}

// --- B: coefficient 1e15+0.5 (exactly representable), x binary, y in [0,3], min y ------------------
do {
    domX = .binary
    domY = .integer(.range(0...3))
    let m = LPModel<V>()
        .minimizing(1.0 * V.y)
        .subjectTo { ((1e15 + 0.5) * V.x + V.y >= 1e15 + 1).named("r") }
    // Exact in Int64 after doubling: (2e15+1) x + 2y >= 2e15+2
    var best: Int64? = nil
    for x in Int64(0)...1 { for y in Int64(0)...3 where (2_000_000_000_000_001 * x + 2 * y) >= 2_000_000_000_000_002 { best = min(best ?? y, y) } }
    await allEngines("B (1e15+0.5)x+y>=1e15+1, min y", m, exact: "min y = \(best.map(String.init) ?? "infeasible")")
}

// --- C: column bound 2^52+1, max x -------------------------------------------------------------------
do {
    domX = .integer(.range(0...(p52 + 1)))
    domY = .integer(.range(0...0))
    let m = LPModel<V>().maximizing(1.0 * V.x).subjectTo { (V.x + V.y >= 0).named("r") }
    await allEngines("C x<=2^52+1, max x", m, exact: "\(Int64(p52) + 1)", bnb: false)
}

// --- D: fractional row side 2^49+0.5 (exactly representable), max x ---------------------------------
do {
    domX = .integer(.range(0...p50))
    domY = .integer(.range(0...0))
    let m = LPModel<V>().maximizing(1.0 * V.x).subjectTo { (V.x + V.y <= p49 + 0.5).named("r") }
    await allEngines("D row x<=2^49+0.5, max x", m, exact: "\(Int64(p49)) (inward rounding)", bnb: false)
}

// --- E: the 2^53 edge: xu = 2^53-5 accepted? and its value ------------------------------------------
for d in [1.0, 4.0, 5.0] {
    domX = .integer(.range(0...(p53 - d)))
    domY = .integer(.range(0...0))
    let m = LPModel<V>().maximizing(1.0 * V.x).subjectTo { (V.x + V.y >= 0).named("r") }
    await allEngines("E x<=2^53-\(Int(d)), max x", m, exact: "\(Int64(p53) - Int64(d)) (README: accepted below 2^53)", bnb: false)
}
print("done")
