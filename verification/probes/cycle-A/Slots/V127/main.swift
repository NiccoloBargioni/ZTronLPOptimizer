// Probe V127 (cycle A, sceptic for A5-03, lens: reproduce and contract).
//
// Mirrors the four tests named in A5-03 at magnitudes inside the documented CP-SAT domain
// (README §2.5 / §4: data integral at a power of 10 up to 1e6, bounds and scaled coefficients
// below 2^53, row activities within ±2^61), through the public API only.
//
// Independent oracle: every number is p / D with an integer p and a power-of-two D, checked to
// be exact as a Double. Feasibility and optimum are decided in exact Int64 arithmetic on the
// numerators by enumerating the (tiny) integer domains. No package code is used by the oracle.
//
// Run: perl -e 'alarm shift; exec @ARGV' 900 .build/release/V127 [T1,T2,T3,T4,T0]

import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport
setvbuf(stdout, nil, _IONBF, 0)

struct Term { let col: Int; let num: Int64 }                      // coefficient = num / D
struct Row { let terms: [Term]; let lowerNum: Int64?; let upperNum: Int64? }   // sides = num / D
struct ExactModel {
    let group: String
    let label: String
    let D: Int64
    let xlNum: [Int64]
    let xuNum: [Int64]
    let rows: [Row]
    let cost: [Int64]             // integral costs, minimization
    let integerData: Bool         // every number is an integer (no fraction anywhere)
}

func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { let q = a / b; return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q }
func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }
func mul(_ a: Int64, _ b: Int64) -> Int64 { let (r, o) = a.multipliedReportingOverflow(by: b); precondition(!o, "overflow"); return r }
func add(_ a: Int64, _ b: Int64) -> Int64 { let (r, o) = a.addingReportingOverflow(b); precondition(!o, "overflow"); return r }

/// num / D as a Double, or nil when that value is not exactly representable.
func exactDouble(_ num: Int64, _ D: Int64) -> Double? {
    let d = Double(num)
    guard let back = Int64(exactly: d), back == num else { return nil }
    return d / Double(D)          // D is a power of two: exact
}

extension ExactModel {
    var n: Int { xlNum.count }
    var lo: [Int64] { xlNum.map { ceilDiv($0, D) } }
    var hi: [Int64] { xuNum.map { floorDiv($0, D) } }

    func compiled() -> CompiledLP? {
        var entries: [(row: Int, col: Int, value: Double)] = []
        var rl: [Double] = [], ru: [Double] = []
        for (i, r) in rows.enumerated() {
            for t in r.terms {
                guard let v = exactDouble(t.num, D) else { return nil }
                entries.append((i, t.col, v))
            }
            if let l = r.lowerNum { guard let v = exactDouble(l, D) else { return nil }; rl.append(v) } else { rl.append(-.infinity) }
            if let u = r.upperNum { guard let v = exactDouble(u, D) else { return nil }; ru.append(v) } else { ru.append(.infinity) }
        }
        var xl: [Double] = [], xu: [Double] = []
        for j in 0..<n {
            guard let a = exactDouble(xlNum[j], D), let b = exactDouble(xuNum[j], D) else { return nil }
            xl.append(a); xu.append(b)
        }
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: cost.map { Double($0) },
            xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: (0..<n).map { Int32($0) })
    }

    /// Exact violation of an integer point, in units of 1/D: (bounds, rows); 0 when feasible.
    func violation(_ x: [Int64]) -> (bounds: Int64, rows: Int64) {
        var vb: Int64 = 0, vr: Int64 = 0
        for j in 0..<n {
            let xd = mul(x[j], D)
            vb = max(vb, xlNum[j] - xd, xd - xuNum[j])
        }
        for r in rows {
            var act: Int64 = 0
            for t in r.terms { act = add(act, mul(t.num, x[t.col])) }   // activity·D
            if let l = r.lowerNum { vr = max(vr, l - act) }
            if let u = r.upperNum { vr = max(vr, act - u) }
        }
        return (vb, vr)
    }

    /// Exact optimum by enumeration: (objective, point), or nil when infeasible.
    func optimum() -> (Int64, [Int64])? {
        let l = lo, h = hi
        var size: Int64 = 1
        for j in 0..<n { if h[j] < l[j] { return nil }; size = mul(size, h[j] - l[j] + 1) }
        precondition(size <= 5_000_000, "domain too large for enumeration")
        var x = l
        var best: (Int64, [Int64])? = nil
        while true {
            let v = violation(x)
            if v.bounds <= 0 && v.rows <= 0 {
                var obj: Int64 = 0
                for j in 0..<n { obj = add(obj, mul(cost[j], x[j])) }
                if best == nil || obj < best!.0 { best = (obj, x) }
            }
            var k = 0
            while k < n { if x[k] < h[k] { x[k] += 1; break }; x[k] = l[k]; k += 1 }
            if k == n { break }
        }
        return best
    }
}

