import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func checkPoint(_ lp: CompiledLP, _ x: [Double]?) -> (ok: Bool, viol: Double, frac: Double) {
    guard let x, x.count == lp.n else { return (false, .infinity, .infinity) }
    let v = lp.maxViolation(at: x)
    var frac = 0.0
    for j in lp.integerColumns { frac = Swift.max(frac, Swift.abs(x[Int(j)] - x[Int(j)].rounded())) }
    let viol = Swift.max(v.bounds, v.rows)
    return (viol <= 1e-6 && frac <= 1e-6, viol, frac)
}

/// bnbagree [count] [seed]: parallel B&B (both node engines) vs deterministic B&B vs CP-SAT;
/// then stopped runs (random time limits / cancellation): every .feasible point must be
/// feasible and no better than the optimum, every bound no worse than the optimum.
func searchAgreement(_ args: [String]) async {
    let count = args.count > 2 ? Int(args[2]) ?? 40 : 40
    let seed0 = args.count > 3 ? UInt64(args[3]) ?? 1 : 1
    var rng = SeededGenerator(seed: seed0)
    var disagreements = 0, badPoints = 0, badBounds = 0, badStatus = 0, stopped = 0
    for k in 0..<count {
        let rows = rng.integer(in: 4...12)
        let cols = rng.integer(in: 10...40)
        let mixed = k % 3 == 2
        let lp = InstanceGenerator.randomMILP(rows: rows, columns: cols, seed: rng.next(), integerFraction: mixed ? 0.6 : 1, upper: rng.integer(in: 1...3), integralData: !mixed)
        guard let det = try? await BranchAndBound(engine: Simplex(.dual), deterministic: true).solve(lp),
              det.status == .optimal, let opt = det.objectiveValue else { print("instance \(k): deterministic not optimal"); badStatus += 1; continue }
        var results: [(String, SolveStatus, Double?, Double?, [Double]?)] = []
        let p1 = try? await BranchAndBound().solve(lp)
        results.append(("BnB(primal) parallel", p1?.status ?? .numericalFailure("threw"), p1?.objectiveValue, p1?.bound, p1?.primal))
        let p2 = try? await BranchAndBound(engine: Simplex(.dual)).solve(lp)
        results.append(("BnB(dual) parallel", p2?.status ?? .numericalFailure("threw"), p2?.objectiveValue, p2?.bound, p2?.primal))
        let p3 = try? await BranchAndBound(engine: InteriorPoint()).solve(lp)
        results.append(("BnB(IPM) parallel", p3?.status ?? .numericalFailure("threw"), p3?.objectiveValue, p3?.bound, p3?.primal))
        if !mixed {
            let s = try? await CPSAT().solve(lp)
            results.append(("CPSAT", s?.status ?? .numericalFailure("threw"), s?.objectiveValue, s?.bound, s?.primal))
        }
        let a = try? await Automatic().solve(lp)
        results.append(("Automatic", a?.status ?? .numericalFailure("threw"), a?.objectiveValue, a?.bound, a?.primal))
        let pf = try? await Portfolio([BranchAndBound(), CPSAT()]).solve(lp)
        if !mixed { results.append(("Portfolio", pf?.status ?? .numericalFailure("threw"), pf?.objectiveValue, pf?.bound, pf?.primal)) }
        let slack = Swift.max(1e-6, 1e-4 * Swift.max(1, Swift.abs(opt)))
        for (name, status, obj, _, x) in results {
            if status != .optimal { print("instance \(k) \(name): status \(status)"); badStatus += 1; continue }
            if let obj, Swift.abs(obj - opt) > slack { print("instance \(k) \(name): objective \(obj) vs deterministic \(opt)"); disagreements += 1 }
            let pc = checkPoint(lp, x)
            if !pc.ok { print("instance \(k) \(name): point viol \(pc.viol) frac \(pc.frac)"); badPoints += 1 }
        }
        // Stopped runs (maximize: a feasible objective must be <= opt; a bound must be >= opt).
        for trial in 0..<3 {
            var ctx = SolveContext(); ctx.timeLimit = [0.0005, 0.002, 0.01][trial]
            for (name, r) in [("BnB", try? await BranchAndBound().solve(lp, context: ctx)), ("BnB(dual)", try? await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: ctx))] {
                guard let r else { badStatus += 1; continue }
                if r.status != .optimal { stopped += 1 }
                if r.status.hasSolution {
                    let pc = checkPoint(lp, r.primal)
                    if !pc.ok { print("instance \(k) \(name) limit \(ctx.timeLimit!): \(r.status) point viol \(pc.viol) frac \(pc.frac)"); badPoints += 1 }
                    if let obj = r.objectiveValue, obj > opt + slack { print("instance \(k) \(name): \(r.status) objective \(obj) better than optimum \(opt)"); badPoints += 1 }
                    if let obj = r.objectiveValue, let x = r.primal, Swift.abs(lp.objective(at: x) - obj) > 1e-6 * Swift.max(1, Swift.abs(obj)) { print("instance \(k) \(name): objective \(obj) != c.x \(lp.objective(at: x))"); badPoints += 1 }
                }
                if let b = r.bound, b < opt - slack { print("instance \(k) \(name) limit \(ctx.timeLimit!): \(r.status) bound \(b) below optimum \(opt) (maximize)"); badBounds += 1 }
            }
        }
    }
    print("instances \(count): disagreements \(disagreements), bad points \(badPoints), bad bounds \(badBounds), bad status \(badStatus), stopped runs \(stopped)")
}

