import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func scaledObjective(_ lp: CompiledLP, _ factor: Double) -> CompiledLP {
    CompiledLP(a: lp.a, c: lp.c.map { $0 * factor }, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu, rl: lp.rl, ru: lp.ru)
}

func scaledRows(_ lp: CompiledLP, _ factor: Double) -> CompiledLP {
    // Scales the right-hand sides (and so x*) by `factor`: x* = factor * 1.
    CompiledLP(a: lp.a, c: lp.c, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu,
               rl: lp.rl.map { $0 * factor }, ru: lp.ru.map { $0 * factor })
}

/// C4: defect 10 and the Hilbert family. args: [minOrder maxOrder objScale rhsScale]
func probeHilbert(_ args: [String]) async throws {
    let lo = args.count > 0 ? Int(args[0])! : 3
    let hi = args.count > 1 ? Int(args[1])! : 12
    let objScale = args.count > 2 ? Double(args[2])! : 1
    let rhsScale = args.count > 3 ? Double(args[3])! : 1
    let configs: [(String, InteriorPoint)] = [
        ("IPM()", InteriorPoint()),
        ("IPM(none)", InteriorPoint(crossover: .none)),
        ("IPM(nopre)", InteriorPoint(presolve: false)),
        ("IPM(none,nopre)", InteriorPoint(crossover: .none, presolve: false)),
    ]
    for order in lo...hi {
        var hmat = [Double](repeating: 0, count: order * order)
        for i in 0..<order { for j in 0..<order { hmat[j * order + i] = 1 / Double(i + j + 1) } }
        let kappa = exactKappa1(hmat, order)
        var warnCount = 0
        for form in HilbertForm.allCases {
            let inst = InstanceGenerator.hilbert(order: order, form: form)
            var lp = inst.lp
            if objScale != 1 { lp = scaledObjective(lp, objScale) }
            if rhsScale != 1 { lp = scaledRows(lp, rhsScale) }
            let refObjective = inst.objective * objScale * rhsScale
            for (name, strategy) in configs {
                let a = try await strategy.solve(lp, context: ctx(60))
                var dist = Double.nan
                if let x = a.primal { dist = x.map { abs($0 / rhsScale - 1) }.max() ?? 0 }
                let objErr = a.objectiveValue.map { relErr($0, refObjective) } ?? .nan
                let stalled = a.warnings.contains { $0.contains("stalled") }
                if name == "IPM()" && !a.warnings.isEmpty { warnCount += 1 }
                var msg = ""
                if case .numericalFailure(let text) = a.status { msg = " msg=\"\(text.prefix(110))\"" }
                let viol = a.primal.map { lp.maxViolation(at: $0) }
                print("order \(order) kappa1 \(e(kappa)) \(form.rawValue) \(name): \(statusName(a.status)) it=\(a.iterations) dist=\(e(dist)) objErr=\(e(objErr)) mu=\(e(a.finalMu)) pres=\(e(a.primalResidual)) dres=\(e(a.dualResidual)) xover=\(a.crossover != nil) stalledWarn=\(stalled) nwarn=\(a.warnings.count) viol=\(viol.map { "\(e($0.bounds))/\(e($0.rows))" } ?? "-")\(msg)")
            }
        }
        print("order \(order): IPM() answers with a warning: \(warnCount) of 4")
    }
}

