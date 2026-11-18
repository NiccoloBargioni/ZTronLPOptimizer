import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// A random small pure-integer model. kind: mixed | binary | decimal | eq | wide
func randomModel(_ rng: inout SeededGenerator, kind: String) -> CompiledLP {
    let n = kind == "binary" ? rng.integer(in: 3...10) : rng.integer(in: 2...5)
    var xl = [Double](), xu = [Double]()
    for _ in 0..<n {
        if kind == "binary" { xl.append(0); xu.append(1); continue }
        let lo = rng.integer(in: -4...2)
        let width = kind == "wide" ? rng.integer(in: 0...9) : rng.integer(in: 0...4)
        xl.append(Double(lo)); xu.append(Double(lo + width))
    }
    let m = rng.integer(in: 1...4)
    let scale: Double = kind == "decimal" ? [0.1, 0.01, 0.5, 0.25, 0.001][rng.integer(in: 0...4)] : 1
    var rows: [[(Int, Double)]] = []
    var rl = [Double](), ru = [Double]()
    for _ in 0..<m {
        var r: [(Int, Double)] = []
        for j in 0..<n where rng.chance(0.7) {
            let a = rng.integer(in: -6...6)
            if a != 0 { r.append((j, Double(a) * scale)) }
        }
        if r.isEmpty { r.append((rng.integer(in: 0...(n - 1)), Double(rng.integer(in: 1...3)) * scale)) }
        // activity range
        var amin = 0.0, amax = 0.0
        for (j, a) in r {
            amin += min(a * xl[j], a * xu[j]); amax += max(a * xl[j], a * xu[j])
        }
        let t = rng.integer(in: 0...4)
        func pick(_ u: Double, _ rng: inout SeededGenerator) -> Double {
            // a value in the activity range, on the scale's grid, occasionally off-grid
            let v = amin + (amax - amin) * u
            let g = (v / scale).rounded() * scale
            return rng.chance(0.15) ? g + scale * 0.5 : g
        }
        switch t {
        case 0: rl.append(-.infinity); ru.append(pick(rng.uniform(), &rng))
        case 1: rl.append(pick(rng.uniform(), &rng)); ru.append(.infinity)
        case 2: let v = pick(rng.uniform(), &rng); rl.append(v); ru.append(v)  // equality
        case 3:
            let a = pick(rng.uniform(), &rng), b = pick(rng.uniform(), &rng)
            rl.append(min(a, b)); ru.append(max(a, b))
        default: rl.append(-.infinity); ru.append(pick(rng.uniform() * 0.6, &rng))
        }
        rows.append(r)
    }
    var c = [Double]()
    for _ in 0..<n { c.append(Double(rng.integer(in: -9...9)) * (kind == "decimal" ? scale : 1)) }
    let c0 = rng.chance(0.3) ? Double(rng.integer(in: -20...20)) : 0
    let sense: ObjectiveSense = rng.chance(0.5) ? .maximize : .minimize
    return makeLP(n: n, rows: rows, rl: rl, ru: ru, c: c, c0: c0, sense: sense, xl: xl, xu: xu)
}

func runEnum(count: Int, seed: UInt64, cfg: String, kind: String) async {
    let strategy = config(cfg).strategy
    var rng = SeededGenerator(seed: seed)
    var feasibleModels = 0, infeasibleModels = 0, bad = 0, timeouts = 0, thrown = 0
    for k in 0..<count {
        let thisKind = kind == "all" ? ["mixed", "binary", "decimal", "eq", "wide"][k % 5] : kind
        let lp = randomModel(&rng, kind: thisKind)
        let truth = enumerate(lp)
        let a: CPSATAnalysis
        do { a = try await strategy.solve(lp, context: ctx(20)) } catch {
            print("k=\(k) kind=\(thisKind) THROW \(error)"); thrown += 1; continue
        }
        if truth.feasibleCount == 0 {
            infeasibleModels += 1
            if a.status != .infeasible {
                if case .noSolution = a.status { timeouts += 1; continue }
                print("k=\(k) kind=\(thisKind) expected infeasible, got \(statusString(a.status)) obj=\(String(describing: a.objectiveValue)) x=\(String(describing: a.primal))")
                bad += 1
            }
            continue
        }
        feasibleModels += 1
        let best = lp.reportedObjective(truth.bestInternal)
        guard a.status == .optimal, let obj = a.objectiveValue, let x = a.primal else {
            if case .noSolution = a.status { timeouts += 1; continue }
            print("k=\(k) kind=\(thisKind) expected optimal \(best), got \(statusString(a.status)) obj=\(String(describing: a.objectiveValue))")
            bad += 1; continue
        }
        let viol = pointViolation(lp, x)
        let objAtX = lp.objective(at: x)
        var problems: [String] = []
        if abs(obj - best) > 1e-9 * max(1, abs(best)) { problems.append("objective \(obj) != enumerated \(best)") }
        if viol > 1e-9 { problems.append("point violates by \(viol)") }
        if abs(objAtX - obj) > 1e-9 * max(1, abs(obj)) { problems.append("objective at point \(objAtX) != reported \(obj)") }
        if let b = a.bound, abs(b - obj) > 1e-9 * max(1, abs(obj)) { problems.append("bound \(b) != objective \(obj)") }
        if a.bound == nil { problems.append("bound nil") }
        if !problems.isEmpty {
            bad += 1
            print("k=\(k) kind=\(thisKind) n=\(lp.n) m=\(lp.m): " + problems.joined(separator: "; "))
        }
    }
    print("enum cfg=\(cfg) kind=\(kind) seed=\(seed) count=\(count): feasible=\(feasibleModels) infeasible=\(infeasibleModels) bad=\(bad) timeouts=\(timeouts) thrown=\(thrown)")
}
