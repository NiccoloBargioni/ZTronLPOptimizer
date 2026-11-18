// DSL semantics and Solution API checks (oracle: hand-derived lowering, finite differences).
import Foundation
import ZTronLPOptimizer

enum X: LPVariable {
    case v(Int)
    case i(Int)
    case b(Int)
    case unused
    var domain: VariableDomain {
        switch self {
        case .v(let k): return k % 3 == 0 ? .free : (k % 3 == 1 ? .continuous : .continuous(.range(-2...5)))
        case .i: return .integer
        case .b: return .binary
        case .unused: return .continuous
        }
    }
}

func expect(_ cond: Bool, _ what: String, _ failures: inout Int) {
    if !cond { failures += 1; print("DSL FAIL: \(what)") }
}

func runDSL() async throws {
    var f = 0
    let x = X.v(1), y = X.v(2), z = X.v(0)
    // 1. sums and constants on both sides
    do {
        let c: LinearConstraint<X> = 2 * x + 3 <= y - 1
        expect(c.expr[x] == 2 && c.expr[y] == -1 && c.expr.constant == 0 && c.lower == -.infinity && c.upper == -4, "2x+3 <= y-1 -> 2x - y <= -4: got \(c)", &f)
        let d: LinearConstraint<X> = 5 >= x + y + 2
        expect(d.expr[x] == 1 && d.expr[y] == 1 && d.upper == 3 && d.lower == -.infinity, "5 >= x+y+2 -> x+y <= 3: got \(d)", &f)
        let e: LinearConstraint<X> = x + 1 == 2 * y + 3
        expect(e.expr[x] == 1 && e.expr[y] == -2 && e.lower == 2 && e.upper == 2, "x+1 == 2y+3 -> x-2y == 2: got \(e)", &f)
        let r = (x + y + 1).within(2...5)
        expect(r.lower == 1 && r.upper == 4 && r.expr.constant == 0, "(x+y+1) within 2...5 -> 1 <= x+y <= 4: got \(r)", &f)
        let g: LinearConstraint<X> = 3.0 <= x - 2
        expect(g.lower == 5 && g.upper == .infinity && g.expr[x] == 1, "3 <= x-2 -> x >= 5: got \(g)", &f)
        var h: LinearConstraint<X> = x <= 4
        h.expr = x + y + 10
        expect(h.upper == -6 && h.expr.constant == 0, "assigning expr with constant folds: got \(h)", &f)
        let m = x + x + 2 * x - y + y
        expect(m.count == 1 && m[x] == 4 && m[y] == 0, "duplicate terms merged: \(m)", &f)
        let n = 0 * (x + 5) + 2 * (x - 1) / 2
        expect(n[x] == 1 && n.constant == -1, "0*(x+5) + 2(x-1)/2 -> x - 1: \(n)", &f)
        let neg = -(x - 2 * y + 3)
        expect(neg[x] == -1 && neg[y] == 2 && neg.constant == -3, "negation: \(neg)", &f)
    }
    // 2. compile: coefficients, bounds, sense, constant; singleton lowering
    do {
        let model = LPModel<X>()
            .maximizing(3 * x + 2 * y - z + 7)
            .subjectTo {
                (x + y + z <= 10).named("cap")
                (2 * x - y >= -3).named("mix")
                (x - z == 1).named("link")
                (x + 2 * y).within(1...8)
                (-2 * y <= 4).named("ylow")        // singleton -> y >= -2 (domain already -2..5)
                (3 * z >= -6).named("zlow")         // singleton on a free var -> z >= -2
            }
            .bounding(x, .range(0...6))
        let cm = try model.compile()
        let lp = cm.lp
        expect(lp.sense == .maximize, "sense stored", &f)
        expect(lp.m == 4, "4 rows (2 singletons lowered), got \(lp.m)", &f)
        let jx = cm.column[x]!, jy = cm.column[y]!, jz = cm.column[z]!
        expect(lp.c[jx] == -3 && lp.c[jy] == -2 && lp.c[jz] == 1 && lp.c0 == -7, "c stored for minimization: \(lp.c) c0=\(lp.c0)", &f)
        expect(lp.xl[jx] == 0 && lp.xu[jx] == 6, "x bounds override [0,6]: \(lp.xl[jx]) \(lp.xu[jx])", &f)
        expect(lp.xl[jy] == -2 && lp.xu[jy] == 5, "y domain [-2,5] with ylow: \(lp.xl[jy]) \(lp.xu[jy])", &f)
        expect(lp.xl[jz] == -2 && lp.xu[jz] == .infinity, "z free with zlow -> [-2,inf): \(lp.xl[jz]) \(lp.xu[jz])", &f)
        let rows = [("cap", [jx: 1.0, jy: 1, jz: 1], -Double.infinity, 10.0), ("mix", [jx: 2, jy: -1], -3, .infinity),
                    ("link", [jx: 1, jz: -1], 1, 1)]
        for (name, coef, lo, hi) in rows {
            guard let i = cm.rowNamed[name] else { expect(false, "row \(name) missing", &f); continue }
            for j in 0..<lp.n { expect(lp.a[i, j] == (coef[j] ?? 0), "row \(name) col \(j) = \(lp.a[i, j])", &f) }
            expect(lp.rl[i] == lo && lp.ru[i] == hi, "row \(name) bounds \(lp.rl[i]) \(lp.ru[i])", &f)
        }
        expect(cm.lowered["ylow"] != nil && cm.lowered["zlow"] != nil, "lowered singletons recorded", &f)
        // maxViolation against own computation at a random point
        var g = RNG(5)
        for _ in 0..<50 {
            let p = (0..<lp.n).map { _ in g.unit() * 20 - 10 }
            let mv = lp.maxViolation(at: p)
            var bv = 0.0, rv = 0.0
            for j in 0..<lp.n { bv = max(bv, lp.xl[j] - p[j], p[j] - lp.xu[j]) }
            let act = activity(lp, p)
            for i in 0..<lp.m { rv = max(rv, lp.rl[i] - act[i], act[i] - lp.ru[i]) }
            expect(abs(mv.bounds - bv) < 1e-12 && abs(mv.rows - rv) < 1e-12, "maxViolation \(mv) vs \(bv),\(rv)", &f)
        }
        let nanV = lp.maxViolation(at: [Double](repeating: .nan, count: lp.n))
        print("info: maxViolation at an all-NaN point = \(nanV)")
        // solve and check objective sign / duals by finite differences
        let sol = try await Simplex(.dual).solve(model, context: ctx(10))
        expect(sol.status == .optimal, "status \(sol.status)", &f)
        let xv = sol.value(of: x), yv = sol.value(of: y), zv = sol.value(of: z)
        let objHand = 3 * xv + 2 * yv - zv + 7
        expect(abs((sol.objectiveValue ?? .nan) - objHand) < 1e-9, "objective in max sense \(sol.objectiveValue ?? .nan) vs \(objHand)", &f)
        expect(sol.value(of: .unused) == 0 && sol.reducedCost(of: .unused) == 0, "unused variable reads 0", &f)
        expect(sol.dual(ofConstraintNamed: "nope") == nil, "unknown name -> nil", &f)
        print("info: maximize model x=\(xv) y=\(yv) z=\(zv) obj=\(sol.objectiveValue ?? .nan)")
    }
    print("DSL basic checks failures=\(f)")
}

