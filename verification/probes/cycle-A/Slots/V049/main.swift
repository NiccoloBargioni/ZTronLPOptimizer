// V049 - sceptic probe for finding A2-07 (cycle A; lens: reproduce and contract).
//
// The finding says no Simplex test checks the duals or reduced costs a solve returns beyond one
// textbook LP, so a wrong dual sign or dual-infeasible reduced costs would pass the suite.
//
// Method 1 (is the suite able to fail?): the dual assertions the suite already contains are
//   re-implemented here, expression for expression:
//     NetlibSimplexTests.check (Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift:44-55),
//     FacadeTests.transportLPWithNamedDuals (Tests/ZTronLPOptimizerTests/FacadeTests.swift:95-117),
//     SimplexBasicsTests.textbookProblem (Tests/ZTronLPSimplexTests/SimplexTests.swift:65-80).
//   They are fed the solver's real duals (control) and deliberately broken ones (mutations).
// Method 2 (are the duals right? an oracle unlike the finder's per-component sign checks):
//   (a) recompute y from the returned basis, B^T y = c_B, by my own dense Gaussian elimination;
//   (b) certify optimality with the Lagrangian dual function of the minimization form,
//       g(y) = c0 + sum_j min_{x_j in [xl_j, xu_j]} d_j x_j + sum_i min_{s_i in [rl_i, ru_i]} y_i s_i,
//       which bounds the optimum from below for ANY y (weak duality): duality gap c'x + c0 - g(y).
//
// Usage: V049 [all|netlib|transport|textbook|constructed|hilbert]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "all"
let inf = Double.infinity

func limited(_ seconds: Double = 120) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    return c
}

func e(_ v: Double) -> String { String(format: "%.2e", v) }

// MARK: - Re-implemented suite assertions

/// NetlibSimplexTests.check, lines 48-55: structural dual feasibility with complementary slackness.
func netlibDualWorst(_ lp: CompiledLP, x: [Double], y: [Double]) -> Double {
    let d = lp.reducedCosts(forDuals: y)
    var worst = 0.0
    for j in 0..<lp.n {
        if x[j] > lp.xl[j] + 1e-6 * (1 + abs(x[j])) { worst = max(worst, d[j]) }
        if x[j] < lp.xu[j] - 1e-6 * (1 + abs(x[j])) { worst = max(worst, -d[j]) }
    }
    return worst
}

let supply = [30.0, 25, 45]
let demand = [20.0, 30, 10, 25]

/// FacadeTests.transportLPWithNamedDuals, lines 109-116: strong duality by name, rc >= -1e-7.
func transportAssertionsPass(y: [Double], rc: [Double], objective: Double) -> (strong: Bool, signs: Bool) {
    var dualObjective = 0.0
    for i in 0..<3 { dualObjective += supply[i] * y[i] }
    for j in 0..<4 { dualObjective += demand[j] * y[3 + j] }
    let strong = abs(dualObjective - objective) <= 1e-7 * max(1, abs(objective))
    let signs = (0..<12).allSatisfy { rc[$0] >= -1e-7 }
    return (strong, signs)
}

/// SimplexBasicsTests.textbookProblem, lines 77-79.
func textbookAssertionsPass(y: [Double], rc: [Double], n: Int, m: Int) -> Bool {
    abs(y[0]) < 1e-9 && abs(y[1] - 1.5) < 1e-9 && abs(y[2] - 1) < 1e-9 && rc.count == n + m
}

// MARK: - Independent oracle

struct Lagrange { var g: Double; var infeasibility: Double }

