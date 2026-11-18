import Testing
import ZTronLPOptimizer
import ZTronLPTestSupport

// Ill-conditioned problems: LPs on the Hilbert matrix whose only optimum is x = (1, …, 1).
//
// With the usual tolerances such a problem has many "optimal" bases: at order 8 the vertex
// with seven of the eight columns basic satisfies every row to 2e-10 and lies at distance 1
// from the solution. These tests pin what the engines do about it: up to order 8, where
// double precision can still resolve the solution, every LP strategy returns it; beyond, no
// strategy calls the problem infeasible or unbounded, and an optimal answer carries a
// warning.

private func worstDistanceFromOnes(_ x: [Double]) -> Double {
    var worst = 0.0
    for value in x { worst = max(worst, abs(value - 1)) }
    return worst
}

private func relativeError(_ value: Double, _ reference: Double) -> Double {
    abs(value - reference) / max(1, abs(reference))
}

/// Every LP strategy of the package, freshly configured.
private func lpStrategies() -> [(name: String, strategy: any SolverStrategy)] {
    [
        ("Simplex(.dual)", Simplex(.dual)),
        ("Simplex(.primal)", Simplex(.primal)),
        ("Simplex(.dual, sparseQR)", Simplex(.dual, factorization: .sparseQR)),
        ("Simplex(.primal, sparseQR)", Simplex(.primal, factorization: .sparseQR)),
        ("Simplex(.dual, no presolve, no scaling)", Simplex(.dual, presolve: false, scaling: .none)),
        ("Simplex(.primal, no presolve, no scaling)", Simplex(.primal, presolve: false, scaling: .none)),
        ("InteriorPoint()", InteriorPoint()),
        ("Automatic()", Automatic()),
        ("Portfolio", Portfolio([Simplex(.dual), Simplex(.primal), InteriorPoint()])),
    ]
}

private func solve(_ strategy: any SolverStrategy, _ lp: CompiledLP) async throws -> any SolutionAnalysis {
    try await strategy.solve(lp, context: SolveContext())
}

@Suite struct IllConditionedTests {
    /// Orders 3 to 8: condition numbers from 5e2 to 1.5e10. The solution is recovered to what
    /// a dense solve in double precision gives (1e-6 at order 8), by every LP strategy.
    @Test(arguments: 3...8)
    func everyLPStrategyFindsTheOnlyOptimum(_ order: Int) async throws {
        for form in HilbertForm.allCases {
            let instance = InstanceGenerator.hilbert(order: order, form: form)
            for (name, strategy) in lpStrategies() {
                let analysis = try await solve(strategy, instance.lp)
                let label = "order \(order), \(form.rawValue), \(name)"
                #expect(analysis.status == .optimal, "\(label): \(analysis.status)")
                let x = try #require(analysis.primal, "\(label): no primal values")
                #expect(worstDistanceFromOnes(x) <= 2e-5, "\(label): x is off by \(worstDistanceFromOnes(x))")
                let objective = try #require(analysis.objectiveValue)
                #expect(relativeError(objective, instance.objective) <= 1e-9, "\(label): objective \(objective)")
                let violation = instance.lp.maxViolation(at: x)
                #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9, "\(label): violation \(violation)")
            }
        }
    }

    /// The same systems over integer columns: branch and bound returns the integer point
    /// exactly, with either node engine.
    @Test(arguments: 4...8)
    func branchAndBoundFindsTheIntegerPoint(_ order: Int) async throws {
        for form in HilbertForm.allCases {
            let instance = InstanceGenerator.hilbert(order: order, form: form, integer: true)
            let primal = try await BranchAndBound().solve(instance.lp)
            let dual = try await BranchAndBound(engine: Simplex(.dual)).solve(instance.lp)
            for (name, analysis) in [("primal", primal), ("dual", dual)] {
                let label = "order \(order), \(form.rawValue), node engine \(name)"
                #expect(analysis.status == .optimal, "\(label): \(analysis.status)")
                let x = try #require(analysis.primal, "\(label): no incumbent")
                #expect(worstDistanceFromOnes(x) <= 1e-9, "\(label): x is off by \(worstDistanceFromOnes(x))")
                #expect(relativeError(try #require(analysis.objectiveValue), instance.objective) <= 1e-9)
            }
        }
    }

