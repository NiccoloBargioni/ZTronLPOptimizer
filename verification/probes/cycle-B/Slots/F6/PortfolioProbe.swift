// Portfolio race semantics with scripted strategies and with real engines.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// A scripted strategy: waits `delay` seconds (polling cancellation if `cooperative`), then
/// returns a fixed status/objective, or throws.
struct Scripted: SolverStrategy {
    let name: String
    let delay: Double
    let status: SolveStatus
    let objective: Double?
    var cooperative = true
    var throwsError: SolverError? = nil
    var engineName: String { name }
    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> SolveRecord {
        let t = nowNs()
        while secs(t) < delay {
            if cooperative && Task.isCancelled {
                return SolveRecord(status: .noSolution(stoppedBy: .cancelled), seconds: secs(t))
            }
            if cooperative {
                try? await Task.sleep(nanoseconds: 1_000_000)
            } else {
                // busy, ignores cancellation
                var z = 0.0
                for k in 0..<10_000 { z += Double(k) }
                if z < 0 { print(z) }
            }
        }
        if let e = throwsError { throw e }
        let x = objective.map { _ in [Double](repeating: 0, count: problem.n) }
        return SolveRecord(status: status, objectiveValue: objective, bound: nil, primal: x, seconds: secs(t))
    }
}

func describe(_ a: PortfolioAnalysis) -> String {
    "status=\(statusName(a.status)) obj=\(f(a.objectiveValue)) winner=\(a.winner) baseEngine=\(a.base.engine) others=\(a.others.map { "\($0.strategy):\(statusName($0.status))" }) seconds=\(String(format: "%.3f", a.seconds))"
}

