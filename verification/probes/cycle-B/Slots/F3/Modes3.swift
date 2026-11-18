// Edge cases, invariances, limits for cycle B / F3.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func mk(_ m: Int, _ n: Int, _ e: [(Int, Int, Double)], c: [Double], c0: Double = 0, sense: ObjectiveSense = .minimize,
        xl: [Double], xu: [Double], rl: [Double], ru: [Double]) -> CompiledLP {
    CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, e.map { (row: $0.0, col: $0.1, value: $0.2) }), c: c, c0: c0,
               sense: sense, xl: xl, xu: xu, rl: rl, ru: ru)
}

func runAll(_ label: String, _ lp: CompiledLP, expect: String, known: Double?) async {
    for cfg in allConfigs {
        do {
            let (r, basis, extra) = try await cfg.run(lp, ctx(10))
            let st = statusName(r.status)
            var ok = st == expect || (st == "infOrUnb" && (expect == "infeasible" || expect == "unbounded") && cfg.name.hasPrefix("ipm"))
            var line = "\(label) \(cfg.name) \(st) obj=\(r.objectiveValue.map { String($0) } ?? "nil") expect=\(expect)/\(known.map { String($0) } ?? "-") \(extra)"
            if r.status.isOptimal, let x = r.primal {
                let k = kktCheck(lp, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: known)
                line += " | \(k)"
                if !k.ok(1e-6) { ok = false }
                if let basis, !cfg.name.contains("none") {
                    let b = checkBasis(lp, basis, x: x); line += " | \(b)"; if !b.ok(1e-6) { ok = false }
                }
            }
            if case .numericalFailure(let msg) = r.status { line += " msg=\(msg)" }
            print((ok ? "ok   " : "BAD  ") + line + (ok ? "" : " W=\(r.warnings)"))
        } catch { print("BAD  \(label) \(cfg.name) THREW \(error)") }
    }
}

func modeEdge() async {
    let inf = Double.infinity
    await runAll("empty", mk(0, 0, [], c: [], c0: 3, xl: [], xu: [], rl: [], ru: []), expect: "optimal", known: 3)
    await runAll("m0-bounded", mk(0, 2, [], c: [1, -1], xl: [0, 0], xu: [1, 1], rl: [], ru: []), expect: "optimal", known: -1)
    await runAll("m0-unbounded", mk(0, 1, [], c: [-1], xl: [0], xu: [inf], rl: [], ru: []), expect: "unbounded", known: nil)
    await runAll("n0-infeasible", mk(1, 0, [], c: [], xl: [], xu: [], rl: [1], ru: [2]), expect: "infeasible", known: nil)
    await runAll("n0-feasible", mk(1, 0, [], c: [], c0: 2, xl: [], xu: [], rl: [-1], ru: [1]), expect: "optimal", known: 2)
    // duplicate rows
    await runAll("dup-rows", mk(3, 2, [(0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 1), (2, 0, 1), (2, 1, -1)], c: [1, 2],
                                xl: [0, 0], xu: [inf, inf], rl: [1, 1, -inf], ru: [inf, inf, 0.25]), expect: "optimal", known: nil)
    // free row + equality with free columns, many optima: min 0, x - y = 0
    await runAll("free-eq-zero-obj", mk(2, 2, [(0, 0, 1), (0, 1, -1), (1, 0, 1), (1, 1, 1)], c: [0, 0],
                                        xl: [-inf, -inf], xu: [inf, inf], rl: [0, -inf], ru: [0, inf]), expect: "optimal", known: 0)
    // unbounded through free columns: min x, x - y = 0, x + y free row
    await runAll("free-unbounded", mk(2, 2, [(0, 0, 1), (0, 1, -1), (1, 0, 1), (1, 1, 2)], c: [1, 0],
                                      xl: [-inf, -inf], xu: [inf, inf], rl: [0, -inf], ru: [0, inf]), expect: "unbounded", known: nil)
    // large optimal value: min -x - y; x + 2y <= B, 2x + y <= B, x,y >= 0 -> x=y=B/3, obj -2B/3
    for B in [1e6, 1e10, 3e12, 1e13, 1e14] {
        await runAll("large-x B=\(B)", mk(2, 2, [(0, 0, 1), (0, 1, 2), (1, 0, 2), (1, 1, 1)], c: [-1, -1],
                                          xl: [0, 0], xu: [inf, inf], rl: [-inf, -inf], ru: [B, B]), expect: "optimal", known: -2 * B / 3)
    }
    // large costs: min C x + C y; x + 2y >= 1, 2x + y >= 1 -> x=y=1/3, obj 2C/3; duals C/3
    for C in [1e6, 1e10, 3e12, 1e13, 1e14] {
        await runAll("large-c C=\(C)", mk(2, 2, [(0, 0, 1), (0, 1, 2), (1, 0, 2), (1, 1, 1)], c: [C, C],
                                          xl: [0, 0], xu: [inf, inf], rl: [1, 1], ru: [inf, inf]), expect: "optimal", known: 2 * C / 3)
    }
    // tiny coefficients: same model scaled by t in the matrix
    for t in [1e-6, 1e-9, 1e-12] {
        await runAll("tiny-a t=\(t)", mk(2, 2, [(0, 0, t), (0, 1, 2 * t), (1, 0, 2 * t), (1, 1, t)], c: [1, 1],
                                         xl: [0, 0], xu: [inf, inf], rl: [t, t], ru: [inf, inf]), expect: "optimal", known: 2.0 / 3)
    }
    // degenerate vertex: 3 rows through one point in 2D
    await runAll("degenerate-vertex", mk(3, 2, [(0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, -1), (2, 0, 1)], c: [-1, -1],
                                         xl: [0, 0], xu: [inf, inf], rl: [-inf, -inf, -inf], ru: [2, 0, 1]), expect: "optimal", known: -2)
    // all columns fixed
    await runAll("all-fixed", mk(1, 2, [(0, 0, 1), (0, 1, 1)], c: [1, 1], xl: [1, 2], xu: [1, 2], rl: [0], ru: [5]), expect: "optimal", known: 3)
    // infeasible bounds via rows only, no presolve trivial: x + y >= 3, x + y <= 2 (two rows)
    await runAll("contradict-rows", mk(2, 2, [(0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 1)], c: [1, 1],
                                       xl: [0, 0], xu: [5, 5], rl: [3, -inf], ru: [inf, 2]), expect: "infeasible", known: nil)
    // infeasible with free columns: x - y >= 1, y - x >= 1
    await runAll("infeasible-free", mk(2, 2, [(0, 0, 1), (0, 1, -1), (1, 0, -1), (1, 1, 1)], c: [1, 1],
                                       xl: [-inf, -inf], xu: [inf, inf], rl: [1, 1], ru: [inf, inf]), expect: "infeasible", known: nil)
    // both infeasible and dual infeasible (min -x, x free... x - y >= 1, y - x >= 1)
    await runAll("primal+dual-infeasible", mk(2, 3, [(0, 0, 1), (0, 1, -1), (1, 0, -1), (1, 1, 1), (0, 2, 0.0)], c: [1, 1, -1],
                                              xl: [-inf, -inf, 0], xu: [inf, inf, inf], rl: [1, 1], ru: [inf, inf]), expect: "infeasible", known: nil)
}

