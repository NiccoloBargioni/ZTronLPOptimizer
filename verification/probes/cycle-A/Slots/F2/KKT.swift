import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C1/C2: KKT-constructed LPs through every configuration.
func runKKT(count: Int, seed0: UInt64, spread: Double, seriousOnly: Bool = false) async {
    let configs = configGrid()
    var failures: [String] = []
    var worst: [String: (obj: Double, primal: Double, dual: Double, gap: Double)] = [:]
    var solves = 0
    var statusTally: [String: Int] = [:]
    var remainsTally: [String] = []
    for k in 0..<count {
        let seed = seed0 + UInt64(k)
        var r = Rng(seed &* 7)
        let m = r.int(3, 25), n = r.int(3, 30)
        let inst = makKKTWrap(m: m, n: n, seed: seed, maximize: k % 3 == 1, degenerate: k % 2 == 0, spread: spread)
        for cfg in configs {
            solves += 1
            do {
                let an = try await cfg.s.solve(inst.lp, context: ctx())
                guard an.status == .optimal else {
                    if seriousOnly {
                        statusTally["\(an.status)", default: 0] += 1
                        if an.status == .infeasible || an.status == .unbounded {
                            let margin = an.dualRay.map { farkasMargin(inst.lp, $0) } ?? .nan
                            let ray = an.primalRay.map { rayCheck(inst.lp, $0) }
                            failures.append("FALSE-VERDICT \(inst.label) \(cfg.name): \(an.status) farkas margin \(margin) ray \(String(describing: ray)) warnings \(an.warnings)")
                        }
                        continue
                    }
                    failures.append("\(inst.label) \(cfg.name): status \(an.status)")
                    continue
                }
                let ch = checkOptimal(inst.lp, an, expected: inst.objective)
                for w in an.warnings where w.contains("remains that pivoting") {
                    let parts = w.components(separatedBy: "a violation of ")
                    if parts.count > 1, let v = Double(parts[1].components(separatedBy: " ")[0]), v > 1e-6 {
                        remainsTally.append("\(inst.label) \(cfg.name): engine-measured violation \(v), objErr \(fmt(ch.objectiveError)), final row/bound violation \(fmt(ch.primalViolation))")
                    }
                }
                let primalTol = 1e-6 * max(1, inst.x.map { abs($0) }.max() ?? 0)
                if seriousOnly {
                    if ch.objectiveError > 1e-6 || ch.primalViolation > 1e-6 * max(1, inst.lp.ru.filter { $0.isFinite }.map { abs($0) }.max() ?? 1, inst.x.map { abs($0) }.max() ?? 0) {
                        failures.append("SERIOUS \(inst.label) \(cfg.name): objErr \(fmt(ch.objectiveError)) primal \(fmt(ch.primalViolation)) obj \(an.objectiveValue ?? .nan) vs \(inst.objective) warnings \(an.warnings.count)")
                    }
                } else if ch.objectiveError > 1e-7 || ch.primalViolation > primalTol || ch.dualSignViolation > 1e-6
                    || ch.gap > 1e-7 || ch.logicalMismatch > 1e-9 || ch.reducedCostMismatch > 1e-6 || !ch.missing.isEmpty {
                    failures.append("\(inst.label) \(cfg.name): objErr \(fmt(ch.objectiveError)) primal \(fmt(ch.primalViolation)) dualSign \(fmt(ch.dualSignViolation)) gap \(fmt(ch.gap)) logical \(fmt(ch.logicalMismatch)) rc \(fmt(ch.reducedCostMismatch)) missing '\(ch.missing)' obj \(an.objectiveValue ?? .nan) vs \(inst.objective)")
                }
                let w = worst[cfg.name] ?? (0, 0, 0, 0)
                worst[cfg.name] = (max(w.obj, ch.objectiveError), max(w.primal, ch.primalViolation), max(w.dual, ch.dualSignViolation), max(w.gap, ch.gap.isFinite ? ch.gap : 1e300))
            } catch {
                failures.append("\(inst.label) \(cfg.name): threw \(error)")
            }
        }
    }
    print("solves \(solves), failures \(failures.count), non-optimal statuses \(statusTally)")
    print("optimal answers whose own warning reports a remaining violation > 1e-6: \(remainsTally.count)")
    for r in remainsTally.prefix(12) { print("REMAINS", r) }
    for f in failures.prefix(60) { print("FAIL", f) }
    var overall = (0.0, 0.0, 0.0, 0.0)
    for (_, w) in worst { overall = (max(overall.0, w.obj), max(overall.1, w.primal), max(overall.2, w.dual), max(overall.3, w.gap)) }
    print("worst over configs: objErr \(fmt(overall.0)) primalViol \(fmt(overall.1)) dualSign \(fmt(overall.2)) gap \(fmt(overall.3))")
}

