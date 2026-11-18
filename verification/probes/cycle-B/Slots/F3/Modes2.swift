// More probe modes for cycle B / F3.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
let lock = NSLock()

func traced(_ s: InteriorPoint, _ lp: CompiledLP, seconds: Double = 20) async throws -> (InteriorPointAnalysis, [String]) {
    let log = Box<[String]>([])
    var c = ctx(seconds)
    c.progress = { e in
        lock.lock(); defer { lock.unlock() }
        switch e {
        case .ipmIteration(let it, let mu, let pr, let dr): log.value.append("  it=\(it) mu=\(fmt(mu)) pr=\(fmt(pr)) dr=\(fmt(dr))")
        case .warning(let w): log.value.append("  WARN \(w)")
        default: break
        }
    }
    let a = try await s.solve(lp, context: c)
    return (a, log.value)
}

// one: trace a single planted instance
func modeOne() async {
    let seed = UInt64(arg(2, "3050"))!
    let m = Int(arg(3, "30"))!, n = Int(arg(4, "50"))!
    let flags = arg(5, "S3")
    var o = GenOptions()
    o.degenerate = flags.contains("D"); o.maximize = flags.contains("M")
    if let r = flags.range(of: "S") { o.spread = Double(flags[r.upperBound...].prefix { "0123456789.".contains($0) }) ?? 3 }
    if flags.contains("d") { o.density = 0.08 }
    let k = knownOptimum(seed: seed, m: m, n: n, o)
    let A = denseA(k.lp)
    let mags = A.flatMap { $0 }.filter { $0 != 0 }.map { abs($0) }
    print("instance \(k.note) known=\(k.objective) |a| in [\(fmt(mags.min()!)), \(fmt(mags.max()!))] |c| max \(fmt(k.lp.c.map { abs($0) }.max()!))")
    let rep = await ConditioningAnalyzer.analyze(k.lp)
    print("analyzer: \(rep.summary)")
    for s in [InteriorPoint(), InteriorPoint(crossover: .none), InteriorPoint(presolve: false), InteriorPoint(scaling: .none), InteriorPoint(scaling: .equilibration)] {
        do {
            let (a, log) = try await traced(s, k.lp)
            print("\(s.engineName) presolve=\(s.presolve) scaling=\(s.scaling) -> \(statusName(a.status)) obj=\(a.objectiveValue.map { String($0) } ?? "nil") it=\(a.iterations) pr=\(fmt(a.primalResidual)) dr=\(fmt(a.dualResidual))")
            if flags.contains("t") { for l in log { print(l) } } else { for l in log.suffix(4) { print(l) } }
            if a.status.isOptimal, let x = a.primal {
                print("   \(kktCheck(k.lp, x: x, dual: a.dual, rc: a.reducedCosts, objective: a.objectiveValue, known: k.objective))")
            }
        } catch { print("THREW \(error)") }
    }
    for s in [Simplex(.dual), Simplex(.primal)] {
        let a = try! await s.solve(k.lp, context: ctx())
        print("\(s.engineName) -> \(statusName(a.status)) obj=\(a.objectiveValue.map { String($0) } ?? "nil")")
    }
}

