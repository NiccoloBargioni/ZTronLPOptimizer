// Cycle B, slot F4: targeted constructions.
import Foundation
import ZTronLPOptimizer

func lpFrom(rows: [[Double]], rl: [Double], ru: [Double], xl: [Double], xu: [Double], cost: [Double], maximize: Bool, integer: [Int], c0: Double = 0) -> CompiledLP {
    let m = rows.count, n = cost.count
    var e: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where rows[i][j] != 0 { e.append((i, j, rows[i][j])) } }
    let s = maximize ? -1.0 : 1.0
    return CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, e), c: cost.map { s * $0 }, c0: s * c0,
                      sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru,
                      integerColumns: integer.map { Int32($0) })
}

func report(_ tag: String, _ lp: CompiledLP, _ out: RunOutcome) {
    var extra = ""
    if let x = out.primal {
        let v = lp.maxViolation(at: x)
        extra = " x=\(x) objective(at:x)=\(lp.objective(at: x)) maxViolation(bounds: \(v.bounds), rows: \(v.rows))"
    }
    print("[\(tag)] status=\(out.status) objective=\(String(describing: out.objective)) bound=\(String(describing: out.bound)) nodes=\(out.nodes)\(extra) warnings=\(out.warnings)")
}

/// (a) An LP vertex within the integrality tolerance of an integer point, where rounding breaks a row.
func probeRounding(scale: Double) async {
    // max x1 + x2  s.t.  scale*x1 - scale*x2 <= -0.5*scale*1e-6 ... i.e. x1 - x2 <= -5e-7; x binary.
    // Exact MILP optimum: x = (0, 1), objective 1.  LP: x2 = 1, x1 = 1 - 5e-7, objective 2 - 5e-7.
    let rhs = -0.5e-6 * scale
    let lp = lpFrom(rows: [[scale, -scale]], rl: [-.infinity], ru: [rhs], xl: [0, 0], xu: [1, 1], cost: [1, 1], maximize: true, integer: [0, 1])
    print("rounding probe: max x1+x2 s.t. \(scale)*x1 - \(scale)*x2 <= \(rhs), x binary; exact optimum 1 at (0,1)")
    for (name, cfg) in [("primal", BranchAndBound()), ("primal-det", BranchAndBound(deterministic: true)), ("noheur", BranchAndBound(heuristics: .none))] {
        report(name, lp, await runBnB(cfg, lp))
    }
    report("dual", lp, await runBnB(BranchAndBound(engine: Simplex(.dual)), lp))
    report("ipm", lp, await runBnB(BranchAndBound(engine: InteriorPoint()), lp))
    report("Automatic", lp, await {
        var ctx = SolveContext(); ctx.timeLimit = 20
        let a = try! await Automatic().solve(lp, context: ctx)
        return RunOutcome(status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal, nodes: 0, lpIterations: 0, history: [], warnings: a.warnings)
    }())
}

/// (a') Big-M "trickle flow": y <= M z, z binary, y in [0, 0.4]; max y - 1000 z.
/// Exact optimum 0 at (y, z) = (0, 0). LP: z = y/M = 4e-7 (within the 1e-6 integrality tolerance).
func probeBigM(_ bigM: Double) async {
    // columns: 0 = z (binary), 1 = y (continuous)
    let lp = lpFrom(rows: [[-bigM, 1]], rl: [-.infinity], ru: [0], xl: [0, 0], xu: [1, 0.4], cost: [-1000, 1], maximize: true, integer: [0])
    print("big-M probe: max y - 1000 z s.t. y - \(bigM) z <= 0, y in [0,0.4], z binary; exact optimum 0 at (z,y)=(0,0)")
    report("primal", lp, await runBnB(BranchAndBound(), lp))
    report("dual-det", lp, await runBnB(BranchAndBound(engine: Simplex(.dual), deterministic: true), lp))
    report("tightgap", lp, await runBnB(BranchAndBound(gap: Gap(relative: 0, absolute: 0)), lp))
    var ctx = SolveContext(); ctx.timeLimit = 20
    let a = try! await Automatic().solve(lp, context: ctx)
    report("Automatic", lp, RunOutcome(status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal, nodes: 0, lpIterations: 0, history: [], warnings: a.warnings))
}

