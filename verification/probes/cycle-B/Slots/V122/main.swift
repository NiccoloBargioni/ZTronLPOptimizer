// V122: sceptic (contract lens) for finding B5-01 of cycle B.
// Question: do integral bounds / row sides of magnitude >= 2^50 (accepted by CP-SAT, README
// says "below 2^53") get widened, so that CP-SAT reports .optimal at an infeasible point or with a
// wrong objective? Models are built with the public DSL (the user path) and use a SMALL objective
// (0..10), i.e. the regime README risk 10 calls exact, so the MIP gap cannot explain anything.
// Build: swift build --product V122 -c release   Run: .build/release/V122
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum V: String, LPVariable {
    case x, y
    var domain: VariableDomain { .integer }
}

let p50 = 1125899906842624.0   // 2^50
let p52 = 4503599627370496.0   // 2^52

func fmt(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 9.2e18 ? String(Int64(v)) : String(v)
}

func statusText(_ s: SolveStatus) -> String { "\(s)" }

struct Case {
    let name: String
    let model: LPModel<V>
    let trueOptimum: Double?     // nil = feasibility problem
    let note: String
}

func cases() -> [Case] {
    var out: [Case] = []
    // A: x + y >= K + 3, x <= K, min y. True optimum y = 3, x = K.
    for (label, k) in [("A0 control K=1000", 1000.0), ("A2 K=2^50-8", p50 - 8), ("A1 K=2^50", p50), ("A3 K=2^51", 2 * p50), ("A K=2^52", p52)] {
        let m = LPModel<V>()
            .minimizing(V.y)
            .subjectTo { (V.x + V.y >= k + 3).named("r") }
            .bounding(.x, .range(0...k))
            .bounding(.y, .range(0...10))
        out.append(Case(name: "\(label): x in [0,K], y in [0,10], x + y >= K+3, min y", model: m, trueOptimum: 3, note: "true optimum 3 (x=K, y=3)"))
    }
    // C: equality row, small objective. x in [K, K+20], y in [0,10], x - y == K+1, min y. True optimum 0 at x = K+1.
    for (label, k) in [("C0 control K=1000", 1000.0), ("C K=2^52", p52)] {
        let m = LPModel<V>()
            .minimizing(V.y)
            .subjectTo { (V.x - V.y == k + 1).named("eq") }
            .bounding(.x, .range(k...(k + 20)))
            .bounding(.y, .range(0...10))
        out.append(Case(name: "\(label): x in [K,K+20], y in [0,10], x - y == K+1, min y", model: m, trueOptimum: 0, note: "true optimum 0 at (K+1, 0)"))
    }
    // B: pure bound, objective on an unrelated variable. x in [K+1, K+10]; min y, y in [0,10]. Optimum 0; any x in bounds.
    for (label, k) in [("B0 control K=1000", 1000.0), ("B1 K=2^50+2", p50 + 2), ("B K=2^52", p52)] {
        let m = LPModel<V>()
            .minimizing(V.y)
            .subjectTo { (V.x + V.y >= 0).named("dummy") }
            .bounding(.x, .range((k + 1)...(k + 10)))
            .bounding(.y, .range(0...10))
        out.append(Case(name: "\(label): x in [K+1,K+10], y in [0,10], min y", model: m, trueOptimum: 0, note: "true optimum 0, x must lie in [K+1,K+10]"))
    }
    // U: the upper side of a row (CPModel.swift:335). x in [K, K+20], y in [0,10], x + y <= K+1, max y.
    // True optimum 1 at (K, 1).
    for (label, k) in [("U0 control K=1000", 1000.0), ("U1 K=2^50", p50), ("U K=2^52", p52)] {
        let m = LPModel<V>()
            .maximizing(V.y)
            .subjectTo { (V.x + V.y <= k + 1).named("cap") }
            .bounding(.x, .range(k...(k + 20)))
            .bounding(.y, .range(0...10))
        out.append(Case(name: "\(label): x in [K,K+20], y in [0,10], x + y <= K+1, max y", model: m, trueOptimum: 1, note: "true optimum 1 at (K, 1)"))
    }
    return out
}

let strategies: [(String, CPSAT)] = [
    ("CPSAT()", CPSAT()),
    ("CPSAT(deterministic: true)", CPSAT(deterministic: true)),
    ("CPSAT(lpPropagator: false, deterministic: true)", CPSAT(lpPropagator: false, deterministic: true)),
]

var context = SolveContext()
context.timeLimit = 10

let only = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
var wrong = 0
var total = 0
for c in cases() where only.isEmpty || c.name.hasPrefix(only) {
    let compiled = try c.model.compile()
    let lp = compiled.lp
    print("== \(c.name)  [\(c.note)]")
    print("   compiled: xl=\(lp.xl.map(fmt)) xu=\(lp.xu.map(fmt)) rl=\(lp.rl.map(fmt)) ru=\(lp.ru.map(fmt)) cols=\(lp.names.columns)")
    for (sname, s) in strategies {
        total += 1
        do {
            let sol = try await s.solve(c.model, context: context)
            let x = sol.analysis.primal ?? []
            let viol = x.isEmpty ? (bounds: 0.0, rows: 0.0) : sol.compiled.lp.maxViolation(at: x)
            let obj = sol.objectiveValue
            let objOK = c.trueOptimum.map { t in obj.map { abs($0 - t) < 1e-9 } ?? false } ?? true
            let feasible = viol.bounds == 0 && viol.rows == 0
            let verdict: String
            if sol.status == .optimal && (!feasible || !objOK) {
                verdict = "WRONG (.optimal" + (feasible ? "" : ", infeasible point") + (objOK ? "" : ", wrong objective") + ")"
                wrong += 1
            } else {
                verdict = "ok"
            }
            let named = lp.names.columns.enumerated().map { "\($0.element)=\(x.isEmpty ? "-" : fmt(x[$0.offset]))" }.joined(separator: " ")
            print("   \(sname): status=\(statusText(sol.status)) obj=\(obj.map(fmt) ?? "nil") bound=\(sol.analysis.bound.map(fmt) ?? "nil") \(named) maxViolation(bounds \(viol.bounds), rows \(viol.rows)) -> \(verdict)")
        } catch {
            print("   \(sname): threw \(error)")
        }
    }
}
print("SUMMARY: \(wrong) wrong .optimal results out of \(total) solves")
