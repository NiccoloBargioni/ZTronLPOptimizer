// Cancellation latency, statuses and lingering CPU after cancellation, for every strategy.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum Problems {
    static func lpTransport() -> CompiledLP { InstanceGenerator.transport(sources: 60, sinks: 600, seed: 11) }
    static func lpDegen2() -> CompiledLP { try! NetlibFixtures.load("degen2") }
    static func mipLiveness() -> CompiledLP { InstanceGenerator.randomMILP(rows: 14, columns: 70, seed: 4242, upper: 1) }
    static func mipHard() -> CompiledLP { InstanceGenerator.randomMILP(rows: 25, columns: 120, seed: 99, upper: 1) }
}

func fullDuration<S: SolverStrategy>(_ s: S, _ lp: CompiledLP, limit: Double) async -> (Double, String) {
    var ctx = SolveContext()
    ctx.timeLimit = limit
    let t = nowNs()
    let status: String
    do { status = statusName(try await s.solve(lp, context: ctx).status) } catch { status = "threw \(error)" }
    return (secs(t), status)
}

func cancelSeries<S: SolverStrategy>(
    _ label: String, _ s: S, _ lp: CompiledLP, reps: Int, seed: UInt64, windowCap: Double = 1.0, baseContext: SolveContext = .init()
) async -> (p50: Double, p99: Double, worst: Double, interrupted: Int, badStatus: [String], idle: Double) {
    let (window0, fullStatus) = await fullDuration(s, lp, limit: 20)
    let window = min(window0, windowCap)
    var rng = SeededGenerator(seed: seed)
    var lat: [Double] = []
    var interrupted = 0
    var bad: [String] = []
    for _ in 0..<reps {
        let delay = rng.uniform(in: 0...window)
        let sample = await LivenessHarness.cancellationLatency(s, problem: lp, context: baseContext, after: delay)
        lat.append(sample.latency)
        if sample.status.stopReason == .cancelled { interrupted += 1 }
        let ok = sample.status == .optimal || sample.status.stopReason == .cancelled || (sample.finishedFirst && sample.status.hasSolution)
        if !ok { bad.append(statusName(sample.status) + (sample.finishedFirst ? "[finishedFirst]" : "")) }
    }
    let idle = await idleCPU(over: 0.6)
    let p50 = quantile(lat, 0.5), p99 = quantile(lat, 0.99), worst = lat.max() ?? 0
    print("CANCEL \(label): full=\(String(format: "%.3f", window0))s(\(fullStatus)) reps=\(reps) interrupted=\(interrupted) p50=\(ms(p50))ms p99=\(ms(p99))ms worst=\(ms(worst))ms idleCPU(0.6s)=\(String(format: "%.3f", idle))s bad=\(bad)")
    fflush(stdout)
    return (p50, p99, worst, interrupted, bad, idle)
}

func runCancel(_ args: [String]) async {
    let reps = args.count > 0 ? Int(args[0]) ?? 20 : 20
    let which = args.count > 1 ? args[1] : "all"
    let lp = Problems.lpTransport()
    let mip = Problems.mipHard()
    print("lp transport m=\(lp.m) n=\(lp.n) nnz=\(lp.nnz); mip m=\(mip.m) n=\(mip.n)")
    if which == "all" || which == "lp" {
        _ = await cancelSeries("Simplex(.primal)/transport", Simplex(.primal), lp, reps: reps, seed: 1)
        _ = await cancelSeries("Simplex(.dual)/transport", Simplex(.dual), lp, reps: reps, seed: 2)
        _ = await cancelSeries("InteriorPoint()/transport", InteriorPoint(), lp, reps: reps, seed: 3)
        _ = await cancelSeries("Automatic()/transport", Automatic(), lp, reps: reps, seed: 4)
        _ = await cancelSeries("Portfolio(dual,ipm)/transport", Portfolio([Simplex(.dual), InteriorPoint()]), lp, reps: reps, seed: 5)
        _ = await cancelSeries("Conditioned(dual)/transport", Conditioned(Simplex(.dual)), lp, reps: reps, seed: 6)
    }
    if which == "all" || which == "mip" {
        _ = await cancelSeries("BranchAndBound()/mipHard", BranchAndBound(), mip, reps: reps, seed: 7)
        _ = await cancelSeries("BranchAndBound(dual)/mipHard", BranchAndBound(engine: Simplex(.dual)), mip, reps: reps, seed: 8)
        _ = await cancelSeries("BranchAndBound(ipm)/mipHard", BranchAndBound(engine: InteriorPoint()), mip, reps: reps, seed: 9)
        _ = await cancelSeries("CPSAT()/mipHard", CPSAT(), mip, reps: reps, seed: 10)
        _ = await cancelSeries("CPSAT(lp:false)/mipHard", CPSAT(lpPropagator: false), mip, reps: reps, seed: 11)
        _ = await cancelSeries("Automatic()/mipHard", Automatic(), mip, reps: reps, seed: 12)
        _ = await cancelSeries("Portfolio(bnb,cpsat)/mipHard", Portfolio([BranchAndBound(), CPSAT()]), mip, reps: reps, seed: 13)
        _ = await cancelSeries("Conditioned(bnb)/mipHard", Conditioned(BranchAndBound()), mip, reps: reps, seed: 14)
        _ = await cancelSeries("Conditioned(cpsat)/mipHard", Conditioned(CPSAT()), mip, reps: reps, seed: 15)
    }
}
