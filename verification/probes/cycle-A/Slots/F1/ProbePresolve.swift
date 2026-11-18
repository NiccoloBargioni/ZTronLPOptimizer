// Presolve / postsolve / scaling probes: presolve on vs off, scaling modes, each engine;
// every result checked on the ORIGINAL problem with independent KKT, basis and ray checks.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

struct Config {
    let label: String
    let run: @Sendable (CompiledLP) async throws -> (any SolutionAnalysis, Basis?, [Double]?, [Double]?)
}

func configs() -> [Config] {
    var out: [Config] = []
    for presolve in [true, false] {
        for scaling in [ScalingMode.none, .equilibration, .geometricEquilibration] {
            for method in [Simplex.Method.primal, .dual] {
                let s = Simplex(method, presolve: presolve, scaling: scaling)
                out.append(Config(label: "S.\(method) pre=\(presolve) sc=\(scaling)") { lp in
                    let r = try await s.solve(lp, context: ctx())
                    return (r, r.basis, r.primalRay, r.dualRay)
                })
            }
            let ipm = InteriorPoint(presolve: presolve, scaling: scaling)
            out.append(Config(label: "IPM pre=\(presolve) sc=\(scaling)") { lp in
                let r = try await ipm.solve(lp, context: ctx())
                return (r, r.finalBasis, r.crossover?.primalRay, r.crossover?.dualRay)
            })
        }
    }
    return out
}

func probePresolve(seeds: Range<UInt64>, infeasible: Bool, verbose: Bool) async {
    let cfgs = configs()
    var failures = 0
    var tally: [String: Int] = [:]
    for seed in seeds {
        let m = 2 + Int(seed % 7)
        let n = 2 + Int((seed / 7) % 8)
        let lp = presolveRichLP(seed: seed, m: m, n: n, infeasibleVariant: infeasible)
        let pre = Presolve.run(lp.relaxed())
        var statuses: [String: [String]] = [:]
        var objectives: [(String, Double)] = []
        var lines: [String] = []
        for cfg in cfgs {
            do {
                let (r, basis, pray, dray) = try await cfg.run(lp)
                let key = statusKey(r.status)
                statuses[key, default: []].append(cfg.label)
                switch r.status {
                case .optimal:
                    guard let x = r.primal else { lines.append("\(cfg.label): optimal without primal"); continue }
                    let rep = kkt(lp, x: x, dualRep: r.dual, rcRep: r.reducedCosts, objective: r.objectiveValue)
                    if !rep.ok { lines.append("\(cfg.label): KKT \(rep.summary)") }
                    if let ov = r.objectiveValue { objectives.append((cfg.label, ov)) }
                    if let basis {
                        let bp = checkBasis(lp, basis, x: x, dualRep: r.dual, rcRep: r.reducedCosts)
                        if !bp.isEmpty {
                            let df = basisDualFeasibility(lp, basis)
                            lines.append("\(cfg.label): BASIS \(bp.prefix(3).joined(separator: "; ")) | basis duals \(df.y.map { "\($0)" } ?? "-") dual-infeasible: \(df.violations.prefix(3))")
                        }
                    } else if cfg.label.hasPrefix("S.") { lines.append("\(cfg.label): no basis") }
                case .unbounded:
                    if let pray {
                        if let why = checkPrimalRay(lp, pray) { lines.append("\(cfg.label): RAY \(why)") }
                    } else if cfg.label.hasPrefix("S.") { lines.append("\(cfg.label): unbounded without ray") }
                    if let x = r.primal {
                        let v = lp.maxViolation(at: x)
                        if max(v.bounds, v.rows) > 1e-6 { lines.append("\(cfg.label): unbounded with infeasible point \(v)") }
                    }
                case .infeasible:
                    if let dray {
                        if let why = checkFarkas(lp, dray) { lines.append("\(cfg.label): FARKAS \(why)") }
                    } else if cfg.label.hasPrefix("S.") { lines.append("\(cfg.label): infeasible without dual ray") }
                default: break
                }
            } catch {
                lines.append("\(cfg.label): threw \(error)")
                statuses["threw", default: []].append(cfg.label)
            }
        }
        if statuses.count > 1 {
            // infOrUnb from IPM is allowed alongside infeasible/unbounded (documented defect 7).
            let keys = Set(statuses.keys).subtracting(["infOrUnb"])
            if keys.count > 1 { lines.append("STATUS DISAGREEMENT \(statuses.mapValues { $0.count })") }
        }
        if let ref = objectives.first {
            for (label, v) in objectives where abs(v - ref.1) > 1e-6 * (1 + abs(ref.1)) {
                lines.append("OBJ DISAGREEMENT \(label)=\(v) vs \(ref.0)=\(ref.1)")
            }
        }
        if !infeasible, let key = statuses.keys.first, statuses.keys.contains("infeasible") {
            // x0 is feasible by construction in the non-infeasible variant
            lines.append("FALSE INFEASIBLE (x0 feasible by construction) from \(statuses["infeasible"]!) key=\(key)")
        }
        for k in statuses.keys { tally[k, default: 0] += 1 }
        if !lines.isEmpty {
            failures += 1
            print("seed \(seed) m=\(m) n=\(n) presolve=\(pre.outcome) removed \(pre.removedRows)r/\(pre.removedColumns)c")
            for l in lines.prefix(verbose ? 50 : 8) { print("   \(l)") }
        }
    }
    print("presolve probe seeds \(seeds) infeasibleVariant=\(infeasible): \(failures) seeds with problems; status tally \(tally)")
}

