import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Random ill-conditioned equality LPs with the unique solution x = 1: A = L·D·U with unit
/// triangular L, U and a geometric diagonal D spanning 10^-k. Checks: no wrong objective
/// under .optimal, and a far-off optimal answer carries a warning.
func illInstance(_ k: Int) -> (lp: CompiledLP, objective: Double, n: Int, decades: Double, A: [[Double]], b: [Double]) {
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
    return (lp, c.reduce(0, +), n, decades, A, b)
}

/// One instance of the family in detail.
func runIllOne(_ k: Int) async {
    let (lp, objective, n, decades, A, b) = illInstance(k)
    var dm = DenseMatrix(rows: n, cols: n)
    for i in 0..<n { for j in 0..<n { dm.storage[j * n + i] = A[i][j] } }
    let kappa = (try? DenseLU(dm))?.conditionEstimate() ?? .infinity
    let ones = [Double](repeating: 1, count: n)
    let v1 = lp.maxViolation(at: ones)
    let xs = denseSolve(dm, b) ?? []
    print("instance k\(k): n \(n), D spans 1e-\(decades), kappa1 \(fmt(kappa)); x = 1 violates rows by \(fmt(v1.rows)), bounds by \(fmt(v1.bounds)); dense solve distance from 1: \(fmt(xs.map { abs($0 - 1) }.max() ?? .nan)); optimum \(objective)")
    for (name, s) in [("Simplex(.primal)", Simplex(.primal) as any SolverStrategy), ("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal, presolve: false, scaling: .none)", Simplex(.primal, presolve: false, scaling: .none)), ("InteriorPoint()", InteriorPoint()), ("Automatic()", Automatic())] {
        let an = try! await s.solve(lp, context: ctx())
        let ray = (an as? SimplexAnalysis)?.dualRay
        let margin = ray.map { farkasMargin(lp, $0) }
        let dist = an.primal.map { $0.map { abs($0 - 1) }.max() ?? 0 }
        print("  \(name): \(an.status) obj \(an.objectiveValue.map { "\($0)" } ?? "nil") dist \(dist.map(fmt) ?? "-") farkas margin \(margin.map { "\($0)" } ?? "-") warnings \(an.warnings)")
    }
}

func runIllRandom() async {
    let configs = configGrid(full: false)
    var bucketObj: [String: (count: Int, wrong: Int, worst: Double)] = [:]
    var far = 0, farUnwarned: [String] = [], wrongObj: [String] = [], verdicts: [String: Int] = [:]
    for k in 0..<24 {
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
        // make c positive-ish combination so x = 1 is the vertex: c = Aᵀ·1 + small positive reduced costs is not possible
        // for an equality system with unique solution; any c works. Use c = Aᵀ1 + 1 to avoid an all-zero objective.
        for j in 0..<n { c[j] += 1 }
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: n, cols: n, entries), c: c, xl: [Double](repeating: -10, count: n),
                            xu: [Double](repeating: 10, count: n), rl: b, ru: b)
        var obj = 0.0
        for j in 0..<n { obj += c[j] }
        var dm = DenseMatrix(rows: n, cols: n)
        for i in 0..<n { for j in 0..<n { dm.storage[j * n + i] = A[i][j] } }
        let kappa = (try? DenseLU(dm))?.conditionEstimate() ?? .infinity
        let bucket = kappa < 1e8 ? "k<1e8" : (kappa < 1e10 ? "1e8-1e10" : (kappa < 1e12 ? "1e10-1e12" : (kappa < 1e14 ? "1e12-1e14" : ">1e14")))
        for cfg in configs {
            let an = try! await cfg.s.solve(lp, context: ctx())
            verdicts["\(bucket) \(an.status)".components(separatedBy: "(").first! + (an.status.stopReason.map { "(\($0))" } ?? ""), default: 0] += 1
            if an.status == .infeasible, let ray = an.dualRay { let mg = farkasMargin(lp, ray); if bucket == "k<1e8" || bucket == "1e8-1e10" { wrongObj.append("FALSE-INFEASIBLE k\(k) kappa \(fmt(kappa)) \(cfg.name) margin \(mg) warnings \(an.warnings)") } }
            guard an.status == .optimal, let x = an.primal else { continue }
            let dist = x.map { abs($0 - 1) }.max() ?? 0
            let oerr = abs((an.objectiveValue ?? .nan) - obj) / max(1, abs(obj))
            let v = lp.maxViolation(at: x)
            let bo = bucketObj[bucket] ?? (0, 0, 0)
            bucketObj[bucket] = (bo.count + 1, bo.wrong + (oerr > 1e-6 ? 1 : 0), max(bo.worst, oerr))
            if dist > 1e-3 {
                far += 1
                if an.warnings.isEmpty { farUnwarned.append("k\(k) n\(n) 1e-\(decades) \(cfg.name): dist \(fmt(dist)) objErr \(fmt(oerr)) viol \(fmt(max(v.bounds, v.rows)))") }
            }
            if oerr > 1e-6 || max(v.bounds, v.rows) > 1e-6 { wrongObj.append("\(bucket) kappa \(fmt(kappa)) k\(k) n\(n) 1e-\(decades) \(cfg.name): objErr \(fmt(oerr)) viol \(fmt(max(v.bounds, v.rows))) dist \(fmt(dist)) warnings \(an.warnings.count)") }
        }
    }
    print("verdicts \(verdicts); far-off optimal answers \(far), unwarned \(farUnwarned.count), wrong objective/infeasible optimal \(wrongObj.count)")
    for s in farUnwarned.prefix(10) { print("UNWARNED", s) }
    for (k, v) in bucketObj.sorted(by: { $0.key < $1.key }) { print("BUCKET \(k): optimal \(v.count), objective off by > 1e-6: \(v.wrong), worst \(fmt(v.worst))") }
    for s in wrongObj.filter({ $0.hasPrefix("FALSE") }).prefix(30) { print(s) }
    for s in wrongObj.filter({ $0.hasPrefix("1e8") || $0.hasPrefix("k<") }).prefix(10) { print("WRONG-LOW-KAPPA", s) }
}
