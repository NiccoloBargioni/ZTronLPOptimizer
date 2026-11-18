import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Random orthogonal m x m matrix (column-major) by modified Gram-Schmidt on Gaussian columns.
func randomOrthogonal(_ m: Int, _ rng: inout Rng) -> [Double] {
    var q = (0..<(m * m)).map { _ in rng.gaussian() }
    for j in 0..<m {
        for _ in 0..<2 {
            for k in 0..<j {
                var dot = 0.0
                for i in 0..<m { dot += q[k * m + i] * q[j * m + i] }
                for i in 0..<m { q[j * m + i] -= dot * q[k * m + i] }
            }
        }
        var norm = 0.0
        for i in 0..<m { norm += q[j * m + i] * q[j * m + i] }
        norm = norm.squareRoot()
        for i in 0..<m { q[j * m + i] /= norm }
    }
    return q
}

/// U diag(sigma) V' with singular values spread geometrically from 1 to 1/kappa2.
func matrixWithCondition(_ m: Int, kappa2: Double, _ rng: inout Rng) -> [Double] {
    let u = randomOrthogonal(m, &rng)
    let v = randomOrthogonal(m, &rng)
    var sigma = [Double](repeating: 1, count: m)
    for k in 0..<m { sigma[k] = m == 1 ? 1 : pow(kappa2, -Double(k) / Double(m - 1)) }
    var a = [Double](repeating: 0, count: m * m)
    for j in 0..<m {
        for i in 0..<m {
            var s = 0.0
            for k in 0..<m { s += u[k * m + i] * sigma[k] * v[k * m + j] }
            a[j * m + i] = s
        }
    }
    return a
}

/// An LP whose constraint matrix is the given square matrix, with every row an equality.
func squareLP(_ a: [Double], _ m: Int) -> CompiledLP {
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<m { for i in 0..<m where a[j * m + i] != 0 { entries.append((i, j, a[j * m + i])) } }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: [Double](repeating: 1, count: m),
        xl: [Double](repeating: -.infinity, count: m), xu: [Double](repeating: .infinity, count: m),
        rl: [Double](repeating: 1, count: m), ru: [Double](repeating: 1, count: m))
}

func structuralBasis(_ m: Int) -> Basis {
    Basis(status: [BasisStatus](repeating: .basic, count: m) + [BasisStatus](repeating: .fixed, count: m), basic: (0..<m).map { Int32($0) })
}

func illFinding(_ r: ConditioningReport) -> String {
    for f in r.findings { if case .illConditionedBasis(let k) = f.kind { return "\(f.severity) kappa \(e(k))" } }
    return "none"
}

