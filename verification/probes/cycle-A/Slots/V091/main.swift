// Cycle A, slot V091: independent REPRODUCE check of finding A4-01 (branch and bound accepts a
// rounded LP-integral point without a feasibility check).
//
// Written from the finding's description only. Models are built with the public DSL (the
// user-facing path), the expected answers come from hand derivation and brute-force
// enumeration in this file, and every returned point is checked against the model's own
// coefficients here (no package helper such as maxViolation is used as the oracle).
//
// Modes:  all (default) | main | scan | repeat | engines
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Independent checker

/// One row of a model, written out by hand: lo <= sum coef*var <= hi.
struct Row<V: Hashable> {
    let name: String
    let coef: [(V, Double)]
    let lo: Double
    let hi: Double
}

struct Spec<V: LPVariable> {
    let vars: [V]
    let cost: [V: Double]
    let rows: [Row<V>]
    let lo: [V: Double]
    let hi: [V: Double]
    let integer: Set<V>
}

struct Check {
    var boundViol = 0.0
    var rowViol = 0.0
    var worstRow = ""
    var integrality = 0.0
    var cx = 0.0
}

func check<V>(_ spec: Spec<V>, _ value: (V) -> Double) -> Check {
    var r = Check()
    for v in spec.vars {
        let x = value(v)
        r.boundViol = max(r.boundViol, spec.lo[v]! - x, x - spec.hi[v]!)
        if spec.integer.contains(v) { r.integrality = max(r.integrality, abs(x - x.rounded())) }
        r.cx += (spec.cost[v] ?? 0) * x
    }
    for row in spec.rows {
        var act = 0.0
        for (v, a) in row.coef { act += a * value(v) }
        let viol = max(0, row.lo - act, act - row.hi)
        if viol > r.rowViol { r.rowViol = viol; r.worstRow = "\(row.name) act=\(act) in [\(row.lo), \(row.hi)]" }
    }
    return r
}

// MARK: - Models

/// Fixed charge, one flow: min 100*open + flow; flow >= 0.5; flow - M*open <= 0; open binary,
/// flow in [0, 10]. The one-variable demand row is lowered to a bound by compile().
enum FC: LPVariable {
    case open, flow
    var domain: VariableDomain {
        switch self {
        case .open: return .binary
        case .flow: return .continuous(.range(0...10))
        }
    }
}

func fcModel(_ M: Double) -> LPModel<FC> {
    LPModel<FC>()
        .minimizing(100 * FC.open + FC.flow)
        .subjectTo {
            (FC.flow >= 0.5).named("demand")
            (FC.flow - M * FC.open <= 0).named("link")
        }
}

func fcSpec(_ M: Double) -> Spec<FC> {
    Spec(
        vars: [.open, .flow], cost: [.open: 100, .flow: 1],
        rows: [Row(name: "demand", coef: [(.flow, 1)], lo: 0.5, hi: .infinity),
               Row(name: "link", coef: [(.flow, 1), (.open, -M)], lo: -.infinity, hi: 0)],
        lo: [.open: 0, .flow: 0], hi: [.open: 1, .flow: 10], integer: [.open])
}

/// Fixed charge, two flows, so that demand stays a real two-column row:
/// min 100*open + a + b; a + b >= 0.5; a + b - M*open <= 0; open binary; a, b in [0, 10].
enum FC2: LPVariable {
    case open, a, b
    var domain: VariableDomain {
        switch self {
        case .open: return .binary
        default: return .continuous(.range(0...10))
        }
    }
}

func fc2Model(_ M: Double) -> LPModel<FC2> {
    LPModel<FC2>()
        .minimizing(100 * FC2.open + FC2.a + FC2.b)
        .subjectTo {
            (FC2.a + FC2.b >= 0.5).named("demand")
            (FC2.a + FC2.b - M * FC2.open <= 0).named("link")
        }
}

func fc2Spec(_ M: Double) -> Spec<FC2> {
    Spec(
        vars: [.open, .a, .b], cost: [.open: 100, .a: 1, .b: 1],
        rows: [Row(name: "demand", coef: [(.a, 1), (.b, 1)], lo: 0.5, hi: .infinity),
               Row(name: "link", coef: [(.a, 1), (.b, 1), (.open, -M)], lo: -.infinity, hi: 0)],
        lo: [.open: 0, .a: 0, .b: 0], hi: [.open: 1, .a: 10, .b: 10], integer: [.open])
}