/// The Lagrangian dual function of the minimization form at yMin. A coefficient that would
/// multiply an infinite bound makes g = -inf; its size is returned as `infeasibility`.
func lagrange(_ lp: CompiledLP, yMin: [Double]) -> Lagrange {
    let d = lp.reducedCosts(forDuals: yMin)
    var g = lp.c0
    var infeasibility = 0.0
    func term(_ coefficient: Double, _ lo: Double, _ hi: Double) {
        if coefficient > 0 {
            if lo.isFinite { g += coefficient * lo } else { infeasibility = max(infeasibility, coefficient) }
        } else if coefficient < 0 {
            if hi.isFinite { g += coefficient * hi } else { infeasibility = max(infeasibility, -coefficient) }
        }
    }
    for j in 0..<lp.n { term(d[j], lp.xl[j], lp.xu[j]) }
    for i in 0..<lp.m { term(yMin[i], lp.rl[i], lp.ru[i]) }
    return Lagrange(g: g, infeasibility: infeasibility)
}

/// Relative duality gap and dual infeasibility of (x, yMin), both >= 0 up to rounding.
func certificate(_ lp: CompiledLP, x: [Double], yMin: [Double]) -> (gap: Double, infeasibility: Double) {
    let l = lagrange(lp, yMin: yMin)
    let p = lp.internalObjective(at: x)
    return ((p - l.g) / (1 + abs(p)), l.infeasibility)
}

/// y from the basis: one equation per basic variable. Structural j: A_j' y = c_j. Logical i
/// (column -e_i, cost 0): y_i = 0. Dense Gaussian elimination with partial pivoting.
func basisDual(_ lp: CompiledLP, basic: [Int32]) -> [Double]? {
    let m = lp.m
    let n = lp.n
    guard basic.count == m, m > 0 else { return nil }
    var a = [Double](repeating: 0, count: m * m)
    var b = [Double](repeating: 0, count: m)
    for (k, raw) in basic.enumerated() {
        let index = Int(raw)
        if index < n {
            for p in lp.a.colStart[index]..<lp.a.colStart[index + 1] {
                a[k * m + Int(lp.a.rowIndex[p])] += lp.a.values[p]
            }
            b[k] = lp.c[index]
        } else {
            a[k * m + (index - n)] = 1
        }
    }
    for col in 0..<m {
        var pivotRow = col
        var best = abs(a[col * m + col])
        for r in (col + 1)..<m where abs(a[r * m + col]) > best {
            best = abs(a[r * m + col])
            pivotRow = r
        }
        if best == 0 { return nil }
        if pivotRow != col {
            for k in 0..<m { a.swapAt(pivotRow * m + k, col * m + k) }
            b.swapAt(pivotRow, col)
        }
        let pivot = a[col * m + col]
        for r in (col + 1)..<m {
            let f = a[r * m + col] / pivot
            if f == 0 { continue }
            for k in col..<m { a[r * m + k] -= f * a[col * m + k] }
            b[r] -= f * b[col]
        }
    }
    var y = [Double](repeating: 0, count: m)
    for r in stride(from: m - 1, through: 0, by: -1) {
        var s = b[r]
        for k in (r + 1)..<m { s -= a[r * m + k] * y[k] }
        y[r] = s / a[r * m + r]
    }
    return y
}

/// Reported reduced costs as the package derives them from reported duals (Simplex.postsolved).
func reportedReducedCosts(_ lp: CompiledLP, reportedDual y: [Double]) -> [Double] {
    let flip: Double = lp.sense == .maximize ? -1 : 1
    return lp.reducedCosts(forDuals: y.map { flip * $0 }).map { flip * $0 }
}

func globalMutations(_ y: [Double]) -> [(String, [Double])] {
    var out: [(String, [Double])] = [
        ("negate all duals", y.map { -$0 }),
        ("all duals zero", [Double](repeating: 0, count: y.count)),
    ]
    if let k = y.indices.max(by: { abs(y[$0]) < abs(y[$1]) }), y[k] != 0 {
        var z = y
        z[k] = -z[k]
        out.append(("negate the largest dual", z))
    }
    out.append(("duals x 1.001", y.map { 1.001 * $0 }))
    out.append(("duals x 1.1", y.map { 1.1 * $0 }))
    return out
}

// MARK: - Netlib: the NetlibSimplexTests configurations

