// Cycle B, area F2 probe. Usage: F2 <mode> [args]. Every solve has SolveContext.timeLimit set.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"
func arg(_ i: Int, _ d: Int) -> Int { args.count > i ? Int(args[i]) ?? d : d }
func argD(_ i: Int, _ d: Double) -> Double { args.count > i ? Double(args[i]) ?? d : d }

let hardFlag = ProcessInfo.processInfo.environment["HARD"] == "1"
func makeInstance(_ s: UInt64, _ mMax: Int, _ nMax: Int, hard: Bool) -> (Planted, Int, Int, PlantOpts) {
    var g = RNG(s &* 7919)
    let m = g.int(1, mMax), n = g.int(1, nMax)
    var o = PlantOpts()
    o.maximize = g.chance(0.4)
    o.degenerate = g.chance(0.5) ? 0.5 : 0.1
    o.density = g.u(0.2, 0.8)
    o.integerData = g.chance(0.7)
    o.spread = g.chance(0.2) ? g.u(0.5, 3) : 0
    if hard { o.spread = g.u(2, 3.5); o.integerData = false; o.degenerate = 0.5 }
    return (planted(seed: s, m: m, n: n, o), m, n, o)
}

func solve(_ cfg: Config, _ p: CompiledLP, warm: WarmStart = .none, limit: Double = 20) async -> SimplexAnalysis? {
    do { return try await cfg.simplex.solve(p, context: ctx(limit, warm: warm)) } catch {
        print("THROW \(cfg): \(error)")
        return nil
    }
}