/// C7: the analyzer's condition estimate and thresholds. args: [seed]
func probeCondition(_ args: [String]) async throws {
    var rng = Rng(args.count > 0 ? UInt64(args[0])! : 99)
    var worstLow = 1.0, worstHigh = 1.0
    // 1. Square matrices with known conditioning, all-structural basis.
    for m in [3, 10, 40, 120] {
        for kappa2 in [1e1, 1e4, 1e8, 1e11, 1e14] {
            let a = matrixWithCondition(m, kappa2: kappa2, &rng)
            let lp = squareLP(a, m)
            let r = await ConditioningAnalyzer.analyze(lp, basis: structuralBasis(m))
            let exact = exactKappa1(a, m)
            let est = r.basisConditionEstimate ?? .nan
            let ratio = est / exact
            worstLow = min(worstLow, ratio); worstHigh = max(worstHigh, ratio)
            print("square m=\(m) kappa2=\(e(kappa2)): exact kappa1 \(e(exact)) estimate \(e(est)) ratio \(String(format: "%.3f", ratio)) outcome \(r.basisAnalysis) finding \(illFinding(r))")
        }
    }
    // 2. Mixed bases: half structural, half logical columns of a random LP.
    for m in [6, 30] {
        let a = matrixWithCondition(m, kappa2: 1e6, &rng)
        let lp = squareLP(a, m)
        var status = [BasisStatus](repeating: .atLower, count: 2 * m)
        var basic: [Int32] = []
        for k in 0..<m {
            if k % 2 == 0 { basic.append(Int32(k)) } else { basic.append(Int32(m + k)) }
        }
        for j in basic { status[Int(j)] = .basic }
        for j in 0..<m where status[j] != .basic { status[j] = .free }
        let basis = Basis(status: status, basic: basic)
        let r = await ConditioningAnalyzer.analyze(lp, basis: basis)
        let exact = exactKappa1(basisMatrix(lp, basis), m)
        print("mixed m=\(m): exact \(e(exact)) estimate \(e(r.basisConditionEstimate ?? .nan)) ratio \(String(format: "%.3f", (r.basisConditionEstimate ?? .nan) / exact)) \(r.basisAnalysis)")
    }
    // 3. Final bases of real solves (netlib), against the exact condition number.
    for name in ["afiro", "sc50a", "kb2", "adlittle", "blend", "share2b", "israel", "beaconfd"] {
        let lp = try NetlibFixtures.load(name)
        let s = try await Simplex(.dual).solve(lp, context: ctx())
        let r = await ConditioningAnalyzer.analyze(lp, after: s)
        let exact = exactKappa1(basisMatrix(lp, s.basis), lp.m)
        let ratio = (r.basisConditionEstimate ?? .nan) / exact
        worstLow = min(worstLow, ratio); worstHigh = max(worstHigh, ratio)
        print("netlib \(name) \(lp.m) rows: exact \(e(exact)) estimate \(e(r.basisConditionEstimate ?? .nan)) ratio \(String(format: "%.3f", ratio)) finding \(illFinding(r))")
    }
    print("estimate/exact ratio range over squares and netlib: [\(String(format: "%.3f", worstLow)), \(String(format: "%.3f", worstHigh))]")
    // 4. Thresholds on diagonal bases: kappa1 of diag(1, ..., 1/k) is k.
    for k in [1e8, 1.0000001e8, 1e12, 1.0000001e12, Double.infinity] {
        let m = 4
        var a = [Double](repeating: 0, count: m * m)
        for i in 0..<m { a[i * m + i] = 1 }
        a[(m - 1) * m + (m - 1)] = k.isInfinite ? 0 : 1 / k
        let lp = squareLP(a, m)
        let r = await ConditioningAnalyzer.analyze(lp, basis: structuralBasis(m))
        print("diagonal kappa \(e(k)): estimate \(e(r.basisConditionEstimate ?? .nan)) finding \(illFinding(r)) outcome \(r.basisAnalysis)")
    }
    // 5. Memory budget: 16 m^2 bytes.
    for m in [50, 200] {
        let a = matrixWithCondition(m, kappa2: 10, &rng)
        let lp = squareLP(a, m)
        for budget in [16 * m * m - 1, 16 * m * m, 0, -5] {
            var c = SolveContext()
            c.memoryBudgetBytes = budget
            let r = await ConditioningAnalyzer.analyze(lp, basis: structuralBasis(m), context: c)
            print("m=\(m) budget \(budget) (16m^2 = \(16 * m * m)): outcome \(r.basisAnalysis) estimate \(r.basisConditionEstimate.map { e($0) } ?? "nil")")
        }
    }
    // 6. Wide coefficient range thresholds: matrix with entries 1 and ratio r.
    for ratio in [1e6, 1.000001e6, 1e9, 1.000001e9] {
        let lp = denseLP(c: [1, 1], rows: [[1, ratio], [1, 1]], rl: [1, 1], ru: [inf, inf])
        let r = await ConditioningAnalyzer.analyze(lp)
        let wide = r.findings.filter { if case .wideCoefficientRange = $0.kind { return true }; return false }
        print("matrix ratio \(ratio): \(wide.map { "\($0.severity) \($0.message)" })")
    }
}
