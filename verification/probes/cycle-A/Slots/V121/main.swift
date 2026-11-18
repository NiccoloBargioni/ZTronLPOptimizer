// Probe slot V121 of cycle A: independent REPRODUCE check of finding A5-01 (CP-SAT snap tolerance).
// Build: swift build --product V121 -c release   Run: .build/release/V121 [reps]
//
// Models are built with the public DSL (LPModel), not by hand. The oracle is independent of the
// package: every expected optimum is obtained by exhaustive enumeration (or a closed form for a
// single bounded column) in exact Int64 arithmetic on the data as written, and every returned
// point is re-checked in exact Int64 arithmetic (no Double tolerance, no CompiledLP.maxViolation).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum V: LPVariable, CustomStringConvertible {
    case x, y
    var domain: VariableDomain { .integer }
    var description: String { self == .x ? "x" : "y" }
}

let reps = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3

func ctx() -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 20
    return c
}

func cpConfigs() -> [(String, CPSAT)] {
    [
        ("det", CPSAT(deterministic: true)),
        ("det-noLP", CPSAT(lpPropagator: false, deterministic: true)),
        ("w1-seed7", CPSAT(workers: 1, clauseSharing: false, seed: 7)),
        ("w4-seed3", CPSAT(workers: 4, seed: 3)),
        ("default", CPSAT()),
    ]
}

