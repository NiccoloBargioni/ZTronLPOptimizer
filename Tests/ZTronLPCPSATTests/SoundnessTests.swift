// Specification §14.2, CP-SAT: learned-clause soundness check by re-propagating each learned
// clause from its reason set.
//
// A learned clause must follow from the model. The check replays the search's clauses in the
// order they were learned on a fresh propagation engine: for each clause it assumes the
// negation of every literal — the reason set, the nogood the clause was derived from — and
// runs the propagators. They must reach a contradiction using only the model, the objective
// bound that was in force when the clause was learned, and the clauses learned before it.
// A clause that survives its own negation was not implied, and the test fails.
//
// This is the oracle of the core as §10.2 specifies it, so every solve here switches the LP
// propagator off: a clause learned from a row the propagator derived follows from the model
// but not by unit propagation, and has an oracle of its own (LPPropagatorTests.swift).

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

/// Replays `recorded` against `model`. Returns how many clauses were checked and the indices
/// of those whose negation did not propagate to a contradiction.
func replayLearnedClauses(model: CPModel, recorded: [RecordedClause]) -> (checked: Int, failures: [Int]) {
    var checker = CPWorker(model: model, options: WorkerOptions())
    var failures: [Int] = []
    var checked = 0
    if checker.rootConflict || checker.propagate() != nil { return (0, []) }
    for (index, clause) in recorded.enumerated() {
        // The objective bound the clause was derived under.
        if model.hasObjective, clause.objectiveBound < checker.linRHS[model.objectiveRow] {
            checker.tightenObjective(below: clause.objectiveBound + 1)
            // A bound that is contradictory on its own implies everything that follows.
            if checker.propagate() != nil { break }
        }
        checker.newDecisionLevel()
        var contradiction = false
        for literal in clause.literals {
            let assumption = literal.negated
            let x = Int(assumption.variable)
            if assumption.isLower {
                if assumption.value > checker.ub[x] {
                    contradiction = true
                    break
                }
                if assumption.value > checker.lb[x] { checker.setLower(x, assumption.value, ReasonKind.none, -1) }
            } else {
                if assumption.value < checker.lb[x] {
                    contradiction = true
                    break
                }
                if assumption.value < checker.ub[x] { checker.setUpper(x, assumption.value, ReasonKind.none, -1) }
            }
        }
        if !contradiction { contradiction = checker.propagate() != nil }
        checked += 1
        if !contradiction { failures.append(index) }
        checker.cancelUntil(0)
        // The clause joins the database for the ones learned after it.
        if !checker.addRootClause(clause.literals, learned: true, lbd: 2, activity: 0) { break }
        if checker.propagate() != nil { break }
    }
    return (checked, failures)
}

@Suite struct SoundnessTests {
    /// Solves with clause recording on and replays what was learned.
    private func solveAndReplay(
        _ lp: CompiledLP, strategy: CPSAT = CPSAT(lpPropagator: false, deterministic: true), reductionInterval: Int = 20_000, _ label: String
    ) async throws -> (analysis: CPSATAnalysis, checked: Int) {
        let result = try await strategy.run(lp, context: SolveContext(), recordLearnedClauses: true, reductionInterval: reductionInterval)
        // No worker runs for a model that is infeasible at load.
        let recorded = result.reports.first?.recorded ?? []
        #expect(recorded.count == result.reports.first?.learnedClauses ?? 0)
        let replay = replayLearnedClauses(model: result.model, recorded: recorded)
        #expect(replay.failures.isEmpty, "\(label): learned clauses \(replay.failures.prefix(5)) of \(recorded.count) do not follow from their reason sets")
        return (result.analysis, replay.checked)
    }

    @Test func learnedClausesOfSATInstancesAreImplied() async throws {
        var checked = 0
        for seed in 0..<30 as Range<UInt64> {
            let formula = CNFFormula.random3SAT(variables: 45, clauses: 192, seed: 700 + seed)
            checked += try await solveAndReplay(formula.compiled(), "3-SAT seed \(seed)").checked
        }
        #expect(checked > 500)
        print("replayed \(checked) learned clauses of 3-SAT instances")
    }

