// Cycle B / F7 probes. Independent oracles (KKT, certificates) over the package's own generators
// and fixtures, plus checks of documented defaults. Run: .build/debug/F7 <probe> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct KKTResult {
    var pinf = 0.0          // max primal violation, relative to 1 + |bound|
    var dsign = 0.0         // max dual-sign / complementarity violation (internal min form), relative to 1 + max|c|
    var rcMismatch = 0.0    // reported structural reduced costs vs c - A^T y (same scale)
    var logical = 0.0       // reported logical reduced costs vs dual (README: equal)
    var gap = 0.0           // |primal - dual objective| / (1 + |primal|), internal form
    var objErr = 0.0        // reported objective vs objective recomputed at x
    var worst = ""
}

enum Oracle {
    /// Independent KKT check. `dual` and `reducedCosts` are read in the model's own sense
    /// (Analysis.swift: dual[i] = sensitivity of the reported objective to the rhs of row i).
    static func kkt(_ lp: CompiledLP, _ an: some SolutionAnalysis) -> KKTResult? {
        guard let x = an.primal, let yModel = an.dual, let rc = an.reducedCosts, let obj = an.objectiveValue else { return nil }
        let m = lp.m, n = lp.n
        let s: Double = lp.sense == .maximize ? -1 : 1
        let A = lp.a
        var act = [Double](repeating: 0, count: m)
        for j in 0..<n {
            for p in A.colStart[j]..<A.colStart[j + 1] { act[Int(A.rowIndex[p])] += A.values[p] * x[j] }
        }
        var r = KKTResult()
        func fin(_ v: Double) -> Double { v.isFinite ? abs(v) : 0 }
        for j in 0..<n {
            let sc = 1 + max(fin(lp.xl[j]), fin(lp.xu[j]))
            r.pinf = max(r.pinf, (lp.xl[j] - x[j]) / sc, (x[j] - lp.xu[j]) / sc)
        }
        for i in 0..<m {
            let sc = 1 + max(fin(lp.rl[i]), fin(lp.ru[i]))
            r.pinf = max(r.pinf, (lp.rl[i] - act[i]) / sc, (act[i] - lp.ru[i]) / sc)
        }
        let y = yModel.map { s * $0 }      // internal (minimization) duals
        var d = lp.c                        // internal costs
        for j in 0..<n {
            for p in A.colStart[j]..<A.colStart[j + 1] { d[j] -= A.values[p] * y[Int(A.rowIndex[p])] }
        }
        let cmax = 1 + (lp.c.map { abs($0) }.max() ?? 0)
        var worstV = 0.0
        func note(_ v: Double, _ what: @autoclosure () -> String) {
            if v > worstV { worstV = v; r.worst = what() }
        }
        // Columns.
        for j in 0..<n {
            let tl = 1e-6 * (1 + fin(lp.xl[j])), tu = 1e-6 * (1 + fin(lp.xu[j]))
            let atL = lp.xl[j].isFinite && x[j] - lp.xl[j] <= tl
            let atU = lp.xu[j].isFinite && lp.xu[j] - x[j] <= tu
            var v = 0.0
            if atL && atU { v = 0 } else if atL { v = max(0, -d[j]) } else if atU { v = max(0, d[j]) } else { v = abs(d[j]) }
            v /= cmax
            r.dsign = max(r.dsign, v); note(v, "col \(j) x=\(x[j]) [\(lp.xl[j]),\(lp.xu[j])] d=\(d[j])")
            r.rcMismatch = max(r.rcMismatch, abs(s * rc[j] - d[j]) / cmax)
        }
        // Rows: y_i >= 0 at rl, <= 0 at ru, 0 strictly between.
        for i in 0..<m {
            let tl = 1e-6 * (1 + fin(lp.rl[i])), tu = 1e-6 * (1 + fin(lp.ru[i]))
            let atL = lp.rl[i].isFinite && act[i] - lp.rl[i] <= tl
            let atU = lp.ru[i].isFinite && lp.ru[i] - act[i] <= tu
            var v = 0.0
            if atL && atU { v = 0 } else if atL { v = max(0, -y[i]) } else if atU { v = max(0, y[i]) } else { v = abs(y[i]) }
            v /= cmax
            r.dsign = max(r.dsign, v); note(v, "row \(i) act=\(act[i]) [\(lp.rl[i]),\(lp.ru[i])] y=\(y[i])")
            if rc.count == n + m { r.logical = max(r.logical, abs(rc[n + i] - yModel[i]) / cmax) } else { r.logical = .infinity }
        }
        // Dual objective (internal form), with multipliers below 1e-9 dropped.
        var dualObj = lp.c0
        var dualInf = false
        for i in 0..<m where abs(y[i]) > 1e-9 {
            let b = y[i] > 0 ? lp.rl[i] : lp.ru[i]
            if b.isFinite { dualObj += y[i] * b } else { dualInf = true }
        }
        for j in 0..<n where abs(d[j]) > 1e-9 {
            let b = d[j] > 0 ? lp.xl[j] : lp.xu[j]
            if b.isFinite { dualObj += d[j] * b } else { dualInf = true }
        }
        var primalObj = lp.c0
        for j in 0..<n { primalObj += lp.c[j] * x[j] }
        r.gap = dualInf ? .infinity : abs(primalObj - dualObj) / (1 + abs(primalObj))
        r.objErr = abs(obj - s * primalObj) / (1 + abs(obj))
        return r
    }

