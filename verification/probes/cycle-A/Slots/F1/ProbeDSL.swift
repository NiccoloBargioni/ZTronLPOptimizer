// DSL, compile, maxViolation and Solution API checks (claims of README §2.1, §2.4).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum V: LPVariable {
    case x, y, z, i, b, f
    var domain: VariableDomain {
        switch self {
        case .i: return .integer
        case .b: return .binary
        case .f: return .free
        default: return .continuous
        }
    }
}

var dslFails = 0
func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "HELD" : "FAIL") | \(label) \(ok ? "" : "| " + detail())")
    if !ok { dslFails += 1 }
}

func rowOf(_ cm: CompiledModel<V>, _ name: String) -> (coeffs: [V: Double], lo: Double, hi: Double)? {
    guard let r = cm.rowNamed[name] else { return nil }
    var coeffs: [V: Double] = [:]
    let lp = cm.lp
    for p in lp.aT.colStart[r]..<lp.aT.colStart[r + 1] { coeffs[cm.variableAt[Int(lp.aT.rowIndex[p])]] = lp.aT.values[p] }
    return (coeffs, lp.rl[r], lp.ru[r])
}

func probeDSL() async {
    // 1. constants and variables on both sides
    do {
        let model = LPModel<V>().minimizing(V.x + V.y).subjectTo {
            (V.x + 3 <= 2 * V.y + 5).named("a")
            (3 + V.x >= V.y - 1 + V.z).named("b")
            ((V.x + V.y).within(1...4)).named("r")
            (2 <= V.x + V.z).named("dl")
            (V.x + V.y + V.z == 7 - V.z).named("e")
            (V.x + V.x + V.y - V.y + V.z >= 0).named("dup")
        }
        let cm = try model.compile()
        let a = rowOf(cm, "a")!, b = rowOf(cm, "b")!, r = rowOf(cm, "r")!, dl = rowOf(cm, "dl")!, e = rowOf(cm, "e")!, dup = rowOf(cm, "dup")!
        check(a.coeffs == [.x: 1, .y: -2] && a.lo == -inf && a.hi == 2, "DSL: x+3 <= 2y+5 is x-2y <= 2", "\(a)")
        check(b.coeffs == [.x: 1, .y: -1, .z: -1] && b.lo == -4 && b.hi == inf, "DSL: 3+x >= y-1+z is x-y-z >= -4", "\(b)")
        check(r.coeffs == [.x: 1, .y: 1] && r.lo == 1 && r.hi == 4, "DSL: within(1...4) is a range row", "\(r)")
        check(dl.coeffs == [.x: 1, .z: 1] && dl.lo == 2 && dl.hi == inf, "DSL: 2 <= x+z", "\(dl)")
        check(e.coeffs == [.x: 1, .y: 1, .z: 2] && e.lo == 7 && e.hi == 7, "DSL: x+y+z == 7-z is x+y+2z = 7", "\(e)")
        check(dup.coeffs == [.x: 2, .z: 1], "DSL: duplicate terms merged, cancelled term dropped", "\(dup)")
        let ex: LinearExpr<V> = V.x + V.x - 2 * V.x + V.y
        check(ex.count == 1 && ex[V.x] == 0, "LinearExpr: x+x-2x cancels to no term", "count=\(ex.count) \(ex)")
    } catch { check(false, "DSL rows compile", "\(error)") }

    // 2. objective sense, constant, domains
    do {
        let model = LPModel<V>().maximizing(3 * V.x + 2 * V.y - V.i + 7).subjectTo {
            (V.x + V.y + V.i + V.b + V.f <= 10).named("cap")
            (V.f >= -3 + 0 * V.x).named("fl")
        }
        let cm = try model.compile()
        let lp = cm.lp
        let jx = cm.column[.x]!, jy = cm.column[.y]!, ji = cm.column[.i]!, jb = cm.column[.b]!, jf = cm.column[.f]!
        check(lp.sense == .maximize && lp.c[jx] == -3 && lp.c[jy] == -2 && lp.c[ji] == 1 && lp.c0 == -7,
              "compile: maximize stores negated c and c0", "c=\(lp.c) c0=\(lp.c0)")
        check(lp.objective(at: [1, 1, 1, 0, 0].enumerated().map { _ in 1.0 }) == 3 + 2 - 1 + 7, "CompiledLP.objective reports the model's sense with constant", "\(lp.objective(at: [Double](repeating: 1, count: lp.n)))")
        check(lp.integerColumns.contains(Int32(ji)) && lp.integerColumns.contains(Int32(jb)) && lp.xl[jb] == 0 && lp.xu[jb] == 1,
              "compile: integer and binary domains", "int=\(lp.integerColumns) b=[\(lp.xl[jb]),\(lp.xu[jb])]")
        check(lp.xl[jf] == -3 && lp.xu[jf] == inf, "compile: free var + singleton f >= -3 lowered to bound", "[\(lp.xl[jf]),\(lp.xu[jf])] lowered=\(cm.lowered)")
        // Solve: max 3x+2y-i+7 s.t. x+y+i+b+f <= 10, f>=-3 -> x=13 (f=-3), objective 3*13+7=46
        let sol = try await Simplex(.dual).solve(model, context: ctx())
        check(sol.status == .optimal && abs((sol.objectiveValue ?? .nan) - 46) < 1e-9, "Solution: objective reported in max sense with constant", "\(sol.status) \(String(describing: sol.objectiveValue))")
        check(abs(sol.value(of: .x) - 13) < 1e-9 && abs(sol.value(of: .f) + 3) < 1e-9, "Solution.value(of:)", "x=\(sol.value(of: .x)) f=\(sol.value(of: .f))")
        let dcap = sol.dual(ofConstraintNamed: "cap") ?? .nan
        check(abs(dcap - 3) < 1e-9, "Solution.dual(cap) = sensitivity of max objective = 3", "\(dcap)")
        // lowered constraint f >= -3: raising the rhs by 1 (f >= -2) loses 3 units -> dual -3
        let dfl = sol.dual(ofConstraintNamed: "fl") ?? .nan
        check(abs(dfl + 3) < 1e-9, "Solution.dual(lowered f >= -3) = -3", "\(dfl)")
        check(sol.dual(ofConstraintNamed: "nope") == nil && sol.value(of: .z) == 0, "unknown name -> nil, absent variable -> 0")
        // reduced cost of y (max sense): c_y - A^T y = 2 - 3 = -1
        check(abs(sol.reducedCost(of: .y) + 1) < 1e-9, "Solution.reducedCost(of: y) in max sense = -1", "\(sol.reducedCost(of: .y))")
        // independent KKT of the whole result
        let rep = kkt(lp, x: sol.analysis.primal!, dualRep: sol.analysis.dual, rcRep: sol.analysis.reducedCosts, objective: sol.objectiveValue)
        check(rep.ok, "KKT of DSL max model", rep.summary)
    } catch { check(false, "DSL objective block", "\(error)") }

    // 3. relaxation helpers and bound overrides
    do {
        let base = LPModel<V>().maximizing(V.i + V.b).subjectTo { (2 * V.i + 2 * V.b <= 3).named("c") }
        let relaxed = base.continuous(.i).continuous(.b)
        let cm = try relaxed.compile()
        check(cm.lp.integerColumns.isEmpty && cm.lp.xu[cm.column[.b]!] == 1, "continuous(...) drops integrality, binary keeps [0,1]", "\(cm.lp.integerColumns) xu_b=\(cm.lp.xu[cm.column[.b]!])")
        let bb = try base.bounding(.b, .range(-2...5)).compile()
        check(bb.lp.xl[bb.column[.b]!] == 0 && bb.lp.xu[bb.column[.b]!] == 1, "binary intersected with [0,1] after bounding", "[\(bb.lp.xl[bb.column[.b]!]),\(bb.lp.xu[bb.column[.b]!])]")
        let r1 = try await BranchAndBound().solve(base, context: ctx())
        check(r1.status == .optimal && abs((r1.objectiveValue ?? .nan) - 1) < 1e-9, "MIP: max i+b s.t. 2i+2b<=3 = 1", "\(r1.status) \(String(describing: r1.objectiveValue))")
        check(r1.dual(ofConstraintNamed: "c") == nil, "MIP result has no duals (dual(ofConstraintNamed:) nil)", "\(String(describing: r1.dual(ofConstraintNamed: "c")))")
        let r2 = try await Simplex().solve(relaxed, context: ctx())
        check(abs((r2.objectiveValue ?? .nan) - 1.5) < 1e-9, "relaxation optimum 1.5", "\(String(describing: r2.objectiveValue))")
        // integer singleton 2i <= 3 lowered to i <= 1.5 then B&B; value must be integral
        let m3 = LPModel<V>().maximizing(V.i).subjectTo { (2 * V.i <= 3).named("half") ; (V.x + V.i <= 100) }
        let r3 = try await BranchAndBound().solve(m3, context: ctx())
        check(r3.status == .optimal && abs(r3.value(of: .i) - 1) < 1e-9, "integer singleton 2i<=3 gives i=1", "\(r3.status) i=\(r3.value(of: .i))")
        // 0.1 i <= 0.7 : floating 0.7/0.1 = 6.999999999999999; integer optimum must be 7
        let m4 = LPModel<V>().maximizing(V.i).subjectTo { (0.1 * V.i <= 0.7).named("tenth"); (V.x + V.i <= 100) }
        let r4 = try await BranchAndBound().solve(m4, context: ctx())
        check(r4.status == .optimal && abs(r4.value(of: .i) - 7) < 1e-9, "integer singleton 0.1i <= 0.7 gives i=7 (B&B)", "\(r4.status) i=\(r4.value(of: .i))")
        let r4c = try await CPSAT().solve(m4.integer(.x), context: ctx())
        check(abs(r4c.value(of: .i) - 7) < 1e-9, "integer singleton 0.1i <= 0.7 gives i=7 (CPSAT)", "\(r4c.status) i=\(r4c.value(of: .i))")
    } catch { check(false, "relaxation block", "\(error)") }

    // 4. compile errors
    func expectInvalid(_ label: String, _ body: () throws -> Void) {
        do { try body(); check(false, label, "did not throw") }
        catch SolverError.invalidModel(let d) { check(true, label + " (\(d.kind))") }
        catch { check(false, label, "threw \(error)") }
    }
    expectInvalid("duplicate constraint name throws invalidModel") {
        _ = try LPModel<V>().minimizing(V.x).subjectTo { (V.x + V.y >= 1).named("d"); (V.x - V.y <= 1).named("d") }.compile()
    }
    expectInvalid("NaN coefficient throws invalidModel") {
        _ = try LPModel<V>().minimizing(V.x).subjectTo { (Double.nan * V.x + V.y >= 1) }.compile()
    }
    expectInvalid("non-integral fixed integer throws invalidModel") {
        _ = try LPModel<V>().minimizing(V.i).bounding(.i, .fixed(1.5)).compile()
    }
    expectInvalid("infeasible constant constraint throws invalidModel") {
        _ = try LPModel<V>().minimizing(V.x).subjectTo { (V.x - V.x <= -1) }.compile()
    }
    // dropped small coefficient warning
    do {
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        var o = CompileOptions(); o.diagnostics = { _ in box.n += 1 }
        let cm = try LPModel<V>().minimizing(V.x).subjectTo { (1e-15 * V.x + V.y + V.z >= 1) }.compile(options: o)
        check(box.n == 1 && cm.lp.nnz == 2, "dropTolerance 1e-14 drops 1e-15 with one warning", "warnings \(box.n) nnz \(cm.lp.nnz)")
    } catch { check(false, "drop tolerance", "\(error)") }

    // 5. infeasible singleton constraint: error or status?
    do {
        let model = LPModel<V>().minimizing(V.x + V.y).subjectTo { (V.x <= -1).named("neg"); (V.x + V.y >= 0) }
        do {
            let r = try await Simplex().solve(model, context: ctx())
            print("INFO | infeasible singleton x <= -1 (x>=0): status \(r.status)")
        } catch { print("INFO | infeasible singleton x <= -1 (x>=0): solve threw \(error)") }
        var o = CompileOptions(); o.lowerSingletonConstraints = false
        let cm = try model.compile(options: o)
        let r = try await Simplex().solve(cm.lp, context: ctx())
        print("INFO | same model with lowerSingletonConstraints=false: status \(r.status)")
        // singleton crossing the bound by 1e-12 (tolerance-level)
        let model2 = LPModel<V>().minimizing(V.x + V.y).subjectTo { (V.x >= 1 + 1e-12); (V.x <= 1); (V.x + V.y >= 0) }
        do {
            let r2 = try await Simplex().solve(model2, context: ctx())
            print("INFO | singleton x>=1+1e-12 and x<=1: status \(r2.status)")
        } catch { print("INFO | singleton x>=1+1e-12 and x<=1: solve threw \(error)") }
    } catch { check(false, "infeasible singleton block", "\(error)") }

    // 6. maxViolation
    do {
        let lp = buildLP([[1, 1]], rl: [1], ru: [2], c: [1, 1], xl: [0, 0], xu: [1, 1])
        let v1 = lp.maxViolation(at: [0.5, 0.5])
        check(v1.bounds == 0 && v1.rows == 0, "maxViolation of a feasible point is 0", "\(v1)")
        let v2 = lp.maxViolation(at: [2, 1])
        check(v2.bounds == 1 && v2.rows == 1, "maxViolation of x=(2,1): bounds 1, rows 1", "\(v2)")
        let v3 = lp.maxViolation(at: [Double.nan, 0.5])
        check(v3.bounds.isNaN || v3.bounds > 0 || v3.rows.isNaN || v3.rows > 0, "maxViolation flags a NaN point", "\(v3)")
        let v4 = lp.maxViolation(at: [Double.infinity, 0])
        check(v4.bounds > 0, "maxViolation flags x=+inf above upper bound 1", "\(v4)")
    }

    // 7. hasSolution semantics
    check(SolveStatus.optimal.hasSolution && SolveStatus.feasible(stoppedBy: .timeLimit).hasSolution && !SolveStatus.infeasible.hasSolution && !SolveStatus.unbounded.hasSolution && !SolveStatus.noSolution(stoppedBy: .timeLimit).hasSolution,
          "SolveStatus.hasSolution: optimal/feasible only")
    print("DSL probe: \(dslFails) failures")
}