// dense: planted LP with dense columns; m > 300 uses the sparse Cholesky path
func modeDense() async {
    let seed = UInt64(arg(2, "7"))!
    let m = Int(arg(3, "400"))!, n = Int(arg(4, "600"))!
    let k0 = Int(arg(5, "2"))!
    let density = Double(arg(6, "0.5"))!
    var rng = Rng(seed)
    var a = makeSparse(&rng, m: m, n: n, density: 4.0 / Double(m), spread: 0)
    for j in 0..<k0 { for i in 0..<m where rng.chance(density) { a[i][j] = rng.u(0.2, 1) * (rng.chance(0.5) ? 1 : -1) } }
    var o = GenOptions(); o.density = 4.0 / Double(m)
    let k = knownOptimum(seed: seed, m: m, n: n, o, matrix: a)
    let cols = (0..<n).map { j in (0..<m).filter { a[$0][j] != 0 }.count }
    print("m=\(m) n=\(n) dense cols requested=\(k0) actual>30%: \(cols.filter { Double($0) > 0.3 * Double(m) }.count) maxcol=\(cols.max()!)")
    for cfg in [ipm("ipm-lite", InteriorPoint()), ipm("ipm-none", InteriorPoint(crossover: .none)), ipm("ipm-none-nopre", InteriorPoint(crossover: .none, presolve: false)), spx("dual", Simplex(.dual))] {
        let t0 = Date()
        do {
            let (r, basis, extra) = try await cfg.run(k.lp, ctx(60))
            var line = "\(cfg.name) \(statusName(r.status)) obj=\(r.objectiveValue.map { String($0) } ?? "nil") known=\(k.objective) \(extra) t=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s"
            if r.status.isOptimal, let x = r.primal {
                let kk = kktCheck(k.lp, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: k.objective)
                line += " | \(kk)\(kk.ok(1e-6) ? "" : " KKT-FAIL")"
                if let basis, !cfg.name.contains("none") { let b = checkBasis(k.lp, basis, x: x); line += " | \(b)\(b.ok(1e-6) ? "" : " BASIS-FAIL")" }
            }
            print(line)
            print("   warnings: \(r.warnings)")
        } catch { print("\(cfg.name) THREW \(error)") }
    }
    let rep = await ConditioningAnalyzer.analyze(k.lp)
    print("analyzer dense findings: \(rep.findings.filter { if case .denseColumn = $0.kind { return true }; return false }.map { "\($0.severity) \($0.message)" })")
}

// netlib: IPM on the bundled netlib set
func modeNetlib() async {
    let names = args.count > 2 ? Array(args[2...]) : NetlibFixtures.names
    for name in names {
        guard let ref = ReferenceValues.netlib(named: name), let lp = try? NetlibFixtures.load(name) else { print("\(name) LOAD-FAIL"); continue }
        for cfg in [ipm("ipm-lite", InteriorPoint()), ipm("ipm-none", InteriorPoint(crossover: .none)), ipm("ipm-lite-nopre", InteriorPoint(presolve: false)), ipm("ipm-none-nopre", InteriorPoint(crossover: .none, presolve: false))] {
            let t0 = Date()
            do {
                let (r, basis, extra) = try await cfg.run(lp, ctx(60))
                let dt = Date().timeIntervalSince(t0)
                var line = "\(name) \(cfg.name) \(statusName(r.status)) obj=\(r.objectiveValue.map { String(format: "%.10e", $0) } ?? "nil") ref=\(String(format: "%.10e", ref.optimalObjective)) relerr=\(r.objectiveValue.map { fmt(ReferenceValues.relativeError($0, reference: ref.optimalObjective)) } ?? "-") \(extra) t=\(String(format: "%.3f", dt))"
                if r.status.isOptimal, let x = r.primal {
                    let kk = kktCheck(lp, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: ref.optimalObjective)
                    line += " | \(kk)"
                    if let basis, cfg.name.contains("lite") { line += " | \(checkBasis(lp, basis, x: x))" }
                }
                let w = r.warnings.filter { !$0.contains("30%") }
                if !w.isEmpty { line += " W=\(w)" }
                print(line)
            } catch { print("\(name) \(cfg.name) THREW \(error)") }
        }
    }
}

