import Foundation
import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Whether the long-running corpus cases run. An optimized build runs everything; a debug
/// build runs them only when ZTRONLP_SLOW_TESTS=1, because unoptimized code is an order of
/// magnitude slower on the largest instances.
enum Slow {
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZTRONLP_SLOW_TESTS"] == "1"
        #else
        return true
        #endif
    }
}

/// Oracle 2 and oracle 3 of §14.1 on the netlib corpus: every engine reaches the published
/// optimum to 1e-6 relative, and primal simplex, dual simplex and IPM + crossover agree to
/// 1e-7 relative.
@Suite struct NetlibCorpusTests {
    @Test(arguments: ReferenceValues.netlib)
    func everyEngineReachesThePublishedOptimumAndTheyAgree(_ instance: ReferenceInstance) async throws {
        let lp = try NetlibFixtures.load(instance.name)
        #expect(lp.m == instance.rows && lp.n == instance.columns)

        let primal = try await Simplex(.primal).solve(lp)
        let dual = try await Simplex(.dual).solve(lp)
        let interior = try await InteriorPoint(crossover: .lite).solve(lp)
        let automatic = try await Automatic().solve(lp)
        let results: [(String, SolveStatus, Double?)] = [
            ("primal simplex", primal.status, primal.objectiveValue),
            ("dual simplex", dual.status, dual.objectiveValue),
            ("interior point + crossover-lite", interior.status, interior.objectiveValue),
            ("automatic", automatic.status, automatic.objectiveValue),
        ]
        for (name, status, objective) in results {
            #expect(status == .optimal, "\(instance.name), \(name): \(status)")
            guard let objective else { continue }
            let error = ReferenceValues.relativeError(objective, reference: instance.optimalObjective)
            #expect(error <= ReferenceValues.relativeTolerance, "\(instance.name), \(name): \(objective) vs \(instance.optimalObjective)")
        }
        // Cross-engine agreement.
        guard let a = primal.objectiveValue, let b = dual.objectiveValue, let c = interior.objectiveValue else { return }
        let scale = max(1, abs(a))
        #expect(abs(a - b) <= 1e-7 * scale, "\(instance.name): primal \(a) vs dual \(b)")
        #expect(abs(a - c) <= 1e-7 * scale, "\(instance.name): primal \(a) vs interior point \(c)")

        // The interior point stays within its iteration budget, and crossover-lite within 20%
        // of a cold primal solve (§8.4).
        #expect(interior.iterations <= 40, "\(instance.name): \(interior.iterations) IPM iterations")
        if let crossover = interior.crossover {
            #expect(crossover.iterations <= max(10, primal.iterations / 5), "\(instance.name): crossover \(crossover.iterations) vs cold primal \(primal.iterations)")
        }
        // Both simplex bases are valid warm starts for each other.
        var context = SolveContext()
        context.warmStart = .basis(primal.basis)
        let rewarmed = try await Simplex(.dual).solve(lp, context: context)
        #expect(rewarmed.status == .optimal && rewarmed.iterations <= dual.iterations)
    }

