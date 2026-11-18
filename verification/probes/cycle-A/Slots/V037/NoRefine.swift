// V037: the main loop's verdict without the refinement pass. SimplexEngine.solve with a
// cutoff skips refine() (SimplexEngine+Driver.swift:462), and the primal method ignores the
// cutoff (drive -> runPrimal), so this is the run the Simplex facade makes, minus refine().
import Foundation
import ZTronLPOptimizer

func runNoRefine(_ inst: GenInstance, _ cert: Certificate, factorization: Simplex.Factorization, method: Simplex.Method) async {
    let strategy = Simplex(method, factorization: factorization, presolve: false, scaling: .none)
    var engine = SimplexEngine(lp: inst.lp, strategy: strategy, factorization: strategy.makeFactorization(rows: inst.lp.m))
    var gate = WorkGate(deadline: Deadline.after(seconds: 20))
    for (tag, cutoff) in [("cutoff 1e300 (refine skipped)", 1e300 as Double?), ("no cutoff (refine runs)", nil)] {
        do {
            let an = try await engine.solve(method: method, warmStart: .none, cutoff: cutoff, gate: &gate)
            print("ENGINE \(method)/\(factorization) \(tag): " + describe(inst, an, cert))
            if cutoff != nil {
                // A fresh factorization of the main loop's final basis, as refine() makes at entry.
                var qr = SparseQRBasis()
                do { try qr.refactor(basic: an.basis.basic, lp: inst.lp); print("  fresh SparseQRBasis.refactor of this basis: ok") }
                catch { print("  fresh SparseQRBasis.refactor of this basis: threw \(error)") }
                var lu = DenseLUBasis()
                do { try lu.refactor(basic: an.basis.basic, lp: inst.lp); print("  fresh DenseLUBasis.refactor of this basis: ok, conditionEstimate \(lu.conditionEstimate().map { e($0) } ?? "nil")") }
                catch { print("  fresh DenseLUBasis.refactor of this basis: threw \(error)") }
            }
            if let rep = vertex(of: an.basis, in: inst.lp) {
                let logicals = an.basis.basic.filter { Int($0) >= inst.lp.n }.count
                print("  basis \(an.basis.basic.count) basic (\(logicals) logical), κ₁(equilibrated) \(e(rep.kappaScaled)); its vertex: basic violation \(e(rep.basicViolation)), objective \(rep.objective)")
            }
        } catch { print("ENGINE \(tag): threw \(error)") }
    }
}