/// bound-detail: time-limited B&B, what the bound says.
func boundDetail(_ args: [String]) async {
    let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)   // optimum 599 (maximize)
    let opt = (try! await BranchAndBound(engine: Simplex(.dual), deterministic: true).solve(mip)).objectiveValue!
    print("optimum \(opt)")
    let limits: [Double] = [0, 0.0001, 0.0003, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02]
    for limit in limits {
        for (name, s) in [("BnB(primal)", BranchAndBound()), ("BnB(dual)", BranchAndBound(engine: Simplex(.dual)))] as [(String, BranchAndBound<Simplex>)] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            let r = try! await s.solve(mip, context: ctx)
            let flag = (r.bound.map { $0 < opt - 1e-6 } ?? false) ? "  <-- bound below the optimum (maximize)" : ""
            print("limit \(limit) \(name): \(r.status) obj \(String(describing: r.objectiveValue)) bound \(String(describing: r.bound)) gap \(String(describing: r.gap)) nodes \(r.nodesProcessed) open \(r.nodesOpen) incumbents \(r.incumbents) root \(r.root.status)\(flag)")
        }
    }
    // Cancellation instead of a time limit.
    for d in [0.0, 0.0005, 0.001, 0.003] {
        let task = Task.detached { try await BranchAndBound().solve(mip) }
        await sleepSeconds(d)
        task.cancel()
        if let r = try? await task.value {
            let flag = (r.bound.map { $0 < opt - 1e-6 } ?? false) ? "  <-- bound below the optimum (maximize)" : ""
            print("cancel after \(d): \(r.status) obj \(String(describing: r.objectiveValue)) bound \(String(describing: r.bound)) gap \(String(describing: r.gap)) nodes \(r.nodesProcessed)\(flag)")
        }
    }
}

/// bound-miplib: the reported bound of time-limited B&B and CP-SAT runs on MIPLIB 3 instances.
func boundMiplib(_ args: [String]) async {
    let names = args.count > 2 ? Array(args[2...]) : ["p0201", "misc03", "stein27", "egout", "mod008", "lseu"]
    for name in names {
        guard let lp = try? Corpora.loadMIPLIB3(name), let ref = ReferenceValues.miplib3(named: name) else { print("\(name): missing"); continue }
        let opt = ref.optimalObjective
        let minimize = lp.sense == .minimize
        func invalid(_ b: Double?) -> Bool {
            guard let b else { return false }
            let slack = 1e-6 * Swift.max(1, Swift.abs(opt))
            return minimize ? b > opt + slack : b < opt - slack
        }
        var line = "\(name) (opt \(opt), \(minimize ? "min" : "max")):"
        var bad = 0
        for limit in [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            if let r = try? await BranchAndBound().solve(lp, context: ctx), r.status != .optimal {
                if invalid(r.bound) { bad += 1; line += "\n  BnB limit \(limit): \(r.status) obj \(String(describing: r.objectiveValue)) bound \(String(describing: r.bound)) gap \(String(describing: r.gap)) nodes \(r.nodesProcessed) open \(r.nodesOpen)  <-- INVALID BOUND" }
            }
            if let s = try? await CPSAT().solve(lp, context: ctx), s.status != .optimal {
                if invalid(s.bound) { bad += 1; line += "\n  CPSAT limit \(limit): \(s.status) obj \(String(describing: s.objectiveValue)) bound \(String(describing: s.bound))  <-- INVALID BOUND" }
            }
        }
        print(line + (bad == 0 ? " all stopped-run bounds valid" : ""))
    }
}