// invariance: transformations of planted LPs must keep the optimal value
func modeInvariance() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "30"))!
    var bad = 0
    for s in 0..<UInt64(count) {
        let seed = seed0 + s
        var rng = Rng(seed &* 7919)
        let k = knownOptimum(seed: seed, m: 20, n: 30, GenOptions())
        let lp = k.lp
        let A = denseA(lp)
        let m = lp.m, n = lp.n
        func build(_ A: [[Double]], c: [Double], c0: Double, sense: ObjectiveSense, xl: [Double], xu: [Double], rl: [Double], ru: [Double]) -> CompiledLP {
            compile(A, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru)
        }
        var variants: [(String, CompiledLP, Double)] = []
        // row permutation
        let rp = Array(0..<m).permuted(&rng)
        variants.append(("rowperm", build(rp.map { A[$0] }, c: lp.c, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu, rl: rp.map { lp.rl[$0] }, ru: rp.map { lp.ru[$0] }), k.objective))
        // column permutation
        let cp = Array(0..<n).permuted(&rng)
        variants.append(("colperm", build(A.map { row in cp.map { row[$0] } }, c: cp.map { lp.c[$0] }, c0: lp.c0, sense: lp.sense, xl: cp.map { lp.xl[$0] }, xu: cp.map { lp.xu[$0] }, rl: lp.rl, ru: lp.ru), k.objective))
        // row scaling (arbitrary positive and negative factors)
        let rs = (0..<m).map { _ in (rng.chance(0.3) ? -1.0 : 1.0) * pow(10, rng.u(-2, 2)) }
        variants.append(("rowscale", build((0..<m).map { i in A[i].map { $0 * rs[i] } }, c: lp.c, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu,
                                           rl: (0..<m).map { rs[$0] > 0 ? lp.rl[$0] * rs[$0] : lp.ru[$0] * rs[$0] },
                                           ru: (0..<m).map { rs[$0] > 0 ? lp.ru[$0] * rs[$0] : lp.rl[$0] * rs[$0] }), k.objective))
        // column scaling x = s x'
        let cs = (0..<n).map { _ in pow(10, rng.u(-2, 2)) }
        variants.append(("colscale", build(A.map { row in (0..<n).map { row[$0] * cs[$0] } }, c: (0..<n).map { lp.c[$0] * cs[$0] }, c0: lp.c0, sense: lp.sense,
                                           xl: (0..<n).map { lp.xl[$0] / cs[$0] }, xu: (0..<n).map { lp.xu[$0] / cs[$0] }, rl: lp.rl, ru: lp.ru), k.objective))
        // redundant row: sum of rows 0 and 1 with loosened bounds; duplicate row 2
        let act = activity(lp, k.x)
        let sum = (0..<n).map { A[0][$0] + A[1][$0] }
        variants.append(("redundant", build(A + [sum, A[2]], c: lp.c, c0: lp.c0, sense: lp.sense, xl: lp.xl, xu: lp.xu,
                                            rl: lp.rl + [act[0] + act[1] - 100, lp.rl[2]], ru: lp.ru + [act[0] + act[1] + 100, lp.ru[2]]), k.objective))
        // sense flip: max (-f) == -(min f); internal c unchanged
        variants.append(("senseflip", build(A, c: lp.c, c0: lp.c0, sense: lp.sense == .minimize ? .maximize : .minimize, xl: lp.xl, xu: lp.xu, rl: lp.rl, ru: lp.ru), -k.objective))
        // negated columns x = -x'
        variants.append(("colneg", build(A.map { $0.map { -$0 } }, c: lp.c.map { -$0 }, c0: lp.c0, sense: lp.sense, xl: lp.xu.map { -$0 }, xu: lp.xl.map { -$0 }, rl: lp.rl, ru: lp.ru), k.objective))
        for (name, v, expected) in variants {
            for cfg in allConfigs.prefix(4) {
                do {
                    let (r, basis, extra) = try await cfg.run(v, ctx())
                    var ok = r.status.isOptimal
                    var line = "seed=\(seed) \(name) \(cfg.name) \(statusName(r.status)) obj=\(r.objectiveValue.map { String($0) } ?? "nil") expected=\(expected) \(extra)"
                    if let x = r.primal, r.status.isOptimal {
                        let kk = kktCheck(v, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: expected)
                        line += " | \(kk)"
                        if !kk.ok(1e-6) { ok = false }
                        if let basis, cfg.name.contains("lite") { let b = checkBasis(v, basis, x: x); line += " | \(b)"; if !b.ok(1e-6) { ok = false } }
                    }
                    if !ok { bad += 1; print("BAD " + line + " W=\(r.warnings)") }
                } catch { bad += 1; print("BAD seed=\(seed) \(name) \(cfg.name) THREW \(error)") }
            }
        }
    }
    print("invariance bad=\(bad)")
}

