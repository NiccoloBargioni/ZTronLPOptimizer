// Slot V031, cycle A: independent REPRODUCE check of finding A2-01 (crossed bounds reported
// .optimal). Written from the finding's description; does not reuse the finder's oracle.
// Oracles here: (1) hand / enumeration emptiness of the feasible set, (2) an own violation
// measure (not CompiledLP.maxViolation), (3) an equivalent uncrossed reformulation of the
// same empty set, solved by the same engines, whose Farkas ray is checked by an own
// interval argument that does not depend on the package's sign convention, (4) the DSL
// compile path, (5) repeat runs with 1 and 8 threads.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let inf = Double.infinity

func ctx(threads: Int? = nil, warm: WarmStart = .none) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 20
    c.threads = threads
    c.metal = .off
    c.warmStart = warm
    return c
}

/// Own violation measure: max over bounds and rows of the distance outside [lo, up].
func ownViolation(_ lp: CompiledLP, _ x: [Double]) -> (bounds: Double, rows: Double) {
    var b = 0.0
    for j in 0..<lp.n {
        b = max(b, lp.xl[j] - x[j], x[j] - lp.xu[j])
    }
    var r = 0.0
    for i in 0..<lp.m {
        var act = 0.0
        for j in 0..<lp.n { act += lp.a[i, j] * x[j] }
        r = max(r, lp.rl[i] - act, act - lp.ru[i])
    }
    return (b, r)
}

/// Hand oracle: a crossed interval makes the feasible set empty, whatever A is.
func crossedWitness(_ lp: CompiledLP) -> String? {
    for j in 0..<lp.n where lp.xl[j] > lp.xu[j] { return "column \(j): [\(lp.xl[j]), \(lp.xu[j])] is empty" }
    for i in 0..<lp.m where lp.rl[i] > lp.ru[i] { return "row \(i): [\(lp.rl[i]), \(lp.ru[i])] is empty" }
    return nil
}

/// Enumeration oracle on a grid of [-10, 10]^n (step 0.25): counts feasible grid points.
func gridFeasibleCount(_ lp: CompiledLP) -> Int {
    let values = stride(from: -10.0, through: 10.0, by: 0.25).map { $0 }
    var count = 0
    var idx = [Int](repeating: 0, count: lp.n)
    while true {
        let x = idx.map { values[$0] }
        let v = ownViolation(lp, x)
        if v.bounds <= 1e-9 && v.rows <= 1e-9 { count += 1 }
        var k = 0
        while k < lp.n {
            idx[k] += 1
            if idx[k] < values.count { break }
            idx[k] = 0
            k += 1
        }
        if k == lp.n { break }
    }
    return count
}

/// Own Farkas check, both orientations: y proves {rl <= Ax <= ru, xl <= x <= xu} empty when the
/// range of (A^T y)^T x over the box and the range of y^T r over [rl, ru] do not meet.
func farkasProves(_ lp: CompiledLP, _ y: [Double]) -> (valid: Bool, detail: String) {
    func lo(_ a: Double, _ l: Double, _ u: Double) -> Double {
        if a == 0 { return 0 }
        return a > 0 ? a * l : a * u
    }
    func hi(_ a: Double, _ l: Double, _ u: Double) -> Double {
        if a == 0 { return 0 }
        return a > 0 ? a * u : a * l
    }
    var w = [Double](repeating: 0, count: lp.n)
    for j in 0..<lp.n { for i in 0..<lp.m { w[j] += lp.a[i, j] * y[i] } }
    var lx = 0.0, ux = 0.0, lr = 0.0, ur = 0.0
    for j in 0..<lp.n { lx += lo(w[j], lp.xl[j], lp.xu[j]); ux += hi(w[j], lp.xl[j], lp.xu[j]) }
    for i in 0..<lp.m { lr += lo(y[i], lp.rl[i], lp.ru[i]); ur += hi(y[i], lp.rl[i], lp.ru[i]) }
    let eps = 1e-9
    let valid = ux < lr - eps || lx > ur + eps
    return (valid, "y=\(y) A^Ty=\(w) box range [\(lx), \(ux)] row range [\(lr), \(ur)]")
}

