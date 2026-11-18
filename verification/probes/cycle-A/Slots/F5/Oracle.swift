// Independent oracles for the F5 (CP-SAT) probe of cycle A.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Independent DPLL (no code shared with the package)

struct DPLL {
    let n: Int
    let clauses: [[Int]]
    var assign: [Int8]   // 0 unassigned, 1 true, -1 false (index v-1)
    var nodes = 0

    init(variables: Int, clauses: [[Int]]) {
        n = variables
        self.clauses = clauses
        assign = [Int8](repeating: 0, count: variables)
    }

    func litValue(_ l: Int) -> Int8 {
        let v = assign[abs(l) - 1]
        return l > 0 ? v : -v
    }

    /// Unit propagation; returns false on conflict. Records assigned vars in trail.
    mutating func propagate(_ trail: inout [Int]) -> Bool {
        var changed = true
        while changed {
            changed = false
            for c in clauses {
                var unassigned = 0
                var lastUnassigned = 0
                var sat = false
                for l in c {
                    let v = litValue(l)
                    if v == 1 { sat = true; break }
                    if v == 0 { unassigned += 1; lastUnassigned = l }
                }
                if sat { continue }
                if unassigned == 0 { return false }
                if unassigned == 1 {
                    assign[abs(lastUnassigned) - 1] = lastUnassigned > 0 ? 1 : -1
                    trail.append(abs(lastUnassigned) - 1)
                    changed = true
                }
            }
        }
        return true
    }

    mutating func solve() -> Bool {
        nodes += 1
        var trail: [Int] = []
        if !propagate(&trail) {
            for v in trail { assign[v] = 0 }
            return false
        }
        // pick the first unassigned variable occurring in an unsatisfied clause
        var pick = -1
        outer: for c in clauses {
            var sat = false
            for l in c where litValue(l) == 1 { sat = true; break }
            if sat { continue }
            for l in c where litValue(l) == 0 { pick = abs(l) - 1; break outer }
        }
        if pick < 0 {
            // every clause satisfied
            return true
        }
        for value: Int8 in [1, -1] {
            assign[pick] = value
            if solve() { return true }
            assign[pick] = 0
        }
        for v in trail { assign[v] = 0 }
        return false
    }

    /// A full assignment (unassigned → false) after a successful solve.
    var model: [Bool] { assign.map { $0 == 1 } }
}

// MARK: - Exhaustive enumeration over a small pure-integer CompiledLP

struct EnumResult {
    var feasibleCount = 0
    var bestInternal: Double = .infinity
    var bestPoint: [Double]? = nil
}

func enumerate(_ lp: CompiledLP, tol: Double = 1e-9) -> EnumResult {
    let n = lp.n
    var lo = [Int](repeating: 0, count: n)
    var hi = [Int](repeating: 0, count: n)
    for j in 0..<n {
        lo[j] = Int((lp.xl[j] - 1e-9).rounded(.up))
        hi[j] = Int((lp.xu[j] + 1e-9).rounded(.down))
        if lo[j] > hi[j] { return EnumResult() }
    }
    var x = lo
    var res = EnumResult()
    // row-wise representation
    var rows = [[(Int, Double)]](repeating: [], count: lp.m)
    for j in 0..<n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
            rows[Int(lp.a.rowIndex[p])].append((j, lp.a.values[p]))
        }
    }
    while true {
        var ok = true
        for i in 0..<lp.m {
            var act = 0.0
            for (j, a) in rows[i] { act += a * Double(x[j]) }
            let t = tol * max(1, abs(act))
            if act < lp.rl[i] - t || act > lp.ru[i] + t { ok = false; break }
        }
        if ok {
            res.feasibleCount += 1
            var obj = lp.c0
            for j in 0..<n { obj += lp.c[j] * Double(x[j]) }
            if obj < res.bestInternal - 1e-12 {
                res.bestInternal = obj
                res.bestPoint = x.map { Double($0) }
            }
        }
        // next point
        var k = 0
        while k < n {
            if x[k] < hi[k] { x[k] += 1; break }
            x[k] = lo[k]
            k += 1
        }
        if k == n { break }
        if n == 0 { break }
    }
    return res
}

// MARK: - Helpers

func makeLP(
    n: Int, rows: [[(Int, Double)]], rl: [Double], ru: [Double], c: [Double], c0: Double = 0,
    sense: ObjectiveSense = .minimize, xl: [Double], xu: [Double], integer: [Int32]? = nil
) -> CompiledLP {
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, r) in rows.enumerated() {
        for (j, a) in r where a != 0 { entries.append((i, j, a)) }
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c, c0: c0, sense: sense,
        xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer ?? (0..<n).map { Int32($0) })
}

func statusString(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infeasibleOrUnbounded"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let m): return "numericalFailure(\(m))"
    }
}

/// Exact (within 1e-9 relative) feasibility of a point.
func pointViolation(_ lp: CompiledLP, _ x: [Double]) -> Double {
    var worst = 0.0
    for j in 0..<lp.n {
        if abs(x[j] - x[j].rounded()) > 0 { worst = max(worst, abs(x[j] - x[j].rounded())) }
        worst = max(worst, lp.xl[j] - x[j], x[j] - lp.xu[j])
    }
    let act = lp.rowActivity(x)
    for i in 0..<lp.m {
        worst = max(worst, lp.rl[i] - act[i], act[i] - lp.ru[i])
    }
    return worst
}

struct Config {
    let name: String
    let strategy: CPSAT
}

func config(_ name: String) -> Config {
    switch name {
    case "default": return Config(name: name, strategy: CPSAT())
    case "det": return Config(name: name, strategy: CPSAT(deterministic: true))
    case "nolp": return Config(name: name, strategy: CPSAT(lpPropagator: false))
    case "detnolp": return Config(name: name, strategy: CPSAT(lpPropagator: false, deterministic: true))
    case "w8": return Config(name: name, strategy: CPSAT(workers: 8))
    case "w8nolp": return Config(name: name, strategy: CPSAT(workers: 8, lpPropagator: false))
    case "w2": return Config(name: name, strategy: CPSAT(workers: 2))
    case "noshare": return Config(name: name, strategy: CPSAT(workers: 4, clauseSharing: false))
    case "never": return Config(name: name, strategy: CPSAT(restarts: .never))
    case "geo": return Config(name: name, strategy: CPSAT(restarts: .geometric(first: 10, factor: 1.5)))
    default: fatalError("unknown config \(name)")
    }
}

func ctx(_ limit: Double?) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = limit
    return c
}
