import Testing
import ZTronLPCore
import ZTronLPNumerics
@testable import ZTronLPSimplex
import ZTronLPTestSupport

/// Builds a small problem from dense rows.
func denseLP(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double]? = nil, xu: [Double]? = nil,
    sense: ObjectiveSense = .minimize
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
        rl: rl, ru: ru)
}

let inf = Double.infinity

/// Checks a Farkas certificate: with z = Aᵀr, min rᵀs over the row bounds exceeds max zᵀx
/// over the column bounds (§14.1, oracle 4).
func farkasGap(_ lp: CompiledLP, _ r: [Double]) -> Double {
    var value = 0.0
    for i in 0..<lp.m where abs(r[i]) > 1e-9 {
        let bound = r[i] > 0 ? lp.rl[i] : lp.ru[i]
        if bound.isInfinite { return -.infinity }
        value += r[i] * bound
    }
    let z = lp.a.multiplyTranspose(r)
    for j in 0..<lp.n where abs(z[j]) > 1e-9 {
        let bound = z[j] > 0 ? lp.xu[j] : lp.xl[j]
        if bound.isInfinite { return -.infinity }
        value -= z[j] * bound
    }
    return value
}

/// Checks a primal ray: it stays within the bounds' recession directions and improves the
/// minimization objective.
func isImprovingRay(_ lp: CompiledLP, _ ray: [Double]) -> Bool {
    let tolerance = 1e-7 * (1 + (ray.map { abs($0) }.max() ?? 0))
    for j in 0..<lp.n {
        if ray[j] > tolerance && lp.xu[j] < .infinity { return false }
        if ray[j] < -tolerance && lp.xl[j] > -.infinity { return false }
    }
    let activity = lp.a.multiply(ray)
    for i in 0..<lp.m {
        if activity[i] > tolerance && lp.ru[i] < .infinity { return false }
        if activity[i] < -tolerance && lp.rl[i] > -.infinity { return false }
    }
    var slope = 0.0
    for j in 0..<lp.n { slope += lp.c[j] * ray[j] }
    return slope < -tolerance
}

let bothMethods: [Simplex.Method] = [.primal, .dual]