func probeMisc() async {
    // Two named singleton constraints implying the same bound: do their duals double count?
    do {
        let model = LPModel<V>().minimizing(V.x + V.y).subjectTo {
            (V.x >= 2).named("a")
            (2 * V.x >= 4).named("b")
            (V.x + V.y >= 1).named("c")
        }
        let sol = try await Simplex().solve(model, context: ctx())
        let da = sol.dual(ofConstraintNamed: "a") ?? .nan, db = sol.dual(ofConstraintNamed: "b") ?? .nan
        // Valid duals need 1*ya + 2*yb + yc = c_x = 1 with yc = 0 (row c slack: x+y = 2 > 1)
        let dc = sol.dual(ofConstraintNamed: "c") ?? .nan
        let residual = 1 - (1 * da + 2 * db + dc)
        check(abs(residual) < 1e-9, "dual(ofConstraintNamed:) of two lowered constraints on the same bound is a valid dual split", "ya=\(da) yb=\(db) yc=\(dc): c_x - (ya + 2yb + yc) = \(residual)")
        // The same model with lowering off (rows), for comparison
        var o = CompileOptions(); o.lowerSingletonConstraints = false
        let cm = try model.compile(options: o)
        let r = try await Simplex().solve(cm.lp, context: ctx())
        print("INFO | same model as rows: duals \(r.dual ?? []) (rows a,b,c)")
    } catch { check(false, "double count block", "\(error)") }

    // Scaling: factors are powers of two; scaled problem maps back.
    var g = SeededGenerator(seed: 99)
    var worst = 0.0
    var notPow2 = 0
    for s in 0..<50 {
        let lp = presolveRichLP(seed: UInt64(1000 + s), m: 6, n: 7)
        for mode in [ScalingMode.equilibration, .geometricEquilibration] {
            let f = Scaler.factors(for: lp, mode: mode)
            for v in f.rows + f.columns { if v <= 0 || v.isNaN || frexp(v).0 != 0.5 { notPow2 += 1 } }
            let scaled = Scaler.apply(f, to: lp)
            // a point of the original maps to the scaled one and back
            let x = (0..<lp.n).map { _ in g.uniform(in: -3...3) }
            let xs = f.scalePrimal(x)
            let back = f.unscalePrimal(xs)
            worst = max(worst, zip(x, back).map { abs($0 - $1) }.max() ?? 0)
            // objective invariant: c^T x (original) == c_s^T x_s (scaled)
            let o1 = lp.internalObjective(at: x), o2 = scaled.internalObjective(at: xs)
            worst = max(worst, abs(o1 - o2) / (1 + abs(o1)))
            // row activity: unscaleRowActivity(A_s x_s) == A x
            let a1 = lp.rowActivity(x), a2 = f.unscaleRowActivity(scaled.rowActivity(xs))
            worst = max(worst, zip(a1, a2).map { abs($0 - $1) / (1 + abs($0)) }.max() ?? 0)
        }
    }
    check(notPow2 == 0 && worst < 1e-12, "Scaler: factors are powers of two; scalePrimal/unscalePrimal/unscaleRowActivity/objective consistent", "notPow2=\(notPow2) worst=\(worst)")
}