// Random DSL models; every named constraint's dual is compared with one-sided finite differences
// of the optimal value w.r.t. its right-hand side (the dual must lie between them).
func runDualFD(from: Int, count: Int) async throws {
    var failures = 0, checked = 0
    for s in from..<(from + count) {
        var g = RNG(UInt64(s) &+ 99)
        let nv = g.int(2, 4)
        let vars = (0..<nv).map { X.v($0 + 1 + 3 * g.int(0, 2)) }
        let unique = Array(Set(vars))
        struct Spec { var terms: [(X, Double)]; var kind: Int; var rhs: Double; var name: String }
        var specs: [Spec] = []
        let nc = g.int(1, 5)
        for k in 0..<nc {
            var terms: [(X, Double)] = []
            if g.chance(0.4) {
                var a = Double(g.int(-3, 3)); if a == 0 { a = 2 }
                terms = [(g.pick(unique), a)]
            } else {
                for v in unique where g.chance(0.7) { var a = Double(g.int(-3, 3)); if a == 0 { a = 1 }; terms.append((v, a)) }
                if terms.isEmpty { terms = [(unique[0], 1)] }
            }
            specs.append(Spec(terms: terms, kind: g.int(0, 2), rhs: Double(g.int(-4, 6)), name: "k\(k)"))
        }
        var cost: [(X, Double)] = []
        for v in unique { cost.append((v, Double(g.int(-4, 4)))) }
        let maximize = g.chance(0.5)
        let constant = Double(g.int(-3, 3))
        // keep everything bounded: box every variable
        func build(_ shift: [Double]) -> LPModel<X> {
            var model = LPModel<X>()
            let obj = sum(over: cost) { $0.1 * $0.0 } + constant
            model.setObjective(maximize ? .maximize : .minimize, obj)
            for (idx, sp) in specs.enumerated() {
                let e = sum(over: sp.terms) { $0.1 * $0.0 }
                let b = sp.rhs + shift[idx]
                let c: LinearConstraint<X>
                switch sp.kind {
                case 0: c = e <= b
                case 1: c = e >= b
                default: c = e == b
                }
                model.add(c.named(sp.name))
            }
            for v in unique { model.setBounds(v, .range(-6...6)) }
            return model
        }
        let zero = [Double](repeating: 0, count: specs.count)
        let base: Solution<X, SimplexAnalysis>
        do { base = try await Simplex(.dual).solve(build(zero), context: ctx(10)) } catch { continue }
        guard base.status == .optimal, let v0 = base.objectiveValue else { continue }
        let delta = 1e-3
        for (idx, sp) in specs.enumerated() {
            var up = zero; up[idx] = delta
            var dn = zero; dn[idx] = -delta
            guard let su = try? await Simplex(.dual).solve(build(up), context: ctx(10)),
                  let sd = try? await Simplex(.dual).solve(build(dn), context: ctx(10)),
                  su.status == .optimal, sd.status == .optimal,
                  let vu = su.objectiveValue, let vd = sd.objectiveValue else { continue }
            let right = (vu - v0) / delta, left = (v0 - vd) / delta
            guard let dual = base.dual(ofConstraintNamed: sp.name) else {
                failures += 1; print("seed \(s) \(sp.name): dual nil"); continue
            }
            checked += 1
            let lo = min(left, right) - 1e-5, hi = max(left, right) + 1e-5
            if dual < lo || dual > hi {
                failures += 1
                let lowered = base.compiled.lowered[sp.name] != nil
                print("seed \(s) \(sp.name) [\(lowered ? "lowered singleton" : "row")] kind=\(sp.kind) terms=\(sp.terms.map { "\($0.1)*\($0.0)" }) rhs=\(sp.rhs) \(maximize ? "max" : "min"): dual=\(dual) but FD left=\(left) right=\(right)")
            }
        }
    }
    print("dualfd done seeds \(from)..<\(from + count): checked \(checked) duals, failures=\(failures)")
}