/// (b) Gap semantics and bound validity. Knapsack weights (3,2,2) capacity 4, profits (p,2,2), plus 10000*x0.
/// LP: x0=1, xa=1, xb=0.5 -> 10000+p+1.  Floor rounding: (1,1,0,0) -> 10000+p.  Optimum: (1,0,1,1) -> 10004.
func probeGap(p: Double) async {
    let lp = lpFrom(rows: [[0, 3, 2, 2]], rl: [-.infinity], ru: [4], xl: [0, 0, 0, 0], xu: [1, 1, 1, 1],
                    cost: [10000, p, 2, 2], maximize: true, integer: [0, 1, 2, 3])
    print("gap probe: max 10000x0 + \(p)xa + 2xb + 2xc s.t. 3xa+2xb+2xc<=4, binary; exact optimum 10004 at (1,0,1,1); LP bound \(10001 + p)")
    let configs: [(String, BranchAndBound<Simplex>)] = [
        ("default-par", BranchAndBound()), ("default-det", BranchAndBound(deterministic: true)),
        ("default-noheur", BranchAndBound(heuristics: .none)),
        ("tight-par", BranchAndBound(gap: Gap(relative: 0, absolute: 0))),
        ("tight-det", BranchAndBound(gap: Gap(relative: 0, absolute: 0), deterministic: true)),
        ("rel1e-6", BranchAndBound(gap: Gap(relative: 1e-6, absolute: 1e-9))),
    ]
    for (name, cfg) in configs {
        var ctx = SolveContext(); ctx.timeLimit = 20
        let a = try! await cfg.solve(lp, context: ctx)
        print("[\(name)] status=\(a.status) objective=\(a.objectiveValue!) bound=\(String(describing: a.bound)) gap=\(String(describing: a.gap)) nodes=\(a.nodesProcessed) history=\(a.incumbentHistory.map { "\($0.objective)@\($0.node)/\($0.source)" }) boundValid=\((a.bound ?? -1) >= 10004 - 1e-9)")
    }
}

/// (c) Mechanism check for the lost optimum: the same model with a dummy continuous column of
/// cost 1 fixed at 0 (objective step becomes 0, cutoff becomes gap based) and with the
/// near-integral row shifts shrunk 1000x (LP gain below the 1e-9 relative tolerance).
func probeStep(seed: UInt64) async {
    let base = nearInt2Instance(seed: seed)
    let truth = oracle(base)
    print("instance \(base.label): oracle \(truth)")
    func run(_ inst: Inst, _ tag: String) async {
        let lp = inst.compiled()
        for (name, cfg) in [("default-par", BranchAndBound()), ("default-det", BranchAndBound(deterministic: true)),
                            ("Gap(0,0)-det", BranchAndBound(gap: Gap(relative: 0, absolute: 0), deterministic: true))] {
            let out = await runBnB(cfg, lp)
            let first = out.history.first.map { "\($0.objective)@\($0.node)/\($0.source)" } ?? "-"
            print("  [\(tag) \(name)] status=\(out.status) objective=\(String(describing: out.objective)) bound=\(String(describing: out.bound)) objective(at:x)=\(out.primal.map { lp.objective(at: $0) } ?? .nan) nodes=\(out.nodes) incumbents=\(out.history.map { "\($0.objective)@\($0.node)/\($0.source)" }) first=\(first)")
        }
        let a = try! await Automatic().solve(lp, context: { var c = SolveContext(); c.timeLimit = 20; return c }())
        print("  [\(tag) Automatic] status=\(a.status) objective=\(String(describing: a.objectiveValue))")
    }
    await run(base, "as generated")
    var dummy = base
    dummy.nC = 1
    dummy.rows = base.rows.map { $0 + [0] }
    dummy.xl = base.xl + [0]; dummy.xu = base.xu + [0]; dummy.cost = base.cost + [1]
    await run(dummy, "+fixed continuous col with cost (step 0)")
    var tiny = base
    for i in 0..<tiny.m where tiny.rows[i].contains(where: { abs($0) == 1e6 }) { tiny.ru[i] = base.ru[i] / 1000 }
    await run(tiny, "row shifts /1000")
}