func statusText(_ s: SolveStatus) -> String {
    switch s {
    case .optimal: return "optimal"
    case .infeasible: return "infeasible"
    case .feasible(let r): return "feasible(\(r))"
    case .noSolution(let r): return "noSolution(\(r))"
    default: return "\(s)"
    }
}

let configs: [(String, CPSAT)] = [
    ("det", CPSAT(deterministic: true)),
    ("par", CPSAT()),
    ("detnolp", CPSAT(lpPropagator: false, deterministic: true)),
]

var tally: [String: (ok: Int, wrongOptimal: Int, rejected: Int, other: Int)] = [:]
var firstWrong: [String: String] = [:]

@MainActor func run(_ m: ExactModel) async {
    guard let lp = m.compiled() else { print("SKIP \(m.group) \(m.label): not exactly representable"); return }
    let oracle = m.optimum()
    let expected = oracle.map { "opt=\($0.0) x=\($0.1)" } ?? "infeasible"
    for (name, strategy) in configs {
        var context = SolveContext()
        context.timeLimit = 10
        var line = "\(m.group) \(m.label) [\(name)] expect \(expected) | "
        var verdict = "OTHER"
        do {
            let a = try await strategy.solve(lp, context: context)
            line += statusText(a.status)
            if let p = a.primal, a.status.hasSolution {
                let xi = p.map { Int64(exactly: $0) }
                if xi.contains(where: { $0 == nil }) {
                    line += " x=\(p) (not integral)"
                } else {
                    let x = xi.map { $0! }
                    let v = m.violation(x)
                    var obj: Int64 = 0
                    for j in 0..<m.n { obj = add(obj, mul(m.cost[j], x[j])) }
                    line += " obj=\(obj) x=\(x) exactViolation(bounds=\(Double(max(0, v.bounds)) / Double(m.D)), rows=\(Double(max(0, v.rows)) / Double(m.D)))"
                    let feasible = v.bounds <= 0 && v.rows <= 0
                    if !feasible {
                        verdict = "INFEASIBLE-POINT"            // wrong whatever the gap
                    } else if a.status == .optimal, let o = oracle {
                        // README risk 10 / CPSAT doc: .optimal means incumbent - bound <= max(1e-6, 1e-4*max(1,|incumbent|))
                        let gap = max(1e-6, 1e-4 * max(1, Double(abs(obj))))
                        if obj == o.0 { verdict = "OK" }
                        else if Double(obj - o.0) <= gap { verdict = "WITHIN-DOCUMENTED-GAP" }
                        else { verdict = "WRONG-OBJ" }
                    }
                }
            } else if a.status == .infeasible {
                verdict = oracle == nil ? "OK" : "WRONG-INFEASIBLE"
            }
        } catch let e as SolverError {
            if case .unsupported(let msg) = e { line += "THROW unsupported(\(msg))"; verdict = "REJECTED" } else { line += "THROW \(e)" }
        } catch {
            line += "THROW \(error)"
        }
        print(line + " => " + verdict)
        var t = tally[m.group] ?? (0, 0, 0, 0)
        switch verdict {
        case "OK", "WITHIN-DOCUMENTED-GAP": t.ok += 1
        case "INFEASIBLE-POINT", "WRONG-OBJ", "WRONG-INFEASIBLE": t.wrongOptimal += 1; if firstWrong[m.group] == nil { firstWrong[m.group] = "\(m.label) [\(name)]" }
        case "REJECTED": t.rejected += 1
        default: t.other += 1
        }
        tally[m.group] = t
    }
}

let only = CommandLine.arguments.count > 1 ? Set(CommandLine.arguments[1].split(separator: ",").map(String.init)) : nil
func wanted(_ g: String) -> Bool { only == nil || only!.contains(g) }
let p2: (Int) -> Int64 = { Int64(1) << Int64($0) }