func makKKTWrap(m: Int, n: Int, seed: UInt64, maximize: Bool, degenerate: Bool, spread: Double) -> KKTInstance {
    makeKKT(m: m, n: n, seed: seed, maximize: maximize, degenerate: degenerate, scaleSpread: spread)
}

/// C3: infeasible LPs built from a Farkas multiplier vector.
func makeInfeasible(seed: UInt64) -> (CompiledLP, String) {
    var r = Rng(seed)
    let m = r.int(2, 20), n = r.int(2, 25)
    var entries: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where r.chance(0.35) { entries.append((i, j, (r.u(-1, 1) * 100).rounded() / 100 + 0.001)) } }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    // Multipliers on a subset of rows.
    var mult = [Double](repeating: 0, count: m)
    for i in 0..<m where r.chance(0.5) { mult[i] = r.chance(0.5) ? r.u(0.2, 2) : -r.u(0.2, 2) }
    if mult.allSatisfy({ $0 == 0 }) { mult[0] = 1 }
    let z = a.multiplyTranspose(mult)
    var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: 0, count: n)
    var maxZX = 0.0
    for j in 0..<n {
        // bounded on the side the multiplier needs, free-ish on the other
        if z[j] > 1e-12 { xu[j] = r.u(0, 5); xl[j] = r.chance(0.5) ? -.infinity : xu[j] - r.u(0, 5); maxZX += z[j] * xu[j] }
        else if z[j] < -1e-12 { xl[j] = r.u(-5, 0); xu[j] = r.chance(0.5) ? .infinity : xl[j] + r.u(0, 5); maxZX += z[j] * xl[j] }
        else { xl[j] = r.chance(0.5) ? -.infinity : -r.u(0, 3); xu[j] = r.chance(0.5) ? .infinity : r.u(0, 3) }
    }
    // Row bounds: min over rows of mult·s must exceed maxZX by a margin.
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    let margin = r.u(0.01, 2)
    var weight = 0.0
    for i in 0..<m where mult[i] != 0 { weight += abs(mult[i]) }
    for i in 0..<m {
        if mult[i] > 0 {
            // rl_i such that Σ mult_i rl_i = maxZX + margin, split by weight
            rl[i] = (maxZX + margin) / weight * (1 / 1)   // per unit of |mult|
            rl[i] = rl[i]   // contribution mult_i * rl_i = |mult_i| * share
            ru[i] = r.chance(0.5) ? .infinity : rl[i] + r.u(0, 3)
        } else if mult[i] < 0 {
            ru[i] = -(maxZX + margin) / weight
            rl[i] = r.chance(0.5) ? -.infinity : ru[i] - r.u(0, 3)
        } else {
            rl[i] = r.chance(0.5) ? -.infinity : -r.u(0, 10)
            ru[i] = r.chance(0.5) ? .infinity : r.u(0, 10)
        }
    }
    // Σ mult_i * bound_i = Σ |mult_i| * (maxZX+margin)/weight = maxZX + margin. Certified.
    var c = [Double](repeating: 0, count: n)
    for j in 0..<n { c[j] = r.u(-1, 1) }
    let lp = CompiledLP(a: a, c: c, sense: r.chance(0.5) ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru)
    precondition(farkasMargin(lp, mult) > 0, "generator: own certificate fails")
    return (lp, "infeas seed\(seed) m\(m) n\(n)")
}

func runInfeasible(count: Int, seed0: UInt64) async {
    let configs = configGrid(full: false)
    var bad: [String] = []
    var solves = 0
    var minMargin = Double.infinity
    var statusCounts: [String: Int] = [:]
    for k in 0..<count {
        let (lp, label) = makeInfeasible(seed: seed0 + UInt64(k))
        for cfg in configs {
            solves += 1
            do {
                let an = try await cfg.s.solve(lp, context: ctx())
                statusCounts["\(an.status)", default: 0] += 1
                guard an.status == .infeasible else { bad.append("\(label) \(cfg.name): status \(an.status)"); continue }
                guard let ray = an.dualRay else { bad.append("\(label) \(cfg.name): no dual ray"); continue }
                let mg = farkasMargin(lp, ray)
                minMargin = min(minMargin, mg)
                if !(mg > 1e-9) { bad.append("\(label) \(cfg.name): ray margin \(mg)") }
                if an.objectiveValue != nil { bad.append("\(label) \(cfg.name): objective on infeasible \(an.objectiveValue!)") }
            } catch { bad.append("\(label) \(cfg.name): threw \(error)") }
        }
    }
    print("solves \(solves), bad \(bad.count), min normalised margin \(minMargin), statuses \(statusCounts)")
    for b in bad.prefix(50) { print("BAD", b) }
}

