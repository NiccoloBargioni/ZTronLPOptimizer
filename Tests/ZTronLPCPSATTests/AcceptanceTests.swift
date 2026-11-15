// Accepted models (specification §10.1): what CP-SAT takes, what it rejects with
// `SolverError.unsupported`, and how a `CompiledLP` becomes exact integer constraints.

import Testing
import ZTronLPCore
import ZTronLPTestSupport
@testable import ZTronLPCPSAT

@Suite struct AcceptanceTests {
    /// One row over the given columns.
    private func singleRow(
        _ coefficients: [Double], lower: Double = -.infinity, upper: Double = .infinity,
        xl: [Double]? = nil, xu: [Double]? = nil, cost: [Double]? = nil, integer: [Int32]? = nil
    ) -> CompiledLP {
        let n = coefficients.count
        let entries = coefficients.enumerated().filter { $0.element != 0 }.map { (row: 0, col: $0.offset, value: $0.element) }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: 1, cols: n, entries), c: cost ?? [Double](repeating: 0, count: n),
            xl: xl ?? [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: 1, count: n),
            rl: [lower], ru: [upper], integerColumns: integer ?? (0..<n).map { Int32($0) })
    }

    /// Asserts that solving `lp` throws `SolverError.unsupported` whose message contains `fragment`.
    private func expectUnsupported(_ lp: CompiledLP, containing fragment: String, strategy: CPSAT = CPSAT()) async {
        do {
            _ = try await strategy.solve(lp)
            Issue.record("the model was accepted; expected unsupported (\(fragment))")
        } catch let error as SolverError {
            guard case .unsupported(let message) = error else {
                Issue.record("expected unsupported, got \(error)")
                return
            }
            #expect(message.contains(fragment), "message: \(message)")
        } catch {
            Issue.record("solve threw something that is not a SolverError: \(error)")
        }
    }

    // MARK: Rejections

    @Test func continuousColumnsAreRejected() async {
        // Column 1 is continuous: this model belongs to branch and bound.
        let lp = singleRow([1, 1], upper: 1, integer: [0])
        await expectUnsupported(lp, containing: "continuous")
    }

    @Test func integerColumnsWithoutFiniteBoundsAreRejected() async {
        await expectUnsupported(singleRow([1, 1], upper: 5, xu: [3, .infinity]), containing: "unbounded")
        await expectUnsupported(singleRow([1, 1], upper: 5, xl: [-.infinity, 0], xu: [3, 3]), containing: "unbounded")
    }

    @Test func dataThatNoPowerOfTenMakesIntegralIsRejected() async {
        // 1/3 has no finite decimal expansion.
        await expectUnsupported(singleRow([1.0 / 3.0, 1], upper: 1), containing: "integral")
        // Seven decimals would need a scale of 1e7; the limit is 1e6.
        await expectUnsupported(singleRow([0.1234567, 1], upper: 1), containing: "integral")
        // The same rule holds for the objective.
        await expectUnsupported(singleRow([1, 1], upper: 1, cost: [0.1234567, 1]), containing: "objective")
    }

    @Test func sixDecimalsAreAccepted() async throws {
        // 0.125 needs a scale of 1,000 and 0.000001 the full 1e6.
        let lp = singleRow([0.125, 0.000001], lower: 0.125, cost: [1, 1])
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.primal == [1, 0])
    }

    /// §10.1: activity bounds of every row must fit in Int64, checked at load.
    @Test func activityOverflowIsRejected() async {
        // 4e12 · 3e6 = 1.2e19 > Int64.max ≈ 9.22e18.
        let row = singleRow([4e12, 1], upper: 10, xu: [3e6, 1])
        await expectUnsupported(row, containing: "Int64")
        // Each term fits, but their sum does not. (The coefficients share no divisor: a common
        // one would be divided out at load and the row would be harmless.)
        let sum = singleRow([1e12, 1e12 + 1, 1e12 + 2, 1e12 + 3], upper: 10, xu: [1e6, 1e6, 1e6, 1e6])
        await expectUnsupported(sum, containing: "Int64")
        // 3e12·(x + y) ≤ 10 is x + y ≤ 0 once the common divisor is gone: accepted.
        #expect((try? CPModel(singleRow([3e12, 3e12], upper: 10, xu: [1e6, 1e6]))) != nil)
        // The objective is one more row and is checked the same way.
        let objective = singleRow([1, 1], upper: 1, xu: [3e6, 1], cost: [4e12, 1])
        await expectUnsupported(objective, containing: "Int64")
        // Bounds beyond 2^53 cannot be read exactly from a Double.
        let bounds = singleRow([1, 1], upper: 1, xu: [1e17, 1])
        await expectUnsupported(bounds, containing: "too large")
    }

    @Test func largeButRepresentableDataIsAccepted() async throws {
        // 1e9 · 1e6 = 1e15 is far inside Int64.
        let lp = singleRow([1e9, 1], lower: 2e9, xu: [1_000_000, 1], cost: [1, 0])
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == 2)
    }

    /// The hook of §10.4 is implemented, and on unless it is switched off: the flag changes
    /// how hard the search has to work, not what it accepts or what it answers
    /// (LPPropagatorTests.swift).
    @Test func theLPPropagatorIsTheDefaultAndCanBeSwitchedOff() async throws {
        #expect(CPSAT().lpPropagator)
        #expect(!CPSAT(lpPropagator: false).lpPropagator)
        let lp = singleRow([2, 3], upper: 4, cost: [-2, -3])
        let plain = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp)
        let analysis = try await CPSAT(deterministic: true).solve(lp)
        #expect(plain.lpSolves == 0 && analysis.lpSolves > 0)
        #expect(analysis.status == .optimal)
        #expect(analysis.objectiveValue == plain.objectiveValue)
        // What the model has to be is unchanged: a continuous column is still rejected.
        await expectUnsupported(singleRow([1, 1], upper: 1, integer: [0]), containing: "continuous", strategy: CPSAT(lpPropagator: true))
    }

    /// A rejected model is an exit path like any other (rule L10): `.started`, then
    /// `.finished` exactly once, then the error.
    @Test func rejectedModelsStillFinishTheirEventSequence() async {
        let recorder = EventRecorder()
        var context = SolveContext()
        context.progress = recorder.callback
        for lp in [singleRow([1, 1], upper: 1, integer: [0]), singleRow([1.0 / 3.0, 1], upper: 1)] {
            do {
                _ = try await CPSAT().solve(lp, context: context)
                Issue.record("the model was accepted")
            } catch {}
        }
        do {
            _ = try await CPSAT(lpPropagator: true).solve(singleRow([1, 1], upper: 1, integer: [0]), context: context)
            Issue.record("the model was accepted")
        } catch {}
        let events = await recorder.finish()
        #expect(events.count == 6)
        for pair in stride(from: 0, to: events.count - 1, by: 2) {
            if case .started = events[pair] {} else { Issue.record("event \(pair) is not .started: \(events[pair])") }
            if case .finished(.numericalFailure(let message), _) = events[pair + 1] {
                #expect(message.contains("unsupported"))
            } else {
                Issue.record("event \(pair + 1) is not .finished: \(events[pair + 1])")
            }
        }
    }

    // MARK: Loading

    @Test func clauseRowsAreDetected() throws {
        // x + y − z ≥ 0  ⇔  x ∨ y ∨ ¬z
        let positive = try CPModel(singleRow([1, 1, -1], lower: 0))
        #expect(positive.clauses.count == 1 && positive.constraintCount == 0)
        #expect(Set(positive.clauses[0]) == [
            BoundLiteral(variable: 0, isLower: true, value: 1),
            BoundLiteral(variable: 1, isLower: true, value: 1),
            BoundLiteral(variable: 2, isLower: false, value: 0),
        ])
        // x + y ≤ 1  ⇔  ¬x ∨ ¬y
        let atMostOne = try CPModel(singleRow([1, 1], upper: 1))
        #expect(atMostOne.clauses.count == 1 && atMostOne.constraintCount == 0)
        #expect(Set(atMostOne.clauses[0]) == [
            BoundLiteral(variable: 0, isLower: false, value: 0),
            BoundLiteral(variable: 1, isLower: false, value: 0),
        ])
        // x + y + z ≤ 1 forbids more than one assignment: a linear constraint.
        let cardinality = try CPModel(singleRow([1, 1, 1], upper: 1))
        #expect(cardinality.clauses.isEmpty && cardinality.constraintCount == 1)
        // x + y ≥ 2 likewise.
        let both = try CPModel(singleRow([1, 1], lower: 2))
        #expect(both.clauses.isEmpty && both.constraintCount == 1)
        // A coefficient other than ±1, or a non-binary column, is not a clause.
        #expect(try CPModel(singleRow([2, 1], lower: 1)).clauses.isEmpty)
        #expect(try CPModel(singleRow([1, 1], lower: 1, xu: [1, 2])).clauses.isEmpty)
        // A scaled clause is still a clause: 0.5x + 0.5y ≥ 0.5.
        #expect(try CPModel(singleRow([0.5, 0.5], lower: 0.5)).clauses.count == 1)
    }

    @Test func rowSidesBecomeLessEqualConstraints() throws {
        // 2 ≤ 3x + 2y − z ≤ 6 over x, y, z ∈ [0, 3]: two constraints, the second negated.
        let range = try CPModel(singleRow([3, 2, -1], lower: 2, upper: 6, xu: [3, 3, 3]))
        #expect(range.constraintCount == 2)
        #expect(range.linRHS == [6, -2])
        // Minimum activities over the root domains: −3 for the row, −15 for its negation.
        #expect(range.linMinActivity == [-3, -15])
        // Terms are stored largest first.
        #expect(Array(range.linCoef[0..<3]) == [3, 2, -1])
        // An equality contributes both sides as well.
        #expect(try CPModel(singleRow([3, 2, -1], lower: 4, upper: 4, xu: [3, 3, 3])).constraintCount == 2)
        // The common divisor of the coefficients is divided out and the bounds round inward:
        // 4x + 6y ≤ 9 is 2x + 3y ≤ 4.
        let reduced = try CPModel(singleRow([4, 6], upper: 9, xu: [3, 3]))
        #expect(reduced.linRHS == [4])
        #expect(Set(reduced.linCoef) == [2, 3])
        // 2x + 2y = 3 has no integer solution, and after the division that is plain: 2 ≤ x + y ≤ 1.
        #expect(try CPModel(singleRow([2, 2], lower: 3, upper: 3, xu: [5, 5])).linRHS == [1, -2])
        // A side that can never bind is dropped: 3x + 2y − z ≤ 15 = max activity.
        #expect(try CPModel(singleRow([3, 2, -1], upper: 15, xu: [3, 3, 3])).constraintCount == 0)
    }

    /// The activity of an integer row is an integer, so fractional row bounds round inward.
    @Test func fractionalRowBoundsRoundInward() throws {
        let upper = try CPModel(singleRow([1, 1, 1], upper: 2.5, xu: [3, 3, 3]))
        #expect(upper.linRHS == [2])
        let lower = try CPModel(singleRow([1, 1, 1], lower: 1.2, xu: [3, 3, 3]))
        #expect(lower.linRHS == [-2])              // Σx ≥ 1.2 ⇔ Σx ≥ 2 ⇔ −Σx ≤ −2
        // Noise within 1e-9 of an integer is that integer, not a reason to round a unit away.
        let noisy = try CPModel(singleRow([1, 1, 1], upper: 2.9999999999, xu: [3, 3, 3]))
        #expect(noisy.linRHS == [3])
    }

    @Test func columnBoundsRoundInward() async throws {
        let model = try CPModel(singleRow([1, 1], upper: 100, xl: [0.5, -2.5], xu: [3.7, 2.2]))
        #expect(model.lower == [1, -2])
        #expect(model.upper == [3, 2])
        // No integer between the bounds: infeasible, which is a result, not an error.
        let empty = singleRow([1, 1], upper: 100, xl: [0.2, 0], xu: [0.8, 1])
        #expect(try CPModel(empty).infeasibleReason != nil)
        #expect(try await CPSAT().solve(empty).status == .infeasible)
    }

    @Test func infeasibilityFoundAtLoadIsAResult() async throws {
        // A row that the column bounds can never satisfy.
        let unreachable = singleRow([1, 1], lower: 5)
        #expect(try CPModel(unreachable).infeasibleReason != nil)
        let recorder = EventRecorder()
        var context = SolveContext()
        context.progress = recorder.callback
        let analysis = try await CPSAT(workers: 4).solve(unreachable, context: context)
        #expect(analysis.status == .infeasible)
        #expect(analysis.conflicts == 0)
        let events = await recorder.finish()
        #expect(eventContractHolds(events))
        // An empty row that demands 0 ≥ 1.
        let emptyRow = CompiledLP(
            a: SparseCSC(rows: 1, cols: 2), c: [1, 1], xl: [0, 0], xu: [1, 1], rl: [1], ru: [.infinity],
            integerColumns: [0, 1])
        #expect(try await CPSAT().solve(emptyRow).status == .infeasible)
    }

    @Test func objectiveIsScaledAndKeepsItsConstantOutside() throws {
        let lp = CompiledLP(
            a: SparseCSC(rows: 0, cols: 3), c: [0.5, -0.25, 0], c0: 1.75, xl: [0, 0, 0], xu: [4, 4, 4], rl: [], ru: [],
            integerColumns: [0, 1, 2])
        let model = try CPModel(lp)
        #expect(model.hasObjective)
        // Scaled by 100 to (50, −25), then divided by the common divisor 25.
        #expect(model.objectiveScale == 4)
        #expect(model.objectivePrefersUpper == [false, true, false])
        // Z = 2x − y; the minimization value is Z / 4 + 1.75.
        #expect(model.objectiveValue(of: [2, 4, 1]) == 0)
        #expect(model.objectiveValue(of: [0, 4, 0]) == -4)
        #expect(model.reportedObjective(0) == 1.75)
        #expect(model.reportedObjective(-4) == 0.75)
        // A model without cost has no objective row at all.
        let feasibility = try CPModel(CNFFormula(variables: 3, clauses: [[1, 2, 3]]).compiled())
        #expect(!feasibility.hasObjective && feasibility.objectiveRow == -1)
    }

    @Test func scalingToleratesFloatingPointNoiseOnly() {
        #expect(CPModel.integralScale(for: [1, 2, -3]) == 1)
        #expect(CPModel.integralScale(for: [0.1, 0.2, 0.3]) == 10)        // 0.1 + 0.2 ≠ 0.3, yet each scales exactly
        #expect(CPModel.integralScale(for: [0.25, 1.5]) == 100)
        #expect(CPModel.integralScale(for: [0.000001]) == 1_000_000)
        #expect(CPModel.integralScale(for: [0.0000001]) == nil)
        #expect(CPModel.integralScale(for: [1.0 / 3.0]) == nil)
        // A large value that is not an integer is not mistaken for one.
        #expect(CPModel.integralScale(for: [123_456_789_012.5]) == 10)
        #expect(CPModel.integralScale(for: []) == 1)
    }

    @Test func boundLiteralNegation() {
        let atLeast = BoundLiteral(variable: 3, isLower: true, value: 5)
        #expect(atLeast.negated == BoundLiteral(variable: 3, isLower: false, value: 4))     // ¬[x ≥ 5] ≡ [x ≤ 4]
        #expect(atLeast.negated.negated == atLeast)
    }
}
