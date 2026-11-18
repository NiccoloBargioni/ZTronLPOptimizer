// Further F7 probes.
//   F7 hilbertwarn lo hi      every warning of every Hilbert answer (form x engine), orders lo...hi
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum F7Extra {
    static func run(_ mode: String, _ args: [String]) async -> Bool {
        do {
            switch mode {
            case "hilbertwarn": try await hilbertWarn(args)
            case "latency": try await latency(args)
            case "membudget": try await memBudget(args)
            default: return false
            }
        } catch { print("THREW: \(error)") }
        return true
    }

    static func hilbertWarn(_ args: [String]) async throws {
        let lo = args.count > 0 ? Int(args[0]) ?? 3 : 3
        let hi = args.count > 1 ? Int(args[1]) ?? 6 : 6
        var context = SolveContext()
        context.timeLimit = 60
        for order in lo...hi {
            var count = 0
            for form in HilbertForm.allCases {
                let instance = InstanceGenerator.hilbert(order: order, form: form)
                let engines: [(String, any SolverStrategy)] = [("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal)", Simplex(.primal)), ("InteriorPoint()", InteriorPoint())]
                for (name, strategy) in engines {
                    let a = try await strategy.solve(instance.lp, context: context)
                    if !a.warnings.isEmpty { count += 1 }
                    print("order \(order) \(form.rawValue) \(name): \(a.status) warnings=\(a.warnings)")
                }
            }
            print("order \(order): \(count) of 12 answers carry a warning")
        }
    }

    /// The benchmark's latency rows, with the samples split by what LivenessHarness records:
    /// a solve that returned before the cancel counts as latency 0 in p50/p99/max.
    static func latency(_ args: [String]) async throws {
        let lp = try NetlibFixtures.load("degen2")
        let hard = InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1)
        var rng = SeededGenerator(seed: 5)
        var limited = SolveContext()
        limited.timeLimit = 5
        func duration(_ body: () async throws -> Void) async rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try await body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        func row(_ name: String, _ window: Double, _ sample: (Double) async -> LivenessHarness.CancellationSample) async {
            var all: [Double] = [], late: [Double] = []
            var interrupted = 0, finishedFirst = 0, optimalAfterCancel = 0
            for _ in 0..<40 {
                let r = await sample(rng.uniform(in: 0...window))
                all.append(r.latency)
                if r.finishedFirst { finishedFirst += 1 } else { late.append(r.latency) }
                if r.status.stopReason == .cancelled { interrupted += 1 } else if !r.finishedFirst { optimalAfterCancel += 1 }
            }
            func q(_ v: [Double], _ x: Double) -> String { String(format: "%.2f", LivenessHarness.quantile(v, x) * 1000) }
            print("\(name): window \(String(format: "%.3f", window)) s; interrupted \(interrupted), finished before the cancel (recorded as 0 ms) \(finishedFirst), returned uninterrupted after the cancel \(optimalAfterCancel); with zeros p50 \(q(all, 0.5)) p99 \(q(all, 0.99)) max \(q(all, 1)); without zeros p50 \(q(late, 0.5)) p99 \(q(late, 0.99))")
        }
        let w0 = try await duration { _ = try await Simplex(.primal).solve(lp) }
        await row("Simplex(.primal)", w0) { await LivenessHarness.cancellationLatency(Simplex(.primal), problem: lp, after: $0) }
        let w2 = try await duration { _ = try await InteriorPoint().solve(lp) }
        await row("InteriorPoint", w2) { await LivenessHarness.cancellationLatency(InteriorPoint(), problem: lp, after: $0) }
        let w3 = try await duration { _ = try await BranchAndBound().solve(hard, context: limited) }
        await row("BranchAndBound", w3) { await LivenessHarness.cancellationLatency(BranchAndBound(), problem: hard, after: $0) }
    }

    /// BranchAndBoundTests.memoryBudgetDegradesThenStops uses this instance and solver at 2,000 bytes
    /// and accepts `.optimal`; print what each budget actually gives, including no budget at all.
    static func memBudget(_ args: [String]) async throws {
        let lp = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)
        let budgets: [Int?] = [2_000, 4_096, 16 * 1024 * 1024, nil]
        for budget in budgets {
            var context = SolveContext()
            context.memoryBudgetBytes = budget
            context.timeLimit = 60
            let a = try await BranchAndBound(nodeSelection: .bestBound, heuristics: .none).solve(lp, context: context)
            print("budget \(budget.map(String.init) ?? "nil (default)"): \(a.status) nodes \(a.nodesProcessed) objective \(a.objectiveValue ?? .nan) s \(String(format: "%.2f", a.seconds))")
        }
    }
}
