// Slot V095 (cycle A): contract-lens sceptic of finding A4-02.
// Builds the models through the public modelling DSL (not the finder's CompiledLP helper),
// solves them with BranchAndBound in several configurations and with the facades, and
// measures the returned point with the package's own documented checker,
// CompiledLP.maxViolation(at:), and with the relative measure TreeSearch.isFeasible uses.
// Build: swift build --product V095 -c release   Run: .build/release/V095 [mode]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct Var: LPVariable {
    let id: String
    let domain: VariableDomain
}

func f(_ v: Double?) -> String { v.map { String(format: "%.10g", $0) } ?? "nil" }

struct Case {
    let name: String
    let model: LPModel<Var>
    let truth: Double          // exact optimum, in the model's own sense
}

let intNN = VariableDomain.integer
func intIn(_ lo: Double, _ hi: Double) -> VariableDomain { .integer(.range(lo...hi)) }

func knapsack(_ N: Double, upper: Bool) -> Case {
    // max x1 + x2  s.t. 3x1 + 3x2 <= 3N - 1, x integer >= 0 (optionally <= N); optimum N - 1.
    let a = Var(id: "x1", domain: upper ? intIn(0, N) : intNN)
    let b = Var(id: "x2", domain: upper ? intIn(0, N) : intNN)
    let m = LPModel<Var>().maximizing(1 * a + 1 * b).subjectTo { (3 * a + 3 * b <= 3 * N - 1).named("cap") }
    return Case(name: "knap N=\(f(N)) ub=\(upper)", model: m, truth: N - 1)
}

func production() -> Case {
    // max 7x + 5y s.t. 3x + 2y <= 20,000,001, x,y integer >= 0. Optimum by enumeration below.
    let x = Var(id: "x", domain: intNN), y = Var(id: "y", domain: intNN)
    let m = LPModel<Var>().maximizing(7 * x + 5 * y).subjectTo { (3 * x + 2 * y <= 20_000_001).named("hours") }
    var best = -Double.infinity
    var xi = 0.0
    while 3 * xi <= 20_000_001 {
        let yi = ((20_000_001 - 3 * xi) / 2).rounded(.down)
        best = max(best, 7 * xi + 5 * yi)
        xi += 1
    }
    return Case(name: "production 7x+5y, 3x+2y<=20000001", model: m, truth: best)
}

func mixed() -> Case {
    // min x s.t. 2x - z >= 20,000,001, z continuous in [0, 0.5], x integer >= 0; optimum 10,000,001.
    let x = Var(id: "x", domain: intNN), z = Var(id: "z", domain: .continuous(.range(0...0.5)))
    let m = LPModel<Var>().minimizing(1 * x).subjectTo { (2 * x - 1 * z >= 20_000_001).named("dem") }
    return Case(name: "mixed min x, 2x-z>=20000001, z<=0.5", model: m, truth: 10_000_001)
}

struct Strat {
    let name: String
    let run: (LPModel<Var>, SolveContext) async throws -> (status: SolveStatus, obj: Double?, bound: Double?, x: [Double]?, extra: String)
}

func bnb<E: NodeLPStrategy>(_ name: String, _ s: BranchAndBound<E>) -> Strat {
    Strat(name: name) { m, ctx in
        let sol = try await s.solve(m, context: ctx)
        let a = sol.analysis
        let src = a.incumbentHistory.map { "\($0.source)@\(f($0.objective))" }.joined(separator: ",")
        return (a.status, a.objectiveValue, a.bound, a.primal, "rootLP=\(f(a.root.objectiveValue)) nodes=\(a.nodesProcessed) hist=[\(src)] warnings=\(a.warnings)")
    }
}

func any<S: SolverStrategy>(_ name: String, _ s: S) -> Strat {
    Strat(name: name) { m, ctx in
        let sol = try await s.solve(m, context: ctx)
        let a = sol.analysis
        return (a.status, a.objectiveValue, a.bound, a.primal, "warnings=\(a.warnings)")
    }
}

func strategies(pureInteger: Bool) -> [Strat] {
    var list: [Strat] = [
        bnb("BnB()", BranchAndBound()),
        bnb("BnB(det)", BranchAndBound(deterministic: true)),
        bnb("BnB(dual)", BranchAndBound(engine: Simplex(.dual))),
        bnb("BnB(gap 0)", BranchAndBound(gap: Gap(relative: 0, absolute: 0))),
        bnb("BnB(rounding only)", BranchAndBound(heuristics: Heuristics(rounding: true, diving: false))),
        bnb("BnB(diving only)", BranchAndBound(heuristics: Heuristics(rounding: false, diving: true))),
        bnb("BnB(heur none)", BranchAndBound(heuristics: .none)),
        any("Automatic()", Automatic()),
        any("Conditioned(Automatic())", Conditioned(Automatic())),
    ]
    if pureInteger {
        list.append(any("CPSAT()", CPSAT()))
        list.append(any("Portfolio([BnB(),CPSAT()])", Portfolio([BranchAndBound(), CPSAT()])))
    }
    return list
}

