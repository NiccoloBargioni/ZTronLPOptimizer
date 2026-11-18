// Probe slot V035 of cycle A: contract-lens sceptic of finding A2-02 (primal simplex answers
// .infeasible on a feasible, moderately ill-conditioned LP).
// Build: swift build --product V035 -c release   Run: .build/release/V035 one 15 | sweep 200
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// Same generator as the finder's (Slots/F2/Common.swift Rng, Slots/F2/IllRandom.swift), copied
// so that instance k is the same LP. Everything checked below is computed here.
struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func u(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
}

struct Instance { let lp: CompiledLP; let n: Int; let decades: Double; let A: [[Double]]; let b: [Double]; let kappa: Double }

func instance(_ k: Int) -> Instance {
    var r = Rng(UInt64(900 + k))
    let n = r.int(5, 12)
    let decades = Double(r.int(6, 13))
    var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    var U = L
    for i in 0..<n { for j in 0..<n {
        if i == j { L[i][j] = 1; U[i][j] = 1 }
        else if i > j { L[i][j] = r.u(-1, 1) } else { U[i][j] = r.u(-1, 1) }
    } }
    let d = (0..<n).map { pow(10, -decades * Double($0) / Double(max(1, n - 1))) }
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0..<n { var s = 0.0; for p in 0..<n { s += L[i][p] * d[p] * U[p][j] }; A[i][j] = s } }
    var entries: [(row: Int, col: Int, value: Double)] = []
    var b = [Double](repeating: 0, count: n), c = [Double](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<n where A[i][j] != 0 { entries.append((i, j, A[i][j])); b[i] += A[i][j]; c[j] += A[i][j] } }
    for j in 0..<n { c[j] += 1 }
    let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: n, cols: n, entries), c: c, xl: [Double](repeating: -10, count: n),
                        xu: [Double](repeating: 10, count: n), rl: b, ru: b)
    var dm = DenseMatrix(rows: n, cols: n)
    for i in 0..<n { for j in 0..<n { dm.storage[j * n + i] = A[i][j] } }
    let kappa = (try? DenseLU(dm))?.conditionEstimate() ?? .infinity
    return Instance(lp: lp, n: n, decades: decades, A: A, b: b, kappa: kappa)
}

func f(_ v: Double) -> String { String(format: "%.3e", v) }

/// My own Farkas check over the model's rows (minimization form, row activity s = Ax in [rl, ru]):
/// value = min over s of rᵀs − max over x of (Aᵀr)ᵀx; positive certifies infeasibility.
/// Returns the value normalised by ‖r‖∞ and the rounding scale of the terms it sums.
func farkas(_ inst: Instance, _ r: [Double]) -> (margin: Double, noise: Double) {
    let lp = inst.lp, n = inst.n
    let scale = r.map { abs($0) }.max() ?? 0
    guard scale > 0 else { return (-.infinity, 0) }
    var value = 0.0, terms = 0.0
    for i in 0..<n where r[i] != 0 {
        let bound = r[i] > 0 ? lp.rl[i] : lp.ru[i]
        if !bound.isFinite { return (-.infinity, 0) }
        value += r[i] * bound; terms += abs(r[i] * bound)
    }
    for j in 0..<n {
        var z = 0.0
        for i in 0..<n { z += inst.A[i][j] * r[i] }
        if z == 0 { continue }
        let bound = z > 0 ? lp.xu[j] : lp.xl[j]
        value -= z * bound; terms += abs(z * bound)
    }
    return (value / scale, terms * Double(n) * 2.3e-16 / scale)
}

func ctx(_ seconds: Double = 20) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.metal = .off
    return c
}

func describe(_ name: String, _ inst: Instance, _ an: any SolutionAnalysis, ray: [Double]?) {
    let viol = an.primal.map { inst.lp.maxViolation(at: $0) }
    let dist = an.primal.map { $0.map { abs($0 - 1) }.max() ?? 0 }
    var line = "  \(name): \(an.status)"
    if let o = an.objectiveValue { line += " obj \(o)" }
    if let dist { line += " dist-from-1 \(f(dist))" }
    if let viol { line += " last-iterate violation rows \(f(viol.rows)) bounds \(f(viol.bounds))" }
    if let ray { let fk = farkas(inst, ray); line += " ray farkas margin \(f(fk.margin)) (rounding scale \(f(fk.noise)))" }
    line += " warnings \(an.warnings)"
    print(line)
}