let configurations: [(String, Simplex)] = [
    ("primal", Simplex(.primal)),
    ("dual", Simplex(.dual)),
    ("primal/nopre/noscale", Simplex(.primal, presolve: false, scaling: .none)),
    ("dual/nopre/noscale", Simplex(.dual, presolve: false, scaling: .none)),
]

func runNetlib() async throws {
    print("== netlib: 13 instances x 4 NetlibSimplexTests configurations")
    var cases = 0
    var controlPass = 0
    var worstControlRatio = 0.0
    var worstGap = 0.0
    var worstInfeasibility = 0.0
    var worstBasisDiff = 0.0
    var basisChecked = 0
    var worstRcConsistency = 0.0
    var global: [String: (caught: Int, total: Int, oracle: Int)] = [:]
    var order: [String] = []
    var flipOne = (caught: 0, total: 0, oracle: 0)
    var zeroOne = (caught: 0, total: 0, oracle: 0)
    for instance in ReferenceValues.netlib {
        let lp = try NetlibFixtures.load(instance.name)
        for (name, strategy) in configurations {
            let analysis = try await strategy.solve(lp, context: limited())
            guard analysis.status == .optimal, let x = analysis.primal, let y = analysis.dual,
                  let objective = analysis.objectiveValue, let rc = analysis.reducedCosts
            else {
                print("  \(instance.name) \(name): \(analysis.status) (skipped)")
                continue
            }
            cases += 1
            let tolerance = 1e-5 * (1 + abs(objective))
            let control = netlibDualWorst(lp, x: x, y: y)
            if control <= tolerance { controlPass += 1 }
            worstControlRatio = max(worstControlRatio, control / tolerance)
            let flip: Double = lp.sense == .maximize ? -1 : 1
            let yMin = y.map { flip * $0 }
            let cert = certificate(lp, x: x, yMin: yMin)
            worstGap = max(worstGap, abs(cert.gap))
            worstInfeasibility = max(worstInfeasibility, cert.infeasibility)
            var basisDiffText = "n/a"
            if let yb = basisDual(lp, basic: analysis.basis.basic) {
                let scale = 1 + (yMin.map { abs($0) }.max() ?? 0)
                var diff = 0.0
                for i in 0..<lp.m { diff = max(diff, abs(yb[i] - yMin[i])) }
                worstBasisDiff = max(worstBasisDiff, diff / scale)
                basisChecked += 1
                basisDiffText = e(diff / scale)
            }
            let derived = reportedReducedCosts(lp, reportedDual: y)
            var rcDiff = 0.0
            for k in 0..<(lp.n + lp.m) { rcDiff = max(rcDiff, abs(derived[k] - rc[k])) }
            worstRcConsistency = max(worstRcConsistency, rcDiff)

            // Oracle threshold for "this dual vector is not optimal": README's 1e-7 scale.
            func oracleRejects(_ z: [Double]) -> Bool {
                let c = certificate(lp, x: x, yMin: z.map { flip * $0 })
                return c.gap > 1e-7 || c.infeasibility > 1e-7
            }
            var line = "  \(instance.name) \(name): control worst \(e(control)) tol \(e(tolerance)) gap \(e(cert.gap)) dualInf \(e(cert.infeasibility)) |y-yB| \(basisDiffText)"
            for (label, z) in globalMutations(y) {
                if global[label] == nil { global[label] = (0, 0, 0); order.append(label) }
                let caught = netlibDualWorst(lp, x: x, y: z) > tolerance
                global[label]!.total += 1
                if caught { global[label]!.caught += 1 }
                if oracleRejects(z) { global[label]!.oracle += 1 }
                if !caught { line += " | MISSED '\(label)'" }
            }
            print(line)
            for i in 0..<lp.m where abs(y[i]) > 1e-9 {
                var z = y
                z[i] = -z[i]
                flipOne.total += 1
                if netlibDualWorst(lp, x: x, y: z) > tolerance { flipOne.caught += 1 }
                if oracleRejects(z) { flipOne.oracle += 1 }
                z[i] = 0
                zeroOne.total += 1
                if netlibDualWorst(lp, x: x, y: z) > tolerance { zeroOne.caught += 1 }
                if oracleRejects(z) { zeroOne.oracle += 1 }
            }
        }
    }
    print("netlib cases solved optimal: \(cases); control (real duals) passes the suite's assertion: \(controlPass)/\(cases); worst worst/tol \(e(worstControlRatio))")
    print("independent oracle on real duals: worst |duality gap| \(e(worstGap)), worst dual infeasibility \(e(worstInfeasibility)), worst |y - B^-T c_B|/(1+|y|max) \(e(worstBasisDiff)) over \(basisChecked) bases, worst |reported rc - derived rc| \(e(worstRcConsistency))")
    for label in order {
        let r = global[label]!
        print("mutation '\(label)': NetlibSimplexTests assertion fails in \(r.caught)/\(r.total) cases; Lagrangian oracle rejects \(r.oracle)/\(r.total)")
    }
    print("mutation 'negate one nonzero dual' (each in turn): assertion fails \(flipOne.caught)/\(flipOne.total); oracle rejects \(flipOne.oracle)/\(flipOne.total)")
    print("mutation 'zero one nonzero dual' (each in turn): assertion fails \(zeroOne.caught)/\(zeroOne.total); oracle rejects \(zeroOne.oracle)/\(zeroOne.total)")
}