    /// Orders 10 and 12 (condition numbers 1.6e13 and 1.7e16) are beyond what double
    /// precision resolves. The objective is still right and the point returned is feasible,
    /// but it need not be the solution — and the answer says so. What must never happen is
    /// a verdict of infeasible or unbounded.
    @Test(arguments: [10, 12])
    func beyondDoublePrecisionNothingIsCalledInfeasible(_ order: Int) async throws {
        for form in HilbertForm.allCases {
            let instance = InstanceGenerator.hilbert(order: order, form: form)
            for (name, strategy) in lpStrategies() {
                let analysis = try await solve(strategy, instance.lp)
                let label = "order \(order), \(form.rawValue), \(name)"
                switch analysis.status {
                case .optimal:
                    let x = try #require(analysis.primal)
                    let violation = instance.lp.maxViolation(at: x)
                    #expect(violation.bounds <= 1e-6 && violation.rows <= 1e-6, "\(label): violation \(violation)")
                    #expect(relativeError(try #require(analysis.objectiveValue), instance.objective) <= 1e-6, "\(label)")
                    #expect(!analysis.warnings.isEmpty, "\(label): an answer this fragile must carry a warning")
                case .numericalFailure:
                    break
                default:
                    Issue.record("\(label): \(analysis.status)")
                }
            }
        }
    }

    /// A caller who answers ill-conditioning by lowering the feasibility tolerances — and
    /// nothing else — gets the solution, not a verdict of infeasible. (Before the tolerances
    /// were kept consistent, the dual method read the one row that only a small pivot could
    /// repair as a proof of infeasibility.)
    @Test(arguments: [Simplex.Method.dual, .primal])
    func loweringOnlyTheFeasibilityTolerancesWorks(_ method: Simplex.Method) async throws {
        var tolerances = Tolerances()
        tolerances.primalFeasibility = 1e-10
        tolerances.dualFeasibility = 1e-10
        for form in HilbertForm.allCases {
            let instance = InstanceGenerator.hilbert(order: 8, form: form)
            let analysis = try await Simplex(method, tolerances: tolerances).solve(instance.lp)
            #expect(analysis.status == .optimal, "\(form.rawValue): \(analysis.status)")
            let x = try #require(analysis.primal)
            #expect(worstDistanceFromOnes(x) <= 2e-5, "\(form.rawValue): x is off by \(worstDistanceFromOnes(x))")
        }
    }

    /// The interior point's normal equations square the condition number, so its residuals
    /// stall well above its tolerance. That is not infeasibility: with crossover the simplex
    /// finishes from the last iterate; without it the result is a numerical failure that
    /// says what happened.
    @Test func theInteriorPointDoesNotMistakeAStallForInfeasibility() async throws {
        for form in HilbertForm.allCases {
            let instance = InstanceGenerator.hilbert(order: 8, form: form)

            let crossed = try await InteriorPoint().solve(instance.lp)
            #expect(crossed.status == .optimal, "\(form.rawValue): \(crossed.status)")
            #expect(worstDistanceFromOnes(try #require(crossed.primal)) <= 2e-5)
            #expect(crossed.crossover != nil, "\(form.rawValue): the simplex should have finished the solve")
            #expect(crossed.warnings.contains { $0.contains("stalled") }, "\(form.rawValue): \(crossed.warnings)")

            let plain = try await InteriorPoint(crossover: .none).solve(instance.lp)
            switch plain.status {
            case .numericalFailure(let message):
                #expect(message.contains("stalled"), "\(form.rawValue): \(message)")
            case .optimal:
                break
            default:
                Issue.record("\(form.rawValue): InteriorPoint(crossover: .none) reported \(plain.status)")
            }
        }
    }

    /// At order 8 the answer is right and still deserves a warning: the basis that carries
    /// it has a condition number above 1e10.
    @Test func anIllConditionedOptimalBasisIsReported() async throws {
        let instance = InstanceGenerator.hilbert(order: 8, form: .equality)
        let analysis = try await Simplex(.dual).solve(instance.lp)
        #expect(analysis.status == .optimal)
        #expect(analysis.warnings.contains { $0.contains("ill-conditioned") }, "\(analysis.warnings)")
        // A well-conditioned problem of the same shape has nothing to report.
        let easy = InstanceGenerator.hilbert(order: 3, form: .equality)
        #expect(try await Simplex(.dual).solve(easy.lp).warnings.isEmpty)
    }
}
