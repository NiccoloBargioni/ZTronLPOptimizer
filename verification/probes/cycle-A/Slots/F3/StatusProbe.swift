import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let ipmConfigs: [(String, InteriorPoint)] = [
    ("lite/pre", InteriorPoint(crossover: .lite, presolve: true)),
    ("lite/nopre", InteriorPoint(crossover: .lite, presolve: false)),
    ("none/pre", InteriorPoint(crossover: .none, presolve: true)),
    ("none/nopre", InteriorPoint(crossover: .none, presolve: false)),
]

/// C2: an infeasibility that is small relative to a large right-hand side.
func probeTinyInfeasible(_ args: [String]) async throws {
    for big in [1e3, 1e6, 1e8] {
        for delta in [1e-4, 1e-2, 1.0, 10.0] {
            // min x + y  s.t. x + y = B, x + y = B + delta, x, y >= 0: infeasible by delta.
            let eq = denseLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [big, big + delta], ru: [big, big + delta])
            // The same with inequalities: x + 2y <= B, x + 2y >= B + delta.
            let ineq = denseLP(c: [1, 1], rows: [[1, 2], [1, 2], [1, -1]], rl: [-inf, big + delta, -inf], ru: [big, inf, big])
            for (shape, lp) in [("eq", eq), ("ineq", ineq)] {
                let simplex = try await Simplex(.dual).solve(lp, context: ctx())
                var line = "B=\(e(big)) delta=\(e(delta)) \(shape): simplex=\(statusName(simplex.status))"
                for (name, strategy) in ipmConfigs {
                    let a = try await strategy.solve(lp, context: ctx())
                    var extra = ""
                    if a.status == .optimal, let x = a.primal {
                        let v = lp.maxViolation(at: x)
                        extra = " x=\(x.map { e($0) }) rowviol=\(e(v.rows)) boundviol=\(e(v.bounds)) obj=\(a.objectiveValue.map { e($0) } ?? "-")"
                        if !a.warnings.isEmpty { extra += " warnings=\(a.warnings)" }
                    }
                    line += " | \(name)=\(statusName(a.status)) it=\(a.iterations)\(extra)"
                }
                print(line)
            }
        }
    }
}

/// CertificateTests' constructions, rebuilt here: a feasible instance plus a row that demands an
/// objective below its optimum (infeasible), or plus an improving column that only helps (unbounded).
func infeasibleVariant(_ inst: ConstructedInstance) -> CompiledLP {
    let lp = inst.lp
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
        if lp.c[j] != 0 { entries.append((lp.m, j, lp.c[j])) }
    }
    let optimum = lp.internalObjective(at: inst.primal)
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: lp.m + 1, cols: lp.n, entries), c: lp.c, sense: lp.sense, xl: lp.xl, xu: lp.xu,
        rl: lp.rl + [-.infinity], ru: lp.ru + [optimum - 1 - 0.01 * abs(optimum)])
}

func unboundedVariant(_ inst: ConstructedInstance) -> CompiledLP {
    let lp = inst.lp
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
    }
    for i in 0..<lp.m {
        if lp.ru[i] == .infinity && lp.rl[i] > -.infinity { entries.append((i, lp.n, 1)) }
        if lp.rl[i] == -.infinity && lp.ru[i] < .infinity { entries.append((i, lp.n, -1)) }
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: lp.m, cols: lp.n + 1, entries), c: lp.c + [-1], sense: lp.sense,
        xl: lp.xl + [0], xu: lp.xu + [.infinity], rl: lp.rl, ru: lp.ru)
}

