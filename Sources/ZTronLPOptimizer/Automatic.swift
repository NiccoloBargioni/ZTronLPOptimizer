// The `Automatic` strategy (specification §11.2, §8, §8.3).

import ZTronLPBranchAndBound
import ZTronLPCore
import ZTronLPInteriorPoint
import ZTronLPMetal
import ZTronLPNumerics
import ZTronLPSimplex

/// Picks from the problem's shape: Simplex(.dual) when m ≤ 4,000, InteriorPoint(crossover:
/// .lite) above, BranchAndBound(engine: Simplex(.primal)) when integer columns exist. Returns
/// a type-erased analysis.
///
/// A model with dense columns and more than 10,000 rows goes to the sparse-QR simplex instead
/// of the interior point: a column with more than 30% nonzeros makes the normal equations
/// dense (§8.3).
///
/// Like every facade strategy, `Automatic` attaches the GPU tier to the run when
/// `context.metal` allows it and nothing is attached yet; the engines themselves never import
/// the Metal target (§3, §6.4).
public struct Automatic: SolverStrategy {
    /// What `Automatic` runs for a problem.
    public enum Choice: Sendable, Hashable {
        /// `BranchAndBound(engine: Simplex(.primal))`: the model has integer columns.
        case branchAndBound
        /// `Simplex(.dual)`: an LP with at most 4,000 rows.
        case dualSimplex
        /// `InteriorPoint(crossover: .lite)`: an LP with more than 4,000 rows.
        case interiorPoint
        /// `Simplex(.dual, factorization: .sparseQR)`: more than 10,000 rows and dense columns.
        case sparseSimplex
    }

    /// The row count above which an LP goes to the interior point.
    public static let interiorPointRows = 4_000
    /// The row count above which dense columns route an LP to the sparse-QR simplex.
    public static let denseColumnRows = 10_000
    /// A column is dense when more than this fraction of the rows have an entry in it.
    public static let denseColumnFraction = 0.3

    public init() {}

    public var engineName: String { "Automatic" }

    /// The engine `Automatic` selects for `problem`.
    public static func choice(for problem: CompiledLP) -> Choice {
        if problem.hasIntegerColumns { return .branchAndBound }
        if problem.m <= interiorPointRows { return .dualSimplex }
        if problem.m > denseColumnRows && hasDenseColumn(problem) { return .sparseSimplex }
        return .interiorPoint
    }

    /// Whether any column has more than 30% nonzeros.
    public static func hasDenseColumn(_ problem: CompiledLP) -> Bool {
        let limit = denseColumnFraction * Double(problem.m)
        for j in 0..<problem.n where Double(problem.a.colStart[j + 1] - problem.a.colStart[j]) > limit {
            return true
        }
        return false
    }

    public func solve(_ problem: CompiledLP, context: SolveContext) async throws -> AnySolutionAnalysis {
        let context = context.attachingMetal()
        switch Self.choice(for: problem) {
        case .branchAndBound:
            let strategy = BranchAndBound(engine: Simplex(.primal))
            return AnySolutionAnalysis(try await strategy.solve(problem, context: context), engine: strategy.engineName)
        case .dualSimplex:
            let strategy = Simplex(.dual)
            return AnySolutionAnalysis(try await strategy.solve(problem, context: context), engine: strategy.engineName)
        case .interiorPoint:
            let strategy = InteriorPoint(crossover: .lite)
            return AnySolutionAnalysis(try await strategy.solve(problem, context: context), engine: strategy.engineName)
        case .sparseSimplex:
            let strategy = Simplex(.dual, factorization: .sparseQR)
            return AnySolutionAnalysis(try await strategy.solve(problem, context: context), engine: strategy.engineName)
        }
    }
}
