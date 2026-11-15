// Specification §11: statuses, analyses and the Decorator, the variable-keyed Solution, the
// strategy protocol's conveniences, events (rules C8 and L10) and the run-level context.

import Testing
import ZTronLPCore

// MARK: - Fixtures

/// A user-defined decorator, as §11.3 describes: conform, store `base`, add fields.
private struct Annotated: AnalysisDecorator {
    let base: SolveRecord
    let note: String
}

/// A decorator over a decorator that overrides one forwarded property and supplies a basis.
private struct Overriding: AnalysisDecorator, BasisProviding {
    let base: Annotated
    let finalBasis: Basis?
    var warnings: [String] { base.warnings + ["from the outer decorator"] }
}

/// A strategy that answers every problem with a prepared record.
private struct Stub: SolverStrategy {
    var record = SolveRecord(status: .optimal, objectiveValue: 1)

    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SolveRecord {
        var answer = record
        answer.primal = (0..<problem.n).map { Double($0 + 1) }
        context.progress?(.started(engine: engineName, rows: problem.m, columns: problem.n, nonzeros: problem.nnz))
        context.progress?(.finished(status: answer.status, seconds: 0))
        return answer
    }
}

/// Collects what a `@Sendable` callback receives, without shared mutable state.
private struct Recorder<Element: Sendable> {
    let stream: AsyncStream<Element>
    let continuation: AsyncStream<Element>.Continuation

    init() {
        var created: AsyncStream<Element>.Continuation?
        stream = AsyncStream<Element> { created = $0 }
        continuation = created!
    }

    var record: @Sendable (Element) -> Void {
        let continuation = continuation
        return { continuation.yield($0) }
    }

    /// Ends the recording and returns everything recorded, in order.
    func finish() async -> [Element] {
        continuation.finish()
        var all: [Element] = []
        for await element in stream { all.append(element) }
        return all
    }
}

@Suite("Solve-side types")
struct SolveTypesTests {
    // MARK: Status

    @Test func statusHelpers() {
        let statuses: [(SolveStatus, optimal: Bool, solution: Bool, reason: StopReason?)] = [
            (.optimal, true, true, nil),
            (.infeasible, false, false, nil),
            (.unbounded, false, false, nil),
            (.infeasibleOrUnbounded, false, false, nil),
            (.feasible(stoppedBy: .timeLimit), false, true, .timeLimit),
            (.feasible(stoppedBy: .gapReached), false, true, .gapReached),
            (.noSolution(stoppedBy: .cancelled), false, false, .cancelled),
            (.noSolution(stoppedBy: .memoryBudget), false, false, .memoryBudget),
            (.numericalFailure("three residual failures"), false, false, nil),
        ]
        for (status, optimal, solution, reason) in statuses {
            #expect(status.isOptimal == optimal, "\(status)")
            #expect(status.hasSolution == solution, "\(status)")
            #expect(status.stopReason == reason, "\(status)")
        }
        #expect(SolveStatus.feasible(stoppedBy: .timeLimit) != .feasible(stoppedBy: .cancelled))
        #expect(SolveStatus.feasible(stoppedBy: .nodeLimit) != .noSolution(stoppedBy: .nodeLimit))
        #expect(SolveStatus.numericalFailure("a") != .numericalFailure("b"))
        #expect(Set<SolveStatus>([.optimal, .optimal, .infeasible]).count == 2)
        let reasons: Set<StopReason> = [.timeLimit, .iterationLimit, .nodeLimit, .cancelled, .gapReached, .memoryBudget]
        #expect(reasons.count == 6)
    }

    @Test func tolerancesHaveTheDefaultsOfTheSpecification() {
        // §6.5.
        let t = Tolerances.default
        #expect(t.primalFeasibility == 1e-7)
        #expect(t.dualFeasibility == 1e-7)
        #expect(t.pivot == 1e-7)
        #expect(t.harris == 1e-9)
        #expect(t.dropZero == 1e-14)
        #expect(t.integrality == 1e-6)
        #expect(t.mipRelativeGap == 1e-4)
        #expect(t.mipAbsoluteGap == 1e-6)
        #expect(t.ipmResidual == 1e-8)
        #expect(t == Tolerances())
        var changed = Tolerances()
        changed.pivot = 1e-9
        #expect(changed != .default)
    }

    // MARK: Records and decorators

