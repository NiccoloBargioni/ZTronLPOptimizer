// Cycle B, slot F5: independent oracles for CP-SAT.
// Nothing here uses the package's own checkers: DIMACS parsing, clause checking, DPLL and
// exhaustive enumeration are written from scratch, in exact integer arithmetic.

import Foundation
import ZTronLPOptimizer

// MARK: - RNG (splitmix64, own implementation)

struct RNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed ^ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        precondition(lo <= hi)
        let span = UInt64(hi - lo + 1)
        return lo + Int(next() % span)
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / 9007199254740992.0 < p }
}

// MARK: - CNF

struct CNF {
    var vars: Int
    var clauses: [[Int]]
}

func parseDIMACS(_ text: String) -> CNF {
    var vars = 0
    var clauses: [[Int]] = []
    var current: [Int] = []
    outer: for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("c") { continue }
        if line.hasPrefix("%") { break outer }
        if line.hasPrefix("p") {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            vars = Int(parts[2])!
            continue
        }
        for tok in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let v = Int(tok) else { continue }
            if v == 0 {
                clauses.append(current)
                current = []
            } else {
                current.append(v)
            }
        }
    }
    if !current.isEmpty { clauses.append(current) }
    return CNF(vars: vars, clauses: clauses)
}

/// Clause check against the raw clauses: x[v-1] > 0.5 means v is true.
func cnfSatisfied(_ f: CNF, _ x: [Double]) -> Int? {
    for (k, c) in f.clauses.enumerated() {
        var ok = false
        for lit in c {
            let v = x[abs(lit) - 1]
            if v != 0 && v != 1 { return k }   // not a 0/1 value at all
            if (lit > 0 && v == 1) || (lit < 0 && v == 0) { ok = true; break }
        }
        if !ok { return k }
    }
    return nil
}

/// The CNF as a 0-1 program built independently: sum(pos) - sum(neg) >= 1 - |neg|.
func cnfToLP(_ f: CNF, objective: [Double]? = nil, maximize: Bool = false) -> CompiledLP {
    var entries: [(row: Int, col: Int, value: Double)] = []
    var rl: [Double] = []
    var ru: [Double] = []
    var row = 0
    for c in f.clauses {
        var sign: [Int: Int] = [:]
        var taut = false
        for lit in c {
            let v = abs(lit) - 1
            let s = lit > 0 ? 1 : -1
            if let e = sign[v], e != s { taut = true }
            sign[v] = s
        }
        if taut { continue }
        var neg = 0
        for (v, s) in sign.sorted(by: { $0.key < $1.key }) {
            entries.append((row, v, Double(s)))
            if s < 0 { neg += 1 }
        }
        rl.append(Double(1 - neg))
        ru.append(.infinity)
        row += 1
    }
    let n = f.vars
    var c = objective ?? [Double](repeating: 0, count: n)
    if maximize { c = c.map { $0 == 0 ? 0 : -$0 } }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: row, cols: n, entries), c: c, sense: maximize ? .maximize : .minimize,
        xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n), rl: rl, ru: ru,
        integerColumns: (0..<n).map { Int32($0) })
}

