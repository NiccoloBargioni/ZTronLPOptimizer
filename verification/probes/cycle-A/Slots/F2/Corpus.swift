import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C5: netlib, every configuration of the grid, with an independent dual check.
func runNetlib() async {
    let configs = configGrid(full: false)
    var worstRel = 0.0
    var worstRelName = ""
    var bad: [String] = []
    var worstPrimal: (Double, String) = (0, "")
    var worstDual: (Double, String) = (0, "")
    for ref in ReferenceValues.netlib {
        guard let lp = try? NetlibFixtures.load(ref.name) else { bad.append("\(ref.name): load failed"); continue }
        if lp.m != ref.rows || lp.n != ref.columns { bad.append("\(ref.name): size \(lp.m)x\(lp.n) vs \(ref.rows)x\(ref.columns)") }
        for cfg in configs {
            do {
                let an = try await cfg.s.solve(lp, context: ctx(60))
                guard an.status == .optimal, let o = an.objectiveValue else { bad.append("\(ref.name) \(cfg.name): \(an.status)"); continue }
                let rel = ReferenceValues.relativeError(o, reference: ref.optimalObjective)
                if rel > worstRel { worstRel = rel; worstRelName = "\(ref.name) \(cfg.name) \(o)" }
                if rel > 1e-6 { bad.append("\(ref.name) \(cfg.name): objective \(o) rel \(rel)") }
                let ch = checkOptimal(lp, an, expected: ref.optimalObjective)
                if ch.primalViolation > worstPrimal.0 { worstPrimal = (ch.primalViolation, "\(ref.name) \(cfg.name)") }
                if ch.dualSignViolation > worstDual.0 { worstDual = (ch.dualSignViolation, "\(ref.name) \(cfg.name)") }
            } catch { bad.append("\(ref.name) \(cfg.name): threw \(error)") }
        }
    }
    print("netlib configs \(configs.count); worst rel err \(fmt(worstRel)) at \(worstRelName)")
    print("worst primal violation \(fmt(worstPrimal.0)) at \(worstPrimal.1); worst dual sign violation \(fmt(worstDual.0)) at \(worstDual.1)")
    print("bad \(bad.count)")
    for b in bad.prefix(40) { print("BAD", b) }
}

func distanceFromOnes(_ x: [Double]) -> Double { x.map { abs($0 - 1) }.max() ?? .infinity }

/// C6: the README §5 ill-conditioned table, re-measured.
func runHilbert(maxOrder: Int) async {
    print("order | dense solve | dual | primal | ipm | obj rel err | warned | statuses")
    for order in 3...maxOrder {
        var dist: [String: Double] = ["dual": 0, "primal": 0, "ipm": 0]
        var objErr = 0.0
        var warned = 0, total = 0
        var statuses: [String] = []
        var dense = 0.0
        for form in HilbertForm.allCases {
            let inst = InstanceGenerator.hilbert(order: order, form: form)
            // dense solve of H x = b
            let h = DenseMatrix(inst.lp.a)
            let b = inst.lp.rl.map { $0.isFinite ? $0 : 0 }
            let bb = form == .packing ? inst.lp.ru : b
            if let xs = denseSolve(h, bb) { dense = max(dense, distanceFromOnes(xs)) }
            let engines: [(String, any SolverStrategy)] = [("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("ipm", InteriorPoint())]
            for (name, s) in engines {
                total += 1
                do {
                    let an = try await s.solve(inst.lp, context: ctx(30))
                    if an.status != .optimal { statuses.append("\(form.rawValue)/\(name):\(an.status)") }
                    if let x = an.primal { dist[name] = max(dist[name]!, distanceFromOnes(x)) }
                    if let o = an.objectiveValue { objErr = max(objErr, abs(o - inst.objective) / max(1, abs(inst.objective))) }
                    if !an.warnings.isEmpty { warned += 1 }
                    let v = inst.lp.maxViolation(at: an.primal ?? [])
                    if an.status == .optimal && max(v.bounds, v.rows) > 1e-7 { statuses.append("\(form.rawValue)/\(name):viol \(fmt(max(v.bounds, v.rows)))") }
                } catch { statuses.append("\(form.rawValue)/\(name): threw \(error)") }
            }
        }
        print("\(order) | \(fmt(dense)) | \(fmt(dist["dual"]!)) | \(fmt(dist["primal"]!)) | \(fmt(dist["ipm"]!)) | \(fmt(objErr)) | \(warned) of \(total) | \(statuses)")
    }
}

/// C6: every configuration of the grid on the Hilbert family at one order.
func runHilbertConfigs(order: Int) async {
    let configs = configGrid()
    var rows: [String] = []
    var worstOptimalDistance = 0.0
    var worstObj = 0.0
    var unwarnedFar = 0
    for form in HilbertForm.allCases {
        let inst = InstanceGenerator.hilbert(order: order, form: form)
        for cfg in configs {
            do {
                let an = try await cfg.s.solve(inst.lp, context: ctx(30))
                let dist = an.primal.map(distanceFromOnes) ?? .infinity
                let objErr = an.objectiveValue.map { abs($0 - inst.objective) / max(1, abs(inst.objective)) } ?? .nan
                let v = an.primal.map { inst.lp.maxViolation(at: $0) }
                let viol = v.map { max($0.bounds, $0.rows) } ?? .nan
                if an.status == .optimal {
                    worstOptimalDistance = max(worstOptimalDistance, dist)
                    worstObj = max(worstObj, objErr)
                    if dist > 1e-3 && an.warnings.isEmpty { unwarnedFar += 1 }
                }
                if an.status != .optimal || dist > 2e-5 || objErr > 1e-9 || viol > 1e-9 {
                    rows.append("\(form.rawValue) \(cfg.name): \(an.status) dist \(fmt(dist)) objErr \(fmt(objErr)) viol \(fmt(viol)) warnings \(an.warnings.count)")
                }
            } catch { rows.append("\(form.rawValue) \(cfg.name): threw \(error)") }
        }
    }
    print("order \(order): configs \(configs.count) x 4 forms; worst distance among .optimal \(fmt(worstOptimalDistance)); worst obj err \(fmt(worstObj)); optimal-far-without-warning \(unwarnedFar)")
    for r in rows.prefix(80) { print("OFF", r) }
    print("off-target rows: \(rows.count)")
}
