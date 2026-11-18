// Probe V097, cycle A: independent reproduction of finding A4-03 (REPRODUCE lens).
//
// Model family M(c2):  min x1 + c2*x2   s.t.  x1 + (c2/1.5)*x2 >= 0.5,
//                      x1 binary, x2 integer in [0, U].
// Oracle (independent of the package's maxViolation/objective):
//   x1 = 1: the row holds with x2 = 0, and c2 > 0, so the branch optimum is exactly 1.
//   x1 = 0: x2 must satisfy a*x2 >= 0.5 with a = fl(c2/1.5); the smallest such integer is
//           found with an exact FMA-based test, giving objective c2*x2min (about 0.75).
//   The integer optimum is min(1, c2*x2min).  Cross-checked by LP engines on the x1-fixed
//   subproblems (x2 relaxed; its LP optimum is integral, so it is the branch's integer optimum).
//
// Build: swift build --product V097 -c release
// Run:   perl -e 'alarm shift; exec @ARGV' 600 .build/release/V097
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum Col: LPVariable, Hashable, CustomStringConvertible {
    case x1, x2
    var domain: VariableDomain { self == .x1 ? .binary : .integer }
    var description: String { self == .x1 ? "x1" : "x2" }
}

func buildModel(c2: Double, upper: Double, integerX2: Bool = true, fixX1: Double? = nil) -> LPModel<Col> {
    var m = LPModel<Col>()
        .minimizing(1.0 * Col.x1 + c2 * Col.x2)
        .subjectTo((1.0 * Col.x1 + (c2 / 1.5) * Col.x2 >= 0.5).named("cover"))
        .bounding(.x2, .range(0...upper))
    if !integerX2 { m = m.continuous(.x2) }
    if let f = fixX1 { m = m.bounding(.x1, .fixed(f)) }
    return m
}

func ctx(_ threads: Int? = nil, _ limit: Double = 30) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = limit
    c.threads = threads
    c.metal = .off
    return c
}

func f(_ v: Double?) -> String { v.map { String(format: "%.12g", $0) } ?? "nil" }

/// Exact test of a*x >= b for doubles a, x, b (x an integer below 2^53): a*x = p + e exactly.
func exactGE(_ a: Double, _ x: Double, _ b: Double) -> Bool {
    let p = a * x
    let err = fma(a, x, -p)          // exact rounding error of the product
    if p > b { return true }
    if p < b { return false }
    return err >= 0
}

/// Smallest integer x >= 0 with a*x >= 0.5 exactly (a > 0).
func smallestCover(_ a: Double) -> Double {
    var x = (0.5 / a).rounded(.down) - 3
    if x < 0 { x = 0 }
    while !exactGE(a, x, 0.5) { x += 1 }
    return x
}

struct Oracle { let x2min: Double; let branch0: Double; let optimum: Double }
func oracle(c2: Double) -> Oracle {
    let a = c2 / 1.5
    let x2 = smallestCover(a)
    let b0 = c2 * x2
    return Oracle(x2min: x2, branch0: b0, optimum: Swift.min(1.0, b0))
}

/// Slack the README states for `.optimal`: max(abs 1e-6, rel 1e-4 * max(1, |incumbent|)).
func readmeSlack(_ inc: Double) -> Double { Swift.max(1e-6, 1e-4 * Swift.max(1, Swift.abs(inc))) }

struct Line: Hashable { let text: String }

