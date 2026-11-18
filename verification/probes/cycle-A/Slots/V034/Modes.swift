// V034: every mode runs inside a function (see main.swift).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func mode_one() async throws {
    let k = iarg(2, 15)
    let inst = finderInstance(k)
    let o = Oracle(inst)
    oracleReport(inst, o)
    let strategies: [(String, any SolverStrategy)] = [
        ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.primal, presolve:false, scaling:.none)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Simplex(.dual)", Simplex(.dual)),
        ("Simplex() [default = dual]", Simplex()),
        ("InteriorPoint()", InteriorPoint()),
        ("Automatic()", Automatic()),
        ("Conditioned(Simplex(.primal))", Conditioned(Simplex(.primal))),
    ]
    for (name, s) in strategies {
        if let sx = s as? Simplex { print("  [diag] \(name): method \(sx.method) maxIterations \(String(describing: sx.maxIterations)) cap \(sx.iterationCap(rows: inst.n, columns: inst.n)) presolve \(sx.presolve) scaling \(sx.scaling) tol \(sx.tolerances)") }
        let an = try await s.solve(inst.lp, context: context())
        print(line(name, an, inst, o))
        if let c = an as? ConditionedAnalysis<SimplexAnalysis> {
            print("    conditioning report: basisConditionEstimate \(c.report.basisConditionEstimate.map(sci) ?? "nil"); summary: \(c.report.summary)")
        }
    }
    // The finder's "x = 1 is feasible": the package's own point check, for comparison only.
    let ones = [Double](repeating: 1, count: inst.n)
    let mv = inst.lp.maxViolation(at: ones)
    print("  package maxViolation(at: 1): rows \(mv.rows) bounds \(mv.bounds); exact violation of 1: \(sci(violation(inst, ones)))")
}

func mode_grid() async throws {
    let k = iarg(2, 15)
    let inst = finderInstance(k)
    let o = Oracle(inst)
    oracleReport(inst, o)
    var cfgs: [(String, Simplex)] = []
    let facts: [(String, Simplex.Factorization)] = [("auto", .automatic), ("dense", .denseLU), ("qr", .sparseQR)]
    let scs: [(String, ScalingMode)] = [("none", .none), ("equil", .equilibration), ("geo", .geometricEquilibration)]
    for (fn, f) in facts { for pre in [true, false] { for (sn, sc) in scs {
        cfgs.append(("primal/\(fn)/pre:\(pre)/\(sn)", Simplex(.primal, factorization: f, presolve: pre, scaling: sc)))
    } } }
    let pr: [(String, Simplex.Pricing)] = [("dantzig", .dantzig), ("devex", .devex), ("steepest", .steepestEdge), ("partial3", .partial(sections: 3))]
    for (pn, p) in pr { for pre in [true, false] { cfgs.append(("primal/\(pn)/pre:\(pre)", Simplex(.primal, pricing: p, presolve: pre))) } }
    let pt: [(String, Simplex.Perturbation)] = [("off", .off), ("always", .always), ("onStall", .onStall)]
    for (pn, p) in pt { cfgs.append(("primal/pert-\(pn)", Simplex(.primal, perturbation: p))) }
    var tight = Tolerances()
    tight.primalFeasibility = 1e-9
    tight.dualFeasibility = 1e-9
    cfgs.append(("primal/tol1e-9", Simplex(.primal, tolerances: tight)))
    var loose = Tolerances()
    loose.primalFeasibility = 1e-6
    loose.dualFeasibility = 1e-6
    cfgs.append(("primal/tol1e-6", Simplex(.primal, tolerances: loose)))
    for (pn, p) in pt { cfgs.append(("dual/pert-\(pn)", Simplex(.dual, perturbation: p))) }
    for (fn, f) in facts { for pre in [true, false] { cfgs.append(("dual/\(fn)/pre:\(pre)", Simplex(.dual, factorization: f, presolve: pre))) } }
    var tally: [String: Int] = [:]
    for (name, s) in cfgs {
        let an = try await s.solve(inst.lp, context: context())
        let key = "\(name.hasPrefix("primal") ? "primal" : "dual") \(an.status)"
        tally[key, default: 0] += 1
        print(line(name, an, inst, o))
    }
    print("TALLY \(tally.sorted { $0.key < $1.key })  (configs: \(cfgs.count))")
}

func mode_det() async throws {
    let k = iarg(2, 15)
    let reps = iarg(3, 10)
    let inst = finderInstance(k)
    func fingerprint(_ an: any SolutionAnalysis) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for v in rayOf(an) ?? [] { h = (h ^ v.bitPattern) &* 0x100_0000_01b3 }
        let it = (an as? SimplexAnalysis)?.iterations ?? -1
        return "\(an.status)|iters \(it)|ray \(String(h, radix: 16))|warn \(an.warnings.count)"
    }
    var seen: [String: Int] = [:]
    let t0 = Date()
    for _ in 0..<reps { seen[fingerprint(try await Simplex(.primal).solve(inst.lp, context: context())), default: 0] += 1 }
    print("sequential x\(reps): \(seen)  (\(sci(Date().timeIntervalSince(t0))) s)")
    for th in [1, 2, 8] {
        let f = fingerprint(try await Simplex(.primal).solve(inst.lp, context: context(threads: th)))
        print("threads \(th): \(f)")
    }
    for t in [2.0, 300.0] {
        let f = fingerprint(try await Simplex(.primal).solve(inst.lp, context: context(t)))
        print("timeLimit \(t): \(f)")
    }
    // Under self-made load: 16 identical solves at once.
    let lp = inst.lp
    let concurrent = await withTaskGroup(of: String.self) { group -> [String: Int] in
        for _ in 0..<16 {
            group.addTask {
                var c = SolveContext(); c.timeLimit = 60; c.metal = .off
                let an = try! await Simplex(.primal).solve(lp, context: c)
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                for v in an.dualRay ?? [] { h = (h ^ v.bitPattern) &* 0x100_0000_01b3 }
                return "\(an.status)|iters \(an.iterations)|ray \(String(h, radix: 16))|warn \(an.warnings.count)"
            }
        }
        var out: [String: Int] = [:]
        for await s in group { out[s, default: 0] += 1 }
        return out
    }
    print("concurrent x16: \(concurrent)")
}