/// Pure integer: min p + q; 1e7 p + 1e7 q >= 5; p, q integer in [0, 10].
enum PI: LPVariable {
    case p, q
    var domain: VariableDomain { .integer(.range(0...10)) }
}

let piModel = LPModel<PI>()
    .minimizing(PI.p + PI.q)
    .subjectTo { (1e7 * PI.p + 1e7 * PI.q >= 5).named("cover") }

let piSpec = Spec<PI>(
    vars: [.p, .q], cost: [.p: 1, .q: 1],
    rows: [Row(name: "cover", coef: [(.p, 1e7), (.q, 1e7)], lo: 5, hi: .infinity)],
    lo: [.p: 0, .q: 0], hi: [.p: 10, .q: 10], integer: [.p, .q])

// MARK: - Oracles (hand derivation + enumeration, no solver involved)

/// FC / FC2: open in {0, 1}. open = 0 forces total flow <= 0 < 0.5: infeasible. open = 1 leaves
/// total flow in [0.5, min(cap, M)]; the cheapest is 0.5, objective 100 + 0.5 = 100.5. The scan
/// below confirms it by enumerating open and a fine grid of flow values.
func fcOracleByEnumeration(_ M: Double) -> (best: Double, open: Double, flow: Double) {
    var best = (best: Double.infinity, open: Double.nan, flow: Double.nan)
    for open in [0.0, 1.0] {
        for k in 0...10_000 {            // flow = k / 1000 in [0, 10]
            let flow = Double(k) / 1000
            let spec = fcSpec(M)
            let c = check(spec) { $0 == .open ? open : flow }
            if c.rowViol == 0, c.boundViol <= 0, c.cx < best.best { best = (c.cx, open, flow) }
        }
    }
    return best
}

func piOracleByEnumeration() -> (best: Double, p: Double, q: Double) {
    var best = (best: Double.infinity, p: Double.nan, q: Double.nan)
    for p in 0...10 {
        for q in 0...10 {
            let c = check(piSpec) { $0 == .p ? Double(p) : Double(q) }
            if c.rowViol == 0, c.cx < best.best { best = (c.cx, Double(p), Double(q)) }
        }
    }
    return best
}

// MARK: - Running

struct Outcome: Hashable {
    var status: String
    var objective: String
    var bound: String
    var point: String
    var check: String
    var sources: String
    var warnings: String
}

func ctx(threads: Int? = nil) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 20
    if let threads { c.threads = threads }
    return c
}

func describe<V, A: SolutionAnalysis>(_ s: Solution<V, A>, _ spec: Spec<V>, sources: [String]) -> Outcome {
    let point = spec.vars.map { "\($0)=\(s.value(of: $0))" }.joined(separator: " ")
    let c = check(spec) { s.value(of: $0) }
    let obj = s.objectiveValue
    let mismatch = obj.map { abs($0 - c.cx) } ?? .nan
    return Outcome(
        status: "\(s.status)",
        objective: obj.map { "\($0)" } ?? "nil",
        bound: s.analysis.bound.map { "\($0)" } ?? "nil",
        point: point,
        check: "rowViol=\(c.rowViol) [\(c.worstRow)] boundViol=\(max(0, c.boundViol)) intViol=\(c.integrality) c.x=\(c.cx) |obj-c.x|=\(mismatch)",
        sources: sources.joined(separator: ","),
        warnings: s.analysis.warnings.joined(separator: " | "))
}

func runBB<V, E: NodeLPStrategy>(_ s: BranchAndBound<E>, _ m: LPModel<V>, _ spec: Spec<V>, threads: Int? = nil) async -> Outcome {
    do {
        let sol = try await s.solve(m, context: ctx(threads: threads))
        return describe(sol, spec, sources: sol.analysis.incumbentHistory.map { "\($0.source)@node\($0.node)" })
    } catch {
        return Outcome(status: "THREW \(error)", objective: "", bound: "", point: "", check: "", sources: "", warnings: "")
    }
}