    @Test func aRecordStoresEveryRequirement() {
        let empty = SolveRecord(status: .infeasible)
        #expect(empty.objectiveValue == nil && empty.bound == nil && empty.primal == nil)
        #expect(empty.dual == nil && empty.reducedCosts == nil && empty.seconds == 0 && empty.warnings.isEmpty)
        let full = SolveRecord(
            status: .optimal, objectiveValue: 7, bound: 7, primal: [1, 2], dual: [3], reducedCosts: [0, 0, 3],
            seconds: 0.25, warnings: ["w"])
        #expect(full.status == .optimal && full.objectiveValue == 7 && full.bound == 7)
        #expect(full.primal == [1, 2] && full.dual == [3] && full.reducedCosts == [0, 0, 3])
        #expect(full.seconds == 0.25 && full.warnings == ["w"])
    }

    @Test func aDecoratorForwardsItsBaseAndMayOverride() {
        let record = SolveRecord(
            status: .feasible(stoppedBy: .timeLimit), objectiveValue: 12, bound: 10, primal: [1, 2, 3], dual: [4],
            reducedCosts: [0, 1, 0, 4], seconds: 1.5, warnings: ["inner"])
        let annotated = Annotated(base: record, note: "hello")
        #expect(annotated.status == record.status)
        #expect(annotated.objectiveValue == 12 && annotated.bound == 10)
        #expect(annotated.primal == [1, 2, 3] && annotated.dual == [4] && annotated.reducedCosts == [0, 1, 0, 4])
        #expect(annotated.seconds == 1.5 && annotated.warnings == ["inner"])
        #expect(annotated.note == "hello")

        // Decorators stack, and a decorator may override what it forwards.
        let basis = Basis(status: [.basic, .atLower], basic: [0])
        let outer = Overriding(base: annotated, finalBasis: basis)
        #expect(outer.status == record.status && outer.primal == [1, 2, 3] && outer.seconds == 1.5)
        #expect(outer.warnings == ["inner", "from the outer decorator"])
        #expect(outer.base.note == "hello")

        // Read through the interface, the override is what a caller sees.
        func warnings(of analysis: some SolutionAnalysis) -> [String] { analysis.warnings }
        #expect(warnings(of: outer) == ["inner", "from the outer decorator"])
        #expect(warnings(of: annotated) == ["inner"])
    }

    @Test func typeErasureRecoversTheConcreteAnalysis() {
        let record = SolveRecord(status: .optimal, objectiveValue: 3, bound: 3, primal: [1], dual: [], reducedCosts: [0], seconds: 2, warnings: ["w"])
        let annotated = Annotated(base: record, note: "n")
        let erased = AnySolutionAnalysis(annotated, engine: "Engine A")
        #expect(erased.engine == "Engine A")
        #expect(erased.status == .optimal && erased.objectiveValue == 3 && erased.bound == 3)
        #expect(erased.primal == [1] && erased.dual == [] && erased.reducedCosts == [0])
        #expect(erased.seconds == 2 && erased.warnings == ["w"])
        #expect(erased.unwrap(as: Annotated.self)?.note == "n")
        #expect(erased.unwrap(as: SolveRecord.self) == nil)          // the wrapped value is the decorator
        let inferred: Annotated? = erased.unwrap()
        #expect(inferred?.note == "n")
        #expect(erased.finalBasis == nil)                             // Annotated supplies no basis

        // Erasing an erased analysis does not nest: one `unwrap` still reaches the concrete type.
        let twice = AnySolutionAnalysis(erased, engine: "Engine B")
        #expect(twice.engine == "Engine B")
        #expect(twice.unwrap(as: Annotated.self)?.note == "n")
        #expect(twice.unwrap(as: AnySolutionAnalysis.self) == nil)

        // A basis is reachable through the erasure when the concrete analysis has one.
        let basis = Basis(status: [.basic, .atLower], basic: [0])
        let withBasis = AnySolutionAnalysis(Overriding(base: annotated, finalBasis: basis), engine: "C")
        #expect(withBasis.finalBasis == basis)
        #expect(withBasis.warnings == ["w", "from the outer decorator"])
    }

    // MARK: Solution