func mode_family() async throws {
    // The finder's 24 instances, judged by my oracle: default primal and dual only.
    var rows: [String] = []
    for k in 0..<24 {
        let inst = finderInstance(k)
        let o = Oracle(inst)
        let p = try await Simplex(.primal).solve(inst.lp, context: context())
        let d = try await Simplex(.dual).solve(inst.lp, context: context())
        var extra = ""
        if p.status == .infeasible, let y = p.dualRay { let f = farkasBoth(inst, y); extra = " primalRayFarkas \(sci(f.best)) sign \(f.sign)" }
        rows.append("k\(k) n \(inst.n) 1e-\(Int(inst.decades)) kappa1 \(sci(o.kappa1)) feasible(proven) \(o.feasible) bound \(sci(o.distanceBound)) | primal \(p.status) iters \(p.iterations) warn \(p.warnings.count)\(extra) | dual \(d.status) warn \(d.warnings.count)")
    }
    for r in rows { print(r) }
}

func mode_fresh() async throws {
    let count = iarg(2, 200)
    let seed0 = UInt64(iarg(3, 7001))
    var buckets: [String: (inst: Int, feasible: Int, primalInf: Int, primalInfCert: Int, primalInfWarned: Int, dualInf: Int, ipmInf: Int)] = [:]
    var examples: [String] = []
    for s in 0..<count {
        let inst = freshInstance(seed: seed0 + UInt64(s))
        let o = Oracle(inst)
        let kb = o.kappa1 < 1e8 ? "a k1<1e8" : o.kappa1 < 1e9 ? "b 1e8-1e9" : o.kappa1 < 1e10 ? "c 1e9-1e10" : o.kappa1 < 1e11 ? "d 1e10-1e11" : "e >=1e11"
        var bk = buckets[kb] ?? (0, 0, 0, 0, 0, 0, 0)
        bk.inst += 1
        if o.feasible { bk.feasible += 1 }
        let p = try await Simplex(.primal).solve(inst.lp, context: context())
        let d = try await Simplex(.dual).solve(inst.lp, context: context())
        let ip = try await InteriorPoint().solve(inst.lp, context: context())
        if p.status == .infeasible && o.feasible {
            bk.primalInf += 1
            if !p.warnings.isEmpty { bk.primalInfWarned += 1 }
            if let y = p.dualRay, farkasBoth(inst, y).sign > 0 { bk.primalInfCert += 1 }
            if examples.count < 12 {
                let f = p.dualRay.map { farkasBoth(inst, $0) }
                examples.append("FALSE-INFEASIBLE \(inst.label) n \(inst.n) 1e-\(Int(inst.decades)) kappa1 \(sci(o.kappa1)) bound \(sci(o.distanceBound)) farkas \(f.map { sci($0.best) } ?? "-") warnings \(p.warnings) | dual \(d.status) | ipm \(ip.status)")
            }
        }
        if d.status == .infeasible && o.feasible { bk.dualInf += 1 }
        if ip.status == .infeasible && o.feasible { bk.ipmInf += 1 }
        buckets[kb] = bk
    }
    for (k, v) in buckets.sorted(by: { $0.key < $1.key }) {
        print("BUCKET \(k): instances \(v.inst), proven feasible \(v.feasible); Simplex(.primal) false-infeasible \(v.primalInf) (ray certifies: \(v.primalInfCert), warned: \(v.primalInfWarned)); Simplex(.dual) false-infeasible \(v.dualInf); InteriorPoint() false-infeasible \(v.ipmInf)")
    }
    for e in examples { print(e) }
}

func mode_diag1() async throws {
    let instD = finderInstance(15)
    if mode != "diag1" { let oD = Oracle(instD); if mode == "diag3" { oracleReport(instD, oD) } else { print("oracle", oD.kappa1) } }
    let list1: [(String, any SolverStrategy)] = [
        ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.primal, presolve:false, scaling:.none)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Simplex(.dual)", Simplex(.dual)),
        ("Simplex()", Simplex()),
        ("InteriorPoint()", InteriorPoint()),
        ("Automatic()", Automatic()),
        ("Conditioned(Simplex(.primal))", Conditioned(Simplex(.primal))),
    ]
    for (name, s) in list1 {
        if let sx = s as? Simplex { print("[\(mode)] \(name): method \(sx.method) maxIterations \(String(describing: sx.maxIterations)) presolve \(sx.presolve) scaling \(sx.scaling)") }
    }
}

func mode_diag0() async throws {
    let list0: [(String, any SolverStrategy)] = [
        ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.primal, presolve:false, scaling:.none)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Simplex(.dual)", Simplex(.dual)),
        ("Simplex()", Simplex()),
        ("InteriorPoint()", InteriorPoint()),
        ("Automatic()", Automatic()),
        ("Conditioned(Simplex(.primal))", Conditioned(Simplex(.primal))),
    ]
    for (name, s) in list0 {
        if let sx = s as? Simplex { print("[diag0] \(name): method \(sx.method) maxIterations \(String(describing: sx.maxIterations)) presolve \(sx.presolve) scaling \(sx.scaling)") }
        else { print("[diag0] \(name): \(type(of: s))") }
    }
}

func mode_debug() async throws {
    try await debugStrategies()
}