func runOne(_ k: Int) async {
    let inst = instance(k)
    let ones = [Double](repeating: 1, count: inst.n)
    let v1 = inst.lp.maxViolation(at: ones)
    var dm = DenseMatrix(rows: inst.n, cols: inst.n)
    for i in 0..<inst.n { for j in 0..<inst.n { dm.storage[j * inst.n + i] = inst.A[i][j] } }
    let xs = denseSolve(dm, inst.b) ?? []
    // Residual of x = 1 summed in a different order (reverse) and with Kahan compensation, to see
    // that its feasibility is not an artefact of one summation order.
    var worstRev = 0.0, worstKahan = 0.0, rowScale = 0.0
    for i in 0..<inst.n {
        var s = 0.0
        for j in stride(from: inst.n - 1, through: 0, by: -1) { s += inst.A[i][j] }
        worstRev = max(worstRev, abs(s - inst.b[i]))
        var sum = 0.0, comp = 0.0
        for j in 0..<inst.n { let y = inst.A[i][j] - comp; let t = sum + y; comp = (t - sum) - y; sum = t }
        worstKahan = max(worstKahan, abs(sum - inst.b[i]))
        rowScale = max(rowScale, inst.A[i].map { abs($0) }.reduce(0, +))
    }
    print("instance k\(k): n \(inst.n), D spans 1e-\(inst.decades), kappa1(A) \(f(inst.kappa)); x = 1: maxViolation rows \(f(v1.rows)) bounds \(f(v1.bounds)); reverse-order residual \(f(worstRev)), Kahan residual \(f(worstKahan)) (row 1-norm up to \(f(rowScale))); dense solve dist-from-1 \(f(xs.map { abs($0 - 1) }.max() ?? .nan)), dense solve in bounds: \(xs.allSatisfy { $0 >= -10 && $0 <= 10 })")
    // Condition of the scaled matrix the engine works on.
    let scaled = Scaler.scale(inst.lp, mode: .geometricEquilibration)
    var sm = DenseMatrix(rows: inst.n, cols: inst.n)
    for j in 0..<inst.n { for p in scaled.a.colStart[j]..<scaled.a.colStart[j + 1] { sm.storage[j * inst.n + Int(scaled.a.rowIndex[p])] = scaled.a.values[p] } }
    print("  kappa1 of the geometrically scaled matrix: \(f((try? DenseLU(sm))?.conditionEstimate() ?? .infinity))")

    var tight = Tolerances(); tight.primalFeasibility = 1e-9; tight.dualFeasibility = 1e-9
    let simplexRuns: [(String, Simplex)] = [
        ("Simplex(.primal) default", Simplex(.primal)),
        ("Simplex(.primal, presolve: false, scaling: .none)", Simplex(.primal, presolve: false, scaling: .none)),
        ("Simplex(.primal, factorization: .denseLU, pricing: .dantzig)", Simplex(.primal, pricing: .dantzig, factorization: .denseLU)),
        ("Simplex(.primal, tolerances 1e-9)", Simplex(.primal, tolerances: tight)),
        ("Simplex(.dual) default", Simplex(.dual)),
    ]
    for (name, s) in simplexRuns {
        let an = try! await s.solve(inst.lp, context: ctx())
        describe(name + " [iters \(an.iterations), phase1 \(an.phase1Iterations)]", inst, an, ray: an.status == .infeasible ? an.dualRay : nil)
    }
    let ip = try! await InteriorPoint().solve(inst.lp, context: ctx())
    describe("InteriorPoint()", inst, ip, ray: nil)
    let auto = try! await Automatic().solve(inst.lp, context: ctx())
    describe("Automatic()", inst, auto, ray: nil)
    let cond = try! await Conditioned(Simplex(.primal)).solve(inst.lp, context: ctx())
    describe("Conditioned(Simplex(.primal))", inst, cond, ray: nil)
    print("    report: basisConditionEstimate \(cond.report.basisConditionEstimate.map(f) ?? "nil"), worst \(String(describing: cond.report.worstSeverity)), findings \(cond.report.findings.map { "\($0.kind): \($0.message)" })")
    for trial in 0..<3 {
        let pf = try! await Portfolio([Simplex(.primal), Simplex(.dual)]).solve(inst.lp, context: ctx())
        print("  Portfolio([primal, dual]) trial \(trial): \(pf.status) winner \(pf.winner) others \(pf.others.map { "\($0.strategy)=\($0.status)" })")
    }
}

