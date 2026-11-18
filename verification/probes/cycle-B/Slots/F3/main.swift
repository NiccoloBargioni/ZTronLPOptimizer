// Cycle B / F3 probe: interior point, crossover-lite, conditioning analyzer, Conditioned facade.
// Usage: F3 <mode> [args]   (see the switch at the bottom)
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func arg(_ i: Int, _ d: String) -> String { args.count > i ? args[i] : d }
func ctx(_ seconds: Double = 20) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.metal = .off
    return c
}

struct Config {
    let name: String
    let run: (CompiledLP, SolveContext) async throws -> (any SolutionAnalysis, Basis?, String)
}

func ipm(_ name: String, _ s: InteriorPoint) -> Config {
    Config(name: name) { lp, c in
        let a = try await s.solve(lp, context: c)
        let extra = "it=\(a.iterations) mu=\(fmt(a.finalMu)) pr=\(fmt(a.primalResidual)) dr=\(fmt(a.dualResidual)) xo=\(a.crossover.map { "\($0.status)/\($0.iterations)" } ?? "-")"
        return (a, a.finalBasis, extra)
    }
}
func spx(_ name: String, _ s: Simplex) -> Config {
    Config(name: name) { lp, c in
        let a = try await s.solve(lp, context: c)
        return (a, a.basis, "it=\(a.iterations)")
    }
}

let allConfigs: [Config] = [
    ipm("ipm-lite", InteriorPoint()),
    ipm("ipm-lite-nopre", InteriorPoint(presolve: false)),
    ipm("ipm-none", InteriorPoint(crossover: .none)),
    ipm("ipm-none-nopre", InteriorPoint(crossover: .none, presolve: false)),
    spx("dual", Simplex(.dual)),
    spx("primal", Simplex(.primal)),
]

func statusName(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infOrUnb"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure: return "numFail"
    }
}

// MARK: - mode kkt: random LPs with planted optimum
func modeKKT() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "50"))!
    let m = Int(arg(4, "20"))!
    let n = Int(arg(5, "30"))!
    let flags = arg(6, "")
    var o = GenOptions()
    o.degenerate = flags.contains("D")
    o.maximize = flags.contains("M")
    if let r = flags.range(of: "S") {
        let tail = flags[r.upperBound...].prefix { "0123456789.".contains($0) }
        o.spread = Double(tail) ?? 3
    }
    if flags.contains("d") { o.density = 0.08 }
    if flags.contains("q") { o.density = 4.0 / Double(m) }
    let verbose = flags.contains("v")
    var tally: [String: [String: Int]] = [:]
    var failures = 0
    for s in 0..<UInt64(count) {
        let seed = seed0 + s
        let k = knownOptimum(seed: seed, m: m, n: n, o)
        for cfg in allConfigs {
            do {
                let (a, basis, extra) = try await cfg.run(k.lp, ctx())
                let st = statusName(a.status)
                tally[cfg.name, default: [:]][st, default: 0] += 1
                var line = "seed=\(seed) \(cfg.name) \(st) obj=\(a.objectiveValue.map { String($0) } ?? "nil") known=\(k.objective) \(extra)"
                var bad = !a.status.isOptimal
                if a.status.isOptimal, let x = a.primal {
                    let r = kktCheck(k.lp, x: x, dual: a.dual, rc: a.reducedCosts, objective: a.objectiveValue, known: k.objective)
                    line += " | \(r)"
                    if !r.ok(1e-6) { bad = true; line += " KKT-FAIL" }
                    if cfg.name.contains("lite") || !cfg.name.contains("ipm") {
                        if let basis {
                            let b = checkBasis(k.lp, basis, x: x)
                            line += " | \(b)"
                            if !b.ok(1e-6) { bad = true; line += " BASIS-FAIL" }
                        } else { line += " | NO-BASIS"; bad = true }
                    }
                }
                if bad { failures += 1 }
                if bad || verbose { print(line + (bad ? " warnings=\(a.warnings)" : "")) }
            } catch {
                print("seed=\(seed) \(cfg.name) THREW \(error)")
                failures += 1
            }
        }
    }
    for (k, v) in tally.sorted(by: { $0.key < $1.key }) { print("TALLY \(k): \(v.sorted { $0.key < $1.key })") }
    print("FAILURES \(failures)")
}