// MARK: - Transport LP of FacadeTests (as a CompiledLP)

func transportLP() -> CompiledLP {
    var entries: [(row: Int, col: Int, value: Double)] = []
    var c: [Double] = []
    for i in 0..<3 {
        for j in 0..<4 {
            let k = i * 4 + j
            c.append(Double(1 + (i * 4 + j * 3) % 6))
            entries.append((row: i, col: k, value: 1))
            entries.append((row: 3 + j, col: k, value: 1))
        }
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: 7, cols: 12, entries), c: c,
        xl: [Double](repeating: 0, count: 12), xu: [Double](repeating: inf, count: 12),
        rl: [-inf, -inf, -inf] + demand, ru: supply + [inf, inf, inf, inf])
}

func runTransport() async throws {
    print("== transport LP of FacadeTests.transportLPWithNamedDuals, Simplex(.dual) and Simplex(.primal)")
    let lp = transportLP()
    for strategy in [Simplex(.dual), Simplex(.primal)] {
        let analysis = try await strategy.solve(lp, context: limited())
        guard analysis.status == .optimal, let x = analysis.primal, let y = analysis.dual,
              let objective = analysis.objectiveValue, let rc = analysis.reducedCosts
        else { print("  \(analysis.status)"); continue }
        let control = transportAssertionsPass(y: y, rc: rc, objective: objective)
        let cert = certificate(lp, x: x, yMin: y)
        print("  objective \(objective) duals \(y.map { e($0) }) control strong=\(control.strong) signs=\(control.signs); oracle gap \(e(cert.gap)) dualInf \(e(cert.infeasibility))")
        var mutations = globalMutations(y).map { ($0.0, $0.1, reportedReducedCosts(lp, reportedDual: $0.1)) }
        mutations.append(("reduced costs alone negated", y, rc.map { -$0 }))
        for (label, z, r) in mutations {
            let result = transportAssertionsPass(y: z, rc: r, objective: objective)
            let caught = !(result.strong && result.signs)
            print("    mutation '\(label)': FacadeTests assertions \(caught ? "FAIL (caught)" : "pass (missed)") strong=\(result.strong) signs=\(result.signs)")
        }
    }
}

// MARK: - Textbook maximization of SimplexBasicsTests