    /// Each warm-start strategy reduces iterations vs a cold start on a modified instance (§14.2).
    @Test(arguments: ["share2b", "scagr7", "israel", "beaconfd", "stocfor1"])
    func warmStartsBeatColdStartsOnModifiedInstances(_ name: String) async throws {
        let lp = try NetlibFixtures.load(name)
        let first = try await Simplex(.dual).solve(lp)
        // Modify: scale every cost by a factor near 1.
        var rng = SeededGenerator(seed: 99)
        let costs = (0..<lp.n).map { lp.c[$0] * (1 + 0.02 * (rng.uniform() - 0.5)) }
        let modified = lp.withObjective(costs, constant: lp.c0)
        let cold = try await Simplex(.primal).solve(modified)
        #expect(cold.status == .optimal)

        var context = SolveContext()
        context.warmStart = .basis(first.basis)
        let fromBasis = try await Simplex(.primal).solve(modified, context: context)
        #expect(fromBasis.status == .optimal && fromBasis.iterations < cold.iterations, "\(name): basis \(fromBasis.iterations) vs cold \(cold.iterations)")

        context.warmStart = .primalPoint(try #require(first.primal))
        let fromPoint = try await Simplex(.primal).solve(modified, context: context)
        #expect(fromPoint.status == .optimal && fromPoint.iterations < cold.iterations, "\(name): point \(fromPoint.iterations) vs cold \(cold.iterations)")

        for analysis in [fromBasis, fromPoint] {
            #expect(abs(analysis.objectiveValue! - cold.objectiveValue!) <= 1e-7 * max(1, abs(cold.objectiveValue!)))
        }
    }
}

/// Oracles 2 and 3 on the MIPLIB 3 corpus: branch and bound with each node strategy, and
/// CP-SAT on the pure-integer instances, agree with the published optimum. The instances are fetched by `Scripts/fetch-miplib.sh`, not bundled; a
/// missing instance is reported as a known issue rather than a failure.
@Suite struct MIPLIBCorpusTests {
    /// The instances §14.2 lists CP-SAT for (its "Engines" column).
    static let cpSat: Set<String> = ["p0033", "stein27", "stein45", "enigma", "lseu", "mod008"]
    /// Instances that take minutes in an unoptimized build.
    static let slow: Set<String> = ["stein45", "lseu", "enigma", "mod008"]
    /// The same for CP-SAT as it runs by default, where every other worker solves a
    /// relaxation at each node.
    static let slowWithTheRelaxation: Set<String> = ["stein45", "lseu", "mod008", "p0201"]
    /// Instances the CP-SAT subset of §10.2 alone finds solutions for but does not close.
    /// mod008 is six covering rows over 319 binaries: proving 307 optimal by clause learning,
    /// with no bound over the rows together, is out of its reach — the risk the table of §15
    /// names ("weak on hard combinatorial instances"). The LP propagator, on by default,
    /// closes it, and so does branch and bound.
    static let unprovenWithoutTheRelaxation: Set<String> = ["mod008"]

    /// Seconds a case may take before it counts as a failure. The cases of this suite run
    /// side by side, so this is several times what any of them needs alone, and under
    /// instrumentation it grows with everything else (`ZTRONLP_LATENCY_SCALE`).
    static var generousLimit: Double { 240 * LivenessHarness.instrumentationScale }

    static func load(_ instance: ReferenceInstance) throws -> CompiledLP? {
        guard let lp = try Corpora.loadMIPLIB3(instance.name) else {
            withKnownIssue("\(instance.name) has not been fetched; run Scripts/fetch-miplib.sh") {
                Issue.record("missing corpus file")
            }
            return nil
        }
        return lp
    }

