import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

@Suite struct PortfolioWithCPSATTests {
    @Test func aStrategyThatCannotRunDoesNotWin() async throws {
        // CP-SAT rejects a model with continuous columns; the simplex concludes.
        let lp = try NetlibFixtures.load("afiro")
        let analysis = try await Portfolio([CPSAT(), Simplex(.dual)]).solve(lp)
        #expect(analysis.status == .optimal && analysis.winner == "Simplex(.dual)")
        #expect(analysis.others.count == 1)
        if case .numericalFailure(let message) = analysis.others[0].status {
            #expect(message.contains("unsupported"))
        } else {
            Issue.record("the rejected strategy was reported as \(analysis.others[0].status)")
        }
        // When every strategy rejects the model, the portfolio throws what the first one threw.
        await #expect(throws: SolverError.self) {
            _ = try await Portfolio([CPSAT(), CPSAT(workers: 1)]).solve(lp)
        }
        await #expect(throws: SolverError.self) {
            _ = try await Portfolio([]).solve(lp)
        }
    }

    @Test func mixedIntegerPortfolio() async throws {
        let mip = InstanceGenerator.randomMILP(rows: 6, columns: 20, seed: 12)
        let analysis = try await Portfolio([
            BranchAndBound(), BranchAndBound(engine: Simplex(.dual)), CPSAT(),
        ]).solve(mip)
        #expect(analysis.status == .optimal)
        let single = try await BranchAndBound(engine: Simplex(.dual)).solve(mip)
        #expect(abs(analysis.objectiveValue! - single.objectiveValue!) <= 1e-6 * max(1, abs(single.objectiveValue!)))
    }
}