func runAny<V, S: SolverStrategy>(_ s: S, _ m: LPModel<V>, _ spec: Spec<V>, threads: Int? = nil) async -> Outcome {
    do {
        let sol = try await s.solve(m, context: ctx(threads: threads))
        var sources: [String] = []
        if let any = sol.analysis as? AnySolutionAnalysis,
           let bb = any.unwrap(as: BranchAndBoundAnalysis<Simplex.Analysis>.self) {
            sources = bb.incumbentHistory.map { "\($0.source)@node\($0.node)" }
        }
        return describe(sol, spec, sources: sources)
    } catch {
        return Outcome(status: "THREW \(error)", objective: "", bound: "", point: "", check: "", sources: "", warnings: "")
    }
}

func show(_ name: String, _ o: Outcome) {
    print("  \(name): status=\(o.status) obj=\(o.objective) bound=\(o.bound) point{\(o.point)}")
    print("      check: \(o.check)")
    print("      incumbent sources: [\(o.sources)]  warnings: [\(o.warnings)]")
}

/// The B&B configurations exercised for a model.
func configs<V>(_ m: LPModel<V>, _ spec: Spec<V>) -> [(String, () async -> Outcome)] {
    [
        ("Automatic()", { await runAny(Automatic(), m, spec) }),
        ("Conditioned(Automatic())", { await runAny(Conditioned(Automatic()), m, spec) }),
        ("BB<Simplex.primal> default", { await runBB(BranchAndBound(engine: Simplex(.primal)), m, spec) }),
        ("BB<Simplex.dual> deterministic", { await runBB(BranchAndBound(engine: Simplex(.dual), deterministic: true), m, spec) }),
        ("BB<InteriorPoint> default", { await runBB(BranchAndBound(engine: InteriorPoint()), m, spec) }),
        ("BB<Simplex.primal> heuristics none, mostFractional", {
            await runBB(BranchAndBound(engine: Simplex(.primal), branching: .mostFractional, heuristics: .none), m, spec) }),
        ("BB<Simplex.dual> gap 0/0", {
            await runBB(BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0)), m, spec) }),
        ("BB<Simplex.primal presolve:false scaling:none> threads 8", {
            await runBB(BranchAndBound(engine: Simplex(.primal, presolve: false, scaling: .none)), m, spec, threads: 8) }),
        ("BB<Simplex.dual> strong(6) bestBound threads 4", {
            await runBB(BranchAndBound(engine: Simplex(.dual), branching: .strong(candidates: 6), nodeSelection: .bestBound), m, spec, threads: 4) }),
    ]
}

// MARK: - Modes

func mainMode() async {
    let M = 1e6
    let fcOracle = fcOracleByEnumeration(M)
    print("== FC (one flow), M = \(M)")
    print("  oracle (hand + enumeration over open in {0,1}, flow grid step 1e-3): best \(fcOracle.best) at open=\(fcOracle.open) flow=\(fcOracle.flow)")
    for (name, run) in configs(fcModel(M), fcSpec(M)) { show(name, await run()) }

    print("== FC2 (two flows, demand is a 2-column row), M = \(M)")
    for (name, run) in configs(fc2Model(M), fc2Spec(M)) { show(name, await run()) }

    let piOracle = piOracleByEnumeration()
    print("== PI (pure integer, 1e7 p + 1e7 q >= 5)")
    print("  oracle (enumeration over 0...10 x 0...10): best \(piOracle.best) at p=\(piOracle.p) q=\(piOracle.q)")
    for (name, run) in configs(piModel, piSpec) { show(name, await run()) }
    do {
        let s = try await CPSAT(deterministic: true).solve(piModel, context: ctx())
        show("CPSAT(deterministic) [second engine]", describe(s, piSpec, sources: []))
    } catch { print("  CPSAT threw \(error)") }
}

