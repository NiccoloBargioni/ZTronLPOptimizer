import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport
@testable import ZTronLPSimplex

// The refinement pass that ends an unlimited run (SimplexEngine.refine), the consistency of
// the tolerances, and the ratio tests' second look below the pivot tolerance.

/// Solves `lp` the way `Simplex.solve` does, with the engine handed to `configure` first.
private func solve(
    _ lp: CompiledLP, _ method: Simplex.Method, iterationLimit: Int? = nil,
    configure: (inout SimplexEngine) -> Void = { _ in }
) async throws -> SimplexAnalysis {
    let strategy = Simplex(method)
    let original = lp.relaxed()
    let pre = Presolve.run(original, tolerances: strategy.tolerances, mode: .full)
    let scaled = Scaler.scale(pre.reduced, mode: strategy.scaling)
    var engine = SimplexEngine(lp: scaled, strategy: strategy, factorization: strategy.makeFactorization(rows: scaled.m))
    configure(&engine)
    var gate = WorkGate(deadline: .none)
    let outcome = try await engine.run(
        method: method, warmStart: .none, cutoff: nil, iterationLimit: iterationLimit, gate: &gate)
    return Simplex.postsolved(outcome, presolve: pre, original: original, seconds: 0, warnings: [])
}

private func distanceFromOnes(_ analysis: SimplexAnalysis) -> Double {
    var worst = 0.0
    for value in analysis.primal ?? [.infinity] { worst = max(worst, abs(value - 1)) }
    return worst
}

@Suite struct RefinementTests {
    let hilbert = InstanceGenerator.hilbert(order: 8, form: .equality)

    /// What the pass is for. Without it the run stops on a basis that is optimal within the
    /// tolerances — every row holds to 1e-7 — and whose vertex is nowhere near the solution.
    @Test(arguments: bothMethods)
    func withoutThePassTheVertexIsOnlyOptimalWithinTheTolerances(_ method: Simplex.Method) async throws {
        let plain = try await solve(hilbert.lp, method) { $0.faults.skipRefinement = true }
        #expect(plain.status == .optimal)
        let x = try #require(plain.primal)
        let violation = hilbert.lp.maxViolation(at: x)
        #expect(violation.rows <= 1e-7 && violation.bounds <= 1e-7)
        #expect(abs(try #require(plain.objectiveValue) - hilbert.objective) <= 1e-8)
        #expect(distanceFromOnes(plain) > 0.1, "the vertex found without the pass is \(distanceFromOnes(plain)) from the solution")

        let refined = try await solve(hilbert.lp, method)
        #expect(refined.status == .optimal)
        #expect(distanceFromOnes(refined) <= 2e-5, "with the pass: \(distanceFromOnes(refined))")
        #expect(refined.iterations > plain.iterations)
        #expect(refined.basis.basic.filter { Int($0) < hilbert.lp.n }.count == hilbert.lp.n, "every column is basic at the solution")
        #expect(refined.method == method, "the pass does not change which method the analysis names")
    }