func runDSL2() async {
    let x = X.v(1), y = X.v(2)
    // (a) relaxation helper after a binary override on a variable whose domain is continuous
    let m1 = LPModel<X>().maximizing(x).subjectTo { x + y <= 10 }.binary(x)
    let relaxed = m1.continuous(x)
    if let c1 = try? m1.compile(), let c2 = try? relaxed.compile() {
        let j = c1.column[x]!
        print("binary(x) bounds [\(c1.lp.xl[j]), \(c1.lp.xu[j])] integer=\(c1.lp.integerColumns); after .continuous(x): [\(c2.lp.xl[j]), \(c2.lp.xu[j])] integer=\(c2.lp.integerColumns)")
        let r1 = try? await Simplex(.dual).solve(relaxed, context: ctx(5))
        print("   max x over the 'relaxation': \(r1?.objectiveValue ?? .nan) (LP relaxation of the binary model would give 1)")
    }
    // (b) contradictory one-variable constraints: an infeasible model, but compile throws
    let m2 = LPModel<X>().minimizing(x).subjectTo { x >= 3; x <= 2 }
    do { let r = try await Simplex(.dual).solve(m2, context: ctx(5)); print("x>=3, x<=2 -> \(statusName(r.status))") }
    catch { print("x>=3, x<=2 (two one-variable constraints) -> throws \(error)") }
    let m3 = LPModel<X>().minimizing(x).subjectTo { x + y >= 3; x + y <= 2 }
    do { let r = try await Simplex(.dual).solve(m3, context: ctx(5)); print("x+y>=3, x+y<=2 -> \(statusName(r.status))") }
    catch { print("x+y>=3, x+y<=2 -> throws \(error)") }
    var opts = CompileOptions(); opts.lowerSingletonConstraints = false
    if let c = try? m2.compile(options: opts) { let r = try? await Simplex(.dual).solve(c.lp, context: ctx(5)); print("x>=3, x<=2 with lowerSingletonConstraints=false -> \(r.map { statusName($0.status) } ?? "throw")") }
    // (c) integer variable constrained to a fraction by a constraint (not a bound)
    let m4 = LPModel<X>().minimizing(X.i(0)).subjectTo { 2 * X.i(0) == 3 }
    do { let r = try await BranchAndBound().solve(m4, context: ctx(5)); print("integer 2i == 3 -> \(statusName(r.status))") }
    catch { print("integer 2i == 3 (a constraint) -> throws \(error)") }
    // (d) duals of two named singletons that imply the same bound: jointly they double count
    let m5 = LPModel<X>().minimizing(x).subjectTo { (x >= 2).named("a"); (2 * x >= 4).named("b") }.bounding(x, .range(0...10))
    if let s = try? await Simplex(.dual).solve(m5, context: ctx(5)) {
        let da = s.dual(ofConstraintNamed: "a") ?? .nan, db = s.dual(ofConstraintNamed: "b") ?? .nan
        print("x>=2 (a) and 2x>=4 (b), min x: dual a=\(da) b=\(db); d/dt of optimum when both move the bound by t is 1, duals predict \(da + 2 * db)")
    }
    // (e) value(of:) on a non-optimal result
    let m6 = LPModel<X>().minimizing(x).subjectTo { x + y >= 3; x + y <= 2 }
    if let s = try? await Simplex(.dual).solve(m6, context: ctx(5)) { print("infeasible: hasSolution=\(s.status.hasSolution) value(of: x)=\(s.value(of: x)) objectiveValue=\(String(describing: s.objectiveValue))") }
}
