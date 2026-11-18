// Shared helpers of the GPU-tier tests (specification §14.2, "Metal"): random problems, the
// fp64 CPU references the fp32 kernels are checked against, and the trait that skips a test
// cleanly on a machine without a usable Metal device.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPMetal

extension Trait where Self == ConditionTrait {
    /// Skips (does not fail) when the GPU tier is unavailable: no device, or the shaders could
    /// neither be loaded nor compiled.
    static var requiresMetal: Self {
        .enabled("the GPU tier is unavailable on this machine") {
            await MetalAccelerator.shared.isAvailable
        }
    }
}

/// One unit in the last place of a float around 1, as the shaders use it.
let singleEpsilon = 1.1920929e-7

enum MetalTestProblems {
    /// A random sparse problem with exactly `perColumn` entries in every column (`rows` must be
    /// at least `perColumn`), so the size thresholds can be hit exactly.
    static func sparse(rows m: Int, columns n: Int, perColumn: Int, seed: UInt64) -> CompiledLP {
        var rng = SeededGenerator(seed: seed)
        var colStart = [Int](repeating: 0, count: n + 1)
        var rowIndex: [Int32] = []
        var values: [Double] = []
        rowIndex.reserveCapacity(n * perColumn)
        values.reserveCapacity(n * perColumn)
        for j in 0..<n {
            // `perColumn` distinct rows starting at a random offset, ascending.
            let start = rng.integer(in: 0...(m - 1))
            var rows = (0..<perColumn).map { (start + $0 * Swift.max(1, m / perColumn)) % m }
            rows = Array(Set(rows)).sorted()
            var extra = 0
            while rows.count < perColumn {
                let candidate = (start + extra) % m
                if !rows.contains(candidate) {
                    rows.append(candidate)
                    rows.sort()
                }
                extra += 1
            }
            for i in rows {
                rowIndex.append(Int32(i))
                let magnitude = rng.uniform(in: 0.25...4)
                values.append(rng.chance(0.5) ? magnitude : -magnitude)
            }
            colStart[j + 1] = values.count
        }
        let a = SparseCSC(rows: Int32(m), cols: Int32(n), colStart: colStart, rowIndex: rowIndex, values: values)
        return CompiledLP(
            a: a, c: (0..<n).map { _ in rng.uniform(in: -10...10) },
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 10, count: n),
            rl: [Double](repeating: -.infinity, count: m), ru: [Double](repeating: .infinity, count: m))
    }

    /// The same problem with different row and column bounds.
    static func bounded(
        _ lp: CompiledLP, xl: [Double]? = nil, xu: [Double]? = nil, rl: [Double]? = nil, ru: [Double]? = nil
    ) -> CompiledLP {
        CompiledLP(
            a: lp.a, c: lp.c, c0: lp.c0, sense: lp.sense, xl: xl ?? lp.xl, xu: xu ?? lp.xu, rl: rl ?? lp.rl,
            ru: ru ?? lp.ru, integerColumns: lp.integerColumns, transpose: lp.aT)
    }

    /// Random inputs of a pricing scan.
    static func scanInputs(
        _ lp: CompiledLP, seed: UInt64
    ) -> (costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8]) {
        var rng = SeededGenerator(seed: seed)
        let duals = (0..<lp.m).map { _ in rng.uniform(in: -5...5) }
        let weights = (0..<lp.n).map { _ in rng.uniform(in: 1...50) }
        let eligibility = (0..<lp.n).map { _ in UInt8(rng.integer(in: 0...3)) }
        return (lp.c, duals, weights, eligibility)
    }
}