    @Test(arguments: ReferenceValues.miplib3)
    func branchAndBoundWithBothStrategies(_ instance: ReferenceInstance) async throws {
        guard !Self.slow.contains(instance.name) || Slow.enabled else { return }
        guard let lp = try Self.load(instance) else { return }
        #expect(lp.m == instance.rows && lp.n == instance.columns)
        var context = SolveContext()
        context.timeLimit = Self.generousLimit
        for (name, strategy) in [("Simplex(.primal)", BranchAndBound()), ("Simplex(.dual)", BranchAndBound(engine: Simplex(.dual)))] {
            let analysis = try await strategy.solve(lp, context: context)
            #expect(analysis.status == .optimal, "\(instance.name), \(name): \(analysis.status)")
            guard let objective = analysis.objectiveValue, let x = analysis.primal else { continue }
            // The gap tolerance is 1e-4 relative, so that is how close the answer has to be.
            let error = ReferenceValues.relativeError(objective, reference: instance.optimalObjective)
            #expect(error <= 1e-4, "\(instance.name), \(name): \(objective) vs \(instance.optimalObjective)")
            for column in lp.integerColumns { #expect(abs(x[Int(column)] - x[Int(column)].rounded()) <= 1e-6) }
            let violation = lp.maxViolation(at: x)
            #expect(violation.bounds <= 1e-6 && violation.rows <= 1e-5, "\(instance.name), \(name): \(violation)")
            #expect(analysis.root.status == .optimal && analysis.root.objectiveValue! <= objective + 1e-6 * max(1, abs(objective)))
        }
    }

    /// CP-SAT as it runs by default — the LP propagator of §10.4 on — proves every
    /// pure-integer instance of the set optimal: the six §14.2 lists for it and `p0201`, which
    /// it lists for branch and bound only. The limit is the generous one of the tests around
    /// it, because the cases of this suite share the machine; the 60 s of §14.3 are measured
    /// by the benchmark executable, which runs one instance at a time.
    @Test(arguments: ReferenceValues.miplib3.filter(\.pureInteger))
    func cpSatClosesEveryPureIntegerInstance(_ instance: ReferenceInstance) async throws {
        guard !Self.slowWithTheRelaxation.contains(instance.name) || Slow.enabled else { return }
        guard let lp = try Self.load(instance) else { return }
        var context = SolveContext()
        context.timeLimit = Self.generousLimit
        let analysis = try await CPSAT().solve(lp, context: context)
        #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status)")
        guard let objective = analysis.objectiveValue, let x = analysis.primal else { return }
        let scale = max(1, abs(instance.optimalObjective))
        #expect(abs(objective - instance.optimalObjective) <= 1e-6 * scale, "\(instance.name): \(objective)")
        #expect(analysis.bound == objective)
        #expect(analysis.lpSolves > 0)
        for column in lp.integerColumns { #expect(abs(x[Int(column)] - x[Int(column)].rounded()) <= 1e-9) }
        let violation = lp.maxViolation(at: x)
        #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-6)
    }

    /// The subset of §10.2 on its own, `CPSAT(lpPropagator: false)`, on the instances §14.2
    /// lists for CP-SAT: five are proven optimal; `mod008` is not, and that is recorded.
    @Test(arguments: ReferenceValues.miplib3.filter { MIPLIBCorpusTests.cpSat.contains($0.name) })
    func cpSatWithoutTheLPPropagator(_ instance: ReferenceInstance) async throws {
        guard !Self.slow.contains(instance.name) || Slow.enabled else { return }
        guard let lp = try Self.load(instance) else { return }
        let unproven = Self.unprovenWithoutTheRelaxation.contains(instance.name)
        var context = SolveContext()
        context.timeLimit = unproven ? 60 : Self.generousLimit
        let analysis = try await CPSAT(lpPropagator: false).solve(lp, context: context)
        #expect(analysis.lpSolves == 0)
        let scale = max(1, abs(instance.optimalObjective))
        if unproven {
            // What must hold regardless: a time limit is a result, and the incumbent it
            // comes with is a real solution, no better than the optimum.
            #expect(analysis.status.hasSolution, "\(instance.name): \(analysis.status)")
            withKnownIssue("CP-SAT without the LP propagator does not prove \(instance.name) optimal within \(Int(context.timeLimit ?? 0)) s", isIntermittent: true) {
                #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status), incumbent \(analysis.objectiveValue ?? .nan) vs \(instance.optimalObjective)")
            }
        } else {
            #expect(analysis.status == .optimal, "\(instance.name): \(analysis.status)")
        }
        guard let objective = analysis.objectiveValue, let x = analysis.primal else { return }
        if analysis.status == .optimal {
            #expect(abs(objective - instance.optimalObjective) <= 1e-6 * scale, "\(instance.name): \(objective)")
        } else {
            #expect(objective >= instance.optimalObjective - 1e-6 * scale, "\(instance.name): \(objective) is below the optimum")
        }
        for column in lp.integerColumns { #expect(abs(x[Int(column)] - x[Int(column)].rounded()) <= 1e-9) }
        let violation = lp.maxViolation(at: x)
        #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-6)
    }

    @Test func interiorPointRootOnAMixedInstance() async throws {
        guard let lp = try Self.load(ReferenceValues.miplib3(named: "flugpl")!) else { return }
        let analysis = try await BranchAndBound(engine: InteriorPoint()).solve(lp)
        #expect(analysis.status == .optimal)
        #expect(ReferenceValues.relativeError(analysis.objectiveValue!, reference: 1_201_500) <= 1e-4)
        #expect(analysis.root.iterations > 0)
    }
}

/// Oracle 1 of §14.1: constructed optima, per engine. An optimized build runs the full 1,000
/// instances up to 500 × 2,000; a debug build runs a smaller suite of small instances.
@Suite struct ConstructedOptimaCorpusTests {
    static func suite(seed: UInt64) -> [ConstructedInstance] {
        #if DEBUG
        return InstanceGenerator.constructedSuite(count: 100, seed: seed, maxSize: (50, 100))
        #else
        // Mostly small, some medium, a few at the top of the size range.
        return InstanceGenerator.constructedSuite(count: 940, seed: seed, maxSize: (60, 120))
            + InstanceGenerator.constructedSuite(count: 50, seed: seed &+ 1, minSize: (60, 120), maxSize: (150, 400))
            + InstanceGenerator.constructedSuite(count: 10, seed: seed &+ 2, minSize: (300, 1_000), maxSize: (500, 2_000))
        #endif
    }

    func check(_ instance: ConstructedInstance, _ status: SolveStatus, _ objective: Double?, _ x: [Double]?, _ engine: String, tolerance: Double) {
        #expect(status == .optimal, "\(engine), seed \(instance.seed): \(status)")
        guard let objective, let x else { return }
        #expect(abs(objective - instance.objective) <= tolerance * max(1, abs(instance.objective)), "\(engine), seed \(instance.seed): \(objective) vs \(instance.objective)")
        let violation = instance.lp.maxViolation(at: x)
        #expect(violation.bounds <= 1e-5 && violation.rows <= 1e-5, "\(engine), seed \(instance.seed): \(violation)")
    }

    @Test func primalSimplex() async throws {
        for instance in Self.suite(seed: 11) {
            let analysis = try await Simplex(.primal).solve(instance.lp)
            check(instance, analysis.status, analysis.objectiveValue, analysis.primal, "primal", tolerance: 1e-7)
        }
    }

    @Test func dualSimplex() async throws {
        for instance in Self.suite(seed: 22) {
            let analysis = try await Simplex(.dual).solve(instance.lp)
            check(instance, analysis.status, analysis.objectiveValue, analysis.primal, "dual", tolerance: 1e-7)
        }
    }

    @Test func interiorPoint() async throws {
        for instance in Self.suite(seed: 33) {
            let analysis = try await InteriorPoint().solve(instance.lp)
            check(instance, analysis.status, analysis.objectiveValue, analysis.primal, "interior point", tolerance: 1e-6)
        }
    }
}

/// Oracle 4 of §14.1: every `.infeasible` result carries a dual ray r with rᵀA within the
/// bound signs and a strictly separating value; every `.unbounded` result carries a primal ray.
@Suite struct CertificateTests {
    static func farkasGap(_ lp: CompiledLP, _ r: [Double]) -> Double {
        var value = 0.0
        for i in 0..<lp.m where abs(r[i]) > 1e-9 {
            let bound = r[i] > 0 ? lp.rl[i] : lp.ru[i]
            if bound.isInfinite { return -.infinity }
            value += r[i] * bound
        }
        let z = lp.a.multiplyTranspose(r)
        let scale = z.map { abs($0) }.max() ?? 0
        for j in 0..<lp.n where abs(z[j]) > 1e-9 * max(1, scale) {
            let bound = z[j] > 0 ? lp.xu[j] : lp.xl[j]
            if bound.isInfinite { return -.infinity }
            value -= z[j] * bound
        }
        return value
    }

    static func isImprovingRay(_ lp: CompiledLP, _ ray: [Double]) -> Bool {
        let tolerance = 1e-7 * (1 + (ray.map { abs($0) }.max() ?? 0))
        for j in 0..<lp.n {
            if ray[j] > tolerance && lp.xu[j] < .infinity { return false }
            if ray[j] < -tolerance && lp.xl[j] > -.infinity { return false }
        }
        let activity = lp.a.multiply(ray)
        let rowTolerance = tolerance * (1 + (activity.map { abs($0) }.max() ?? 0))
        for i in 0..<lp.m {
            if activity[i] > rowTolerance && lp.ru[i] < .infinity { return false }
            if activity[i] < -rowTolerance && lp.rl[i] > -.infinity { return false }
        }
        var slope = 0.0
        for j in 0..<lp.n { slope += lp.c[j] * ray[j] }
        return slope < 0
    }

    /// A feasible instance made infeasible: one more row demands an objective below the optimum.
    static func infeasible(from instance: ConstructedInstance) -> CompiledLP {
        let lp = instance.lp
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<lp.n {
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
            if lp.c[j] != 0 { entries.append((lp.m, j, lp.c[j])) }
        }
        let optimum = lp.internalObjective(at: instance.primal)
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: lp.m + 1, cols: lp.n, entries), c: lp.c, xl: lp.xl, xu: lp.xu,
            rl: lp.rl + [-.infinity], ru: lp.ru + [optimum - 1 - 0.01 * abs(optimum)])
    }

    /// A feasible instance made unbounded: one more column, with a negative cost, that only
    /// helps the rows it appears in.
    static func unbounded(from instance: ConstructedInstance) -> CompiledLP {
        let lp = instance.lp
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<lp.n {
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
        }
        // The new column enters only rows that are bounded on one side, pushing away from that side.
        for i in 0..<lp.m {
            if lp.ru[i] == .infinity && lp.rl[i] > -.infinity { entries.append((i, lp.n, 1)) }
            if lp.rl[i] == -.infinity && lp.ru[i] < .infinity { entries.append((i, lp.n, -1)) }
        }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: lp.m, cols: lp.n + 1, entries), c: lp.c + [-1],
            xl: lp.xl + [0], xu: lp.xu + [.infinity], rl: lp.rl, ru: lp.ru)
    }

