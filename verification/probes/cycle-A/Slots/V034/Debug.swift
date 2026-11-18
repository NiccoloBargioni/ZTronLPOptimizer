import Foundation
import ZTronLPOptimizer

func debugStrategies() async throws {
    let which = argv.count > 2 ? argv[2] : "a"
    let inst = finderInstance(15)
    var strategies: [(String, any SolverStrategy)] = [
        ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.primal, presolve:false, scaling:.none)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Simplex(.dual)", Simplex(.dual)),
        ("Simplex() [default = dual]", Simplex()),
    ]
    if which.contains("i") { strategies.append(("InteriorPoint()", InteriorPoint())) }
    if which.contains("u") { strategies.append(("Automatic()", Automatic())) }
    if which.contains("c") { strategies.append(("Conditioned(Simplex(.primal))", Conditioned(Simplex(.primal)))) }
    for (name, s) in strategies {
        let t0 = Date()
        let an = try await s.solve(inst.lp, context: context())
        print(name, an.status, (an as? SimplexAnalysis)?.iterations as Any, "seconds", an.seconds, "wall", Date().timeIntervalSince(t0))
    }
}