func probeMisc2() async {
    // LP writer: range row 'a' whose Rg name collides with a column 'Rga', and another row named 'a_'.
    let lp = buildLP([[1, 1, 0], [1, 0, 1]], rl: [1, -inf], ru: [4, 3], c: [-1, -1, -1], xl: [0, 0, 0], xu: [inf, 2, 2],
                     names: LPNames(columns: ["x", "Rga", "z"], rows: ["a", "a_"]))
    do {
        let text = try LPFormat.write(lp)
        print("LP text:\n" + text)
        do {
            let back = try LPFormat.read(text)
            print("read back: rows \(back.names.rows) cols \(back.names.columns) m=\(back.m) n=\(back.n)")
            let r1 = try await Simplex().solve(lp, context: ctx()), r2 = try await Simplex().solve(back, context: ctx())
            check(back.m == lp.m && abs((r1.objectiveValue ?? .nan) - (r2.objectiveValue ?? .nan)) < 1e-9, "LP writer keeps rows distinct when an Rg name collides", "orig \(statusKey(r1.status)) \(String(describing: r1.objectiveValue)) back \(statusKey(r2.status)) \(String(describing: r2.objectiveValue)) m \(lp.m)->\(back.m)")
        } catch { check(false, "LP writer keeps rows distinct when an Rg name collides", "read back threw \(error)") }
    } catch { check(false, "LP write", "\(error)") }
    // LinearExpr Hashable regardless of term order
    let e1: LinearExpr<V> = V.x + 2 * V.y + 3, e2: LinearExpr<V> = 2 * V.y + 3 + V.x
    check(e1 == e2 && e1.hashValue == e2.hashValue, "LinearExpr == and hash regardless of term order")
    // fromTriplets: duplicates summed, zeros dropped
    let s = SparseCSC.fromTriplets(rows: 2, cols: 2, [(0, 0, 1.0), (0, 0, -1.0), (1, 1, 2.0), (1, 1, 3.0), (0, 1, 0.0)])
    check(s.nnz == 1 && s[1, 1] == 5, "SparseCSC.fromTriplets sums duplicates and drops zeros", "nnz \(s.nnz) a11=\(s[1, 1])")
    // integer column handed to an LP engine: relaxed with a warning
    let mip = buildLP([[2]], rl: [-inf], ru: [3], c: [-1], xl: [0], xu: [inf], integer: [0])
    let r = try! await Simplex().solve(mip, context: ctx())
    check(abs((r.objectiveValue ?? .nan) + 1.5) < 1e-9 && r.warnings.contains(where: { $0.contains("integer") }), "integer column relaxed by an LP engine with a warning", "\(String(describing: r.objectiveValue)) \(r.warnings)")
    // compile is deterministic for override-only variables (sorted by name)
    let m1 = LPModel<V>().minimizing(V.x).subjectTo { (V.x + V.y >= 1) }.bounding(.z, .range(0...3)).integer(.f).binary(.b)
    let c1 = try! m1.compile(), c2 = try! m1.compile()
    check(c1.lp == c2.lp && c1.variableAt == c2.variableAt, "two compilations are identical", "\(c1.variableAt) vs \(c2.variableAt)")
    print("override-only column order: \(c1.variableAt)")
}

