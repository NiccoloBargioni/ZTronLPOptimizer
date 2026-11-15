// Shared helpers of the CP-SAT tests: small random pure-integer programs and a brute-force
// reference solver for them.

import ZTronLPCore
import ZTronLPTestSupport

/// What exhaustive enumeration says about a small pure-integer program.
struct BruteForceResult {
    /// The optimal objective in the model's own sense; `nil` when infeasible.
    var objective: Double?
    var solution: [Double]?
    var feasibleCount: Int
}

/// Enumerates every integer point within the column bounds. Only for tiny models.
func bruteForce(_ lp: CompiledLP) -> BruteForceResult {
    let n = lp.n
    let lower = lp.xl.map { Int($0.rounded(.up)) }
    let upper = lp.xu.map { Int($0.rounded(.down)) }
    var best: Double? = nil
    var bestPoint: [Double]? = nil
    var feasible = 0
    if zip(lower, upper).contains(where: { $0 > $1 }) {
        return BruteForceResult(objective: nil, solution: nil, feasibleCount: 0)
    }
    var x = lower
    let aT = lp.aT
    while true {
        var ok = true
        for i in 0..<lp.m {
            var activity = 0.0
            for p in aT.colStart[i]..<aT.colStart[i + 1] {
                activity += aT.values[p] * Double(x[Int(aT.rowIndex[p])])
            }
            if activity < lp.rl[i] - 1e-9 || activity > lp.ru[i] + 1e-9 {
                ok = false
                break
            }
        }
        if ok {
            feasible += 1
            let point = x.map { Double($0) }
            let value = lp.objective(at: point)
            let better: Bool
            if let current = best {
                better = lp.sense == .maximize ? value > current + 1e-12 : value < current - 1e-12
            } else {
                better = true
            }
            if better {
                best = value
                bestPoint = point
            }
        }
        // Odometer increment.
        var k = 0
        while k < n {
            if x[k] < upper[k] {
                x[k] += 1
                break
            }
            x[k] = lower[k]
            k += 1
        }
        if k == n { break }
    }
    return BruteForceResult(objective: best, solution: bestPoint, feasibleCount: feasible)
}

/// Options of `randomIntegerProgram`.
struct RandomIPOptions {
    var variables = 5
    var rows = 4
    /// Halves and quarters in the data, to exercise the per-row scaling by powers of 10.
    var fractional = false
    var maximize = false
    /// General integers with negative lower bounds, not just binaries.
    var generalIntegers = true
}

/// A small random pure-integer program with negative coefficients, equality and range rows.
/// It may be infeasible; the brute-force reference says so.
func randomIntegerProgram(seed: UInt64, options: RandomIPOptions = .init()) -> CompiledLP {
    var rng = SeededGenerator(seed: seed)
    let n = options.variables
    let m = options.rows
    var xl = [Double](repeating: 0, count: n)
    var xu = [Double](repeating: 1, count: n)
    for j in 0..<n where options.generalIntegers && rng.chance(0.6) {
        let lo = rng.integer(in: -3...1)
        xl[j] = Double(lo)
        xu[j] = Double(lo + rng.integer(in: 1...4))
    }
    func coefficient(_ rng: inout SeededGenerator) -> Double {
        var value = Double(rng.integer(in: -5...5))
        if options.fractional {
            value += [0, 0.5, 0.25, 0.75][rng.integer(in: 0...3)]
        }
        return value
    }
    var entries: [(row: Int, col: Int, value: Double)] = []
    var rl = [Double](repeating: -.infinity, count: m)
    var ru = [Double](repeating: .infinity, count: m)
    // A reference point makes most instances feasible.
    let reference = (0..<n).map { j in Double(rng.integer(in: Int(xl[j])...Int(xu[j]))) }
    for i in 0..<m {
        var activity = 0.0
        var any = false
        for j in 0..<n where rng.chance(0.7) {
            let a = coefficient(&rng)
            if a == 0 { continue }
            entries.append((i, j, a))
            activity += a * reference[j]
            any = true
        }
        if !any {
            let j = rng.integer(in: 0...(n - 1))
            entries.append((i, j, 1))
            activity += reference[j]
        }
        let slackBelow = Double(rng.integer(in: 0...3)) + (options.fractional && rng.chance(0.5) ? 0.5 : 0)
        let slackAbove = Double(rng.integer(in: 0...3)) + (options.fractional && rng.chance(0.5) ? 0.5 : 0)
        switch rng.integer(in: 0...4) {
        case 0:
            ru[i] = activity + slackAbove                                   // ≤
        case 1:
            rl[i] = activity - slackBelow                                   // ≥
        case 2:
            rl[i] = activity                                                // =
            ru[i] = activity
        case 3:
            rl[i] = activity - slackBelow                                   // range
            ru[i] = activity + slackAbove
        default:
            // A row unrelated to the reference point: this is what makes some instances infeasible.
            ru[i] = Double(rng.integer(in: -6...6))
        }
    }
    var cost = (0..<n).map { _ in coefficient(&rng) }
    if cost.allSatisfy({ $0 == 0 }) { cost[0] = 1 }
    let sense: ObjectiveSense = options.maximize ? .maximize : .minimize
    // `c` is stored in minimization form.
    let c = options.maximize ? cost.map { $0 == 0 ? 0 : -$0 } : cost
    let constant = Double(rng.integer(in: -3...3))
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: c,
        c0: options.maximize ? (constant == 0 ? 0 : -constant) : constant, sense: sense,
        xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: (0..<n).map { Int32($0) })
}