/// Pure-integer presolve check by enumeration: the integer optimum (and feasibility) of the
/// presolved problem plus its constant equals that of the original, in .full and .boundsOnly.
func probeIntegerPresolve(seeds: Range<UInt64>) {
    var failures = 0
    var checked = 0
    for seed in seeds {
        var g = SeededGenerator(seed: seed)
        let n = 2 + Int(seed % 3)
        let m = 1 + Int((seed / 3) % 3)
        var xl = [Double](), xu = [Double]()
        for _ in 0..<n {
            let a = Double(g.integer(in: -6...6)) / 2 + (g.chance(0.3) ? 0.3 : 0)
            let b = a + Double(g.integer(in: 0...8)) / 2 + (g.chance(0.3) ? 0.2 : 0)
            xl.append(a); xu.append(b)
        }
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
        for i in 0..<m {
            if g.chance(0.4) { let j = g.integer(in: 0...(n - 1)); rows[i][j] = Double(g.integer(in: 1...3)) * (g.chance(0.5) ? 1 : -1) * (g.chance(0.4) ? 0.1 : 1) }
            else { for j in 0..<n where g.chance(0.6) { rows[i][j] = Double(g.integer(in: -3...3)) } }
        }
        var rl = [Double](), ru = [Double]()
        for _ in 0..<m {
            let a = Double(g.integer(in: -8...8)) / 2 + (g.chance(0.3) ? 0.7 : 0)
            let t = g.integer(in: 0...3)
            switch t {
            case 0: rl.append(a); ru.append(a)
            case 1: rl.append(-inf); ru.append(a)
            case 2: rl.append(a); ru.append(inf)
            default: rl.append(a); ru.append(a + Double(g.integer(in: 0...6)) / 2)
            }
        }
        let c = (0..<n).map { _ in Double(g.integer(in: -4...4)) }
        let lp = buildLP(rows, rl: rl, ru: ru, c: c, xl: xl, xu: xu, c0: 1.5, integer: (0..<n).map { Int32($0) })
        func best(_ p: CompiledLP) -> Double? {
            // enumerate integer points in the (finite) box
            // same 1e-9 relative snapping as the package (a bound 2.2e-16 below an integer is that integer)
            let lo = p.xl.map { ($0 - 1e-9 * max(1, abs($0))).rounded(.up) }, hi = p.xu.map { ($0 + 1e-9 * max(1, abs($0))).rounded(.down) }
            if zip(lo, hi).contains(where: { $0 > $1 }) { return nil }
            if p.n == 0 {
                let ok = (0..<p.m).allSatisfy { p.rl[$0] <= 1e-9 && p.ru[$0] >= -1e-9 }
                return ok ? p.c0 : nil
            }
            var bestV: Double? = nil
            var x = lo
            let A = dense(p)
            while true {
                let s = activity(A, x)
                if (0..<p.m).allSatisfy({ s[$0] >= p.rl[$0] - 1e-9 * (1 + abs(p.rl[$0])) && s[$0] <= p.ru[$0] + 1e-9 * (1 + abs(p.ru[$0])) }) {
                    let v = p.internalObjective(at: x)
                    if bestV == nil || v < bestV! { bestV = v }
                }
                var k = 0
                while k < p.n { x[k] += 1; if x[k] <= hi[k] { break }; x[k] = lo[k]; k += 1 }
                if k == p.n { break }
            }
            return bestV
        }
        let truth = best(lp)
        for mode in [Presolve.Mode.full, .boundsOnly] {
            checked += 1
            let pre = Presolve.run(lp, mode: mode)
            var got: Double? = nil
            var tag = ""
            switch pre.outcome {
            case .infeasible(let why): got = nil; tag = "infeasible(\(why))"
            case .solved: got = pre.reduced.c0 + 0; tag = "solved"
                // the reduced problem is empty: objective is its constant (c0 accumulates removed columns)
                let x = pre.expandPrimal([])
                let v = lp.maxViolation(at: x)
                if max(v.bounds, v.rows) > 1e-9 || x.enumerated().contains(where: { $0.element.rounded() != $0.element }) { tag += " expandPrimal infeasible/nonintegral \(x)" ; got = .nan }
                else { got = lp.internalObjective(at: x) }
            case .reduced:
                tag = "reduced"
                if pre.reduced.integerColumns.count != pre.reduced.n { tag += " lost integrality" }
                got = best(pre.reduced)
            }
            let same: Bool
            switch (truth, got) {
            case (nil, nil): same = true
            case let (a?, b?): same = abs(a - b) <= 1e-9 * (1 + abs(a))
            default: same = false
            }
            if !same {
                failures += 1
                print("seed \(seed) mode \(mode): original optimum \(truth.map { String($0) } ?? "infeasible") presolved \(got.map { String($0) } ?? "infeasible") [\(tag)]")
                print("   xl=\(xl) xu=\(xu)\n   rows=\(rows) rl=\(rl) ru=\(ru) c=\(c)")
                print("   reduced xl=\(pre.reduced.xl) xu=\(pre.reduced.xu) rl=\(pre.reduced.rl) ru=\(pre.reduced.ru)")
            }
        }
    }
    print("integer presolve enumeration: \(checked) checks, \(failures) mismatches")
}

