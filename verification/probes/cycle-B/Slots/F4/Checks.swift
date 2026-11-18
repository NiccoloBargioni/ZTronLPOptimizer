// Cycle B, slot F4: configurations and result checks against the oracle.
import Foundation
import ZTronLPOptimizer

struct RunOutcome {
    var status: SolveStatus
    var objective: Double?
    var bound: Double?
    var primal: [Double]?
    var nodes: Int
    var lpIterations: Int
    var history: [IncumbentEvent]
    var warnings: [String]
}

func runBnB<E: NodeLPStrategy>(_ s: BranchAndBound<E>, _ lp: CompiledLP, timeLimit: Double = 20, threads: Int? = nil, memory: Int? = nil) async -> RunOutcome {
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    ctx.threads = threads
    ctx.memoryBudgetBytes = memory
    do {
        let a = try await s.solve(lp, context: ctx)
        return RunOutcome(status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal,
                          nodes: a.nodesProcessed, lpIterations: a.lpIterations, history: a.incumbentHistory, warnings: a.warnings)
    } catch {
        return RunOutcome(status: .numericalFailure("THROWN \(error)"), objective: nil, bound: nil, primal: nil, nodes: 0, lpIterations: 0, history: [], warnings: [])
    }
}

/// Runs BnB on a problem first reduced by the full presolve, then expands the primal back.
func runPresolvedBnB(_ lp: CompiledLP, timeLimit: Double = 20) async -> RunOutcome {
    let pre = Presolve.run(lp, tolerances: .default, mode: .full)
    switch pre.outcome {
    case .infeasible:
        return RunOutcome(status: .infeasible, objective: nil, bound: nil, primal: nil, nodes: 0, lpIterations: 0, history: [], warnings: ["presolve infeasible"])
    case .solved:
        let x = pre.expandPrimal([Double](repeating: 0, count: pre.reduced.n))
        return RunOutcome(status: .optimal, objective: lp.objective(at: x), bound: lp.objective(at: x), primal: x, nodes: 0, lpIterations: 0, history: [], warnings: ["presolve solved"])
    case .reduced:
        var out = await runBnB(BranchAndBound(), pre.reduced, timeLimit: timeLimit)
        if let x = out.primal { out.primal = pre.expandPrimal(x) }
        return out
    }
}

struct Config {
    let name: String
    let run: (CompiledLP) async -> RunOutcome
}

let tight = Gap(relative: 0, absolute: 0)

let allConfigs: [Config] = [
    Config(name: "primal-par") { await runBnB(BranchAndBound(), $0) },
    Config(name: "primal-det") { await runBnB(BranchAndBound(deterministic: true), $0) },
    Config(name: "dual-par") { await runBnB(BranchAndBound(engine: Simplex(.dual)), $0) },
    Config(name: "dual-det") { await runBnB(BranchAndBound(engine: Simplex(.dual), deterministic: true), $0) },
    Config(name: "ipm-par") { await runBnB(BranchAndBound(engine: InteriorPoint()), $0) },
    Config(name: "ipm-nopre-det") { await runBnB(BranchAndBound(engine: InteriorPoint(presolve: false), deterministic: true), $0) },
    Config(name: "primal-nopre-par") { await runBnB(BranchAndBound(engine: Simplex(.primal, presolve: false)), $0) },
    Config(name: "mf-dfs-noheur") { await runBnB(BranchAndBound(branching: .mostFractional, nodeSelection: .depthFirst, heuristics: .none), $0) },
    Config(name: "strong-best-dual") { await runBnB(BranchAndBound(engine: Simplex(.dual), branching: .strong(candidates: 3), nodeSelection: .bestBound), $0) },
    Config(name: "tightgap-par") { await runBnB(BranchAndBound(gap: tight), $0) },
    Config(name: "tightgap-dual-det") { await runBnB(BranchAndBound(engine: Simplex(.dual), gap: tight, deterministic: true), $0) },
    Config(name: "presolve-full") { await runPresolvedBnB($0) },
    Config(name: "threads1-par") { await runBnB(BranchAndBound(), $0, threads: 1) },
]

func slack(_ z: Double, _ g: Gap = Gap()) -> Double { max(g.absolute, g.relative * max(1, abs(z))) }

/// Returns a list of problems with the run, empty when it agrees with the oracle.
func check(_ inst: Inst, _ lp: CompiledLP, _ truth: OracleResult, _ out: RunOutcome, gapUsed: Gap) -> [String] {
    var issues: [String] = []
    let maxim = inst.maximize
    switch truth {
    case .infeasible:
        if out.status != .infeasible { issues.append("status \(out.status) but oracle infeasible") }
    case .unbounded:
        if !(out.status == .unbounded || out.status == .infeasibleOrUnbounded) { issues.append("status \(out.status) but oracle unbounded") }
    case .optimal(let zstar, _):
        guard out.status == .optimal else { issues.append("status \(out.status) but oracle optimal \(zstar)"); return issues }
        guard let z = out.objective, let x = out.primal else { issues.append("optimal without objective/primal"); return issues }
        let tol = 1e-6 * (1 + abs(zstar))
        // better than the optimum?
        if maxim ? z > zstar + tol : z < zstar - tol { issues.append("objective \(z) better than true optimum \(zstar)") }
        // within gap
        let worse = maxim ? zstar - z : z - zstar
        if worse > slack(z, gapUsed) + tol { issues.append("objective \(z) worse than optimum \(zstar) by \(worse) > gap slack \(slack(z, gapUsed))") }
        // primal checks against the ORIGINAL problem
        for j in 0..<inst.nI where abs(x[j] - x[j].rounded()) > 1e-9 { issues.append("x[\(j)]=\(x[j]) not integral") }
        let v = lp.maxViolation(at: x)
        var relRow = 0.0
        let act = lp.rowActivity(x)
        for i in 0..<lp.m {
            relRow = max(relRow, (lp.rl[i] - act[i]) / (1 + abs(lp.rl[i])), (act[i] - lp.ru[i]) / (1 + abs(lp.ru[i])))
        }
        if v.bounds > 1e-6 || relRow > 1e-6 { issues.append("primal infeasible: bounds \(v.bounds) rows(rel) \(relRow) x=\(x)") }
        let zx = lp.objective(at: x)
        if abs(zx - z) > 1e-6 * (1 + abs(z)) { issues.append("objectiveValue \(z) != objective(at: primal) \(zx)") }
        if let b = out.bound {
            if maxim ? b < zstar - tol : b > zstar + tol { issues.append("bound \(b) invalid vs true optimum \(zstar)") }
            if maxim ? b < z - tol : b > z + tol { issues.append("bound \(b) on wrong side of incumbent \(z)") }
        } else { issues.append("optimal without bound") }
    }
    return issues
}
