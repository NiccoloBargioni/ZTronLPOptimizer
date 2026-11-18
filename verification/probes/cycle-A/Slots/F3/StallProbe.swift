import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class Clock: @unchecked Sendable {
    let lock = NSLock()
    var stalledAt: Double? = nil
    var start = Date()
    var task: Task<InteriorPointAnalysis, Error>? = nil
    var cancelOnStall = false
    func onEvent(_ event: SolverEvent) {
        if case .warning(let text) = event, text.contains("stalled") {
            lock.lock()
            stalledAt = Date().timeIntervalSince(start)
            if cancelOnStall { task?.cancel() }
            lock.unlock()
        }
    }
}

/// Block-diagonal LP: a Hilbert equality block (makes the IPM stall) plus a degenerate
/// assignment block with tied costs (makes the crossover from the last iterate take pivots).
func stallPlusAssignment(hilbert order: Int, assignment size: Int) -> (CompiledLP, Double) {
    var entries: [(row: Int, col: Int, value: Double)] = []
    var c: [Double] = []
    var rl: [Double] = []
    var ru: [Double] = []
    var objective = 0.0
    for i in 0..<order {
        var b = 0.0
        for j in 0..<order {
            let v = 1 / Double(i + j + 1)
            entries.append((i, j, v))
            b += v
        }
        rl.append(b); ru.append(b)
        objective += b
    }
    for j in 0..<order {
        var cj = 0.0
        for i in 0..<order { cj += 1 / Double(i + j + 1) }
        c.append(cj)
    }
    let base = order
    for i in 0..<size {
        for j in 0..<size {
            let col = order + i * size + j
            c.append(Double((i * 7 + j * 3) % 4))
            entries.append((base + i, col, 1))
            entries.append((base + size + j, col, 1))
        }
    }
    for _ in 0..<(2 * size) { rl.append(1); ru.append(1) }
    let n = c.count
    let lp = CompiledLP(
        a: SparseCSC.fromTriplets(rows: order + 2 * size, cols: n, entries), c: c,
        xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n), rl: rl, ru: ru)
    return (lp, objective)
}

/// C5: "never returns .feasible: a limit or a cancellation gives .noSolution", including a stop
/// that lands in the crossover of the stalled path. args: [order size steps]
func probeStallCancel(_ args: [String]) async throws {
    let order = args.count > 0 ? Int(args[0])! : 8
    let size = args.count > 1 ? Int(args[1])! : 30
    let steps = args.count > 2 ? Int(args[2])! : 30
    let (lp, _) = stallPlusAssignment(hilbert: order, assignment: size)
    let reference = try await Simplex(.dual).solve(lp, context: ctx())
    print("model \(lp.m)x\(lp.n); simplex \(statusName(reference.status)) obj \(reference.objectiveValue ?? .nan)")
    let strategy = InteriorPoint()
    // Free run: timings.
    let clock = Clock()
    var context = ctx(120)
    context.progress = { clock.onEvent($0) }
    clock.start = Date()
    let free = try await strategy.solve(lp, context: context)
    let total = Date().timeIntervalSince(clock.start)
    let stall = clock.stalledAt ?? .nan
    print("free run: \(statusName(free.status)) obj \(free.objectiveValue ?? .nan) ipm it \(free.iterations) crossover it \(free.crossover?.iterations ?? -1) stalled at \(String(format: "%.4f", stall)) s, total \(String(format: "%.4f", total)) s warnings \(free.warnings.map { String($0.prefix(60)) })")
    guard stall.isFinite else { print("no stall: nothing to scan"); return }
    var seen: [String: Int] = [:]
    for k in 0...steps {
        let limit = stall + (total - stall) * Double(k) / Double(steps)
        var c = SolveContext()
        c.timeLimit = limit
        let a = try await strategy.solve(lp, context: c)
        let name = statusName(a.status)
        seen[name, default: 0] += 1
        var extra = ""
        if let x = a.primal { extra = " viol=\(lp.maxViolation(at: x)) obj=\(a.objectiveValue ?? .nan)" }
        print(String(format: "limit %.4f s: ", limit) + "\(name) xover=\(a.crossover.map { statusName($0.status) + " it \($0.iterations)" } ?? "nil")\(extra)")
    }
    // Cancel exactly when the stall is announced.
    for _ in 0..<5 {
        let cl = Clock()
        cl.cancelOnStall = true
        var c = ctx(120)
        c.progress = { cl.onEvent($0) }
        cl.start = Date()
        let task = Task { try await strategy.solve(lp, context: c) }
        cl.lock.lock(); cl.task = task; cl.lock.unlock()
        let a = try await task.value
        let name = "cancel-on-stall " + statusName(a.status)
        seen[name, default: 0] += 1
        print("\(name) xover=\(a.crossover.map { statusName($0.status) + " it \($0.iterations)" } ?? "nil") obj=\(a.objectiveValue ?? .nan)")
    }
    print("statuses seen: \(seen)")
}