/// One scaled Hilbert model against every LP engine. args: order form objScale rhsScale
func probeHilbertOne(_ args: [String]) async throws {
    let order = Int(args[0])!
    let form = HilbertForm(rawValue: args[1])!
    let objScale = Double(args[2])!, rhsScale = Double(args[3])!
    let inst = InstanceGenerator.hilbert(order: order, form: form)
    var lp = inst.lp
    if objScale != 1 { lp = scaledObjective(lp, objScale) }
    if rhsScale != 1 { lp = scaledRows(lp, rhsScale) }
    let ref = inst.objective * objScale * rhsScale
    print("Hilbert order \(order) \(form.rawValue), objective x \(objScale), rhs x \(rhsScale): unique optimum x = \(rhsScale) * 1, objective \(ref)")
    // Independent feasibility witness: the stored data at x = rhsScale * 1.
    let witness = [Double](repeating: rhsScale, count: order)
    print("  witness x=\(rhsScale)*1: maxViolation \(lp.maxViolation(at: witness)), objective \(lp.objective(at: witness))")
    let strategies: [(String, any SolverStrategy)] = [
        ("InteriorPoint()", InteriorPoint()), ("InteriorPoint(.none)", InteriorPoint(crossover: .none)),
        ("InteriorPoint(nopresolve)", InteriorPoint(presolve: false)),
        ("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal)", Simplex(.primal)), ("Automatic()", Automatic()),
    ]
    for (name, s) in strategies {
        let t = Date()
        let a = try await s.solve(lp, context: ctx(60))
        let secs = Date().timeIntervalSince(t)
        let dist = a.primal.map { $0.map { abs($0 / rhsScale - 1) }.max() ?? 0 } ?? .nan
        var extra = ""
        if let ipm = a as? InteriorPointAnalysis {
            extra = " ipm-it \(ipm.iterations) pres \(e(ipm.primalResidual)) dres \(e(ipm.dualResidual)) mu \(e(ipm.finalMu)) xover \(ipm.crossover.map { statusName($0.status) + " it \($0.iterations) ph1 \($0.phase1Iterations)" } ?? "nil")"
        }
        if let sx = a as? SimplexAnalysis { extra = " it \(sx.iterations)" }
        var msg = ""
        if case .numericalFailure(let text) = a.status { msg = " msg \(text.prefix(100))" }
        print("  \(name): \(statusName(a.status)) dist \(e(dist)) obj \(a.objectiveValue.map { e(relErr($0, ref)) } ?? "-") \(String(format: "%.3f", secs)) s\(extra) warnings \(a.warnings.map { String($0.prefix(90)) })\(msg)")
    }
}

/// Objective scaling on well-conditioned constructed LPs. args: count seed factor free(0/1)
func probeObjectiveScale(_ args: [String]) async throws {
    let count = Int(args[0])!, seed = UInt64(args[1])!, factor = Double(args[2])!
    let free = args.count > 3 ? args[3] == "1" : true
    var rng = Rng(seed)
    var tally: [String: Int] = [:]
    for k in 0..<count {
        let m = rng.int(5, 40), n = rng.int(max(5, m / 2), 80)
        var options = ConstructedOptions()
        options.density = max(0.02, min(0.5, 6.0 / Double(m)))
        options.freeColumns = free
        let s = rng.next()
        let inst = InstanceGenerator.constructedOptimum(rows: m, columns: n, seed: s, options: options)
        let lp = scaledObjective(inst.lp, factor)
        let ref = inst.objective * factor
        let simplex = try await Simplex(.dual).solve(lp, context: ctx())
        for (name, strategy) in [("IPM()", InteriorPoint()), ("IPM(none)", InteriorPoint(crossover: .none))] {
            let a = try await strategy.solve(lp, context: ctx())
            let key = "\(name) \(statusName(a.status))"
            tally[key, default: 0] += 1
            if a.status != .optimal || relErr(a.objectiveValue ?? .nan, ref) > 1e-6 {
                print("k=\(k) seed \(s) \(m)x\(n) \(name): \(statusName(a.status)) obj err \(a.objectiveValue.map { e(relErr($0, ref)) } ?? "-") simplex \(statusName(simplex.status)) it \(a.iterations) pres \(e(a.primalResidual)) dres \(e(a.dualResidual)) mu \(e(a.finalMu))")
            }
        }
    }
    print("factor \(factor) free \(free): \(tally.sorted { $0.key < $1.key })")
}

/// Random square matrix with a prescribed condition number, equality rows, free columns, unique
/// optimum x = 1; costs c = factor * A'1. args: m kappa2 factor seeds
func probeIllFree(_ args: [String]) async throws {
    let m = Int(args[0])!, kappa = Double(args[1])!, factor = Double(args[2])!
    let seeds = args.count > 3 ? Int(args[3])! : 10
    var tally: [String: Int] = [:]
    for s in 0..<seeds {
        var rng = Rng(UInt64(1000 + s))
        let a = matrixWithCondition(m, kappa2: kappa, &rng)
        var entries: [(row: Int, col: Int, value: Double)] = []
        var b = [Double](repeating: 0, count: m)
        var c = [Double](repeating: 0, count: m)
        for j in 0..<m { for i in 0..<m { entries.append((i, j, a[j * m + i])); b[i] += a[j * m + i]; c[j] += factor * a[j * m + i] } }
        for free in [true, false] {
            let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: c,
                                xl: [Double](repeating: free ? -.infinity : -10, count: m), xu: [Double](repeating: free ? .infinity : 10, count: m), rl: b, ru: b)
            let simplex = try await Simplex(.dual).solve(lp, context: ctx())
            for (name, strategy) in [("IPM()", InteriorPoint()), ("IPM(none)", InteriorPoint(crossover: .none))] {
                let r = try await strategy.solve(lp, context: ctx())
                let dist = r.primal.map { $0.map { abs($0 - 1) }.max() ?? 0 } ?? .nan
                let key = "\(free ? "free" : "boxed") \(name) \(statusName(r.status))"
                tally[key, default: 0] += 1
                if r.status != .optimal && !(name == "IPM(none)" && statusName(r.status) == "numericalFailure") {
                    print("seed \(s) \(free ? "free" : "boxed[-10,10]") \(name): \(statusName(r.status)) it \(r.iterations) pres \(e(r.primalResidual)) mu \(e(r.finalMu)); simplex \(statusName(simplex.status)) dist \(e(dist))")
                }
            }
        }
    }
    print("m \(m) kappa2 \(e(kappa)) factor \(e(factor)): \(tally.sorted { $0.key < $1.key })")
}

