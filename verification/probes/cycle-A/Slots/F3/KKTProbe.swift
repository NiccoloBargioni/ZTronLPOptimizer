import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C1: optimality of IPM answers on constructed LPs with known optima.
/// args: count seed maxRows maxCols [spread]
func probeKKT(_ args: [String]) async throws {
    let count = args.count > 0 ? Int(args[0])! : 60
    let seed = args.count > 1 ? UInt64(args[1])! : 7
    let maxRows = args.count > 2 ? Int(args[2])! : 60
    let maxCols = args.count > 3 ? Int(args[3])! : 120
    let spread = args.count > 4 ? Double(args[4])! : 0
    var rng = Rng(seed)
    var failures = 0
    var worst: [String: (Double, String)] = [:]
    func track(_ key: String, _ v: Double, _ label: String) {
        if v.isNaN { return }
        if v > (worst[key]?.0 ?? -1) { worst[key] = (v, label) }
    }
    var configs: [(String, InteriorPoint)] = []
    for x in [InteriorPoint.Crossover.lite, .none] {
        for p in [true, false] {
            configs.append(("\(x == .lite ? "lite" : "none")/presolve=\(p)", InteriorPoint(crossover: x, presolve: p)))
        }
    }
    var statusCounts: [String: Int] = [:]
    for k in 0..<count {
        let m = rng.int(5, maxRows)
        let n = rng.int(max(5, m / 2), maxCols)
        var options = ConstructedOptions()
        options.density = max(0.02, min(0.5, 6.0 / Double(m)))
        switch k % 6 {
        case 1: options.degenerate = true
        case 2: options.freeColumns = true
        case 3: options.rangeRows = true
        case 4: options.maximize = true
        case 5: options.degenerate = true; options.freeColumns = true; options.rangeRows = true; options.maximize = true
        default: break
        }
        options.scaleSpread = spread
        let s = rng.next()
        let inst = InstanceGenerator.constructedOptimum(rows: m, columns: n, seed: s, options: options)
        let lp = inst.lp
        let simplex = try await Simplex(.dual).solve(lp, context: ctx())
        for (name, strategy) in configs {
            let label = "k=\(k) seed=\(s) \(m)x\(n) opts(deg=\(options.degenerate),free=\(options.freeColumns),range=\(options.rangeRows),max=\(options.maximize)) \(name)"
            let a = try await strategy.solve(lp, context: ctx())
            statusCounts[name + " " + statusName(a.status), default: 0] += 1
            guard a.status == .optimal, let x = a.primal, let obj = a.objectiveValue else {
                print("FAIL status \(statusName(a.status)) \(label) iters=\(a.iterations) warnings=\(a.warnings)")
                failures += 1
                continue
            }
            let r = kkt(lp, x: x, y: a.dual, d: a.reducedCosts)
            let objErr = relErr(obj, inst.objective)
            let simErr = simplex.objectiveValue.map { relErr(obj, $0) } ?? .nan
            track(name + " objErr", objErr, label)
            track(name + " simplexDiff", simErr, label)
            track(name + " pviol", r.primalViolation, label)
            track(name + " dviol", r.dualViolation, label)
            track(name + " gap", abs(r.gap), label)
            track(name + " dmis", r.reducedCostMismatch, label)
            // Recompute the objective from x.
            let recomputed = lp.objective(at: x)
            track(name + " objVsX", relErr(obj, recomputed), label)
            var bad: [String] = []
            if objErr > 1e-6 { bad.append("objErr \(e(objErr))") }
            if r.primalViolation > 1e-6 { bad.append("pviol \(e(r.primalViolation))") }
            if r.dualViolation > 1e-6 { bad.append("dviol \(e(r.dualViolation))") }
            if abs(r.gap) > 1e-6 { bad.append("gap \(e(r.gap))") }
            if r.reducedCostMismatch > 1e-6 { bad.append("dmis \(e(r.reducedCostMismatch))") }
            if strategy.crossover == .lite {
                if a.crossover == nil { bad.append("no crossover analysis") }
                if let basis = a.finalBasis {
                    var c = ctx()
                    c.warmStart = .basis(basis)
                    for method in [Simplex.Method.primal, .dual] {
                        let w = try await Simplex(method, presolve: false).solve(lp, context: c)
                        track(name + " warm\(method) iters", Double(w.iterations), label)
                        if w.status != .optimal || w.iterations > 0 {
                            bad.append("warm \(method): \(statusName(w.status)) \(w.iterations) it")
                        }
                    }
                } else {
                    bad.append("no final basis")
                }
            }
            if !bad.isEmpty {
                failures += 1
                print("FAIL \(label): \(bad.joined(separator: ", ")) warnings=\(a.warnings)")
            }
        }
    }
    print("statuses: \(statusCounts.sorted { $0.key < $1.key })")
    for (k, v) in worst.sorted(by: { $0.key < $1.key }) { print("worst \(k): \(e(v.0))  [\(v.1)]") }
    print("failures: \(failures)")
}