// T0 — the tests' own magnitudes (largeButRepresentableDataIsAccepted, the 1e15-activity row of
// dataNearTheLimitsOfInt64IsHandled): expected to pass.
if wanted("T0") {
    await run(ExactModel(group: "T0", label: "test data 1e9*x0 + x1 >= 2e9, x0<=1e6, min x0", D: 1,
        xlNum: [0, 0], xuNum: [1_000_000, 1],
        rows: [Row(terms: [Term(col: 0, num: 1_000_000_000), Term(col: 1, num: 1)], lowerNum: 2_000_000_000, upperNum: nil)],
        cost: [1, 0], integerData: true))
    // integralScale's own example value, 123456789012.5, as a coefficient (scale 10 is exact)
    await run(ExactModel(group: "T0", label: "test value a=123456789012.5: a*x + y >= a+0.5, min y", D: 2,
        xlNum: [0, 0], xuNum: [2, 6],
        rows: [Row(terms: [Term(col: 0, num: 246_913_578_025), Term(col: 1, num: 2)], lowerNum: 246_913_578_026, upperNum: nil)],
        cost: [0, 1], integerData: false))
}

// T1 — mirror of columnBoundsRoundInward: x in [K-3-f, K] (min x, expect K-3) and x in [K-3, K+f]
// (max x, expect K), f in {0, 1/4, 1/2, 3/4}. f = 0 is integral data: nothing to round at all.
if wanted("T1") {
    for e in [36, 47, 48, 49, 50, 51, 52] {
        let K = p2(e) + 5
        let D: Int64 = 4
        for f4: Int64 in [0, 1, 2, 3] {
            await run(ExactModel(group: f4 == 0 ? "T1-int" : "T1-frac", label: "upper K+\(Double(f4) / 4), K=2^\(e)+5, max x", D: D,
                xlNum: [(K - 3) * D], xuNum: [K * D + f4], rows: [], cost: [-1], integerData: f4 == 0))
            await run(ExactModel(group: f4 == 0 ? "T1-int" : "T1-frac", label: "lower K-3-\(Double(f4) / 4), K=2^\(e)+5, min x", D: D,
                xlNum: [(K - 3) * D - f4], xuNum: [K * D], rows: [], cost: [1], integerData: f4 == 0))
        }
    }
}

// T2 — mirror of scalingToleratesFloatingPointNoiseOnly ("a large value that is not an integer is
// not mistaken for one"): a = K + 1/2, a*x + y >= a + 1/2, x binary, y in [0,3], min y -> 1.
// For 10a < 2^53 the documented domain accepts this at scale 10; beyond, README says unsupported.
if wanted("T2") {
    let Ks: [(String, Int64)] = [("2^36", p2(36)), ("2^44", p2(44)), ("2^48", p2(48)), ("2^49", p2(49)),
                                 ("7e14", 700_000_000_000_000), ("2^50", p2(50))]
    for (name, K) in Ks {
        let D: Int64 = 2
        let aNum = 2 * K + 1
        let tenA = Double(aNum) / 2 * 10
        await run(ExactModel(group: "T2", label: "a=\(name)+0.5 (10a \(tenA < 9_007_199_254_740_992 ? "<" : ">=") 2^53), min y", D: D,
            xlNum: [0, 0], xuNum: [1 * D, 3 * D],
            rows: [Row(terms: [Term(col: 0, num: aNum), Term(col: 1, num: D)], lowerNum: aNum + 1, upperNum: nil)],
            cost: [0, 1], integerData: false))
    }
}

// T3 — mirror of largeButRepresentableDataIsAccepted / dataNearTheLimitsOfInt64IsHandled with
// integral data only: a = 2^e + 1. (a) a*x + y >= 2a + 1, x in [0,2], y in [0,3], min y -> 1;
// (b) a*x - y <= 2a - 1, x fixed at 2, y in [0,3], min y -> 1.
if wanted("T3") {
    for e in [30, 47, 48, 49, 50, 51] {
        let a = p2(e) + 1
        await run(ExactModel(group: "T3", label: "(a) a=2^\(e)+1, a*x+y >= 2a+1, min y", D: 1,
            xlNum: [0, 0], xuNum: [2, 3],
            rows: [Row(terms: [Term(col: 0, num: a), Term(col: 1, num: 1)], lowerNum: 2 * a + 1, upperNum: nil)],
            cost: [0, 1], integerData: true))
        await run(ExactModel(group: "T3", label: "(b) a=2^\(e)+1, a*x-y <= 2a-1, x=2, min y", D: 1,
            xlNum: [2, 0], xuNum: [2, 3],
            rows: [Row(terms: [Term(col: 0, num: a), Term(col: 1, num: -1)], lowerNum: nil, upperNum: 2 * a - 1)],
            cost: [0, 1], integerData: true))
    }
}

