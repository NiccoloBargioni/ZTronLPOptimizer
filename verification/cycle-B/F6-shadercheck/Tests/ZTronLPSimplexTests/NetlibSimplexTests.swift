import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport

/// Day-2 and day-3 gates (§15): every netlib instance optimal to 1e-6 with the primal and the
/// dual method, and the two agree.
@Suite struct NetlibSimplexTests {
    static let configurations: [(String, Simplex)] = [
        ("primal", Simplex(.primal)),
        ("dual", Simplex(.dual)),
        ("primal, no presolve, no scaling", Simplex(.primal, presolve: false, scaling: .none)),
        ("dual, no presolve, no scaling", Simplex(.dual, presolve: false, scaling: .none)),
    ]

    @Test(arguments: ReferenceValues.netlib)
    func primalReachesThePublishedOptimum(_ instance: ReferenceInstance) async throws {
        try await check(instance, Simplex(.primal))
    }

    @Test(arguments: ReferenceValues.netlib)
    func dualReachesThePublishedOptimum(_ instance: ReferenceInstance) async throws {
        try await check(instance, Simplex(.dual))
    }

    @Test(arguments: ReferenceValues.netlib)
    func primalWithoutPresolveOrScaling(_ instance: ReferenceInstance) async throws {
        try await check(instance, Simplex(.primal, presolve: false, scaling: .none))
    }

    @Test(arguments: ReferenceValues.netlib)
    func dualWithoutPresolveOrScaling(_ instance: ReferenceInstance) async throws {
        try await check(instance, Simplex(.dual, presolve: false, scaling: .none))
    }

    private func check(_ instance: ReferenceInstance, _ strategy: Simplex) async throws {
        let lp = try NetlibFixtures.load(instance.name)
        let analysis = try await strategy.solve(lp)
        #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status)")
        let objective = try #require(analysis.objectiveValue)
        let error = ReferenceValues.relativeError(objective, reference: instance.optimalObjective)
        #expect(error <= ReferenceValues.relativeTolerance, "\(instance.name): \(objective) vs \(instance.optimalObjective)")
        // The reported point must be feasible for the problem as given, and the duals optimal.
        let x = try #require(analysis.primal)
        let violation = lp.maxViolation(at: x)
        #expect(violation.bounds <= 1e-6 && violation.rows <= 1e-6, "\(instance.name): violation \(violation)")
        let y = try #require(analysis.dual)
        let d = lp.reducedCosts(forDuals: y)
        var worst = 0.0
        for j in 0..<lp.n {
            if x[j] > lp.xl[j] + 1e-6 * (1 + abs(x[j])) { worst = max(worst, d[j]) }
            if x[j] < lp.xu[j] - 1e-6 * (1 + abs(x[j])) { worst = max(worst, -d[j]) }
        }
        #expect(worst <= 1e-5 * (1 + abs(objective)), "\(instance.name): dual infeasibility \(worst)")
        #expect(analysis.basis.basic.count == lp.m)
    }
}