@Suite struct SimplexBasicsTests {
    @Test(arguments: bothMethods)
    func textbookProblem(_ method: Simplex.Method) async throws {
        // max 3x + 5y  s.t.  x ≤ 4, 2y ≤ 12, 3x + 2y ≤ 18  → (2, 6), value 36.
        let lp = denseLP(
            c: [3, 5], rows: [[1, 0], [0, 2], [3, 2]], rl: [-inf, -inf, -inf], ru: [4, 12, 18], sense: .maximize)
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - 36) < 1e-9)
            #expect(abs(analysis.primal![0] - 2) < 1e-9 && abs(analysis.primal![1] - 6) < 1e-9)
            #expect(analysis.bound == analysis.objectiveValue)
            // Shadow prices of the maximization: 0, 1.5, 1.
            let y = analysis.dual!
            #expect(abs(y[0]) < 1e-9 && abs(y[1] - 1.5) < 1e-9 && abs(y[2] - 1) < 1e-9)
            #expect(analysis.reducedCosts!.count == lp.n + lp.m)
        }
    }

    @Test(arguments: bothMethods)
    func infeasibleProblemCarriesADualRay(_ method: Simplex.Method) async throws {
        // x + y ≤ 1 and x + y ≥ 3 with x, y ≥ 0.
        let lp = denseLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 3], ru: [1, inf])
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp)
            #expect(analysis.status == .infeasible)
            #expect(analysis.objectiveValue == nil && analysis.primalRay == nil)
            let ray = try #require(analysis.dualRay)
            #expect(farkasGap(lp, ray) > 1e-9, "ray \(ray) does not certify infeasibility")
        }
    }

    @Test(arguments: bothMethods)
    func infeasibilityFoundByPresolveStillCarriesARay(_ method: Simplex.Method) async throws {
        // Two singleton rows that cross: 2x ≥ 8 and x ≤ 3 (as rows, not bounds).
        let lp = denseLP(c: [1, 0], rows: [[2, 0], [1, 0], [1, 1]], rl: [8, -inf, -inf], ru: [inf, 3, 10])
        let analysis = try await Simplex(method).solve(lp)
        #expect(analysis.status == .infeasible)
        let ray = try #require(analysis.dualRay)
        #expect(farkasGap(lp, ray) > 1e-9)
    }

    @Test(arguments: bothMethods)
    func unboundedProblemCarriesAPrimalRay(_ method: Simplex.Method) async throws {
        // min −x − y  s.t.  x − y ≤ 1,  −x + y ≤ 2.
        let lp = denseLP(c: [-1, -1], rows: [[1, -1], [-1, 1]], rl: [-inf, -inf], ru: [1, 2])
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp)
            #expect(analysis.status == .unbounded)
            let ray = try #require(analysis.primalRay)
            #expect(isImprovingRay(lp, ray), "ray \(ray)")
        }
    }

    @Test(arguments: bothMethods)
    func emptyColumnWithImprovingCostIsUnbounded(_ method: Simplex.Method) async throws {
        // z appears nowhere and improves forever; the rest is feasible.
        let lp = denseLP(c: [1, 1, -1], rows: [[1, 1, 0]], rl: [2], ru: [inf])
        let analysis = try await Simplex(method).solve(lp)
        #expect(analysis.status == .unbounded)
        #expect(isImprovingRay(lp, try #require(analysis.primalRay)))
        // … and infeasible when the rest is.
        let bad = denseLP(c: [1, 1, -1], rows: [[1, 1, 0], [1, 1, 0]], rl: [2, -inf], ru: [inf, 1])
        let second = try await Simplex(method).solve(bad)
        #expect(second.status == .infeasible)
    }

    @Test(arguments: bothMethods)
    func boundsRangesAndFreeColumns(_ method: Simplex.Method) async throws {
        // min x − 2y + z  with  −1 ≤ x ≤ 4, y free, 0 ≤ z ≤ 3;  2 ≤ x + y ≤ 6,  x − y = 1,  y + z ≥ −5.
        let lp = denseLP(
            c: [1, -2, 1], rows: [[1, 1, 0], [1, -1, 0], [0, 1, 1]], rl: [2, 1, -5], ru: [6, 1, inf],
            xl: [-1, -inf, 0], xu: [4, inf, 3])
        // x = y + 1, 2 ≤ 2y + 1 ≤ 6 → y ≤ 2.5, objective = (y + 1) − 2y = 1 − y → y = 2.5, x = 3.5.
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - (-1.5)) < 1e-9)
            #expect(abs(analysis.primal![0] - 3.5) < 1e-9 && abs(analysis.primal![1] - 2.5) < 1e-9)
        }
    }

    @Test(arguments: bothMethods)
    func problemWithoutRows(_ method: Simplex.Method) async throws {
        let lp = CompiledLP(
            a: SparseCSC(rows: 0, cols: 3), c: [1, -1, 0], xl: [2, 0, 0], xu: [5, 7, 1], rl: [], ru: [])
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - (2 - 7)) < 1e-12)
        }
    }

    @Test func integerColumnsAreRelaxedWithAWarning() async throws {
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 2), (0, 1, 2)]), c: [-1, -1],
            xl: [0, 0], xu: [1, 1], rl: [-inf], ru: [3], integerColumns: [0, 1])
        let analysis = try await Simplex(.dual).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - (-1.5)) < 1e-9)
        #expect(analysis.warnings.contains { $0.contains("relaxation") })
    }
}

@Suite struct SimplexTerminationTests {
    /// Klee–Minty cube, n = 10 (§14.2, rule L3): max Σ 2^(n−j) x_j with the classic constraints.
    static func kleeMinty(_ n: Int) -> CompiledLP {
        var rows: [[Double]] = []
        var ru: [Double] = []
        for i in 0..<n {
            var row = [Double](repeating: 0, count: n)
            for j in 0..<i { row[j] = pow2(i - j + 1) }
            row[i] = 1
            rows.append(row)
            ru.append(pow5(i + 1))
        }
        let c = (0..<n).map { pow2(n - 1 - $0) }
        return denseLP(c: c, rows: rows, rl: [Double](repeating: -inf, count: n), ru: ru, sense: .maximize)
    }

    static func pow2(_ k: Int) -> Double { Double(1 << k) }
    static func pow5(_ k: Int) -> Double { (0..<k).reduce(1.0) { value, _ in value * 5 } }

    @Test(arguments: bothMethods)
    func kleeMintyTerminates(_ method: Simplex.Method) async throws {
        let lp = Self.kleeMinty(10)
        for pricing in [Simplex.Pricing.dantzig, .devex, .steepestEdge] {
            let analysis = try await Simplex(method, pricing: pricing, presolve: false, scaling: .none).solve(lp)
            #expect(analysis.status == .optimal)
            // The optimum is x_n = 5^n, everything else 0.
            #expect(abs(analysis.objectiveValue! - Self.pow5(10)) < 1e-6 * Self.pow5(10))
            #expect(analysis.iterations <= 2_000)
        }
    }