func runTextbook() async throws {
    print("== textbook max LP of SimplexBasicsTests.textbookProblem")
    let lp = CompiledLP(
        a: SparseCSC.fromTriplets(rows: 3, cols: 2, [(row: 0, col: 0, value: 1), (row: 1, col: 1, value: 2), (row: 2, col: 0, value: 3), (row: 2, col: 1, value: 2)]),
        c: [-3, -5], sense: .maximize, xl: [0, 0], xu: [inf, inf], rl: [-inf, -inf, -inf], ru: [4, 12, 18])
    for method in [Simplex.Method.primal, .dual] {
        for presolve in [true, false] {
            let analysis = try await Simplex(method, presolve: presolve).solve(lp, context: limited())
            guard let x = analysis.primal, let y = analysis.dual, let rc = analysis.reducedCosts else {
                print("  \(method) presolve \(presolve): \(analysis.status)"); continue
            }
            let cert = certificate(lp, x: x, yMin: y.map { -$0 })
            print("  \(method) presolve \(presolve): \(analysis.status) obj \(analysis.objectiveValue ?? .nan) y \(y) rc \(rc) control \(textbookAssertionsPass(y: y, rc: rc, n: 2, m: 3)) oracle gap \(e(cert.gap)) dualInf \(e(cert.infeasibility))")
            var mutations = globalMutations(y).map { ($0.0, $0.1, reportedReducedCosts(lp, reportedDual: $0.1)) }
            mutations.append(("reduced costs alone negated", y, rc.map { -$0 }))
            mutations.append(("reduced costs without the max flip", y, lp.reducedCosts(forDuals: y.map { -$0 })))
            for (label, z, r) in mutations {
                let pass = textbookAssertionsPass(y: z, rc: r, n: 2, m: 3)
                print("    mutation '\(label)': textbookProblem assertions \(pass ? "pass (missed)" : "FAIL (caught)")")
            }
        }
    }
}

// MARK: - Constructed instances, min and max, through the oracle (the duals the suite does not check there)

func runConstructed(count: Int) async throws {
    print("== constructed optima: \(count) instances x 2 methods, min and max, free columns, ranges, degenerate")
    var solved = 0
    var bad = 0
    var worstGap = 0.0
    var worstInfeasibility = 0.0
    var worstLogical = 0.0
    var worstRc = 0.0
    var maxCount = 0
    for seed in 0..<count {
        var options = ConstructedOptions()
        options.maximize = seed % 2 == 1
        options.freeColumns = seed % 3 == 0
        options.rangeRows = seed % 4 == 0
        options.degenerate = seed % 5 == 0
        let instance = InstanceGenerator.constructedOptimum(
            rows: 8 + seed % 30, columns: 12 + seed % 45, seed: UInt64(7_000 + seed), options: options)
        let lp = instance.lp
        if lp.sense == .maximize { maxCount += 1 }
        for method in [Simplex.Method.primal, .dual] {
            let analysis = try await Simplex(method).solve(lp, context: limited(30))
            guard analysis.status == .optimal, let x = analysis.primal, let y = analysis.dual,
                  let rc = analysis.reducedCosts, let objective = analysis.objectiveValue
            else { print("  seed \(seed) \(method): \(analysis.status)"); bad += 1; continue }
            solved += 1
            let flip: Double = lp.sense == .maximize ? -1 : 1
            let cert = certificate(lp, x: x, yMin: y.map { flip * $0 })
            var logical = 0.0
            for i in 0..<lp.m { logical = max(logical, abs(rc[lp.n + i] - y[i])) }
            let derived = reportedReducedCosts(lp, reportedDual: y)
            var rcDiff = 0.0
            for k in 0..<(lp.n + lp.m) { rcDiff = max(rcDiff, abs(derived[k] - rc[k])) }
            worstGap = max(worstGap, abs(cert.gap))
            worstInfeasibility = max(worstInfeasibility, cert.infeasibility)
            worstLogical = max(worstLogical, logical)
            worstRc = max(worstRc, rcDiff)
            let objectiveError = abs(objective - instance.objective) / max(1, abs(instance.objective))
            if abs(cert.gap) > 1e-7 || cert.infeasibility > 1e-7 || objectiveError > 1e-7 {
                bad += 1
                print("  seed \(seed) \(method) sense \(lp.sense): gap \(e(cert.gap)) dualInf \(e(cert.infeasibility)) objErr \(e(objectiveError))")
            }
        }
    }
    print("constructed: \(solved) optimal solves (\(maxCount) of \(count) instances are maximizations), \(bad) bad; worst |gap| \(e(worstGap)), worst dual infeasibility \(e(worstInfeasibility)), worst |rc_logical - dual| \(e(worstLogical)), worst |reported rc - flip*d(flip*y)| \(e(worstRc))")
}

