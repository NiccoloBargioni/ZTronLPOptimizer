// Cycle B / F6 probe helpers: timing, CPU usage, independent oracles.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func secs(_ from: UInt64) -> Double { Double(nowNs() &- from) / 1e9 }

/// Process CPU seconds (user + system) so far.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

/// CPU seconds this process burns while it sleeps `seconds` on the main task: lingering work.
func idleCPU(over seconds: Double) async -> Double {
    let before = cpuSeconds()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    return cpuSeconds() - before
}

func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }
func f(_ x: Double?) -> String { x.map { String(format: "%.9g", $0) } ?? "nil" }

func quantile(_ v: [Double], _ q: Double) -> Double { LivenessHarness.quantile(v, q) }

/// Independent primal check of a returned point: bound and row violations, objective recomputed.
struct PrimalCheck: CustomStringConvertible {
    let boundViolation: Double
    let rowViolation: Double
    let integrality: Double
    let objectiveRecomputed: Double
    let objectiveReported: Double?
    var description: String {
        "boundViol=\(String(format: "%.2e", boundViolation)) rowViol=\(String(format: "%.2e", rowViolation)) intViol=\(String(format: "%.2e", integrality)) obj(rep)=\(f(objectiveReported)) obj(recomp)=\(f(objectiveRecomputed))"
    }
}

func checkPrimal(_ lp: CompiledLP, _ a: some SolutionAnalysis) -> PrimalCheck? {
    guard let x = a.primal, x.count == lp.n else { return nil }
    var bv = 0.0
    for j in 0..<lp.n { bv = max(bv, lp.xl[j] - x[j], x[j] - lp.xu[j]) }
    let act = lp.a.multiply(x)
    var rv = 0.0
    for i in 0..<lp.m {
        let scale = 1 + max(abs(lp.rl[i].isFinite ? lp.rl[i] : 0), abs(lp.ru[i].isFinite ? lp.ru[i] : 0))
        rv = max(rv, (lp.rl[i] - act[i]) / scale, (act[i] - lp.ru[i]) / scale)
    }
    var iv = 0.0
    for j in lp.integerColumns { iv = max(iv, abs(x[Int(j)] - x[Int(j)].rounded())) }
    return PrimalCheck(boundViolation: bv, rowViolation: rv, integrality: iv, objectiveRecomputed: lp.objective(at: x), objectiveReported: a.objectiveValue)
}

/// Exhaustive enumeration of a pure integer problem with small finite integer boxes.
/// Returns the optimum in the model's sense, or nil if infeasible.
func enumerateOptimum(_ lp: CompiledLP) -> Double? {
    precondition(lp.integerColumns.count == lp.n, "pure integer only")
    let n = lp.n
    var lo = [Int](repeating: 0, count: n), hi = [Int](repeating: 0, count: n)
    var total = 1.0
    for j in 0..<n {
        lo[j] = Int(lp.xl[j].rounded(.up)); hi[j] = Int(lp.xu[j].rounded(.down))
        total *= Double(hi[j] - lo[j] + 1)
    }
    precondition(total <= 5e6, "box too large to enumerate")
    var x = lo.map(Double.init)
    var best: Double? = nil
    // row activities maintained incrementally would be faster; brute force is fine at this size
    func feasible() -> Bool {
        let act = lp.a.multiply(x)
        for i in 0..<lp.m where act[i] < lp.rl[i] - 1e-9 || act[i] > lp.ru[i] + 1e-9 { return false }
        return true
    }
    while true {
        if feasible() {
            let v = lp.internalObjective(at: x)
            if best == nil || v < best! { best = v }
        }
        var k = 0
        while k < n {
            if x[k] < Double(hi[k]) { x[k] += 1; break }
            x[k] = Double(lo[k]); k += 1
        }
        if k == n { break }
    }
    return best.map { lp.reportedObjective($0) }
}

/// A random pure binary/integer knapsack-like MIP small enough to enumerate.
func smallIP(seed: UInt64, rows: Int = 6, cols: Int = 14, upper: Int = 1) -> CompiledLP {
    InstanceGenerator.randomMILP(rows: rows, columns: cols, seed: seed, integerFraction: 1, upper: upper)
}

func statusName(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infeasibleOrUnbounded"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let t): return "numericalFailure(\(t.prefix(80)))"
    }
}

/// Runs an async body under a wall-clock watchdog: prints and exits if it exceeds `limit`.
func watchdog(_ limit: Double, _ label: String) -> Task<Void, Never> {
    Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(limit * 1e9))
        if !Task.isCancelled {
            print("WATCHDOG: \(label) exceeded \(limit) s")
            fflush(stdout)
            exit(3)
        }
    }
}