    /// The pass can only improve an answer: with no pivots to spend it gives up, and the run
    /// returns to the basis it had proved optimal.
    @Test(arguments: bothMethods)
    func aPassThatCannotFinishLeavesTheAnswerAsItWas(_ method: Simplex.Method) async throws {
        let plain = try await solve(hilbert.lp, method) { $0.faults.skipRefinement = true }
        let abandoned = try await solve(hilbert.lp, method) { $0.faults.refinementIterationLimit = 0 }
        #expect(abandoned.status == .optimal)
        #expect(abandoned.basis == plain.basis)
        #expect(abandoned.iterations == plain.iterations)
        let (x, y) = (try #require(abandoned.primal), try #require(plain.primal))
        for j in x.indices { #expect(abs(x[j] - y[j]) <= 1e-9 * (1 + abs(y[j]))) }
        let duals = try #require(abandoned.dual)
        let reference = try #require(plain.dual)
        for i in duals.indices { #expect(abs(duals[i] - reference[i]) <= 1e-9 * (1 + abs(reference[i]))) }
    }

    /// A cancellation that lands inside the pass costs nothing: the run returns the answer it
    /// had, restored from a copy, and does not stop to factor a basis again.
    @Test(arguments: bothMethods)
    func aStopInsideThePassKeepsTheAnswerAndRefactorsNothing(_ method: Simplex.Method) async throws {
        let plain = try await solve(hilbert.lp, method) { $0.faults.skipRefinement = true }
        let stopped = try await solve(hilbert.lp, method) { $0.faults.stopInsideRefinement = true }
        #expect(stopped.status == .optimal)
        #expect(stopped.basis == plain.basis)
        #expect(stopped.iterations == plain.iterations)
        #expect(stopped.refactorizations == plain.refactorizations, "a stop must not pay for a factorization")
        #expect(stopped.primal == plain.primal)
        #expect(stopped.dual == plain.dual)
        #expect(stopped.reducedCosts == plain.reducedCosts)
        #expect(stopped.objectiveValue == plain.objectiveValue)
    }

    /// A run with an iteration budget is one of many related solves — a branch-and-bound
    /// node, a probe, a look of CP-SAT's propagator — and ends where it always did.
    @Test func runsWithAnIterationBudgetAreNotRefined() async throws {
        let plain = try await solve(hilbert.lp, .dual) { $0.faults.skipRefinement = true }
        let node = try await solve(hilbert.lp, .dual, iterationLimit: 100_000)
        #expect(node.status == .optimal)
        #expect(node.basis == plain.basis)
        #expect(node.iterations == plain.iterations)
    }

    /// On problems whose first optimal basis is optimal at the tighter tolerances as well —
    /// the usual case — the pass changes nothing and says nothing.
    @Test func wellConditionedProblemsAreLeftAlone() async throws {
        var lps: [(String, CompiledLP)] = []
        for name in ["afiro", "sc50a", "adlittle", "blend", "share2b"] { lps.append((name, try NetlibFixtures.load(name))) }
        var options = ConstructedOptions()
        options.degenerate = true
        options.rangeRows = true
        for seed in 0..<20 {
            lps.append(("constructed \(seed)", InstanceGenerator.constructedOptimum(rows: 10 + seed, columns: 16 + 2 * seed, seed: UInt64(seed), options: options).lp))
        }
        // Badly scaled problems are full of violations of 1e-10 that are rounding, not
        // structure; the pass must not chase them.
        options = ConstructedOptions()
        options.scaleSpread = 6
        for seed in 0..<40 {
            lps.append(("scaled \(seed)", InstanceGenerator.constructedOptimum(rows: 8 + seed % 25, columns: 12 + seed % 40, seed: UInt64(seed), options: options).lp))
        }
        for (name, lp) in lps {
            for method in bothMethods {
                let plain = try await solve(lp, method) { $0.faults.skipRefinement = true }
                let refined = try await solve(lp, method)
                #expect(refined.status == plain.status, "\(name) \(method)")
                #expect(refined.iterations == plain.iterations, "\(name) \(method): \(plain.iterations) → \(refined.iterations) pivots")
                #expect(refined.basis == plain.basis, "\(name) \(method)")
                #expect(refined.warnings == plain.warnings, "\(name) \(method): \(refined.warnings)")
            }
        }
    }

    /// The condition estimate behind the warning works with a factorization that has none of
    /// its own (sparse QR), and agrees with the dense one in order of magnitude.
    @Test func theConditionEstimateDoesNotNeedADenseBasis() async throws {
        let lp = Scaler.scale(hilbert.lp, mode: .none)
        var estimates: [Double] = []
        for factorization in [Simplex.Factorization.denseLU, .sparseQR] {
            let strategy = Simplex(.dual, factorization: factorization, presolve: false, scaling: .none)
            var engine = SimplexEngine(lp: lp, strategy: strategy, factorization: strategy.makeFactorization(rows: lp.m))
            var gate = WorkGate(deadline: .none)
            let outcome = try await engine.run(method: .dual, warmStart: .none, cutoff: nil, iterationLimit: nil, gate: &gate)
            #expect(outcome.status == .optimal)
            let estimate = engine.basisConditionEstimate()
            estimates.append(try #require(estimate))
        }
        // κ₁ of the 8 × 8 Hilbert matrix is 3.4e10.
        for estimate in estimates { #expect(estimate > 3e9 && estimate < 3e11, "estimate \(estimate)") }
    }
}

@Suite struct ToleranceConsistencyTests {
    @Test func theDefaultsAreConsistentAsTheyAre() {
        let defaults = Tolerances()
        #expect(defaults.consistent == defaults)
    }

    /// Lower feasibility tolerances pull the pivot tolerance and the Harris slack down with
    /// them; tolerances a caller set lower still are kept.
    @Test func lowerFeasibilityTolerancesPullTheOthersDown() {
        var tolerances = Tolerances()
        tolerances.primalFeasibility = 1e-10
        let consistent = tolerances.consistent
        #expect(consistent.primalFeasibility == 1e-10)
        #expect(consistent.dualFeasibility == 1e-7)
        #expect(consistent.pivot == 1e-10)
        #expect(abs(consistent.harris - 1e-12) <= 1e-24)
        #expect(consistent.integrality == tolerances.integrality && consistent.dropZero == tolerances.dropZero)

        tolerances.pivot = 1e-12
        tolerances.harris = 1e-15
        #expect(tolerances.consistent.pivot == 1e-12)
        #expect(tolerances.consistent.harris == 1e-15)
    }
}

@Suite struct SmallPivotTests {
    /// One row, `x0 + 1e-9·x1 ≥ 1` with x0 ≤ 0.5: only x1, through an entry far below the
    /// pivot tolerance, can make it feasible. A ratio test that drops that entry reads the
    /// row as a proof of infeasibility; the problem is feasible, at x1 = 5e8.
    @Test(arguments: bothMethods)
    func aRowThatOnlyASmallEntryCanRepairIsNotAProofOfInfeasibility(_ method: Simplex.Method) async throws {
        let lp = denseLP(c: [1, 1e-9], rows: [[1, 1e-9]], rl: [1], ru: [inf], xu: [0.5, inf])
        let analysis = try await Simplex(method, presolve: false, scaling: .none).solve(lp)
        #expect(analysis.status == .optimal, "\(analysis.status)")
        let x = try #require(analysis.primal)
        let violation = lp.maxViolation(at: x)
        #expect(violation.rows <= 1e-7 && violation.bounds <= 1e-7, "x = \(x)")
        #expect(abs(try #require(analysis.objectiveValue) - 1) <= 1e-7)
    }

    /// The same shape with nothing that can help is still infeasible, with its certificate.
    @Test(arguments: bothMethods)
    func aRowNothingCanRepairStillProvesInfeasibility(_ method: Simplex.Method) async throws {
        let lp = denseLP(c: [1, 1], rows: [[1, 1]], rl: [1], ru: [inf], xu: [0.25, 0.25])
        let analysis = try await Simplex(method, presolve: false, scaling: .none).solve(lp)
        #expect(analysis.status == .infeasible)
        let ray = try #require(analysis.dualRay)
        #expect(farkasGap(lp, ray) > 1e-9)
    }
}
