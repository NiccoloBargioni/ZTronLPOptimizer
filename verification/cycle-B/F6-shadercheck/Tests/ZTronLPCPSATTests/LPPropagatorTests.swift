// The LP propagator, `CPSAT(lpPropagator: true)` — the hook of specification §10.4, and the
// default. The tests name the flag even so: what they compare is the two settings.
//
// What it adds is strength, so what has to be tested is that it adds nothing else: the
// answers are those of exhaustive enumeration, and every clause learned from a row the
// propagator derived holds at every feasible point — checked by enumeration too, because
// such a clause does not follow by unit propagation and the replay of SoundnessTests cannot
// see it.

import Foundation
import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

/// Compares a solve with the brute-force reference; records an issue on a mismatch.
private func agrees(_ analysis: CPSATAnalysis, with reference: BruteForceResult, on lp: CompiledLP, _ label: String) -> Bool {
    guard let expected = reference.objective else {
        if analysis.status != .infeasible {
            Issue.record("\(label): expected infeasible, got \(analysis.status)")
            return false
        }
        return analysis.primal == nil && analysis.objectiveValue == nil
    }
    guard analysis.status == .optimal, let objective = analysis.objectiveValue, let primal = analysis.primal else {
        Issue.record("\(label): expected optimal \(expected), got \(analysis.status)")
        return false
    }
    if abs(objective - expected) > 1e-9 * max(1, abs(expected)) {
        Issue.record("\(label): expected \(expected), got \(objective)")
        return false
    }
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

/// The clauses of `recorded` that some point violates although it satisfies the model and its
/// objective is within the bound the clause was learned under — by enumeration of every
/// integer point of the root domains. `nil` when there are too many points to enumerate.
func clausesViolatedByAFeasiblePoint(model: CPModel, recorded: [RecordedClause], limit: Int = 300_000) -> [Int]? {
    let n = model.variableCount
    var points = 1
    for j in 0..<n {
        let size = Int(model.upper[j] - model.lower[j]) + 1
        if size <= 0 { return [] }
        points *= size
        if points > limit { return nil }
    }
    var feasible: [(values: [Int64], objective: Int64)] = []
    var x = model.lower
    while true {
        if model.isSatisfied(by: x) { feasible.append((x, model.objectiveValue(of: x))) }
        var k = 0
        while k < n {
            if x[k] < model.upper[k] {
                x[k] += 1
                break
            }
            x[k] = model.lower[k]
            k += 1
        }
        if k == n { break }
    }
    var failures: [Int] = []
    for (index, clause) in recorded.enumerated() {
        for point in feasible where !model.hasObjective || point.objective <= clause.objectiveBound {
            let satisfied = clause.literals.contains { literal in
                let v = point.values[Int(literal.variable)]
                return literal.isLower ? v >= literal.value : v <= literal.value
            }
            if !satisfied {
                failures.append(index)
                break
            }
        }
    }
    return failures
}

/// A small dense program over binaries.
private func binaryProgram(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], sense: ObjectiveSense = .minimize
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, sense: sense,
        xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rl: rl, ru: ru,
        integerColumns: (0..<n).map { Int32($0) })
}

/// The assignment problem on `size` agents and tasks with the given costs: its relaxation has
/// integral vertices.
private func assignment(size: Int, cost: (Int, Int) -> Double) -> CompiledLP {
    var c: [Double] = []
    var rows = [[Double]](repeating: [Double](repeating: 0, count: size * size), count: 2 * size)
    for i in 0..<size {
        for j in 0..<size {
            c.append(cost(i, j))
            rows[i][i * size + j] = 1
            rows[size + j][i * size + j] = 1
        }
    }
    let ones = [Double](repeating: 1, count: 2 * size)
    return binaryProgram(c: c, rows: rows, rl: ones, ru: ones)
}

@Suite struct LPPropagatorTests {
    private let inf = Double.infinity

    // MARK: - Answers

