// Helpers of the conditioning tests: small problems written out row by row, and analyses that
// stand in for an engine's result.

import ZTronLPCore
import ZTronLPNumerics

@testable import ZTronLPConditioning

enum ConditioningProblems {
    /// A problem from dense rows. Defaults: zero costs, columns in [0, ∞), rows unbounded on
    /// both sides.
    static func make(
        rows: [[Double]], c: [Double]? = nil, xl: [Double]? = nil, xu: [Double]? = nil, rl: [Double]? = nil,
        ru: [Double]? = nil, integer: [Int] = [], columns: Int? = nil
    ) -> CompiledLP {
        let m = rows.count
        let n = columns ?? rows.first?.count ?? 0
        var entries: [(row: Int, col: Int, value: Double)] = []
        for (i, row) in rows.enumerated() {
            precondition(row.count == n, "every row needs \(n) entries")
            for (j, value) in row.enumerated() where value != 0 { entries.append((i, j, value)) }
        }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: c ?? [Double](repeating: 0, count: n),
            xl: xl ?? [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: .infinity, count: n),
            rl: rl ?? [Double](repeating: -.infinity, count: m), ru: ru ?? [Double](repeating: .infinity, count: m),
            integerColumns: integer.sorted().map { Int32($0) })
    }

    /// `A = diag(d)`: a square problem whose all-structural basis has κ₁ = max|d| / min|d|.
    static func diagonal(_ d: [Double]) -> CompiledLP {
        let n = d.count
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { rows[i][i] = d[i] }
        return make(rows: rows)
    }

    /// The basis whose basic columns are the structural columns `0..<m` of a square problem.
    static func structuralBasis(_ lp: CompiledLP) -> Basis {
        precondition(lp.m == lp.n, "needs a square problem")
        var status = [BasisStatus](repeating: .basic, count: lp.n + lp.m)
        for i in 0..<lp.m { status[lp.n + i] = .atLower }
        return Basis(status: status, basic: (0..<lp.m).map { Int32($0) })
    }
}

/// An analysis with a basis, as a simplex engine returns one.
struct BasisCarryingAnalysis: AnalysisDecorator, BasisProviding {
    let base: SolveRecord
    let basis: Basis?
    var finalBasis: Basis? { basis }
}

/// An analysis without a basis, as CP-SAT returns one.
struct PlainAnalysis: AnalysisDecorator {
    let base: SolveRecord
}

extension ConditioningReport {
    /// The kinds of the findings, in report order.
    var kinds: [Finding.Kind] { findings.map(\.kind) }

    func first(where predicate: (Finding.Kind) -> Bool) -> Finding? {
        findings.first { predicate($0.kind) }
    }
}
