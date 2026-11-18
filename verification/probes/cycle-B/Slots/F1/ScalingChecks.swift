import Foundation
import ZTronLPOptimizer

/// Regenerates the LP of runScalingExtremes for seed `target` (same RNG stream, no solving).
func scalingLP(_ target: Int) -> CompiledLP {
    var g = RNG(77)
    for s in 0...target {
        let n = g.int(1, 4), m = g.int(1, 4)
        var e: [(row: Int, col: Int, value: Double)] = []
        let x0 = (0..<n).map { _ in Double(g.int(1, 5)) }
        var rl = [Double](), ru = [Double]()
        let colScale = (0..<n).map { _ in pow(10.0, Double(g.int(-120, 120))) }
        for i in 0..<m {
            let rs = pow(10.0, Double(g.int(-120, 120)))
            var act = 0.0
            for j in 0..<n where g.chance(0.8) {
                let v = Double(g.int(1, 9)) * rs * colScale[j] * (g.chance(0.5) ? 1 : -1)
                guard v.isFinite, v != 0, abs(v) > 1e-290, abs(v) < 1e290 else { continue }
                e.append((i, j, v)); act += v * x0[j] / colScale[j] * colScale[j]
            }
            rl.append(act - abs(act) * 0.1 - 1e-300); ru.append(act + abs(act) * 0.1 + 1e-300)
        }
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, e), c: (0..<n).map { _ in Double(g.int(-3, 3)) },
                            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 10, count: n), rl: rl, ru: ru)
        if s == target { return lp }
    }
    fatalError()
}

func subLP(_ lp: CompiledLP, rows keep: [Int]) -> CompiledLP {
    var e: [(row: Int, col: Int, value: Double)] = []
    let cols = denseColumns(lp)
    for (ni, i) in keep.enumerated() { for j in 0..<lp.n { for (r, v) in cols[j] where r == i { e.append((ni, j, v)) } } }
    return CompiledLP(a: SparseCSC.fromTriplets(rows: keep.count, cols: lp.n, e), c: lp.c, xl: lp.xl, xu: lp.xu,
                      rl: keep.map { lp.rl[$0] }, ru: keep.map { lp.ru[$0] })
}

func runScalingCase(_ seed: Int, probe: [Double]?) async {
    let lp = scalingLP(seed)
    print(describeLP(lp))
    for e in lpEngines {
        do {
            let r = try await e.run(lp, ctx(10))
            let x = r.primal ?? []
            let mv = x.count == lp.n ? "\(lp.maxViolation(at: x))" : "-"
            print("  \(e.name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(x) maxViolation=\(mv) warnings=\(r.warnings.count)")
            if e.name == "dual", let y = r.dual { print("    dual y=\(y) reducedCosts=\(r.reducedCosts ?? [])") }
        } catch { print("  \(e.name): threw \(error)") }
    }
    if let p = probe, p.count == lp.n {
        let obj = zip(lp.c, p).map { $0 * $1 }.reduce(lp.c0, +)
        let act = lp.rowActivity(p)
        print("  probe x=\(p): objective=\(obj) maxViolation=\(lp.maxViolation(at: p))")
        for i in 0..<lp.m { print("    row \(i): \(lp.rl[i]) <= \(act[i]) <= \(lp.ru[i])  ok=\(lp.rl[i] <= act[i] && act[i] <= lp.ru[i])") }
    }
    // minimization over row subsets: smallest subset where default Simplex differs from scaling .none and .equilibration
    var found: [([Int], Double, Double, Double)] = []
    for mask in 1..<(1 << lp.m) {
        let keep = (0..<lp.m).filter { mask & (1 << $0) != 0 }
        let sub = subLP(lp, rows: keep)
        let d = try? await Simplex(.dual).solve(sub, context: ctx(5))
        let q = try? await Simplex(.dual, scaling: .equilibration).solve(sub, context: ctx(5))
        let z = try? await Simplex(.dual, scaling: .none).solve(sub, context: ctx(5))
        let od = d?.objectiveValue ?? .nan, oq = q?.objectiveValue ?? .nan, oz = z?.objectiveValue ?? .nan
        if d?.status == .optimal, od - Swift.min(oq.isNaN ? od : oq, oz.isNaN ? od : oz) > 1e-6 { found.append((keep, od, oq, oz)) }
    }
    for f in found.sorted(by: { $0.0.count < $1.0.count }).prefix(6) {
        print("  rows \(f.0): default(geom)=\(f.1) equil=\(f.2) none=\(f.3)")
    }
}

/// One row: 10^-k x0 + x1 <= 1, 0 <= x <= 10, min -x0 - x1. True optimum -10 - (1 - 10^-k*10) = about -11.
func runScalingMinimal() async {
    for k in [4, 6, 8, 10, 12, 14, 16, 20, 24, 30, 40, 60] {
        let a = pow(10.0, Double(-k))
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, a), (0, 1, 1.0)]), c: [-1, -1],
                            xl: [0, 0], xu: [10, 10], rl: [-.infinity], ru: [1])
        let truth = -10 - (1 - 10 * a)
        var line = "k=\(k) truth=\(truth):"
        for e in lpEngines where ["dual", "dual-noscale", "dual-equil", "primal", "ipm", "auto"].contains(e.name) {
            if let r = try? await e.run(lp, ctx(5)) {
                let o = r.objectiveValue ?? .nan
                let bad = r.status == .optimal && abs(o - truth) > 1e-6 * Swift.max(1, abs(truth))
                line += " \(e.name)=\(statusName(r.status)) \(o)\(bad ? " WRONG x=\(r.primal ?? []) w=\(r.warnings.count)" : "")"
            }
        }
        print(line)
    }
}

func runScalingMinimalDetail(_ k: Int) async {
    let a = pow(10.0, Double(-k))
    let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, a), (0, 1, 1.0)]), c: [-1, -1],
                        xl: [0, 0], xu: [10, 10], rl: [-.infinity], ru: [1])
    let f = Scaler.factors(for: lp, mode: .geometricEquilibration)
    let s = Scaler.scale(lp, mode: .geometricEquilibration)
    print("k=\(k) factors rows=\(f.rows) columns=\(f.columns); scaled c=\(s.c) xu=\(s.xu) a=\(s.a.values) ru=\(s.ru)")
    for e in lpEngines where ["dual", "primal", "auto", "dual-noscale"].contains(e.name) {
        let r = try! await e.run(lp, ctx(5))
        print("  \(e.name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(r.primal ?? []) y=\(r.dual ?? []) d=\(r.reducedCosts ?? []) warnings=\(r.warnings)")
    }
    let p = [10.0, 0.5]
    print("  point \(p): objective \(zip(lp.c, p).map { $0 * $1 }.reduce(0, +)) maxViolation \(lp.maxViolation(at: p))")
}
