import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C9: netlib with the interior point. args: [repeats]
func probeNetlib(_ args: [String]) async throws {
    let repeats = args.count > 0 ? Int(args[0])! : 1
    var totalLite = 0.0
    var totalNone = 0.0
    for inst in ReferenceValues.netlib {
        let lp = try NetlibFixtures.load(inst.name)
        var best = Double.infinity
        var lite: InteriorPointAnalysis! = nil
        for _ in 0..<repeats {
            let t = Date()
            lite = try await InteriorPoint().solve(lp, context: ctx())
            best = min(best, Date().timeIntervalSince(t))
        }
        totalLite += best
        var bestNone = Double.infinity
        var none: InteriorPointAnalysis! = nil
        for _ in 0..<repeats {
            let t = Date()
            none = try await InteriorPoint(crossover: .none).solve(lp, context: ctx())
            bestNone = min(bestNone, Date().timeIntervalSince(t))
        }
        totalNone += bestNone
        let errLite = relErr(lite.objectiveValue ?? .nan, inst.optimalObjective)
        let errNone = relErr(none.objectiveValue ?? .nan, inst.optimalObjective)
        let vLite = lite.primal.map { kkt(lp, x: $0, y: lite.dual, d: lite.reducedCosts) }
        let vNone = none.primal.map { kkt(lp, x: $0, y: none.dual, d: none.reducedCosts) }
        // Warm start from the crossover basis: an optimal basis needs no pivot.
        var warm = "-"
        if let basis = lite.finalBasis {
            var c = ctx()
            c.warmStart = .basis(basis)
            let w = try await Simplex(.primal, presolve: false).solve(lp, context: c)
            let w2 = try await Simplex(.dual, presolve: false).solve(lp, context: c)
            warm = "\(w.iterations)/\(w2.iterations)"
        }
        print("\(inst.name): lite \(statusName(lite.status)) err \(e(errLite)) it \(lite.iterations) xover \(lite.crossover?.iterations ?? -1) \(String(format: "%.4f", best)) s kkt[\(vLite.map { "\($0)" } ?? "-")] warm p/d \(warm) | none \(statusName(none.status)) err \(e(errNone)) it \(none.iterations) \(String(format: "%.4f", bestNone)) s kkt[\(vNone.map { "\($0)" } ?? "-")] | warnings lite \(lite.warnings.count) none \(none.warnings.count)")
    }
    print(String(format: "total IPM+crossover %.4f s, IPM alone %.4f s", totalLite, totalNone))
}

/// C10: iteration limits, time limits, cancellation.
func probeLimits(_ args: [String]) async throws {
    let lp = try NetlibFixtures.load("israel")
    for cap in [0, 1, 3, 10] {
        for xo in [InteriorPoint.Crossover.lite, .none] {
            let a = try await InteriorPoint(crossover: xo, maxIterations: cap).solve(lp, context: ctx())
            print("maxIterations \(cap) crossover \(xo): \(statusName(a.status)) iterations \(a.iterations) primal \(a.primal == nil ? "nil" : "present")")
        }
    }
    var c = SolveContext()
    c.timeLimit = 0
    let z = try await InteriorPoint().solve(lp, context: c)
    print("timeLimit 0: \(statusName(z.status)) iterations \(z.iterations)")
    c.timeLimit = -1
    let neg = try await InteriorPoint().solve(lp, context: c)
    print("timeLimit -1: \(statusName(neg.status)) iterations \(neg.iterations)")
    // A model that presolve solves completely: status with limit 0 and with maxIterations 0.
    let trivial = denseLP(c: [1, 2], rows: [[1, 0], [0, 1]], rl: [1, 2], ru: [inf, inf])
    let t1 = try await InteriorPoint(maxIterations: 0).solve(trivial, context: c)
    print("presolve-solved model with timeLimit -1, maxIterations 0: \(statusName(t1.status)) obj \(t1.objectiveValue ?? .nan) duals \(t1.dual ?? [])")
    let t2 = try await InteriorPoint(maxIterations: 0, presolve: false).solve(trivial, context: ctx())
    print("same model, no presolve, maxIterations 0: \(statusName(t2.status)) iterations \(t2.iterations)")
}

/// Where an IPM(crossover: .none) answer violates the model. args: name
func probeViolation(_ args: [String]) async throws {
    let lp = try NetlibFixtures.load(args[0])
    let a = try await InteriorPoint(crossover: .none).solve(lp, context: ctx())
    let x = a.primal!
    let v = lp.maxViolation(at: x)
    let act = lp.rowActivity(x)
    var worstRow = (0, 0.0)
    for i in 0..<lp.m { let viol = max(lp.rl[i] - act[i], act[i] - lp.ru[i]); if viol > worstRow.1 { worstRow = (i, viol) } }
    let i = worstRow.0
    let bmax = (0..<lp.m).map { max(abs(lp.rl[$0].isFinite ? lp.rl[$0] : 0), abs(lp.ru[$0].isFinite ? lp.ru[$0] : 0)) }.max() ?? 0
    print("\(args[0]) IPM(none): \(statusName(a.status)) maxViolation bounds \(e(v.bounds)) rows \(e(v.rows)); worst row \(i) bounds [\(lp.rl[i]), \(lp.ru[i])] activity \(act[i]); max |rhs| \(e(bmax)); reported primalResidual \(e(a.primalResidual))")
}
