// V133: sceptic for finding A5-05 (cycle A, F5 CP-SAT).
// Claim under test: CPSATAnalysis doc "bound ... equals objectiveValue once optimality is
// proven" and SolutionAnalysis.bound doc "Proven bound; equals objectiveValue when optimal".
// Independent construction (DSL, not raw CompiledLP) and independent oracles (own
// enumeration in exact integer units; own brute force over all subsets of a knapsack).
import Foundation
import ZTronLPOptimizer

enum I: LPVariable {
    case x(Int)
    var domain: VariableDomain { .integer }
}
enum B: LPVariable {
    case b(Int)
    var domain: VariableDomain { .binary }
}

func ctx(_ limit: Double, threads: Int? = nil) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = limit
    if let t = threads { c.threads = t }
    return c
}
func f(_ d: Double?) -> String { d.map { String(format: "%.17g", $0) } ?? "nil" }
/// README risk 10 / CPSAT doc: optimal iff incumbent - bound <= max(1e-6, 1e-4 * max(1, |incumbent|)).
func allowedGap(_ inc: Double) -> Double { max(1e-6, 1e-4 * max(1, abs(inc))) }

let args = CommandLine.arguments.dropFirst()
let which = Set(args)
func on(_ k: String) -> Bool { which.isEmpty || which.contains(k) }

let strategies: [(String, CPSAT)] = [
    ("det", CPSAT(deterministic: true)),
    ("detnolp", CPSAT(lpPropagator: false, deterministic: true)),
    ("par4", CPSAT(workers: 4)),
]

func report<A: SolutionAnalysis>(_ label: String, _ a: A, trueOpt: Double, sense: ObjectiveSense) {
    let obj = a.objectiveValue
    let bnd = a.bound
    var notes: [String] = []
    if a.status == .optimal, let o = obj, let b = bnd {
        notes.append(o == b ? "bound==obj" : "BOUND!=OBJ diff=\(f(abs(b - o)))")
        // a proven bound must not cut off the true optimum
        let valid = sense == .maximize ? b >= trueOpt - 1e-9 * max(1, abs(trueOpt)) : b <= trueOpt + 1e-9 * max(1, abs(trueOpt))
        notes.append(valid ? "bound valid" : "BOUND CUTS OFF OPTIMUM")
        notes.append(abs(b - o) <= allowedGap(o) ? "within gap(\(f(allowedGap(o))))" : "OUTSIDE GAP")
        notes.append(o == trueOpt ? "obj==trueOpt" : "obj!=trueOpt (short by \(f(abs(trueOpt - o))))")
    }
    print("\(label): status=\(a.status) obj=\(f(obj)) bound=\(f(bnd)) trueOpt=\(f(trueOpt)) | \(notes.joined(separator: ", "))")
}

// Case 1: the finder's D13 model, built with the DSL. max 1e-6 x + 3.5, x integer in [0,7].
// Oracle: enumerate x in exact micro-units: value = (3_500_000 + x) / 1e6.
if on("c1") {
    var bestMicro = Int.min
    for x in 0...7 { bestMicro = max(bestMicro, 3_500_000 + x) }
    let trueOpt = Double(bestMicro) / 1e6
    print("C1 oracle: best micro-units \(bestMicro) -> \(f(trueOpt))")
    let m1 = LPModel<I>()
        .maximizing(0.000001 * I.x(0) + 3.5)
        .bounding(I.x(0), .range(0...7))
    // Variant with a genuine two-column row so the model is not bounds-only.
    let m1b = LPModel<I>()
        .maximizing(0.000001 * I.x(0) + 3.5)
        .subjectTo(I.x(0) + I.x(1) <= 7)
        .bounding(I.x(1), .range(0...7))
        .bounding(I.x(0), .range(0...7))
    for (name, s) in strategies {
        for (tag, m) in [("bounds-only", m1), ("with-row", m1b)] {
            do {
                let sol = try await s.solve(m, context: ctx(5))
                report("C1 \(tag) [\(name)] x0=\(sol.value(of: .x(0)))", sol.analysis, trueOpt: trueOpt, sense: .maximize)
            } catch { print("C1 \(tag) [\(name)]: THROW \(error)") }
        }
    }
}

