// Cycle B, slot F4: MIPLIB 3 and limit probes.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Published MIPLIB 3 optima, typed independently from memory of the MIPLIB 3 catalogue
/// (miplib.cat / Bixby et al. 1998), to cross-check ReferenceValues.swift.
let publishedMIPLIB3: [String: (rows: Int, cols: Int, opt: Double)] = [
    "p0033": (16, 33, 3089), "stein27": (118, 27, 18), "stein45": (331, 45, 30), "enigma": (21, 100, 0),
    "lseu": (28, 89, 1120), "mod008": (6, 319, 307), "flugpl": (18, 18, 1_201_500), "egout": (98, 141, 568.1007),
    "misc03": (96, 160, 3360), "p0201": (133, 201, 7615),
]

func probeMiplib(names: [String], engines: [String], timeLimit: Double) async {
    for inst in ReferenceValues.miplib3 where names.isEmpty || names.contains(inst.name) {
        let pub = publishedMIPLIB3[inst.name]!
        let refOK = pub.opt == inst.optimalObjective && pub.rows == inst.rows && pub.cols == inst.columns
        guard let lp = try? Corpora.loadMIPLIB3(inst.name) else { print("\(inst.name): not fetched"); continue }
        print("\(inst.name): reference \(inst.optimalObjective) published \(pub.opt) refMatches=\(refOK) m=\(lp.m) n=\(lp.n) ints=\(lp.integerColumns.count)")
        for e in engines {
            let t0 = Date()
            let out: RunOutcome
            switch e {
            case "primal": out = await runBnB(BranchAndBound(), lp, timeLimit: timeLimit)
            case "dual": out = await runBnB(BranchAndBound(engine: Simplex(.dual)), lp, timeLimit: timeLimit)
            case "primal-det": out = await runBnB(BranchAndBound(deterministic: true), lp, timeLimit: timeLimit)
            case "dual-tight": out = await runBnB(BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 1e-9)), lp, timeLimit: timeLimit)
            default: out = await runBnB(BranchAndBound(engine: InteriorPoint()), lp, timeLimit: timeLimit)
            }
            let dt = Date().timeIntervalSince(t0)
            var feas = "-"
            if let x = out.primal {
                let v = lp.maxViolation(at: x)
                var intErr = 0.0
                for j in lp.integerColumns { intErr = max(intErr, abs(x[Int(j)] - x[Int(j)].rounded())) }
                feas = "viol(b=\(v.bounds), r=\(v.rows)) intErr=\(intErr) obj(at:x)=\(lp.objective(at: x))"
            }
            let rel = out.objective.map { ReferenceValues.relativeError($0, reference: inst.optimalObjective) } ?? .nan
            let boundOK = out.bound.map { lp.sense == .minimize ? $0 <= inst.optimalObjective + 1e-6 * max(1, abs(inst.optimalObjective)) : $0 >= inst.optimalObjective - 1e-6 * max(1, abs(inst.optimalObjective)) } ?? true
            print("  [\(e)] status=\(out.status) objective=\(String(describing: out.objective)) relErr=\(rel) bound=\(String(describing: out.bound)) boundValid=\(boundOK) nodes=\(out.nodes) lpIter=\(out.lpIterations) wall=\(String(format: "%.2f", dt))s \(feas)")
        }
    }
}
