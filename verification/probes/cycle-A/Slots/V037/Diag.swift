// V037 diagnostic: the same strategy called through the concrete type and through
// `any SolverStrategy`, in both orders, on one instance.
import Foundation
import ZTronLPOptimizer

func runDiag(_ inst: GenInstance) async {
    func line(_ tag: String, _ an: any SolutionAnalysis) {
        let it = (an as? SimplexAnalysis).map { "\($0.iterations)" } ?? "-"
        print("DIAG \(tag): \(an.status) obj \(an.objectiveValue.map { "\($0)" } ?? "nil") iters \(it) warnings \(an.warnings.count)")
    }
    let s = Simplex()
    let erased: any SolverStrategy = Simplex()
    do {
        line("concrete Simplex() #1", try await s.solve(inst.lp, context: context()))
        line("existential Simplex() #1", try await erased.solve(inst.lp, context: context()))
        line("concrete Simplex() #2", try await s.solve(inst.lp, context: context()))
        line("concrete Simplex() default context", try await s.solve(inst.lp))
        var c = SolveContext(); c.timeLimit = 20
        line("concrete Simplex() metal default", try await s.solve(inst.lp, context: c))
        line("concrete InteriorPoint()", try await InteriorPoint().solve(inst.lp, context: context()))
        let erasedIPM: any SolverStrategy = InteriorPoint()
        line("existential InteriorPoint()", try await erasedIPM.solve(inst.lp, context: context()))
    } catch { print("DIAG threw \(error)") }
}