// cond: analyzer condition estimate vs own kappa_1 (explicit inverse) and kappa_2 (Jacobi SVD)
func modeCond() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "30"))!
    var worstLow = 1.0, worstHigh = 1.0
    func compare(_ label: String, _ lp: CompiledLP, _ basis: Basis) async {
        let rep = await ConditioningAnalyzer.analyze(lp, basis: basis)
        let m = lp.m, n = lp.n
        let A = denseA(lp)
        var B = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for (k, jj) in basis.basic.enumerated() {
            let j = Int(jj)
            for i in 0..<m { B[i][k] = j < n ? A[i][j] : (i == j - n ? -1 : 0) }
        }
        let k1 = inverse(B).map { oneNorm(B) * oneNorm($0) } ?? .infinity
        let sv = singularValues(B)
        let k2 = sv.last! > 0 ? sv.first! / sv.last! : .infinity
        let est = rep.basisConditionEstimate ?? .nan
        let ratio = est / k1
        worstLow = min(worstLow, ratio); worstHigh = max(worstHigh, ratio)
        let kinds = rep.findings.compactMap { f -> String? in if case .illConditionedBasis = f.kind { return "\(f.severity)" }; return nil }
        print("\(label) m=\(m) est=\(fmt(est)) kappa1=\(fmt(k1)) kappa2=\(fmt(k2)) est/k1=\(String(format: "%.3f", ratio)) outcome=\(rep.basisAnalysis) illCondFinding=\(kinds)")
    }
    for s in 0..<UInt64(count) {
        let k = knownOptimum(seed: seed0 + s, m: 15, n: 25, GenOptions())
        let a = try! await Simplex(.dual).solve(k.lp, context: ctx())
        await compare("rand\(seed0 + s)", k.lp, a.basis)
    }
    for order in 3...13 {
        let (lp, _) = hilbertLP(order: order, form: "equality")
        // basis: all structurals basic
        var st = [BasisStatus](repeating: .basic, count: 2 * order)
        for i in 0..<order { st[order + i] = .fixed }
        await compare("hilbert\(order)", lp, Basis(status: st, basic: (0..<order).map { Int32($0) }))
    }
    print("est/kappa1 range [\(worstLow), \(worstHigh)]")
}

// budget: memoryBudgetBytes cap of the analyzer and of Conditioned
func modeBudget() async {
    let order = Int(arg(2, "60"))!
    let (lp, _) = hilbertLP(order: order, form: "equality")
    var st = [BasisStatus](repeating: .basic, count: 2 * order)
    for i in 0..<order { st[order + i] = .fixed }
    let basis = Basis(status: st, basic: (0..<order).map { Int32($0) })
    let need = 16 * order * order
    for budget in [need - 1, need, need + 1, 0, 8 * order * order] {
        var c = SolveContext(); c.memoryBudgetBytes = budget
        let rep = await ConditioningAnalyzer.analyze(lp, basis: basis, context: c)
        print("m=\(order) budget=\(budget) need16m2=\(need) -> \(rep.basisAnalysis) est=\(rep.basisConditionEstimate.map { fmt($0) } ?? "nil")")
    }
    // invalid basis
    let bad = Basis(status: st, basic: [0])
    print("invalid -> \((await ConditioningAnalyzer.analyze(lp, basis: bad)).basisAnalysis)")
    // Conditioned honours the budget
    var c = ctx(); c.memoryBudgetBytes = need - 1
    let k = knownOptimum(seed: 5, m: order, n: order + 10, GenOptions())
    let a = try! await Conditioned(Simplex()).solve(k.lp, context: c)
    print("Conditioned(Simplex) budget=\(need - 1) m=\(k.lp.m) -> \(a.report.basisAnalysis) status=\(statusName(a.status))")
    var c2 = ctx(); c2.memoryBudgetBytes = 16 * k.lp.m * k.lp.m
    let a2 = try! await Conditioned(Simplex()).solve(k.lp, context: c2)
    print("Conditioned(Simplex) budget=16m^2 -> \(a2.report.basisAnalysis)")
}