func evaluate(_ c: Case, _ strats: [Strat]) async {
    print("== \(c.name)  [exact optimum \(f(c.truth))]")
    let compiled: CompiledModel<Var>
    do { compiled = try c.model.compile() } catch { print("  compile error \(error)"); return }
    let lp = compiled.lp
    for s in strats {
        var ctx = SolveContext()
        ctx.timeLimit = 60
        do {
            let r = try await s.run(c.model, ctx)
            var violText = "-"
            if let x = r.x, x.count == lp.n {
                let v = lp.maxViolation(at: x)
                // The relative measure of TreeSearch.isFeasible: violation / (1 + |bound|).
                let act = lp.rowActivity(x)
                var rel = 0.0
                for i in 0..<lp.m {
                    if act[i] < lp.rl[i] { rel = max(rel, (lp.rl[i] - act[i]) / (1 + abs(lp.rl[i]))) }
                    if act[i] > lp.ru[i] { rel = max(rel, (act[i] - lp.ru[i]) / (1 + abs(lp.ru[i]))) }
                }
                violText = "absRowViol=\(f(v.rows)) absBndViol=\(f(v.bounds)) relRowViol=\(String(format: "%.2e", rel)) x=\(x.map { f($0) })"
            }
            let wrong: String
            if let o = r.obj, r.status == .optimal || r.status.hasSolution {
                wrong = abs(o - c.truth) <= 1e-9 * max(1, abs(c.truth)) ? "EXACT" : (
                    (lp.sense == .maximize ? o > c.truth : o < c.truth) ? "SUPEROPTIMAL(by \(f(abs(o - c.truth))))" : "suboptimal(by \(f(abs(o - c.truth))))")
            } else { wrong = "no-solution" }
            print("  \(s.name): \(r.status) obj=\(f(r.obj)) bound=\(f(r.bound)) \(wrong) \(violText) \(r.extra)")
        } catch {
            print("  \(s.name): threw \(error)")
        }
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
if mode == "all" || mode == "main" {
    await evaluate(knapsack(1e7, upper: true), strategies(pureInteger: true))
    await evaluate(knapsack(1e7, upper: false), strategies(pureInteger: true))
    await evaluate(production(), strategies(pureInteger: true))
    await evaluate(mixed(), strategies(pureInteger: false))
}
if mode == "all" || mode == "threshold" {
    // isFeasible accepts violation 1 on rhs 3N-1 iff 1 <= 1e-7*(1 + 3N - 1) = 3e-7*N, i.e. N >= 3.34e6.
    let s = [bnb("BnB(det)", BranchAndBound(deterministic: true)), bnb("BnB(det, heur none)", BranchAndBound(heuristics: .none, deterministic: true))]
    for N in [10.0, 1e3, 1e5, 1e6, 3e6, 3.3e6, 3.4e6, 4e6, 1e7, 1e8] {
        await evaluate(knapsack(N, upper: true), s)
    }
}

if mode == "scaled" {
    // What "Bound/row violation allowed, after scaling" (Tolerances.primalFeasibility doc) means
    // for the point B&B returns: scaled row violation = rows[i] * (unscaled violation).
    for c in [knapsack(1e7, upper: true), production(), mixed()] {
        let lp = try c.model.compile().lp
        var ctx = SolveContext(); ctx.timeLimit = 60
        let a = try await BranchAndBound(deterministic: true).solve(lp, context: ctx)
        guard let x = a.primal else { print("\(c.name): no point"); continue }
        let act = lp.rowActivity(x)
        for mode in [ScalingMode.geometricEquilibration, .equilibration] {
            let s = Scaler.factors(for: lp, mode: mode)
            var worst = 0.0
            for i in 0..<lp.m {
                let v = max(lp.rl[i] - act[i], act[i] - lp.ru[i], 0)
                worst = max(worst, (s.rows.isEmpty ? 1 : s.rows[i]) * v)
            }
            print("\(c.name): status=\(a.status) obj=\(f(a.objectiveValue)) scaling=\(mode) rowFactors=\(s.rows) colFactors=\(s.columns) scaledRowViolation=\(f(worst)) vs primalFeasibility 1e-7 -> \(String(format: "%.1e", worst / 1e-7))x over")
        }
    }
}
