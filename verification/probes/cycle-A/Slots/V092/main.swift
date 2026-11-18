// Slot V092, cycle A: contract-lens sceptic for finding A4-01 (LP-integral node point rounded and
// accepted as incumbent without a feasibility re-check). Independent of the finder's helpers: every
// model is built through the public modelling DSL.
// Build: swift build --product V092 -c release   Run: .build/release/V092
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)

func ctx(_ seconds: Double = 30, threads: Int? = nil) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    if let threads { c.threads = threads }
    return c
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.9g", $0) } ?? "nil" }

/// Prints status, objective, bound, the point, c.x at the point, its violation and the incumbent sources.
func run<V: LPVariable, S: SolverStrategy>(_ label: String, _ strategy: S, _ model: LPModel<V>, threads: Int? = nil) async {
    do {
        let s = try await strategy.solve(model, context: ctx(threads: threads))
        let lp = s.compiled.lp
        var history: [IncumbentEvent]? = nil
        if let a = s.analysis as? BranchAndBoundAnalysis<SimplexAnalysis> { history = a.incumbentHistory }
        if let a = s.analysis as? BranchAndBoundAnalysis<InteriorPointAnalysis> { history = a.incumbentHistory }
        if let a = s.analysis as? AnySolutionAnalysis {
            history = a.unwrap(as: BranchAndBoundAnalysis<SimplexAnalysis>.self)?.incumbentHistory
        }
        let point = s.analysis.primal
        let violation = point.map { lp.maxViolation(at: $0) }
        let cx = point.map { lp.objective(at: $0) }
        let values = s.compiled.variableAt.map { "\($0)=\(fmt(s.value(of: $0)))" }.joined(separator: " ")
        var line = "\(label): status=\(s.status) obj=\(fmt(s.objectiveValue)) bound=\(fmt(s.analysis.bound)) [\(values)]"
        line += " c.x=\(fmt(cx)) viol(bounds \(fmt(violation?.bounds)), rows \(fmt(violation?.rows)))"
        if let history { line += " sources=\(history.map(\.source))" }
        if !s.analysis.warnings.isEmpty { line += " warnings=\(s.analysis.warnings)" }
        if let c = s.analysis as? ConditionedAnalysis<AnySolutionAnalysis> {
            line += " conditioning=\(c.report.findings.map { "\($0.severity):\($0.message)" })"
        }
        print(line)
    } catch {
        print("\(label): THROW \(error)")
    }
}

// MARK: - Shape 1: fixed charge  min 100·open + flow,  flow ≥ d,  flow ≤ M·open,  open binary, flow ∈ [0, 10]

enum FC: LPVariable {
    case open, flow
    var domain: VariableDomain {
        switch self {
        case .open: return .binary
        case .flow: return .continuous(.range(0...10))
        }
    }
}

func fixedCharge(demand: Double, bigM: Double) -> LPModel<FC> {
    LPModel<FC>()
        .minimizing(100 * FC.open + FC.flow)
        .subjectTo {
            (FC.flow >= demand).named("demand")
            (FC.flow <= bigM * FC.open).named("link")
        }
}

// MARK: - Shape 2: pure integer  min a + b,  1e7·a + 1e7·b ≥ 5,  a, b integer in [0, 10]

enum P2: LPVariable {
    case a, b
    var domain: VariableDomain { .integer(.range(0...10)) }
}

let shape2 = LPModel<P2>().minimizing(P2.a + P2.b).subjectTo { (1e7 * P2.a + 1e7 * P2.b >= 5).named("r") }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

if mode == "all" || mode == "relax" {
    print("== causal story: the LP relaxations ==")
    let relaxed1 = fixedCharge(demand: 0.5, bigM: 1e6).continuous(.open)
    for (name, s) in [("Simplex(.primal)", Simplex(.primal)), ("Simplex(.dual)", Simplex(.dual))] {
        let r = try await s.solve(relaxed1, context: ctx())
        let lp = r.compiled.lp
        let x = r.analysis.primal!
        let open = r.value(of: .open)
        var rounded = x
        rounded[r.compiled.column[.open]!] = open.rounded()
        print("shape1 LP \(name): status=\(r.status) obj=\(fmt(r.objectiveValue)) open=\(fmt(open)) |open-round|=\(fmt(abs(open - open.rounded()))) (<= 1e-6: \(abs(open - open.rounded()) <= 1e-6)) flow=\(fmt(r.value(of: .flow))) LP-point rowViol=\(fmt(lp.maxViolation(at: x).rows)) | rounded point rowViol=\(fmt(lp.maxViolation(at: rounded).rows)) c.x(rounded)=\(fmt(lp.objective(at: rounded)))")
    }
    let relaxed2 = shape2.continuous(.a).continuous(.b)
    let r2 = try await Simplex(.dual).solve(relaxed2, context: ctx())
    print("shape2 LP Simplex(.dual): status=\(r2.status) obj=\(fmt(r2.objectiveValue)) a=\(fmt(r2.value(of: .a))) b=\(fmt(r2.value(of: .b)))")
}

if mode == "all" || mode == "bigm" {
    print("== shape 1, d = 0.5, M = 1e6 (true optimum: open = 1, flow = 0.5, objective 100.5) ==")
    let m = fixedCharge(demand: 0.5, bigM: 1e6)
    await run("BranchAndBound()", BranchAndBound(), m)
    await run("BranchAndBound(deterministic)", BranchAndBound(deterministic: true), m)
    await run("BranchAndBound(Simplex(.dual))", BranchAndBound(engine: Simplex(.dual)), m)
    await run("BranchAndBound(InteriorPoint())", BranchAndBound(engine: InteriorPoint()), m)
    await run("BranchAndBound(threads 4, heuristics none)", BranchAndBound(heuristics: .none), m, threads: 4)
    await run("BranchAndBound(tight gap 1e-9/1e-12)", BranchAndBound(gap: Gap(relative: 1e-9, absolute: 1e-12)), m)
    await run("Automatic()", Automatic(), m)
    await run("Conditioned(Automatic())", Conditioned(Automatic()), m)
    print("== shape 1 with M = 1e7, d = 5 (true optimum 105) ==")
    await run("BranchAndBound()", BranchAndBound(), fixedCharge(demand: 5, bigM: 1e7))
    await run("Automatic()", Automatic(), fixedCharge(demand: 5, bigM: 1e7))
}

if mode == "all" || mode == "sweep" {
    print("== threshold: M = 1e6, LP puts open = d·1e-6; accepted unchecked iff d·1e-6 <= 1e-6 (true optimum 100 + d) ==")
    for d in [0.5, 0.9, 1.0, 1.01, 1.5, 2.0] {
        await run("d=\(d) BranchAndBound(deterministic)", BranchAndBound(deterministic: true), fixedCharge(demand: d, bigM: 1e6))
    }
}

if mode == "all" || mode == "shape2" {
    print("== shape 2 (true optimum 1, at a + b = 1) ==")
    await run("BranchAndBound()", BranchAndBound(), shape2)
    await run("BranchAndBound(Simplex(.dual), deterministic)", BranchAndBound(engine: Simplex(.dual), deterministic: true), shape2)
    await run("Automatic()", Automatic(), shape2)
    await run("CPSAT()", CPSAT(), shape2)
    await run("Portfolio([BranchAndBound(), CPSAT()])", Portfolio([BranchAndBound(), CPSAT()]), shape2)
}