    /// Linear reasons — rebuilt lazily from the bounds and then relaxed — are where an
    /// explanation is most easily wrong, and optimization adds the moving objective bound.
    @Test func learnedClausesOfIntegerProgramsAreImplied() async throws {
        var checked = 0
        for seed in 0..<60 as Range<UInt64> {
            var options = RandomIPOptions()
            options.variables = 8 + Int(seed % 4)
            options.rows = 5 + Int(seed % 5)
            options.maximize = seed % 2 == 1
            options.fractional = seed % 3 == 0
            let lp = randomIntegerProgram(seed: 5_000 + seed, options: options)
            checked += try await solveAndReplay(lp, "integer program seed \(seed)").checked
        }
        for seed in 0..<6 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 5, columns: 22, seed: 40 + seed)
            checked += try await solveAndReplay(lp, "knapsack seed \(seed)").checked
        }
        // General integers with wide domains: bound literals that are not Boolean.
        for seed in 0..<6 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 4, columns: 9, seed: 80 + seed, upper: 6)
            checked += try await solveAndReplay(lp, "wide-domain knapsack seed \(seed)").checked
        }
        #expect(checked > 500)
        print("replayed \(checked) learned clauses of integer programs")
    }

    @Test func learnedClausesOfThePigeonholeAreImplied() async throws {
        let result = try await solveAndReplay(pigeonhole(holes: 5), "pigeonhole")
        #expect(result.analysis.status == .infeasible)
        #expect(result.checked > 0)
    }

    /// Reducing the database every few clauses rebuilds atoms, clauses and watch lists over
    /// and over. Neither the answers nor the soundness of what is learned may change.
    @Test func frequentDatabaseReductionsChangeNothing() async throws {
        for seed in 0..<12 as Range<UInt64> {
            let lp: CompiledLP
            if seed % 3 == 0 {
                lp = CNFFormula.random3SAT(variables: 45, clauses: 192, seed: 900 + seed).compiled()
            } else {
                lp = InstanceGenerator.randomMILP(rows: 5, columns: 20, seed: seed)
            }
            let reference = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
            let strategy = CPSAT(lpPropagator: false, deterministic: true)
            let result = try await strategy.run(lp, context: SolveContext(), recordLearnedClauses: true, reductionInterval: 40)
            #expect(result.analysis.status == reference.status, "seed \(seed)")
            #expect(result.analysis.objectiveValue == reference.objectiveValue, "seed \(seed)")
            let report = try #require(result.reports.first)
            if report.learnedClauses > 400 { #expect(report.reductions > 0, "seed \(seed): the database was never reduced") }
            let replay = replayLearnedClauses(model: result.model, recorded: report.recorded)
            #expect(replay.failures.isEmpty, "seed \(seed): \(replay.failures.count) learned clauses are not implied")
        }
    }

    /// The same with general integers over wide domains, where reductions also free and
    /// renumber the bound literals that no surviving clause mentions.
    @Test func reductionsRenumberBoundLiterals() async throws {
        var renumbered = 0
        for seed in 0..<8 as Range<UInt64> {
            let lp = InstanceGenerator.randomMILP(rows: 4, columns: 8, seed: 300 + seed, upper: 10)
            let reference = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
            #expect(reference.status == .optimal)
            let result = try await CPSAT(lpPropagator: false, deterministic: true).run(
                lp, context: SolveContext(), recordLearnedClauses: true, reductionInterval: 25)
            #expect(result.analysis.status == .optimal, "seed \(seed)")
            #expect(result.analysis.objectiveValue == reference.objectiveValue, "seed \(seed)")
            let report = try #require(result.reports.first)
            renumbered += report.renumberings
            let replay = replayLearnedClauses(model: result.model, recorded: report.recorded)
            #expect(replay.failures.isEmpty, "seed \(seed): \(replay.failures.count) learned clauses are not implied")
        }
        #expect(renumbered > 0, "no reduction freed and renumbered bound literals")
    }

    /// The restart policy changes the path, never the soundness or the answer.
    @Test func everyRestartPolicyIsSound() async throws {
        let lp = InstanceGenerator.randomMILP(rows: 5, columns: 21, seed: 12)
        let reference = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
        for policy in [RestartPolicy.never, .luby(unit: 1), .luby(unit: 8), .geometric(first: 4, factor: 1.2), .geometric(first: 1_000, factor: 2)] {
            let result = try await solveAndReplay(lp, strategy: CPSAT(restarts: policy, lpPropagator: false, deterministic: true), "\(policy)")
            #expect(result.analysis.status == .optimal)
            #expect(result.analysis.objectiveValue == reference.objectiveValue, "\(policy)")
        }
    }

    /// The checker itself must be able to fail: a clause that does not follow is caught.
    @Test func theReplayRejectsAClauseThatIsNotImplied() throws {
        // x + y + z ≥ 1 does not imply ¬x.
        let model = try CPModel(CNFFormula(variables: 3, clauses: [[1, 2, 3]]).compiled())
        let bogus = RecordedClause(literals: [BoundLiteral(variable: 0, isLower: false, value: 0)], objectiveBound: .max)
        #expect(replayLearnedClauses(model: model, recorded: [bogus]).failures == [0])
        // ¬x ∨ ¬y, on the other hand, does follow from x + y ≤ 1 stated as a linear row over wider domains.
        let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1), (0, 1, 1)])
        let lp = CompiledLP(a: a, c: [0, 0], xl: [0, 0], xu: [2, 2], rl: [-.infinity], ru: [1], integerColumns: [0, 1])
        let implied = RecordedClause(
            literals: [BoundLiteral(variable: 0, isLower: false, value: 0), BoundLiteral(variable: 1, isLower: false, value: 0)],
            objectiveBound: .max)
        #expect(replayLearnedClauses(model: try CPModel(lp), recorded: [implied]).failures.isEmpty)
    }
}