    /// Beale's cycling example: Dantzig pricing with the textbook ratio rule cycles forever;
    /// the engine must terminate (§7.3, §14.2).
    @Test(arguments: bothMethods)
    func bealeCyclingExampleTerminates(_ method: Simplex.Method) async throws {
        let lp = denseLP(
            c: [-0.75, 150, -0.02, 6],
            rows: [[0.25, -60, -0.04, 9], [0.5, -90, -0.02, 3], [0, 0, 1, 0]],
            rl: [-inf, -inf, -inf], ru: [0, 0, 1])
        for pricing in [Simplex.Pricing.dantzig, .devex] {
            let analysis = try await Simplex(method, pricing: pricing, perturbation: .off, presolve: false, scaling: .none).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - (-0.05)) < 1e-9)
            #expect(analysis.iterations < 100)
        }
    }

    @Test(arguments: bothMethods)
    func iterationLimitIsAResult(_ method: Simplex.Method) async throws {
        let lp = try NetlibFixtures.load("share2b")
        let analysis = try await Simplex(method, maxIterations: 5).solve(lp)
        #expect(analysis.status.stopReason == .iterationLimit)
        #expect(analysis.iterations <= 5)
    }

    @Test(arguments: bothMethods)
    func degenerateInstanceTerminates(_ method: Simplex.Method) async throws {
        // degen2 is the anti-cycling instance of the specification's table.
        let lp = try NetlibFixtures.load("degen2")
        for perturbation in [Simplex.Perturbation.off, .always, .onStall] {
            let analysis = try await Simplex(method, perturbation: perturbation).solve(lp)
            #expect(analysis.status == .optimal, "\(perturbation): \(analysis.status)")
            let reference = ReferenceValues.netlib(named: "degen2")!.optimalObjective
            #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: reference) <= 1e-6)
            #expect(analysis.degeneracy > 0)
        }
    }
}

@Suite struct SimplexConstructedOptimaTests {
    /// Oracle 1 (§14.1): instances whose optimum is known by construction.
    @Test(arguments: bothMethods)
    func constructedOptima(_ method: Simplex.Method) async throws {
        let suite = InstanceGenerator.constructedSuite(count: 120, seed: method == .primal ? 101 : 202)
        for instance in suite {
            let analysis = try await Simplex(method).solve(instance.lp)
            #expect(analysis.status == .optimal, "seed \(instance.seed): \(analysis.status)")
            guard let objective = analysis.objectiveValue else { continue }
            let error = abs(objective - instance.objective) / max(1, abs(instance.objective))
            #expect(error <= 1e-7, "seed \(instance.seed): \(objective) vs \(instance.objective)")
            let violation = instance.lp.maxViolation(at: analysis.primal!)
            #expect(violation.bounds <= 1e-6 && violation.rows <= 1e-6)
        }
    }

    @Test func everyConfigurationAgreesOnConstructedOptima() async throws {
        let suite = InstanceGenerator.constructedSuite(count: 24, seed: 77, maxSize: (40, 80))
        let configurations: [Simplex] = [
            Simplex(.primal, pricing: .dantzig),
            Simplex(.primal, pricing: .steepestEdge),
            Simplex(.primal, pricing: .partial(sections: 4)),
            Simplex(.primal, factorization: .sparseQR),
            Simplex(.dual, factorization: .sparseQR),
            Simplex(.primal, perturbation: .always),
            Simplex(.dual, perturbation: .always),
            Simplex(.primal, presolve: false),
            Simplex(.dual, scaling: .equilibration),
            Simplex(.dual, scaling: .none),
        ]
        for instance in suite {
            for configuration in configurations {
                let analysis = try await configuration.solve(instance.lp)
                #expect(analysis.status == .optimal, "seed \(instance.seed), \(configuration)")
                guard let objective = analysis.objectiveValue else { continue }
                let error = abs(objective - instance.objective) / max(1, abs(instance.objective))
                #expect(error <= 1e-7, "seed \(instance.seed), \(configuration): \(objective) vs \(instance.objective)")
            }
        }
    }

    @Test func badlyScaledInstances() async throws {
        var options = ConstructedOptions()
        options.scaleSpread = 3
        options.rangeRows = true
        options.freeColumns = true
        for seed in 0..<20 {
            let instance = InstanceGenerator.constructedOptimum(rows: 30, columns: 45, seed: UInt64(900 + seed), options: options)
            for method in bothMethods {
                let analysis = try await Simplex(method).solve(instance.lp)
                #expect(analysis.status == .optimal, "seed \(seed) \(method)")
                guard let objective = analysis.objectiveValue else { continue }
                #expect(abs(objective - instance.objective) <= 1e-6 * max(1, abs(instance.objective)), "seed \(seed) \(method)")
            }
        }
    }
}