/// A small DPLL with unit propagation, written independently. Returns a model or nil (UNSAT).
func dpll(_ f: CNF, nodeLimit: Int = 50_000_000) -> (sat: Bool?, model: [Bool]?, nodes: Int) {
    let n = f.vars
    var assign = [Int8](repeating: 0, count: n + 1)
    var nodes = 0
    // occurrence lists
    var occ = [[Int]](repeating: [], count: n + 1)
    for (k, c) in f.clauses.enumerated() { for l in c { occ[abs(l)].append(k) } }
    func value(_ lit: Int) -> Int8 { let a = assign[abs(lit)]; return lit > 0 ? a : -a }
    // returns false on conflict; trail collects assigned vars
    func propagate(_ trail: inout [Int]) -> Bool {
        var changed = true
        while changed {
            changed = false
            for c in f.clauses {
                var unassigned = 0
                var lastLit = 0
                var sat = false
                for l in c {
                    let v = value(l)
                    if v == 1 { sat = true; break }
                    if v == 0 { unassigned += 1; lastLit = l }
                }
                if sat { continue }
                if unassigned == 0 { return false }
                if unassigned == 1 {
                    assign[abs(lastLit)] = lastLit > 0 ? 1 : -1
                    trail.append(abs(lastLit))
                    changed = true
                }
            }
        }
        return true
    }
    func pick() -> Int {
        // variable occurring most often in unsatisfied clauses of minimal size
        var best = 0
        var bestScore = -1
        var score = [Int](repeating: 0, count: n + 1)
        var minLen = Int.max
        for c in f.clauses {
            var sat = false
            var len = 0
            for l in c { let v = value(l); if v == 1 { sat = true; break }; if v == 0 { len += 1 } }
            if !sat && len > 0 && len < minLen { minLen = len }
        }
        for c in f.clauses {
            var sat = false
            var len = 0
            for l in c { let v = value(l); if v == 1 { sat = true; break }; if v == 0 { len += 1 } }
            if sat || len != minLen { continue }
            for l in c where value(l) == 0 { score[abs(l)] += 1 }
        }
        for v in 1...max(1, n) where n > 0 && assign[v] == 0 && score[v] > bestScore { bestScore = score[v]; best = v }
        if best == 0 { for v in 1...max(1, n) where n > 0 && assign[v] == 0 { return v } }
        return best
    }
    var aborted = false
    func solve() -> Bool {
        nodes += 1
        if nodes > nodeLimit { aborted = true; return false }
        var trail: [Int] = []
        if !propagate(&trail) {
            for v in trail { assign[v] = 0 }
            return false
        }
        let v = pick()
        if v == 0 { return true }   // all assigned (or no clause left unsatisfied with free vars)
        for s in [Int8(1), Int8(-1)] {
            assign[v] = s
            if solve() { return true }
            assign[v] = 0
            if aborted { break }
        }
        for t in trail { assign[t] = 0 }
        return false
    }
    // empty clause check
    if f.clauses.contains(where: { $0.isEmpty }) { return (false, nil, 0) }
    let ok = solve()
    if aborted { return (nil, nil, nodes) }
    if !ok { return (false, nil, nodes) }
    // unassigned vars -> false
    let model = (1...max(1, n)).map { assign[$0] == 1 }
    return (true, n == 0 ? [] : model, nodes)
}

func random3SAT(vars n: Int, clauses m: Int, rng: inout RNG) -> CNF {
    var cl: [[Int]] = []
    for _ in 0..<m {
        var vs: Set<Int> = []
        while vs.count < 3 { vs.insert(rng.int(1, n)) }
        cl.append(vs.sorted().map { rng.chance(0.5) ? $0 : -$0 })
    }
    return CNF(vars: n, clauses: cl)
}

// MARK: - Exact small integer programs

/// Row i: sum a[i][j] * x_j / 10^e[i], bounds lo2/hi2 in half units: L2/(2*10^e) <= activity <= U2/(2*10^e).
struct IntRow {
    var terms: [(col: Int, a: Int)]
    var e: Int
    var lo2: Int?
    var hi2: Int?
}

struct IntProgram {
    var n: Int
    var lb: [Int]
    var ub: [Int]
    var rows: [IntRow]
    var cost: [Int]      // cost_j = cost[j] / 10^ec
    var ec: Int
    var c0: Int          // constant = c0 / 10^ec
    var maximize: Bool

    func pow10(_ e: Int) -> Int { var p = 1; for _ in 0..<e { p *= 10 }; return p }