func probeDetail(seed: UInt64) async {
    let m = 2 + Int(seed % 7)
    let n = 2 + Int((seed / 7) % 8)
    let lp = presolveRichLP(seed: seed, m: m, n: n)
    print("m=\(m) n=\(n) sense=\(lp.sense) c(min form)=\(lp.c) c0=\(lp.c0)")
    print("A=\(dense(lp))")
    print("xl=\(lp.xl) xu=\(lp.xu)\nrl=\(lp.rl) ru=\(lp.ru) int=\(lp.integerColumns)")
    for pre in [true, false] {
        let r = try! await Simplex(.dual, presolve: pre).solve(lp, context: ctx())
        print("presolve=\(pre): \(r.status) obj=\(String(describing: r.objectiveValue))")
        print("  x=\(r.primal ?? []) y=\(r.dual ?? []) d=\(r.reducedCosts ?? [])")
        print("  basis status=\(r.basis.status) basic=\(r.basis.basic)")
        print("  basis check: \(checkBasis(lp, r.basis, x: r.primal ?? [], dualRep: r.dual, rcRep: r.reducedCosts))")
    }
}

/// Minimal repro: min x s.t. -4x >= 4 (x <= -1), x in [-1, 1]. Optimum x = -1 at its own lower bound, d = 1.
func probeBasisRepro() async {
    let lp = buildLP([[-4]], rl: [4], ru: [inf], c: [1], xl: [-1], xu: [1])
    for pre in [true, false] {
        let r = try! await Simplex(.dual, presolve: pre).solve(lp, context: ctx())
        let df = basisDualFeasibility(lp, r.basis)
        print("presolve=\(pre): \(r.status) obj=\(String(describing: r.objectiveValue)) x=\(r.primal ?? []) y=\(r.dual ?? []) d=\(r.reducedCosts ?? [])")
        print("   basis status=\(r.basis.status) basic=\(r.basis.basic); basis's own duals \(df.y ?? []) dual-infeasible \(df.violations)")
        print("   checkBasis: \(checkBasis(lp, r.basis, x: r.primal ?? [], dualRep: r.dual, rcRep: r.reducedCosts))")
        // warm start from this basis on the unpresolved problem
        var c = ctx(); c.warmStart = .basis(r.basis)
        let w = try! await Simplex(.primal, presolve: false).solve(lp, context: c)
        print("   warm start from it (primal, no presolve): \(w.status) iterations \(w.iterations)")
    }
    let pre = Presolve.run(lp)
    print("Presolve outcome \(pre.outcome); expandBasis(empty) = \(pre.expandBasis(Basis(status: [], basic: [])).status)")
}

func probeNetlib() async {
    for inst in ReferenceValues.netlib {
        guard let lp = try? NetlibFixtures.load(inst.name) else { print("cannot load \(inst.name)"); continue }
        var line = "\(inst.name) (\(lp.m)x\(lp.n)) ref \(inst.optimalObjective):"
        for (label, strategy) in [("S.primal", 0), ("S.dual", 1), ("IPM", 2)] {
            for pre in [true, false] {
                var status = "", obj: Double? = nil, kktOK = true
                if strategy < 2 {
                    let r = try! await Simplex(strategy == 0 ? .primal : .dual, presolve: pre).solve(lp, context: ctx(120))
                    status = statusKey(r.status); obj = r.objectiveValue
                    if let x = r.primal, case .optimal = r.status { kktOK = kkt(lp, x: x, dualRep: r.dual, rcRep: r.reducedCosts, objective: r.objectiveValue).dualityGap < 1e-6 }
                } else {
                    let r = try! await InteriorPoint(presolve: pre).solve(lp, context: ctx(120))
                    status = statusKey(r.status); obj = r.objectiveValue
                    if let x = r.primal, case .optimal = r.status { kktOK = kkt(lp, x: x, dualRep: r.dual, rcRep: r.reducedCosts, objective: r.objectiveValue).dualityGap < 1e-6 }
                }
                let rel = obj.map { abs($0 - inst.optimalObjective) / max(1, abs(inst.optimalObjective)) } ?? .infinity
                let mark = (status == "optimal" && rel <= ReferenceValues.relativeTolerance && kktOK) ? "ok" : "BAD(\(status) rel=\(fmt(rel)) kkt=\(kktOK))"
                line += " \(label)/pre=\(pre ? 1 : 0):\(mark)"
            }
        }
        print(line)
    }
}