/// A thread-safe event recorder usable from the synchronous `progress` callback.
final class EventRecorder: Sendable {
    private let stream: AsyncStream<SolverEvent>
    private let continuation: AsyncStream<SolverEvent>.Continuation

    init() {
        var created: AsyncStream<SolverEvent>.Continuation?
        stream = AsyncStream<SolverEvent>(bufferingPolicy: .unbounded) { created = $0 }
        continuation = created!
    }

    /// The callback to install in `SolveContext.progress`.
    var callback: @Sendable (SolverEvent) -> Void {
        let continuation = self.continuation
        return { event in continuation.yield(event) }
    }

    /// Ends the recording and returns everything recorded, in order.
    func finish() async -> [SolverEvent] {
        continuation.finish()
        var all: [SolverEvent] = []
        for await event in stream { all.append(event) }
        return all
    }
}

/// The pigeonhole principle as a 0–1 program: `holes + 1` pigeons, `holes` holes, every pigeon
/// in at least one hole (a clause row) and every hole holding at most one pigeon (a linear
/// row). Infeasible, and exponentially hard for clause learning — the instance the liveness
/// tests cancel and time out.
func pigeonhole(holes: Int) -> CompiledLP {
    let pigeons = holes + 1
    let n = pigeons * holes
    var entries: [(row: Int, col: Int, value: Double)] = []
    var rl: [Double] = []
    var ru: [Double] = []
    var row = 0
    for p in 0..<pigeons {
        for h in 0..<holes { entries.append((row, p * holes + h, 1)) }
        rl.append(1)
        ru.append(.infinity)
        row += 1
    }
    for h in 0..<holes {
        for p in 0..<pigeons { entries.append((row, p * holes + h, 1)) }
        rl.append(-.infinity)
        ru.append(1)
        row += 1
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: row, cols: n, entries), c: [Double](repeating: 0, count: n),
        xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rl: rl, ru: ru,
        integerColumns: (0..<n).map { Int32($0) })
}

/// A multi-row knapsack that yields incumbents at once and takes a long time to close: the
/// instance for "a limit returns the best incumbent".
func slowKnapsack(seed: UInt64 = 7) -> CompiledLP {
    InstanceGenerator.randomMILP(rows: 30, columns: 160, seed: seed)
}

/// The events of a solve with the wall-clock time removed, so two runs can be compared.
func normalized(_ events: [SolverEvent]) -> [SolverEvent] {
    events.map { event in
        if case .finished(let status, _) = event { return .finished(status: status, seconds: 0) }
        return event
    }
}

/// Checks the event contract of rule L10: `.started` first, `.finished` last and exactly once.
func eventContractHolds(_ events: [SolverEvent]) -> Bool {
    guard let first = events.first, let last = events.last else { return false }
    guard case .started = first, case .finished = last else { return false }
    return events.filter(\.isFinished).count == 1
}