// T4 — acceptance side of the ±2^61 activity limit, integral data: a = 2^40 + 1, x in [0, 2^20],
// a*x <= R with R the largest multiple of 256 below a*M (exact in Double), max x -> M - 1.
if wanted("T4") {
    let a = p2(40) + 1
    for M: Int64 in [1_000, 1_048_000] {
        let aM = mul(a, M)
        var R = (aM / 256) * 256
        if R == aM { R -= 256 }
        // a 2-column version keeps the enumeration small: x = M - 1 - d with d in [0, 5]
        // is not needed; the domain is [M-6, M+5] so that enumeration stays exact and cheap.
        await run(ExactModel(group: "T4", label: "a=2^40+1, a*x <= \(R) (a*M - \(aM - R)), M=\(M), x in [M-6, M+5], max x", D: 1,
            xlNum: [M - 6], xuNum: [M + 5],
            rows: [Row(terms: [Term(col: 0, num: a)], lowerNum: nil, upperNum: R)],
            cost: [-1], integerData: true))
    }
}

// T1u / T1l — column bounds with a small objective (no gap effect). Upper: x in [K-10, K+f], w = 1,
// y in [0,10], row x - (K-3)*w - y >= 0, max y -> 3 (x = K). Lower: x in [L, L+10] with
// L = K-3-f, w = 1, y in [0,10], row (ceil(L)+3)*w - x - y >= 0, max y -> 3 (x = ceil(L)).
// Integral coefficients and a zero row side: nothing but the column bound can be rounded.
if wanted("T1u") || wanted("T1l") {
    for e in [36, 47, 48, 49, 50, 51, 52] {
        let K = p2(e) + 5
        let D: Int64 = 4
        for f4: Int64 in [0, 1, 2, 3] {
            let grp = f4 == 0 ? "int" : "frac"
            if wanted("T1u") {
                await run(ExactModel(group: "T1u-" + grp, label: "upper bound K+\(Double(f4) / 4), K=2^\(e)+5, max y", D: D,
                    xlNum: [(K - 10) * D, D, 0], xuNum: [K * D + f4, D, 10 * D],
                    rows: [Row(terms: [Term(col: 0, num: D), Term(col: 1, num: -(K - 3) * D), Term(col: 2, num: -D)], lowerNum: 0, upperNum: nil)],
                    cost: [0, 0, -1], integerData: f4 == 0))
            }
            if wanted("T1l") {
                let lNum = (K - 3) * D - f4                 // L = K - 3 - f
                let cl = ceilDiv(lNum, D)
                await run(ExactModel(group: "T1l-" + grp, label: "lower bound K-3-\(Double(f4) / 4), K=2^\(e)+5, max y", D: D,
                    xlNum: [lNum, D, 0], xuNum: [lNum + 10 * D, D, 10 * D],
                    rows: [Row(terms: [Term(col: 0, num: -D), Term(col: 1, num: (cl + 3) * D), Term(col: 2, num: -D)], lowerNum: 0, upperNum: nil)],
                    cost: [0, 0, -1], integerData: f4 == 0))
            }
        }
    }
}

// T5 — one large coefficient (the row's common divisor) and an integral side that is not a
// multiple of it: a*x <= 5a - 1 (max x -> 4) and a*x >= 5a + 1 (min x -> 6), x in [0,10].
if wanted("T5") {
    for a: Int64 in [99_999_999, 999_999_999, 1_000_000_000, 1_000_000_001, 10_000_000_001, p2(40) + 1] {
        await run(ExactModel(group: "T5", label: "a=\(a), a*x <= 5a-1, max x", D: 1,
            xlNum: [0], xuNum: [10], rows: [Row(terms: [Term(col: 0, num: a)], lowerNum: nil, upperNum: 5 * a - 1)],
            cost: [-1], integerData: true))
        await run(ExactModel(group: "T5", label: "a=\(a), a*x >= 5a+1, min x", D: 1,
            xlNum: [0], xuNum: [10], rows: [Row(terms: [Term(col: 0, num: a)], lowerNum: 5 * a + 1, upperNum: nil)],
            cost: [1], integerData: true))
    }
}

print("\nSUMMARY (per group: ok-or-within-documented-gap / wrong (infeasible point or objective beyond gap) / rejected unsupported / other)")
for g in tally.keys.sorted() {
    let t = tally[g]!
    print("  \(g): ok=\(t.ok) wrong=\(t.wrongOptimal) rejected=\(t.rejected) other=\(t.other)  first wrong: \(firstWrong[g] ?? "-")")
}