/// (d) Edge cases with known answers.
func probeEdges() async {
    struct Case { let name: String; let lp: CompiledLP; let expect: String }
    let inf = Double.infinity
    var cases: [Case] = []
    // 1. No rows, one binary, min -x -> optimal -1
    cases.append(Case(name: "m=0 binary", lp: lpFrom(rows: [], rl: [], ru: [], xl: [0], xu: [1], cost: [-1], maximize: false, integer: [0]), expect: "optimal -1"))
    // 2. n=0, m=0 with integer list empty
    cases.append(Case(name: "empty model", lp: CompiledLP(a: SparseCSC(rows: 0, cols: 0), c: [], xl: [], xu: [], rl: [], ru: []), expect: "optimal 0"))
    // 3. free integer with cost, no rows -> unbounded
    cases.append(Case(name: "free int, cost, no rows", lp: lpFrom(rows: [], rl: [], ru: [], xl: [-inf], xu: [inf], cost: [1], maximize: false, integer: [0]), expect: "unbounded or infeasibleOrUnbounded"))
    // 4. integer x in [0.2, 0.8] (no integer inside) + free continuous y with cost -> infeasible (LP unbounded)
    cases.append(Case(name: "int no lattice pt + unbounded cont", lp: lpFrom(rows: [[1, 1]], rl: [-inf], ru: [inf], xl: [0.2, -inf], xu: [0.8, inf], cost: [0, -1], maximize: false, integer: [0]), expect: "infeasible (or infeasibleOrUnbounded)"))
    // 5. parity: 2x - 2y = 1, x,y integer in [-5,5], y continuous? all integer -> infeasible, LP feasible
    cases.append(Case(name: "parity infeasible", lp: lpFrom(rows: [[2, -2]], rl: [1], ru: [1], xl: [-5, -5], xu: [5, 5], cost: [1, 1], maximize: false, integer: [0, 1]), expect: "infeasible"))
    // 6. LP unbounded via ray but integer infeasible: x int in [0,1], 2x = 1 (singleton) , y free cost -1
    cases.append(Case(name: "singleton parity + unbounded cont", lp: lpFrom(rows: [[2, 0]], rl: [1], ru: [1], xl: [0, -inf], xu: [1, inf], cost: [0, -1], maximize: false, integer: [0]), expect: "infeasible (or infeasibleOrUnbounded)"))
    // 7. feasible MILP with unbounded relaxation along an integer direction: x - y = 0, x,y int, min -x -> unbounded
    cases.append(Case(name: "unbounded integer ray", lp: lpFrom(rows: [[1, -1]], rl: [0], ru: [0], xl: [0, 0], xu: [inf, inf], cost: [-1, 0], maximize: false, integer: [0, 1]), expect: "unbounded or infeasibleOrUnbounded"))
    // 8. maximize with negative fixed integer bound and constant: max 3x + 5, x in [-3,-3] int -> -4
    cases.append(Case(name: "fixed negative int, c0", lp: lpFrom(rows: [[1]], rl: [-10], ru: [10], xl: [-3], xu: [-3], cost: [3], maximize: true, integer: [0], c0: 5), expect: "optimal -4"))
    // 9. fractional fixed integer bound [0.5, 0.5] -> infeasible
    cases.append(Case(name: "fixed fractional int", lp: lpFrom(rows: [[1, 1]], rl: [-10], ru: [10], xl: [0.5, 0], xu: [0.5, 1], cost: [1, 1], maximize: false, integer: [0]), expect: "infeasible"))
    // 10. huge integer bounds: x in [0, 1e9] int, 3x <= 1e9 + 1 (two-var row with y fixed 0) max x -> 333333333
    cases.append(Case(name: "huge int bound", lp: lpFrom(rows: [[3, 1]], rl: [-inf], ru: [1e9 + 1], xl: [0, 0], xu: [1e9, 0], cost: [1, 0], maximize: true, integer: [0]), expect: "optimal 333333333"))
    // 11. negative domain general int: min x, 2x + 3y >= -7.5, x in [-10,-1], y in [-2, 2] int; -> enumerate
    cases.append(Case(name: "negative general ints", lp: lpFrom(rows: [[2, 3]], rl: [-7.5], ru: [inf], xl: [-10, -2], xu: [-1, 2], cost: [1, 0], maximize: false, integer: [0, 1]), expect: "optimal -6 (2x>=-7.5-3*2=-13.5 -> x>=-6.75 -> -6)"))
    // 12. duplicated rows and many optima: max x+y+z s.t. x+y+z <= 2 (x3 copies), binaries -> 2
    cases.append(Case(name: "duplicate rows, many optima", lp: lpFrom(rows: [[1, 1, 1], [1, 1, 1], [2, 2, 2]], rl: [-inf, -inf, -inf], ru: [2, 2, 4], xl: [0, 0, 0], xu: [1, 1, 1], cost: [1, 1, 1], maximize: true, integer: [0, 1, 2]), expect: "optimal 2"))
    // 13. tiny coefficients: 1e-7 x + 1e-7 y <= 1.5e-7 binaries max x + y -> 1
    cases.append(Case(name: "tiny coefficients", lp: lpFrom(rows: [[1e-7, 1e-7]], rl: [-inf], ru: [1.5e-7], xl: [0, 0], xu: [1, 1], cost: [1, 1], maximize: true, integer: [0, 1]), expect: "optimal 1"))
    // 14. no integer columns via BnB (pure LP): min x s.t. x >= 1.5
    cases.append(Case(name: "pure LP via BnB", lp: lpFrom(rows: [[1, 1]], rl: [1.5], ru: [inf], xl: [0, 0], xu: [10, 0], cost: [1, 0], maximize: false, integer: []), expect: "optimal 1.5"))
    // 15. empty row infeasible: 0 in [1, 2] with an integer column elsewhere
    cases.append(Case(name: "empty infeasible row", lp: lpFrom(rows: [[0, 0], [1, 1]], rl: [1, 0], ru: [2, 5], xl: [0, 0], xu: [3, 3], cost: [1, 1], maximize: false, integer: [0, 1]), expect: "infeasible"))
    for c in cases {
        for (name, s) in [("par", BranchAndBound()), ("det", BranchAndBound(deterministic: true))] {
            let out = await runBnB(s, c.lp, timeLimit: 10)
            var extra = ""
            if let x = out.primal, c.lp.n > 0 { let v = c.lp.maxViolation(at: x); extra = " x=\(x) viol=(\(v.bounds),\(v.rows))" }
            print("[\(c.name) / \(name)] expect \(c.expect) -> status=\(out.status) objective=\(String(describing: out.objective)) bound=\(String(describing: out.bound))\(extra) warnings=\(out.warnings)")
        }
        let d = await runBnB(BranchAndBound(engine: Simplex(.dual)), c.lp, timeLimit: 10)
        print("[\(c.name) / dual] status=\(d.status) objective=\(String(describing: d.objective))")
        let i = await runBnB(BranchAndBound(engine: InteriorPoint()), c.lp, timeLimit: 10)
        print("[\(c.name) / ipm] status=\(i.status) objective=\(String(describing: i.objective))")
    }
}

