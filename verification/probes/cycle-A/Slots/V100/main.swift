// Cycle A, slot V100: independent reproduction of finding A4-04 (REPRODUCE lens).
// Claim under test: when branch and bound prunes nodes by the gap (objectiveStep == 0) and the
// search then completes, the reported bound is set to the incumbent and gap to 0, although a
// better feasible solution exists.
//
// Independent of the finder's probe: own model builder (the public DSL), own instance families,
// own brute-force enumeration, plus a hand-derived instance and a second engine (CP-SAT) and a
// zero-gap branch and bound as cross-checks.
//
// Modes:  hand            hand-derived 6-item knapsack, repeated runs
//         family N rel    random near-tie knapsacks (maximize), N seeds, the given relative gap
//         minfam N rel    random near-tie covering problems (minimize)
import Foundation
import ZTronLPOptimizer

enum Item: LPVariable {
    case take(Int)
    var domain: VariableDomain { .binary }
}

struct Knap {
    var name: String
    var p: [Double]        // objective coefficients
    var rows: [[Double]]   // integral weights
    var rhs: [Double]      // <= rhs (maximize) or >= rhs (minimize)
    var maximize: Bool
}

func buildModel(_ k: Knap) -> LPModel<Item> {
    let n = k.p.count
    let obj = sum(over: 0..<n) { j in k.p[j] * Item.take(j) }
    var m = LPModel<Item>()
    m = k.maximize ? m.maximizing(obj) : m.minimizing(obj)
    for (i, row) in k.rows.enumerated() {
        let lhs = sum(over: 0..<n) { j in row[j] * Item.take(j) }
        m.add(k.maximize ? (lhs <= k.rhs[i]) : (lhs >= k.rhs[i]))
    }
    return m
}

/// Own oracle: every 0/1 assignment. Weights are integers, so feasibility is exact.
func enumerate(_ k: Knap) -> (value: Double, mask: Int)? {
    let n = k.p.count
    var best = k.maximize ? -Double.infinity : Double.infinity
    var bestMask = -1
    for mask in 0..<(1 << n) {
        var ok = true
        for (i, row) in k.rows.enumerated() {
            var s = 0.0
            for j in 0..<n where mask & (1 << j) != 0 { s += row[j] }
            if k.maximize ? (s > k.rhs[i] + 1e-9) : (s < k.rhs[i] - 1e-9) { ok = false; break }
        }
        if !ok { continue }
        var v = 0.0
        for j in 0..<n where mask & (1 << j) != 0 { v += k.p[j] }
        if k.maximize ? (v > best) : (v < best) { best = v; bestMask = mask }
    }
    return bestMask >= 0 ? (best, bestMask) : nil
}

/// Checks a 0/1 point directly against the data: feasible? objective?
func evaluate(_ k: Knap, _ x: [Double]) -> (feasible: Bool, value: Double) {
    var ok = true
    for (i, row) in k.rows.enumerated() {
        var s = 0.0
        for j in 0..<x.count { s += row[j] * x[j] }
        if k.maximize ? (s > k.rhs[i] + 1e-6) : (s < k.rhs[i] - 1e-6) { ok = false }
    }
    for v in x where abs(v - v.rounded()) > 1e-6 || v < -1e-6 || v > 1 + 1e-6 { ok = false }
    var val = 0.0
    for j in 0..<x.count { val += k.p[j] * x[j] }
    return (ok, val)
}

func context(threads: Int?) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 30
    c.threads = threads
    c.metal = .off
    return c
}

func f(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.9f", v)
}
func e(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.3e", v)
}

struct Outcome {
    var status: SolveStatus
    var objective: Double?
    var bound: Double?
    var gap: Double?
    var nodes: Int
    var x: [Double]?
}

func runBB(_ s: BranchAndBound<Simplex>, _ k: Knap, threads: Int?) async throws -> Outcome {
    let sol = try await s.solve(buildModel(k), context: context(threads: threads))
    let a = sol.analysis
    let x: [Double]? = a.primal == nil ? nil : (0..<k.p.count).map { sol.value(of: .take($0)) }
    return Outcome(status: a.status, objective: a.objectiveValue, bound: a.bound, gap: a.gap, nodes: a.nodesProcessed, x: x)
}

/// A bound is valid when no feasible solution is better than it.
func boundValid(_ k: Knap, bound: Double?, opt: Double) -> Bool {
    guard let b = bound else { return true }
    let tol = 1e-9 * max(1, abs(opt))
    return k.maximize ? (b >= opt - tol) : (b <= opt + tol)
}

func trueRelGap(_ k: Knap, obj: Double, opt: Double) -> Double {
    abs(obj - opt) / max(1, abs(obj))
}

// MARK: - Hand-derived instance