func describeBB<E>(_ a: BranchAndBoundAnalysis<E>, truth: Double) -> (String, Bool) {
    let obj = a.objectiveValue
    let wrong = a.status.isOptimal && (obj ?? .infinity) > truth + readmeSlack(obj ?? 0)
    let boundBad = (a.bound ?? -.infinity) > truth + 1e-9
    let s = "\(a.status) obj \(f(obj)) bound \(f(a.bound)) x \((a.primal ?? []).map { f($0) }) nodes \(a.nodesProcessed) open \(a.nodesOpen) src \(a.incumbentHistory.map(\.source)) gap \(f(a.gap))"
        + (wrong ? "  <-- WRONG: .optimal but obj exceeds true optimum \(f(truth)) by \(f((obj ?? 0) - truth))" : "")
        + (boundBad ? " [bound > true optimum]" : "")
    return (s, wrong)
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
let c2 = 1e-9
let U = 1e9

// ---------- Part 0: oracle by hand / exact arithmetic ----------
let o = oracle(c2: c2)
let aCoef = c2 / 1.5
print("PART0 exact oracle c2=\(c2) a=\(String(format: "%.17g", aCoef)): x1=0 needs x2 >= \(f(o.x2min)) (0.5/a = \(String(format: "%.17g", 0.5 / aCoef))), branch0 obj \(String(format: "%.17g", o.branch0)); branch1 obj 1; optimum \(f(o.optimum))")
print("PART0 exact: a*7.5e8 >= 0.5 ? \(exactGE(aCoef, 7.5e8, 0.5));  a*(7.5e8-1) >= 0.5 ? \(exactGE(aCoef, 7.5e8 - 1, 0.5)); my activity at (0,7.5e8) = \(String(format: "%.17g", aCoef * 7.5e8)), objective = \(String(format: "%.17g", c2 * 7.5e8))")

// The compiled problem, as the DSL lowers it.
let model = buildModel(c2: c2, upper: U)
let compiled = try model.compile()
let lp = compiled.lp
print("PART0 compiled: m \(lp.m) n \(lp.n) c \(lp.c) xl \(lp.xl) xu \(lp.xu) rl \(lp.rl) ru \(lp.ru) A.values \(lp.a.values) integer \(lp.integerColumns) diagnostics \(compiled.diagnostics.map { "\($0.kind)" })")

if mode == "all" || mode == "lp" {
    // ---------- Part 1: second engines on the x1-fixed subproblems ----------
    for fx in [0.0, 1.0] {
        let sub = try buildModel(c2: c2, upper: U, integerX2: false, fixX1: fx).compile().lp.relaxed()
        let s1 = try await Simplex(.dual).solve(sub, context: ctx())
        let s2 = try await Simplex(.primal).solve(sub, context: ctx())
        let s3 = try await InteriorPoint().solve(sub, context: ctx())
        print("PART1 x1=\(Int(fx)) LP: dual \(s1.status) \(f(s1.objectiveValue)) x \((s1.primal ?? []).map { f($0) }) | primal \(s2.status) \(f(s2.objectiveValue)) | ipm \(s3.status) \(f(s3.objectiveValue)) x \((s3.primal ?? []).map { f($0) })")
    }
    // Full LP relaxation (root bound).
    let root = try await Simplex(.dual).solve(lp.relaxed(), context: ctx())
    print("PART1 root LP relaxation: \(root.status) \(f(root.objectiveValue)) x \((root.primal ?? []).map { f($0) })")
}

if mode == "all" || mode == "bb" {
    // ---------- Part 2: the MIP, many configurations, repeated ----------
    let reps = 6
    func rep<E>(_ name: String, _ make: () -> BranchAndBound<E>, threads: Int? = nil) async throws {
        var outs: [String: Int] = [:]
        var wrongCount = 0
        var maxSec = 0.0
        for _ in 0..<reps {
            let a = try await make().solve(lp, context: ctx(threads))
            let (s, w) = describeBB(a, truth: o.optimum)
            outs[s, default: 0] += 1
            if w { wrongCount += 1 }
            maxSec = Swift.max(maxSec, a.seconds)
        }
        for (s, k) in outs.sorted(by: { $0.value > $1.value }) {
            print("PART2 \(name) [\(k)/\(reps)]: \(s)")
        }
        print("PART2 \(name): wrong \(wrongCount)/\(reps), max solve seconds \(f(maxSec)) (time limit 30)")
    }
    try await rep("default(8 threads)", { BranchAndBound() })
    try await rep("default threads=1", { BranchAndBound() }, threads: 1)
    try await rep("dual-engine", { BranchAndBound(engine: Simplex(.dual)) })
    try await rep("ipm-engine", { BranchAndBound(engine: InteriorPoint()) })
    try await rep("deterministic seed0", { BranchAndBound(deterministic: true, seed: 0) })
    try await rep("deterministic seed987654321", { BranchAndBound(deterministic: true, seed: 987_654_321) })
    try await rep("exact gap 0/0", { BranchAndBound(gap: Gap(relative: 0, absolute: 0)) })
    try await rep("no heuristics", { BranchAndBound(heuristics: .none) })
    try await rep("no heuristics, mostFractional, primal", { BranchAndBound(branching: .mostFractional, heuristics: .none) })
    try await rep("no heuristics, mostFractional, dual", { BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none) })
    try await rep("no heuristics, depthFirst", { BranchAndBound(nodeSelection: .depthFirst, heuristics: .none) })
    try await rep("strong, bestBound", { BranchAndBound(branching: .strong(candidates: 4), nodeSelection: .bestBound) })

    // Facade on the DSL model.
    for k in 0..<3 {
        let sol = try await Automatic().solve(model, context: ctx())
        let wrong = sol.status.isOptimal && (sol.objectiveValue ?? .infinity) > o.optimum + readmeSlack(sol.objectiveValue ?? 0)
        print("PART2 Automatic() on LPModel run \(k): engine \(sol.analysis.engine) \(sol.status) obj \(f(sol.objectiveValue)) bound \(f(sol.analysis.bound)) x1 \(f(sol.value(of: .x1))) x2 \(f(sol.value(of: .x2)))" + (wrong ? "  <-- WRONG" : ""))
    }
}