/// (d') Incumbent versus the root LP bound for the two tolerance cases.
func probeTolerance() async {
    let inf = Double.infinity
    let cases: [(String, CompiledLP)] = [
        ("huge rhs: max x s.t. 3x + y <= 1e9+1", lpFrom(rows: [[3, 1]], rl: [-inf], ru: [1e9 + 1], xl: [0, 0], xu: [1e9, 0], cost: [1, 0], maximize: true, integer: [0])),
        ("knapsack budget in cents: max sum v x, sum w x <= 1e9+50 (w ~ 3.3e8)", lpFrom(rows: [[333_333_334, 333_333_333, 333_333_335, 1]], rl: [-inf], ru: [1e9 + 50], xl: [0, 0, 0, 0], xu: [1, 1, 1, 0], cost: [10, 10, 10, 0], maximize: true, integer: [0, 1, 2])),
        ("tiny coefficients: max x+y s.t. 1e-7x+1e-7y <= 1.5e-7", lpFrom(rows: [[1e-7, 1e-7]], rl: [-inf], ru: [1.5e-7], xl: [0, 0], xu: [1, 1], cost: [1, 1], maximize: true, integer: [0, 1])),
    ]
    for (name, lp) in cases {
        var ctx = SolveContext(); ctx.timeLimit = 10
        let a = try! await BranchAndBound().solve(lp, context: ctx)
        let lpRelax = try! await Simplex(.dual).solve(lp.relaxed(), context: ctx)
        let x = a.primal ?? []
        let act = x.isEmpty ? [] : lp.rowActivity(x)
        print("[\(name)] status=\(a.status) objective=\(String(describing: a.objectiveValue)) bound=\(String(describing: a.bound)) root LP=\(String(describing: a.root.objectiveValue)) relaxation(Simplex)=\(String(describing: lpRelax.objectiveValue)) x=\(x) activity=\(act) ru=\(lp.ru) history=\(a.incumbentHistory.map { "\($0.objective)@\($0.node)/\($0.source)" }) heuristics-off:", terminator: " ")
        let b = try! await BranchAndBound(heuristics: .none).solve(lp, context: ctx)
        print("status=\(b.status) objective=\(String(describing: b.objectiveValue)) x=\(b.primal ?? [])")
    }
}