switch mode {
case "grid":
    // planted LPs × every configuration (or the core grid), cold start
    let seed0 = UInt64(arg(2, 1)), count = arg(3, 20), mMax = arg(4, 12), nMax = arg(5, 16)
    let which = args.count > 6 ? args[6] : "core"
    let configs = which == "full" ? allConfigs() : which == "mid" ? midConfigs() : which == "default" ? [Config(method: .dual, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall), Config(method: .primal, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall)] : coreConfigs()
    var solves = 0, failures = 0
    var worst = KKT()
    var failByConfig: [String: Int] = [:]
    for s in seed0..<(seed0 + UInt64(count)) {
        var g = RNG(s &* 7919)
        let m = g.int(1, mMax), n = g.int(1, nMax)
        var o = PlantOpts()
        o.maximize = g.chance(0.4)
        o.degenerate = g.chance(0.5) ? 0.5 : 0.1
        o.density = g.u(0.2, 0.8)
        o.integerData = g.chance(0.7)
        o.spread = g.chance(0.2) ? g.u(0.5, 3) : 0
        if args.count > 7 && args[7] == "hard" { o.spread = g.u(2, 3.5); o.integerData = false; o.degenerate = 0.5 }
        let pl = planted(seed: s, m: m, n: n, o)
        let p = pl.lp.compiled()
        for cfg in configs {
            solves += 1
            guard let r = await solve(cfg, p) else { failures += 1; continue }
            var bad = false
            var line = ""
            if r.status != .optimal {
                bad = true
                line = "status=\(statusName(r.status))"
            } else if let x = r.primal {
                let k = checkKKT(pl.lp, x: x, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt)
                worst.primal = max(worst.primal, k.primal); worst.dual = max(worst.dual, k.dual)
                worst.comp = max(worst.comp, k.comp); worst.dcons = max(worst.dcons, k.dcons)
                worst.gap = max(worst.gap, k.gap); worst.objErr = max(worst.objErr, k.objErr)
                worst.repObjErr = max(worst.repObjErr, k.repObjErr)
                if !k.ok(1e-6) { bad = true; line = k.description }
            } else { bad = true; line = "no primal" }
            if bad {
                failures += 1
                failByConfig[cfg.description, default: 0] += 1
                if failures <= 60 || line.contains("infeasible") || line.contains("unbounded") {
                    print("FAIL seed=\(s) m=\(m) n=\(n) max=\(o.maximize) int=\(o.integerData) spread=\(String(format: "%.1f", o.spread)) cfg=\(cfg) \(line) it=\(r.iterations) opt=\(pl.opt) got=\(r.objectiveValue.map { "\($0)" } ?? "nil") warn=\(r.warnings.count)")
                }
            }
        }
    }
    print("grid: solves=\(solves) failures=\(failures) worst: \(worst)")
    for (k, v) in failByConfig.sorted(by: { $0.value > $1.value }).prefix(20) { print("  \(v)  \(k)") }

case "one":
    // re-run one planted seed with one or all configurations, verbose (HARD=1 for the hard family)
    let s = UInt64(arg(2, 1)), mMax = arg(3, 12), nMax = arg(4, 16)
    let (pl, m, n, o) = makeInstance(s, mMax, nMax, hard: hardFlag)
    print("m=\(m) n=\(n) max=\(o.maximize) tags=\(pl.tags) opt=\(pl.opt)")
    print("xl=\(pl.lp.xl)\nxu=\(pl.lp.xu)\nrl=\(pl.lp.rl)\nru=\(pl.lp.ru)\nc=\(pl.lp.c)")
    for row in pl.lp.A { print("A: \(row)") }
    print("x*=\(pl.x)\ny*=\(pl.y)\nd*=\(pl.d)")
    let p = pl.lp.compiled()
    let want = args.count > 5 ? args[5] : ""
    for cfg in allConfigs() where want.isEmpty || cfg.description == want {
        guard let r = await solve(cfg, p) else { continue }
        let k = r.primal.map { checkKKT(pl.lp, x: $0, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt) }
        if want.isEmpty && r.status == .optimal && (k?.ok() ?? false) { continue }
        print("\(cfg) status=\(statusName(r.status)) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") it=\(r.iterations) \(k.map { "\($0)" } ?? "")")
        if let x = r.primal {
            let act = pl.lp.activity(x)
            var viol: [(String, Double, Double)] = []
            for i in 0..<pl.lp.m {
                if act[i] < pl.lp.rl[i] { viol.append(("row \(i) below rl=\(pl.lp.rl[i]) act=\(act[i])", pl.lp.rl[i] - act[i], (pl.lp.rl[i] - act[i]) / (1 + abs(pl.lp.rl[i])))) }
                if act[i] > pl.lp.ru[i] { viol.append(("row \(i) above ru=\(pl.lp.ru[i]) act=\(act[i])", act[i] - pl.lp.ru[i], (act[i] - pl.lp.ru[i]) / (1 + abs(pl.lp.ru[i])))) }
            }
            for j in 0..<pl.lp.n {
                if x[j] < pl.lp.xl[j] { viol.append(("col \(j) below xl=\(pl.lp.xl[j]) x=\(x[j])", pl.lp.xl[j] - x[j], (pl.lp.xl[j] - x[j]) / (1 + abs(pl.lp.xl[j])))) }
                if x[j] > pl.lp.xu[j] { viol.append(("col \(j) above xu=\(pl.lp.xu[j]) x=\(x[j])", x[j] - pl.lp.xu[j], (x[j] - pl.lp.xu[j]) / (1 + abs(pl.lp.xu[j])))) }
            }
            for v in viol.sorted(by: { $0.2 > $1.2 }).prefix(6) { print("    viol abs=\(v.1) rel=\(v.2) \(v.0)") }
            let pv = p.maxViolation(at: x)
            print("    package maxViolation(at:) bounds=\(pv.bounds) rows=\(pv.rows)")
        }
        print("  warnings=\(r.warnings)")
        let structuralBasics = r.basis.basic.filter { Int($0) < pl.lp.n }.count
        let slackPoint = (0..<pl.lp.n).map { j -> Double in
            let lo = pl.lp.xl[j], hi = pl.lp.xu[j]
            switch Basis.nonbasicStatus(lower: lo, upper: hi) { case .atLower, .fixed: return lo; case .atUpper: return hi; default: return 0 }
        }
        let dist = zip(r.primal ?? [], slackPoint).map { abs($0 - $1) }.max() ?? -1
        print("  basis: \(structuralBasics) structural of \(r.basis.basic.count) basic; max |x - slack-basis point| = \(dist); iterations=\(r.iterations) refactorizations=\(r.refactorizations)")
        if args.count > 6 && args[6] == "x" { print("  x=\(r.primal ?? [])\n  y=\(r.dual ?? [])") }
    }

case "trace":
    // planted seed, one configuration (by description), iteration events every 1000
    let s = UInt64(arg(2, 1)), mMax = arg(3, 12), nMax = arg(4, 16)
    let want = args.count > 5 ? args[5] : "D/LU/pre=0/sc=eq/devex/pert=onStall"
    let every = arg(6, 1000)
    let (pl, m, n, _) = makeInstance(s, mMax, nMax, hard: hardFlag)
    print("m=\(m) n=\(n) tags=\(pl.tags) opt=\(pl.opt)")
    let p = pl.lp.compiled()
    for cfg in allConfigs() where cfg.description == want {
        var c = ctx(60)
        c.progress = { e in
            switch e {
            case .simplexIteration(let it, let obj, let inf, let ph):
                if it % every == 0 { print("  it=\(it) obj=\(obj) inf=\(inf) phase=\(ph)") }
            case .warning(let w): print("  WARN \(w)")
            case .finished(let st, let sec): print("  finished \(statusName(st)) \(sec)s")
            default: break
            }
        }
        let r = try await cfg.simplex.solve(p, context: c)
        print("\(cfg) status=\(statusName(r.status)) it=\(r.iterations) ph1=\(r.phase1Iterations) refac=\(r.refactorizations) degen=\(r.degeneracy)")
    }

case "hilbert":
    // own Hilbert LPs (b = H·1, c = Hᵀ1): orders lo...hi × 4 forms × configs
    let lo = arg(2, 3), hi = arg(3, 12)
    let which = args.count > 4 ? args[4] : "default"
    var configs: [Config] = []
    if which == "default" {
        configs = [Config(method: .dual, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall),
                   Config(method: .primal, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall)]
    } else { configs = midConfigs() + coreConfigs().filter { $0.factorization == .denseLU } }
    for k in lo...hi {
        var worstX: [String: Double] = [:], worstObj: [String: Double] = [:]
        var notOpt: [String] = [], warned = 0, total = 0, wrongOpt: [String] = []
        for form in 0..<4 {
            let (lp, opt) = hilbertLP(order: k, form: form)
            let p = lp.compiled()
            for cfg in configs {
                total += 1
                guard let r = await solve(cfg, p) else { notOpt.append("throw"); continue }
                let key = "\(cfg.method == .primal ? "P" : "D")/\(cfg.factorization)"
                if r.status != .optimal { notOpt.append("f\(form) \(cfg) \(statusName(r.status))"); continue }
                if !r.warnings.isEmpty { warned += 1 }
                let x = r.primal ?? []
                let dx = x.map { abs($0 - 1) }.max() ?? .infinity
                let oe = abs((r.objectiveValue ?? .nan) - opt) / max(1, abs(opt))
                let pv = lp.primalViolation(x)
                worstX[key] = max(worstX[key] ?? 0, dx)
                worstObj[key] = max(worstObj[key] ?? 0, oe)
                if oe > 1e-6 || pv > 1e-6 { wrongOpt.append("f\(form) \(cfg) objErr=\(String(format: "%.1e", oe)) pv=\(String(format: "%.1e", pv)) warn=\(r.warnings.count) structBasic=\(r.basis.basic.filter { Int($0) < k }.count)") }
            }
        }
        let xs = worstX.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.0e", $0.value))" }.joined(separator: " ")
        let os = worstObj.values.max() ?? .nan
        print("order \(k): |x-1| \(xs) | objErr max \(String(format: "%.0e", os)) | warned \(warned)/\(total) | notOptimal \(notOpt.count)")
        for w in notOpt.prefix(6) { print("   NOT-OPT \(w)") }
        for w in wrongOpt.prefix(8) { print("   WRONG-OPT \(w)") }
        if wrongOpt.count > 8 { print("   ... \(wrongOpt.count) wrong optimal answers in all") }
    }