// MARK: - mode status: infeasible / unbounded families
func modeStatus() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "50"))!
    let m = Int(arg(4, "20"))!
    let n = Int(arg(5, "30"))!
    let kind = arg(6, "infeasible")  // infeasible | unbounded | unboundedMax | nearInfeasible
    let verbose = arg(7, "") == "v"
    var tally: [String: [String: Int]] = [:]
    for s in 0..<UInt64(count) {
        let seed = seed0 + s
        let lp: CompiledLP
        switch kind {
        case "unbounded": lp = unboundedLP(seed: seed, m: m, n: n, density: 0.3, maximize: false).lp
        case "unboundedMax": lp = unboundedLP(seed: seed, m: m, n: n, density: 0.3, maximize: true).lp
        case "infeasibleTight": lp = infeasibleLP(seed: seed, m: m, n: n, density: 0.3, margin: 1e-3).lp
        case "infeasibleTiny": lp = infeasibleLP(seed: seed, m: m, n: n, density: 0.3, margin: 1e-6).lp
        case "infeasibleMicro": lp = infeasibleLP(seed: seed, m: m, n: n, density: 0.3, margin: 1e-9).lp
        default: lp = infeasibleLP(seed: seed, m: m, n: n, density: 0.3, margin: 0.5).lp
        }
        let expect = kind.hasPrefix("unbounded") ? "unbounded" : "infeasible"
        for cfg in allConfigs {
            do {
                let (a, _, extra) = try await cfg.run(lp, ctx())
                let st = statusName(a.status)
                tally[cfg.name, default: [:]][st, default: 0] += 1
                let wrong = st == "optimal" || (expect == "infeasible" && st == "unbounded") || (expect == "unbounded" && st == "infeasible") || st.hasPrefix("feasible")
                if st == "infeasible", let ia = a as? InteriorPointAnalysis {
                    let ray = ia.crossover?.dualRay
                    let ok = ray.map { farkasValid(lp, $0) || farkasValid(lp, $0.map { -$0 }) }
                    tally[cfg.name + "-farkas", default: [:]][ok == nil ? "noRay" : (ok! ? "valid" : "INVALID"), default: 0] += 1
                }
                if st == "infeasible", let sa = a as? SimplexAnalysis {
                    let ok = sa.dualRay.map { farkasValid(lp, $0) || farkasValid(lp, $0.map { -$0 }) }
                    tally[cfg.name + "-farkas", default: [:]][ok == nil ? "noRay" : (ok! ? "valid" : "INVALID"), default: 0] += 1
                }
                if wrong || verbose {
                    print("seed=\(seed) \(cfg.name) \(st) expect=\(expect) obj=\(a.objectiveValue.map { String($0) } ?? "nil") \(extra) \(wrong ? "WRONG" : "") warnings=\(a.warnings)")
                    if wrong, let x = a.primal {
                        let r = kktCheck(lp, x: x, dual: a.dual, rc: a.reducedCosts, objective: a.objectiveValue, known: nil)
                        print("   \(r)")
                    }
                }
            } catch {
                print("seed=\(seed) \(cfg.name) THREW \(error)")
            }
        }
    }
    for (k, v) in tally.sorted(by: { $0.key < $1.key }) { print("TALLY \(k): \(v.sorted { $0.key < $1.key })") }
}

/// Farkas: with row multipliers y, max over the column box of (A^T y)^T x < min over row bounds of y^T s.
func farkasValid(_ lp: CompiledLP, _ y: [Double]) -> Bool {
    guard y.count == lp.m else { return false }
    let ymax = y.map { abs($0) }.max() ?? 0
    let y = y.map { abs($0) <= 1e-12 * ymax ? 0 : $0 }   // noise multipliers count as zero
    let g = aTy(lp, y)
    var U = 0.0, L = 0.0, scale = 0.0
    for j in 0..<lp.n {
        if abs(g[j]) <= 1e-12 * (1 + (y.map { abs($0) }.max() ?? 0)) { continue }
        let b = g[j] > 0 ? lp.xu[j] : lp.xl[j]
        if !b.isFinite { return false }
        U += g[j] * b; scale += abs(g[j] * b)
    }
    for i in 0..<lp.m where y[i] != 0 {
        let b = y[i] > 0 ? lp.rl[i] : lp.ru[i]
        if !b.isFinite { return false }
        L += y[i] * b; scale += abs(y[i] * b)
    }
    return L - U > 1e-9 * (1 + scale)
}

// MARK: - mode hilbert
func modeHilbert() async {
    let lo = Int(arg(2, "3"))!, hi = Int(arg(3, "12"))!
    let forms = ["equality", "equalityFree", "covering", "packing"]
    for order in lo...hi {
        let a = denseA(hilbertLP(order: order, form: "equality").lp)
        let sv = singularValues(a)
        let k2 = sv.first! / sv.last!
        print("order=\(order) kappa2(H)=\(fmt(k2))")
        for form in forms {
            let (lp, obj) = hilbertLP(order: order, form: form)
            for cfg in allConfigs {
                do {
                    let (r, basis, extra) = try await cfg.run(lp, ctx())
                    var line = "  \(form) \(cfg.name) \(statusName(r.status)) obj=\(r.objectiveValue.map { String($0) } ?? "nil") known=\(obj) \(extra)"
                    if r.status.isOptimal, let x = r.primal {
                        let k = kktCheck(lp, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: obj)
                        line += " | \(k)\(k.ok(1e-6) ? "" : " KKT-FAIL")"
                        if let basis, !cfg.name.contains("none") { line += " | \(checkBasis(lp, basis, x: x))" }
                    }
                    if case .numericalFailure(let msg) = r.status { line += " msg=\(msg)" }
                    let w = r.warnings.filter { $0.contains("stall") || $0.contains("crossover") }
                    if !w.isEmpty { line += " W=\(w)" }
                    print(line)
                } catch { print("  \(form) \(cfg.name) THREW \(error)") }
            }
        }
    }
}

switch arg(1, "help") {
case "kkt": await modeKKT()
case "status": await modeStatus()
case "hilbert": await modeHilbert()
case "one": await modeOne()
case "dense": await modeDense()
case "netlib": await modeNetlib()
case "cond": await modeCond()
case "budget": await modeBudget()
case "facade": await modeFacade()
case "findings": await modeFindings()
case "edge": await modeEdge()
case "invariance": await modeInvariance()
case "limits": await modeLimits()
case "mixedscale": await modeMixedScale()
case "viol": await modeViol()
case "basisdbg": await modeBasisDbg()
case "presolvebasis": await modePresolveBasis()
case "stalllimit": await modeStallLimit()
case "hugebounds": await modeHugeBounds()
case "bigbox": await modeBigBox()
case "findings2": await modeFindings2()
case "farkasdbg": await modeFarkasDbg()
case "misc": await modeMisc()
case "hilbertdist": await modeHilbertDist()
default:
    print("modes: kkt seed count m n flags | status seed count m n kind | hilbert lo hi")
}
