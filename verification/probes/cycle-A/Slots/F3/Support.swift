// Probe helpers of cycle A, area F3 (interior point, crossover, conditioning).
// Everything here is computed independently of the package's own evaluation code.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let inf = Double.infinity

struct KKTReport: CustomStringConvertible {
    var primalViolation: Double      // absolute, bounds and rows
    var dualViolation: Double        // wrong-signed reduced cost or dual against an infinite bound
    var gap: Double                  // (primal - Lagrangian dual bound) / (1 + |primal|), internal min form
    var reducedCostMismatch: Double  // |reported d - recomputed d| max
    var description: String {
        String(format: "pviol %.2e dviol %.2e gap %.2e dmis %.2e", primalViolation, dualViolation, gap, reducedCostMismatch)
    }
}

/// Independent KKT check of (x, y) for min/max c'x s.t. rl <= Ax <= ru, xl <= x <= xu.
/// `y` and `d` are in the model's own sense, as SolutionAnalysis reports them.
func kkt(_ lp: CompiledLP, x: [Double], y yReported: [Double]?, d dReported: [Double]?) -> KKTReport {
    let n = lp.n, m = lp.m
    // Primal violation from scratch.
    var pviol = 0.0
    var activity = [Double](repeating: 0, count: m)
    for j in 0..<n {
        pviol = max(pviol, lp.xl[j] - x[j], x[j] - lp.xu[j])
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            activity[Int(lp.a.rowIndex[p])] += lp.a.values[p] * x[j]
        }
    }
    for i in 0..<m { pviol = max(pviol, lp.rl[i] - activity[i], activity[i] - lp.ru[i]) }
    guard let yReported, yReported.count == m else {
        return KKTReport(primalViolation: pviol, dualViolation: .nan, gap: .nan, reducedCostMismatch: .nan)
    }
    let flip: Double = lp.sense == .maximize ? -1 : 1
    let y = yReported.map { flip * $0 }
    var d = lp.c
    for j in 0..<n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { d[j] -= lp.a.values[p] * y[Int(lp.a.rowIndex[p])] }
    }
    var mismatch = 0.0
    if let dReported, dReported.count == n + m {
        for j in 0..<n { mismatch = max(mismatch, abs(flip * dReported[j] - d[j])) }
        for i in 0..<m { mismatch = max(mismatch, abs(flip * dReported[n + i] - y[i])) }
    }
    var dviol = 0.0
    var bound = lp.c0
    for j in 0..<n {
        let dj = d[j]
        if dj > 0 {
            if lp.xl[j].isFinite { bound += dj * lp.xl[j] } else { dviol = max(dviol, dj) }
        } else if dj < 0 {
            if lp.xu[j].isFinite { bound += dj * lp.xu[j] } else { dviol = max(dviol, -dj) }
        }
    }
    for i in 0..<m {
        let yi = y[i]
        if yi > 0 {
            if lp.rl[i].isFinite { bound += yi * lp.rl[i] } else { dviol = max(dviol, yi) }
        } else if yi < 0 {
            if lp.ru[i].isFinite { bound += yi * lp.ru[i] } else { dviol = max(dviol, -yi) }
        }
    }
    var primal = lp.c0
    for j in 0..<n { primal += lp.c[j] * x[j] }
    return KKTReport(primalViolation: pviol, dualViolation: dviol, gap: (primal - bound) / (1 + abs(primal)), reducedCostMismatch: mismatch)
}

func statusName(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infeasibleOrUnbounded"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure: return "numericalFailure"
    }
}

func ctx(_ seconds: Double = 60) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    return c
}

func relErr(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(1, abs(b)) }

func e(_ v: Double) -> String { String(format: "%.2e", v) }

/// Builds a CompiledLP from dense rows.
func denseLP(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double]? = nil, xu: [Double]? = nil,
    sense: ObjectiveSense = .minimize, integer: [Int32] = []
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, sense: sense,
        xl: xl ?? [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: .infinity, count: n),
        rl: rl, ru: ru, integerColumns: integer)
}

/// Exact 1-norm condition number of a dense column-major m x m matrix by Gauss-Jordan with
/// partial pivoting (independent of the package's LAPACK path). Returns .infinity when singular.
func exactKappa1(_ colMajor: [Double], _ m: Int) -> Double {
    // a[i][j]
    var a = [[Double]](repeating: [Double](repeating: 0, count: 2 * m), count: m)
    for i in 0..<m {
        for j in 0..<m { a[i][j] = colMajor[j * m + i] }
        a[i][m + i] = 1
    }
    var norm1 = 0.0
    for j in 0..<m {
        var s = 0.0
        for i in 0..<m { s += abs(colMajor[j * m + i]) }
        norm1 = max(norm1, s)
    }
    for k in 0..<m {
        var p = k
        for i in k..<m where abs(a[i][k]) > abs(a[p][k]) { p = i }
        if a[p][k] == 0 { return .infinity }
        if p != k { a.swapAt(p, k) }
        let pivot = a[k][k]
        for j in 0..<(2 * m) { a[k][j] /= pivot }
        for i in 0..<m where i != k {
            let f = a[i][k]
            if f == 0 { continue }
            for j in 0..<(2 * m) { a[i][j] -= f * a[k][j] }
        }
    }
    var inv1 = 0.0
    for j in 0..<m {
        var s = 0.0
        for i in 0..<m { s += abs(a[i][m + j]) }
        inv1 = max(inv1, s)
    }
    return norm1 * inv1
}

/// The dense basis matrix (columns `basic` of [A -I]), column-major.
func basisMatrix(_ lp: CompiledLP, _ basis: Basis) -> [Double] {
    let m = lp.m, n = lp.n
    var b = [Double](repeating: 0, count: m * m)
    for (k, col) in basis.basic.enumerated() {
        let j = Int(col)
        if j < n {
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { b[k * m + Int(lp.a.rowIndex[p])] = lp.a.values[p] }
        } else {
            b[k * m + (j - n)] = -1
        }
    }
    return b
}

/// A small deterministic RNG for the probe (SplitMix64).
struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
}
