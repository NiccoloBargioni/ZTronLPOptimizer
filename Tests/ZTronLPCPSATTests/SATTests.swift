// Specification §14.2, CP-SAT: CDCL on SATLIB uf50 instances (100 instances, all SAT) and on
// the unsatisfiable uuf50 family, plus seeded random 3-SAT so the core is exercised when the
// corpus has not been fetched.

import Foundation
import Testing
import ZTronLPCore
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

private let satlibHint: Comment = "SATLIB is not bundled: run Scripts/fetch-satlib.sh to fetch uf50-218 and uuf50-218"

@Suite struct SATTests {
    /// The first 100 files of uf50-218: every one is satisfiable, and the model the solver
    /// returns must satisfy every clause of the formula it was read from.
    @Test(.enabled(if: !Corpora.satlib("uf50-218").isEmpty, satlibHint))
    func satlibUF50AllSatisfiable() async throws {
        let files = Corpora.satlib("uf50-218").prefix(100)
        #expect(files.count == 100)
        var conflicts = 0
        let started = Date()
        for url in files {
            let formula = try DIMACS.read(contentsOf: url)
            #expect(formula.variables == 50 && formula.clauses.count == 218)
            let analysis = try await CPSAT(deterministic: true).solve(formula.compiled())
            #expect(analysis.status == .optimal, "\(url.lastPathComponent): \(analysis.status)")
            let primal = try #require(analysis.primal, "\(url.lastPathComponent) has no model")
            #expect(formula.isSatisfied(byValues: primal), "\(url.lastPathComponent): the model violates a clause")
            conflicts += analysis.conflicts
        }
        print("SATLIB uf50-218: \(files.count) instances satisfiable, \(conflicts) conflicts, \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
    }

    /// The first 100 files of uuf50-218: every one is unsatisfiable.
    @Test(.enabled(if: !Corpora.satlib("uuf50-218").isEmpty, satlibHint))
    func satlibUUF50AllUnsatisfiable() async throws {
        let files = Corpora.satlib("uuf50-218").prefix(100)
        #expect(files.count == 100)
        var conflicts = 0
        let started = Date()
        for url in files {
            let formula = try DIMACS.read(contentsOf: url)
            let analysis = try await CPSAT(deterministic: true).solve(formula.compiled())
            #expect(analysis.status == .infeasible, "\(url.lastPathComponent): \(analysis.status)")
            #expect(analysis.primal == nil && analysis.objectiveValue == nil)
            conflicts += analysis.conflicts
        }
        print("SATLIB uuf50-218: \(files.count) instances unsatisfiable, \(conflicts) conflicts, \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
    }

    /// The portfolio reaches the same verdicts as the single deterministic worker.
    @Test(.enabled(if: !Corpora.satlib("uf50-218").isEmpty && !Corpora.satlib("uuf50-218").isEmpty, satlibHint))
    func satlibPortfolioAgrees() async throws {
        for url in Corpora.satlib("uf50-218").dropFirst(100).prefix(20) {
            let formula = try DIMACS.read(contentsOf: url)
            let analysis = try await CPSAT(workers: 4).solve(formula.compiled())
            #expect(analysis.status == .optimal)
            if let primal = analysis.primal { #expect(formula.isSatisfied(byValues: primal)) }
            #expect(analysis.workers == 4)
            #expect(analysis.winningWorker != nil)
        }
        for url in Corpora.satlib("uuf50-218").dropFirst(100).prefix(20) {
            let formula = try DIMACS.read(contentsOf: url)
            let analysis = try await CPSAT(workers: 4).solve(formula.compiled())
            #expect(analysis.status == .infeasible)
        }
    }

    /// Always on: seeded uniform random 3-SAT at the threshold ratio 4.26, the distribution
    /// the SATLIB families were drawn from. Satisfiable verdicts are checked against the
    /// formula; every verdict is checked against a second, differently configured run.
    @Test func randomThreeSATAtTheThreshold() async throws {
        var satisfiable = 0
        var unsatisfiable = 0
        var conflicts = 0
        for seed in 0..<60 as Range<UInt64> {
            let formula = CNFFormula.random3SAT(variables: 50, clauses: 213, seed: 0xC0FFEE + seed)
            let lp = formula.compiled()
            let analysis = try await CPSAT(deterministic: true).solve(lp)
            conflicts += analysis.conflicts
            switch analysis.status {
            case .optimal:
                satisfiable += 1
                let primal = try #require(analysis.primal)
                #expect(formula.isSatisfied(byValues: primal), "seed \(seed): the model violates a clause")
            case .infeasible:
                unsatisfiable += 1
            default:
                Issue.record("seed \(seed): unexpected status \(analysis.status)")
            }
            let second = try await CPSAT(workers: 3, restarts: .geometric(first: 50, factor: 1.5), seed: 99).solve(lp)
            #expect(second.status == analysis.status, "seed \(seed): \(second.status) vs \(analysis.status)")
            if let primal = second.primal { #expect(formula.isSatisfied(byValues: primal)) }
        }
        // At the threshold both verdicts occur.
        #expect(satisfiable > 0 && unsatisfiable > 0)
        print("random 3-SAT (50 variables, 213 clauses): \(satisfiable) satisfiable, \(unsatisfiable) unsatisfiable, \(conflicts) conflicts")
    }

    /// Small formulas, where exhaustive enumeration is the oracle for both verdicts.
    @Test func smallFormulasMatchExhaustiveSearch() async throws {
        for seed in 0..<80 as Range<UInt64> {
            let variables = 9 + Int(seed % 6)
            let clauses = Int((Double(variables) * (3.6 + Double(seed % 5) * 0.4)).rounded())
            let formula = CNFFormula.random3SAT(variables: variables, clauses: clauses, seed: 31 * seed + 5)
            var expected = false
            var assignment = [Bool](repeating: false, count: variables)
            for mask in 0..<(1 << variables) {
                for v in 0..<variables { assignment[v] = (mask >> v) & 1 == 1 }
                if formula.isSatisfied(by: assignment) {
                    expected = true
                    break
                }
            }
            let analysis = try await CPSAT(deterministic: true).solve(formula.compiled())
            #expect(analysis.status == (expected ? .optimal : .infeasible), "seed \(seed)")
            if let primal = analysis.primal { #expect(formula.isSatisfied(byValues: primal)) }
        }
    }

    /// A satisfiability problem has no objective: the first model is the answer, its value is
    /// the objective constant and the bound coincides with it.
    @Test func feasibilityProblemReportsTheConstantObjective() async throws {
        let formula = CNFFormula(variables: 4, clauses: [[1, 2], [-1, 3], [-2, -3], [3, 4], [-4, 1]])
        let analysis = try await CPSAT(deterministic: true).solve(formula.compiled())
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == 0)
        #expect(analysis.bound == 0)
        #expect(analysis.dual == nil && analysis.reducedCosts == nil)
        let primal = try #require(analysis.primal)
        #expect(primal.count == 4 && primal.allSatisfy { $0 == 0 || $0 == 1 })
        #expect(formula.isSatisfied(byValues: primal))
    }

    @Test func emptyClauseIsInfeasibleAndTautologiesAreDropped() async throws {
        let contradictory = CNFFormula(variables: 2, clauses: [[1, 2], []])
        #expect(try await CPSAT(deterministic: true).solve(contradictory.compiled()).status == .infeasible)

        let tautological = CNFFormula(variables: 2, clauses: [[1, -1], [2, 2, -1]])
        let lp = tautological.compiled()
        #expect(lp.m == 1)          // the tautology is not a row
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(analysis.status == .optimal)
        if let primal = analysis.primal { #expect(tautological.isSatisfied(byValues: primal)) }
    }

    // MARK: DIMACS

    @Test func dimacsParserReadsTheSATLIBDialect() throws {
        let text = """
        c This Formular is generated by mcnf
        c
        p cnf 4  3
         -3 1 4 0
        2 -4
          3 0
        -1 -2 0
        %
        0

        """
        let formula = try DIMACS.parse(text)
        #expect(formula.variables == 4)
        #expect(formula.clauses == [[-3, 1, 4], [2, -4, 3], [-1, -2]])
        // Writing and reading back is the identity.
        #expect(try DIMACS.parse(DIMACS.write(formula)) == formula)
    }

    @Test func dimacsParserRejectsMalformedInput() {
        #expect(throws: SolverError.self) { try DIMACS.parse("1 2 0\n") }                       // no problem line
        #expect(throws: SolverError.self) { try DIMACS.parse("p cnf 2 1\n1 x 0\n") }            // not a literal
        #expect(throws: SolverError.self) { try DIMACS.parse("p cnf 2 1\n1 3 0\n") }            // literal out of range
        #expect(throws: SolverError.self) { try DIMACS.parse("p cnf 2 2\n1 2 0\n") }            // clause count mismatch
        #expect(throws: SolverError.self) { try DIMACS.parse("p sat 2 1\n1 2 0\n") }            // not cnf
    }

    @Test func compiledFormulaIsAPureBinaryProgramOfClauseRows() throws {
        let formula = CNFFormula(variables: 3, clauses: [[1, -2, 3], [-1, -3]])
        let lp = formula.compiled()
        #expect(lp.n == 3 && lp.m == 2)
        #expect(lp.integerColumns == [0, 1, 2])
        #expect(lp.xl == [0, 0, 0] && lp.xu == [1, 1, 1])
        // x1 − x2 + x3 ≥ 0 and −x1 − x3 ≥ −1.
        #expect(lp.rl == [0, -1])
        #expect(lp.a[0, 0] == 1 && lp.a[0, 1] == -1 && lp.a[0, 2] == 1)
        #expect(lp.a[1, 0] == -1 && lp.a[1, 2] == -1)
        // The loader stores both rows as clauses, not as linear constraints.
        let model = try CPModel(lp)
        #expect(model.clauses.count == 2)
        #expect(model.constraintCount == 0)
    }
}
