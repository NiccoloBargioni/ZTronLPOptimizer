// Optimization by linear search (specification §10.2), checked against exhaustive
// enumeration: both senses, negative coefficients, general integers and not just binaries,
// equality and range rows, data that needs the per-row scaling by powers of 10. The
// enumeration tests run both ways — as CP-SAT runs by default, with the LP propagator, and
// with `lpPropagator: false`, the subset of §10.2 on its own; the rest run the default.

import Testing
import ZTronLPCore
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

/// The variables of the DSL test: one binary per item.
private enum Item: LPVariable {
    case take(Int)
    var domain: VariableDomain { .binary }
}

@Suite struct OptimizationTests {
    /// Compares a solve with the brute-force reference. Returns false on a mismatch.
    private func agrees(_ analysis: CPSATAnalysis, with reference: BruteForceResult, on lp: CompiledLP, _ label: String) -> Bool {
        guard let expected = reference.objective else {
            if analysis.status != .infeasible {
                Issue.record("\(label): expected infeasible, got \(analysis.status)")
                return false
            }
            return analysis.primal == nil && analysis.objectiveValue == nil && analysis.bound == nil
        }
        guard analysis.status == .optimal, let objective = analysis.objectiveValue, let primal = analysis.primal else {
            Issue.record("\(label): expected optimal \(expected), got \(analysis.status)")
            return false
        }
        if abs(objective - expected) > 1e-9 * max(1, abs(expected)) {
            Issue.record("\(label): expected \(expected), got \(objective)")
            return false
        }
        // The returned point is integral, feasible and has the reported value.
        let violation = lp.maxViolation(at: primal)
        if violation.bounds > 1e-9 || violation.rows > 1e-9 || primal.contains(where: { $0 != $0.rounded() }) {
            Issue.record("\(label): the returned point is not a feasible integer point")
            return false
        }
        if abs(lp.objective(at: primal) - objective) > 1e-9 * max(1, abs(objective)) {
            Issue.record("\(label): the returned point does not have the reported objective")
            return false
        }
        if analysis.bound != objective {
            Issue.record("\(label): bound \(String(describing: analysis.bound)) differs from the optimal objective \(objective)")
            return false
        }
        return true
    }