    func lp(permRows: [Int]? = nil, permCols: [Int]? = nil) -> CompiledLP {
        // permCols[newIndex] = oldIndex
        let pc = permCols ?? Array(0..<n)
        var inv = [Int](repeating: 0, count: n)
        for (newJ, oldJ) in pc.enumerated() { inv[oldJ] = newJ }
        let pr = permRows ?? Array(0..<rows.count)
        var entries: [(row: Int, col: Int, value: Double)] = []
        var rl: [Double] = []
        var ru: [Double] = []
        for (newI, oldI) in pr.enumerated() {
            let r = rows[oldI]
            let d = Double(pow10(r.e))
            for t in r.terms where t.a != 0 { entries.append((newI, inv[t.col], Double(t.a) / d)) }
            rl.append(r.lo2.map { Double($0) / (2 * d) } ?? -.infinity)
            ru.append(r.hi2.map { Double($0) / (2 * d) } ?? .infinity)
        }
        let dc = Double(pow10(ec))
        var c = [Double](repeating: 0, count: n)
        for oldJ in 0..<n { c[inv[oldJ]] = Double(cost[oldJ]) / dc }
        var c0d = Double(c0) / dc
        if maximize { c = c.map { $0 == 0 ? 0 : -$0 }; c0d = c0d == 0 ? 0 : -c0d }
        var xl = [Double](repeating: 0, count: n)
        var xu = [Double](repeating: 0, count: n)
        for oldJ in 0..<n { xl[inv[oldJ]] = Double(lb[oldJ]); xu[inv[oldJ]] = Double(ub[oldJ]) }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: pr.count, cols: n, entries), c: c, c0: c0d,
            sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru,
            integerColumns: (0..<n).map { Int32($0) })
    }

    func feasible(_ x: [Int]) -> Bool {
        for j in 0..<n where x[j] < lb[j] || x[j] > ub[j] { return false }
        for r in rows {
            var act = 0
            for t in r.terms { act += t.a * x[t.col] }
            if let l = r.lo2, 2 * act < l { return false }
            if let h = r.hi2, 2 * act > h { return false }
        }
        return true
    }

    func objInt(_ x: [Int]) -> Int { var s = 0; for j in 0..<n { s += cost[j] * x[j] }; return s }

    /// Exhaustive enumeration. best = optimal sum cost_j x_j (integer units), in the model's sense.
    func bruteForce() -> (best: Int?, count: Int, optima: Int) {
        if zip(lb, ub).contains(where: { $0 > $1 }) { return (nil, 0, 0) }
        var x = lb
        var best: Int? = nil
        var count = 0
        var optima = 0
        while true {
            if feasible(x) {
                count += 1
                let v = objInt(x)
                if let b = best {
                    if (maximize && v > b) || (!maximize && v < b) { best = v; optima = 1 } else if v == b { optima += 1 }
                } else { best = v; optima = 1 }
            }
            var k = 0
            while k < n {
                if x[k] < ub[k] { x[k] += 1; break }
                x[k] = lb[k]
                k += 1
            }
            if k == n || n == 0 { break }
        }
        return (best, count, optima)
    }

    func reported(_ objInt: Int) -> Double { Double(objInt + c0) / Double(pow10(ec)) }

    func describe() -> String {
        var s = "n=\(n) \(maximize ? "max" : "min") cost=\(cost)/1e\(ec) c0=\(c0)\n"
        for j in 0..<n { s += "  x\(j) in [\(lb[j]),\(ub[j])]\n" }
        for (i, r) in rows.enumerated() {
            s += "  r\(i): " + r.terms.map { "\($0.a)*x\($0.col)" }.joined(separator: " + ")
            s += " /1e\(r.e) in [\(r.lo2.map { "\($0)/2" } ?? "-inf"), \(r.hi2.map { "\($0)/2" } ?? "inf")]\n"
        }
        return s
    }
}

struct GenOptions {
    var maxVars = 6
    var maxRows = 5
    var maxExp = 6          // row decimal exponent
    var costExpMax = 0      // objective decimal exponent upper bound
    var halfRHS = true
    var binaryOnly = false
    var allowEmptyRows = true
    var bigCoefs = false
}