func dense(_ rows: [[Double]], c: [Double], xl: [Double], xu: [Double], rl: [Double], ru: [Double],
           sense: ObjectiveSense = .minimize) -> CompiledLP {
    var e: [(row: Int, col: Int, value: Double)] = []
    for (i, r) in rows.enumerated() { for (j, v) in r.enumerated() where v != 0 { e.append((i, j, v)) } }
    let a = SparseCSC.fromTriplets(rows: rows.count, cols: c.count, e)
    return CompiledLP(a: a, c: sense == .maximize ? c.map { -$0 } : c, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru)
}

func line(_ label: String, _ lp: CompiledLP, _ an: any SolutionAnalysis, ray: [Double]? = nil) -> String {
    let v = an.primal.map { ownViolation(lp, $0) }
    var s = "\(label): status \(an.status) x \(an.primal.map { "\($0)" } ?? "nil") obj \(an.objectiveValue.map { "\($0)" } ?? "nil")"
    if let v { s += " ownViolation(bounds \(v.bounds), rows \(v.rows))" }
    if let ray { s += " dualRay \(ray)" }
    if !an.warnings.isEmpty { s += " warnings \(an.warnings)" }
    return s
}

// MARK: - Cases

struct Case {
    let name: String
    let lp: CompiledLP          // crossed
    let split: CompiledLP       // same feasible set (empty), no crossed interval
}

func cases() -> [Case] {
    var out: [Case] = []
    // K1: one column, no rows, x in [2, 1], min x.
    out.append(Case(
        name: "K1 column [2,1], no rows, min x",
        lp: CompiledLP(a: SparseCSC.fromTriplets(rows: 0, cols: 1, []), c: [1], xl: [2], xu: [1], rl: [], ru: []),
        split: dense([[1]], c: [1], xl: [2], xu: [inf], rl: [-inf], ru: [1])))
    // K2: one column, no rows, x in [2, 1], max x (cost pushes to the upper bound).
    out.append(Case(
        name: "K2 column [2,1], no rows, max x",
        lp: CompiledLP(a: SparseCSC.fromTriplets(rows: 0, cols: 1, []), c: [-1], sense: .maximize, xl: [2], xu: [1], rl: [], ru: []),
        split: dense([[1]], c: [1], xl: [2], xu: [inf], rl: [-inf], ru: [1], sense: .maximize)))
    // K3: crossed column that sits in a row: x0 in [4, 3], x0 + x1 + x2 <= 10, others in [0, 5].
    out.append(Case(
        name: "K3 column [4,3] inside a row",
        lp: dense([[1, 1, 1]], c: [1, 1, 1], xl: [4, 0, 0], xu: [3, 5, 5], rl: [-inf], ru: [10]),
        split: dense([[1, 1, 1], [1, 0, 0]], c: [1, 1, 1], xl: [4, 0, 0], xu: [inf, 5, 5], rl: [-inf, -inf], ru: [10, 3])))
    // K4: crossed row 3 <= x + y <= 1 with x, y in [0, 5], min x + y.
    out.append(Case(
        name: "K4 row [3,1] over x,y in [0,5]",
        lp: dense([[1, 1]], c: [1, 1], xl: [0, 0], xu: [5, 5], rl: [3], ru: [1]),
        split: dense([[1, 1], [1, 1]], c: [1, 1], xl: [0, 0], xu: [5, 5], rl: [3, -inf], ru: [inf, 1])))
    // K5: crossed row in a 2-row model, max 2x + 3y; second row feasible.
    out.append(Case(
        name: "K5 row [6,2] plus a normal row, max 2x+3y",
        lp: dense([[1, 2], [1, -1]], c: [2, 3], xl: [0, 0], xu: [4, 4], rl: [6, -inf], ru: [2, 1], sense: .maximize),
        split: dense([[1, 2], [1, 2], [1, -1]], c: [2, 3], xl: [0, 0], xu: [4, 4], rl: [6, -inf, -inf], ru: [inf, 2, 1], sense: .maximize)))
    return out
}

