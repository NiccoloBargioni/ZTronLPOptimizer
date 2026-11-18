import Testing
import ZTronLPCore
import ZTronLPNumerics
@testable import ZTronLPInteriorPoint
import ZTronLPSimplex
import ZTronLPTestSupport

private let inf = Double.infinity

private func denseLP(
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

/// Day-4 gate (§15): the interior point converges in at most 40 iterations on every netlib
/// instance, crossover-lite costs at most 20% of a cold primal solve, and the engines agree.
@Suite struct NetlibInteriorPointTests {
    @Test(arguments: ReferenceValues.netlib)
    func convergesWithinFortyIterations(_ instance: ReferenceInstance) async throws {
        let lp = try NetlibFixtures.load(instance.name)
        let analysis = try await InteriorPoint(crossover: .none).solve(lp)
        #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status)")
        #expect(analysis.iterations <= 40, "\(instance.name): \(analysis.iterations) iterations")
        let objective = try #require(analysis.objectiveValue)
        #expect(
            ReferenceValues.relativeError(objective, reference: instance.optimalObjective) <= ReferenceValues.relativeTolerance,
            "\(instance.name): \(objective) vs \(instance.optimalObjective)")
        #expect(analysis.primalResidual <= 1e-8 && analysis.dualResidual <= 1e-8)
        #expect(analysis.crossover == nil && analysis.finalBasis == nil)
        let violation = lp.maxViolation(at: try #require(analysis.primal))
        #expect(violation.bounds <= 1e-5 * (1 + abs(objective)) && violation.rows <= 1e-5 * (1 + abs(objective)))
    }

    @Test(arguments: ReferenceValues.netlib)
    func crossoverLiteReachesAVertexCheaply(_ instance: ReferenceInstance) async throws {
        let lp = try NetlibFixtures.load(instance.name)
        let analysis = try await InteriorPoint(crossover: .lite).solve(lp)
        #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status)")
        let crossover = try #require(analysis.crossover)
        #expect(crossover.status == .optimal)
        let objective = try #require(analysis.objectiveValue)
        #expect(ReferenceValues.relativeError(objective, reference: instance.optimalObjective) <= ReferenceValues.relativeTolerance)
        // A vertex: the basis is complete and reusable.
        #expect(analysis.finalBasis?.basic.count == lp.m)
        let violation = lp.maxViolation(at: try #require(analysis.primal))
        #expect(violation.bounds <= 1e-6 && violation.rows <= 1e-6)

        // §8.4 / §14.2: crossover-lite takes at most 20% of the cold-start primal iterations.
        let cold = try await Simplex(.primal).solve(lp)
        let allowance = max(10, cold.iterations / 5)
        #expect(crossover.iterations <= allowance, "\(instance.name): crossover \(crossover.iterations) vs cold primal \(cold.iterations)")

        // Three engines agree to 1e-7 relative.
        let dual = try await Simplex(.dual).solve(lp)
        let scale = max(1, abs(cold.objectiveValue!))
        #expect(abs(objective - cold.objectiveValue!) <= 1e-7 * scale)
        #expect(abs(dual.objectiveValue! - cold.objectiveValue!) <= 1e-7 * scale)
    }
}

@Suite struct InteriorPointTests {
    @Test func textbookProblemWithDualsAndBounds() async throws {
        // max 3x + 5y  s.t.  x ≤ 4, 2y ≤ 12, 3x + 2y ≤ 18  → (2, 6), value 36, duals 0, 1.5, 1.
        let lp = denseLP(c: [3, 5], rows: [[1, 0], [0, 2], [3, 2]], rl: [-inf, -inf, -inf], ru: [4, 12, 18], sense: .maximize)
        for crossover in [InteriorPoint.Crossover.none, .lite] {
            for presolve in [true, false] {
                let analysis = try await InteriorPoint(crossover: crossover, presolve: presolve).solve(lp)
                #expect(analysis.status == .optimal)
                #expect(abs(analysis.objectiveValue! - 36) < 1e-6)
                #expect(abs(analysis.primal![0] - 2) < 1e-5 && abs(analysis.primal![1] - 6) < 1e-5)
                let y = analysis.dual!
                #expect(abs(y[0]) < 1e-5 && abs(y[1] - 1.5) < 1e-5 && abs(y[2] - 1) < 1e-5)
            }
        }
    }

    @Test func freeColumnsRangesAndUpperBounds() async throws {
        let lp = denseLP(
            c: [1, -2, 1], rows: [[1, 1, 0], [1, -1, 0], [0, 1, 1]], rl: [2, 1, -5], ru: [6, 1, inf],
            xl: [-1, -inf, 0], xu: [4, inf, 3])
        for presolve in [true, false] {
            let analysis = try await InteriorPoint(crossover: .none, presolve: presolve).solve(lp)
            #expect(analysis.status == .optimal)
            #expect(abs(analysis.objectiveValue! - (-1.5)) < 1e-6)
            #expect(abs(analysis.primal![0] - 3.5) < 1e-5 && abs(analysis.primal![1] - 2.5) < 1e-5)
        }
    }

    @Test func constructedOptima() async throws {
        for instance in InstanceGenerator.constructedSuite(count: 60, seed: 303, maxSize: (50, 100)) {
            let analysis = try await InteriorPoint(crossover: .lite).solve(instance.lp)
            #expect(analysis.status == .optimal, "seed \(instance.seed): \(analysis.status)")
            guard let objective = analysis.objectiveValue else { continue }
            #expect(abs(objective - instance.objective) <= 1e-6 * max(1, abs(instance.objective)), "seed \(instance.seed): \(objective) vs \(instance.objective)")
            #expect(analysis.iterations <= 60)
        }
    }

    @Test func sparsePathAgreesWithTheSimplex() async throws {
        // More than 300 rows and a sparse normal matrix: the Accelerate sparse Cholesky path.
        let lp = InstanceGenerator.transport(sources: 40, sinks: 320, seed: 4)
        let simplex = try await Simplex(.dual).solve(lp)
        let analysis = try await InteriorPoint(crossover: .lite).solve(lp)
        #expect(simplex.status == .optimal && analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - simplex.objectiveValue!) <= 1e-7 * max(1, abs(simplex.objectiveValue!)))
        let interior = try await InteriorPoint(crossover: .none).solve(lp)
        #expect(interior.status == .optimal)
        #expect(abs(interior.objectiveValue! - simplex.objectiveValue!) <= 1e-6 * max(1, abs(simplex.objectiveValue!)))
    }

    @Test func crossoverLeavesAnOptimalBasisOnADegenerateFace() async throws {
        // An assignment problem with tied costs: every vertex is degenerate and the optimal
        // face is not a point, so the interior point ends in the middle of it and the basis
        // of the vertex the crash reaches holds columns the duals pin to zero. The dual push
        // (§8.4) carries the interior duals onto that basis; the proof that what comes out is
        // an optimal basis is that both simplex methods accept it without a single pivot.
        // (The pivoting path of the push is exercised by the netlib instances above: degen2,
        // share2b, blend, sc105 and stocfor1 all need it.)
        let size = 12
        var c: [Double] = []
        var rows = [[Double]](repeating: [Double](repeating: 0, count: size * size), count: 2 * size)
        for i in 0..<size {
            for j in 0..<size {
                c.append(Double((i * 7 + j * 3) % 4))
                rows[i][i * size + j] = 1
                rows[size + j][i * size + j] = 1
            }
        }
        let ones = [Double](repeating: 1, count: 2 * size)
        let lp = denseLP(c: c, rows: rows, rl: ones, ru: ones)
        let reference = try await Simplex(.primal).solve(lp)
        #expect(reference.status == .optimal)

        let analysis = try await InteriorPoint(crossover: .lite).solve(lp)
        #expect(analysis.status == .optimal)
        let crossover = try #require(analysis.crossover)
        #expect(crossover.status == .optimal)
        #expect(abs(analysis.objectiveValue! - reference.objectiveValue!) <= 1e-7)
        // The cost of the whole crossover stays below a cold solve's.
        #expect(crossover.iterations < reference.iterations, "crossover \(crossover.iterations) vs cold \(reference.iterations)")

        let basis = try #require(analysis.finalBasis)
        #expect(basis.basic.count == lp.m)
        var context = SolveContext()
        context.warmStart = .basis(basis)
        for method in [Simplex.Method.primal, .dual] {
            let warm = try await Simplex(method, presolve: false).solve(lp, context: context)
            #expect(warm.status == .optimal)
            #expect(warm.iterations == 0, "\(method): \(warm.iterations) iterations from the crossover basis")
            #expect(abs(warm.objectiveValue! - reference.objectiveValue!) <= 1e-7)
        }
    }

    @Test func infeasibleAndUnboundedAreReportedWithoutLooping() async throws {
        let infeasible = denseLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 3], ru: [1, inf])
        let first = try await InteriorPoint(presolve: false).solve(infeasible)
        #expect(first.status == .infeasibleOrUnbounded || first.status == .noSolution(stoppedBy: .iterationLimit) || first.status == .infeasible)
        #expect(first.iterations <= 200)
        let unbounded = denseLP(c: [-1, -1], rows: [[1, -1], [-1, 1]], rl: [-inf, -inf], ru: [1, 2])
        let second = try await InteriorPoint(presolve: false).solve(unbounded)
        #expect(second.status == .infeasibleOrUnbounded || second.status == .noSolution(stoppedBy: .iterationLimit))
        #expect(!second.status.hasSolution)
    }

    @Test func iterationCapIsAResult() async throws {
        let lp = try NetlibFixtures.load("israel")
        let analysis = try await InteriorPoint(crossover: .none, maxIterations: 3).solve(lp)
        #expect(analysis.status == .noSolution(stoppedBy: .iterationLimit))
        #expect(analysis.iterations == 3)
    }

    @Test func cancellationAndTimeLimitAreResults() async throws {
        let lp = try NetlibFixtures.load("degen2")
        let strategy = InteriorPoint()
        let task = Task { try await strategy.solve(lp) }
        task.cancel()
        #expect(try await task.value.status == .noSolution(stoppedBy: .cancelled))
        var context = SolveContext()
        context.timeLimit = 0
        #expect(try await strategy.solve(lp, context: context).status == .noSolution(stoppedBy: .timeLimit))
        // The strategy value is reusable afterwards (rule L2).
        #expect(try await strategy.solve(lp).status == .optimal)
    }

    /// Rule L6: at most two Cholesky retries — δ × 100, then LDLᵀ — and never a loop.
    @Test func choleskyFailuresFallBackToLDLT() async throws {
        let lp = try NetlibFixtures.load("share2b")
        for dense in [true, false] {
            // share2b has 96 rows (dense path); the transport problem takes the sparse path.
            let problem = dense ? lp : InstanceGenerator.transport(sources: 30, sinks: 330, seed: 8)
            let scaled = Scaler.scale(Presolve.run(problem).reduced, mode: .geometricEquilibration)
            var worker = try IPMWorker(lp: scaled, config: InteriorPoint())
            let tookDensePath = worker.useDense
            #expect(tookDensePath == dense)
            worker.failingFactorizations = 2
            var gate = WorkGate(deadline: .none)
            let outcome = try await worker.run(gate: &gate)
            #expect(outcome.status == .converged, "\(outcome.status)")
            let switched = worker.usingLDLT
            #expect(switched)
            #expect(outcome.warnings.contains { $0.contains("LDL") })
        }
    }

    @Test func eventsReportEveryIterationAndFinishOnce() async throws {
        let lp = try NetlibFixtures.load("afiro")
        var context = SolveContext()
        let stream = context.makeEventStream()
        let analysis = try await InteriorPoint(crossover: .lite).solve(lp, context: context)
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        let iterations = events.compactMap { event -> Int? in
            if case .ipmIteration(let iteration, _, _, _) = event { return iteration }
            return nil
        }
        #expect(iterations == Array(0...analysis.iterations))
        #expect(events.filter(\.isFinished).count == 1)
        #expect(events.last?.isFinished == true)
    }

    @Test func denseColumnsAreDetectedAndWarnedAbout() async throws {
        // One column touches every row.
        var entries: [(row: Int, col: Int, value: Double)] = []
        let m = 20
        for i in 0..<m {
            entries.append((i, 0, 1))
            entries.append((i, i + 1, 1))
        }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: m + 1, entries), c: [Double](repeating: 1, count: m + 1),
            xl: [Double](repeating: 0, count: m + 1), xu: [Double](repeating: .infinity, count: m + 1),
            rl: [Double](repeating: 1, count: m), ru: [Double](repeating: .infinity, count: m))
        let analysis = try await InteriorPoint(crossover: .none, presolve: false).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(abs(analysis.objectiveValue! - 1) < 1e-6)
        #expect(analysis.warnings.contains { $0.contains("30%") })
    }
}