extension Array {
    func permuted(_ rng: inout Rng) -> [Element] {
        var a = self
        if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(0, i)) } }
        return a
    }
}

// limits: time limit, iteration limit, cancellation; crossover stop status
func modeLimits() async {
    let m = Int(arg(2, "1500"))!, n = Int(arg(3, "2500"))!
    var o = GenOptions(); o.density = 6.0 / Double(m); o.degenerate = true
    let k = knownOptimum(seed: 99, m: m, n: n, o)
    print("instance m=\(m) n=\(n) nnz=\(k.lp.nnz)")
    let t0 = Date()
    let full = try! await InteriorPoint().solve(k.lp, context: ctx(120))
    let tFull = Date().timeIntervalSince(t0)
    print("full lite: \(statusName(full.status)) it=\(full.iterations) xo=\(full.crossover.map { "\(statusName($0.status))/\($0.iterations)" } ?? "-") t=\(String(format: "%.3f", tFull)) objErr=\(full.objectiveValue.map { fmt(abs($0 - k.objective) / (1 + abs(k.objective))) } ?? "-")")
    for limit in [0.001, 0.01, 0.05, 0.1, 0.2] + stride(from: 0.3, through: max(0.4, tFull * 1.2), by: max(0.05, tFull / 12)).map { $0 } {
        for s in [InteriorPoint(), InteriorPoint(crossover: .none)] {
            let t1 = Date()
            let a = try! await s.solve(k.lp, context: ctx(limit))
            let dt = Date().timeIntervalSince(t1)
            let flag = (dt > limit + 0.25 ? " OVERRUN" : "") + ({ if case .feasible = a.status { return " FEASIBLE-STATUS" }; return "" }())
            print("limit=\(String(format: "%.3f", limit)) \(s.engineName) -> \(statusName(a.status)) it=\(a.iterations) xo=\(a.crossover.map { "\(statusName($0.status))/\($0.iterations)" } ?? "-") t=\(String(format: "%.3f", dt))\(flag) W=\(a.warnings.filter { !$0.contains("30%") })")
        }
    }
    for cap in [1, 3, 10] {
        let a = try! await InteriorPoint(maxIterations: cap).solve(k.lp, context: ctx(60))
        print("maxIterations=\(cap) -> \(statusName(a.status)) it=\(a.iterations)")
    }
    // cancellation
    for delay in [0.005, 0.05, 0.2] {
        let lp = k.lp
        let task = Task { () -> (SolveStatus, Double) in
            let a = try await InteriorPoint().solve(lp, context: ctx(60))
            return (a.status, a.seconds)
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        let tc = Date()
        task.cancel()
        if let (st, secs) = try? await task.value {
            print("cancel after \(delay)s -> \(statusName(st)) solveSeconds=\(String(format: "%.3f", secs)) latency=\(String(format: "%.3f", Date().timeIntervalSince(tc)))")
        }
    }
}

// mixedscale: one row with a huge right-hand side hides an absolute violation elsewhere
// (the IPM's primal residual is divided by 1 + max|b|).
func modeMixedScale() async {
    let inf = Double.infinity
    for big in [1e3, 1e6, 1e9] {
        for delta in [1e-3, 1e-5] {
            // rows: r0: x0 + x1 >= big ; r1: x2 + x3 >= 1 ; r2: x2 + x3 <= 1 - delta  (r1,r2 contradict)
            // min x0 + x1 + x2 + x3, x >= 0
            let lp = mk(3, 4, [(0, 0, 1), (0, 1, 1), (1, 2, 1), (1, 3, 1), (2, 2, 1), (2, 3, 2)], c: [1, 1, 1, 1],
                        xl: [0, 0, 0, 0], xu: [inf, inf, inf, inf], rl: [big, 1, -inf], ru: [inf, inf, 1 - delta])
            await runAll("infeas big=\(big) delta=\(delta)", lp, expect: "infeasible", known: nil)
        }
    }
    // feasible twin: r2 is x2 + 2 x3 <= 1 - delta; optimum x2 = 1 (x3 = 0), obj = big + 1
    for big in [1e6, 1e9] {
        let lp = mk(3, 4, [(0, 0, 1), (0, 1, 1), (1, 2, 1), (1, 3, 1), (2, 2, 3), (2, 3, 1)], c: [1, 1, 1, 2],
                    xl: [0, 0, 0, 0], xu: [inf, inf, inf, inf], rl: [big, 1, -inf], ru: [inf, inf, 3])
        await runAll("feas big=\(big)", lp, expect: "optimal", known: big + 1)
    }
}

// viol: worst violated rows/bounds of an IPM(.none) solution on a netlib instance
func modeViol() async {
    let name = arg(2, "beaconfd")
    let presolve = arg(3, "pre") == "pre"
    let lp = try! NetlibFixtures.load(name)
    let a = try! await InteriorPoint(crossover: .none, presolve: presolve).solve(lp, context: ctx(60))
    guard let x = a.primal else { print("no primal \(statusName(a.status))"); return }
    let act = activity(lp, x)
    var terms = [Double](repeating: 0, count: lp.m)
    for j in 0..<lp.n { for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { terms[Int(lp.a.rowIndex[p])] += abs(lp.a.values[p] * x[j]) } }
    var worstTermRel = 0.0
    for i in 0..<lp.m {
        let v = max(lp.rl[i].isFinite ? lp.rl[i] - act[i] : 0, lp.ru[i].isFinite ? act[i] - lp.ru[i] : 0, 0)
        worstTermRel = max(worstTermRel, v / (1 + terms[i]))
    }
    print("worst row violation relative to 1+sum|a_ij x_j|: \(fmt(worstTermRel))")
    var items: [(Double, String)] = []
    for i in 0..<lp.m {
        if lp.rl[i].isFinite, lp.rl[i] - act[i] > 0 { items.append(((lp.rl[i] - act[i]) / (1 + abs(lp.rl[i])), "row \(lp.names.row(i)) act=\(act[i]) rl=\(lp.rl[i]) abs=\(fmt(lp.rl[i] - act[i])) terms=\(fmt(terms[i]))")) }
        if lp.ru[i].isFinite, act[i] - lp.ru[i] > 0 { items.append(((act[i] - lp.ru[i]) / (1 + abs(lp.ru[i])), "row \(lp.names.row(i)) act=\(act[i]) ru=\(lp.ru[i]) abs=\(fmt(act[i] - lp.ru[i])) terms=\(fmt(terms[i]))")) }
    }
    for j in 0..<lp.n {
        if lp.xl[j].isFinite, lp.xl[j] - x[j] > 0 { items.append(((lp.xl[j] - x[j]) / (1 + abs(lp.xl[j])), "col \(lp.names.column(j)) x=\(x[j]) xl=\(lp.xl[j])")) }
        if lp.xu[j].isFinite, x[j] - lp.xu[j] > 0 { items.append(((x[j] - lp.xu[j]) / (1 + abs(lp.xu[j])), "col \(lp.names.column(j)) x=\(x[j]) xu=\(lp.xu[j])")) }
    }
    let bmax = (lp.rl + lp.ru).filter { $0.isFinite }.map { abs($0) }.max() ?? 0
    print("\(name) presolve=\(presolve) status=\(statusName(a.status)) pr=\(fmt(a.primalResidual)) max|b|=\(fmt(bmax)) violations=\(items.count)")
    for (v, s) in items.sorted(by: { $0.0 > $1.0 }).prefix(5) { print("  rel=\(fmt(v)) \(s)") }
}

// basisdbg: which nonbasic column makes a returned basis dual infeasible
func modeBasisDbg() async {
    let seed = UInt64(arg(2, "7"))!
    let m = Int(arg(3, "400"))!, n = Int(arg(4, "600"))!
    let k0 = Int(arg(5, "2"))!
    var rng = Rng(seed)
    var a = makeSparse(&rng, m: m, n: n, density: 4.0 / Double(m), spread: 0)
    for j in 0..<k0 { for i in 0..<m where rng.chance(0.5) { a[i][j] = rng.u(0.2, 1) * (rng.chance(0.5) ? 1 : -1) } }
    var o = GenOptions(); o.density = 4.0 / Double(m)
    let k = knownOptimum(seed: seed, m: m, n: n, o, matrix: a)
    let lp = k.lp
    let singletonRows = (0..<m).filter { i in a[i].filter { $0 != 0 }.count == 1 }.count
    print("singleton rows: \(singletonRows)")
    for (name, cfg) in [("dual-pre", spx("dual", Simplex(.dual))), ("dual-nopre", spx("dual", Simplex(.dual, presolve: false))),
                        ("lite-pre", ipm("lite", InteriorPoint())), ("lite-nopre", ipm("lite", InteriorPoint(presolve: false)))] {
        let (r, basis, _) = try! await cfg.run(lp, ctx(60))
        guard let basis, let x = r.primal else { print("\(name) no basis"); continue }
        let b = checkBasis(lp, basis, x: x)
        print("\(name) \(statusName(r.status)) \(b)")
        let act = activity(lp, x)
        for i in 0..<m where a[i].filter({ $0 != 0 }).count == 1 {
            let j = a[i].firstIndex { $0 != 0 }!
            print("   singleton row \(i): a=\(a[i][j]) rl=\(lp.rl[i]) ru=\(lp.ru[i]) act=\(act[i]) rowStatus=\(basis.status[lp.n + i]) dual=\(r.dual![i]) | col \(j) xl=\(lp.xl[j]) xu=\(lp.xu[j]) x=\(x[j]) colStatus=\(basis.status[j]) rc=\(r.reducedCosts![j])")
        }
        // detail: nonbasic statuses vs returned reduced costs and position
        if let rc = r.reducedCosts {
            var bad = 0
            for j in 0..<(lp.n + lp.m) where basis.status[j] != .basic {
                let lo = j < lp.n ? lp.xl[j] : lp.rl[j - lp.n], hi = j < lp.n ? lp.xu[j] : lp.ru[j - lp.n]
                let v = j < lp.n ? x[j] : activity(lp, x)[j - lp.n]
                let st = basis.status[j]
                let atLo = lo.isFinite && abs(v - lo) <= 1e-7 * (1 + abs(lo)), atHi = hi.isFinite && abs(v - hi) <= 1e-7 * (1 + abs(hi))
                let consistent = (st == .atLower && atLo) || (st == .atUpper && atHi) || (st == .fixed && atLo && atHi) || (st == .free && !lo.isFinite && !hi.isFinite)
                if !consistent && bad < 5 {
                    bad += 1
                    print("   col \(j) \(j < lp.n ? "struct" : "logical") status=\(st) value=\(v) lo=\(lo) hi=\(hi) rc=\(rc[j])")
                }
            }
        }
    }
}

// presolvebasis: minimal model where a singleton row and a column bound fix a column
func modePresolveBasis() async {
    let inf = Double.infinity
    // min -x0 + x1 + 2 x2 ; r0: -x0 <= 1 (x0 >= -1, singleton) ; r1: x0 + x1 + x2 >= 1 ; r2: x1 - x2 <= 0.5
    // x0 <= -1 (own bound), x1, x2 >= 0.  Optimum x = (-1, 1.25, 0.75), obj 3.75; d_0 = -1 at its own upper bound.
    let lp = mk(3, 3, [(0, 0, -1), (1, 0, 1), (1, 1, 1), (1, 2, 1), (2, 1, 1), (2, 2, -1)], c: [-1, 1, 2],
                xl: [-inf, 0, 0], xu: [-1, inf, inf], rl: [-inf, 1, -inf], ru: [1, inf, 0.5])
    for cfg in allConfigs where !cfg.name.contains("none") {
        let (r, basis, extra) = try! await cfg.run(lp, ctx())
        guard let basis, let x = r.primal else { print("\(cfg.name) \(statusName(r.status)) no basis \(extra)"); continue }
        let b = checkBasis(lp, basis, x: x)
        let k = kktCheck(lp, x: x, dual: r.dual, rc: r.reducedCosts, objective: r.objectiveValue, known: 3.75)
        print("\(cfg.name) \(statusName(r.status)) obj=\(r.objectiveValue!) x=\(x) status=\(basis.status) basic=\(basis.basic) dual=\(r.dual!) rc=\(r.reducedCosts!) \(extra)")
        print("    KKT(returned duals): \(k)")
        print("    \(b)\(b.ok(1e-6) ? "" : "  <-- basis not optimal")")
        let rep = await ConditioningAnalyzer.analyze(lp, basis: basis, primal: x)
        print("    analyzer on this basis: \(rep.basisAnalysis) est=\(rep.basisConditionEstimate.map { fmt($0) } ?? "nil")")
        for method in [Simplex.Method.primal, .dual] {
            var c = ctx(); c.warmStart = .basis(basis)
            let w = try! await Simplex(method, presolve: false).solve(lp, context: c)
            print("    warm start Simplex(\(method), presolve: false) from it: \(statusName(w.status)) iterations=\(w.iterations)")
        }
    }
}

// stalllimit: a time limit that fires inside the simplex that finishes a stalled interior point
func modeStallLimit() async {
    let seed0 = UInt64(arg(2, "1"))!
    let m = Int(arg(3, "300"))!, n = Int(arg(4, "500"))!
    let spread = Double(arg(5, "3"))!
    var o = GenOptions(); o.density = 8.0 / Double(m); o.spread = spread
    for s in 0..<UInt64(Int(arg(6, "5"))!) {
        let k = knownOptimum(seed: seed0 + s, m: m, n: n, o)
        let t0 = Date()
        let full = try! await InteriorPoint().solve(k.lp, context: ctx(120))
        let tFull = Date().timeIntervalSince(t0)
        let stalled = full.warnings.contains { $0.contains("stalled") }
        print("seed=\(seed0 + s) full: \(statusName(full.status)) it=\(full.iterations) xo=\(full.crossover.map { "\(statusName($0.status))/\($0.iterations)" } ?? "-") stalled=\(stalled) t=\(String(format: "%.3f", tFull))")
        guard stalled, tFull > 0.05 else { continue }
        for f in stride(from: 0.3, through: 0.98, by: 0.05) {
            let limit = tFull * f
            let a = try! await InteriorPoint().solve(k.lp, context: ctx(limit))
            var flag = ""
            if case .feasible = a.status {
                let kk = a.primal.map { kktCheck(k.lp, x: $0, dual: nil, rc: nil, objective: a.objectiveValue, known: nil) }
                flag = " <-- .feasible from InteriorPoint obj=\(a.objectiveValue.map { String($0) } ?? "nil") bound=\(a.bound.map { String($0) } ?? "nil") known=\(k.objective) pviol=\(kk.map { fmt($0.primalViol) } ?? "-")"
            }
            print("   limit=\(String(format: "%.3f", limit)) -> \(statusName(a.status)) it=\(a.iterations) xo=\(a.crossover.map { "\(statusName($0.status))/\($0.iterations)" } ?? "-")\(flag)")
        }
    }
}

// hugebounds: planted LPs whose infinite bounds are replaced by finite +-B (nonbinding)
func modeHugeBounds() async {
    let seed0 = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "20"))!
    let Bs = args.count > 4 ? args[4...].map { Double($0)! } : [1e9, 1e11, 1e12, 1e13, 1e15, 1e20]
    for B in Bs {
        var tally: [String: Int] = [:]
        var example = ""
        var worstObj = 0.0, worstViol = 0.0, worstLine = ""
        for s in 0..<UInt64(count) {
            let k = knownOptimum(seed: seed0 + s, m: 20, n: 30, GenOptions())
            let lp = k.lp
            let big = CompiledLP(a: lp.a, c: lp.c, c0: lp.c0, sense: lp.sense,
                                 xl: lp.xl.map { $0 == -.infinity ? -B : $0 }, xu: lp.xu.map { $0 == .infinity ? B : $0 },
                                 rl: lp.rl, ru: lp.ru)
            for cfg in [ipm("ipm-lite", InteriorPoint()), ipm("ipm-none", InteriorPoint(crossover: .none)), spx("dual", Simplex(.dual))] {
                let (r, _, extra) = try! await cfg.run(big, ctx())
                var st = statusName(r.status)
                if r.status.isOptimal, let x = r.primal, let o = r.objectiveValue {
                    let kk = kktCheck(big, x: x, dual: r.dual, rc: r.reducedCosts, objective: o, known: k.objective)
                    if kk.objKnown > worstObj { worstObj = kk.objKnown; worstLine = "seed=\(seed0 + s) \(cfg.name) obj=\(o) known=\(k.objective) \(kk) \(extra)" }
                    worstViol = max(worstViol, kk.primalViol)
                }
                if r.status.isOptimal, let o = r.objectiveValue, abs(o - k.objective) > 1e-6 * (1 + abs(k.objective)) { st += "-WRONGOBJ" }
                tally[cfg.name + ":" + st, default: 0] += 1
                if example.isEmpty && !r.status.isOptimal { example = "seed=\(seed0 + s) \(cfg.name) \(st) \(extra)" }
            }
        }
        print("bound B=\(B): \(tally.sorted { $0.key < $1.key }) \(example)")
        print("   worst optimal objective rel error \(fmt(worstObj)) worst pviol \(fmt(worstViol)): \(worstLine)")
    }
}

