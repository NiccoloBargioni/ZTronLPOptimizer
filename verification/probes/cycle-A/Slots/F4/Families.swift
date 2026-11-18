// Cycle A, slot F4: random instance families with an enumeration oracle.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum Family: String, CaseIterable {
    case binary, generalInt, mixed, equality
}

/// Rows built around a random point x0 of the domain, so most instances are feasible; a fraction
/// get random right-hand sides (often infeasible).
func randomRows(
    _ rng: inout SeededGenerator, m: Int, n: Int, x0: [Double], coef: (inout SeededGenerator, Int) -> Double,
    equalityShare: Double, randomRHS: Bool
) -> (rows: [[Double]], rl: [Double], ru: [Double]) {
    var rows: [[Double]] = []
    var rl: [Double] = []
    var ru: [Double] = []
    for _ in 0..<m {
        var row = [Double](repeating: 0, count: n)
        var any = false
        for j in 0..<n where rng.chance(0.6) {
            row[j] = coef(&rng, j)
            if row[j] != 0 { any = true }
        }
        if !any { row[rng.integer(in: 0...(n - 1))] = 1 + Double(rng.integer(in: 0...4)) }
        var act = 0.0
        for j in 0..<n { act += row[j] * x0[j] }
        if randomRHS { act += Double(rng.integer(in: -6...6)) + (rng.chance(0.3) ? 0.5 : 0) }
        let u = rng.uniform()
        if u < equalityShare {
            rl.append(act); ru.append(act)
        } else if u < equalityShare + (1 - equalityShare) * 0.4 {
            rl.append(-INF); ru.append(act + Double(rng.integer(in: 0...3)))
        } else if u < equalityShare + (1 - equalityShare) * 0.8 {
            rl.append(act - Double(rng.integer(in: 0...3))); ru.append(INF)
        } else {
            rl.append(act - Double(rng.integer(in: 0...2))); ru.append(act + Double(rng.integer(in: 0...2)))
        }
        rows.append(row)
    }
    return (rows, rl, ru)
}

func generate(_ family: Family, seed: UInt64) -> CompiledLP {
    var rng = SeededGenerator(seed: seed &* 7919 &+ UInt64(Family.allCases.firstIndex(of: family)!))
    let sense: ObjectiveSense = rng.chance(0.5) ? .minimize : .maximize
    let randomRHS = rng.chance(0.25)
    switch family {
    case .binary:
        let n = rng.integer(in: 6...11)
        let m = rng.integer(in: 2...5)
        let x0 = (0..<n).map { _ in Double(rng.integer(in: 0...1)) }
        let (rows, rl, ru) = randomRows(
            &rng, m: m, n: n, x0: x0, coef: { r, _ in Double(r.integer(in: -9...9)) }, equalityShare: 0.15,
            randomRHS: randomRHS)
        let c = (0..<n).map { _ in Double(rng.integer(in: -10...10)) }
        return makeLP(
            c: c, rows: rows, rl: rl, ru: ru, xl: [Double](repeating: 0, count: n),
            xu: [Double](repeating: 1, count: n), integer: Array(0..<n), sense: sense)
    case .generalInt:
        let n = rng.integer(in: 3...6)
        let m = rng.integer(in: 2...4)
        var xl: [Double] = []
        var xu: [Double] = []
        for _ in 0..<n {
            let l = rng.integer(in: -4...1)
            let u = l + rng.integer(in: 0...5)
            // Fractional bounds exercise the inward rounding of presolve.
            xl.append(Double(l) - (rng.chance(0.3) ? 0.4 : 0))
            xu.append(Double(u) + (rng.chance(0.3) ? 0.6 : 0))
        }
        let x0 = (0..<n).map { Double(rng.integer(in: Int(xl[$0].rounded(.up))...Int(xu[$0].rounded(.down)))) }
        let (rows, rl, ru) = randomRows(
            &rng, m: m, n: n, x0: x0, coef: { r, _ in Double(r.integer(in: -7...7)) }, equalityShare: 0.2,
            randomRHS: randomRHS)
        let c = (0..<n).map { _ in Double(rng.integer(in: -9...9)) }
        return makeLP(c: c, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu, integer: Array(0..<n), sense: sense)
    case .mixed:
        let ni = rng.integer(in: 2...5)
        let nc = rng.integer(in: 1...3)
        let n = ni + nc
        let m = rng.integer(in: 2...4)
        var xl: [Double] = []
        var xu: [Double] = []
        for j in 0..<n {
            if j < ni {
                let l = rng.integer(in: -3...0)
                xl.append(Double(l)); xu.append(Double(l + rng.integer(in: 1...4)))
            } else {
                let l = rng.uniform(in: -5...2)
                xl.append(l); xu.append(l + rng.uniform(in: 0.5...8))
            }
        }
        let x0 = (0..<n).map { j -> Double in
            j < ni ? Double(rng.integer(in: Int(xl[j])...Int(xu[j]))) : rng.uniform(in: xl[j]...xu[j])
        }
        let (rows, rl, ru) = randomRows(
            &rng, m: m, n: n, x0: x0,
            coef: { r, j in j < ni ? Double(r.integer(in: -6...6)) : (r.uniform(in: -5...5) * 100).rounded() / 100 },
            equalityShare: 0.1, randomRHS: randomRHS)
        // Non-integral costs on every column: objectiveStep is 0, so pruning uses the gap.
        let c = (0..<n).map { _ in (rng.uniform(in: -10...10) * 1000).rounded() / 1000 }
        // Integer columns first, then shuffle the column order so integer columns are not a prefix.
        var perm = Array(0..<n)
        perm.shuffle(using: &rng)
        let pc = perm.map { c[$0] }
        let prows = rows.map { row in perm.map { row[$0] } }
        let pxl = perm.map { xl[$0] }
        let pxu = perm.map { xu[$0] }
        let pint = (0..<n).filter { perm[$0] < ni }
        return makeLP(c: pc, rows: prows, rl: rl, ru: ru, xl: pxl, xu: pxu, integer: pint, sense: sense)
    case .equality:
        let n = rng.integer(in: 4...7)
        let m = rng.integer(in: 1...3)
        let xl = (0..<n).map { _ in Double(rng.integer(in: -2...0)) }
        let xu = (0..<n).map { xl[$0] + Double(rng.integer(in: 1...4)) }
        let x0 = (0..<n).map { Double(rng.integer(in: Int(xl[$0])...Int(xu[$0]))) }
        let (rows, rl, ru) = randomRows(
            &rng, m: m, n: n, x0: x0, coef: { r, _ in Double(r.integer(in: -5...5)) }, equalityShare: 1.0,
            randomRHS: randomRHS)
        let c = (0..<n).map { _ in Double(rng.integer(in: -8...8)) }
        return makeLP(c: c, rows: rows, rl: rl, ru: ru, xl: xl, xu: xu, integer: Array(0..<n), sense: sense)
    }
}