    /// Farkas value of a candidate dual ray r for rl <= Ax <= ru, xl <= x <= xu (positive certifies).
    static func farkas(_ lp: CompiledLP, _ r: [Double]) -> Double {
        var value = 0.0
        for i in 0..<lp.m where abs(r[i]) > 1e-12 {
            let b = r[i] > 0 ? lp.rl[i] : lp.ru[i]
            if !b.isFinite { return -.infinity }
            value += r[i] * b
        }
        var z = [Double](repeating: 0, count: lp.n)
        for j in 0..<lp.n {
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { z[j] += lp.a.values[p] * r[Int(lp.a.rowIndex[p])] }
        }
        for j in 0..<lp.n where abs(z[j]) > 1e-12 {
            let b = z[j] > 0 ? lp.xu[j] : lp.xl[j]
            if !b.isFinite { return -.infinity }
            value -= z[j] * b
        }
        return value
    }
}

func fmt(_ v: Double) -> String { String(format: "%.2e", v) }

enum F7Probes {
    static func dispatch() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { return }
        do {
            switch cmd {
            case "kkt": try await kktSuite(args)
            case "rays": try await rays(args)
            case "defaults": defaults()
            case "hilbert": try await HilbertTable.run()
            case "api2": try await Api2Probe.run()
            case "budget": try await BudgetProbe.run()
            case "hilbertonly": try await HilbertOnlyDense.run(args.dropFirst().map { Int($0)! })
            case "hilbertwarn": try await HilbertWarnings.run(args.dropFirst().map { Int($0)! })
            default: print("unknown probe \(cmd)")
            }
        } catch {
            print("probe threw: \(error)")
        }
    }

    /// kkt <count> <seed> [maxRows maxCols]: the constructed suite the integration tests use.
    static func kktSuite(_ args: [String]) async throws {
        let count = args.count > 1 ? Int(args[1])! : 100
        let seed = args.count > 2 ? UInt64(args[2])! : 11
        let maxR = args.count > 3 ? Int(args[3])! : 50, maxC = args.count > 4 ? Int(args[4])! : 100
        let suite = InstanceGenerator.constructedSuite(count: count, seed: seed, maxSize: (maxR, maxC))
        var ctx = SolveContext(); ctx.timeLimit = 30
        let engines: [(String, any SolverStrategy)] = [
            ("Simplex(.primal)", Simplex(.primal)), ("Simplex(.dual)", Simplex(.dual)),
            ("Simplex(.dual,presolve:false)", Simplex(.dual, presolve: false)),
            ("InteriorPoint()", InteriorPoint()), ("InteriorPoint(.none)", InteriorPoint(crossover: .none)),
            ("Automatic()", Automatic()),
        ]
        for (name, engine) in engines {
            var worst = KKTResult(); var notOptimal = 0; var objRel = 0.0; var missing = 0
            var worstSeed: [String: UInt64] = [:]; var kinds: [String: Int] = [:]
            for (k, inst) in suite.enumerated() {
                let an = try await engine.solve(inst.lp, context: ctx)
                guard an.status == .optimal else { notOptimal += 1; continue }
                guard let r = Oracle.kkt(inst.lp, an) else { missing += 1; continue }
                let e = abs(an.objectiveValue! - inst.objective) / max(1, abs(inst.objective))
                if e > objRel { objRel = e; worstSeed["obj"] = inst.seed }
                if r.pinf > worst.pinf { worst.pinf = r.pinf; worstSeed["pinf"] = inst.seed }
                if r.dsign > worst.dsign { worst.dsign = r.dsign; worstSeed["dsign"] = inst.seed; worst.worst = "k=\(k) " + r.worst }
                if r.rcMismatch > worst.rcMismatch { worst.rcMismatch = r.rcMismatch; worstSeed["rc"] = inst.seed }
                if r.logical > worst.logical { worst.logical = r.logical; worstSeed["logical"] = inst.seed }
                if r.gap > worst.gap { worst.gap = r.gap; worstSeed["gap"] = inst.seed }
                if r.objErr > worst.objErr { worst.objErr = r.objErr; worstSeed["objErr"] = inst.seed }
                if r.dsign > 1e-6 || r.logical > 1e-6 || r.rcMismatch > 1e-6 || r.gap > 1e-6 {
                    let kind = k % 10 == 3 ? "degenerate" : k % 10 == 5 ? "free" : k % 10 == 7 ? "range" : k % 10 == 9 ? "maximize" : "plain"
                    kinds[kind, default: 0] += 1
                }
            }
            print("\(name): notOptimal=\(notOptimal) noDuals=\(missing) objRel=\(fmt(objRel)) pinf=\(fmt(worst.pinf)) dsign=\(fmt(worst.dsign)) rcMismatch=\(fmt(worst.rcMismatch)) logical=\(fmt(worst.logical)) gap=\(fmt(worst.gap)) objErr=\(fmt(worst.objErr))")
            print("    failing(>1e-6) by kind: \(kinds.sorted { $0.key < $1.key })  worst seeds: \(worstSeed.sorted { $0.key < $1.key })")
            if worst.dsign > 1e-6 { print("    worst dual-sign: \(worst.worst)") }
        }
    }

    /// rays <count> <seed>: CertificateTests' constructions, applied to the maximize instances the
    /// tests filter out, and to the minimize ones for comparison.
    static func rays(_ args: [String]) async throws {
        let count = args.count > 1 ? Int(args[1])! : 60
        let seed = args.count > 2 ? UInt64(args[2])! : 404
        var ctx = SolveContext(); ctx.timeLimit = 30
        for sense in [ObjectiveSense.minimize, .maximize] {
            var statuses: [String: Int] = [:]; var farkasPos = 0, farkasNeg = 0, noRay = 0
            var primalOK = 0, primalBad = 0, noPrimal = 0
            for inst in InstanceGenerator.constructedSuite(count: count, seed: seed, maxSize: (30, 60)) {
                let lp0 = inst.lp
                // The same LP in the requested sense (internal costs unchanged).
                let lp = CompiledLP(a: lp0.a, c: lp0.c, c0: 0, sense: sense, xl: lp0.xl, xu: lp0.xu, rl: lp0.rl, ru: lp0.ru)
                // Infeasible: add c_int x <= optimum_int - 1 - 1%.
                var e: [(row: Int, col: Int, value: Double)] = []
                for j in 0..<lp.n {
                    for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { e.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
                    if lp.c[j] != 0 { e.append((lp.m, j, lp.c[j])) }
                }
                let opt = lp.internalObjective(at: inst.primal)
                let inf = CompiledLP(a: SparseCSC.fromTriplets(rows: lp.m + 1, cols: lp.n, e), c: lp.c, c0: 0, sense: sense,
                                     xl: lp.xl, xu: lp.xu, rl: lp.rl + [-.infinity], ru: lp.ru + [opt - 1 - 0.01 * abs(opt)])
                for strategy in [Simplex(.primal), Simplex(.dual)] {
                    let an = try await strategy.solve(inf, context: ctx)
                    statuses["inf:\(an.status)", default: 0] += 1
                    guard let ray = an.dualRay else { noRay += 1; continue }
                    if Oracle.farkas(inf, ray) > 0 { farkasPos += 1 } else if Oracle.farkas(inf, ray.map { -$0 }) > 0 { farkasNeg += 1 } else { farkasNeg += 0 }
                }
                // Unbounded: one more column with internal cost -1 that only helps one-sided rows.
                var u: [(row: Int, col: Int, value: Double)] = []
                for j in 0..<lp.n {
                    for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { u.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
                }
                for i in 0..<lp.m {
                    if lp.ru[i] == .infinity && lp.rl[i] > -.infinity { u.append((i, lp.n, 1)) }
                    if lp.rl[i] == -.infinity && lp.ru[i] < .infinity { u.append((i, lp.n, -1)) }
                }
                let unb = CompiledLP(a: SparseCSC.fromTriplets(rows: lp.m, cols: lp.n + 1, u), c: lp.c + [-1], c0: 0, sense: sense,
                                     xl: lp.xl + [0], xu: lp.xu + [.infinity], rl: lp.rl, ru: lp.ru)
                for strategy in [Simplex(.primal), Simplex(.dual)] {
                    let an = try await strategy.solve(unb, context: ctx)
                    statuses["unb:\(an.status)", default: 0] += 1
                    guard let ray = an.primalRay else { noPrimal += 1; continue }
                    // Improving for the internal (minimization) objective.
                    var slope = 0.0
                    for j in 0..<unb.n { slope += unb.c[j] * ray[j] }
                    let act = unb.a.multiply(ray)
                    var ok = slope < 0
                    let tol = 1e-7 * (1 + (ray.map { abs($0) }.max() ?? 0))
                    for j in 0..<unb.n where (ray[j] > tol && unb.xu[j] < .infinity) || (ray[j] < -tol && unb.xl[j] > -.infinity) { ok = false }
                    for i in 0..<unb.m where (act[i] > tol && unb.ru[i] < .infinity) || (act[i] < -tol && unb.rl[i] > -.infinity) { ok = false }
                    if ok { primalOK += 1 } else { primalBad += 1 }
                }
            }
            print("sense \(sense): statuses \(statuses.sorted { $0.key < $1.key })")
            print("    dual rays: certify as given \(farkasPos), certify only negated \(farkasNeg), missing \(noRay); primal rays ok \(primalOK), bad \(primalBad), missing \(noPrimal)")
        }
    }

    static func defaults() {
        let t = Tolerances.default
        print("Tolerances", t.primalFeasibility, t.dualFeasibility, t.pivot, t.harris, t.dropZero, t.integrality, t.mipRelativeGap, t.mipAbsoluteGap, t.ipmResidual)
        print("Gap", Gap().relative, Gap().absolute)
        let h = Heuristics.default
        print("Heuristics", h.rounding, h.diving, h.divingInterval, h.divingMaxDepth, h.divingIterationLimit, h.roundingBatch)
        print("Simplex.denseBasisLimit", Simplex.denseBasisLimit, "iterationCap(10,10)", Simplex().iterationCap(rows: 10, columns: 10), "iterationCap(1000,1000)", Simplex().iterationCap(rows: 1000, columns: 1000))
        print("Automatic", Automatic.interiorPointRows, Automatic.denseColumnRows, Automatic.denseColumnFraction)
        print("IndexedVector.sparseDensity", IndexedVector.sparseDensity, "sparseMultiplyThreshold", sparseMultiplyThreshold)
        print("RestartPolicy.lubyTerm 1..10", (1...10).map { RestartPolicy.lubyTerm($0) })
        print("BoundChange size/stride", MemoryLayout<BoundChange>.size, MemoryLayout<BoundChange>.stride)
        print("CompileOptions", CompileOptions().lowerSingletonConstraints, CompileOptions().dropTolerance)
        print("SolveContext.metal default", SolveContext().metal)
        print("InteriorPoint.Regularization", InteriorPoint.Regularization().primal, InteriorPoint.Regularization().dual)
        print("ConditioningAnalyzer.Options", ConditioningAnalyzer.Options().maxFindingsPerKind, ConditioningAnalyzer.Options().parallelRowThreshold)
        print("KernelThresholds", KernelThresholds.reducedCostScanColumns, KernelThresholds.reducedCostScanNonzeros, KernelThresholds.reducedCostCandidates, KernelThresholds.batchedActivityPoints, KernelThresholds.batchedActivityNonzeros, KernelThresholds.batchedActivityMaxBatch, KernelThresholds.disagreementFraction)
    }
}