func probeEmptyColumn() async {
    // min -w + x  s.t. x + y >= 3, x + y <= 1 (infeasible rest), w empty column with xu = inf: must be infeasible
    let infeasibleRest = buildLP([[0, 1, 1], [0, 1, 1]], rl: [3, -inf], ru: [inf, 1], c: [-1, 1, 0], xl: [0, 0, 0], xu: [inf, inf, inf])
    let feasibleRest = buildLP([[0, 1, 1], [0, 1, 1]], rl: [1, -inf], ru: [inf, 3], c: [-1, 1, 0], xl: [0, 0, 0], xu: [inf, inf, inf])
    for (tag, lp, expect) in [("rest infeasible", infeasibleRest, "infeasible"), ("rest feasible", feasibleRest, "unbounded")] {
        for pre in [true, false] {
            let s = try! await Simplex(.dual, presolve: pre).solve(lp, context: ctx())
            let i = try! await InteriorPoint(presolve: pre).solve(lp, context: ctx())
            let okS = statusKey(s.status) == expect
            let okI = statusKey(i.status) == expect || statusKey(i.status) == "infOrUnb"
            var ray = ""
            if case .unbounded = s.status, let r = s.primalRay { ray = checkPrimalRay(lp, r) ?? "ray ok" }
            if case .infeasible = s.status, let d = s.dualRay { ray = checkFarkas(lp, d) ?? "farkas ok" }
            check(okS && okI, "empty improving column, \(tag), presolve=\(pre): Simplex \(statusKey(s.status)) IPM \(statusKey(i.status)) \(ray)", "expected \(expect)")
        }
    }
    // presolve .solved path with an unbounded empty column: min -x s.t. x >= 2 (singleton row)
    let solvedUnb = buildLP([[1]], rl: [2], ru: [inf], c: [-1], xl: [0], xu: [inf])
    let s = try! await Simplex().solve(solvedUnb, context: ctx())
    let i = try! await InteriorPoint().solve(solvedUnb, context: ctx())
    check(statusKey(s.status) == "unbounded" && (s.primalRay.map { checkPrimalRay(solvedUnb, $0) == nil } ?? false) && statusKey(i.status) == "unbounded",
          "presolve-solved unbounded: Simplex \(statusKey(s.status)) ray \(String(describing: s.primalRay)) IPM \(statusKey(i.status))")
    // presolve .solved optimal path with duals: max 3x s.t. x <= 4 (singleton row), x >= 0 -> 12, dual 3
    let solvedOpt = buildLP([[1]], rl: [-inf], ru: [4], c: [3], xl: [0], xu: [inf], c0: 1, sense: .maximize)
    let o = try! await Simplex().solve(solvedOpt, context: ctx())
    let oi = try! await InteriorPoint().solve(solvedOpt, context: ctx())
    check(abs((o.objectiveValue ?? .nan) - 13) < 1e-12 && abs((o.dual?.first ?? .nan) - 3) < 1e-12 && abs((oi.dual?.first ?? .nan) - 3) < 1e-12,
          "presolve-solved optimal: objective \(String(describing: o.objectiveValue)) dual \(String(describing: o.dual)) IPM dual \(String(describing: oi.dual)) rc \(String(describing: o.reducedCosts))")
}

