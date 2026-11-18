// Time limits, node-limit monotonicity, memory budget.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func timed<S: SolverStrategy>(_ s: S, _ lp: CompiledLP, _ ctx: SolveContext) async -> (Double, Result<S.Analysis, Error>) {
    let t = nowNs()
    do { let a = try await s.solve(lp, context: ctx); return (secs(t), .success(a)) } catch { return (secs(t), .failure(error)) }
}

func limitCase<S: SolverStrategy>(_ label: String, _ s: S, _ lp: CompiledLP, limit: Double, margin: Double = 0.25) async {
    var ctx = SolveContext()
    ctx.timeLimit = limit
    let (el, r) = await timed(s, lp, ctx)
    switch r {
    case .success(let a):
        let st = a.status
        let okStatus = st == .optimal || st == .infeasible || st.stopReason == .timeLimit
        let over = el - max(limit, 0)
        let verdict = (okStatus && over <= margin) ? "OK" : "SUSPECT"
        var extra = ""
        if let pc = checkPrimal(lp, a), st.hasSolution { extra = " " + pc.description }
        print("LIMIT \(verdict) \(label) limit=\(limit) elapsed=\(String(format: "%.3f", el)) over=\(String(format: "%.3f", over)) status=\(statusName(st))\(extra)")
    case .failure(let e):
        print("LIMIT THREW \(label) limit=\(limit) elapsed=\(String(format: "%.3f", el)) error=\(e)")
    }
}

func runLimits(_ args: [String]) async {
    let lp = Problems.lpTransport()
    let mip = Problems.mipHard()
    let which = args.first ?? "all"
    if which == "all" || which == "time" {
        for limit in [0.0, -1.0, 0.05, 0.3] {
            await limitCase("Simplex(.primal)/transport", Simplex(.primal), lp, limit: limit)
            await limitCase("Simplex(.dual)/transport", Simplex(.dual), lp, limit: limit)
            await limitCase("InteriorPoint/transport", InteriorPoint(), lp, limit: limit)
            await limitCase("Automatic/transport", Automatic(), lp, limit: limit)
            await limitCase("Portfolio(primal,dual,ipm)/transport", Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()]), lp, limit: limit)
            await limitCase("Conditioned(dual)/transport", Conditioned(Simplex(.dual)), lp, limit: limit)
            await limitCase("BranchAndBound/mipHard", BranchAndBound(), mip, limit: limit)
            await limitCase("BranchAndBound(ipm)/mipHard", BranchAndBound(engine: InteriorPoint()), mip, limit: limit)
            await limitCase("CPSAT/mipHard", CPSAT(), mip, limit: limit)
            await limitCase("Automatic/mipHard", Automatic(), mip, limit: limit)
            await limitCase("Portfolio(bnb,cpsat)/mipHard", Portfolio([BranchAndBound(), CPSAT()]), mip, limit: limit)
            await limitCase("Conditioned(bnb)/mipHard", Conditioned(BranchAndBound()), mip, limit: limit)
        }
    }
    if which == "all" || which == "nan" {
        // NaN / infinite limits: documented at Deadline.after as "no deadline".
        for limit in [Double.nan, Double.infinity] {
            var ctx = SolveContext()
            ctx.timeLimit = limit
            let task = Task { await timed(BranchAndBound(), mip, ctx) }
            let killer = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); task.cancel() }
            let (el, r) = await task.value
            killer.cancel()
            let st = (try? r.get())?.status
            print("LIMIT nonfinite limit=\(limit) elapsed=\(String(format: "%.3f", el)) status=\(st.map(statusName) ?? "threw") (cancelled by probe after 3 s if still running)")
        }
    }
    if which == "all" || which == "monotone" {
        // Monotonicity under tighter node limits (deterministic search: a prefix of the longer one).
        var prevObj: Double? = nil, prevBound: Double? = nil
        var violations = 0
        for limit in [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000] {
            var ctx = SolveContext()
            ctx.timeLimit = 60
            let s = BranchAndBound(nodeLimit: limit, deterministic: true)
            let (el, r) = await timed(s, mip, ctx)
            guard case .success(let a) = r else { print("MONO threw at \(limit)"); continue }
            // maximization model: incumbent must not decrease, bound must not increase.
            let obj = a.objectiveValue, bnd = a.bound
            var note = ""
            if let p = prevObj, let o = obj, o < p - 1e-9 { note += " OBJ-WORSE"; violations += 1 }
            if prevObj != nil && obj == nil { note += " LOST-INCUMBENT"; violations += 1 }
            if let p = prevBound, let b = bnd, b > p + 1e-9 { note += " BOUND-LOOSER"; violations += 1 }
            print("MONO nodeLimit=\(limit) status=\(statusName(a.status)) obj=\(f(obj)) bound=\(f(bnd)) nodes=\(a.nodesProcessed) t=\(String(format: "%.2f", el))\(note)")
            prevObj = obj ?? prevObj; prevBound = bnd ?? prevBound
        }
        print("MONO violations=\(violations)")
    }
}

func runMemory(_ args: [String]) async {
    let mip = Problems.mipHard()
    for budget in [0, 1 << 10, 1 << 14, 1 << 18, 1 << 22, -5] {
        var ctx = SolveContext()
        ctx.timeLimit = 8
        ctx.memoryBudgetBytes = budget
        let (e1, r1) = await timed(BranchAndBound(), mip, ctx)
        let s1 = (try? r1.get()).map { "\(statusName($0.status)) obj=\(f($0.objectiveValue)) nodes=\($0.nodesProcessed) open=\($0.nodesOpen)" } ?? "threw \(r1)"
        print("MEM bnb budget=\(budget) t=\(String(format: "%.2f", e1)) \(s1)")
        let (e2, r2) = await timed(CPSAT(), mip, ctx)
        let s2 = (try? r2.get()).map { "\(statusName($0.status)) obj=\(f($0.objectiveValue)) learned=\($0.learnedClauses) lpSolves=\($0.lpSolves)" } ?? "threw \(r2)"
        print("MEM cpsat budget=\(budget) t=\(String(format: "%.2f", e2)) \(s2)")
        let (e3, r3) = await timed(Portfolio([BranchAndBound(), CPSAT()]), mip, ctx)
        let s3 = (try? r3.get()).map { "\(statusName($0.status)) obj=\(f($0.objectiveValue)) winner=\($0.winner) others=\($0.others.map { "\($0.strategy):\(statusName($0.status))" })" } ?? "threw \(r3)"
        print("MEM portfolio budget=\(budget) t=\(String(format: "%.2f", e3)) \(s3)")
    }
}
