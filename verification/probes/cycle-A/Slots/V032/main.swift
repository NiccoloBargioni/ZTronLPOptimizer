// Cycle A, sceptic V032 for finding A2-01 (contract lens): crossed bounds and the solve contract.
// Build: swift build --product V032 -c release   Run: .build/release/V032
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let inf = Double.infinity

func ctx(_ warm: WarmStart = .none) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 20
    c.threads = 2
    c.metal = .off
    c.warmStart = warm
    return c
}

func dense(c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double], xu: [Double],
           sense: ObjectiveSense = .minimize, integer: [Int32] = []) -> CompiledLP {
    var e: [(row: Int, col: Int, value: Double)] = []
    for (i, r) in rows.enumerated() { for (j, v) in r.enumerated() where v != 0 { e.append((i, j, v)) } }
    let a = SparseCSC.fromTriplets(rows: rows.count, cols: c.count, e)
    let cc = sense == .maximize ? c.map { -$0 } : c
    return CompiledLP(a: a, c: cc, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer)
}

func line(_ label: String, _ lp: CompiledLP, _ an: any SolutionAnalysis) {
    let v = an.primal.map { lp.maxViolation(at: $0) }
    let viol = v.map { String(format: "bounds %.3g rows %.3g", $0.bounds, $0.rows) } ?? "-"
    var ray = ""
    if let s = an as? SimplexAnalysis { ray = " dualRay=\(s.dualRay.map { "\($0)" } ?? "nil")" }
    print("\(label): status=\(an.status) x=\(an.primal ?? []) obj=\(an.objectiveValue.map { "\($0)" } ?? "nil") viol(\(viol))\(ray) warnings=\(an.warnings)")
}

func run(_ label: String, _ lp: CompiledLP, _ s: some SolverStrategy, _ c: SolveContext = ctx()) async {
    do { line(label, lp, try await s.solve(lp, context: c)) } catch { print("\(label): THROWS \(error)") }
}

let arg = CommandLine.arguments.dropFirst().first ?? "all"

if arg == "all" || arg == "lp" {
    // V1: one column, no rows, xl = 2 > xu = 1.
    let v1 = dense(c: [1], rows: [], rl: [], ru: [], xl: [2], xu: [1])
    // V2: crossed column inside a row: min x + y, x + y >= 3, x in [2, 1], y in [0, 5].
    let v2 = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [inf], xl: [2, 0], xu: [1, 5])
    // V3: max x, x + y <= 10, x in [2, 1], y in [0, 5]: the cost pushes the crossed column.
    let v3 = dense(c: [1, 0], rows: [[1, 1]], rl: [-inf], ru: [10], xl: [2, 0], xu: [1, 5], sense: .maximize)
    // V4: crossed row: x + y in [3, 1], x, y in [0, 5].
    let v4 = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [1], xl: [0, 0], xu: [5, 5])
    // V5: a crossing of 1e-9 (rounding noise, inside the 1e-7 feasibility tolerance).
    let v5 = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [inf], xl: [1 + 1e-9, 0], xu: [1, 5])
    for (name, lp) in [("V1", v1), ("V2", v2), ("V3", v3), ("V4", v4), ("V5", v5)] {
        for m in [Simplex.Method.dual, .primal] {
            await run("\(name) Simplex(\(m))", lp, Simplex(m))
            await run("\(name) Simplex(\(m), presolve:false)", lp, Simplex(m, presolve: false))
        }
        await run("\(name) InteriorPoint", lp, InteriorPoint())
        await run("\(name) Automatic", lp, Automatic())
        let p = Presolve.run(lp, tolerances: .default, mode: .full)
        print("\(name) Presolve.run(.full).outcome = \(p.outcome)")
    }
}

if arg == "all" || arg == "extra" {
    // T1: the exact instance PresolveTests.boundsThatCrossByRoundingNoiseDescribeAFixedColumn
    // calls "a real crossing is infeasible".
    let t1 = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [inf], xl: [1.5, 0], xu: [1, inf])
    print("T1 Presolve outcome = \(Presolve.run(t1, tolerances: .default, mode: .full).outcome)")
    for m in [Simplex.Method.dual, .primal] { await run("T1 Simplex(\(m))", t1, Simplex(m)) }
    await run("T1 InteriorPoint", t1, InteriorPoint())
    await run("T1 Conditioned(Simplex(.dual))", t1, Conditioned(Simplex(.dual)))
    for k in 0..<3 { await run("T1 Portfolio[Simplex(.dual), InteriorPoint] run \(k)", t1, Portfolio([Simplex(.dual), InteriorPoint()])) }
    // T2: incremental warm start whose bound change crosses, on a feasible base.
    let base = dense(c: [-1, -1], rows: [[1, 2]], rl: [-inf], ru: [4], xl: [0, 0], xu: [3, 3])
    let cold = try! await Simplex(.dual).solve(base, context: ctx())
    line("T2 base", base, cold)
    let change = BoundChange(column: 0, lower: 2.5, upper: 1.5)
    await run("T2 Simplex(dual) .incremental crossed", base.applying([change]), Simplex(.dual), ctx(.incremental(parent: cold.basis, changes: [change])))
    // T3: the engine directly.
    var engine = SimplexEngine(lp: base, strategy: Simplex(.dual), factorization: DenseLUBasis())
    var gate = WorkGate(deadline: .after(seconds: 20))
    _ = try! await engine.solve(method: .dual, warmStart: .none, gate: &gate)
    engine.applyBoundChanges([change])
    let after = try! await engine.solve(method: .dual, warmStart: .basis(engine.basis), gate: &gate)
    line("T3 SimplexEngine.applyBoundChanges crossed", base.applying([change]), after)
}

if arg == "all" || arg == "other" {
    // The package's other paths for the same data.
    enum X: LPVariable { case x, y }
    let model = LPModel<X>()
        .minimizing(X.x + X.y)
        .subjectTo { X.x + X.y >= 3 }
        .bounding(.x, Bounds(lower: 2, upper: 1))
        .bounding(.y, Bounds(lower: 0, upper: 5))
    do { _ = try model.compile(); print("DSL compile: accepted") } catch { print("DSL compile: THROWS \(error)") }
    do { let s = try await Simplex(.dual).solve(model, context: ctx()); print("DSL Simplex: status=\(s.status)") }
    catch { print("DSL Simplex solve(model): THROWS \(error)") }
    let mps = """
    NAME CROSSED
    ROWS
     N obj
     G r1
    COLUMNS
     x obj 1 r1 1
     y obj 1 r1 1
    RHS
     rhs r1 3
    BOUNDS
     LO bnd x 2
     UP bnd x 1
     UP bnd y 5
    ENDATA
    """
    do { _ = try MPSFormat.read(mps); print("MPS read: accepted") } catch { print("MPS read: THROWS \(error)") }

    // Integer engines on the integer version of V2.
    let i2 = dense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [inf], xl: [2, 0], xu: [1, 5], integer: [0, 1])
    await run("I2 BranchAndBound", i2, BranchAndBound())
    await run("I2 CPSAT", i2, CPSAT())
    await run("I2 Automatic", i2, Automatic())
    await run("I2 Simplex(dual) relaxation", i2, Simplex(.dual))
    // A non-integral crossing created by rounding: integer x in [0.3, 0.7].
    let i3 = dense(c: [1, 1], rows: [[1, 1]], rl: [0], ru: [inf], xl: [0.3, 0], xu: [0.7, 5], integer: [0, 1])
    await run("I3 BranchAndBound", i3, BranchAndBound())
    await run("I3 CPSAT", i3, CPSAT())
}