func runSweep(_ count: Int) async {
    var buckets: [String: (total: Int, falseInfeasible: Int, rayCertifies: Int, dualOptimal: Int)] = [:]
    var list: [String] = []
    for k in 0..<count {
        let inst = instance(k)
        // The LP is feasible: x = 1 within bounds, and (A nonsingular) its exact solution near 1.
        let v1 = inst.lp.maxViolation(at: [Double](repeating: 1, count: inst.n))
        let kp = inst.kappa
        let bucket = kp < 1e8 ? "a <1e8" : (kp < 1e9 ? "b 1e8-1e9" : (kp < 1e10 ? "c 1e9-1e10" : (kp < 1e11 ? "d 1e10-1e11" : (kp < 1e12 ? "e 1e11-1e12" : "f >=1e12"))))
        let p = try! await Simplex(.primal).solve(inst.lp, context: ctx())
        let d = try! await Simplex(.dual).solve(inst.lp, context: ctx())
        var e = buckets[bucket] ?? (0, 0, 0, 0)
        e.total += 1
        if d.status == .optimal { e.dualOptimal += 1 }
        if p.status == .infeasible {
            e.falseInfeasible += 1
            let fk = p.dualRay.map { farkas(inst, $0) }
            if let fk, fk.margin > 0 { e.rayCertifies += 1 }
            list.append("k\(k) n \(inst.n) kappa \(f(kp)) x=1 viol \(f(max(v1.rows, v1.bounds))) primal infeasible, ray margin \(fk.map { f($0.margin) } ?? "nil"), warnings \(p.warnings.count); dual \(d.status)")
        }
        buckets[bucket] = e
    }
    for (key, v) in buckets.sorted(by: { $0.key < $1.key }) {
        print("BUCKET \(key): instances \(v.total), Simplex(.primal) false .infeasible \(v.falseInfeasible) (ray certifies in \(v.rayCertifies)), Simplex(.dual) optimal \(v.dualOptimal)")
    }
    for s in list { print("FALSE-INFEASIBLE", s) }
}

/// The primal run of instance k cut at growing iteration limits: how the last iterate's
/// infeasibility evolves, and how many refactorizations (every fragile pivot forces one) the run
/// spent.
func runTrace(_ k: Int) async {
    let inst = instance(k)
    let full = try! await Simplex(.primal).solve(inst.lp, context: ctx())
    print("k\(k) Simplex(.primal): \(full.status) iterations \(full.iterations) phase1 \(full.phase1Iterations) refactorizations \(full.refactorizations) degeneracy \(full.degeneracy) fragile-pivot limit m+50 = \(inst.n + 50)")
    for cap in [1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 75, 78, 79, 80] {
        let an = try! await Simplex(.primal, maxIterations: cap).solve(inst.lp, context: ctx())
        let v = an.primal.map { inst.lp.maxViolation(at: $0) }
        print("  maxIterations \(cap): \(an.status) iterations \(an.iterations) refactorizations \(an.refactorizations) last-iterate row violation \(v.map { f($0.rows) } ?? "-") bounds \(v.map { f($0.bounds) } ?? "-")")
    }
}

/// The same equality system with every column integer: x = 1 is integral and feasible, so the
/// MILP is feasible. Automatic() routes a model with integer columns to
/// BranchAndBound(engine: Simplex(.primal)).
func runMIP(_ ks: [Int]) async {
    for k in ks {
        let inst = instance(k)
        let lp = inst.lp
        let mip = CompiledLP(a: lp.a, c: lp.c, xl: lp.xl, xu: lp.xu, rl: lp.rl, ru: lp.ru,
                             integerColumns: (0..<inst.n).map { Int32($0) })
        let v = mip.maxViolation(at: [Double](repeating: 1, count: inst.n))
        let auto = try! await Automatic().solve(mip, context: ctx())
        let bbPrimal = try! await BranchAndBound(engine: Simplex(.primal)).solve(mip, context: ctx())
        print("  BranchAndBound(engine: Simplex(.primal)) k\(k): \(bbPrimal.status), root LP \(bbPrimal.root.status) root warnings \(bbPrimal.root.warnings), nodes \(bbPrimal.nodesProcessed)")
        let bbDual = try! await BranchAndBound(engine: Simplex(.dual)).solve(mip, context: ctx())
        print("MIP k\(k) kappa \(f(inst.kappa)) x=1 integral, violation \(f(max(v.rows, v.bounds))): Automatic() \(auto.status) obj \(auto.objectiveValue.map { "\($0)" } ?? "nil") warnings \(auto.warnings); BranchAndBound(engine: Simplex(.dual)) \(bbDual.status) obj \(bbDual.objectiveValue.map { "\($0)" } ?? "nil")")
    }
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "one"
if mode == "mip" {
    let ks = args.count > 2 ? args[2].split(separator: ",").compactMap { Int($0) } : [15]
    await runMIP(ks)
    exit(0)
}
let value = args.count > 2 ? Int(args[2]) ?? 15 : 15
switch mode {
case "sweep": await runSweep(value)
case "trace": await runTrace(value)
default: await runOne(value)
}