    /// min 2x + 3y  s.t.  need: x + y ≥ rhs,  lo: 2x ≥ 6 (lowered to x ≥ 3).
    private static func compiledExample(rhs: Double, maximize: Bool = false) throws -> CompiledModel<XY> {
        var model = LPModel<XY>()
        if maximize {
            model.setObjective(.maximize, -2 * XY.x - 3 * XY.y)
        } else {
            model.setObjective(.minimize, 2 * XY.x + 3 * XY.y)
        }
        model.add {
            (XY.x + XY.y >= rhs).named("need")
            (2 * XY.x >= 6).named("lo")
            (XY.y - XY.y <= 1).named("trivial")
        }
        return try model.compile()
    }

    @Test func valuesAndReducedCostsAreKeyedByVariable() throws {
        // rhs = 4: x = 4, y = 0, objective 8; the row is active with dual 2, d_y = 3 − 2 = 1.
        let compiled = try Self.compiledExample(rhs: 4)
        let record = SolveRecord(status: .optimal, objectiveValue: 8, bound: 8, primal: [4, 0], dual: [2], reducedCosts: [0, 1, 2])
        let solution = Solution(analysis: record, compiled: compiled)
        #expect(solution.status == .optimal && solution.status.isOptimal)
        #expect(solution.objectiveValue == 8)
        #expect(solution.value(of: .x) == 4 && solution.value(of: .y) == 0)
        #expect(solution.value(of: .z(9)) == 0)                       // absent from the model
        #expect(solution.values(where: { _ in true }) == [.x: 4, .y: 0])
        #expect(solution.values(where: { $0 == .x }) == [.x: 4])
        #expect(solution.reducedCost(of: .y) == 1 && solution.reducedCost(of: .x) == 0)
        #expect(solution.reducedCost(of: .z(9)) == 0)
        #expect(solution.analysis.dual == [2])
        #expect(solution.compiled.lp == compiled.lp)
    }

    @Test func dualsOfRowsAndOfLoweredSingletons() throws {
        // rhs = 4: the row is active (dual 2); x = 4 is strictly above the bound from `lo`.
        let slack = Solution(
            analysis: SolveRecord(status: .optimal, objectiveValue: 8, primal: [4, 0], dual: [2], reducedCosts: [0, 1, 2]),
            compiled: try Self.compiledExample(rhs: 4))
        #expect(slack.dual(ofConstraintNamed: "need") == 2)
        #expect(slack.dual(ofConstraintNamed: "lo") == 0)
        #expect(slack.dual(ofConstraintNamed: "trivial") == 0)       // a constraint with no variables
        #expect(slack.dual(ofConstraintNamed: "no such constraint") == nil)

        // rhs = 2: x = 3 rests on the bound from `lo`, y = 0, objective 6. d_x = 2, and `lo`
        // (2x ≥ 6) takes it: 2 / 2 = 1 — the objective is 2·(6/2), so ∂/∂6 = 1.
        let active = Solution(
            analysis: SolveRecord(status: .optimal, objectiveValue: 6, primal: [3, 0], dual: [0], reducedCosts: [2, 3, 0]),
            compiled: try Self.compiledExample(rhs: 2))
        #expect(active.dual(ofConstraintNamed: "need") == 0)
        #expect(active.dual(ofConstraintNamed: "lo") == 1)

        // The same problem written as a maximization reports the negated sensitivities.
        let maximized = Solution(
            analysis: SolveRecord(status: .optimal, objectiveValue: -6, primal: [3, 0], dual: [0], reducedCosts: [-2, -3, 0]),
            compiled: try Self.compiledExample(rhs: 2, maximize: true))
        #expect(maximized.dual(ofConstraintNamed: "lo") == -1)
    }

    @Test func loweredSingletonsOnTheUpperSideAndWithNegativeCoefficients() throws {
        // min −x  s.t.  cap: 4x ≤ 10.   x = 2.5, d = −1; dual = −1/4 (objective = −10/4).
        let cap = try LPModel<XY>().minimizing(-XY.x).subjectTo((4 * XY.x <= 10).named("cap")).compile()
        #expect(cap.lp.xu == [2.5] && cap.lp.m == 0)
        let capped = Solution(
            analysis: SolveRecord(status: .optimal, objectiveValue: -2.5, primal: [2.5], dual: [], reducedCosts: [-1]),
            compiled: cap)
        #expect(capped.dual(ofConstraintNamed: "cap") == -0.25)

        // min x  s.t.  neg: −2x ≤ −6  (x ≥ 3).   x = 3, d = 1; dual = 1/(−2) (objective = −(−6)/2).
        let neg = try LPModel<XY>().minimizing(XY.x).subjectTo((-2 * XY.x <= -6).named("neg")).compile()
        #expect(neg.lp.xl == [3])
        let negated = Solution(
            analysis: SolveRecord(status: .optimal, objectiveValue: 3, primal: [3], dual: [], reducedCosts: [1]),
            compiled: neg)
        #expect(negated.dual(ofConstraintNamed: "neg") == -0.5)
    }

