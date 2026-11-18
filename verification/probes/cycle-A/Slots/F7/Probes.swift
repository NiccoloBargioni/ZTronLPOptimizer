// Probe slot F7, cycle A: package integrity checks.
//   F7 netlib                 netlib table of README §5 (dims, nnz, pivots, IPM its, crossover, max rel error)
//   F7 hilbert [lo hi]        Hilbert table of README §5 (orders lo...hi, default 3...12)
//   F7 gen                    independent KKT check of the constructed-optimum oracle (every suite the tests use)
//   F7 defaults               defaults and constants of README §2 tables, Automatic.choice boundaries
//   F7 bnbdet <names...>      BranchAndBound(deterministic: true), both node engines, twice each
//   F7 cpdet <names...>       CPSAT(deterministic: true) twice, and CPSAT(lpPropagator:false, deterministic:true)
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum F7Probes {
    static func run(_ mode: String, _ args: [String]) async {
        do {
            switch mode {
            case "netlib": try await netlib()
            case "hilbert": try await hilbert(args)
            case "gen": gen()
            case "defaults": defaults()
            case "bnbdet": try await bnbdet(args)
            case "cpdet": try await cpdet(args)
            default:
                if !(await F7Extra.run(mode, args)) { print("unknown mode \(mode)") }
            }
        } catch {
            print("THREW: \(error)")
        }
    }

    static func e(_ v: Double) -> String { String(format: "%.1e", v) }

    // MARK: netlib
    static func netlib() async throws {
        print("instance m n nnz | primal_it dual_it ipm_it xover_it | maxrelerr | statuses")
        var context = SolveContext()
        context.timeLimit = 60
        for instance in ReferenceValues.netlib {
            let lp = try NetlibFixtures.load(instance.name)
            let primal = try await Simplex(.primal).solve(lp, context: context)
            let dual = try await Simplex(.dual).solve(lp, context: context)
            let interior = try await InteriorPoint(crossover: .lite).solve(lp, context: context)
            let errors = [primal.objectiveValue, dual.objectiveValue, interior.objectiveValue].map {
                $0.map { ReferenceValues.relativeError($0, reference: instance.optimalObjective) } ?? .infinity
            }
            var objNnz = 0
            for j in 0..<lp.n where lp.c[j] != 0 { objNnz += 1 }
            print("\(instance.name) \(lp.m) \(lp.n) \(lp.nnz) (obj nnz \(objNnz)) | \(primal.iterations) \(dual.iterations) \(interior.iterations) \(interior.crossover?.iterations ?? 0) | \(e(errors.max() ?? .infinity)) | \(primal.status) \(dual.status) \(interior.status)")
        }
    }

    // MARK: hilbert
    static func worst(_ x: [Double]) -> Double { x.reduce(0) { max($0, abs($1 - 1)) } }

    static func hilbert(_ args: [String]) async throws {
        let lo = args.count > 0 ? Int(args[0]) ?? 3 : 3
        let hi = args.count > 1 ? Int(args[1]) ?? 12 : 12
        var context = SolveContext()
        context.timeLimit = 60
        print("order cond dense | dual primal ipm | objWorstRel | warned/12 | non-optimal")
        for order in lo...hi {
            // condition estimate and dense solve on the equation system
            let eq = InstanceGenerator.hilbert(order: order, form: .equality)
            let h = DenseMatrix(eq.lp.a)
            let lu = try DenseLU(h)
            let cond = lu.conditionEstimate() ?? .nan
            let dense = denseSolve(h, eq.lp.rl).map { worst($0) } ?? .nan
            var worstBy = [0.0, 0.0, 0.0]
            var objWorst = 0.0
            var warned = 0
            var nonOptimal: [String] = []
            for form in HilbertForm.allCases {
                let instance = InstanceGenerator.hilbert(order: order, form: form)
                let engines: [(String, any SolverStrategy)] = [("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("ipm", InteriorPoint())]
                for (k, (name, strategy)) in engines.enumerated() {
                    let a = try await strategy.solve(instance.lp, context: context)
                    if a.status != .optimal { nonOptimal.append("\(form.rawValue)/\(name):\(a.status)") }
                    if let x = a.primal { worstBy[k] = max(worstBy[k], worst(x)) }
                    if let o = a.objectiveValue { objWorst = max(objWorst, abs(o - instance.objective) / max(1, abs(instance.objective))) }
                    if !a.warnings.isEmpty { warned += 1 }
                }
            }
            print("\(order) \(e(cond)) \(e(dense)) | \(e(worstBy[0])) \(e(worstBy[1])) \(e(worstBy[2])) | \(e(objWorst)) | \(warned) | \(nonOptimal.joined(separator: ","))")
        }
    }

    // MARK: constructed-optimum oracle, independent KKT certificate
    /// Returns (primal violation, worst complementarity/sign violation, duality gap relative, objective mismatch relative).
    static func kkt(_ inst: ConstructedInstance) -> (Double, Double, Double, Double) {
        let lp = inst.lp
        let x = inst.primal, y = inst.dual
        let v = lp.maxViolation(at: x)
        let s = lp.a.multiply(x)
        let aty = lp.a.multiplyTranspose(y)
        var worstSign = 0.0
        var dualObj = 0.0
        var dualInfeasible = false
        let tol = 1e-9
        for j in 0..<lp.n {
            let d = lp.c[j] - aty[j]
            let atLower = abs(x[j] - lp.xl[j]) <= tol * max(1, abs(lp.xl[j]))
            let atUpper = abs(x[j] - lp.xu[j]) <= tol * max(1, abs(lp.xu[j]))
            if d > 0 {
                if !atLower { worstSign = max(worstSign, d) }
                if lp.xl[j].isInfinite { dualInfeasible = true } else { dualObj += d * lp.xl[j] }
            } else if d < 0 {
                if !atUpper { worstSign = max(worstSign, -d) }
                if lp.xu[j].isInfinite { dualInfeasible = true } else { dualObj += d * lp.xu[j] }
            }
        }
        for i in 0..<lp.m {
            let atLower = abs(s[i] - lp.rl[i]) <= 1e-9 * max(1, abs(lp.rl[i]))
            let atUpper = abs(s[i] - lp.ru[i]) <= 1e-9 * max(1, abs(lp.ru[i]))
            if y[i] > 0 {
                if !atLower { worstSign = max(worstSign, y[i]) }
                if lp.rl[i].isInfinite { dualInfeasible = true } else { dualObj += y[i] * lp.rl[i] }
            } else if y[i] < 0 {
                if !atUpper { worstSign = max(worstSign, -y[i]) }
                if lp.ru[i].isInfinite { dualInfeasible = true } else { dualObj += y[i] * lp.ru[i] }
            }
        }
        let primalObj = lp.internalObjective(at: x)
        let gap = dualInfeasible ? Double.infinity : abs(primalObj - dualObj) / max(1, abs(primalObj))
        let reported = lp.objective(at: x)
        let mismatch = abs(reported - inst.objective) / max(1, abs(inst.objective))
        return (max(v.bounds, v.rows), worstSign, gap, mismatch)
    }

    static func gen() {
        var suites: [(String, [ConstructedInstance])] = []
        for seed: UInt64 in [11, 22, 33] {
            suites.append(("debug seed \(seed)", InstanceGenerator.constructedSuite(count: 100, seed: seed, maxSize: (50, 100))))
            suites.append(("release seed \(seed)",
                InstanceGenerator.constructedSuite(count: 940, seed: seed, maxSize: (60, 120))
                + InstanceGenerator.constructedSuite(count: 50, seed: seed &+ 1, minSize: (60, 120), maxSize: (150, 400))
                + InstanceGenerator.constructedSuite(count: 10, seed: seed &+ 2, minSize: (300, 1_000), maxSize: (500, 2_000))))
        }
        suites.append(("fixture seed 11", InstanceGenerator.constructedSuite(count: 40, seed: 11)))
        suites.append(("certificate seed 404", InstanceGenerator.constructedSuite(count: 40, seed: 404, maxSize: (30, 60))))
        suites.append(("certificate seed 505", InstanceGenerator.constructedSuite(count: 40, seed: 505, maxSize: (30, 60))))
        for (name, suite) in suites {
            var worst = (0.0, 0.0, 0.0, 0.0)
            var bad = 0
            for inst in suite {
                let r = kkt(inst)
                worst = (max(worst.0, r.0), max(worst.1, r.1), max(worst.2, r.2), max(worst.3, r.3))
                if r.0 > 1e-9 || r.1 > 0 || r.2 > 1e-9 || r.3 > 1e-9 { bad += 1 }
            }
            print("\(name): \(suite.count) instances, worst primal viol \(e(worst.0)), worst sign/compl viol \(e(worst.1)), worst duality gap \(e(worst.2)), worst objective mismatch \(e(worst.3)), instances failing \(bad)")
        }
        // Hilbert oracle: certificate too
        for order in [3, 8, 12] {
            for form in HilbertForm.allCases {
                let r = kkt(InstanceGenerator.hilbert(order: order, form: form))
                print("hilbert \(order) \(form.rawValue): viol \(e(r.0)) sign \(e(r.1)) gap \(e(r.2)) mismatch \(e(r.3))")
            }
        }
    }

    // MARK: defaults
    static func defaults() {
        let t = Tolerances.default
        print("Tolerances: primal \(t.primalFeasibility) dual \(t.dualFeasibility) pivot \(t.pivot) harris \(t.harris) dropZero \(t.dropZero) integrality \(t.integrality) mipRel \(t.mipRelativeGap) mipAbs \(t.mipAbsoluteGap) ipm \(t.ipmResidual)")
        print("Simplex.denseBasisLimit \(Simplex.denseBasisLimit); iterationCap(10,10) \(Simplex(.dual).iterationCap(rows: 10, columns: 10)); iterationCap(1000,1000) \(Simplex(.dual).iterationCap(rows: 1000, columns: 1000))")
        print("sparseMultiplyThreshold \(sparseMultiplyThreshold); IndexedVector.sparseDensity \(IndexedVector.sparseDensity)")
        print("DenseLUBasis.refactorInterval \(DenseLUBasis().refactorInterval); SparseQRBasis.refactorInterval \(SparseQRBasis().refactorInterval)")
        print("KernelThresholds: \(KernelThresholds.reducedCostScanColumns) \(KernelThresholds.reducedCostScanNonzeros) \(KernelThresholds.reducedCostCandidates) \(KernelThresholds.batchedActivityPoints) \(KernelThresholds.batchedActivityNonzeros) \(KernelThresholds.batchedActivityMaxBatch) \(KernelThresholds.disagreementFraction)")
        print("Automatic: ipmRows \(Automatic.interiorPointRows) denseRows \(Automatic.denseColumnRows) denseFraction \(Automatic.denseColumnFraction)")
        let h = Heuristics.default
        print("Heuristics.default: rounding \(h.rounding) diving \(h.diving) interval \(h.divingInterval) depth \(h.divingMaxDepth) its \(h.divingIterationLimit) batch \(h.roundingBatch)")
        let g = Gap()
        print("Gap(): \(g.relative) \(g.absolute)")
        let b = BranchAndBound()
        print("BranchAndBound(): engine \(b.engine.engineName) branching \(b.branching) nodeSelection \(b.nodeSelection) gap \(b.gap) deterministic \(b.deterministic) name \(b.engineName)")
        let c = CPSAT()
        print("CPSAT(): workers \(String(describing: c.workers)) restarts \(c.restarts) sharing \(c.clauseSharing) lp \(c.lpPropagator) seed \(c.seed) det \(c.deterministic)")
        let ip = InteriorPoint()
        print("InteriorPoint(): crossover \(ip.crossover) maxIterations \(ip.maxIterations) regularization \(ip.regularization)")
        print("RestartPolicy.lubyTerm 0..15: \((0...15).map { RestartPolicy.lubyTerm($0) })")
        let o = ConditioningAnalyzer.Options()
        print("ConditioningAnalyzer.Options(): maxFindings \(o.maxFindingsPerKind) parallelRows \(o.parallelRowThreshold) boundTol \(o.boundTolerance)")
        let co = CompileOptions()
        print("CompileOptions(): lowerSingletons \(co.lowerSingletonConstraints) dropTolerance \(co.dropTolerance)")
        let ctx = SolveContext()
        print("SolveContext(): timeLimit \(String(describing: ctx.timeLimit)) threads \(String(describing: ctx.threads)) resolved \(ctx.resolvedThreads) memory \(String(describing: ctx.memoryBudgetBytes)) metal \(ctx.metal)")
        print("MemoryBudget.availableBytes \(MemoryBudget.availableBytes()) resolve(default) \(MemoryBudget.resolve(ctx)) physical \(ProcessInfo.processInfo.physicalMemory)")
        // Automatic.choice boundaries
        func lp(rows: Int, denseColumn: Int?) -> CompiledLP {
            var entries: [(row: Int, col: Int, value: Double)] = []
            for i in 0..<rows { entries.append((i, i, 1)) }
            var n = rows
            if let k = denseColumn {
                for i in 0..<k { entries.append((i, rows, 1)) }
                n += 1
            }
            return CompiledLP(a: SparseCSC.fromTriplets(rows: rows, cols: n, entries), c: [Double](repeating: 1, count: n),
                              xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n),
                              rl: [Double](repeating: -.infinity, count: rows), ru: [Double](repeating: 1, count: rows))
        }
        for (rows, dense) in [(4_000, nil), (4_001, nil), (10_000, 5_000), (10_001, 3_000), (10_001, 3_001), (10_001, 5_000)] as [(Int, Int?)] {
            print("Automatic.choice rows \(rows) dense column \(dense.map(String.init) ?? "none"): \(Automatic.choice(for: lp(rows: rows, denseColumn: dense)))")
        }
    }

    // MARK: deterministic search
    static func bnbdet(_ args: [String]) async throws {
        var context = SolveContext()
        context.timeLimit = Double(ProcessInfo.processInfo.environment["F7_LIMIT"] ?? "120") ?? 120
        let names = args.isEmpty ? ReferenceValues.miplib3.map(\.name).filter { $0 != "stein45" } : args
        for name in names {
            guard let ref = ReferenceValues.miplib3(named: name), let lp = try Corpora.loadMIPLIB3(name) else { print("\(name): missing"); continue }
            for (label, run) in [("primal", { try await BranchAndBound(deterministic: true).solve(lp, context: context) as any SolutionAnalysis }),
                                 ("dual", { try await BranchAndBound(engine: Simplex(.dual), deterministic: true).solve(lp, context: context) as any SolutionAnalysis })] as [(String, () async throws -> any SolutionAnalysis)] {
                var lines: [String] = []
                for _ in 0..<2 {
                    let a = try await run()
                    let nodes: Int, its: Int
                    if let p = a as? BranchAndBoundAnalysis<SimplexAnalysis> { nodes = p.nodesProcessed; its = p.lpIterations } else { nodes = -1; its = -1 }
                    let err = a.objectiveValue.map { ReferenceValues.relativeError($0, reference: ref.optimalObjective) } ?? .infinity
                    lines.append("\(a.status) obj \(a.objectiveValue ?? .nan) relerr \(e(err)) nodes \(nodes) LPit \(its) s \(String(format: "%.2f", a.seconds))")
                }
                print("\(name) \(label) det: [\(lines[0])] [\(lines[1])]")
            }
        }
    }

    static func cpdet(_ args: [String]) async throws {
        var context = SolveContext()
        context.timeLimit = Double(ProcessInfo.processInfo.environment["F7_LIMIT"] ?? "60") ?? 60
        let names = args.isEmpty ? ReferenceValues.miplib3.filter(\.pureInteger).map(\.name).filter { $0 != "stein45" } : args
        for name in names {
            guard let ref = ReferenceValues.miplib3(named: name), let lp = try Corpora.loadMIPLIB3(name) else { print("\(name): missing"); continue }
            for (label, strategy) in [("CPSAT(det)", CPSAT(deterministic: true)), ("CPSAT(lp:false,det)", CPSAT(lpPropagator: false, deterministic: true))] {
                var lines: [String] = []
                for _ in 0..<2 {
                    let a = try await strategy.solve(lp, context: context)
                    let err = a.objectiveValue.map { ReferenceValues.relativeError($0, reference: ref.optimalObjective) } ?? .infinity
                    lines.append("\(a.status) obj \(a.objectiveValue ?? .nan) relerr \(e(err)) conflicts \(a.conflicts) lpSolves \(a.lpSolves) workers \(a.workers) s \(String(format: "%.2f", a.seconds))")
                }
                print("\(name) \(label): [\(lines[0])] [\(lines[1])]")
            }
        }
    }
}