/// Farkas check of a row-dual ray r for rl <= Ax <= ru, xl <= x <= xu (independent): the
/// largest value of the separating inequality; positive means the ray proves infeasibility.
func farkasValue(_ lp: CompiledLP, _ r: [Double]) -> Double {
    var value = 0.0
    for i in 0..<lp.m where r[i] != 0 {
        let bound = r[i] > 0 ? lp.rl[i] : lp.ru[i]
        if bound.isInfinite { return -.infinity }
        value += r[i] * bound
    }
    let z = lp.a.multiplyTranspose(r)
    for j in 0..<lp.n where z[j] != 0 {
        let bound = z[j] > 0 ? lp.xu[j] : lp.xl[j]
        if bound.isInfinite { return -.infinity }
        value -= z[j] * bound
    }
    return value
}

/// One ill-conditioned boxed or free model in detail. args: m kappa2 factor seed free(0/1)
func probeIllOne(_ args: [String]) async throws {
    let m = Int(args[0])!, kappa = Double(args[1])!, factor = Double(args[2])!, seed = Int(args[3])!
    let free = args.count > 4 && args[4] == "1"
    var rng = Rng(UInt64(1000 + seed))
    let a = matrixWithCondition(m, kappa2: kappa, &rng)
    var entries: [(row: Int, col: Int, value: Double)] = []
    var b = [Double](repeating: 0, count: m)
    var c = [Double](repeating: 0, count: m)
    for j in 0..<m { for i in 0..<m { entries.append((i, j, a[j * m + i])); b[i] += a[j * m + i]; c[j] += factor * a[j * m + i] } }
    let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: c,
                        xl: [Double](repeating: free ? -.infinity : -10, count: m), xu: [Double](repeating: free ? .infinity : 10, count: m), rl: b, ru: b)
    print("m \(m) kappa2 \(e(kappa)) exact kappa1 \(e(exactKappa1(a, m))) cost factor \(factor) seed \(seed) \(free ? "free" : "boxed [-10,10]") columns, equality rows, x* = 1 (unique)")
    let ones = [Double](repeating: 1, count: m)
    print("  witness x = 1: maxViolation \(lp.maxViolation(at: ones)) objective \(lp.objective(at: ones))")
    let strategies: [(String, any SolverStrategy)] = [
        ("InteriorPoint()", InteriorPoint()), ("InteriorPoint(.none)", InteriorPoint(crossover: .none)),
        ("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.primal, nopre, noscale)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Automatic()", Automatic()), ("Portfolio(dual, primal, IPM)", Portfolio([Simplex(.dual), Simplex(.primal), InteriorPoint()])),
    ]
    for (name, s) in strategies {
        let r = try await s.solve(lp, context: ctx(60))
        let dist = r.primal.map { $0.map { abs($0 - 1) }.max() ?? 0 } ?? .nan
        var extra = ""
        if let ipm = r as? InteriorPointAnalysis {
            extra = " ipm-it \(ipm.iterations) pres \(e(ipm.primalResidual)) mu \(e(ipm.finalMu))"
            if let x = ipm.crossover {
                extra += " xover \(statusName(x.status)) it \(x.iterations)"
                if let ray = x.dualRay { extra += " xover dualRay farkas \(e(farkasValue(lp, ray)))" }
            }
        }
        if let sx = r as? SimplexAnalysis {
            extra = " it \(sx.iterations)"
            if let ray = sx.dualRay { extra += " dualRay farkas \(e(farkasValue(lp, ray)))" }
        }
        print("  \(name): \(statusName(r.status)) dist \(e(dist))\(extra) warnings \(r.warnings.map { String($0.prefix(70)) })")
    }
}
