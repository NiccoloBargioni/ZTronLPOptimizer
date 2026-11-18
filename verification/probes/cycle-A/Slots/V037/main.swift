// V037 (cycle A): sceptic for finding A2-03 (refine() fallback leaves .optimal at an
// infeasible vertex; false .infeasible on badly scaled inputs with scaling: .none).
// Usage:
//   V037 one <seed> <m> <n> <max 0/1> <deg 0/1> <spread> <config names...|all>
//   V037 sweep <count> <seed0> <spread>
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct Cfg { let name: String; let s: Simplex }

func grid() -> [Cfg] {
    var out: [Cfg] = []
    let facts: [(String, Simplex.Factorization)] = [("auto", .automatic), ("dense", .denseLU), ("qr", .sparseQR)]
    let scs: [(String, ScalingMode)] = [("none", .none), ("eq", .equilibration), ("geo", .geometricEquilibration)]
    for method in [Simplex.Method.primal, .dual] {
        for (fn, f) in facts {
            for pre in [true, false] {
                for (sn, sc) in scs {
                    out.append(Cfg(name: "\(method)/\(fn)/pre\(pre)/\(sn)",
                                   s: Simplex(method, factorization: f, presolve: pre, scaling: sc)))
                }
            }
        }
    }
    let pricings: [(String, Simplex.Pricing)] = [("dantzig", .dantzig), ("steep", .steepestEdge), ("partial3", .partial(sections: 3))]
    for (pn, p) in pricings {
        for pre in [true, false] {
            out.append(Cfg(name: "primal/\(pn)/pre\(pre)", s: Simplex(.primal, pricing: p, presolve: pre)))
        }
    }
    let perts: [(String, Simplex.Perturbation)] = [("off", .off), ("always", .always)]
    for method in [Simplex.Method.primal, .dual] {
        for (pn, p) in perts {
            out.append(Cfg(name: "\(method)/pert-\(pn)", s: Simplex(method, perturbation: p)))
            out.append(Cfg(name: "\(method)/pert-\(pn)/qr/nopre", s: Simplex(method, factorization: .sparseQR, perturbation: p, presolve: false)))
        }
    }
    var tight = Tolerances()
    tight.primalFeasibility = 1e-9
    tight.dualFeasibility = 1e-9
    for method in [Simplex.Method.primal, .dual] {
        out.append(Cfg(name: "\(method)/tol1e-9", s: Simplex(method, tolerances: tight)))
    }
    return out
}

func context(_ seconds: Double = 20) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.metal = .off
    return c
}

func describe(_ inst: GenInstance, _ an: any SolutionAnalysis, _ cert: Certificate) -> String {
    var s = "\(an.status)"
    if let o = an.objectiveValue {
        s += " obj \(o) (relerr \(e(abs(o - cert.primalObjective) / max(1, abs(cert.primalObjective)))))"
    } else { s += " obj nil" }
    if let x = an.primal {
        let v = violation(inst.lp, x)
        s += " | my viol rows abs \(e(v.rowAbs)) rel \(e(v.rowRel)) bounds abs \(e(v.boundAbs)) rel \(e(v.boundRel))"
        if v.worstRow >= 0 {
            s += " [worst row \(v.worstRow): activity \(v.worstRowActivity) in [\(v.worstRowLo), \(v.worstRowHi)], Σ|a x| \(e(v.worstRowMag))]"
        }
        s += " | objective at returned x \(modelObjective(inst.lp, x))"
    }
    if let sa = an as? SimplexAnalysis {
        s += " | iters \(sa.iterations)"
        if let r = sa.dualRay { s += " farkas(dualRay) \(e(farkas(inst.lp, r)))" }
    }
    s += " | warnings \(an.warnings)"
    return s
}

let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "help"

