import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func runHilbertWarnings(order: Int) async {
    for form in HilbertForm.allCases {
        let inst = InstanceGenerator.hilbert(order: order, form: form)
        for (name, s) in [("dual", Simplex(.dual) as any SolverStrategy), ("primal", Simplex(.primal)), ("ipm", InteriorPoint())] {
            let an = try! await s.solve(inst.lp, context: ctx(30))
            if !an.warnings.isEmpty { print("order \(order) \(form.rawValue) \(name): \(an.status) warnings \(an.warnings)") }
        }
    }
}