    @Test func aSolutionWithoutValuesAnswersWithZeroAndNil() throws {
        let compiled = try Self.compiledExample(rhs: 4)
        let infeasible = Solution(analysis: SolveRecord(status: .infeasible), compiled: compiled)
        #expect(!infeasible.status.hasSolution && infeasible.objectiveValue == nil)
        #expect(infeasible.value(of: .x) == 0)
        #expect(infeasible.values(where: { _ in true }).isEmpty)
        #expect(infeasible.reducedCost(of: .x) == 0)
        #expect(infeasible.dual(ofConstraintNamed: "need") == nil)
        #expect(infeasible.dual(ofConstraintNamed: "lo") == nil)

        // A MIP result has a primal solution but no duals.
        let mip = Solution(analysis: SolveRecord(status: .optimal, objectiveValue: 8, primal: [4, 0]), compiled: compiled)
        #expect(mip.value(of: .x) == 4)
        #expect(mip.dual(ofConstraintNamed: "need") == nil && mip.dual(ofConstraintNamed: "lo") == nil)
        #expect(mip.reducedCost(of: .x) == 0)
    }

    // MARK: Strategy conveniences

    @Test func theProtocolSuppliesTheDefaultContextAndTheTypedSolve() async throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + XY.y + XY.z(0))
            .subjectTo(XY.x + XY.y + XY.z(0) >= 1)
        let compiled = try model.compile()
        let stub = Stub()
        #expect(stub.engineName == "Stub")

        let analysis = try await stub.solve(compiled.lp)                 // default context
        #expect(analysis.primal == [1, 2, 3])

        let solution = try await stub.solve(model)                       // compiles, solves, keys by variable
        #expect(solution.value(of: .y) == 2 && solution.value(of: .z(0)) == 3)
        #expect(solution.compiled.lp == compiled.lp)
        #expect(solution.analysis.status == .optimal)

        // The context reaches the strategy.
        let recorder = Recorder<SolverEvent>()
        var context = SolveContext()
        context.progress = recorder.record
        _ = try await stub.solve(model, context: context)
        let events = await recorder.finish()
        #expect(events == [.started(engine: "Stub", rows: 1, columns: 3, nonzeros: 3), .finished(status: .optimal, seconds: 0)])

        // A model that does not compile throws the compile error, not something else.
        let broken = LPModel<XY>().subjectTo(LinearExpr<XY>(0) <= -1)
        await #expect(throws: SolverError.self) { _ = try await stub.solve(broken) }
    }

    // MARK: Context

    @Test func aFreshContextHasTheDocumentedDefaults() {
        let context = SolveContext()
        #expect(context.timeLimit == nil && context.threads == nil && context.memoryBudgetBytes == nil)
        #expect(context.metal == .automatic)
        #expect(context.progress == nil && context.accelerator == nil)
        if case .none = context.warmStart {} else { Issue.record("the default warm start is not .none") }
        #expect(context.resolvedThreads >= 1)

        var limited = SolveContext()
        limited.threads = 3
        #expect(limited.resolvedThreads == 3)
        limited.threads = 0
        #expect(limited.resolvedThreads == 1)
        limited.threads = -4
        #expect(limited.resolvedThreads == 1)
        requireSendable(SolveContext.self)
        requireSendable(WarmStart.self)
    }

    @Test func nestedAndSilencedContexts() async {
        let recorder = Recorder<SolverEvent>()
        var context = SolveContext()
        context.progress = recorder.record
        context.timeLimit = 9
        context.threads = 2

        // A nested solve reports through the same listener, minus the start and the finish
        // that only the enclosing solve may report.
        let nested = context.nested()
        #expect(nested.timeLimit == 9 && nested.threads == 2)
        nested.progress?(.started(engine: "inner", rows: 1, columns: 1, nonzeros: 1))
        nested.progress?(.simplexIteration(iteration: 100, objective: 1, infeasibility: 0, phase: 2))
        nested.progress?(.warning("inner warning"))
        nested.progress?(.finished(status: .optimal, seconds: 1))
        context.progress?(.finished(status: .infeasible, seconds: 2))

        let silenced = context.silenced()
        #expect(silenced.progress == nil && silenced.timeLimit == 9)
        #expect(SolveContext().nested().progress == nil)

        let events = await recorder.finish()
        #expect(events == [
            .simplexIteration(iteration: 100, objective: 1, infeasibility: 0, phase: 2),
            .warning("inner warning"),
            .finished(status: .infeasible, seconds: 2),
        ])
    }

    // MARK: Events — rule L10

    @Test func nothingIsDeliveredAfterFinished() async {
        let recorder = Recorder<SolverEvent>()
        let sink = EventSink(recorder.record)
        #expect(sink.hasListener)
        await sink.emit(.started(engine: "E", rows: 2, columns: 3, nonzeros: 4))
        await sink.warn("first")
        await sink.emit(.nodes(processed: 1, open: 2))
        #expect(await !sink.isFinished)
        await sink.finish(status: .optimal, seconds: 1)
        #expect(await sink.isFinished)
        // Everything after the finish is dropped, including a second finish.
        await sink.warn("late")
        await sink.emit(.nodes(processed: 9, open: 9))
        await sink.finish(status: .infeasible, seconds: 2)
        await sink.emit(.finished(status: .unbounded, seconds: 3))

        #expect(await sink.warnings == ["first"])
        let events = await recorder.finish()
        #expect(events == [
            .started(engine: "E", rows: 2, columns: 3, nonzeros: 4),
            .warning("first"),
            .nodes(processed: 1, open: 2),
            .finished(status: .optimal, seconds: 1),
        ])
    }

    @Test func finishedIsLastAndUniqueUnderConcurrentEmitters() async {
        for round in 0..<20 {
            let recorder = Recorder<SolverEvent>()
            let sink = EventSink(recorder.record)
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<8 {
                    group.addTask {
                        for i in 0..<200 {
                            await sink.emit(.nodes(processed: worker, open: i))
                            // Several workers believe they are the one to end the solve.
                            if i == 60 + 15 * worker + round { await sink.finish(status: .optimal, seconds: Double(worker)) }
                        }
                    }
                }
            }
            let events = await recorder.finish()
            #expect(events.filter(\.isFinished).count == 1, "round \(round)")
            #expect(events.last?.isFinished == true, "round \(round)")
            #expect(events.count < 8 * 200 + 1, "round \(round)")       // the tail really was dropped
        }
    }

    @Test func aSinkWithoutAListenerStillTracksItsState() async {
        let sink = EventSink(nil)
        #expect(!sink.hasListener)
        await sink.warn("kept")
        await sink.finish(status: .optimal, seconds: 0)
        await sink.warn("dropped")
        #expect(await sink.warnings == ["kept"])
        #expect(await sink.isFinished)
    }

    @Test func eventsCompareByValue() {
        #expect(SolverEvent.finished(status: .optimal, seconds: 1).isFinished)
        #expect(!SolverEvent.warning("w").isFinished)
        #expect(SolverEvent.newIncumbent(objective: 1, node: 2, source: "rounding") == .newIncumbent(objective: 1, node: 2, source: "rounding"))
        #expect(SolverEvent.boundImproved(bound: 1, gap: 0.5) != .boundImproved(bound: 1, gap: 0.25))
        #expect(SolverEvent.ipmIteration(iteration: 1, mu: 1, primalResidual: 1, dualResidual: 1) != .presolved(rows: 1, columns: 1, removedRows: 0, removedColumns: 0))
        requireSendable(SolverEvent.self)
    }

    // MARK: Events — rule C8

    @Test func aConsumerThatNeverReadsCannotBlockOrGrowMemory() async throws {
        var context = SolveContext()
        let stream = context.makeEventStream()
        let progress = try #require(context.progress)
        // Nobody reads while 100,000 events are produced: the producer must not block, and
        // the stream keeps only the newest 256.
        for i in 0..<100_000 {
            progress(.simplexIteration(iteration: i, objective: 0, infeasibility: 0, phase: 2))
        }
        progress(.finished(status: .optimal, seconds: 1))
        progress(.warning("after the end"))                              // ignored: the stream has ended

        var received: [SolverEvent] = []
        for await event in stream { received.append(event) }             // ends by itself after .finished
        #expect(received.count == 256)
        #expect(received.last == .finished(status: .optimal, seconds: 1))
        #expect(received.filter(\.isFinished).count == 1)
        // The newest events survived, in order.
        #expect(received.first == .simplexIteration(iteration: 100_000 - 255, objective: 0, infeasibility: 0, phase: 2))
        #expect(received[254] == .simplexIteration(iteration: 99_999, objective: 0, infeasibility: 0, phase: 2))
    }

    @Test func theStreamKeepsAnEarlierCallbackAndDeliversInOrder() async {
        let recorder = Recorder<SolverEvent>()
        var context = SolveContext()
        context.progress = recorder.record
        let stream = context.makeEventStream()
        let consumer = Task { () -> [SolverEvent] in
            var seen: [SolverEvent] = []
            for await event in stream { seen.append(event) }
            return seen
        }
        let sent: [SolverEvent] = [
            .started(engine: "E", rows: 1, columns: 1, nonzeros: 1),
            .presolved(rows: 1, columns: 1, removedRows: 0, removedColumns: 0),
            .warning("w"),
            .finished(status: .optimal, seconds: 0.5),
        ]
        for event in sent { context.progress?(event) }
        #expect(await consumer.value == sent)
        #expect(await recorder.finish() == sent)
    }

    // MARK: Basis and bound changes

    @Test func theAllLogicalBasis() {
        let lp = denseLP(
            rows: [[1, 1, 1, 1, 1], [1, 0, 0, 0, 1]], rl: [0, 0], ru: [1, 1], c: [0, 0, 0, 0, 0],
            xl: [0, -inf, -inf, 2, -5], xu: [inf, 4, inf, 2, 3])
        let basis = Basis.allLogical(for: lp)
        #expect(basis.status == [.atLower, .atUpper, .free, .fixed, .atUpper, .basic, .basic])
        #expect(basis.basic == [5, 6])

        #expect(Basis.nonbasicStatus(lower: 1, upper: 1) == .fixed)
        #expect(Basis.nonbasicStatus(lower: 0, upper: .infinity) == .atLower)
        #expect(Basis.nonbasicStatus(lower: -.infinity, upper: 0) == .atUpper)
        #expect(Basis.nonbasicStatus(lower: -.infinity, upper: .infinity) == .free)
        // A boxed column starts at the bound nearer to zero.
        #expect(Basis.nonbasicStatus(lower: -1, upper: 5) == .atLower)
        #expect(Basis.nonbasicStatus(lower: -5, upper: 3) == .atUpper)
        #expect(Basis.nonbasicStatus(lower: -2, upper: 2) == .atLower)
        #expect(Basis(status: [.basic], basic: [0]) == Basis(status: [.basic], basic: [0]))
        #expect(BasisStatus.basic.rawValue == 0 && BasisStatus.fixed.rawValue == 4)
    }

    @Test func boundChangesAndProblemCopies() {
        let lp = denseLP(
            rows: [[1, 2, 3]], rl: [1], ru: [9], c: [1, -2, 3], xl: [0, 0, 0], xu: [5, 5, 5], c0: 4,
            sense: .maximize, integer: [1])
        let changed = lp.applying([
            BoundChange(column: 1, lower: 2, upper: 2),
            BoundChange(column: 2, lower: 1, upper: 4),
        ])
        #expect(changed.xl == [0, 2, 1] && changed.xu == [5, 2, 4])
        #expect(changed.a == lp.a && changed.c == lp.c && changed.integerColumns == lp.integerColumns)
        #expect(lp.applying([]) == lp)
        #expect(lp.xl == [0, 0, 0])                                      // the original is untouched
        #expect(BoundChange(column: 1, lower: 0, upper: 1) == BoundChange(column: 1, lower: 0, upper: 1))

        let rebounded = lp.withColumnBounds(xl: [1, 1, 1], xu: [2, 2, 2])
        #expect(rebounded.xl == [1, 1, 1] && rebounded.rl == lp.rl && rebounded.aT == lp.aT)
        let rerowed = lp.withRowBounds(rl: [-inf], ru: [0])
        #expect(rerowed.rl == [-inf] && rerowed.ru == [0] && rerowed.xu == lp.xu)

        // `withObjective` takes coefficients in the model's own sense.
        let reobjective = lp.withObjective([1, 1, 0], constant: 2)
        #expect(reobjective.c == [-1, -1, 0] && reobjective.c0 == -2 && reobjective.sense == .maximize)
        #expect(reobjective.objective(at: [1, 1, 1]) == 4)
        #expect(lp.reportedObjective(5) == -5)

        let relaxed = lp.relaxed()
        #expect(relaxed.integerColumns.isEmpty && relaxed.xu == lp.xu && lp.hasIntegerColumns)
        #expect(lp.integerMask() == [false, true, false])

        #expect(lp.rowActivity([1, 1, 1]) == [6])
        let violation = lp.maxViolation(at: [6, 0, 2])                   // x₀ above its bound, row above 9
        #expect(violation.bounds == 1 && violation.rows == 3)
    }

    // MARK: Sparse storage and names

    @Test func sparseMatrixFromTriplets() {
        // Duplicates are summed, exact zeros (also after summing) are kept out, rows are sorted.
        let a = SparseCSC.fromTriplets(rows: 3, cols: 3, [
            (row: 2, col: 0, value: 5), (row: 0, col: 0, value: 1), (row: 2, col: 0, value: -2),
            (row: 1, col: 1, value: 4), (row: 1, col: 1, value: -4), (row: 0, col: 2, value: 7),
            (row: 1, col: 2, value: 0),
        ])
        #expect(a.rows == 3 && a.cols == 3 && a.nnz == 3)
        #expect(a.colStart == [0, 2, 2, 3])
        #expect(a.rowIndex == [0, 2, 0])
        #expect(a.values == [1, 3, 7])
        #expect(a[0, 0] == 1 && a[2, 0] == 3 && a[1, 0] == 0 && a[1, 1] == 0 && a[0, 2] == 7)
        #expect(a.count(inColumn: 0) == 2 && a.count(inColumn: 1) == 0)
        #expect(a.range(ofColumn: 2) == 2..<3)
        #expect(a.multiply([1, 1, 1]) == [8, 0, 3])
        #expect(a.multiplyTranspose([1, 1, 1]) == [4, 0, 7])

        let t = a.transposed()
        #expect(t.rows == 3 && t.cols == 3 && t.nnz == 3)
        #expect(t[0, 0] == 1 && t[0, 2] == 3 && t[2, 0] == 7)
        #expect(t.transposed() == a)
        let empty = SparseCSC(rows: 2, cols: 4)
        #expect(empty.nnz == 0 && empty.colStart == [0, 0, 0, 0, 0] && empty.transposed().cols == 2)
    }

    @Test func namesAreMaterializedLazilyAndCompareByValue() {
        let eager = LPNames(columns: ["a", "b"], rows: ["r"])
        let lazy = LPNames(lazyColumns: { ["a", "b"] }, lazyRows: { ["r"] })
        #expect(eager == lazy)
        #expect(lazy.columns == ["a", "b"] && lazy.rows == ["r"])
        #expect(lazy.column(1) == "b" && lazy.row(0) == "r")
        #expect(eager != LPNames(columns: ["a", "c"], rows: ["r"]))
        let defaults = LPNames.default(columns: 3, rows: 2)
        #expect(defaults.columns == ["x1", "x2", "x3"] && defaults.rows == ["c1", "c2"])
        // A problem built without names gets the defaults.
        let lp = denseLP(rows: [[1, 1]], rl: [0], ru: [1], c: [1, 1], xl: [0, 0], xu: [1, 1])
        #expect(lp.names == LPNames.default(columns: 2, rows: 1))
    }

    @Test func lazyNamesAreSafeUnderConcurrentFirstUse() async {
        // Many first readers at once: every one of them sees the same, complete table.
        for round in 0..<20 {
            let shared = LPNames(lazyColumns: { (0..<2_000).map { "v\($0)" } }, lazyRows: { ["only"] })
            let seen = await withTaskGroup(of: Bool.self) { group -> Int in
                for _ in 0..<16 {
                    group.addTask { shared.columns.count == 2_000 && shared.column(1_999) == "v1999" && shared.rows == ["only"] }
                }
                var good = 0
                for await ok in group where ok { good += 1 }
                return good
            }
            #expect(seen == 16, "round \(round)")
        }
    }
}