/// (e) Random MILPs with an unbounded relaxation: a free continuous column y with an improving
/// cost, entering one row with a coefficient that never limits it. Oracle: unbounded when the
/// base model is feasible, infeasible otherwise.
func probeUnbounded(kind: String, seeds: Range<UInt64>) async {
    var bad = 0, feasibleCount = 0
    for s in seeds {
        let base = randomInstance(seed: s, kind: kind)
        let truth = oracle(base)
        var inst = base
        inst.nC += 1
        // y enters row 0 with coefficient +1 on a <= row side or -1 on a >= row side so that moving y towards -inf never violates
        let i0 = 0
        let coef: Double = base.ru[i0] < .infinity && base.rl[i0] == -.infinity ? -1 : (base.rl[i0] > -.infinity && base.ru[i0] == .infinity ? 1 : 0)
        inst.rows = base.rows.enumerated().map { (i, r) in r + [i == i0 ? coef : 0] }
        inst.xl = base.xl + [-.infinity]; inst.xu = base.xu + [.infinity]
        // objective: improve as y -> +inf when coef <= 0 for a <= row (-y increases slack) ... use y -> +inf with coef -1 on <=, +1 on >=
        inst.cost = base.cost + [inst.maximize ? 1 : -1]
        let lp = inst.compiled()
        let feasible: Bool
        if case .optimal = truth { feasible = true } else { feasible = false }
        if feasible { feasibleCount += 1 }
        for (name, cfg) in [("par", BranchAndBound()), ("det", BranchAndBound(deterministic: true))] {
            let out = await runBnB(cfg, lp, timeLimit: 10)
            let ok: Bool
            if feasible { ok = out.status == .infeasibleOrUnbounded || out.status == .unbounded }
            else { ok = out.status == .infeasible || out.status == .infeasibleOrUnbounded }
            if !ok { bad += 1; print("\(inst.label) [\(name)] base \(truth) -> status \(out.status) obj=\(String(describing: out.objective))") }
        }
        let d = await runBnB(BranchAndBound(engine: Simplex(.dual)), lp, timeLimit: 10)
        if feasible ? !(d.status == .infeasibleOrUnbounded || d.status == .unbounded) : !(d.status == .infeasible || d.status == .infeasibleOrUnbounded) { bad += 1; print("\(inst.label) [dual] base \(truth) -> \(d.status)") }
    }
    print("UNBOUNDED kind=\(kind) seeds=\(seeds) feasibleBases=\(feasibleCount) bad=\(bad)")
}

/// (f) Greedy minimisation of a failing instance for B4-03 under BranchAndBound() (parallel default)
/// and BranchAndBound(deterministic: true): drop rows, then columns, while the failure persists.
func failsBeyondGap(_ inst: Inst) async -> Bool {
    guard case .optimal(let zs, _) = oracle(inst) else { return false }
    let lp = inst.compiled()
    for cfg in [BranchAndBound(deterministic: true), BranchAndBound()] {
        let out = await runBnB(cfg, lp, timeLimit: 10)
        guard let z = out.objective, out.status == .optimal else { return false }
        let worse = inst.maximize ? zs - z : z - zs
        if worse <= slack(z) + 1e-6 { return false }
    }
    return true
}

func dropRow(_ inst: Inst, _ i: Int) -> Inst {
    var r = inst
    r.rows.remove(at: i); r.rl.remove(at: i); r.ru.remove(at: i)
    return r
}

func dropColumn(_ inst: Inst, _ j: Int) -> Inst {
    var r = inst
    r.rows = inst.rows.map { var row = $0; row.remove(at: j); return row }
    r.xl.remove(at: j); r.xu.remove(at: j); r.cost.remove(at: j)
    if j < inst.nI { r.nI -= 1; r.domLo.remove(at: j); r.domHi.remove(at: j) } else { r.nC -= 1 }
    return r
}

func probeMinimize(seed: UInt64) async {
    var inst = nearInt2Instance(seed: seed)
    guard await failsBeyondGap(inst) else { print("seed \(seed) does not fail under both default configs"); return }
    var changed = true
    while changed {
        changed = false
        for i in stride(from: inst.m - 1, through: 0, by: -1) {
            let c = dropRow(inst, i)
            if await failsBeyondGap(c) { inst = c; changed = true }
        }
        for j in stride(from: inst.n - 1, through: 0, by: -1) where inst.n > 2 {
            let c = dropColumn(inst, j)
            if c.rows.allSatisfy({ $0.contains { $0 != 0 } }), await failsBeyondGap(c) { inst = c; changed = true }
        }
    }
    print(describe(inst))
    print("oracle: \(oracle(inst))")
    let lp = inst.compiled()
    for (name, cfg) in [("BranchAndBound()", BranchAndBound()), ("deterministic", BranchAndBound(deterministic: true)), ("Gap(0,0)", BranchAndBound(gap: Gap(relative: 0, absolute: 0))), ("dual", BranchAndBound(engine: Simplex(.dual)))] {
        let out = await runBnB(cfg, lp)
        print("[\(name)] status=\(out.status) objective=\(String(describing: out.objective)) bound=\(String(describing: out.bound)) x=\(out.primal ?? []) incumbents=\(out.history.map { "\($0.objective)@\($0.node)/\($0.source)" })")
    }
}
