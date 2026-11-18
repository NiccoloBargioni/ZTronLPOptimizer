import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }

func sleepSeconds(_ s: Double) async {
    if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
}

func quantile(_ values: [Double], _ q: Double) -> Double {
    LivenessHarness.quantile(values, q)
}

/// A type-erased strategy runner.
struct Config: Sendable {
    let name: String
    let problem: CompiledLP
    let run: @Sendable (CompiledLP, SolveContext) async throws -> (status: SolveStatus, objective: Double?, extra: String)
}

func config<S: SolverStrategy>(_ name: String, _ s: S, _ p: CompiledLP, extra: @escaping @Sendable (S.Analysis) -> String = { _ in "" }) -> Config {
    Config(name: name, problem: p) { lp, ctx in
        let a = try await s.solve(lp, context: ctx)
        return (a.status, a.objectiveValue, extra(a))
    }
}

struct CancelSample {
    let latency: Double
    let status: String
    let stopReason: StopReason?
    let finishedFirst: Bool
    let idleCPU: Double   // CPU seconds consumed by the process in the 300 ms after return
    let threw: Bool
}

func cancelSample(_ c: Config, delay: Double, context: SolveContext = .init(), idleWindow: Double = 0.3) async -> CancelSample {
    let task = Task.detached { () -> (String, StopReason?, Bool, UInt64) in
        do {
            let r = try await c.run(c.problem, context)
            return ("\(r.status)", r.status.stopReason, false, DispatchTime.now().uptimeNanoseconds)
        } catch {
            return ("threw \(error)", nil, true, DispatchTime.now().uptimeNanoseconds)
        }
    }
    await sleepSeconds(delay)
    let cancelled = DispatchTime.now().uptimeNanoseconds
    task.cancel()
    let (status, reason, threw, returned) = await task.value
    let c0 = cpuSeconds()
    await sleepSeconds(idleWindow)
    let c1 = cpuSeconds()
    let first = returned <= cancelled
    return CancelSample(
        latency: first ? 0 : Double(returned - cancelled) / 1e9, status: status, stopReason: reason,
        finishedFirst: first, idleCPU: c1 - c0, threw: threw)
}

func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let t0 = uptime()
    let r = try await body()
    return (r, uptime() - t0)
}

/// Transport LP with an extra dense column that has an entry in every row (cost `denseCost`).
func transportWithDenseColumn(sources: Int, sinks: Int, seed: UInt64, denseFraction: Double = 1.0, denseCost: Double = 500) -> CompiledLP {
    var rng = SeededGenerator(seed: seed)
    let n0 = sources * sinks
    let m = sources + sinks
    var entries: [(row: Int, col: Int, value: Double)] = []
    entries.reserveCapacity(2 * n0 + m)
    var c = [Double](repeating: 0, count: n0 + 1)
    for s in 0..<sources {
        for t in 0..<sinks {
            let j = s * sinks + t
            entries.append((s, j, 1))
            entries.append((sources + t, j, 1))
            c[j] = (rng.uniform(in: 1...100)).rounded()
        }
    }
    let demand = (0..<sinks).map { _ in (rng.uniform(in: 5...50)).rounded() }
    let totalDemand = demand.reduce(0, +)
    var supply = (0..<sources).map { _ in rng.uniform(in: 1...2) }
    let weight = supply.reduce(0, +)
    supply = supply.map { ($0 / weight * totalDemand * 1.2).rounded(.up) }
    // Dense column: +1 in a fraction of the demand rows (helps demand) and in the supply rows.
    for i in 0..<m where Double(i % 100) < denseFraction * 100 { entries.append((i, n0, 1)) }
    c[n0] = denseCost
    var rl = [Double](repeating: -.infinity, count: m)
    var ru = [Double](repeating: .infinity, count: m)
    for s in 0..<sources { ru[s] = supply[s] }
    for t in 0..<sinks { rl[sources + t] = demand[t] }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: m, cols: n0 + 1, entries), c: c,
        xl: [Double](repeating: 0, count: n0 + 1), xu: [Double](repeating: .infinity, count: n0 + 1), rl: rl, ru: ru)
}

func statusName(_ s: SolveStatus) -> String { "\(s)" }
