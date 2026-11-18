// V037 diagnostic 2: bisect what makes the cross-check engines stop at iteration 0 in `one`.
import Foundation
import ZTronLPOptimizer

func runDiag2(_ inst: GenInstance, _ step: String) async {
    func line(_ tag: String, _ an: any SolutionAnalysis) {
        let it = (an as? SimplexAnalysis).map { "\($0.iterations)" } ?? "-"
        print("DIAG2[\(step)] \(tag): \(an.status) obj \(an.objectiveValue.map { "\($0)" } ?? "nil") iters \(it)")
    }
    switch step {
    case "certify": _ = certify(inst.lp, x: inst.x, yMin: inst.yMin)
    case "grid": _ = grid()
    case "automatic": _ = Automatic()
    case "array":
        let _: [(String, any SolverStrategy)] = [("a", InteriorPoint()), ("b", Simplex()), ("c", Automatic())]
    default: break
    }
    do {
        line("Simplex()", try await Simplex().solve(inst.lp, context: context()))
        line("InteriorPoint()", try await InteriorPoint().solve(inst.lp, context: context()))
    } catch { print("DIAG2 threw \(error)") }
}