func statusKey(_ s: SolveStatus) -> String { "\(s)" }

// MARK: - Commands

func runGrid() async {
    let methods: [Simplex.Method] = [.dual, .primal]
    let pricings: [Simplex.Pricing] = [.dantzig, .devex, .steepestEdge]
    let presolves = [true, false]
    let scalings: [ScalingMode] = [.geometricEquilibration, .none]
    for k in cases() {
        print("== \(k.name)")
        print("  hand oracle: \(crossedWitness(k.lp) ?? "no crossed interval")")
        if k.lp.n <= 3 { print("  grid enumeration feasible points (crossed): \(gridFeasibleCount(k.lp)); (split): \(gridFeasibleCount(k.split))") }
        var tally: [String: Int] = [:]
        var tallySplit: [String: Int] = [:]
        var worstViolation = 0.0
        var splitRaysValid = 0, splitRays = 0
        var firstLine: String? = nil
        for m in methods { for p in pricings { for pre in presolves { for sc in scalings {
            let strat = Simplex(m, pricing: p, presolve: pre, scaling: sc)
            let a = try! await strat.solve(k.lp, context: ctx())
            tally[statusKey(a.status), default: 0] += 1
            if let x = a.primal, a.status == .optimal {
                let v = ownViolation(k.lp, x)
                worstViolation = max(worstViolation, v.bounds, v.rows)
            }
            if firstLine == nil { firstLine = line("  first config \(m) \(p) presolve=\(pre) \(sc)", k.lp, a, ray: a.dualRay) }
            let b = try! await strat.solve(k.split, context: ctx())
            tallySplit[statusKey(b.status), default: 0] += 1
            if b.status == .infeasible, let y = b.dualRay {
                splitRays += 1
                if farkasProves(k.split, y).valid { splitRaysValid += 1 }
            }
        } } } }
        print(firstLine ?? "")
        print("  crossed  over 24 Simplex configs: \(tally.sorted { $0.key < $1.key }); worst own violation of an .optimal point \(worstViolation)")
        print("  split    over 24 Simplex configs: \(tallySplit.sorted { $0.key < $1.key }); Farkas rays verified by own check \(splitRaysValid)/\(splitRays)")
        let ip = try! await InteriorPoint().solve(k.lp, context: ctx())
        print(line("  InteriorPoint(lite) crossed", k.lp, ip))
        let ipn = try! await InteriorPoint(crossover: .none).solve(k.lp, context: ctx())
        print(line("  InteriorPoint(none) crossed", k.lp, ipn))
        let au = try! await Automatic().solve(k.lp, context: ctx())
        print(line("  Automatic crossed", k.lp, au))
        let sp = try! await Simplex(.dual, presolve: false).solve(k.split, context: ctx())
        if let y = sp.dualRay { print("  split dual nopresolve: \(sp.status) Farkas own check: \(farkasProves(k.split, y))") }
        else { print(line("  split dual nopresolve", k.split, sp)) }
    }
}