    @Test func infeasibleResultsCarryADualRay() async throws {
        var checked = 0
        for instance in InstanceGenerator.constructedSuite(count: 40, seed: 404, maxSize: (30, 60)) where instance.lp.sense == .minimize {
            let lp = Self.infeasible(from: instance)
            for strategy in [Simplex(.primal), Simplex(.dual), Simplex(.primal, presolve: false), Simplex(.dual, presolve: false)] {
                let analysis = try await strategy.solve(lp)
                #expect(analysis.status == .infeasible, "seed \(instance.seed): \(analysis.status)")
                guard let ray = analysis.dualRay else {
                    Issue.record("seed \(instance.seed): no dual ray")
                    continue
                }
                #expect(Self.farkasGap(lp, ray) > 0, "seed \(instance.seed): the ray does not certify infeasibility")
                checked += 1
            }
        }
        #expect(checked >= 100)
    }

    @Test func unboundedResultsCarryAPrimalRay() async throws {
        var checked = 0
        for instance in InstanceGenerator.constructedSuite(count: 40, seed: 505, maxSize: (30, 60)) where instance.lp.sense == .minimize {
            let lp = Self.unbounded(from: instance)
            for strategy in [Simplex(.primal), Simplex(.dual), Simplex(.primal, presolve: false), Simplex(.dual, presolve: false)] {
                let analysis = try await strategy.solve(lp)
                #expect(analysis.status == .unbounded, "seed \(instance.seed): \(analysis.status)")
                guard let ray = analysis.primalRay else {
                    Issue.record("seed \(instance.seed): no primal ray")
                    continue
                }
                #expect(Self.isImprovingRay(lp, ray), "seed \(instance.seed): the ray is not an improving direction")
                checked += 1
            }
        }
        #expect(checked >= 100)
    }
}