// facade: Conditioned(X) returns the same answer as X
func modeFacade() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "30"))!
    var diffs = 0
    for s in 0..<UInt64(count) {
        let k = knownOptimum(seed: seed0 + s, m: 20, n: 30, GenOptions())
        let pairs: [(String, any SolutionAnalysis, any SolutionAnalysis, ConditioningReport)] = [
            await { () async -> (String, any SolutionAnalysis, any SolutionAnalysis, ConditioningReport) in
                let x = try! await InteriorPoint().solve(k.lp, context: ctx())
                let y = try! await Conditioned(InteriorPoint()).solve(k.lp, context: ctx())
                return ("ipm-lite", x, y, y.report) }(),
            await { () async -> (String, any SolutionAnalysis, any SolutionAnalysis, ConditioningReport) in
                let x = try! await InteriorPoint(crossover: .none).solve(k.lp, context: ctx())
                let y = try! await Conditioned(InteriorPoint(crossover: .none)).solve(k.lp, context: ctx())
                return ("ipm-none", x, y, y.report) }(),
            await { () async -> (String, any SolutionAnalysis, any SolutionAnalysis, ConditioningReport) in
                let x = try! await Simplex().solve(k.lp, context: ctx())
                let y = try! await Conditioned(Simplex()).solve(k.lp, context: ctx())
                return ("dual", x, y, y.report) }(),
        ]
        for (name, x, y, rep) in pairs {
            let same = x.status == y.status && x.objectiveValue == y.objectiveValue && x.primal == y.primal && x.dual == y.dual
            if !same {
                diffs += 1
                print("seed=\(seed0 + s) \(name) DIFF status \(statusName(x.status))/\(statusName(y.status)) obj \(String(describing: x.objectiveValue))/\(String(describing: y.objectiveValue))")
            }
            if s == 0 { print("seed=\(seed0) \(name) report basis=\(rep.basisAnalysis) est=\(rep.basisConditionEstimate.map { fmt($0) } ?? "nil") findings=\(rep.findings.count)") }
        }
    }
    print("facade diffs=\(diffs)")
}

// findings: thresholds of the analyzer on hand-made models
func modeFindings() async {
    func lp(_ entries: [(Int, Int, Double)], m: Int, n: Int, xl: [Double]? = nil, xu: [Double]? = nil) -> CompiledLP {
        CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, entries.map { (row: $0.0, col: $0.1, value: $0.2) }),
                   c: [Double](repeating: 1, count: n), xl: xl ?? [Double](repeating: 0, count: n),
                   xu: xu ?? [Double](repeating: 10, count: n), rl: [Double](repeating: 1, count: m), ru: [Double](repeating: .infinity, count: m))
    }
    for big in [1e6, 1.0000001e6, 1e9, 1.0000001e9] {
        let r = await ConditioningAnalyzer.analyze(lp([(0, 0, 1), (0, 1, big), (1, 0, 1), (1, 1, 1)], m: 2, n: 2))
        let f = r.findings.filter { if case .wideCoefficientRange = $0.kind { return true }; return false }.map { "\($0.severity)" }
        print("matrix ratio \(big): \(f)")
    }
    for (eps, label) in [(1e-3, "1e-3"), (1e-5, "1e-5"), (3e-5, "3e-5"), (1e-6, "1e-6")] {
        // rows (1,1,...) and (1,1+eps,...): cos = 1 - O(eps^2)
        let n = 6
        var e: [(Int, Int, Double)] = []
        for j in 0..<n { e.append((0, j, 1 + Double(j))); e.append((1, j, (1 + Double(j)) * (j == 0 ? 1 + eps : 1))) }
        let L = lp(e, m: 2, n: n)
        let A = denseA(L)
        let dot = zip(A[0], A[1]).reduce(0) { $0 + $1.0 * $1.1 }
        let cosv = dot / (A[0].reduce(0) { $0 + $1 * $1 }.squareRoot() * A[1].reduce(0) { $0 + $1 * $1 }.squareRoot())
        let r = await ConditioningAnalyzer.analyze(L)
        let f = r.findings.filter { if case .nearParallelRows = $0.kind { return true }; return false }.count
        print("near-parallel eps=\(label) 1-cos=\(fmt(1 - cosv)) found=\(f) (expected \(abs(cosv) > 1 - 1e-9 ? 1 : 0))")
    }
}
