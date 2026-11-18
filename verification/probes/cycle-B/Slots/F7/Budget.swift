import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// budget: what L7MemoryBudgetTests.sixteenMegabytesIsEnoughAndIsRespected actually gets.
enum BudgetProbe {
    static func run() async throws {
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        for budget in [16 * 1024 * 1024, 64 * 1024 * 1024, 0] {
            var ctx = SolveContext()
            if budget > 0 { ctx.memoryBudgetBytes = budget }
            ctx.timeLimit = 60
            let t0 = Date()
            let an = try await BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound).solve(mip, context: ctx)
            print("budget \(budget == 0 ? "default" : String(budget)) -> \(an.status) objective \(an.objectiveValue ?? .nan) bound \(an.bound ?? .nan) nodes \(an.nodesProcessed) open \(an.nodesOpen) \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        }
    }
}