// Case 2: integral costs, |objective| >= 1e4 (README risk 10 says the proof is exact only below 1e4).
// max x0 s.t. x0 + x1 <= 1e9, x0 in [0,1e9], x1 in [0,10]. Oracle: 1e9 (x1 = 0).
if on("c2") {
    let trueOpt = 1e9
    let m2 = LPModel<I>()
        .maximizing(1.0 * I.x(0))
        .subjectTo(I.x(0) + I.x(1) <= 1e9)
        .bounding(I.x(0), .range(0...1e9))
        .bounding(I.x(1), .range(0...10))
    for (name, s) in strategies {
        for rep in 0..<2 {
            do {
                let sol = try await s.solve(m2, context: ctx(5))
                report("C2 rep\(rep) [\(name)]", sol.analysis, trueOpt: trueOpt, sense: .maximize)
            } catch { print("C2 [\(name)]: THROW \(error)") }
        }
    }
}

// Case 3: 0/1 knapsacks with large integral values; oracle = own brute force over all 2^n subsets.
struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }
func knapsack(seed: UInt64, n: Int) -> (v: [Double], w: [Double], cap: Double) {
    var g = LCG(s: seed &* 7919 &+ 17)
    var v: [Double] = [], w: [Double] = []
    for _ in 0..<n {
        let wi = 20 + Double(g.next() % 80)
        w.append(wi)
        v.append((wi * 10_000 + Double(g.next() % 50_000)).rounded())  // correlated, values ~2e5..1e6
    }
    let cap = (w.reduce(0, +) / 2).rounded()
    return (v, w, cap)
}
func bruteForce(_ v: [Double], _ w: [Double], _ cap: Double) -> Double {
    let n = v.count
    var best = 0.0
    for mask in 0..<(1 << n) {
        var wt = 0.0, val = 0.0
        var m = mask, j = 0
        while m != 0 { if m & 1 == 1 { wt += w[j]; val += v[j] }; m >>= 1; j += 1 }
        if wt <= cap && val > best { best = val }
    }
    return best
}
if on("c3") {
    let n = Int(ProcessInfo.processInfo.environment["V133_N"] ?? "18")!
    let seeds = Int(ProcessInfo.processInfo.environment["V133_SEEDS"] ?? "6")!
    var counts: [String: (optimal: Int, differ: Int, invalid: Int, outside: Int)] = [:]
    for seed in 0..<UInt64(seeds) {
        let (v, w, cap) = knapsack(seed: seed, n: n)
        let trueOpt = bruteForce(v, w, cap)
        let model = LPModel<B>()
            .maximizing(sum(over: 0..<n) { v[$0] * B.b($0) })
            .subjectTo(sum(over: 0..<n) { w[$0] * B.b($0) } <= cap)
        var runs: [(String, any SolutionAnalysis)] = []
        for (name, s) in strategies {
            do { runs.append((name, try await s.solve(model, context: ctx(10)).analysis)) } catch { print("C3 seed \(seed) [\(name)]: THROW \(error)") }
        }
        if on("bnb") || which.isEmpty {
            do { runs.append(("bnb", try await BranchAndBound(deterministic: true).solve(model, context: ctx(10)).analysis)) } catch { print("C3 seed \(seed) [bnb]: THROW \(error)") }
        }
        for (name, a) in runs {
            report("C3 seed \(seed) n=\(n) [\(name)]", a, trueOpt: trueOpt, sense: .maximize)
            var c = counts[name] ?? (0, 0, 0, 0)
            if a.status == .optimal, let o = a.objectiveValue, let b = a.bound {
                c.optimal += 1
                if o != b { c.differ += 1 }
                if b < trueOpt - 1e-9 * trueOpt { c.invalid += 1 }
                if abs(b - o) > allowedGap(o) { c.outside += 1 }
            }
            counts[name] = c
        }
    }
    for (k, c) in counts.sorted(by: { $0.key < $1.key }) {
        print("C3 summary [\(k)]: optimal=\(c.optimal) bound!=obj=\(c.differ) bound-cuts-optimum=\(c.invalid) outside-gap=\(c.outside)")
    }
}