switch mode {
case "one":
    let seed = UInt64(argv[2])!, m = Int(argv[3])!, n = Int(argv[4])!
    let inst = generate(m: m, n: n, seed: seed, maximize: argv[5] == "1", degenerate: argv[6] == "1",
                        scaleSpread: Double(argv[7])!)
    var amin = Double.infinity, amax = 0.0
    for v in inst.lp.a.values where v != 0 { amin = min(amin, abs(v)); amax = max(amax, abs(v)) }
    let cert = certify(inst.lp, x: inst.x, yMin: inst.yMin)
    print("instance \(inst.label): nnz \(inst.lp.nnz), |a| in [\(e(amin)), \(e(amax))]")
    print("ORACLE weak duality: P(x constructed) = \(cert.primalObjective), D(y,d) = \(cert.dualObjective), "
          + "gap rel \(e(abs(cert.primalObjective - cert.dualObjective) / max(1, abs(cert.primalObjective)))), "
          + "constructed x viol rel \(e(cert.primalViolationRel)), multipliers on infinite bounds \(cert.badSigns), "
          + "noise |d| \(e(cert.noiseOnInfinite)) -> certificate valid: \(cert.valid)")
    print("generator's own objective (not used): \(inst.generatorObjective)")
    let names = Set(argv[8...])
    for cfg in grid() where names.contains(cfg.name) || names.contains("all") {
        do {
            let an = try await cfg.s.solve(inst.lp, context: context())
            print("SOLVE \(cfg.name): " + describe(inst, an, cert))
        } catch { print("SOLVE \(cfg.name): threw \(error)") }
    }
    if names.contains("cross") || names.contains("all") { await runCross(inst, cert) }
case "sweep":
    let count = Int(argv[2])!, seed0 = UInt64(argv[3])!, spread = Double(argv[4])!
    let configs = grid()
    var solves = 0, invalidCerts = 0
    var statusTally: [String: Int] = [:]
    var remainsWarned: [String] = []          // .optimal whose own warning says a violation > 1e-6 remains
    var badOptimal: [String] = []             // .optimal, my oracle: rel viol > 1e-6 or objErr > 1e-6
    var badOptimalUnwarned: [String] = []
    var falseVerdicts: [String] = []
    var badByScaling: [String: Int] = [:]
    for k in 0..<count {
        let seed = seed0 + UInt64(k)
        var r = GenRng(seed &* 7)
        let m = r.int(3, 25), n = r.int(3, 30)
        let inst = generate(m: m, n: n, seed: seed, maximize: k % 3 == 1, degenerate: k % 2 == 0, scaleSpread: spread)
        let cert = certify(inst.lp, x: inst.x, yMin: inst.yMin)
        if !cert.valid { invalidCerts += 1; print("INVALID-CERT \(inst.label) P \(cert.primalObjective) D \(cert.dualObjective) viol \(e(cert.primalViolationRel)) bad \(cert.badSigns)"); continue }
        for cfg in configs {
            solves += 1
            let an: any SolutionAnalysis
            do { an = try await cfg.s.solve(inst.lp, context: context()) } catch {
                statusTally["threw", default: 0] += 1; continue
            }
            let key = "\(an.status)"
            statusTally[key, default: 0] += 1
            let scal = cfg.name.hasSuffix("/none") ? "none" : (cfg.name.hasSuffix("/eq") ? "eq" : "geo/default")
            if an.status == .optimal {
                for w in an.warnings where w.contains("remains that pivoting") {
                    let parts = w.components(separatedBy: "a violation of ")
                    if parts.count > 1, let v = Double(parts[1].components(separatedBy: " ")[0]), v > 1e-6 {
                        remainsWarned.append("\(inst.label) \(cfg.name): engine says \(e(v))")
                    }
                }
                guard let x = an.primal, let o = an.objectiveValue else { badOptimal.append("\(inst.label) \(cfg.name): no point/objective"); continue }
                let v = violation(inst.lp, x)
                let objErr = abs(o - cert.primalObjective) / max(1, abs(cert.primalObjective))
                if max(v.rowRel, v.boundRel) > 1e-6 || objErr > 1e-6 {
                    let line = "\(inst.label) \(cfg.name): rowAbs \(e(v.rowAbs)) rowRel \(e(v.rowRel)) boundRel \(e(v.boundRel)) objErr \(e(objErr)) warnings \(an.warnings.count)"
                    badOptimal.append(line)
                    badByScaling[scal, default: 0] += 1
                    if an.warnings.isEmpty { badOptimalUnwarned.append(line) }
                }
            } else if an.status == .infeasible || an.status == .unbounded {
                var line = "\(inst.label) \(cfg.name): \(an.status) (feasible point known, viol rel \(e(cert.primalViolationRel)); bounded by weak duality)"
                if let sa = an as? SimplexAnalysis, let ray = sa.dualRay { line += " farkas \(e(farkas(inst.lp, ray)))" }
                line += " warnings \(an.warnings)"
                falseVerdicts.append(line)
                badByScaling["false-verdict/" + scal, default: 0] += 1
            }
        }
    }
    print("solves \(solves), invalid certificates \(invalidCerts), statuses \(statusTally)")
    print("bad answers by scaling: \(badByScaling)")
    print("optimal answers whose own warning reports a remaining violation > 1e-6: \(remainsWarned.count)")
    print("optimal answers wrong by my oracle (rel viol > 1e-6 or objErr > 1e-6): \(badOptimal.count), of them without any warning: \(badOptimalUnwarned.count)")
    print("false infeasible/unbounded verdicts: \(falseVerdicts.count)")
    for l in remainsWarned.prefix(40) { print("REMAINS", l) }
    for l in badOptimal.prefix(40) { print("BADOPT", l) }
    for l in badOptimalUnwarned.prefix(40) { print("BADOPT-UNWARNED", l) }
    for l in falseVerdicts.prefix(40) { print("FALSE", l) }
case "diag":
    let inst = generate(m: Int(argv[3])!, n: Int(argv[4])!, seed: UInt64(argv[2])!, maximize: argv[5] == "1", degenerate: argv[6] == "1", scaleSpread: Double(argv[7])!)
    await runDiag(inst)
case "diag2":
    let inst = generate(m: Int(argv[3])!, n: Int(argv[4])!, seed: UInt64(argv[2])!, maximize: argv[5] == "1", degenerate: argv[6] == "1", scaleSpread: Double(argv[7])!)
    await runDiag2(inst, argv[8])
case "vertex":
    let inst = generate(m: Int(argv[3])!, n: Int(argv[4])!, seed: UInt64(argv[2])!, maximize: argv[5] == "1", degenerate: argv[6] == "1", scaleSpread: Double(argv[7])!)
    await runVertex(inst, certify(inst.lp, x: inst.x, yMin: inst.yMin), names: Set(argv[8...]))
case "norefine":
    let inst = generate(m: Int(argv[3])!, n: Int(argv[4])!, seed: UInt64(argv[2])!, maximize: argv[5] == "1", degenerate: argv[6] == "1", scaleSpread: Double(argv[7])!)
    let fact: Simplex.Factorization = argv[8] == "qr" ? .sparseQR : (argv[8] == "dense" ? .denseLU : .automatic)
    await runNoRefine(inst, certify(inst.lp, x: inst.x, yMin: inst.yMin), factorization: fact, method: argv[9] == "dual" ? .dual : .primal)
case "anomaly":
    // An array of existentials built in top-level async code, as the first version of `one` did.
    let others: [(String, any SolverStrategy)] = [
        ("InteriorPoint()", InteriorPoint()), ("Simplex()", Simplex()), ("Simplex(.primal)", Simplex(.primal)),
        ("Automatic()", Automatic()), ("InteriorPoint(scaling:.none)", InteriorPoint(scaling: .none)),
    ]
    for (name, s) in others {
        print("ANOMALY \(name): engineName \(s.engineName) maxIterations \((s as? Simplex).map { String(describing: $0.maxIterations) } ?? "-")")
    }
default:
    print("modes: one, sweep, diag, diag2")
}