/// The fp64 CPU references of the two kernels.
enum DoubleReference {
    /// d_j = c_j − a_jᵀy and the magnitude Σ|a_ij y_i| + |c_j| that bounds its rounding error.
    static func reducedCost(_ lp: CompiledLP, column j: Int, costs: [Double], duals: [Double]) -> (d: Double, magnitude: Double) {
        var d = costs[j]
        var magnitude = Swift.abs(costs[j])
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            let term = lp.a.values[p] * duals[Int(lp.a.rowIndex[p])]
            d -= term
            magnitude += Swift.abs(term)
        }
        return (d, magnitude)
    }

    static func isAttractive(_ d: Double, code: UInt8) -> Bool {
        switch code {
        case PricingEligibility.increase: return d < 0
        case PricingEligibility.decrease: return d > 0
        case PricingEligibility.either: return d != 0
        default: return false
        }
    }

    /// The pricing score of every column in Double, with the bound on what single precision
    /// may differ by.
    static func scores(
        _ lp: CompiledLP, costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8]
    ) -> (score: [Double], bound: [Double]) {
        var score = [Double](repeating: 0, count: lp.n)
        var bound = [Double](repeating: 0, count: lp.n)
        for j in 0..<lp.n {
            let (d, magnitude) = reducedCost(lp, column: j, costs: costs, duals: duals)
            let root = weights[j].squareRoot()
            if isAttractive(d, code: eligibility[j]) { score[j] = Swift.abs(d) / root }
            let length = Double(lp.a.colStart[j + 1] - lp.a.colStart[j])
            // Rounded inputs and summation, then the division and square root.
            bound[j] = 2 * (length + 6) * singleEpsilon * magnitude / root + 4 * singleEpsilon * score[j] + 1e-30
        }
        return (score, bound)
    }

    /// The best `limit` columns by Double score, best first.
    static func topCandidates(_ score: [Double], limit: Int) -> [Int] {
        let positive = score.indices.filter { score[$0] > 0 }
        let sorted = positive.sorted { score[$0] > score[$1] || (score[$0] == score[$1] && $0 < $1) }
        return Array(sorted.prefix(limit))
    }

    /// Row activities of `count` points (`count × m`, point after point) and Σ|a_ij x_j| per entry.
    static func activities(_ lp: CompiledLP, points: [Double], count: Int) -> (activity: [Double], magnitude: [Double]) {
        var activity = [Double](repeating: 0, count: count * lp.m)
        var magnitude = [Double](repeating: 0, count: count * lp.m)
        for k in 0..<count {
            for j in 0..<lp.n {
                let x = points[k * lp.n + j]
                for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                    let i = Int(lp.a.rowIndex[p])
                    let term = lp.a.values[p] * x
                    activity[k * lp.m + i] += term
                    magnitude[k * lp.m + i] += Swift.abs(term)
                }
            }
        }
        return (activity, magnitude)
    }

    /// Whether point `k` satisfies every row and column bound within `tolerance`, in Double.
    static func isFeasible(_ lp: CompiledLP, points: [Double], point k: Int, tolerance: Double) -> Bool {
        let x = Array(points[(k * lp.n)..<((k + 1) * lp.n)])
        for j in 0..<lp.n where !(x[j] >= lp.xl[j] - tolerance && x[j] <= lp.xu[j] + tolerance) { return false }
        let activity = lp.a.multiply(x)
        for i in 0..<lp.m where !(activity[i] >= lp.rl[i] - tolerance && activity[i] <= lp.ru[i] + tolerance) {
            return false
        }
        return true
    }
}

/// A scan "kernel" that computes in Double on the CPU: what an honest kernel would return.
struct ReferenceScanner: ReducedCostScanning {
    let lp: CompiledLP

    func scan(costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int) async -> [Int32]? {
        let reference = DoubleReference.scores(lp, costs: costs, duals: duals, weights: weights, eligibility: eligibility)
        return DoubleReference.topCandidates(reference.score, limit: limit).map { Int32($0) }
    }
}

/// A scan "kernel" that lies: it returns eligible columns whose reduced cost has the wrong
/// sign, as a kernel with a broken shader or a corrupted buffer would.
struct LyingScanner: ReducedCostScanning {
    let lp: CompiledLP

    func scan(costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int) async -> [Int32]? {
        var wrong: [Int32] = []
        for j in 0..<lp.n where eligibility[j] != PricingEligibility.none {
            let d = DoubleReference.reducedCost(lp, column: j, costs: costs, duals: duals).d
            if !DoubleReference.isAttractive(d, code: eligibility[j]) { wrong.append(Int32(j)) }
            if wrong.count == limit { break }
        }
        return wrong
    }
}

/// What an engine does with a scan's candidates: recompute each reduced cost in Double, keep
/// the ones that really are attractive, and tell the guard how many were not (§6.4).
func verifyCandidates(
    _ candidates: [Int32], lp: CompiledLP, costs: [Double], duals: [Double], eligibility: [UInt8],
    guard disagreement: inout KernelDisagreementGuard
) -> (kept: [Int32], justDisabled: Bool) {
    var kept: [Int32] = []
    var wrong = 0
    for candidate in candidates {
        let j = Int(candidate)
        let d = DoubleReference.reducedCost(lp, column: j, costs: costs, duals: duals).d
        if DoubleReference.isAttractive(d, code: eligibility[j]) {
            kept.append(candidate)
        } else {
            wrong += 1
        }
    }
    let justDisabled = disagreement.record(candidates: candidates.count, disagreements: wrong)
    return (kept, justDisabled)
}
