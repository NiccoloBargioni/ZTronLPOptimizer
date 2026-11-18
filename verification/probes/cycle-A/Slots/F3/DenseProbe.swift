import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Adds a column with `fraction` of the rows filled to a constructed instance, with a cost that
/// keeps it at zero with reduced cost `dcost` (> 0), so the optimum does not change.
func withDenseColumn(_ inst: ConstructedInstance, fraction: Double, count: Int = 1, dcost: Double = 1, seed: UInt64 = 1) -> CompiledLP {
    let lp = inst.lp
    var rng = Rng(seed)
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
    }
    var c = lp.c
    var xl = lp.xl, xu = lp.xu
    let flip: Double = lp.sense == .maximize ? -1 : 1
    for k in 0..<count {
        let target = Int((fraction * Double(lp.m)).rounded(.down))
        var rows = Array(0..<lp.m)
        for i in stride(from: rows.count - 1, to: 0, by: -1) { rows.swapAt(i, rng.int(0, i)) }
        var cost = 0.0
        for i in rows.prefix(target) {
            let v = rng.uniform(0.5, 2) * (rng.uniform() < 0.5 ? -1 : 1)
            entries.append((i, lp.n + k, v))
            // c = A'y + d in the minimization form; inst.dual is in the minimization form.
            cost += v * inst.dual[i]
        }
        c.append(cost + dcost)
        xl.append(0); xu.append(.infinity)
        _ = flip
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: lp.m, cols: lp.n + count, entries), c: c, sense: lp.sense, xl: xl, xu: xu,
        rl: lp.rl, ru: lp.ru)
}

/// C6: dense columns. args: [rows cols]
func probeDense(_ args: [String]) async throws {
    let m = args.count > 0 ? Int(args[0])! : 400
    let n = args.count > 1 ? Int(args[1])! : 700
    var options = ConstructedOptions()
    options.density = 4.0 / Double(m)
    let inst = InstanceGenerator.constructedOptimum(rows: m, columns: n, seed: 2024, options: options)
    let plainStart = Date()
    let plain = try await InteriorPoint().solve(inst.lp, context: ctx())
    print("no dense column: \(statusName(plain.status)) obj err \(e(relErr(plain.objectiveValue ?? .nan, inst.objective))) it \(plain.iterations) \(String(format: "%.3f", Date().timeIntervalSince(plainStart))) s warnings \(plain.warnings)")
    for (fraction, count) in [(0.29, 1), (0.30, 1), (0.31, 1), (0.35, 3), (0.9, 2)] {
        let lp = withDenseColumn(inst, fraction: fraction, count: count)
        let nnzLast = lp.a.colStart[lp.n] - lp.a.colStart[lp.n - 1]
        let simplex = try await Simplex(.dual).solve(lp, context: ctx())
        for (name, strategy) in ipmConfigs {
            let t = Date()
            let a = try await strategy.solve(lp, context: ctx())
            let secs = Date().timeIntervalSince(t)
            let warn = a.warnings.filter { $0.contains("30%") }
            let kk = a.primal.map { kkt(lp, x: $0, y: a.dual, d: a.reducedCosts) }
            print("fraction \(fraction) x\(count) (last column \(nnzLast) of \(m) rows) \(name): \(statusName(a.status)) obj err \(e(relErr(a.objectiveValue ?? .nan, inst.objective))) vs simplex \(e(relErr(a.objectiveValue ?? .nan, simplex.objectiveValue ?? .nan))) it \(a.iterations) \(String(format: "%.3f", secs)) s dense-warning: \(warn.isEmpty ? "NONE" : warn[0]) kkt \(kk.map { "\($0)" } ?? "-")")
        }
        let report = await ConditioningAnalyzer.analyze(lp)
        let dense = report.findings.filter { if case .denseColumn = $0.kind { return true }; return false }
        print("   analyzer dense findings: \(dense.map { "\($0.severity) \($0.message)" })")
    }
    // Tiny problem: 3 rows, a full column. README: a column over 30% makes the normal equations dense, a warning says so.
    let tiny = denseLP(c: [1, 1, 1, 1], rows: [[1, 1, 0, 0], [1, 0, 1, 0], [1, 0, 0, 1]], rl: [1, 1, 1], ru: [inf, inf, inf])
    for (name, strategy) in ipmConfigs {
        let a = try await strategy.solve(tiny, context: ctx())
        print("3-row model, column 0 in 100% of rows, \(name): \(statusName(a.status)) obj \(a.objectiveValue ?? .nan) warnings \(a.warnings)")
    }
    let four = denseLP(c: [1, 1, 1, 1, 1], rows: [[1, 1, 0, 0, 0], [1, 0, 1, 0, 0], [1, 0, 0, 1, 0], [1, 0, 0, 0, 1]], rl: [1, 1, 1, 1], ru: [inf, inf, inf, inf])
    let a4 = try await InteriorPoint(presolve: false).solve(four, context: ctx())
    print("4-row model, column 0 in 100% of rows, lite/nopre: \(statusName(a4.status)) obj \(a4.objectiveValue ?? .nan) warnings \(a4.warnings)")
}