func runWarm() async {
    // Feasible base: min -x - 2y, x + y <= 4, x, y in [0, 3]. By hand: y = 3, x = 1, obj -7.
    let base = dense([[1, 1]], c: [-1, -2], xl: [0, 0], xu: [3, 3], rl: [-inf], ru: [4])
    let cold = try! await Simplex(.dual).solve(base, context: ctx())
    print(line("base cold (hand: x=[1,3], obj -7)", base, cold))
    let crossed = BoundChange(column: 1, lower: 3.5, upper: 2.5)
    let control = BoundChange(column: 0, lower: 4.5, upper: 5)   // uncrossed, infeasible through the row with y >= 0
    for (label, ch) in [("crossed y in [3.5,2.5]", crossed), ("control x in [4.5,5] (row infeasible)", control)] {
        let target = base.applying([ch])
        print("-- \(label): hand oracle \(crossedWitness(target) ?? "no crossed interval"); grid feasible points \(gridFeasibleCount(target))")
        for m in [Simplex.Method.dual, .primal] {
            let inc = try! await Simplex(m).solve(base, context: ctx(warm: .incremental(parent: cold.basis, changes: [ch])))
            print(line("  \(m) incremental", target, inc, ray: inc.dualRay))
            let applied = try! await Simplex(m).solve(target, context: ctx())
            print(line("  \(m) cold on applying()", target, applied, ray: applied.dualRay))
        }
        var engine = SimplexEngine(lp: base, strategy: Simplex(.dual), factorization: DenseLUBasis())
        var gate = WorkGate(deadline: Deadline.after(seconds: 20))
        let first = try! await engine.solve(method: .dual, warmStart: .none, gate: &gate)
        engine.applyBoundChanges([ch])
        let after = try! await engine.solve(method: .dual, warmStart: .basis(first.basis), gate: &gate)
        print(line("  engine applyBoundChanges + dual", target, after, ray: after.dualRay))
    }
}

/// Tolerance sweep: how far the bounds cross vs. how far the reported .optimal point is off.
func runSweep() async {
    for gap in [1e-12, 1e-8, 1e-6, 1e-4, 1e-2, 1.0, 1e3] {
        let lp = dense([[1, 1]], c: [1, 1], xl: [1 + gap, 0], xu: [1, 5], rl: [-inf], ru: [10])
        for pre in [true, false] {
            let a = try! await Simplex(.dual, presolve: pre).solve(lp, context: ctx())
            let v = a.primal.map { ownViolation(lp, $0) }
            print("gap \(gap) presolve=\(pre): status \(a.status) x \(a.primal ?? []) ownViolation \(v.map { "\($0.bounds)" } ?? "-")")
        }
    }
}

/// Determinism: the same solves five times with 1 and 8 threads give one answer.
func runRepeat() async {
    var seen: [String: Set<String>] = [:]
    for k in cases() {
        for t in [1, 8] {
            for _ in 0..<5 {
                for m in [Simplex.Method.dual, .primal] {
                    let a = try! await Simplex(m).solve(k.lp, context: ctx(threads: t))
                    seen["\(k.name) \(m)", default: []].insert("\(a.status) \(a.primal ?? [])")
                }
            }
        }
    }
    for (key, values) in seen.sorted(by: { $0.key < $1.key }) { print("\(key): \(values.count) distinct answer(s) over 10 runs: \(values.sorted())") }
}

enum V: LPVariable { case x, y }

func runDSL() {
    do {
        _ = try LPModel<V>().minimizing(V.x).bounding(.x, Bounds(lower: 2, upper: 1)).compile()
        print("DSL compile with x in [2,1]: accepted")
    } catch {
        print("DSL compile with x in [2,1]: threw \(error)")
    }
}

/// Reach beyond LP (observation only): an integer column with crossed bounds.
func runMIP() async {
    let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1), (0, 1, 1)])
    let lp = CompiledLP(a: a, c: [1, 1], xl: [3, 0], xu: [2, 5], rl: [-inf], ru: [10], integerColumns: [0, 1])
    let au = try! await Automatic().solve(lp, context: ctx())
    print(line("MIP x0 in [3,2] integer: Automatic", lp, au))
    do {
        let cp = try await CPSAT(deterministic: true).solve(lp, context: ctx())
        print(line("MIP x0 in [3,2] integer: CPSAT", lp, cp))
    } catch { print("MIP CPSAT threw \(error)") }
}

let arg = CommandLine.arguments.dropFirst().first ?? "all"
switch arg {
case "mip": await runMIP()
case "grid": await runGrid()
case "warm": await runWarm()
case "sweep": await runSweep()
case "repeat": await runRepeat()
case "dsl": runDSL()
default:
    runDSL()
    await runGrid()
    await runWarm()
    await runSweep()
    await runRepeat()
}