/// C4: unbounded LPs built from a feasible point and an improving recession direction.
func makeUnbounded(seed: UInt64) -> (CompiledLP, String) {
    var r = Rng(seed)
    let m = r.int(2, 20), n = r.int(2, 25)
    var entries: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where r.chance(0.35) { entries.append((i, j, (r.u(-1, 1) * 100).rounded() / 100 + 0.001)) } }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    var x0 = [Double](repeating: 0, count: n)
    var v = [Double](repeating: 0, count: n)
    for j in 0..<n {
        x0[j] = r.u(-3, 3)
        v[j] = r.chance(0.5) ? 0 : r.u(-1, 1)
    }
    if v.allSatisfy({ $0 == 0 }) { v[0] = 1 }
    var xl = [Double](repeating: 0, count: n), xu = [Double](repeating: 0, count: n)
    for j in 0..<n {
        if v[j] > 0 { xu[j] = .infinity; xl[j] = r.chance(0.6) ? x0[j] - r.u(0, 2) : -.infinity }
        else if v[j] < 0 { xl[j] = -.infinity; xu[j] = r.chance(0.6) ? x0[j] + r.u(0, 2) : .infinity }
        else { xl[j] = r.chance(0.7) ? x0[j] - r.u(0, 2) : -.infinity; xu[j] = r.chance(0.7) ? x0[j] + r.u(0, 2) : .infinity }
    }
    let s0 = a.multiply(x0), av = a.multiply(v)
    var rl = [Double](repeating: -.infinity, count: m), ru = [Double](repeating: .infinity, count: m)
    for i in 0..<m {
        if av[i] > 1e-12 { rl[i] = r.chance(0.7) ? s0[i] - r.u(0, 2) : -.infinity; ru[i] = .infinity }
        else if av[i] < -1e-12 { ru[i] = r.chance(0.7) ? s0[i] + r.u(0, 2) : .infinity; rl[i] = -.infinity }
        else { rl[i] = r.chance(0.6) ? s0[i] - r.u(0, 2) : -.infinity; ru[i] = r.chance(0.6) ? s0[i] + r.u(0, 2) : .infinity; if r.chance(0.2) { rl[i] = s0[i]; ru[i] = s0[i] } }
    }
    var c = (0..<n).map { _ in r.u(-1, 1) }
    var cv = 0.0, vv = 0.0
    for j in 0..<n { cv += c[j] * v[j]; vv += v[j] * v[j] }
    let target = -r.u(0.05, 1)
    for j in 0..<n { c[j] += (target - cv) / vv * v[j] }
    let lp = CompiledLP(a: a, c: c, sense: r.chance(0.5) ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru)
    let (slope, viol) = rayCheck(lp, v)
    precondition(slope < 0 && viol <= 1e-12, "generator: own ray fails \(slope) \(viol)")
    return (lp, "unbdd seed\(seed) m\(m) n\(n)")
}

func runUnbounded(count: Int, seed0: UInt64) async {
    let configs = configGrid(full: false)
    var bad: [String] = []
    var solves = 0
    var statusCounts: [String: Int] = [:]
    for k in 0..<count {
        let (lp, label) = makeUnbounded(seed: seed0 + UInt64(k))
        for cfg in configs {
            solves += 1
            do {
                let an = try await cfg.s.solve(lp, context: ctx())
                statusCounts["\(an.status)", default: 0] += 1
                guard an.status == .unbounded else { bad.append("\(label) \(cfg.name): status \(an.status)"); continue }
                guard let ray = an.primalRay else { bad.append("\(label) \(cfg.name): no primal ray"); continue }
                let (slope, viol) = rayCheck(lp, ray)
                if !(slope < -1e-9) || viol > 1e-7 { bad.append("\(label) \(cfg.name): ray slope \(slope) viol \(viol)") }
                if let x = an.primal {
                    let v = lp.maxViolation(at: x)
                    if max(v.bounds, v.rows) > 1e-6 { bad.append("\(label) \(cfg.name): primal point violates by \(max(v.bounds, v.rows))") }
                }
            } catch { bad.append("\(label) \(cfg.name): threw \(error)") }
        }
    }
    print("solves \(solves), bad \(bad.count), statuses \(statusCounts)")
    for b in bad.prefix(50) { print("BAD", b) }
}
