import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func miscProbe(_ args: [String]) async {
    let which = args.count > 2 ? args[2] : "limits"
    switch which {
    case "limits":
        // timeLimit edge values on every engine: never throws, sane status.
        let lp = try! NetlibFixtures.load("degen2")
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        let values: [Double] = [0, -1, .nan, .infinity, -.infinity, 1e-9, 1e300]
        let configs: [Config] = [
            config("Simplex(.dual)", Simplex(.dual), lp), config("Simplex(.primal)", Simplex(.primal), lp),
            config("InteriorPoint()", InteriorPoint(), lp), config("BranchAndBound()", BranchAndBound(), mip),
            config("CPSAT()", CPSAT(), mip), config("Automatic()", Automatic(), mip),
            config("Portfolio", Portfolio([BranchAndBound(), CPSAT()]), mip), config("Conditioned", Conditioned(Simplex(.dual)), lp),
        ]
        for c in configs {
            var line = "\(c.name):"
            for v in values {
                var ctx = SolveContext(); ctx.timeLimit = v
                if v == .infinity || v == 1e300 || v.isNaN { ctx.timeLimit = v }
                let t0 = uptime()
                do {
                    // Guard with an outer cancellation after 20 s so a "no limit" run on the MIP ends.
                    let task = Task.detached { try await c.run(c.problem, ctx) }
                    let watchdog = Task.detached { await sleepSeconds(20); task.cancel() }
                    let r = try await task.value
                    watchdog.cancel()
                    line += " [\(v): \(r.status) \(String(format: "%.2f", uptime() - t0))s]"
                } catch {
                    line += " [\(v): THREW \(error)]"
                }
            }
            print(line)
        }
    case "bound-facades":
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)   // max, optimum 599
        for limit in [0.0003, 0.0005, 0.001] {
            var ctx = SolveContext(); ctx.timeLimit = limit
            let a = try! await Automatic().solve(mip, context: ctx)
            let c = try! await Conditioned(Automatic()).solve(mip, context: ctx)
            print("limit \(limit): Automatic \(a.status) obj \(String(describing: a.objectiveValue)) bound \(String(describing: a.bound)); Conditioned(Automatic) \(c.status) obj \(String(describing: c.objectiveValue)) bound \(String(describing: c.bound))")
        }
        for limit in [1, 2, 3] {
            let r = try! await BranchAndBound(nodeLimit: limit).solve(mip)
            print("nodeLimit \(limit): \(r.status) obj \(String(describing: r.objectiveValue)) bound \(String(describing: r.bound)) gap \(String(describing: r.gap))")
        }
    case "l1":
        // The L1 test timeLimitsAreHonouredPromptly with the limit removed: would it still pass?
        let mip = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        for rep in 0..<3 {
            var line = "rep \(rep) (no time limit; test bound in release 0.25 + 0.200 = 0.45 s):"
            for run in 0..<3 {
                let t0 = uptime()
                let task = Task.detached { () -> SolveStatus in
                    switch run {
                    case 0: return try await BranchAndBound().solve(mip).status
                    case 1: return try await BranchAndBound(engine: InteriorPoint()).solve(mip).status
                    default: return try await CPSAT().solve(mip).status
                    }
                }
                let watchdog = Task.detached { await sleepSeconds(20); task.cancel() }
                let status = (try? await task.value).map { "\($0)" } ?? "threw"
                watchdog.cancel()
                line += " [run \(run): \(status) \(String(format: "%.3f", uptime() - t0)) s]"
            }
            print(line)
        }
    case "threadsedge":
        // threads 0 / negative resolve to at least 1.
        var ctx = SolveContext(); ctx.threads = 0
        var ctx2 = SolveContext(); ctx2.threads = -5
        print("resolvedThreads 0 -> \(ctx.resolvedThreads), -5 -> \(ctx2.resolvedThreads), nil -> \(SolveContext().resolvedThreads)")
        let mip = InstanceGenerator.randomMILP(rows: 8, columns: 30, seed: 17, upper: 1)
        let r = try? await BranchAndBound().solve(mip, context: ctx2)
        let s = try? await CPSAT().solve(mip, context: ctx2)
        let s2 = try? await CPSAT(workers: 0).solve(mip)
        let p = try? await Portfolio([BranchAndBound(), CPSAT()]).solve(mip, context: ctx2)
        print("threads -5: BnB \(String(describing: r?.status)); CPSAT \(String(describing: s?.status)) workers \(String(describing: s?.workers)); CPSAT(workers:0) \(String(describing: s2?.status)) workers \(String(describing: s2?.workers)); Portfolio \(String(describing: p?.status))")
        var m = SolveContext(); m.memoryBudgetBytes = -100
        print("MemoryBudget.resolve(-100) = \(MemoryBudget.resolve(m)); default = \(MemoryBudget.resolve(SolveContext())); available \(MemoryBudget.availableBytes())")
    default:
        print("unknown")
    }
}