if mode == "all" || mode == "sweep" {
    // ---------- Part 3: threshold sweep over c2 (true optimum ~0.75 for every c2) ----------
    for cc in [4e-9, 2e-9, 1.5e-9, 1.1e-9, 1.000001e-9, 1.0000000000000002e-9, 1e-9, 9.99999e-10, 9e-10, 5e-10, 1e-10] {
        let oc = oracle(c2: cc)
        let up = 2 * (0.75 / cc).rounded(.up)
        let l = try buildModel(c2: cc, upper: up).compile().lp
        let a = try await BranchAndBound().solve(l, context: ctx())
        let d = try await BranchAndBound(deterministic: true).solve(l, context: ctx())
        let (sa, _) = describeBB(a, truth: oc.optimum)
        let (sd, _) = describeBB(d, truth: oc.optimum)
        print("PART3 c2=\(String(format: "%.17g", cc)) U=\(f(up)) truth \(f(oc.optimum)) (x2min \(f(oc.x2min)))\n      default: \(sa)\n      determ.: \(sd)")
    }

    // ---------- Part 4: contrasts ----------
    // x2 continuous: a costed continuous column makes the step 0.
    let cont = try buildModel(c2: c2, upper: U, integerX2: false).compile().lp
    let ac = try await BranchAndBound().solve(cont, context: ctx())
    print("PART4 x2 continuous, c2=1e-9: \(describeBB(ac, truth: 0.75).0)")
    // Same model with every cost multiplied by 2 (c = (2, 2e-9)): the optimum doubles to 1.5.
    let m2 = LPModel<Col>()
        .minimizing(2.0 * Col.x1 + 2e-9 * Col.x2)
        .subjectTo((1.0 * Col.x1 + (1e-9 / 1.5) * Col.x2 >= 0.5).named("cover"))
        .bounding(.x2, .range(0...U))
    let a2 = try await BranchAndBound().solve(try m2.compile().lp, context: ctx())
    print("PART4 costs doubled (2, 2e-9), same rows: \(describeBB(a2, truth: 1.5).0)")
    // Same model with the objective scaled by 1/1000 (c = (1e-3, 1e-12)): step test at scale 1000.
    let m3 = LPModel<Col>()
        .minimizing(1e-3 * Col.x1 + 1e-12 * Col.x2)
        .subjectTo((1.0 * Col.x1 + (1e-9 / 1.5) * Col.x2 >= 0.5).named("cover"))
        .bounding(.x2, .range(0...U))
    let a3 = try await BranchAndBound().solve(try m3.compile().lp, context: ctx())
    print("PART4 objective scaled 1e-3 (1e-3, 1e-12): \(describeBB(a3, truth: 0.75e-3).0)")
}
print("DONE")