func randomIP(_ rng: inout RNG, _ o: GenOptions) -> IntProgram {
    let n = rng.int(1, o.maxVars)
    var lb = [Int](repeating: 0, count: n)
    var ub = [Int](repeating: 1, count: n)
    for j in 0..<n where !o.binaryOnly && rng.chance(0.6) {
        lb[j] = rng.int(-4, 2)
        ub[j] = lb[j] + rng.int(0, 4)
    }
    // keep the enumeration small
    var space = 1
    for j in 0..<n { space *= (ub[j] - lb[j] + 1) }
    while space > 40_000 {
        let j = rng.int(0, n - 1)
        if ub[j] > lb[j] { ub[j] -= 1 }
        space = 1
        for j in 0..<n { space *= (ub[j] - lb[j] + 1) }
    }
    let ref = (0..<n).map { rng.int(lb[$0], ub[$0]) }
    let m = rng.int(0, o.maxRows)
    var rows: [IntRow] = []
    for _ in 0..<m {
        var terms: [(col: Int, a: Int)] = []
        for j in 0..<n where rng.chance(0.65) {
            var a = rng.int(-7, 7)
            if o.bigCoefs && rng.chance(0.3) { a *= rng.int(100, 100_000) }
            if a != 0 { terms.append((j, a)) }
        }
        if terms.isEmpty && !(o.allowEmptyRows && rng.chance(0.3)) {
            terms.append((rng.int(0, n - 1), rng.int(1, 3)))
        }
        let e = rng.chance(0.5) ? 0 : rng.int(0, o.maxExp)
        // multiply coefficients by a power of 10 sometimes so the scaled data has trailing zeros
        var act = 0
        for t in terms { act += t.a * ref[t.col] }
        let kind = rng.int(0, 5)
        let half = o.halfRHS && rng.chance(0.3) ? 1 : 0
        var lo2: Int? = nil
        var hi2: Int? = nil
        switch kind {
        case 0: hi2 = 2 * (act + rng.int(0, 3)) + half
        case 1: lo2 = 2 * (act - rng.int(0, 3)) - half
        case 2: lo2 = 2 * act; hi2 = 2 * act
        case 3: lo2 = 2 * (act - rng.int(0, 2)) - half; hi2 = 2 * (act + rng.int(0, 2)) + half
        case 4: hi2 = 2 * rng.int(-8, 8) + half   // unrelated: may be infeasible
        default: lo2 = 2 * rng.int(-6, 6) - half; hi2 = lo2! + 2 * rng.int(0, 3)
        }
        rows.append(IntRow(terms: terms, e: e, lo2: lo2, hi2: hi2))
    }
    var cost = (0..<n).map { _ in rng.int(-9, 9) }
    if rng.chance(0.1) { cost = [Int](repeating: 0, count: n) }
    let ec = o.costExpMax == 0 ? 0 : rng.int(0, o.costExpMax)
    let c0 = rng.chance(0.5) ? 0 : rng.int(-20, 20)
    return IntProgram(n: n, lb: lb, ub: ub, rows: rows, cost: cost, ec: ec, c0: c0, maximize: rng.chance(0.5))
}

// MARK: - Running CP-SAT

struct Outcome {
    var status: SolveStatus?
    var objective: Double?
    var bound: Double?
    var primal: [Double]?
    var error: String?
    var seconds: Double
    var winning: Int?
    var conflicts: Int = 0
}

func runCP(_ lp: CompiledLP, _ s: CPSAT, timeLimit: Double = 10, threads: Int? = nil) async -> Outcome {
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    ctx.threads = threads
    let t0 = Date()
    do {
        let r = try await s.solve(lp, context: ctx)
        return Outcome(status: r.status, objective: r.objectiveValue, bound: r.bound, primal: r.primal, error: nil,
                       seconds: Date().timeIntervalSince(t0), winning: r.winningWorker, conflicts: r.conflicts)
    } catch {
        return Outcome(status: nil, objective: nil, bound: nil, primal: nil, error: "\(error)",
                       seconds: Date().timeIntervalSince(t0), winning: nil)
    }
}

func statusName(_ s: SolveStatus?) -> String {
    guard let s else { return "THROW" }
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .unbounded: return "unbounded"
    case .infeasibleOrUnbounded: return "infOrUnb"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    case .numericalFailure(let m): return "numericalFailure(\(m))"
    }
}

let configs: [(String, CPSAT)] = [
    ("det-lp", CPSAT(deterministic: true)),
    ("det-nolp", CPSAT(lpPropagator: false, deterministic: true)),
    ("par4-lp", CPSAT(workers: 4)),
    ("par4-nolp", CPSAT(workers: 4, lpPropagator: false)),
    ("par8-seed", CPSAT(workers: 8, seed: 12345)),
    ("par3-geo-noshare", CPSAT(workers: 3, restarts: .geometric(first: 10, factor: 1.5), clauseSharing: false)),
    ("det-never", CPSAT(restarts: .never, lpPropagator: false, deterministic: true)),
]
