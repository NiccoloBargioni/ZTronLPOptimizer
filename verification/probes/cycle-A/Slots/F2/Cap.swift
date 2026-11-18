import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Does maxIterations bound the refinement pass and the clean-up? (README 2: I "unless maxIterations is given").
func runCap() async {
    for form in HilbertForm.allCases {
        let inst = InstanceGenerator.hilbert(order: 8, form: form)
        for method in [Simplex.Method.dual, .primal] {
            let full = try! await Simplex(method).solve(inst.lp, context: ctx())
            var line = "\(form.rawValue) \(method): unlimited \(full.iterations) iters dist \(fmt(distanceFromOnes(full.primal ?? [])));"
            for cap in Swift.max(0, full.iterations - 12)...full.iterations {
                let an = try! await Simplex(method, maxIterations: cap).solve(inst.lp, context: ctx())
                if an.iterations > cap { line += " cap \(cap): \(an.status) \(an.iterations) iters dist \(fmt(distanceFromOnes(an.primal ?? [])));" }
            }
            print(line)
        }
    }
}
