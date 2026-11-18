// V037: cross-check engines, called from a function (an array of existentials built inside
// main.swift's top-level async code gave zeroed strategy values in a release build:
// Simplex() reported engineName "Simplex(.primal)" and maxIterations 0; see Diag*.swift).
import Foundation
import ZTronLPOptimizer

func runCross(_ inst: GenInstance, _ cert: Certificate) async {
    func show(_ name: String, _ body: () async throws -> any SolutionAnalysis) async {
        do { print("CROSS \(name): " + describe(inst, try await body(), cert)) } catch { print("CROSS \(name): threw \(error)") }
    }
    await show("InteriorPoint()") { try await InteriorPoint().solve(inst.lp, context: context()) }
    await show("InteriorPoint(scaling: .none)") { try await InteriorPoint(scaling: .none).solve(inst.lp, context: context()) }
    await show("Simplex()") { try await Simplex().solve(inst.lp, context: context()) }
    await show("Simplex(.primal)") { try await Simplex(.primal).solve(inst.lp, context: context()) }
    await show("Automatic()") { try await Automatic().solve(inst.lp, context: context()) }
    await show("Conditioned(Simplex(.primal, factorization: .sparseQR, scaling: .none))") { try await Conditioned(Simplex(.primal, factorization: .sparseQR, scaling: .none)).solve(inst.lp, context: context()) }
}