struct Verdict {
    var ok: Bool
    var note: String
    var subopt: Bool = false
    var badBound: Bool = false
}

/// Checks one run against the oracle. Values compared in the internal minimisation form.
func check(_ r: Run, _ lp: CompiledLP, _ ans: OracleAnswer?, gapRel: Double = 1e-4, gapAbs: Double = 1e-6) -> Verdict {
    let flip: Double = lp.sense == .maximize ? -1 : 1
    guard let ans else {
        switch r.status {
        case .infeasible: return Verdict(ok: true, note: "infeasible ok")
        case .infeasibleOrUnbounded: return Verdict(ok: true, note: "weak: infeasibleOrUnbounded on a bounded infeasible MILP")
        default: return Verdict(ok: false, note: "oracle infeasible, got \(r.status) obj \(fmt(r.objective))")
        }
    }
    guard r.status == .optimal else {
        return Verdict(ok: false, note: "oracle optimum \(fmt(flip * ans.internalValue)), got \(r.status) obj \(fmt(r.objective))")
    }
    guard let obj = r.objective, let x = r.primal else { return Verdict(ok: false, note: "optimal without objective/primal") }
    let inc = flip * obj
    let v = ans.internalValue
    var notes: [String] = []
    var ok = true
    let viol = lp.maxViolation(at: x)
    if viol.bounds > 1e-6 || viol.rows > 1e-6 { ok = false; notes.append("infeasible incumbent \(viol)") }
    for j in lp.integerColumns where abs(x[Int(j)] - x[Int(j)].rounded()) > 1e-6 { ok = false; notes.append("non-integral col \(j)") }
    let atX = lp.internalObjective(at: x)
    if abs(atX - inc) > 1e-6 * (1 + abs(inc)) { ok = false; notes.append("objective \(inc) != c.x \(atX)") }
    if inc < v - 1e-6 * (1 + abs(v)) { ok = false; notes.append("better than enumeration optimum \(v)?") }
    let s = max(gapAbs, gapRel * max(1, abs(inc)))
    var subopt = false
    if inc > v + s + 1e-9 * (1 + abs(v)) { ok = false; notes.append("outside gap: inc \(inc) opt \(v) slack \(s)") }
    else if inc > v + 1e-7 * (1 + abs(v)) { subopt = true; notes.append("suboptimal within gap by \(inc - v)") }
    var badBound = false
    if let b = r.bound {
        let bi = flip * b
        if bi > v + 1e-7 * (1 + abs(v)) { badBound = true; notes.append("bound \(bi) above optimum \(v) by \(bi - v)") }
        if inc - bi > s + 1e-9 * (1 + abs(inc)) { ok = false; notes.append("optimal but inc-bound \(inc - bi) > slack \(s)") }
    } else {
        notes.append("no bound")
    }
    return Verdict(ok: ok, note: notes.joined(separator: "; "), subopt: subopt, badBound: badBound)
}