/// The second-engine check of the oracle for FC: fix open and solve the remaining LP with the
/// simplex (no integrality left), and look at the LP relaxation itself.
func enginesMode() async {
    let M = 1e6
    print("== FC, M = \(M): LP cross-check with open fixed (Simplex .dual and InteriorPoint)")
    for open in [0.0, 1.0] {
        let lp = fcModel(M).continuous(.open).bounding(.open, .fixed(open))
        do {
            let a = try await Simplex(.dual).solve(lp, context: ctx())
            let b = try await InteriorPoint().solve(lp, context: ctx())
            print("  open fixed \(open): Simplex.dual status=\(a.status) obj=\(a.objectiveValue.map { "\($0)" } ?? "nil"); InteriorPoint status=\(b.status) obj=\(b.objectiveValue.map { "\($0)" } ?? "nil")")
        } catch { print("  threw \(error)") }
    }
    do {
        let relaxed = fcModel(M).continuous(.open)
        let r = try await Simplex(.dual).solve(relaxed, context: ctx())
        print("  LP relaxation: status=\(r.status) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") open=\(r.value(of: .open)) flow=\(r.value(of: .flow)); |open - round(open)| = \(abs(r.value(of: .open) - r.value(of: .open).rounded())) vs Tolerances.default.integrality = \(Tolerances.default.integrality)")
    } catch { print("  threw \(error)") }
    do {
        let relaxed = piModel.continuous(forEach: [PI.p, PI.q], { $0 })
        let r = try await Simplex(.dual).solve(relaxed, context: ctx())
        print("  PI LP relaxation: status=\(r.status) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") p=\(r.value(of: .p)) q=\(r.value(of: .q))")
    } catch { print("  threw \(error)") }
}

/// Mechanism: the LP relaxation puts open = 0.5 / M. The finding predicts a wrong answer
/// exactly when that is within the integrality tolerance (1e-6), i.e. for M >= 5e5.
func scanMode() async {
    print("== FC scan over M (LP open = 0.5/M; integrality tolerance 1e-6)")
    for M in [1e3, 1e4, 1e5, 4e5, 6e5, 1e6, 1e7, 1e9] {
        let oracle = fcOracleByEnumeration(M)
        let det = await runBB(BranchAndBound(engine: Simplex(.dual), deterministic: true), fcModel(M), fcSpec(M))
        let auto = await runAny(Automatic(), fcModel(M), fcSpec(M))
        print("  M=\(M) LP open=\(0.5 / M) oracle=\(oracle.best)")
        show("    BB<dual> det", det)
        show("    Automatic", auto)
    }
}

/// Load / randomness: the same solve many times, sequentially and concurrently, with several
/// seeds and thread counts; the distinct outcomes are counted.
func repeatMode() async {
    let M = 1e6
    var seen: [Outcome: Int] = [:]
    for rep in 0..<5 {
        for seed in [UInt64(0), 1, 7, 12345] {
            for threads in [1, 2, 8] {
                let o = await runBB(BranchAndBound(engine: Simplex(.primal), seed: seed), fcModel(M), fcSpec(M), threads: threads)
                var key = o; key.sources = key.sources.replacingOccurrences(of: #"@node\d+"#, with: "", options: .regularExpression)
                seen[key, default: 0] += 1
            }
        }
        let a = await runAny(Automatic(), fcModel(M), fcSpec(M))
        seen[a, default: 0] += 1
        _ = rep
    }
    // 16 concurrent solves to add load from this process itself.
    let concurrent = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
        for _ in 0..<16 { group.addTask { await runAny(Automatic(), fcModel(M), fcSpec(M), threads: 8) } }
        var all: [Outcome] = []
        for await o in group { all.append(o) }
        return all
    }
    for o in concurrent { seen[o, default: 0] += 1 }
    print("== FC repeat: \(seen.values.reduce(0, +)) solves, \(seen.count) distinct outcome(s)")
    for (o, n) in seen { print("  x\(n): status=\(o.status) obj=\(o.objective) point{\(o.point)} \(o.check) sources=[\(o.sources)]") }

    var piSeen: [Outcome: Int] = [:]
    for rep in 0..<5 {
        for threads in [1, 8] {
            let o = await runAny(Automatic(), piModel, piSpec, threads: threads)
            piSeen[o, default: 0] += 1
        }
        _ = rep
    }
    print("== PI repeat via Automatic: \(piSeen.values.reduce(0, +)) solves, \(piSeen.count) distinct outcome(s)")
    for (o, n) in piSeen { print("  x\(n): status=\(o.status) obj=\(o.objective) point{\(o.point)} \(o.check)") }
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
switch mode {
case "main": await mainMode()
case "engines": await enginesMode()
case "scan": await scanMode()
case "repeat": await repeatMode()
default:
    await mainMode()
    await enginesMode()
    await scanMode()
    await repeatMode()
}