func st(_ s: SolveStatus) -> String {
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

/// One test case: the model, plus an exact description of the same model as written, for the
/// oracle. `feasible` and `objective` take the point in column order of the compiled model.
struct Case {
    let name: String
    let model: LPModel<V>
    let keepSingletonRows: Bool
    /// Exact feasibility of an integer point (x, y) for the data as written.
    let feasible: (Int64, Int64) -> Bool
    /// Exact objective in the model's own sense.
    let objective: (Int64, Int64) -> Int64
    let maximize: Bool
    /// Exact optimum by enumeration or closed form, nil when the model is infeasible.
    let exactOptimum: Int64?
    let note: String
}

/// Exhaustive enumeration over small integer boxes (exact Int64).
func enumerate(xs: ClosedRange<Int64>, ys: ClosedRange<Int64>, maximize: Bool,
               feasible: (Int64, Int64) -> Bool, objective: (Int64, Int64) -> Int64) -> (Int64, Int64, Int64)? {
    var best: (Int64, Int64, Int64)? = nil
    for x in xs {
        for y in ys where feasible(x, y) {
            let f = objective(x, y)
            if best == nil || (maximize ? f > best!.2 : f < best!.2) { best = (x, y, f) }
        }
    }
    return best
}

let p49: Int64 = 1 << 49, p50: Int64 = 1 << 50, p51: Int64 = 1 << 51, p52: Int64 = 1 << 52, p53: Int64 = 1 << 53

var cases: [Case] = []

// A: x fixed at R = 2^52 + 1, y in [0, 10], x + y <= R, maximize y.
do {
    let R: Int64 = p52 + 1
    let Rd = Double(R)
    precondition(Int64(exactly: Rd) == R)
    let feas: (Int64, Int64) -> Bool = { x, y in x >= R && x <= R && y >= 0 && y <= 10 && x + y <= R }
    let obj: (Int64, Int64) -> Int64 = { _, y in y }
    let e = enumerate(xs: R...R, ys: 0...10, maximize: true, feasible: feas, objective: obj)
    let m = LPModel<V>()
        .maximizing(V.y)
        .subjectTo(V.x + V.y <= Rd)
        .bounding(.x, .fixed(Rd))
        .bounding(.y, Bounds(lower: 0, upper: 10))
    cases.append(Case(name: "A fixed x=2^52+1, x+y<=2^52+1, max y", model: m, keepSingletonRows: false,
                      feasible: feas, objective: obj, maximize: true, exactOptimum: e?.2,
                      note: "enumerated y in 0...10 with x = \(R): best \(String(describing: e))"))
}

// B: (1e15 + 0.5) x + y >= 1e15 + 1, x binary, y in [0, 3], minimize y. In halves (exact):
//    (2e15 + 1) x + 2 y >= 2e15 + 2.
do {
    let a = 1e15 + 0.5
    let r = 1e15 + 1
    precondition(a * 2 == 2e15 + 1 && Int64(exactly: a * 2) == 2_000_000_000_000_001)
    let a2: Int64 = 2_000_000_000_000_001, r2: Int64 = 2_000_000_000_000_002
    let feas: (Int64, Int64) -> Bool = { x, y in (x == 0 || x == 1) && y >= 0 && y <= 3 && a2 * x + 2 * y >= r2 }
    let obj: (Int64, Int64) -> Int64 = { _, y in y }
    let e = enumerate(xs: 0...1, ys: 0...3, maximize: false, feasible: feas, objective: obj)
    let m = LPModel<V>()
        .minimizing(V.y)
        .subjectTo(a * V.x + V.y >= r)
        .binary(.x)
        .bounding(.y, Bounds(lower: 0, upper: 3))
    cases.append(Case(name: "B (1e15+0.5)x + y >= 1e15+1, x bin, y<=3, min y", model: m, keepSingletonRows: false,
                      feasible: feas, objective: obj, maximize: false, exactOptimum: e?.2,
                      note: "enumerated x in 0...1, y in 0...3 (halves, exact): best \(String(describing: e)); README also allows .unsupported (scale 10 gives >= 2^53)"))
}

// C: one column x in [0, B], maximize x (bound only); and the mirror x in [-B, 0], minimize x.
for (label, B) in [("2^49+1", p49 + 1), ("2^50+1", p50 + 1), ("2^51+1", p51 + 1), ("2^52+1", p52 + 1)] {
    let Bd = Double(B)
    precondition(Int64(exactly: Bd) == B)
    let feasU: (Int64, Int64) -> Bool = { x, _ in x >= 0 && x <= B }
    let feasL: (Int64, Int64) -> Bool = { x, _ in x >= -B && x <= 0 }
    cases.append(Case(name: "C x in [0, \(label)], max x", model: LPModel<V>().maximizing(V.x).bounding(.x, Bounds(lower: 0, upper: Bd)),
                      keepSingletonRows: false, feasible: feasU, objective: { x, _ in x }, maximize: true, exactOptimum: B,
                      note: "closed form: max of {0..B} is B = \(B)"))
    cases.append(Case(name: "C' x in [-(\(label)), 0], min x", model: LPModel<V>().minimizing(V.x).bounding(.x, Bounds(lower: -Bd, upper: 0)),
                      keepSingletonRows: false, feasible: feasL, objective: { x, _ in x }, maximize: false, exactOptimum: -B,
                      note: "closed form: min of {-B..0} is -B = \(-B)"))
}

// D: a row, not a bound: x in [0, 2^52 + 100], row x <= 2^52 + 1 (singleton kept as a row), max x.
do {
    let R: Int64 = p52 + 1
    let U: Int64 = p52 + 100
    let feas: (Int64, Int64) -> Bool = { x, _ in x >= 0 && x <= U && x <= R }
    let m = LPModel<V>().maximizing(V.x).subjectTo(1.0 * V.x <= Double(R)).bounding(.x, Bounds(lower: 0, upper: Double(U)))
    cases.append(Case(name: "D row x <= 2^52+1 (bound 2^52+100), max x", model: m, keepSingletonRows: true,
                      feasible: feas, objective: { x, _ in x }, maximize: true, exactOptimum: R, note: "closed form: min(U, R) = \(R)"))
}

// T: realistic: a start time in microseconds since 1970 (about 1.73e15, between 2^50 and 2^51) must
//    not precede a release time; minimize the start time. Two columns: start s = x, slack y in [0, 5].
//    x - y >= release, x in [release - 10, release + 10]; minimize x.
do {
    let release: Int64 = 1_731_916_800_000_001
    precondition(Int64(exactly: Double(release)) == release)
    let lo = release - 10, hi = release + 10
    let feas: (Int64, Int64) -> Bool = { x, y in x >= lo && x <= hi && y >= 0 && y <= 5 && x - y >= release }
    let obj: (Int64, Int64) -> Int64 = { x, _ in x }
    let e = enumerate(xs: lo...hi, ys: 0...5, maximize: false, feasible: feas, objective: obj)
    let m = LPModel<V>()
        .minimizing(V.x)
        .subjectTo(V.x - V.y >= Double(release))
        .bounding(.x, Bounds(lower: Double(lo), upper: Double(hi)))
        .bounding(.y, Bounds(lower: 0, upper: 5))
    cases.append(Case(name: "T microsecond timestamp: x - y >= 1731916800000001, min x", model: m, keepSingletonRows: false,
                      feasible: feas, objective: obj, maximize: false, exactOptimum: e?.2,
                      note: "enumerated x in \(lo)...\(hi), y in 0...5: best \(String(describing: e))"))
}

// E: the rejection limit. README: .unsupported only for bounds of magnitude 2^53 or more.
for (label, U) in [("2^53-1", p53 - 1), ("2^53-4", p53 - 4), ("2^53-5", p53 - 5)] {
    precondition(Int64(exactly: Double(U)) == U)
    cases.append(Case(name: "E x in [0, \(label)], max x", model: LPModel<V>().maximizing(V.x).bounding(.x, Bounds(lower: 0, upper: Double(U))),
                      keepSingletonRows: false, feasible: { x, _ in x >= 0 && x <= U }, objective: { x, _ in x }, maximize: true,
                      exactOptimum: U, note: "closed form: \(U); README: accepted (below 2^53)"))
}

// Control: the same structure as A at a small magnitude (must be right).
do {
    let R: Int64 = 1001
    let feas: (Int64, Int64) -> Bool = { x, y in x == R && y >= 0 && y <= 10 && x + y <= R }
    let m = LPModel<V>().maximizing(V.y).subjectTo(V.x + V.y <= Double(R)).bounding(.x, .fixed(Double(R))).bounding(.y, Bounds(lower: 0, upper: 10))
    cases.append(Case(name: "K control: fixed x=1001, x+y<=1001, max y", model: m, keepSingletonRows: false,
                      feasible: feas, objective: { _, y in y }, maximize: true, exactOptimum: 0, note: "control"))
}

let only = ProcessInfo.processInfo.environment["V121_ONLY"].map { $0.split(separator: ",").map(String.init) } ?? []

func exactCheck(_ c: Case, _ lp: CompiledLP, _ primal: [Double]?) -> String {
    guard let p = primal else { return "no primal" }
    // Map compiled columns back to x and y by name.
    var xv: Int64 = 0, yv: Int64 = 0
    for j in 0..<lp.n {
        guard let v = Int64(exactly: p[j]) else { return "column \(j) non-integral value \(p[j])" }
        let name = lp.names.column(j)
        if name == "x" { xv = v } else if name == "y" { yv = v }
    }
    let ok = c.feasible(xv, yv)
    return "point(x=\(xv), y=\(yv)) exactFeasible=\(ok) exactObjective=\(c.objective(xv, yv))"
}

var mismatches = 0
for c in cases {
    if !only.isEmpty && !only.contains(where: { c.name.hasPrefix($0 + " ") }) { continue }
    print("== \(c.name)")
    print("   oracle: exact optimum \(c.exactOptimum.map(String.init) ?? "infeasible") (\(c.note))")
    var options = CompileOptions()
    options.lowerSingletonConstraints = !c.keepSingletonRows
    let compiled: CompiledModel<V>
    do { compiled = try c.model.compile(options: options) } catch { print("   compile threw \(error)"); continue }
    let lp = compiled.lp
    print("   compiled: n=\(lp.n) m=\(lp.m) names=\((0..<lp.n).map { lp.names.column($0) }) xl=\(lp.xl.map { String(format: "%.1f", $0) }) xu=\(lp.xu.map { String(format: "%.1f", $0) }) rl=\(lp.rl.map { String(format: "%.1f", $0) }) ru=\(lp.ru.map { String(format: "%.1f", $0) }) c=\(lp.c) sense=\(lp.sense) int=\(lp.integerColumns)")
    for (cfgName, s) in cpConfigs() {
        var signatures: [String] = []
        for _ in 0..<reps {
            do {
                let a = try await s.solve(lp, context: ctx())
                let obj = a.objectiveValue.map { String(format: "%.1f", $0) } ?? "nil"
                let bnd = a.bound.map { String(format: "%.1f", $0) } ?? "nil"
                let mv = a.primal.map { lp.maxViolation(at: $0) }
                signatures.append("\(st(a.status)) obj=\(obj) bound=\(bnd) \(exactCheck(c, lp, a.primal)) [pkg maxViolation \(mv.map { "b=\($0.bounds) r=\($0.rows)" } ?? "-")]")
            } catch {
                signatures.append("THROW \(error)")
            }
        }
        let distinct = Array(Set(signatures))
        print("   CPSAT[\(cfgName)] x\(reps) \(distinct.count == 1 ? "identical" : "DIFFER(\(distinct.count))"): \(distinct.joined(separator: " | "))")
        if let first = signatures.first, first.hasPrefix("optimal"), let e = c.exactOptimum {
            if !first.contains("exactObjective=\(e) ") || first.contains("exactFeasible=false") { mismatches += 1 }
        }
    }
    // Second engine: branch and bound on the same compiled problem.
    do {
        let a = try await BranchAndBound().solve(lp, context: ctx())
        let obj = a.objectiveValue.map { String(format: "%.1f", $0) } ?? "nil"
        print("   BranchAndBound: \(st(a.status)) obj=\(obj) \(exactCheck(c, lp, a.primal.map { $0.map { $0.rounded() } })) raw=\(a.primal ?? [])")
    } catch {
        print("   BranchAndBound: THROW \(error)")
    }
}
print("CP-SAT .optimal results that disagree with the exact oracle (first run per config): \(mismatches)")
