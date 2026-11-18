// Cycle A, slot F4: shared helpers — model builder, independent enumeration oracle, runner.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let INF = Double.infinity

/// Builds a CompiledLP from dense rows. `c` is in the model's own sense.
func makeLP(
    c: [Double], c0: Double = 0, rows: [[Double]], rl: [Double], ru: [Double], xl: [Double], xu: [Double],
    integer: [Int], sense: ObjectiveSense
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, c0: flip * c0,
        sense: sense, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer.sorted().map { Int32($0) })
}

/// Dense copy of A, row-major.
func denseRows(_ lp: CompiledLP) -> [[Double]] {
    var rows = [[Double]](repeating: [Double](repeating: 0, count: lp.n), count: lp.m)
    for j in 0..<lp.n {
        var e = [Double](repeating: 0, count: lp.n)
        e[j] = 1
        let col = lp.a.multiply(e)
        for i in 0..<lp.m { rows[i][j] = col[i] }
    }
    return rows
}

struct OracleAnswer {
    /// Internal (minimisation-form) optimum.
    var internalValue: Double
    var point: [Double]
    var feasibleIntegerPoints: Int
}

/// Exhaustive enumeration of the integer part (finite bounds required, rounded inward); the
/// continuous part (at most a few columns, finite bounds required) is solved for each integer
/// assignment by vertex enumeration — an LP method independent of the package's engines.
/// Returns nil when the MILP is infeasible.
func enumerateMILP(_ lp: CompiledLP, tol: Double = 1e-9) -> OracleAnswer? {
    let A = denseRows(lp)
    let isInt = lp.integerMask()
    let ints = (0..<lp.n).filter { isInt[$0] }
    let conts = (0..<lp.n).filter { !isInt[$0] }
    precondition(ints.allSatisfy { lp.xl[$0].isFinite && lp.xu[$0].isFinite }, "integer bounds must be finite")
    precondition(conts.allSatisfy { lp.xl[$0].isFinite && lp.xu[$0].isFinite }, "continuous bounds must be finite")
    let lo = ints.map { lp.xl[$0].rounded(.up) }
    let hi = ints.map { lp.xu[$0].rounded(.down) }
    if zip(lo, hi).contains(where: { $0 > $1 }) { return nil }
    var assign = lo
    var best: OracleAnswer? = nil
    var count = 0
    let k = conts.count
    while true {
        // Residual row bounds.
        var rlo = lp.rl, rhi = lp.ru
        for i in 0..<lp.m {
            var s = 0.0
            for (t, j) in ints.enumerated() { s += A[i][j] * assign[t] }
            rlo[i] -= s
            rhi[i] -= s
        }
        var intObj = lp.c0
        for (t, j) in ints.enumerated() { intObj += lp.c[j] * assign[t] }
        if let (yval, y) = solveContinuous(A: A, conts: conts, rlo: rlo, rhi: rhi, lp: lp, tol: tol) {
            _ = k
            count += 1
            let value = intObj + yval
            if best == nil || value < best!.internalValue - 1e-12 {
                var point = [Double](repeating: 0, count: lp.n)
                for (t, j) in ints.enumerated() { point[j] = assign[t] }
                for (t, j) in conts.enumerated() { point[j] = y[t] }
                best = OracleAnswer(internalValue: value, point: point, feasibleIntegerPoints: 0)
            }
        }
        // odometer
        var t = 0
        while t < ints.count {
            if assign[t] < hi[t] { assign[t] += 1; break }
            assign[t] = lo[t]
            t += 1
        }
        if t == ints.count { break }
    }
    best?.feasibleIntegerPoints = count
    return best
}