// bigbox: min x + y, x + 2y >= 1, 2x + y >= 1, -B <= x, y <= B  (optimum x = y = 1/3, obj 2/3)
func modeBigBox() async {
    for B in [1e4, 1e6, 1e8, 1e9, 1e10, 1e11, 1e12] {
        let lp = mk(2, 2, [(0, 0, 1), (0, 1, 2), (1, 0, 2), (1, 1, 1)], c: [1, 1], xl: [-B, -B], xu: [B, B],
                    rl: [1, 1], ru: [.infinity, .infinity])
        await runAll("bigbox B=\(B)", lp, expect: "optimal", known: 2.0 / 3)
    }
}

// findings2: degeneracy fraction, suggested scaling, empty rows/columns, big-M
func modeFindings2() async {
    // (i) degeneracy fraction vs own count
    var worst = 0.0
    for s in 0..<20 {
        var o = GenOptions(); o.degenerate = true
        let k = knownOptimum(seed: UInt64(700 + s), m: 25, n: 40, o)
        let a = try! await Simplex(.dual, presolve: false).solve(k.lp, context: ctx())
        guard let x = a.primal else { continue }
        let act = activity(k.lp, x)
        var count = 0
        for jj in a.basis.basic {
            let j = Int(jj)
            let v = j < k.lp.n ? x[j] : act[j - k.lp.n]
            let lo = j < k.lp.n ? k.lp.xl[j] : k.lp.rl[j - k.lp.n], hi = j < k.lp.n ? k.lp.xu[j] : k.lp.ru[j - k.lp.n]
            if (lo.isFinite && abs(v - lo) <= 1e-7 * (1 + abs(lo))) || (hi.isFinite && abs(v - hi) <= 1e-7 * (1 + abs(hi))) { count += 1 }
        }
        let own = Double(count) / Double(k.lp.m)
        let rep = await ConditioningAnalyzer.analyze(k.lp, basis: a.basis, primal: x)
        var reported = 0.0; var sev = "-"
        for f in rep.findings { if case .degenerateBasis(let fr) = f.kind { reported = fr; sev = "\(f.severity)" } }
        worst = max(worst, abs(own - reported))
        if s < 3 || abs(own - reported) > 1e-12 { print("degeneracy seed=\(700 + s) own=\(own) reported=\(reported) severity=\(sev) (warning iff > 0.3: \(own > 0.3))") }
    }
    print("degeneracy worst |own-reported| = \(worst)")
    // (j) suggested scaling: powers of two, equal to the engines' factors
    let k = knownOptimum(seed: 3, m: 30, n: 50, { var o = GenOptions(); o.spread = 2; return o }())
    let rep = await ConditioningAnalyzer.analyze(k.lp)
    let f = Scaler.factors(for: k.lp, mode: .geometricEquilibration)
    let pow2 = (rep.suggestedScaling.rows + rep.suggestedScaling.columns).allSatisfy { v in v > 0 && v.significandBitPattern == 0 }
    print("suggestedScaling powers of two: \(pow2); equals Scaler.factors: \(rep.suggestedScaling.rows == f.rows && rep.suggestedScaling.columns == f.columns); scalingIsApplied=\(rep.scalingIsApplied)")
    let scaled = Scaler.scale(k.lp, mode: .geometricEquilibration)
    let rep2 = await ConditioningAnalyzer.analyze(scaled)
    print("on scaled copy: scalingIsApplied=\(rep2.scalingIsApplied) equals stored: \(rep2.suggestedScaling.rows == scaled.scaling!.rows)")
    // (k) empty rows / columns
    let inf = Double.infinity
    let e = mk(3, 3, [(0, 0, 1), (0, 1, 1)], c: [1, -1, 1], xl: [0, 0, -inf], xu: [1, inf, inf], rl: [0, 1, -1], ru: [5, 2, 1])
    let r3 = await ConditioningAnalyzer.analyze(e)
    for fnd in r3.findings { print("  finding: \(fnd.severity) \(fnd.kind)") }
    // (l) big-M: x - M y <= 0, y binary
    for M in [9999.0, 1e4] {
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(row: 0, col: 0, value: 1), (row: 0, col: 1, value: -M)]), c: [1, 1],
                            xl: [0, 0], xu: [100, 1], rl: [-inf], ru: [0], integerColumns: [1])
        let r = await ConditioningAnalyzer.analyze(lp)
        print("bigM M=\(M): \(r.findings.filter { if case .bigM = $0.kind { return true }; return false }.count) finding(s)")
    }
}

