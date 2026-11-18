import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Cross-engine check of the A5-01 counterexamples with BranchAndBound.
func runXCheck() async {
    let b52 = Double(Int64(1) << 52) + 1
    let d14c = makeLP(n: 2, rows: [[(0, 1), (1, 1)]], rl: [-.infinity], ru: [b52], c: [0, -1], sense: .maximize, xl: [b52, 0], xu: [b52, 10])
    let d14 = makeLP(n: 2, rows: [[(0, 1e15 + 0.5), (1, 1)]], rl: [1e15 + 1], ru: [.infinity], c: [0, 1], xl: [0, 0], xu: [1, 3])
    for (name, lp) in [("D14c", d14c), ("D14", d14)] {
        var c = SolveContext(); c.timeLimit = 10
        if let a = try? await BranchAndBound(deterministic: true).solve(lp, context: c) {
            print("\(name) BranchAndBound: \(statusString(a.status)) obj=\(a.objectiveValue ?? .nan) x=\(a.primal ?? [])")
        }
        if let a = try? await CPSAT(deterministic: true).solve(lp, context: c) {
            let v = lp.maxViolation(at: a.primal!)
            print("\(name) CPSAT: \(statusString(a.status)) obj=\(a.objectiveValue ?? .nan) x=\(a.primal ?? []) maxViolation=\(v)")
        }
    }
}