func probeNames() {
    let cases: [[String]] = [["a", "a", "a_2", "a"], ["x", "x_2", "x", "x_2", "x"], ["", "", " "], ["c1", "c1_2", "c1", "c1"]]
    for names in cases {
        let u = LPName.uniqued(names)
        check(Set(u).count == u.count && u.count == names.count, "LPName.uniqued gives distinct names for \(names)", "\(u)")
    }
    let lp = buildLP([[1, 1, 1, 1]], rl: [0], ru: [1], c: [0, 0, 0, 0], xl: [-5, -3, -inf, -inf], xu: [-2, 4, inf, 7])
    let b = Basis.allLogical(for: lp)
    check(b.status[0] == .atUpper && b.status[1] == .atLower && b.status[2] == .free && b.status[3] == .atUpper && b.status[4] == .basic && b.basic == [4],
          "Basis.allLogical: finite bound nearest to zero, free at zero, slacks basic", "\(b.status) \(b.basic)")
}

func probeEmptyName() async {
    let model = LPModel<V>().minimizing(V.x + V.y).subjectTo { (V.x + V.y >= 1).named(""); (V.x - V.y <= 3).named("ok") }
    do {
        let text = try model.mpsString()
        print(text)
        do { let back = try MPSFormat.read(text); check(back.m == 2, "MPS export of a constraint named \"\" reads back", "m=\(back.m) rows \(back.names.rows)") }
        catch { check(false, "MPS export of a constraint named \"\" reads back", "\(error)") }
        let lpText = try model.lpString()
        do { let back = try LPFormat.read(lpText); check(back.m == 2, "LP export of a constraint named \"\" reads back", "m=\(back.m)") }
        catch { check(false, "LP export of a constraint named \"\" reads back", "\(error)") }
    } catch { check(false, "export", "\(error)") }
}

func probeUnboundedObjective() async {
    // min -x - y s.t. x - y <= 1, x,y >= 0 : unbounded along (1,1)
    let lp = buildLP([[1, -1]], rl: [-inf], ru: [1], c: [-1, -1], xl: [0, 0], xu: [inf, inf])
    for pre in [true, false] {
        let r = try! await Simplex(.primal, presolve: pre).solve(lp, context: ctx())
        print("presolve=\(pre): \(statusKey(r.status)) hasSolution=\(r.status.hasSolution) objectiveValue=\(String(describing: r.objectiveValue)) primal=\(String(describing: r.primal))")
    }
}