/// Six items, capacity 82, strictly decreasing profit/weight ratios 1.10 > 1.09 > 1.08 > 1.06 >
/// 1.04 > 1.00, all profits multiplied by `scale`.
///   LP relaxation (Dantzig): A, B, then C at 2/8 -> (55 + 32.7 + 2.16)·scale = 89.86·scale.
///   Rounding at the root (C to 0): A + B -> 87.70·scale.
///   Optimum (by hand, confirmed by enumeration): A + B + F, weight 82 -> 89.70·scale.
func handInstance(scale: Double) -> Knap {
    let w: [Double] = [50, 30, 8, 7, 5, 2]
    let p: [Double] = [55.0, 32.7, 8.64, 7.42, 5.2, 2.0].map { $0 * scale }
    return Knap(name: "hand(scale \(scale))", p: p, rows: [w], rhs: [82], maximize: true)
}

func handMode() async throws {
    let phi = Double.pi / 3   // no power of 10 up to 1e6 makes these profits integral: objectiveStep 0
    for scale in [phi, 1.0] {
        let k = handInstance(scale: scale)
        let en = enumerate(k)!
        let optPoint = (0..<6).map { (en.mask >> $0) & 1 == 1 ? 1.0 : 0.0 }
        let chk = evaluate(k, optPoint)
        print("== \(k.name): enumeration optimum \(f(en.value)) at x=\(optPoint.map { Int($0) }) (direct check: feasible \(chk.feasible), value \(f(chk.value)))")
        print("   hand: LP bound \(f(89.86 * scale)), rounding point A+B \(f(87.7 * scale)), optimum A+B+F \(f(89.7 * scale))")

        // Second engine: CP-SAT on the unscaled instance (integral after x100); the argmax is
        // invariant under a positive scale.
        if scale == 1.0 {
            let sat = try await CPSAT(deterministic: true).solve(buildModel(k), context: context(threads: 1))
            print("   CPSAT(deterministic) unscaled: \(sat.status) obj \(f(sat.objectiveValue)) bound \(f(sat.analysis.bound))")
        }
        // Zero-gap branch and bound: third oracle.
        let exact = try await runBB(BranchAndBound(gap: Gap(relative: 0, absolute: 0)), k, threads: 1)
        print("   BB exact gap 0: \(exact.status) obj \(f(exact.objective)) bound \(f(exact.bound)) gap \(e(exact.gap)) nodes \(exact.nodes)")

        let loose = Gap(relative: 0.05, absolute: 1e-6)
        let configs: [(String, BranchAndBound<Simplex>, Int?)] = [
            ("P rel0.05 t8", BranchAndBound(gap: loose), 8),
            ("P rel0.05 t1", BranchAndBound(gap: loose), 1),
            ("P rel0.05 default-ctx-threads", BranchAndBound(gap: loose), nil),
            ("D-det rel0.05", BranchAndBound(engine: Simplex(.dual), gap: loose, deterministic: true), 1),
            ("P rel0.05 bestBound mostFrac", BranchAndBound(branching: .mostFractional, nodeSelection: .bestBound, gap: loose), 8),
            ("P rel0.05 no-diving", BranchAndBound(heuristics: Heuristics(rounding: true, diving: false), gap: loose), 8),
            ("P rel0.05 nodeLimit1", BranchAndBound(gap: loose, nodeLimit: 1), 8),
            ("P rel0.03", BranchAndBound(gap: Gap(relative: 0.03, absolute: 1e-6)), 8),
            ("P rel0.02", BranchAndBound(gap: Gap(relative: 0.02, absolute: 1e-6)), 8),
            ("P default gap", BranchAndBound(), 8),
        ]
        for (name, s, t) in configs {
            var lines = Set<String>()
            var last: Outcome? = nil
            for _ in 0..<5 {
                let r = try await runBB(s, k, threads: t)
                last = r
                lines.insert("\(r.status) obj \(f(r.objective)) bound \(f(r.bound)) gap \(e(r.gap)) nodes \(r.nodes)")
            }
            let r = last!
            let pointCheck = r.x.map { evaluate(k, $0) }
            let valid = boundValid(k, bound: r.bound, opt: en.value)
            let tg = r.objective.map { trueRelGap(k, obj: $0, opt: en.value) }
            print("   [\(name)] x5 distinct=\(lines.count): \(lines.sorted().joined(separator: " | "))")
            print("        point feasible \(pointCheck?.feasible ?? false) value \(f(pointCheck?.value)); boundValid \(valid); trueRelGap \(e(tg)) vs reported gap \(e(r.gap))\(valid ? "" : "  <-- BOUND BELOW A FEASIBLE SOLUTION")")
        }
    }
}

// MARK: - Random families (own generator)

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
}

/// Two-row knapsack, 15 binaries, profit = e·w1 + small additive noise (non-terminating), so
/// many fillings of row 1 lie within 1e-4 of one another.
func nearTieMax(seed: UInt64) -> Knap {
    var g = SplitMix64(state: 0xA4_04_0000 &+ seed &* 7919)
    let n = 15
    let w1 = (0..<n).map { _ in Double(g.int(15, 95)) }
    let w2 = (0..<n).map { _ in Double(g.int(1, 30)) }
    let p = (0..<n).map { j in M_E * w1[j] + 0.004 * g.unit() }
    let cap1 = (0.45 * w1.reduce(0, +)).rounded(.down) + 0.37
    let cap2 = (0.55 * w2.reduce(0, +)).rounded(.down)
    return Knap(name: "max seed \(seed)", p: p, rows: [w1, w2], rhs: [cap1, cap2], maximize: true)
}