func runPortfolio(_ args: [String]) async {
    let which = args.first ?? "all"
    // A tiny minimization LP for the scripted members (they ignore it).
    let tiny = CompiledLP(
        a: SparseCSC.fromTriplets(rows: 1, cols: 1, [(0, 0, 1.0)]), c: [1], xl: [0], xu: [10], rl: [0], ru: [10])
    if which == "all" || which == "scripted" {
        // S1: two inconclusive feasible results, the worse one arrives first (minimization).
        let p1 = Portfolio([
            Scripted(name: "fastWorse", delay: 0.05, status: .feasible(stoppedBy: .timeLimit), objective: 10),
            Scripted(name: "slowBetter", delay: 0.30, status: .feasible(stoppedBy: .timeLimit), objective: 5),
        ])
        if let a = try? await p1.solve(tiny) { print("PORT S1 two feasible (min; members 10 then 5): \(describe(a))") }
        // S1b: same but listed in the other order
        let p1b = Portfolio([
            Scripted(name: "slowBetter", delay: 0.30, status: .feasible(stoppedBy: .timeLimit), objective: 5),
            Scripted(name: "fastWorse", delay: 0.05, status: .feasible(stoppedBy: .timeLimit), objective: 10),
        ])
        if let a = try? await p1b.solve(tiny) { print("PORT S1b two feasible reversed order: \(describe(a))") }
        // S2: conclusive fast vs cooperative slow -> slow must be cancelled promptly
        let t2 = nowNs()
        let p2 = Portfolio([
            Scripted(name: "fastOptimal", delay: 0.05, status: .optimal, objective: 3),
            Scripted(name: "slowCoop", delay: 5.0, status: .optimal, objective: 3),
        ])
        if let a = try? await p2.solve(tiny) { print("PORT S2 conclusive wins, loser cancelled: wall=\(String(format: "%.3f", secs(t2))) \(describe(a))") }
        // S3: conclusive fast vs non-cooperative slow (documented: plus the others' cancellation latency)
        let t3 = nowNs()
        let p3 = Portfolio([
            Scripted(name: "fastOptimal", delay: 0.05, status: .optimal, objective: 3),
            Scripted(name: "slowDeaf", delay: 1.0, status: .feasible(stoppedBy: .timeLimit), objective: 4, cooperative: false),
        ])
        if let a = try? await p3.solve(tiny) { print("PORT S3 deaf loser: wall=\(String(format: "%.3f", secs(t3))) \(describe(a))") }
        // S4: a thrower and a feasible
        let p4 = Portfolio([
            Scripted(name: "thrower", delay: 0.01, status: .optimal, objective: nil, throwsError: .unsupported("scripted")),
            Scripted(name: "feasible", delay: 0.05, status: .feasible(stoppedBy: .timeLimit), objective: 7),
        ])
        if let a = try? await p4.solve(tiny) { print("PORT S4 thrower+feasible: \(describe(a))") }
        // S5: all throw -> first error by index order
        let p5 = Portfolio([
            Scripted(name: "slowThrowerA", delay: 0.2, status: .optimal, objective: nil, throwsError: .unsupported("A")),
            Scripted(name: "fastThrowerB", delay: 0.01, status: .optimal, objective: nil, throwsError: .internalInconsistency("B")),
        ])
        do { _ = try await p5.solve(tiny); print("PORT S5 all throw: did not throw") } catch { print("PORT S5 all throw: threw \(error) (expected the first by index: unsupported: A)") }
        // S6: conclusive infeasible arriving first vs optimal later: first conclusive wins (documented)
        let p6 = Portfolio([
            Scripted(name: "slowOptimal", delay: 0.2, status: .optimal, objective: 3),
            Scripted(name: "fastNoSolution", delay: 0.01, status: .noSolution(stoppedBy: .timeLimit), objective: nil),
        ])
        if let a = try? await p6.solve(tiny) { print("PORT S6 noSolution first then optimal: \(describe(a))") }
        // S7: maximization: two feasible, worse first
        let tinyMax = CompiledLP(
            a: SparseCSC.fromTriplets(rows: 1, cols: 1, [(0, 0, 1.0)]), c: [-1], sense: .maximize, xl: [0], xu: [10], rl: [0], ru: [10])
        let p7 = Portfolio([
            Scripted(name: "fastWorse", delay: 0.05, status: .feasible(stoppedBy: .nodeLimit), objective: 5),
            Scripted(name: "slowBetter", delay: 0.30, status: .feasible(stoppedBy: .nodeLimit), objective: 10),
        ])
        if let a = try? await p7.solve(tinyMax) { print("PORT S7 two feasible (max; members 5 then 10): \(describe(a))") }
    }
    if which == "all" || which == "real" {
        // R1: real engines, two inconclusive members, deterministic: the faster one has the worse incumbent.
        let mip = Problems.mipHard()
        var ctx = SolveContext()
        ctx.timeLimit = 60
        let small = BranchAndBound(nodeLimit: 3, deterministic: true)
        let large = BranchAndBound(nodeLimit: 3000, deterministic: true)
        let a1 = try? await small.solve(mip, context: ctx)
        let a2 = try? await large.solve(mip, context: ctx)
        print("PORT R1 members alone: small(nodeLimit 3)=\(a1.map { "\(statusName($0.status)) obj=\(f($0.objectiveValue))" } ?? "-") large(nodeLimit 3000)=\(a2.map { "\(statusName($0.status)) obj=\(f($0.objectiveValue))" } ?? "-") (maximization)")
        if let p = try? await Portfolio([small, large]).solve(mip, context: ctx) { print("PORT R1 portfolio([small,large]): \(describe(p))") }
        if let p = try? await Portfolio([large, small]).solve(mip, context: ctx) { print("PORT R1 portfolio([large,small]): \(describe(p))") }
    }
    if which == "all" || which == "oracle" {
        // R2: Portfolio on netlib vs reference values; R3: Portfolio(bnb,cpsat) on small IPs vs enumeration.
        var worst = 0.0
        for name in NetlibFixtures.names {
            guard let lp = try? NetlibFixtures.load(name), let ref = ReferenceValues.netlib(named: name)?.optimalObjective else { continue }
            var ctx = SolveContext()
            ctx.timeLimit = 30
            guard let a = try? await Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()]).solve(lp, context: ctx) else { print("PORT R2 \(name) threw"); continue }
            let err = a.objectiveValue.map { ReferenceValues.relativeError($0, reference: ref) } ?? .infinity
            worst = max(worst, err)
            let pc = checkPrimal(lp, a)
            if err > 1e-6 || a.status != .optimal || (pc?.rowViolation ?? 1) > 1e-6 {
                print("PORT R2 MISMATCH \(name): \(describe(a)) ref=\(ref) relErr=\(err) \(pc?.description ?? "")")
            }
        }
        print("PORT R2 netlib portfolio(primal,dual,ipm): worst relErr=\(worst)")
        var mism = 0
        for seed in UInt64(1)...30 {
            let ip = smallIP(seed: 1000 + seed, rows: 5, cols: 12, upper: seed % 3 == 0 ? 2 : 1)
            let ref = enumerateOptimum(ip)
            var ctx = SolveContext()
            ctx.timeLimit = 20
            guard let a = try? await Portfolio([BranchAndBound(), CPSAT()]).solve(ip, context: ctx) else { print("PORT R3 seed \(seed) threw"); mism += 1; continue }
            let ok = a.status == .optimal && ref != nil && abs(a.objectiveValue! - ref!) <= 1e-6 * max(1, abs(ref!))
            if !ok { mism += 1; print("PORT R3 MISMATCH seed=\(1000 + seed) ref=\(f(ref)) \(describe(a))") }
        }
        print("PORT R3 portfolio(bnb,cpsat) vs enumeration: \(mism) mismatches of 30")
    }
}