// hilbertdist: distance of InteriorPoint() solutions from x = 1 (README §5 table)
func modeHilbertDist() async {
    for order in 3...12 {
        var worst = [String: Double]()
        for form in ["equality", "equalityFree", "covering", "packing"] {
            let (lp, obj) = hilbertLP(order: order, form: form)
            for (name, s) in [("ipm", InteriorPoint())] {
                let a = try! await s.solve(lp, context: ctx())
                let d = a.primal.map { $0.map { abs($0 - 1) }.max()! } ?? .nan
                worst[name] = max(worst[name] ?? 0, d)
                let oe = a.objectiveValue.map { abs($0 - obj) / max(1, abs(obj)) } ?? .nan
                worst["obj"] = max(worst["obj"] ?? 0, oe)
                if !a.status.isOptimal { print("order \(order) \(form) \(statusName(a.status))") }
            }
        }
        print("order=\(order) InteriorPoint() worst |x-1| = \(fmt(worst["ipm"]!)) worst obj rel err = \(fmt(worst["obj"]!))")
    }
}

// farkasdbg: why a simplex dual ray fails the Farkas check
func modeFarkasDbg() async {
    let seed = UInt64(arg(2, "1"))!
    let margin = Double(arg(3, "0.5"))!
    let (lp, yTrue) = infeasibleLP(seed: seed, m: 20, n: 30, density: 0.3, margin: margin)
    print("planted certificate valid: \(farkasValid(lp, yTrue))")
    for (name, s) in [("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("dual-nopre", Simplex(.dual, presolve: false))] {
        let a = try! await s.solve(lp, context: ctx())
        guard let ray = a.dualRay else { print("\(name) \(statusName(a.status)) no ray"); continue }
        for sign in [1.0, -1.0] {
            let y = ray.map { sign * $0 }
            let g = aTy(lp, y)
            var U = 0.0, L = 0.0, infNeeded: [String] = []
            for j in 0..<lp.n where abs(g[j]) > 1e-12 {
                let b = g[j] > 0 ? lp.xu[j] : lp.xl[j]
                if !b.isFinite { infNeeded.append("col\(j) g=\(fmt(g[j]))") } else { U += g[j] * b }
            }
            for i in 0..<lp.m where y[i] != 0 {
                let b = y[i] > 0 ? lp.rl[i] : lp.ru[i]
                if !b.isFinite { infNeeded.append("row\(i) y=\(fmt(y[i]))") } else { L += y[i] * b }
            }
            print("\(name) \(statusName(a.status)) sign=\(sign) L-U=\(fmt(L - U)) |y|max=\(fmt(y.map { abs($0) }.max()!)) infinite sides needed: \(infNeeded.prefix(6))")
        }
    }
}

// misc: integer columns relaxed with a warning; Conditioned warning event on numericalFailure
func modeMisc() async {
    let inf = Double.infinity
    let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(row: 0, col: 0, value: 2), (row: 0, col: 1, value: 2)]), c: [-1, -1],
                        xl: [0, 0], xu: [inf, inf], rl: [-inf], ru: [3], integerColumns: [0, 1])
    let a = try! await InteriorPoint().solve(lp, context: ctx())
    print("integer columns: \(statusName(a.status)) obj=\(a.objectiveValue!) (LP relaxation -1.5) warnings=\(a.warnings)")
    let (h, _) = hilbertLP(order: 6, form: "equality")
    let events = Box<[String]>([])
    var c = ctx()
    c.progress = { e in
        lock.lock(); defer { lock.unlock() }
        switch e {
        case .warning(let w): events.value.append("warning: \(w.prefix(90))")
        case .finished(let st, _): events.value.append("finished \(statusName(st))")
        case .started(let eng, _, _, _): events.value.append("started \(eng)")
        default: break
        }
    }
    let r = try! await Conditioned(InteriorPoint(crossover: .none)).solve(h, context: c)
    print("Conditioned(IPM .none) on Hilbert 6: \(statusName(r.status)); report summary: \(r.report.summary.prefix(120))")
    for e in events.value { print("   event \(e)") }
    print("   summary in analysis.warnings: \(r.warnings.contains(r.report.summary))")
}