    @Test func randomProgramsMatchExhaustiveSearch() async throws {
        var failures = 0
        var optimal = 0
        var infeasible = 0
        for seed in 0..<500 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 3 + Int(seed % 4)
            options.rows = 2 + Int(seed % 5)
            options.fractional = seed % 3 == 0
            options.maximize = seed % 2 == 1
            let lp = randomIntegerProgram(seed: seed, options: options)
            let reference = bruteForce(lp)
            if reference.objective == nil { infeasible += 1 } else { optimal += 1 }
            // As CP-SAT runs by default, and the subset of §10.2 on its own.
            for lpPropagator in [true, false] {
                let analysis = try await CPSAT(lpPropagator: lpPropagator, deterministic: true).solve(lp)
                if !agrees(analysis, with: reference, on: lp, "seed \(seed), LP propagator \(lpPropagator)") { failures += 1 }
            }
            if failures > 5 { break }
        }
        #expect(failures == 0)
        // The generator has to produce both kinds for the test to mean anything.
        #expect(optimal > 100 && infeasible > 20)
    }

    @Test func binaryProgramsMatchExhaustiveSearch() async throws {
        var failures = 0
        for seed in 0..<120 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 8 + Int(seed % 5)
            options.rows = 3 + Int(seed % 6)
            options.generalIntegers = false
            options.maximize = seed % 2 == 0
            options.fractional = seed % 4 == 3
            let lp = randomIntegerProgram(seed: 10_000 + seed, options: options)
            let reference = bruteForce(lp)
            for lpPropagator in [true, false] {
                let analysis = try await CPSAT(lpPropagator: lpPropagator, deterministic: true).solve(lp)
                if !agrees(analysis, with: reference, on: lp, "seed \(seed), LP propagator \(lpPropagator)") { failures += 1 }
            }
            if failures > 5 { break }
        }
        #expect(failures == 0)
    }

    /// The portfolio — several strategies, shared incumbent, exchanged clauses — reaches the
    /// same optimum as enumeration.
    @Test func portfolioMatchesExhaustiveSearch() async throws {
        var failures = 0
        for seed in 0..<150 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 4 + Int(seed % 3)
            options.rows = 3 + Int(seed % 4)
            options.fractional = seed % 5 == 0
            options.maximize = seed % 2 == 1
            let lp = randomIntegerProgram(seed: 20_000 + seed, options: options)
            let reference = bruteForce(lp)
            for lpPropagator in [true, false] {
                let analysis = try await CPSAT(workers: 2 + Int(seed % 4), lpPropagator: lpPropagator, seed: seed).solve(lp)
                if !agrees(analysis, with: reference, on: lp, "seed \(seed), LP propagator \(lpPropagator)") { failures += 1 }
            }
            if failures > 5 { break }
        }
        #expect(failures == 0)
    }

    /// Larger multi-row knapsacks: too big to enumerate, so the portfolio and the single
    /// worker, which search differently, are checked against each other.
    @Test func knapsacksAgreeAcrossConfigurations() async throws {
        for seed in 0..<8 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 5, columns: 24, seed: seed)
            let single = try await CPSAT(deterministic: true).solve(lp)
            let portfolio = try await CPSAT(workers: 4, clauseSharing: true).solve(lp)
            let unshared = try await CPSAT(workers: 3, restarts: .geometric(first: 64, factor: 1.3), clauseSharing: false, seed: 5).solve(lp)
            #expect(single.status == .optimal && portfolio.status == .optimal && unshared.status == .optimal)
            #expect(single.objectiveValue == portfolio.objectiveValue)
            #expect(single.objectiveValue == unshared.objectiveValue)
            for analysis in [single, portfolio, unshared] {
                let primal = try #require(analysis.primal)
                let violation = lp.maxViolation(at: primal)
                #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
            }
        }
    }

    /// The typed convenience: compile a DSL model, solve it, read the result by variable.
    @Test func knapsackFromTheDSL() async throws {
        let weights: [Double] = [12, 7, 11, 8, 9, 6, 14, 5, 10, 4, 13, 3]
        let values: [Double] = [24, 13, 23, 15, 16, 11, 28, 9, 20, 7, 26, 5]
        let n = weights.count
        let model = LPModel<Item>()
            .maximizing(sum(over: 0..<n) { values[$0] * Item.take($0) })
            .subjectTo(sum(over: 0..<n) { weights[$0] * Item.take($0) } <= 40)
            .subjectTo((Item.take(0) + Item.take(6) <= 1).named("exclusive"))
        let solution = try await CPSAT(workers: 2).solve(model)
        #expect(solution.status.isOptimal)
        let reference = bruteForce(try model.compile().lp)
        #expect(solution.objectiveValue == reference.objective)
        var weight = 0.0
        var value = 0.0
        for i in 0..<n where solution.value(of: .take(i)) > 0.5 {
            weight += weights[i]
            value += values[i]
        }
        #expect(weight <= 40)
        #expect(value == solution.objectiveValue)
        #expect(solution.value(of: .take(0)) + solution.value(of: .take(6)) <= 1)
        // A MIP result has no duals.
        #expect(solution.dual(ofConstraintNamed: "exclusive") == nil)
    }

    /// Equality and range rows over general integers, with a known answer.
    @Test func equalityAndRangeRows() async throws {
        // minimize 3x − 2y + z   s.t.  x + y + z = 7,  1 ≤ x − y ≤ 3,  x, y ∈ [−2, 6], z ∈ [0, 4]
        let a = SparseCSC.fromTriplets(rows: 2, cols: 3, [(0, 0, 1), (0, 1, 1), (0, 2, 1), (1, 0, 1), (1, 1, -1)])
        let lp = CompiledLP(
            a: a, c: [3, -2, 1], xl: [-2, -2, 0], xu: [6, 6, 4], rl: [7, 1], ru: [7, 3], integerColumns: [0, 1, 2])
        let reference = bruteForce(lp)
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == reference.objective)
        let x = try #require(analysis.primal)
        #expect(x[0] + x[1] + x[2] == 7)
        #expect(x[0] - x[1] >= 1 && x[0] - x[1] <= 3)
    }

    @Test func infeasibleModelsAreProvenInfeasible() async throws {
        // Three binaries cannot sum to at least 4.
        let a = SparseCSC.fromTriplets(rows: 1, cols: 3, [(0, 0, 1), (0, 1, 1), (0, 2, 1)])
        let impossible = CompiledLP(
            a: a, c: [1, 1, 1], xl: [0, 0, 0], xu: [1, 1, 1], rl: [4], ru: [.infinity], integerColumns: [0, 1, 2])
        let first = try await CPSAT(deterministic: true).solve(impossible)
        #expect(first.status == .infeasible)
        #expect(first.primal == nil && first.objectiveValue == nil && first.bound == nil)

        // Parity: 2x + 2y = 3 has no integer solution although its relaxation does.
        let b = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 2), (0, 1, 2)])
        let parity = CompiledLP(a: b, c: [1, 0], xl: [0, 0], xu: [5, 5], rl: [3], ru: [3], integerColumns: [0, 1])
        #expect(try await CPSAT(workers: 3).solve(parity).status == .infeasible)

        // The pigeonhole principle, small enough to refute.
        let pigeons = try await CPSAT(workers: 2).solve(pigeonhole(holes: 5))
        #expect(pigeons.status == .infeasible)
        #expect(pigeons.conflicts > 0)
    }

    /// Reported values are in the model's own sense and include the objective constant.
    @Test func maximizationAndTheObjectiveConstantAreReportedInTheModelsSense() async throws {
        // maximize 4x + 3y + 10   s.t.  2x + y ≤ 7,  x, y ∈ [0, 3]
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 2), (0, 1, 1)])
        // Stored in minimization form: c = −(4, 3), c0 = −10.
        let lp = CompiledLP(
            a: a, c: [-4, -3], c0: -10, sense: .maximize, xl: [0, 0], xu: [3, 3], rl: [-.infinity], ru: [7],
            integerColumns: [0, 1])
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        // Best: x = 2, y = 3 → 8 + 9 + 10 = 27.
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == 27)
        #expect(analysis.bound == 27)
        #expect(analysis.primal == [2, 3])
    }

    /// Halves and quarters in the data are scaled away exactly (§10.1).
    @Test func rationalDataIsScaledPerRow() async throws {
        // minimize 0.5x + 0.25y   s.t.  0.5x + 1.5y ≥ 4.2,  0.125x − 0.5y ≤ 0.3,  x, y ∈ [0, 10]
        let a = SparseCSC.fromTriplets(rows: 2, cols: 2, [(0, 0, 0.5), (0, 1, 1.5), (1, 0, 0.125), (1, 1, -0.5)])
        let lp = CompiledLP(
            a: a, c: [0.5, 0.25], xl: [0, 0], xu: [10, 10], rl: [4.2, -.infinity], ru: [.infinity, 0.3],
            integerColumns: [0, 1])
        let reference = bruteForce(lp)
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == reference.objective)
        // 0.25 needs two decimals: (50, 25) at scale 100, then (2, 1) after dividing by 25.
        let model = try CPModel(lp)
        #expect(model.objectiveScale == 4)
        #expect(model.reportedObjective(model.objectiveValue(of: [1, 2])) == 1)
    }

    /// Domains of more than 1e6 values are bisected, not enumerated (§10.2).
    @Test func largeDomainsAreBisected() async throws {
        // minimize x + y   s.t.  3x + 7y ≥ 20,000,001,  x, y ∈ [0, 10,000,000]
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 3), (0, 1, 7)])
        let covering = CompiledLP(
            a: a, c: [1, 1], xl: [0, 0], xu: [10_000_000, 10_000_000], rl: [20_000_001], ru: [.infinity],
            integerColumns: [0, 1])
        let first = try await CPSAT(deterministic: true).solve(covering)
        #expect(first.status == .optimal)
        // 7 · 2,857,143 = 20,000,001 exactly, so y alone does it.
        #expect(first.objectiveValue == 2_857_143)
        #expect(first.primal == [0, 2_857_143])
        // The search took a number of decisions logarithmic in the domain, not linear.
        #expect(first.decisions < 10_000)

        // The equality 3x + 7y = 20,000,002 forces x ≡ 5 (mod 7).
        let equality = CompiledLP(
            a: a, c: [1, 1], xl: [0, 0], xu: [10_000_000, 10_000_000], rl: [20_000_002], ru: [20_000_002],
            integerColumns: [0, 1])
        let second = try await CPSAT(deterministic: true).solve(equality)
        #expect(second.status == .optimal)
        #expect(second.primal == [5, 2_857_141])
        #expect(second.objectiveValue == 2_857_146)
    }

    /// A warm start's primal point steers the first decisions; it never changes the answer.
    @Test func primalPointWarmStartIsAHint() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 4, columns: 18, seed: 3)
        let cold = try await CPSAT(deterministic: true).solve(lp)
        var context = SolveContext()
        context.warmStart = .primalPoint(try #require(cold.primal))
        let recorder = EventRecorder()
        context.progress = recorder.callback
        let warm = try await CPSAT(deterministic: true).solve(lp, context: context)
        #expect(warm.status == .optimal)
        #expect(warm.objectiveValue == cold.objectiveValue)
        // Starting from the optimum, the first solution found is the optimum.
        let incumbents = await recorder.finish().compactMap { event -> Double? in
            if case .newIncumbent(let objective, _, _) = event { return objective }
            return nil
        }
        #expect(incumbents.first == cold.objectiveValue)
        #expect(incumbents.count == 1)
        // Other kinds of warm start are ignored, as §11.1 says an engine may.
        var other = SolveContext()
        other.warmStart = .basis(.allLogical(for: lp))
        #expect(try await CPSAT(deterministic: true).solve(lp, context: other).objectiveValue == cold.objectiveValue)
    }

    @Test func degenerateShapes() async throws {
        // No rows at all: every variable goes to the bound its cost prefers.
        let free = CompiledLP(
            a: SparseCSC(rows: 0, cols: 3), c: [2, -1, 0], xl: [-1, 0, 2], xu: [4, 5, 2], rl: [], ru: [],
            integerColumns: [0, 1, 2])
        let unconstrained = try await CPSAT(deterministic: true).solve(free)
        #expect(unconstrained.status == .optimal)
        #expect(unconstrained.objectiveValue == -7)
        #expect(unconstrained.primal == [-1, 5, 2])

        // No columns: the objective is the constant.
        let empty = CompiledLP(a: SparseCSC(rows: 0, cols: 0), c: [], c0: 4.5, xl: [], xu: [], rl: [], ru: [])
        let nothing = try await CPSAT(deterministic: true).solve(empty)
        #expect(nothing.status == .optimal)
        #expect(nothing.objectiveValue == 4.5)
        #expect(nothing.primal == [])
    }

    /// The counters of §11.3 are totals over the workers that ran.
    @Test func analysisCarriesTheSearchStatistics() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 5, columns: 22, seed: 1)
        let analysis = try await CPSAT(workers: 3).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.workers == 3)
        #expect(analysis.winningWorker.map { (0..<3).contains($0) } == true)
        #expect(analysis.conflicts > 0 && analysis.decisions > 0 && analysis.propagations > 0)
        #expect(analysis.learnedClauses > 0 && analysis.learnedClauses <= analysis.conflicts)
        #expect(analysis.seconds >= 0)
        #expect(analysis.dual == nil && analysis.reducedCosts == nil)
        // Through the type-erased interface the same record is visible.
        let erased = AnySolutionAnalysis(analysis, engine: "CPSAT")
        #expect(erased.unwrap(as: CPSATAnalysis.self)?.conflicts == analysis.conflicts)
        #expect(erased.objectiveValue == analysis.objectiveValue)
    }
}