case "infeas", "unbnd":
    let seed0 = UInt64(arg(2, 1)), count = arg(3, 100), mMax = arg(4, 12), nMax = arg(5, 12)
    let which = args.count > 6 ? args[6] : "mid"
    let configs = which == "full" ? allConfigs() : midConfigs()
    var solves = 0, wrongStatus = 0, badCert = 0, noCert = 0, optimalClaims = 0
    var signs: [Double: Int] = [:]
    var signByConfig: [String: Int] = [:]
    var byStatus: [String: Int] = [:]
    var primalInfeasibleAtUnbounded = 0
    for s in seed0..<(seed0 + UInt64(count)) {
        var g = RNG(s &* 31)
        let m = g.int(1, mMax), n = g.int(1, nMax)
        let lp = mode == "infeas" ? plantedInfeasible(seed: s, m: m, n: n, free: g.chance(0.4)) : plantedUnbounded(seed: s, m: m, n: n, maximize: g.chance(0.5))
        let p = lp.compiled()
        for cfg in configs {
            solves += 1
            guard let r = await solve(cfg, p) else { continue }
            let st = statusName(r.status)
            byStatus[st, default: 0] += 1
            if r.status == .optimal { optimalClaims += 1 }
            let want: SolveStatus = mode == "infeas" ? .infeasible : .unbounded
            if r.status != want {
                wrongStatus += 1
                if wrongStatus <= 25 { print("WRONG-STATUS seed=\(s) m=\(m) n=\(n) cfg=\(cfg) status=\(st) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil")") }
                continue
            }
            if mode == "infeas" {
                guard let ray = r.dualRay else { noCert += 1; if noCert <= 10 { print("NO-RAY seed=\(s) cfg=\(cfg)") }; continue }
                if ray.count != lp.m { badCert += 1; print("RAY-COUNT seed=\(s) cfg=\(cfg) count=\(ray.count) m=\(lp.m)"); continue }
                let (margin, sign) = farkasMargin(lp, ray)
                signs[sign, default: 0] += 1
                if sign < 0 && margin > 1e-9 { signByConfig["\(cfg.method == .primal ? "P" : "D")/pre=\(cfg.presolve ? 1 : 0)/\(cfg.factorization)", default: 0] += 1; if signByConfig.values.reduce(0, +) <= 5 { print("NEG-SIGN seed=\(s) m=\(m) n=\(n) cfg=\(cfg) ray=\(ray)") } }
                if !(margin > 1e-9) { badCert += 1; if badCert <= 25 { print("BAD-FARKAS seed=\(s) m=\(m) n=\(n) cfg=\(cfg) margin=\(margin) ray=\(ray)") } }
            } else {
                guard let ray = r.primalRay else { noCert += 1; if noCert <= 10 { print("NO-RAY seed=\(s) cfg=\(cfg)") }; continue }
                if ray.count != lp.n { badCert += 1; print("RAY-COUNT seed=\(s) cfg=\(cfg) count=\(ray.count)"); continue }
                let (cone, improve) = rayCheck(lp, ray)
                if !(cone <= 1e-7 && improve > 1e-9) { badCert += 1; if badCert <= 25 { print("BAD-RAY seed=\(s) m=\(m) n=\(n) cfg=\(cfg) cone=\(cone) improve=\(improve) ray=\(ray)") } }
                if let x = r.primal, lp.primalViolation(x) > 1e-6 { primalInfeasibleAtUnbounded += 1 }
            }
        }
    }
    print("\(mode): solves=\(solves) wrongStatus=\(wrongStatus) noCert=\(noCert) badCert=\(badCert) optimalClaims=\(optimalClaims) farkasSign=\(signs) primalInfeasibleAtUnbounded=\(primalInfeasibleAtUnbounded)")
    print("statuses: \(byStatus)")
    if !signByConfig.isEmpty { print("negative-sign certificates by config: \(signByConfig)") }

case "netlib":
    let which = args.count > 2 ? args[2] : "default"
    let only = args.count > 3 ? args[3] : ""
    let configs: [Config]
    if which == "default" {
        configs = [Config(method: .primal, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall),
                   Config(method: .dual, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall)]
    } else if which == "full" { configs = allConfigs() } else { configs = midConfigs() }
    var worstRel = 0.0
    for ref in ReferenceValues.netlib where only.isEmpty || ref.name == only {
        let p = try NetlibFixtures.load(ref.name)
        let lp = LP.from(p)
        var line = "\(ref.name) \(p.m)x\(p.n) nnz=\(p.nnz):"
        var fails: [String] = []
        var worstHere = 0.0, worstK = KKT()
        for cfg in configs {
            guard let r = await solve(cfg, p, limit: 60) else { fails.append("throw \(cfg)"); continue }
            if r.status != .optimal { fails.append("\(cfg) \(statusName(r.status)) it=\(r.iterations)"); continue }
            let rel = abs((r.objectiveValue ?? .nan) - ref.optimalObjective) / max(1, abs(ref.optimalObjective))
            worstHere = max(worstHere, rel)
            if let x = r.primal {
                let k = checkKKT(lp, x: x, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: ref.optimalObjective)
                worstK.primal = max(worstK.primal, k.primal); worstK.dual = max(worstK.dual, k.dual); worstK.comp = max(worstK.comp, k.comp)
                worstK.gap = max(worstK.gap, k.gap); worstK.dcons = max(worstK.dcons, k.dcons); worstK.repObjErr = max(worstK.repObjErr, k.repObjErr)
                if !(k.primal <= 1e-6 && k.dual <= 1e-6 && k.comp <= 1e-6 && k.gap <= 1e-6 && k.dcons <= 1e-6) || rel > 1e-6 {
                    fails.append("\(cfg) rel=\(String(format: "%.1e", rel)) \(k)")
                }
            }
            if which == "default" { line += " \(cfg.method == .primal ? "P" : "D")it=\(r.iterations) rel=\(String(format: "%.1e", rel)) warn=\(r.warnings.count)" }
        }
        worstRel = max(worstRel, worstHere)
        print(line + " worstRel=\(String(format: "%.1e", worstHere)) worstKKT[\(worstK)] fails=\(fails.count)")
        for f in fails.prefix(8) { print("   FAIL \(f)") }
    }
    print("netlib worst relative objective error: \(worstRel)")

case "limits":
    // iteration limits on netlib + planted LPs: status, honoured cap, usable iterate, valid bound
    var instances: [(String, LP, Double)] = []
    for name in ["afiro", "sc105", "stocfor1", "share2b", "degen2"] {
        let p = try NetlibFixtures.load(name)
        instances.append((name, LP.from(p), ReferenceValues.netlib(named: name)!.optimalObjective))
    }
    for s in UInt64(1)...6 {
        let pl = planted(seed: s * 101, m: 30, n: 40, PlantOpts())
        instances.append(("planted\(s * 101)", pl.lp, pl.opt))
    }
    let ks = [0, 1, 2, 3, 5, 10, 20, 50, 100, 200, 500, 1000, 2000]
    var checks = 0, problems = 0
    for (name, lp, opt) in instances {
        let p = lp.compiled()
        for cfg0 in coreConfigs() {
            var unlimitedIt = -1
            if let r = await solve(cfg0, p) { unlimitedIt = r.iterations }
            var solvedAt: Int? = nil
            for k in ks {
                var cfg = cfg0
                cfg.maxIterations = k
                guard let r = await solve(cfg, p) else { continue }
                checks += 1
                var issues: [String] = []
                switch r.status {
                case .optimal:
                    if solvedAt == nil { solvedAt = k }
                    let e = abs((r.objectiveValue ?? .nan) - opt) / max(1, abs(opt))
                    if e > 1e-6 { issues.append("optimal at wrong objective \(e)") }
                    if r.iterations > k { issues.append("iterations \(r.iterations) > maxIterations \(k) (unlimited run: \(unlimitedIt))") }
                case .feasible(.iterationLimit), .noSolution(.iterationLimit):
                    if solvedAt != nil { issues.append("not optimal at k=\(k) though optimal at smaller k=\(solvedAt!)") }
                    if r.iterations > k { issues.append("iterations \(r.iterations) > cap \(k)") }
                    guard let x = r.primal else { issues.append("no iterate"); break }
                    let pv = lp.primalViolation(x)
                    if case .feasible = r.status {
                        if pv > 1e-6 { issues.append(".feasible but primal violation \(pv)") }
                        let obj = lp.objective(x)
                        let better = lp.maximize ? obj - opt : opt - obj
                        if better > 1e-6 * max(1, abs(opt)) { issues.append(".feasible iterate better than the optimum: \(obj) vs \(opt)") }
                        if let ov = r.objectiveValue, abs(ov - obj) > 1e-6 * max(1, abs(obj)) { issues.append("objectiveValue \(ov) != objective(x) \(obj)") }
                    }
                    if let b = r.bound {
                        let invalid = lp.maximize ? opt - b : b - opt
                        if invalid > 1e-6 * max(1, abs(opt)) { issues.append("invalid bound \(b) vs optimum \(opt)") }
                    }
                default:
                    issues.append("status \(statusName(r.status))")
                }
                if !issues.isEmpty {
                    problems += 1
                    if problems <= 40 { print("LIMIT \(name) cfg=\(cfg0) k=\(k) status=\(statusName(r.status)) it=\(r.iterations): \(issues.joined(separator: "; "))") }
                }
            }
        }
    }
    print("limits: checks=\(checks) problems=\(problems)")

case "timelimit":
    // time limits: degen2 and a transport LP, timeLimit 0 / 1e-4 / 1e-3 / 1e-2
    let p1 = try NetlibFixtures.load("degen2")
    let p2 = InstanceGenerator.transport(sources: 100, sinks: 1000, seed: 7)
    for (name, p) in [("degen2", p1), ("transport100x1000", p2)] {
        for limit in [0.0, 1e-4, 1e-3, 1e-2] {
            for cfg in [Config(method: .primal, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall),
                        Config(method: .dual, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall)] {
                let t0 = Date()
                let r = try await cfg.simplex.solve(p, context: ctx(limit))
                let dt = Date().timeIntervalSince(t0)
                let pv = r.primal.map { p.maxViolation(at: $0) }
                print("\(name) limit=\(limit) \(cfg.method) status=\(statusName(r.status)) wall=\(String(format: "%.4f", dt))s reported=\(String(format: "%.4f", r.seconds)) it=\(r.iterations) primal=\(r.primal != nil) viol=\(pv.map { "\($0.bounds),\($0.rows)" } ?? "-") obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") bound=\(r.bound.map { "\($0)" } ?? "nil")")
            }
        }
    }

case "warm":
    // warm starts: same problem from its optimal basis; perturbed costs/rhs; incremental bound
    // changes; primal point; garbage bases. Oracle: planted optimum / KKT on the modified LP.
    let seed0 = UInt64(arg(2, 1)), count = arg(3, 50), mMax = arg(4, 20), nMax = arg(5, 25)
    var stats: [String: (n: Int, bad: Int, maxIt: Int, sumIt: Int)] = [:]
    func note(_ key: String, _ ok: Bool, _ it: Int, _ msg: @autoclosure () -> String) {
        var e = stats[key] ?? (0, 0, 0, 0)
        e.n += 1; e.sumIt += it; e.maxIt = max(e.maxIt, it)
        if !ok { e.bad += 1; if e.bad <= 4 { print("WARM-FAIL \(key): \(msg())") } }
        stats[key] = e
    }
    for s in seed0..<(seed0 + UInt64(count)) {
        let (pl, _, _, _) = makeInstance(s, mMax, nMax, hard: false)
        let lp = pl.lp, p = lp.compiled()
        for cfg in coreConfigs() {
            guard let cold = await solve(cfg, p), cold.status == .optimal else { continue }
            // 1. same problem, optimal basis
            if let r = await solve(cfg, p, warm: .basis(cold.basis)) {
                let k = checkKKT(lp, x: r.primal ?? [], yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt)
                note("sameBasis \(cfg.method == .primal ? "P" : "D") pre=\(cfg.presolve)", r.status == .optimal && k.ok() && r.iterations <= 2, r.iterations, "seed=\(s) cfg=\(cfg) status=\(statusName(r.status)) it=\(r.iterations) cold it=\(cold.iterations) \(k)")
            }
            // 2. primal point x*
            if let r = await solve(cfg, p, warm: .primalPoint(pl.x)) {
                let k = checkKKT(lp, x: r.primal ?? [], yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt)
                note("primalPoint", r.status == .optimal && k.ok(), r.iterations, "seed=\(s) cfg=\(cfg) status=\(statusName(r.status)) \(k)")
            }
            // 3. perturbed costs: oracle = KKT on the perturbed LP + agreement with a cold solve
            var g = RNG(s ^ 0x77)
            var lp2 = lp
            for j in 0..<lp.n { lp2.c[j] += Double(g.int(-2, 2)) }
            let p2 = lp2.compiled()
            if let r = await solve(cfg, p2, warm: .basis(cold.basis)), let c2 = await solve(cfg, p2) {
                var ok = r.status == c2.status
                var msg = "status warm=\(statusName(r.status)) cold=\(statusName(c2.status))"
                if r.status == .optimal, let x = r.primal {
                    let k = checkKKT(lp2, x: x, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: c2.objectiveValue)
                    ok = ok && k.ok()
                    msg += " \(k)"
                }
                note("perturbedCost", ok, r.iterations, "seed=\(s) cfg=\(cfg) \(msg)")
            }
            // 4. incremental bound changes on a few columns (tighten towards x*, or cut it off)
            var changes: [BoundChange] = []
            var lp3 = lp
            for j in 0..<lp.n where g.chance(0.3) {
                var lo = lp.xl[j], hi = lp.xu[j]
                if lo.isFinite && hi.isFinite && hi > lo { if g.chance(0.5) { hi = lo + (hi - lo) / 2 } else { lo = lo + (hi - lo) / 2 } }
                else if lo.isFinite { hi = lo + Double(g.int(0, 3)) }
                else if hi.isFinite { lo = hi - Double(g.int(0, 3)) }
                else { lo = -2; hi = 2 }
                changes.append(BoundChange(column: Int32(j), lower: lo, upper: hi))
                lp3.xl[j] = lo; lp3.xu[j] = hi
            }
            let p3 = lp3.compiled()
            if let r = await solve(cfg, p, warm: .incremental(parent: cold.basis, changes: changes)), let c3 = await solve(cfg, p3) {
                var ok = r.status == c3.status
                var msg = "status inc=\(statusName(r.status)) cold=\(statusName(c3.status))"
                if r.status == .optimal, let x = r.primal {
                    let k = checkKKT(lp3, x: x, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: c3.objectiveValue)
                    ok = ok && k.ok()
                    msg += " \(k)"
                }
                note("incremental", ok, r.iterations, "seed=\(s) cfg=\(cfg) \(msg) changes=\(changes.count)")
            }
            // 5. garbage bases
            for kind in 0..<5 {
                var st = [BasisStatus](repeating: .atLower, count: lp.n + lp.m)
                var basic: [Int32] = []
                switch kind {
                case 0: // random statuses, random basic list with duplicates and out-of-range entries
                    for j in 0..<st.count { st[j] = [BasisStatus.basic, .atLower, .atUpper, .free, .fixed][g.int(0, 4)] }
                    basic = (0..<lp.m).map { _ in Int32(g.int(-3, lp.n + lp.m + 3)) }
                case 1: // all structurals basic (too many)
                    for j in 0..<lp.n { st[j] = .basic }
                    basic = (0..<lp.n).map { Int32($0) }
                case 2: // empty basis
                    basic = []
                case 3: // the cold basis with one duplicate column (singular)
                    st = cold.basis.status; basic = cold.basis.basic
                    if basic.count >= 2 { basic[1] = basic[0] }
                default: // wrong length
                    st = [BasisStatus](repeating: .basic, count: max(0, lp.n + lp.m - 1)); basic = [0]
                }
                if let r = await solve(cfg, p, warm: .basis(Basis(status: st, basic: basic))) {
                    let k = checkKKT(lp, x: r.primal ?? [], yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt)
                    note("garbage\(kind)", r.status == .optimal && k.ok(), r.iterations, "seed=\(s) cfg=\(cfg) status=\(statusName(r.status)) \(k)")
                }
            }
        }
    }
    for (k, v) in stats.sorted(by: { $0.key < $1.key }) { print("\(k): n=\(v.n) bad=\(v.bad) maxIt=\(v.maxIt) meanIt=\(String(format: "%.2f", Double(v.sumIt) / Double(max(1, v.n))))") }

case "allbasic":
    // warm start whose status marks every structural column basic (and lists them), on one seed
    let s = UInt64(arg(2, 30)), mMax = arg(3, 20), nMax = arg(4, 25)
    let want = args.count > 5 ? args[5] : "P/QR/pre=1/sc=none/devex/pert=onStall"
    let (pl, m, n, _) = makeInstance(s, mMax, nMax, hard: false)
    let lp = pl.lp, p = lp.compiled()
    print("seed=\(s) m=\(m) n=\(n) max=\(lp.maximize) opt=\(pl.opt) tags=\(pl.tags)")
    var st = [BasisStatus](repeating: .atLower, count: lp.n + lp.m)
    for j in 0..<lp.n { st[j] = .basic }
    let warmBasis = Basis(status: st, basic: (0..<lp.n).map { Int32($0) })
    for cfg in allConfigs() where want == "all" || cfg.description == want {
        var c = ctx(20, warm: .basis(warmBasis))
        if want != "all" {
            c.progress = { e in
                switch e {
                case .simplexIteration(let it, let obj, let inf, let ph): print("  it=\(it) obj=\(obj) inf=\(inf) phase=\(ph)")
                case .warning(let w): print("  WARN \(w)")
                default: break
                }
            }
        }
        let r = try await cfg.simplex.solve(p, context: c)
        if want == "all" && r.status == .optimal { continue }
        let pv = r.primal.map { lp.primalViolation($0) } ?? .nan
        let fm = r.dualRay.map { farkasMargin(lp, $0) }
        print("\(cfg) status=\(statusName(r.status)) it=\(r.iterations) ph1=\(r.phase1Iterations) primalViol=\(pv) obj(x)=\(r.primal.map { lp.objective($0) } ?? .nan) farkasMargin=\(fm.map { "\($0.margin)" } ?? "nil") warnings=\(r.warnings)")
        if want != "all" { print("  dualRay=\(r.dualRay ?? [])") }
    }

case "cert":
    // one planted seed (HARD=1 for the hard family), one configuration, cold: status, the
    // certificate's Farkas margin, violations of the returned point and of the planted x*
    let s = UInt64(arg(2, 1)), mMax = arg(3, 12), nMax = arg(4, 16)
    let want = args.count > 5 ? args[5] : ""
    let (pl, m, n, o) = makeInstance(s, mMax, nMax, hard: hardFlag)
    let lp = pl.lp, p = lp.compiled()
    func absViol(_ x: [Double]) -> Double {
        var v = 0.0
        for j in 0..<lp.n { v = max(v, lp.xl[j] - x[j], x[j] - lp.xu[j]) }
        let a = lp.activity(x)
        for i in 0..<lp.m { v = max(v, lp.rl[i] - a[i], a[i] - lp.ru[i]) }
        return v
    }
    print("seed=\(s) m=\(m) n=\(n) max=\(o.maximize) spread=\(o.spread) int=\(o.integerData) opt=\(pl.opt); planted x*: relViol=\(lp.primalViolation(pl.x)) absViol=\(absViol(pl.x)) package maxViolation=\(p.maxViolation(at: pl.x))")
    let maxAbsA = lp.A.flatMap { $0 }.map { abs($0) }.max() ?? 0
    let minAbsA = lp.A.flatMap { $0 }.filter { $0 != 0 }.map { abs($0) }.min() ?? 0
    print("  |A| range [\(minAbsA), \(maxAbsA)]")
    for cfg in allConfigs() where cfg.description == want {
        let r = try await cfg.simplex.solve(p, context: ctx(20))
        let fm = r.dualRay.map { farkasMargin(lp, $0) }
        print("\(cfg) status=\(statusName(r.status)) it=\(r.iterations) ph1=\(r.phase1Iterations) x relViol=\(r.primal.map { lp.primalViolation($0) } ?? .nan) absViol=\(r.primal.map { absViol($0) } ?? .nan) obj(x)=\(r.primal.map { lp.objective($0) } ?? .nan) farkas=\(fm.map { "margin \($0.margin) sign \($0.sign)" } ?? "nil") warnings=\(r.warnings)")
    }

case "degen":
    // Klee-Minty cubes (orders 3...kmMax) and highly degenerate assignment LPs vs Hungarian
    let kmMax = arg(2, 14), asgCount = arg(3, 40), asgMax = arg(4, 14)
    for k in 3...kmMax {
        let (lp, opt) = kleeMinty(k)
        let p = lp.compiled()
        var line = "klee-minty \(k):"
        var bad: [String] = []
        for cfg in allConfigs() {
            guard let r = await solve(cfg, p, limit: 30) else { continue }
            let e = abs((r.objectiveValue ?? .nan) - opt) / opt
            if r.status != .optimal || e > 1e-9 { bad.append("\(cfg) \(statusName(r.status)) it=\(r.iterations) e=\(e)") }
            if cfg.description == "P/auto/pre=0/sc=none/dantzig/pert=off" { line += " dantzigNoScale it=\(r.iterations)" }
            if cfg.description == "P/auto/pre=1/sc=geo/devex/pert=onStall" { line += " Pdefault it=\(r.iterations)" }
            if cfg.description == "D/auto/pre=1/sc=geo/devex/pert=onStall" { line += " Ddefault it=\(r.iterations)" }
        }
        print(line + " bad=\(bad.count)")
        for b in bad.prefix(5) { print("   \(b)") }
    }
    var asgBad = 0, asgSolves = 0, maxIt = 0
    for s in UInt64(1)...UInt64(asgCount) {
        var g = RNG(s)
        let k = g.int(2, asgMax), levels = g.int(1, 3)
        let (lp, cost) = assignmentLP(k: k, seed: s, levels: levels)
        let ref = hungarian(cost)
        let p = lp.compiled()
        for cfg in midConfigs() {
            asgSolves += 1
            guard let r = await solve(cfg, p, limit: 30) else { asgBad += 1; continue }
            maxIt = max(maxIt, r.iterations)
            let kk = r.primal.map { checkKKT(lp, x: $0, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: ref) }
            if r.status != .optimal || !(kk?.ok() ?? false) {
                asgBad += 1
                if asgBad <= 10 { print("ASSIGN-FAIL seed=\(s) k=\(k) levels=\(levels) cfg=\(cfg) status=\(statusName(r.status)) it=\(r.iterations) ref=\(ref) \(kk.map { "\($0)" } ?? "")") }
            }
        }
    }
    print("assignment: solves=\(asgSolves) bad=\(asgBad) maxIterations=\(maxIt)")

case "km":
    // Klee-Minty breakdown: status counts by method/presolve/scaling over all pricings and perturbations
    let lo = arg(2, 8), hi = arg(3, 14)
    for k in lo...hi {
        let (lp, opt) = kleeMinty(k)
        let p = lp.compiled()
        var table: [String: [String: Int]] = [:]
        var example: [String: String] = [:]
        for cfg in allConfigs() {
            guard let r = await solve(cfg, p, limit: 30) else { continue }
            let e = abs((r.objectiveValue ?? .nan) - opt) / opt
            var st = statusName(r.status)
            if r.status == .optimal && !(e <= 1e-9) { st = "optimal-WRONG(e=\(String(format: "%.1e", e)))" }
            let key = "\(cfg.method == .primal ? "P" : "D")/pre=\(cfg.presolve ? 1 : 0)/sc=\(cfg.scaling)"
            table[key, default: [:]][st, default: 0] += 1
            if st != "optimal" && example[key] == nil { example[key] = "\(cfg) it=\(r.iterations) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") x0feasible=\(lp.primalViolation([Double](repeating: 0, count: k)) == 0) xViol=\(r.primal.map { lp.primalViolation($0) } ?? .nan) farkas=\(r.dualRay.map { "\(farkasMargin(lp, $0).margin)" } ?? "nil")" }
        }
        print("klee-minty \(k) (optimum \(opt)):")
        for (key, v) in table.sorted(by: { $0.key < $1.key }) { print("   \(key): \(v.sorted { $0.key < $1.key })") }
        for (key, e) in example.sorted(by: { $0.key < $1.key }) { print("      e.g. \(key): \(e)") }
    }

case "numerics":
    for line in runNumerics(seed: UInt64(arg(2, 1)), trials: arg(3, 200)) { print(line) }

case "invariance":
    // permutations, row/column scaling by powers of two and ten (with sign flips), duplicate and
    // redundant rows, min<->max reformulation: the optimum must not change
    let seed0 = UInt64(arg(2, 1)), count = arg(3, 100), mMax = arg(4, 15), nMax = arg(5, 20)
    var solves = 0, bad = 0
    var byKind: [String: Int] = [:]
    for s in seed0..<(seed0 + UInt64(count)) {
        let (pl, _, _, _) = makeInstance(s, mMax, nMax, hard: false)
        let lp = pl.lp
        var g = RNG(s ^ 0x1234)
        var variants: [(String, LP, Double)] = []
        // permutation
        let rp = (0..<lp.m).shuffled(using: &g), cp = (0..<lp.n).shuffled(using: &g)
        var P = lp
        P.A = rp.map { i in cp.map { j in lp.A[i][j] } }
        P.c = cp.map { lp.c[$0] }; P.xl = cp.map { lp.xl[$0] }; P.xu = cp.map { lp.xu[$0] }
        P.rl = rp.map { lp.rl[$0] }; P.ru = rp.map { lp.ru[$0] }
        variants.append(("permute", P, pl.opt))
        // row scaling (negative factors flip the row)
        var R = lp
        for i in 0..<lp.m {
            let f = pow(10, Double(g.int(-3, 3))) * (g.chance(0.3) ? -1 : 1)
            R.A[i] = R.A[i].map { $0 * f }
            if f > 0 { R.rl[i] = lp.rl[i] * f; R.ru[i] = lp.ru[i] * f } else { R.rl[i] = lp.ru[i] * f; R.ru[i] = lp.rl[i] * f }
        }
        variants.append(("rowScale", R, pl.opt))
        // column scaling x = s·x': A[:,j]·s, c_j·s, bounds / s (negative s flips)
        var C = lp
        for j in 0..<lp.n {
            let f = pow(2, Double(g.int(-8, 8))) * (g.chance(0.3) ? -1 : 1)
            for i in 0..<lp.m { C.A[i][j] = lp.A[i][j] * f }
            C.c[j] = lp.c[j] * f
            if f > 0 { C.xl[j] = lp.xl[j] / f; C.xu[j] = lp.xu[j] / f } else { C.xl[j] = lp.xu[j] / f; C.xu[j] = lp.xl[j] / f }
        }
        variants.append(("colScale", C, pl.opt))
        // duplicate rows and a redundant (implied) row
        var D = lp
        for i in 0..<lp.m where g.chance(0.4) { D.A.append(lp.A[i]); D.rl.append(lp.rl[i]); D.ru.append(lp.ru[i]); D.m += 1 }
        if lp.m >= 2 {
            let a = 0, b = lp.m - 1
            D.A.append((0..<lp.n).map { lp.A[a][$0] + lp.A[b][$0] })
            let lo = lp.rl[a] + lp.rl[b], hi = lp.ru[a] + lp.ru[b]
            D.rl.append(lo.isNaN ? -.infinity : lo - 1); D.ru.append(hi.isNaN ? .infinity : hi + 1); D.m += 1
        }
        variants.append(("duplicateRows", D, pl.opt))
        // min <-> max
        var X = lp
        X.maximize.toggle(); X.c = lp.c.map { -$0 }
        variants.append(("flipSense", X, -pl.opt))
        // free row added (no bounds) and an empty column with zero cost
        var F = lp
        F.A.append((0..<lp.n).map { _ in Double(g.int(-3, 3)) }); F.rl.append(-.infinity); F.ru.append(.infinity); F.m += 1
        for i in 0..<F.m { F.A[i].append(0) }
        F.c.append(0); F.xl.append(-.infinity); F.xu.append(.infinity); F.n += 1
        variants.append(("freeRow+emptyCol", F, pl.opt))
        for (kind, v, opt) in variants {
            let p = v.compiled()
            for cfg in midConfigs() {
                solves += 1
                guard let r = await solve(cfg, p) else { bad += 1; continue }
                var ok = r.status == .optimal
                var msg = statusName(r.status)
                if ok, let x = r.primal {
                    let k = checkKKT(v, x: x, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: opt)
                    ok = k.ok(2e-6)
                    msg = "\(k)"
                }
                if !ok {
                    bad += 1; byKind[kind, default: 0] += 1
                    if bad <= 20 { print("INV-FAIL \(kind) seed=\(s) cfg=\(cfg) \(msg)") }
                }
            }
        }
    }
    print("invariance: solves=\(solves) bad=\(bad) byKind=\(byKind)")

case "sensitivity":
    // dual[i] = d(reported objective)/d(rhs_i): central finite differences on afiro and on
    // a maximization planted LP, for rows with a nonzero dual
    var cases: [(String, LP)] = [("afiro", LP.from(try NetlibFixtures.load("afiro"))), ("sc50a", LP.from(try NetlibFixtures.load("sc50a")))]
    var o = PlantOpts(); o.maximize = true; o.degenerate = 0
    cases.append(("plantedMax", planted(seed: 4242, m: 10, n: 14, o).lp))
    var flip = cases[0].1; flip.maximize = true; flip.c = flip.c.map { -$0 }
    cases.append(("afiroAsMax", flip))
    let cfg = Config(method: .dual, factorization: .automatic, presolve: true, scaling: .geometricEquilibration, pricing: .devex, perturbation: .onStall)
    for (name, lp) in cases {
        guard let r0 = await solve(cfg, lp.compiled()), r0.status == .optimal, let y = r0.dual, let f0 = r0.objectiveValue else { print("\(name): base solve failed"); continue }
        let s = lp.activity(r0.primal!)
        var worst = 0.0, checked = 0
        for i in 0..<lp.m where abs(y[i]) > 1e-6 {
            let h = 1e-5 * max(1, abs(s[i]))
            func shifted(_ d: Double) -> LP {
                var v = lp
                let atLower = abs(s[i] - lp.rl[i]) <= 1e-7 * (1 + abs(lp.rl[i]))
                let atUpper = abs(s[i] - lp.ru[i]) <= 1e-7 * (1 + abs(lp.ru[i]))
                if atLower { v.rl[i] += d }
                if atUpper { v.ru[i] += d }
                return v
            }
            guard let rp = await solve(cfg, shifted(h).compiled()), let rm = await solve(cfg, shifted(-h).compiled()),
                  let fp = rp.objectiveValue, let fm = rm.objectiveValue else { continue }
            // one-sided derivatives: at a degenerate vertex the dual is a subgradient and must
            // lie between them (for a min problem the value function is convex in the rhs)
            let fwd = (fp - f0) / h, bwd = (f0 - fm) / h
            let lo = min(fwd, bwd), hi = max(fwd, bwd)
            let slack = 1e-5 * max(1, abs(y[i]))
            let e = y[i] < lo - slack ? lo - y[i] : (y[i] > hi + slack ? y[i] - hi : 0)
            worst = max(worst, e / max(1, abs(y[i]))); checked += 1
            if e > 0 { print("  \(name) row \(i): dual \(y[i]) outside one-sided derivatives [\(lo), \(hi)] (f0=\(f0))") }
        }
        print("\(name) (maximize=\(lp.maximize)): rows checked \(checked), worst violation of the subgradient bracket (rel) \(worst)")
    }

case "engine":
    // B2-01 localisation: the public SimplexEngine (no presolve, no scaling) on a planted seed,
    // without a cutoff (the refinement pass runs) and with a cutoff that cannot bind (it does not)
    let s = UInt64(arg(2, 5067)), mMax = arg(3, 60), nMax = arg(4, 80)
    let method: Simplex.Method = (args.count > 5 && args[5] == "dual") ? .dual : .primal
    let qr = !(args.count > 6 && args[6] == "lu")
    let (pl, m, n, _) = makeInstance(s, mMax, nMax, hard: hardFlag)
    let lp = pl.lp, p = lp.compiled()
    print("seed=\(s) m=\(m) n=\(n) opt=\(pl.opt) method=\(method) factorization=\(qr ? "sparseQR" : "denseLU")")
    let strategy = Simplex(method, factorization: qr ? .sparseQR : .denseLU, presolve: false, scaling: .none)
    for cutoff in [nil, 1e300] as [Double?] {
        var engine = SimplexEngine(lp: p, strategy: strategy, factorization: strategy.makeFactorization(rows: p.m))
        var gate = WorkGate(deadline: .after(seconds: 20))
        let r = try await engine.solve(method: method, warmStart: .none, cutoff: cutoff, gate: &gate)
        let x = r.primal ?? []
        print("  cutoff=\(cutoff.map { "\($0)" } ?? "nil (refinement runs)") status=\(statusName(r.status)) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") it=\(r.iterations) refac=\(r.refactorizations) structural basics=\(r.basis.basic.filter { Int($0) < n }.count) maxViolation=\(p.maxViolation(at: x)) warnings=\(r.warnings.count)")
    }

case "crash":
    // cold starts by crash kind: .crash(.slack) and .crash(.triangular), planted LPs, mid configs
    let seed0 = UInt64(arg(2, 1)), count = arg(3, 150), mMax = arg(4, 30), nMax = arg(5, 40)
    var n = 0, bad = 0
    for s in seed0..<(seed0 + UInt64(count)) {
        let (pl, _, _, _) = makeInstance(s, mMax, nMax, hard: false)
        let p = pl.lp.compiled()
        for cfg in midConfigs() {
            for kind in [CrashKind.slack, .triangular] {
                n += 1
                guard let r = await solve(cfg, p, warm: .crash(kind)) else { bad += 1; continue }
                let k = r.primal.map { checkKKT(pl.lp, x: $0, yRep: r.dual, dRep: r.reducedCosts, reported: r.objectiveValue, ref: pl.opt) }
                if r.status != .optimal || !(k?.ok() ?? false) { bad += 1; if bad <= 10 { print("CRASH-FAIL seed=\(s) \(kind) cfg=\(cfg) \(statusName(r.status)) \(k.map { "\($0)" } ?? "")") } }
            }
        }
    }
    print("crash: solves=\(n) bad=\(bad)")
    print("Simplex().makeFactorization(rows: 1500) -> \(type(of: Simplex().makeFactorization(rows: 1500))), rows: 1501 -> \(type(of: Simplex().makeFactorization(rows: 1501)))")

case "kmone":
    let k = arg(2, 14)
    let want = args.count > 3 ? args[3] : "P/auto/pre=1/sc=none/devex/pert=onStall"
    let (lp, opt) = kleeMinty(k)
    let p = lp.compiled()
    print("klee-minty \(k): optimum \(opt); x = 0 feasible: package maxViolation(at: 0) = \(p.maxViolation(at: [Double](repeating: 0, count: k)))")
    for cfg in allConfigs() where cfg.description == want {
        let r = try await cfg.simplex.solve(p, context: ctx(30))
        let fm = r.dualRay.map { farkasMargin(lp, $0) }
        print("\(cfg) status=\(statusName(r.status)) it=\(r.iterations) obj=\(r.objectiveValue.map { "\($0)" } ?? "nil") farkas=\(fm.map { "margin \($0.margin)" } ?? "nil") dualRay=\(r.dualRay ?? []) warnings=\(r.warnings)")
    }

default:
    print("modes: grid one trace hilbert infeas unbnd netlib limits timelimit warm allbasic cert degen km numerics invariance sensitivity engine crash kmone")
}