/// Covering: minimise cost = sqrt(2)·w + noise subject to w·x >= demand.
func nearTieMin(seed: UInt64) -> Knap {
    var g = SplitMix64(state: 0x0B_0004_0000 &+ seed &* 104_729)
    let n = 15
    let w = (0..<n).map { _ in Double(g.int(15, 95)) }
    let c = (0..<n).map { j in 2.0.squareRoot() * w[j] + 0.004 * g.unit() }
    let demand = (0.55 * w.reduce(0, +)).rounded(.down) + 0.41
    return Knap(name: "min seed \(seed)", p: c, rows: [w], rhs: [demand], maximize: false)
}

func familyMode(count: Int, rel: Double, minimize: Bool) async throws {
    let gap = Gap(relative: rel, absolute: 1e-6)
    let configs: [(String, BranchAndBound<Simplex>, Int?)] = [
        ("P-t8", BranchAndBound(gap: gap), 8),
        ("P-det", BranchAndBound(gap: gap, deterministic: true), 1),
        ("D-det", BranchAndBound(engine: Simplex(.dual), gap: gap, deterministic: true), 1),
    ]
    var invalid = [Int](repeating: 0, count: configs.count)
    var completedSubopt = [Int](repeating: 0, count: configs.count)
    var outsideGap = [Int](repeating: 0, count: configs.count)
    var gapUnder = [Int](repeating: 0, count: configs.count)
    var runs = [Int](repeating: 0, count: configs.count)
    var exactWrong = 0
    var worst = [Double](repeating: 0, count: configs.count)
    for seed in 0..<UInt64(count) {
        let k = minimize ? nearTieMin(seed: seed) : nearTieMax(seed: seed)
        guard let en = enumerate(k) else { print("\(k.name): infeasible"); continue }
        // Second oracle: zero-gap search, deterministic.
        let exact = try await runBB(BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0), deterministic: true), k, threads: 1)
        if let o = exact.objective, abs(o - en.value) > 1e-9 * max(1, abs(en.value)) {
            exactWrong += 1
            print("\(k.name): ZERO-GAP BB disagrees with enumeration: \(f(o)) vs \(f(en.value))")
        }
        for (ci, (name, s, t)) in configs.enumerated() {
            let r = try await runBB(s, k, threads: t)
            runs[ci] += 1
            guard let obj = r.objective, r.status == .optimal else {
                print("\(k.name) [\(name)]: \(r.status)")
                continue
            }
            let pc = evaluate(k, r.x!)
            precondition(pc.feasible, "infeasible incumbent")
            let tg = trueRelGap(k, obj: obj, opt: en.value)
            if tg > rel + 1e-9 { outsideGap[ci] += 1 }
            let valid = boundValid(k, bound: r.bound, opt: en.value)
            if tg > 1e-12 { completedSubopt[ci] += 1 }
            if let g = r.gap, g + 1e-12 < tg { gapUnder[ci] += 1 }
            if !valid {
                invalid[ci] += 1
                let excess = abs((r.bound ?? 0) - en.value) / max(1, abs(en.value))
                worst[ci] = max(worst[ci], excess)
                if invalid[ci] <= 4 {
                    print("\(k.name) [\(name)]: optimal obj \(f(obj)) bound \(f(r.bound)) gap \(e(r.gap)) nodes \(r.nodes) | enumerated opt \(f(en.value)) trueRelGap \(e(tg)) zero-gap BB \(f(exact.objective)) -> INVALID BOUND")
                }
            }
        }
    }
    for (ci, (name, _, _)) in configs.enumerated() {
        print("SUMMARY \(minimize ? "min" : "max") rel=\(rel) [\(name)] runs=\(runs[ci]) suboptimalWithinGap=\(completedSubopt[ci]) outsideGap=\(outsideGap[ci]) invalidBound=\(invalid[ci]) reportedGapBelowTrueGap=\(gapUnder[ci]) worstBoundExcess(rel)=\(e(worst[ci]))")
    }
    print("SUMMARY zero-gap BB disagreements with enumeration: \(exactWrong) of \(count)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "hand" {
case "hand": try await handMode()
case "family":
    try await familyMode(count: args.count > 2 ? Int(args[2])! : 20, rel: args.count > 3 ? Double(args[3])! : 1e-4, minimize: false)
case "minfam":
    try await familyMode(count: args.count > 2 ? Int(args[2])! : 20, rel: args.count > 3 ? Double(args[3])! : 1e-4, minimize: true)
default: print("modes: hand | family N rel | minfam N rel")
}