    /// One LP worker — which is what a deterministic run with the propagator is — against
    /// enumeration: both senses, general integers, equality and range rows, rational data,
    /// infeasible models.
    @Test func randomProgramsMatchExhaustiveSearch() async throws {
        var failures = 0
        var optimal = 0
        var infeasible = 0
        var lpSolves = 0
        for seed in 0..<400 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 3 + Int(seed % 5)
            options.rows = 2 + Int(seed % 5)
            options.fractional = seed % 3 == 0
            options.maximize = seed % 2 == 1
            options.generalIntegers = seed % 7 != 0
            let lp = randomIntegerProgram(seed: 30_000 + seed, options: options)
            let reference = bruteForce(lp)
            if reference.objective == nil { infeasible += 1 } else { optimal += 1 }
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            lpSolves += analysis.lpSolves
            if !agrees(analysis, with: reference, on: lp, "seed \(seed)") { failures += 1 }
            if failures > 5 { break }
        }
        #expect(failures == 0)
        #expect(optimal > 100 && infeasible > 20)
        #expect(lpSolves > 400, "the relaxation was hardly ever solved: \(lpSolves)")
    }

    /// Knapsacks over binaries, where the relaxation does most of the work.
    @Test func knapsacksMatchExhaustiveSearch() async throws {
        var failures = 0
        for seed in 0..<60 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 3 + Int(seed % 3), columns: 10 + Int(seed % 5), seed: 600 + seed)
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            if !agrees(analysis, with: bruteForce(lp), on: lp, "seed \(seed)") { failures += 1 }
            if failures > 5 { break }
        }
        // General integers with wider domains: the row tightens bounds that are not Boolean.
        for seed in 0..<30 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 3, columns: 6, seed: 900 + seed, upper: 5)
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            if !agrees(analysis, with: bruteForce(lp), on: lp, "wide seed \(seed)") { failures += 1 }
            if failures > 5 { break }
        }
        #expect(failures == 0)
    }

    /// The mixed portfolio — LP workers and pure CDCL workers sharing incumbent and clauses.
    @Test func portfolioMatchesExhaustiveSearch() async throws {
        var failures = 0
        for seed in 0..<150 as Range<UInt64> {
            let lp: CompiledLP
            if seed % 3 == 0 {
                lp = InstanceGenerator.randomMILP(rows: 4, columns: 12, seed: 2_000 + seed)
            } else {
                var options = RandomIPOptions()
                options.variables = 4 + Int(seed % 4)
                options.rows = 3 + Int(seed % 4)
                options.fractional = seed % 5 == 0
                options.maximize = seed % 2 == 1
                lp = randomIntegerProgram(seed: 40_000 + seed, options: options)
            }
            let analysis = try await CPSAT(workers: 2 + Int(seed % 4), lpPropagator: true, seed: seed).solve(lp)
            if !agrees(analysis, with: bruteForce(lp), on: lp, "seed \(seed)") { failures += 1 }
            if failures > 5 { break }
        }
        #expect(failures == 0)
    }

    /// Larger knapsacks, too big to enumerate: with and without the propagator, one worker
    /// and several, the optimum is the same.
    @Test func configurationsAgreeOnLargerKnapsacks() async throws {
        for seed in 0..<6 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 5, columns: 26, seed: 70 + seed)
            let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
            let single = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            let portfolio = try await CPSAT(workers: 4, lpPropagator: true).solve(lp)
            #expect(plain.status == .optimal && single.status == .optimal && portfolio.status == .optimal)
            #expect(single.objectiveValue == plain.objectiveValue, "seed \(seed)")
            #expect(portfolio.objectiveValue == plain.objectiveValue, "seed \(seed)")
            // The relaxation is what makes these short.
            #expect(single.conflicts <= plain.conflicts, "seed \(seed): \(single.conflicts) conflicts with the relaxation, \(plain.conflicts) without")
        }
    }

    // MARK: - Soundness of what is learned

    /// Every clause an LP worker learns — from a conflict of a derived row, or through a bound
    /// a derived row tightened — holds at every feasible point whose objective is within the
    /// bound the clause was learned under.
    @Test func learnedClausesHoldAtEveryFeasiblePoint() async throws {
        var clauses = 0
        var derived = 0
        var checkedModels = 0
        func check(_ lp: CompiledLP, _ label: String) async throws {
            let result = try await CPSAT(lpPropagator: true, deterministic: true)
                .run(lp, context: SolveContext(), recordLearnedClauses: true)
            guard let report = result.reports.first else { return }
            guard let failures = clausesViolatedByAFeasiblePoint(model: result.model, recorded: report.recorded) else { return }
            checkedModels += 1
            clauses += report.recorded.count
            derived += report.lpConflicts + report.lpTightenings
            #expect(failures.isEmpty, "\(label): learned clauses \(failures.prefix(5)) of \(report.recorded.count) cut off a feasible point")
        }
        for seed in 0..<60 as Range<UInt64> {
            try await check(InstanceGenerator.randomMILP(rows: 3 + Int(seed % 4), columns: 13 + Int(seed % 4), seed: 3_000 + seed), "knapsack seed \(seed)")
        }
        for seed in 0..<30 as Range<UInt64> {
            try await check(InstanceGenerator.randomMILP(rows: 3 + Int(seed % 2), columns: 6, seed: 3_500 + seed, upper: 6), "wide knapsack seed \(seed)")
        }
        for seed in 0..<80 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 6 + Int(seed % 4)
            options.rows = 3 + Int(seed % 5)
            options.maximize = seed % 2 == 1
            options.fractional = seed % 3 == 0
            try await check(randomIntegerProgram(seed: 50_000 + seed, options: options), "integer program seed \(seed)")
        }
        #expect(checkedModels > 100)
        #expect(clauses > 300, "only \(clauses) clauses were learned")
        #expect(derived > 300, "the propagator derived only \(derived) rows that did something")
        print("checked \(clauses) learned clauses of \(checkedModels) models against every feasible point; \(derived) derived rows took part")
    }

    /// The check itself must be able to fail.
    @Test func theEnumerationRejectsAClauseThatCutsOffASolution() throws {
        // x + y ≤ 1: (1, 0) is feasible, so ¬x does not hold everywhere; ¬x ∨ ¬y does.
        let lp = binaryProgram(c: [1, 1], rows: [[1, 1]], rl: [-inf], ru: [1])
        let model = try CPModel(lp)
        let bogus = RecordedClause(literals: [BoundLiteral(variable: 0, isLower: false, value: 0)], objectiveBound: .max)
        let valid = RecordedClause(
            literals: [BoundLiteral(variable: 0, isLower: false, value: 0), BoundLiteral(variable: 1, isLower: false, value: 0)],
            objectiveBound: .max)
        #expect(clausesViolatedByAFeasiblePoint(model: model, recorded: [bogus, valid]) == [0])
        // Under an objective bound of 0 only (0, 0) remains, and there ¬x holds.
        let bounded = RecordedClause(literals: bogus.literals, objectiveBound: 0)
        #expect(clausesViolatedByAFeasiblePoint(model: model, recorded: [bounded]) == [])
    }

    // MARK: - What the relaxation proves

    /// The seven lines of the Fano plane, at most one point on each, and at least three points
    /// in all. Every row is consistent with the bounds on its own, so propagation finds
    /// nothing at level 0; but each point lies on three lines, so the relaxation allows a
    /// total of 7/3 at most: it is infeasible, and its Farkas ray is the whole proof.
    @Test func anInfeasibleRelaxationIsAProofWithoutSearch() async throws {
        let lines = [[0, 1, 2], [0, 3, 4], [0, 5, 6], [1, 3, 5], [1, 4, 6], [2, 3, 6], [2, 4, 5]]
        var rows = lines.map { line in (0..<7).map { line.contains($0) ? 1.0 : 0.0 } }
        rows.append([Double](repeating: 1, count: 7))
        let lp = binaryProgram(
            c: [Double](repeating: 0, count: 7), rows: rows,
            rl: [Double](repeating: -inf, count: 7) + [3], ru: [Double](repeating: 1, count: 7) + [inf])
        #expect(bruteForce(lp).objective == nil)
        let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
        #expect(plain.status == .infeasible)
        #expect(plain.decisions > 0)
        let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
        #expect(analysis.status == .infeasible)
        #expect(analysis.decisions == 0)
        #expect(analysis.lpSolves >= 1)
        #expect(analysis.primal == nil && analysis.bound == nil)
    }

    /// Rows that are clauses stay out of the relaxation (§10.1): a model made of clauses has
    /// none, and is searched exactly as it is without the propagator — same path, same counts.
    @Test func aModelOfClausesHasNoRelaxation() async throws {
        for seed in 0..<6 as Range<UInt64> {
            let lp = CNFFormula.random3SAT(variables: 40, clauses: 170, seed: 4_100 + seed).compiled()
            let model = try CPModel(lp)
            #expect(!model.rowHasLinearSide.contains(true))
            #expect(RelaxationData(problem: lp, model: model) == nil)
            let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            #expect(analysis.lpSolves == 0)
            #expect(analysis.warnings.isEmpty)
            #expect(analysis.status == plain.status)
            #expect(analysis.conflicts == plain.conflicts && analysis.decisions == plain.decisions, "seed \(seed)")
            #expect(analysis.primal == plain.primal)
        }
        // One linear row among clauses is relaxed on its own.
        let mixed = binaryProgram(
            c: [1, 1, 1], rows: [[1, 1, 0], [0, 1, 1], [2, 3, 4]], rl: [1, 1, 4], ru: [inf, inf, inf])
        let model = try CPModel(mixed)
        #expect(model.rowHasLinearSide == [false, false, true])
        let data = try #require(RelaxationData(problem: mixed, model: model))
        #expect(data.lp.m == 1 && data.lp.n == 3)
        let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(mixed)
        #expect(agrees(analysis, with: bruteForce(mixed), on: mixed, "one linear row among clauses"))
    }

    /// The restart policy and the frequency of database reductions change the path of an LP
    /// worker, never the answer or the soundness of what it learns.
    @Test func restartsAndReductionsKeepAnLPWorkerSound() async throws {
        var clauses = 0
        for seed in 0..<8 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 4, columns: 14, seed: 9_000 + seed)
            let reference = bruteForce(lp)
            for policy in [RestartPolicy.never, .luby(unit: 1), .luby(unit: 8), .geometric(first: 4, factor: 1.2)] {
                let result = try await CPSAT(restarts: policy, lpPropagator: true, deterministic: true)
                    .run(lp, context: SolveContext(), recordLearnedClauses: true, reductionInterval: 25)
                #expect(agrees(result.analysis, with: reference, on: lp, "seed \(seed), \(policy)"))
                let report = try #require(result.reports.first)
                clauses += report.recorded.count
                let failures = try #require(clausesViolatedByAFeasiblePoint(model: result.model, recorded: report.recorded))
                #expect(failures.isEmpty, "seed \(seed), \(policy): learned clauses \(failures.prefix(5)) cut off a feasible point")
            }
        }
        #expect(clauses > 100, "only \(clauses) clauses were learned")
    }

    /// The relaxation of an assignment problem has an integral optimum: it is taken as the
    /// solution, and the relaxation under `objective ≤ optimum − 1` is the proof.
    @Test func anIntegralRelaxationIsSolvedWithoutSearch() async throws {
        let lp = assignment(size: 6) { i, j in Double((i * 7 + j * 13 + i * j * 5) % 23 + 1) }
        let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
        #expect(plain.status == .optimal)
        let result = try await CPSAT(lpPropagator: true, deterministic: true).run(lp, context: SolveContext(), recordLearnedClauses: false)
        let analysis = result.analysis
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == plain.objectiveValue)
        #expect(analysis.bound == analysis.objectiveValue)
        // No decision; the one conflict is the contradiction at level 0 that ends the search.
        #expect(analysis.decisions == 0 && analysis.conflicts <= 1, "\(analysis.decisions) decisions, \(analysis.conflicts) conflicts")
        let report = try #require(result.reports.first)
        #expect(report.lpSolutions >= 1)
        // And a feasibility problem ends with that solution.
        let feasibility = assignment(size: 5) { _, _ in 0 }
        let found = try await CPSAT(lpPropagator: true, deterministic: true).solve(feasibility)
        #expect(found.status == .optimal)
        #expect(lp.maxViolation(at: try #require(analysis.primal)).rows <= 1e-9)
        #expect(feasibility.maxViolation(at: try #require(found.primal)).rows <= 1e-9)
    }

    /// The bound an LP worker reports at level 0 is the optimum of the relaxation rounded up
    /// to a value of the objective — far above what propagating the objective row alone gives.
    @Test func theRelaxationBoundsTheObjective() async throws {
        // Minimize a cover: every row needs a few of the columns.
        var rng = SeededGenerator(seed: 99)
        let n = 16
        let rows: [[Double]] = (0..<5).map { _ in (0..<n).map { _ in rng.chance(0.5) ? Double(rng.integer(in: 2...9)) : 0 } }
        let cost = (0..<n).map { _ in Double(rng.integer(in: 5...20)) }
        let demand = rows.map { ($0.reduce(0, +) * 0.3).rounded(.down) }
        let lp = binaryProgram(c: cost, rows: rows, rl: demand, ru: [Double](repeating: inf, count: 5))
        let relaxed = try await Simplex(.dual).solve(lp.relaxed())
        let relaxation = try #require(relaxed.objectiveValue)

        let recorder = EventRecorder()
        var context = SolveContext()
        context.progress = recorder.callback
        let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp, context: context)
        let events = await recorder.finish()
        #expect(analysis.status == .optimal)
        #expect(eventContractHolds(events))
        var bounds: [Double] = []
        for event in events {
            if case .boundImproved(let bound, _) = event { bounds.append(bound) }
        }
        let first = try #require(bounds.first)
        #expect(first >= (relaxation - 1e-6).rounded(.up), "first bound \(first), relaxation \(relaxation)")
        #expect(first <= analysis.objectiveValue!)
        #expect(bounds == bounds.sorted())
        #expect(analysis.objectiveValue == bruteForce(lp).objective)
    }

    /// Large coefficients and a finely scaled objective push the integer combination towards
    /// the limits of Int64. The multipliers are then scaled down, or the row is given up; the
    /// answer does not change and nothing overflows.
    @Test func dataNearTheLimitsOfInt64IsHandled() async throws {
        // 1e9·x + y ≥ 2e9 with x up to a million: activities of 1e15.
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1e9), (0, 1, 1)])
        let large = CompiledLP(a: a, c: [1, 0], xl: [0, 0], xu: [1_000_000, 1], rl: [2e9], ru: [inf], integerColumns: [0, 1])
        let first = try await CPSAT(lpPropagator: true, deterministic: true).solve(large)
        #expect(first.status == .optimal)
        #expect(first.objectiveValue == 2)

        // Costs with six decimals: the objective row is scaled by 1e6 before anything else.
        for seed in 0..<12 as Range<UInt64> {
            let base = InstanceGenerator.randomMILP(rows: 3, columns: 11, seed: 8_000 + seed)
            var rng = SeededGenerator(seed: seed)
            let costs = (0..<base.n).map { _ in Double(rng.integer(in: 1...30)) + Double(rng.integer(in: 1...999_999)) * 1e-6 }
            let lp = base.withObjective(costs)
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            #expect(agrees(analysis, with: bruteForce(lp), on: lp, "six decimals, seed \(seed)"))
        }

        // Coefficients in the millions over small integer domains: bounds that are not 0 and 1.
        for seed in 0..<12 as Range<UInt64> {
            var rng = SeededGenerator(seed: 500 + seed)
            let n = 5
            var entries: [(row: Int, col: Int, value: Double)] = []
            for i in 0..<3 {
                for j in 0..<n { entries.append((i, j, Double(rng.integer(in: 1...9)) * 1e6)) }
            }
            let xu = (0..<n).map { _ in Double(rng.integer(in: 3...8)) }
            let demand = (0..<3).map { _ in Double(rng.integer(in: 20...60)) * 1e6 }
            let lp = CompiledLP(
                a: SparseCSC.fromTriplets(rows: 3, cols: n, entries), c: (0..<n).map { _ in Double(rng.integer(in: 1...50)) },
                xl: [Double](repeating: 0, count: n), xu: xu, rl: demand, ru: [Double](repeating: inf, count: 3),
                integerColumns: (0..<n).map { Int32($0) })
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            #expect(agrees(analysis, with: bruteForce(lp), on: lp, "large coefficients, seed \(seed)"))
        }
    }

    // MARK: - The portfolio

    /// Every other worker, starting with the first, is an LP worker.
    @Test func everyOtherWorkerPropagatesWithTheRelaxation() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 5, columns: 30, seed: 5)
        let result = try await CPSAT(workers: 4, lpPropagator: true).run(lp, context: SolveContext(), recordLearnedClauses: false)
        #expect(result.analysis.status == .optimal)
        #expect(result.reports.count == 4)
        for report in result.reports where report.index % 2 == 1 {
            #expect(report.lpSolves == 0, "worker \(report.index) solved \(report.lpSolves) relaxations")
        }
        #expect(result.reports[0].lpSolves > 0)
        #expect(result.analysis.lpSolves == result.reports.reduce(0) { $0 + $1.lpSolves })
        // Without the flag nobody does.
        let plain = try await CPSAT(workers: 4, lpPropagator: false).run(lp, context: SolveContext(), recordLearnedClauses: false)
        #expect(plain.analysis.lpSolves == 0)
        #expect(plain.analysis.objectiveValue == result.analysis.objectiveValue)
    }

    /// Rule C9 with the propagator on: one worker, a fixed seed, a deterministic simplex —
    /// identical results and identical event sequences.
    @Test func deterministicRunsAreIdentical() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 6, columns: 34, seed: 21)
        var reference: (analysis: CPSATAnalysis, events: [SolverEvent])? = nil
        for run in 0..<10 {
            let recorder = EventRecorder()
            var context = SolveContext()
            context.progress = recorder.callback
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp, context: context)
            let events = normalized(await recorder.finish())
            #expect(analysis.status == .optimal)
            if let reference {
                #expect(analysis.objectiveValue == reference.analysis.objectiveValue, "run \(run)")
                #expect(analysis.primal == reference.analysis.primal, "run \(run)")
                #expect(analysis.conflicts == reference.analysis.conflicts, "run \(run)")
                #expect(analysis.decisions == reference.analysis.decisions, "run \(run)")
                #expect(analysis.lpSolves == reference.analysis.lpSolves, "run \(run)")
                #expect(events == reference.events, "run \(run)")
            } else {
                reference = (analysis, events)
                #expect(analysis.lpSolves > 0)
            }
        }
    }

    // MARK: - Limits

    /// Rules L7 and L9: when the memory budget cannot hold an engine per LP worker the solve
    /// says so and runs as plain CDCL; it neither fails nor waits.
    @Test func aBudgetTooSmallForTheEngineRunsWithoutIt() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 40, columns: 60, seed: 3)
        let model = try CPModel(lp)
        var context = SolveContext()
        context.threads = 2
        context.timeLimit = 20
        // Room for the model and the two workers' own state, not for a 40 × 40 basis as well.
        context.memoryBudgetBytes = model.approximateBytes + 2 * 24_000
        let result = try await CPSAT(lpPropagator: true).run(lp, context: context, recordLearnedClauses: false)
        #expect(result.analysis.lpSolves == 0)
        #expect(result.analysis.warnings.contains { $0.contains("LP propagator") }, "\(result.analysis.warnings)")
        #expect(result.analysis.status.hasSolution || result.analysis.status.stopReason == .memoryBudget, "\(result.analysis.status)")
    }

    /// A model with a continuous column is still outside what CP-SAT accepts (§10.1).
    @Test func continuousColumnsAreStillRejected() async {
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1), (0, 1, 1)])
        let lp = CompiledLP(a: a, c: [1, 1], xl: [0, 0], xu: [1, 1], rl: [1], ru: [inf], integerColumns: [0])
        await #expect(throws: SolverError.self) { _ = try await CPSAT(lpPropagator: true).solve(lp) }
    }

    /// A time limit and a cancellation are results with the propagator on as well, and the
    /// engine inside a worker sees them.
    @Test func limitsAndCancellationAreResults() async throws {
        let lp = slowKnapsack()
        var context = SolveContext()
        context.timeLimit = 0.3
        let start = DispatchTime.now().uptimeNanoseconds
        let limited = try await CPSAT(lpPropagator: true).solve(lp, context: context)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(limited.status == .optimal || limited.status.stopReason == .timeLimit, "\(limited.status)")
        #expect(limited.status.hasSolution)
        #expect(elapsed < 5, "a 0.3 s limit took \(elapsed) s")
        if let x = limited.primal {
            let violation = lp.maxViolation(at: x)
            #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
        }

        let task = Task { try await CPSAT(lpPropagator: true).solve(lp) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let cancelled = try await task.value
        #expect(cancelled.status == .optimal || cancelled.status.stopReason == .cancelled, "\(cancelled.status)")
    }

    /// Clause rows have a relaxation too, a useless one: satisfiability answers do not change
    /// and the workers back off from it.
    @Test func satisfiabilityIsUnchanged() async throws {
        for seed in 0..<12 as Range<UInt64> {
            let formula = CNFFormula.random3SAT(variables: 40, clauses: 170, seed: 4_000 + seed)
            let lp = formula.compiled()
            let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
            let analysis = try await CPSAT(lpPropagator: true, deterministic: true).solve(lp)
            #expect(analysis.status == plain.status, "seed \(seed): \(analysis.status) vs \(plain.status)")
            if let x = analysis.primal {
                #expect(lp.maxViolation(at: x).rows <= 1e-9)
            }
        }
        let pigeons = try await CPSAT(lpPropagator: true, deterministic: true).solve(pigeonhole(holes: 5))
        #expect(pigeons.status == .infeasible)
    }
}
