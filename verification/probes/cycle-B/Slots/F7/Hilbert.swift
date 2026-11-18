import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// hilbert: reproduces README §5 "Linear programs: ill-conditioned ones" (orders 3...12, four
/// forms, Simplex(.dual), Simplex(.primal), InteriorPoint()).
enum HilbertTable {
    static func run() async throws {
        print("order cond dense dual primal ipm objWorst warned statuses")
        for order in 3...12 {
            let eq = InstanceGenerator.hilbert(order: order, form: .equality)
            let h = DenseMatrix(eq.lp.a)
            let cond = (try? DenseLU(h))?.conditionEstimate() ?? .nan
            let xs = denseSolve(h, eq.lp.rl) ?? []
            let dense = xs.map { abs($0 - 1) }.max() ?? .nan
            var worst = [0.0, 0.0, 0.0]; var objWorst = 0.0; var warned = 0; var statuses: [String: Int] = [:]
            for form in HilbertForm.allCases {
                let inst = InstanceGenerator.hilbert(order: order, form: form)
                let engines: [any SolverStrategy] = [Simplex(.dual), Simplex(.primal), InteriorPoint()]
                for (k, engine) in engines.enumerated() {
                    var ctx = SolveContext(); ctx.timeLimit = 30
                    let an = try await engine.solve(inst.lp, context: ctx)
                    statuses["\(an.status)", default: 0] += 1
                    if let x = an.primal { worst[k] = max(worst[k], x.map { abs($0 - 1) }.max() ?? 0) } else { worst[k] = .infinity }
                    if let o = an.objectiveValue { objWorst = max(objWorst, abs(o - inst.objective) / max(1, abs(inst.objective))) }
                    if !an.warnings.isEmpty { warned += 1 }
                }
            }
            print(order, fmt(cond), fmt(dense), fmt(worst[0]), fmt(worst[1]), fmt(worst[2]), fmt(objWorst), "\(warned)/12", statuses.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ","))
        }
    }
}

enum HilbertWarnings {
    static func run(_ orders: [Int]) async throws {
        for order in orders {
            for form in HilbertForm.allCases {
                let inst = InstanceGenerator.hilbert(order: order, form: form)
                let engines: [(String, any SolverStrategy)] = [("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("ipm", InteriorPoint())]
                for (name, engine) in engines {
                    var ctx = SolveContext(); ctx.timeLimit = 30
                    let an = try await engine.solve(inst.lp, context: ctx)
                    if !an.warnings.isEmpty { print("order \(order) \(form.rawValue) \(name): \(an.status) warnings=\(an.warnings)") }
                }
            }
        }
    }
}

/// hilbertonly <orders...>: which of IllConditionedTests' nine strategies answer `.optimal` at
/// distance >= 1e-3 from the solution with no warning other than the IPM's dense-column note.
enum HilbertOnlyDense {
    static func run(_ orders: [Int]) async throws {
        let strategies: [(String, any SolverStrategy)] = [
            ("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal)", Simplex(.primal)),
            ("Simplex(.dual, sparseQR)", Simplex(.dual, factorization: .sparseQR)),
            ("Simplex(.primal, sparseQR)", Simplex(.primal, factorization: .sparseQR)),
            ("Simplex(.dual, no presolve, no scaling)", Simplex(.dual, presolve: false, scaling: .none)),
            ("Simplex(.primal, no presolve, no scaling)", Simplex(.primal, presolve: false, scaling: .none)),
            ("InteriorPoint()", InteriorPoint()), ("Automatic()", Automatic()),
            ("Portfolio", Portfolio([Simplex(.dual), Simplex(.primal), InteriorPoint()])),
        ]
        for order in orders {
            var total = 0, warnedAny = 0, warnedOnlyDense = 0, far = 0
            for form in HilbertForm.allCases {
                let inst = InstanceGenerator.hilbert(order: order, form: form)
                for (name, s) in strategies {
                    var ctx = SolveContext(); ctx.timeLimit = 30
                    let an = try await s.solve(inst.lp, context: ctx)
                    total += 1
                    let dist = an.primal.map { $0.map { abs($0 - 1) }.max() ?? 0 } ?? .infinity
                    if dist >= 1e-3 { far += 1 }
                    let relevant = an.warnings.filter { !$0.contains("nonzeros; the normal equations will be dense") }
                    if !an.warnings.isEmpty { warnedAny += 1 }
                    if !an.warnings.isEmpty && relevant.isEmpty {
                        warnedOnlyDense += 1
                        print("  order \(order) \(form.rawValue) \(name): \(an.status) dist=\(fmt(dist)) ONLY dense-column warning")
                    }
                    if an.warnings.isEmpty && dist >= 1e-3 { print("  order \(order) \(form.rawValue) \(name): \(an.status) dist=\(fmt(dist)) NO warning") }
                }
            }
            print("order \(order): \(total) solves, far(>=1e-3) \(far), any warning \(warnedAny), only the dense-column warning \(warnedOnlyDense)")
        }
    }
}
