import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Minimal repro: crossed bounds (xl > xu, rl > ru) reported .optimal.
func runCrossed() async {
    let inf = Double.infinity
    func show(_ label: String, _ lp: CompiledLP, _ an: any SolutionAnalysis) {
        let v = an.primal.map { lp.maxViolation(at: $0) }
        print("\(label): status \(an.status) x \(an.primal ?? []) obj \(an.objectiveValue.map { "\($0)" } ?? "nil") maxViolation \(v.map { "(bounds \($0.bounds), rows \($0.rows))" } ?? "-") warnings \(an.warnings)")
    }
    // 1. one column, no rows, xl = 2 > xu = 1
    let lp1 = CompiledLP(a: SparseCSC(rows: 0, cols: 1), c: [1], xl: [2], xu: [1], rl: [], ru: [])
    for m in [Simplex.Method.dual, .primal] {
        show("1 crossed column \(m)", lp1, try! await Simplex(m).solve(lp1, context: ctx()))
        show("1 crossed column \(m) nopresolve", lp1, try! await Simplex(m, presolve: false).solve(lp1, context: ctx()))
    }
    // 2. row with rl = 3 > ru = 1 over x, y in [0, 5]
    let lp2 = lpDense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [1], xl: [0, 0], xu: [5, 5])
    for m in [Simplex.Method.dual, .primal] {
        show("2 crossed row \(m)", lp2, try! await Simplex(m).solve(lp2, context: ctx()))
    }
    // 3. a feasible LP, then an incremental warm start whose bound change crosses
    let base = lpDense(c: [-1, -1], rows: [[1, 2]], rl: [-inf], ru: [4], xl: [0, 0], xu: [3, 3])
    let cold = try! await Simplex(.dual).solve(base, context: ctx())
    show("3 base", base, cold)
    let change = BoundChange(column: 0, lower: 2.5, upper: 1.5)
    let inc = try! await Simplex(.dual).solve(base, context: ctx(warm: .incremental(parent: cold.basis, changes: [change])))
    show("3 incremental crossed change", base.applying([change]), inc)
    let derived = base.withColumnBounds(xl: [2.5, 0], xu: [1.5, 3])
    show("3 withColumnBounds crossed", derived, try! await Simplex(.primal).solve(derived, context: ctx()))
    // 4. the engine directly
    var engine = SimplexEngine(lp: base, strategy: Simplex(.dual), factorization: DenseLUBasis())
    var gate = WorkGate(deadline: .none)
    _ = try! await engine.solve(method: .dual, warmStart: .none, gate: &gate)
    engine.applyBoundChanges([change])
    let after = try! await engine.solve(method: .dual, warmStart: .basis(engine.basis), gate: &gate)
    show("4 engine applyBoundChanges crossed", base.applying([change]), after)
    // 5. InteriorPoint and Automatic for comparison
    show("5 InteriorPoint crossed column", lp2, try! await InteriorPoint().solve(lp2, context: ctx()))
    show("5 Automatic crossed column+row", lp1, try! await Automatic().solve(lp1, context: ctx()))
}