/// min c_y·y s.t. rlo ≤ A_y y ≤ rhi, yl ≤ y ≤ yu by vertex enumeration. nil when infeasible.
func solveContinuous(A: [[Double]], conts: [Int], rlo: [Double], rhi: [Double], lp: CompiledLP, tol: Double) -> (Double, [Double])? {
    let m = A.count
    let k = conts.count
    func feasible(_ y: [Double]) -> Bool {
        for (t, j) in conts.enumerated() {
            if y[t] < lp.xl[j] - tol * (1 + abs(lp.xl[j])) || y[t] > lp.xu[j] + tol * (1 + abs(lp.xu[j])) { return false }
        }
        for i in 0..<m {
            var s = 0.0
            for (t, j) in conts.enumerated() { s += A[i][j] * y[t] }
            if s < rlo[i] - tol * (1 + abs(rlo[i])) || s > rhi[i] + tol * (1 + abs(rhi[i])) { return false }
        }
        return true
    }
    if k == 0 { return feasible([]) ? (0, []) : nil }
    // Constraint list: (coefficients over y, rhs)
    var cons: [([Double], Double)] = []
    for i in 0..<m {
        let row = conts.map { A[i][$0] }
        if row.allSatisfy({ $0 == 0 }) { continue }
        if rlo[i].isFinite { cons.append((row, rlo[i])) }
        if rhi[i].isFinite && rhi[i] != rlo[i] { cons.append((row, rhi[i])) }
    }
    for (t, j) in conts.enumerated() {
        var e = [Double](repeating: 0, count: k)
        e[t] = 1
        cons.append((e, lp.xl[j]))
        if lp.xu[j] != lp.xl[j] { cons.append((e, lp.xu[j])) }
    }
    var best: (Double, [Double])? = nil
    var idx = Array(0..<k)
    let total = cons.count
    if total < k { return nil }
    while true {
        // Solve the k x k system.
        var M = idx.map { cons[$0].0 }
        var b = idx.map { cons[$0].1 }
        var ok = true
        for col in 0..<k {
            var piv = col
            for r in col..<k where abs(M[r][col]) > abs(M[piv][col]) { piv = r }
            if abs(M[piv][col]) < 1e-12 { ok = false; break }
            M.swapAt(col, piv); b.swapAt(col, piv)
            for r in 0..<k where r != col {
                let f = M[r][col] / M[col][col]
                if f != 0 {
                    for cc in col..<k { M[r][cc] -= f * M[col][cc] }
                    b[r] -= f * b[col]
                }
            }
        }
        if ok {
            let y = (0..<k).map { b[$0] / M[$0][$0] }
            if feasible(y) {
                var v = 0.0
                for (t, j) in conts.enumerated() { v += lp.c[j] * y[t] }
                if best == nil || v < best!.0 { best = (v, y) }
            }
        }
        // next combination
        var p = k - 1
        while p >= 0 && idx[p] == total - k + p { p -= 1 }
        if p < 0 { break }
        idx[p] += 1
        for q in (p + 1)..<k { idx[q] = idx[q - 1] + 1 }
    }
    return best
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SolverEvent] = []
    func append(_ e: SolverEvent) { lock.lock(); items.append(e); lock.unlock() }
    var events: [SolverEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

struct Run {
    var status: SolveStatus
    var objective: Double?
    var bound: Double?
    var primal: [Double]?
    var gap: Double?
    var nodes: Int
    var open: Int
    var iterations: Int
    var history: [IncumbentEvent]
    var seconds: Double
    var warnings: [String]
    var wall: Double
    var events: [SolverEvent]
}

func run<E: NodeLPStrategy>(
    _ s: BranchAndBound<E>, _ lp: CompiledLP, threads: Int? = nil, timeLimit: Double? = 30,
    memory: Int? = nil, captureEvents: Bool = false
) async throws -> Run {
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    ctx.threads = threads
    ctx.memoryBudgetBytes = memory
    ctx.metal = .off
    let log = EventLog()
    if captureEvents { ctx.progress = { e in log.append(e) } }
    let t0 = Date()
    let a = try await s.solve(lp, context: ctx)
    let wall = Date().timeIntervalSince(t0)
    return Run(
        status: a.status, objective: a.objectiveValue, bound: a.bound, primal: a.primal, gap: a.gap,
        nodes: a.nodesProcessed, open: a.nodesOpen, iterations: a.lpIterations, history: a.incumbentHistory,
        seconds: a.seconds, warnings: a.warnings, wall: wall, events: log.events)
}

/// The slack the README states for `.optimal`: max(abs, rel·max(1, |incumbent|)).
func slack(_ incumbent: Double, rel: Double = 1e-4, abs a: Double = 1e-6) -> Double {
    max(a, rel * max(1, abs(incumbent)))
}

func fmt(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.10g", v)
}

func statusName(_ s: SolveStatus) -> String { "\(s)" }

/// Configurations: name and a closure that solves.
struct Config {
    let name: String
    let threads: Int?
    let solve: (CompiledLP, Int?, Double?, Bool) async throws -> Run
}

func cfg<E: NodeLPStrategy>(_ name: String, threads: Int? = nil, _ s: BranchAndBound<E>) -> Config {
    Config(name: name, threads: threads) { lp, th, tl, ev in try await run(s, lp, threads: th, timeLimit: tl, captureEvents: ev) }
}

func standardConfigs() -> [Config] {
    [
        cfg("P-default", BranchAndBound()),
        cfg("D-default", BranchAndBound(engine: Simplex(.dual))),
        cfg("I-default", BranchAndBound(engine: InteriorPoint())),
        cfg("P-det", BranchAndBound(deterministic: true)),
        cfg("D-det", BranchAndBound(engine: Simplex(.dual), deterministic: true)),
        cfg("I-det-nopre", BranchAndBound(engine: InteriorPoint(presolve: false), deterministic: true)),
        cfg("P-nopre-t8", threads: 8, BranchAndBound(engine: Simplex(.primal, presolve: false))),
        cfg("D-mostfrac-noheur", BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none)),
        cfg("P-strong-bestbound", threads: 4, BranchAndBound(branching: .strong(candidates: 6), nodeSelection: .bestBound)),
        cfg("D-depthfirst-t2", threads: 2, BranchAndBound(engine: Simplex(.dual), nodeSelection: .depthFirst)),
        cfg("P-t1", threads: 1, BranchAndBound()),
    ]
}