/// C3: status distribution on infeasible and unbounded models. args: count seed
func probeInfeasibleUnbounded(_ args: [String]) async throws {
    let count = args.count > 0 ? Int(args[0])! : 40
    let seed = args.count > 1 ? UInt64(args[1])! : 404
    var tally: [String: Int] = [:]
    var examples: [String: String] = [:]
    var simplexTally: [String: Int] = [:]
    let suite = InstanceGenerator.constructedSuite(count: count, seed: seed, maxSize: (40, 80))
    for inst in suite {
        for (kind, lp) in [("infeasible", infeasibleVariant(inst)), ("unbounded", unboundedVariant(inst))] {
            let simplex = try await Simplex(.dual).solve(lp, context: ctx())
            simplexTally[kind + " simplex " + statusName(simplex.status), default: 0] += 1
            for (name, strategy) in ipmConfigs {
                let a = try await strategy.solve(lp, context: ctx())
                let key = "\(kind) \(name) \(statusName(a.status))"
                tally[key, default: 0] += 1
                if examples[key] == nil {
                    examples[key] = "seed \(inst.seed) \(lp.m)x\(lp.n) iters \(a.iterations) simplex \(statusName(simplex.status)) mu \(e(a.finalMu)) pres \(e(a.primalResidual)) dres \(e(a.dualResidual))"
                }
                if a.status == .optimal || (kind == "infeasible" && a.status == .unbounded) || (kind == "unbounded" && a.status == .infeasible) {
                    let v = a.primal.map { lp.maxViolation(at: $0) }
                    print("WRONG \(key) seed \(inst.seed) simplex=\(statusName(simplex.status)) obj=\(String(describing: a.objectiveValue)) viol=\(String(describing: v)) warnings=\(a.warnings)")
                }
            }
        }
    }
    // Classic textbook pairs.
    let infeasibleSmall = denseLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 3], ru: [1, inf])
    let unboundedSmall = denseLP(c: [-1, -1], rows: [[1, -1], [-1, 1]], rl: [-inf, -inf], ru: [1, 2])
    // Primal and dual infeasible: min -x1 - x2 s.t. x1 - x2 >= 1, -x1 + x2 >= 1.
    let bothSmall = denseLP(c: [-1, -1], rows: [[1, -1], [-1, 1]], rl: [1, 1], ru: [inf, inf])
    for (name, lp) in [("textbook infeasible", infeasibleSmall), ("textbook unbounded", unboundedSmall), ("primal+dual infeasible", bothSmall)] {
        var line = "\(name): simplex=\(statusName(try await Simplex(.dual).solve(lp, context: ctx()).status))"
        for (cname, strategy) in ipmConfigs {
            let a = try await strategy.solve(lp, context: ctx())
            line += " | \(cname)=\(statusName(a.status)) it=\(a.iterations)"
        }
        print(line)
    }
    for (k, v) in simplexTally.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
    for (k, v) in tally.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)   e.g. \(examples[k]!)") }
}

/// The minimal A3-01 model through every public route. args: [runs]
func probeTinyFacades(_ args: [String]) async throws {
    let runs = args.count > 0 ? Int(args[0])! : 20
    // min x + y  s.t.  x + y = 1e8,  x + y = 1e8 + 1,  x, y >= 0  (infeasible)
    let lp = denseLP(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [1e8, 1e8 + 1], ru: [1e8, 1e8 + 1])
    let mps = MPSFormat.write(lp)
    let reread = try MPSFormat.read(mps)
    for (name, model) in [("CompiledLP", lp), ("MPS round trip", reread)] {
        for (sname, s) in [("InteriorPoint()", InteriorPoint() as any SolverStrategy), ("Simplex(.dual)", Simplex(.dual)), ("Automatic()", Automatic()), ("Conditioned(InteriorPoint())", Conditioned(InteriorPoint()))] {
            let a = try await s.solve(model, context: ctx())
            print("\(name) \(sname): \(statusName(a.status)) obj \(a.objectiveValue ?? .nan) x \(a.primal ?? []) viol \(a.primal.map { model.maxViolation(at: $0) }.map { "\($0)" } ?? "-")")
        }
    }
    var tally: [String: Int] = [:]
    for _ in 0..<runs {
        let a = try await Portfolio([Simplex(.dual), InteriorPoint()]).solve(lp, context: ctx())
        tally["\(statusName(a.status)) winner \(a.winner)", default: 0] += 1
    }
    print("Portfolio([Simplex(.dual), InteriorPoint()]) x\(runs): \(tally)")
}
