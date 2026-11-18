import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C12: SimplexEngine's public surface on scaled and unscaled problems, bound changes, cutoffs.
func runEngine() async {
    var bad: [String] = []
    var runs = 0
    for k in 0..<60 {
        var r = Rng(UInt64(k) &* 31)
        let inst = makeKKT(m: r.int(3, 20), n: r.int(3, 25), seed: UInt64(5000 + k), maximize: k % 2 == 1, degenerate: k % 3 == 0, scaleSpread: k % 4 == 0 ? 2 : 0)
        for scaled in [false, true] {
            for method in [Simplex.Method.primal, .dual] {
                let lp = scaled ? Scaler.scale(inst.lp, mode: .geometricEquilibration) : inst.lp
                var engine = SimplexEngine(lp: lp, strategy: Simplex(method), factorization: DenseLUBasis())
                var gate = WorkGate(deadline: .after(seconds: 20))
                do {
                    let an = try await engine.solve(method: method, warmStart: .none, gate: &gate)
                    runs += 1
                    guard an.status == .optimal else { bad.append("\(inst.label) scaled\(scaled) \(method): \(an.status)"); continue }
                    let ch = checkOptimal(inst.lp, an, expected: inst.objective)
                    if ch.objectiveError > 1e-7 || ch.primalViolation > 1e-6 || ch.dualSignViolation > 1e-6 || ch.gap > 1e-6 || !ch.missing.isEmpty {
                        bad.append("\(inst.label) scaled\(scaled) \(method): objErr \(fmt(ch.objectiveError)) primal \(fmt(ch.primalViolation)) dualSign \(fmt(ch.dualSignViolation)) gap \(fmt(ch.gap)) missing '\(ch.missing)'")
                    }
                    // Bound changes are given for the unscaled problem: fix column 0 at its optimal value + shift
                    let j = 0
                    let target = (an.primal![j]).isFinite ? an.primal![j] : 0
                    let lo = inst.lp.xl[j], up = inst.lp.xu[j]
                    let newUp = up.isFinite ? (lo.isFinite ? lo + 0.5 * (up - lo) : up - 1) : target + 0.5
                    let newLo = lo.isFinite ? lo : newUp - 3
                    let change = BoundChange(column: Int32(j), lower: newLo, upper: newUp)
                    engine.applyBoundChanges([change])
                    let after = try await engine.solve(method: method, warmStart: .basis(engine.basis), gate: &gate)
                    let changed = inst.lp.applying([change])
                    let reference = try await Simplex(method).solve(changed, context: ctx())
                    if after.status != reference.status { bad.append("\(inst.label) scaled\(scaled) \(method) bound change: \(after.status) vs cold \(reference.status)") }
                    else if after.status == .optimal {
                        let o1 = after.objectiveValue ?? .nan, o2 = reference.objectiveValue ?? .nan
                        if abs(o1 - o2) > 1e-7 * max(1, abs(o2)) { bad.append("\(inst.label) scaled\(scaled) \(method) bound change: objective \(o1) vs cold \(o2)") }
                        let v = changed.maxViolation(at: after.primal!)
                        if max(v.bounds, v.rows) > 1e-6 { bad.append("\(inst.label) scaled\(scaled) \(method) bound change: point violates by \(fmt(max(v.bounds, v.rows)))") }
                    }
                } catch { bad.append("\(inst.label): threw \(error)") }
            }
        }
    }
    print("engine runs \(runs), bad \(bad.count)")
    for b in bad.prefix(30) { print("BAD", b) }
    // Cutoff: a minimization LP with optimum known; cutoff below the optimum must stop with gapReached
    // and a bound that is still a valid lower bound; a cutoff above it must not stop early.
    for k in 0..<20 {
        let inst = makeKKT(m: 12, n: 16, seed: UInt64(7000 + k), maximize: false, degenerate: false)
        let opt = inst.objective
        for cutoff in [opt - 1 - abs(opt) * 0.1, opt + 1 + abs(opt) * 0.1] {
            var engine = SimplexEngine(lp: inst.lp, strategy: Simplex(.dual), factorization: DenseLUBasis())
            var gate = WorkGate(deadline: .after(seconds: 20))
            let an = try! await engine.solve(method: .dual, warmStart: .none, cutoff: cutoff, gate: &gate)
            let below = cutoff < opt
            let ok: Bool
            switch an.status {
            case .optimal: ok = abs((an.objectiveValue ?? .nan) - opt) <= 1e-7 * max(1, abs(opt))
            case .feasible(let why), .noSolution(let why): ok = why == .gapReached && below && (an.bound ?? -.infinity) <= opt + 1e-7 * max(1, abs(opt))
            default: ok = false
            }
            if !ok { print("CUTOFF BAD seed \(7000 + k) cutoff \(cutoff) opt \(opt): \(an.status) bound \(an.bound ?? .nan) obj \(an.objectiveValue ?? .nan)") }
        }
    }
    print("cutoff checks done")
    // makeFactorization: is the choice ever density-based (SparseQRBasis doc says "or the basis density is below 2%")?
    let s = Simplex()
    print("makeFactorization(rows: 100) is DenseLUBasis: \(s.makeFactorization(rows: 100) is DenseLUBasis); rows 1500: \(s.makeFactorization(rows: 1500) is DenseLUBasis); rows 1501: \(s.makeFactorization(rows: 1501) is SparseQRBasis)")
}