// MARK: - Hilbert orders 3-8: the distance the README calls "about 1e-6"

func runHilbert() async throws {
    print("== Hilbert orders 3-8, worst distance from (1,...,1) over the four forms")
    let strategies: [(String, any SolverStrategy)] = [
        ("Simplex(.dual)", Simplex(.dual)), ("Simplex(.primal)", Simplex(.primal)), ("InteriorPoint()", InteriorPoint()),
    ]
    for order in 3...8 {
        var line = "  order \(order):"
        for (name, strategy) in strategies {
            var worst = 0.0
            var statuses: Set<String> = []
            for form in HilbertForm.allCases {
                let instance = InstanceGenerator.hilbert(order: order, form: form)
                let analysis = try await strategy.solve(instance.lp, context: limited(60))
                statuses.insert("\(analysis.status)")
                if let x = analysis.primal { for v in x { worst = max(worst, abs(v - 1)) } } else { worst = .infinity }
            }
            line += " \(name) \(e(worst)) [\(statuses.sorted().joined(separator: ","))]"
        }
        print(line)
    }
}

// MARK: - Aside: why |y - B^-T c_B| is large on beaconfd with presolve on

func runBasisAside(_ name: String) async throws {
    print("== aside: \(name), the basis returned with presolve on versus the duals returned")
    let lp = try NetlibFixtures.load(name)
    for (label, strategy) in configurations {
        let analysis = try await strategy.solve(lp, context: limited())
        guard let y = analysis.dual, let x = analysis.primal else { continue }
        let basic = analysis.basis.basic
        let structural = basic.filter { Int($0) < lp.n }.count
        guard let yb = basisDual(lp, basic: basic) else { print("  \(label): basis singular or wrong size \(basic.count)"); continue }
        let reported = certificate(lp, x: x, yMin: y)
        let fromBasis = certificate(lp, x: x, yMin: yb)
        var differing = 0
        for i in 0..<lp.m where abs(yb[i] - y[i]) > 1e-7 * (1 + abs(y[i])) { differing += 1 }
        var context = limited()
        context.warmStart = .basis(analysis.basis)
        let warm = try await Simplex(.dual, presolve: false, scaling: .none).solve(lp, context: context)
        print("  \(label): basic \(basic.count) (\(structural) structural); rows whose dual differs from B^-T c_B: \(differing); reported y gap \(e(reported.gap)) dualInf \(e(reported.infeasibility)); basis y gap \(e(fromBasis.gap)) dualInf \(e(fromBasis.infeasibility)); warm start of the unpresolved problem: \(warm.status) in \(warm.iterations) iterations")
    }
}

let started = Date()
switch mode {
case "aside": try await runBasisAside(args.count > 2 ? args[2] : "beaconfd")
case "netlib": try await runNetlib()
case "transport": try await runTransport()
case "textbook": try await runTextbook()
case "constructed": try await runConstructed(count: args.count > 2 ? Int(args[2]) ?? 200 : 200)
case "hilbert": try await runHilbert()
default:
    try await runTextbook()
    try await runTransport()
    try await runNetlib()
    try await runConstructed(count: 200)
    try await runHilbert()
}
print(String(format: "elapsed %.1f s", Date().timeIntervalSince(started)))