// Case 4: integral costs, objective >= 1e4 (README risk 10's stated regime):
// max 100000 b + y, b binary, y integer in [0,10], row b + y <= 11 (slack).
// Oracle: enumerate b in {0,1}, y in 0...10 -> 100010.
if on("c4") {
    var best = Int.min
    for b in 0...1 { for y in 0...10 where b + y <= 11 { best = max(best, 100_000 * b + y) } }
    let trueOpt = Double(best)
    print("C4 oracle: \(best)")
    let m4 = LPModel<I>()
        .maximizing(100_000.0 * I.x(0) + I.x(1))
        .subjectTo(I.x(0) + I.x(1) <= 11)
        .bounding(I.x(0), .range(0...1))
        .bounding(I.x(1), .range(0...10))
    for (name, s) in strategies {
        do {
            let sol = try await s.solve(m4, context: ctx(5))
            report("C4 [\(name)] b=\(sol.value(of: .x(0))) y=\(sol.value(of: .x(1)))", sol.analysis, trueOpt: trueOpt, sense: .maximize)
        } catch { print("C4 [\(name)]: THROW \(error)") }
    }
}

// Case 5: the protocol-level doc on BranchAndBound: fractional root, gap closes before the tree is complete.
// max 100000 b + 3 y s.t. 2y + 2z <= 21, b binary, y,z integer in [0,20]. Oracle: enumerate -> 100030.
if on("c5") {
    var best = Int.min
    for b in 0...1 { for y in 0...20 { for z in 0...20 where 2 * y + 2 * z <= 21 { best = max(best, 100_000 * b + 3 * y) } } }
    let trueOpt = Double(best)
    print("C5 oracle: \(best)")
    let m5 = LPModel<I>()
        .maximizing(100_000.0 * I.x(0) + 3.0 * I.x(1))
        .subjectTo(2.0 * I.x(1) + 2.0 * I.x(2) <= 21)
        .bounding(I.x(0), .range(0...1))
        .bounding(I.x(1), .range(0...20))
        .bounding(I.x(2), .range(0...20))
    for (name, s) in [("bnb-det", BranchAndBound(deterministic: true)), ("bnb", BranchAndBound())] {
        do {
            let sol = try await s.solve(m5, context: ctx(5))
            report("C5 [\(name)]", sol.analysis, trueOpt: trueOpt, sense: .maximize)
        } catch { print("C5 [\(name)]: THROW \(error)") }
    }
    for (name, s) in strategies {
        do {
            let sol = try await s.solve(m5, context: ctx(5))
            report("C5 [\(name)]", sol.analysis, trueOpt: trueOpt, sense: .maximize)
        } catch { print("C5 [\(name)]: THROW \(error)") }
    }
}

// Case 6: integral cost, large objective, bounds only (no relaxation): max x, x integer in [0, 1e12+1].
// Oracle: 1e12 + 1 (the upper bound; nothing else constrains x). Below 2^49, so outside A5-01's range.
if on("c6") {
    let ub = 1e12 + 1
    let m6 = LPModel<I>()
        .maximizing(1.0 * I.x(0))
        .bounding(I.x(0), .range(0...ub))
    for (name, s) in strategies {
        for rep in 0..<3 {
            do {
                let sol = try await s.solve(m6, context: ctx(4))
                report("C6 rep\(rep) [\(name)]", sol.analysis, trueOpt: ub, sense: .maximize)
            } catch { print("C6 [\(name)]: THROW \(error)") }
        }
    }
}
