// Cycle B, finder F1 probe. Usage: F1 <mode> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"
func arg(_ i: Int, _ d: Int) -> Int { args.count > i ? Int(args[i]) ?? d : d }

struct EngineConfig {
    let name: String
    let run: (CompiledLP, SolveContext) async throws -> (any SolutionAnalysis)
}

let lpEngines: [EngineConfig] = [
    EngineConfig(name: "dual") { try await Simplex(.dual).solve($0, context: $1) },
    EngineConfig(name: "dual-nopre") { try await Simplex(.dual, presolve: false).solve($0, context: $1) },
    EngineConfig(name: "dual-noscale") { try await Simplex(.dual, scaling: .none).solve($0, context: $1) },
    EngineConfig(name: "dual-equil") { try await Simplex(.dual, scaling: .equilibration).solve($0, context: $1) },
    EngineConfig(name: "dual-raw") { try await Simplex(.dual, presolve: false, scaling: .none).solve($0, context: $1) },
    EngineConfig(name: "primal") { try await Simplex(.primal).solve($0, context: $1) },
    EngineConfig(name: "primal-nopre") { try await Simplex(.primal, presolve: false).solve($0, context: $1) },
    EngineConfig(name: "ipm") { try await InteriorPoint().solve($0, context: $1) },
    EngineConfig(name: "ipm-nopre") { try await InteriorPoint(presolve: false).solve($0, context: $1) },
    EngineConfig(name: "ipm-noscale") { try await InteriorPoint(scaling: .none).solve($0, context: $1) },
    EngineConfig(name: "auto") { try await Automatic().solve($0, context: $1) },
]

func runLPDiff(from: Int, count: Int, bounded: Bool, integerData: Bool, verbose: Bool) async {
    var failures = 0
    var statusCounts: [String: Int] = [:]
    for s in from..<(from + count) {
        let seed = UInt64(s)
        var o = GenOptions()
        o.boundedOnly = bounded
        o.integerData = integerData
        let (lp, x0) = randomLP(seed: seed, o)
        // sanity: x0 feasible in my own oracle
        let pre = kkt(lp, x: x0, y: nil, d: nil)
        if !pre.isEmpty { print("GENERATOR BUG seed \(seed): \(pre)"); continue }
        var objectives: [(String, Double)] = []
        var statuses: [(String, String)] = []
        for e in lpEngines {
            let a: any SolutionAnalysis
            do { a = try await e.run(lp, ctx(20)) } catch {
                print("seed \(seed) \(e.name): THROW \(error)"); failures += 1; continue
            }
            let st = statusName(a.status)
            statuses.append((e.name, st))
            statusCounts[st, default: 0] += 1
            switch a.status {
            case .optimal:
                guard let x = a.primal else { print("seed \(seed) \(e.name): optimal without primal"); failures += 1; continue }
                var v = kkt(lp, x: x, y: a.dual, d: a.reducedCosts, objective: a.objectiveValue)
                if a.dual == nil || a.reducedCosts == nil { v.append("no dual/reducedCosts on an LP optimum") }
                if let ov = a.objectiveValue { objectives.append((e.name, ov)) } else { v.append("no objectiveValue") }
                if let b = a.bound, let ov = a.objectiveValue, Swift.abs(b - ov) > 1e-6 * (1 + Swift.abs(ov)) { v.append("bound \(b) != objective \(ov)") }
                if !v.isEmpty {
                    failures += 1
                    print("seed \(seed) \(e.name): KKT FAIL \(v.prefix(4))")
                    if verbose { print(describeLP(lp)); print(" x=\(x)\n y=\(a.dual ?? [])\n d=\(a.reducedCosts ?? [])") }
                }
            case .infeasible:
                failures += 1
                print("seed \(seed) \(e.name): FALSE INFEASIBLE (x0 is feasible)")
                if verbose { print(describeLP(lp)) }
            case .unbounded:
                if bounded {
                    failures += 1
                    print("seed \(seed) \(e.name): FALSE UNBOUNDED (all columns bounded)")
                } else if let sa = a as? SimplexAnalysis, let ray = sa.primalRay {
                    let (ok, why) = primalRayValid(lp, ray: ray)
                    if !ok { failures += 1; print("seed \(seed) \(e.name): unbounded with invalid ray: \(why)") }
                    objectives.append((e.name, lp.sense == .maximize ? .infinity : -.infinity))
                } else {
                    objectives.append((e.name, lp.sense == .maximize ? .infinity : -.infinity))
                }
            case .infeasibleOrUnbounded:
                if bounded { failures += 1; print("seed \(seed) \(e.name): infeasibleOrUnbounded on a feasible bounded LP") }
                else { objectives.append((e.name, lp.sense == .maximize ? .infinity : -.infinity)) }
            default:
                failures += 1
                print("seed \(seed) \(e.name): status \(st)")
            }
        }
        // differential: every engine must agree on the optimum (or unboundedness)
        if let first = objectives.first {
            for (name, v) in objectives.dropFirst() {
                let same = (v.isInfinite && first.1.isInfinite && v == first.1) || Swift.abs(v - first.1) <= 1e-6 * (1 + Swift.abs(first.1))
                if !same { failures += 1; print("seed \(seed): objective \(first.0)=\(first.1) vs \(name)=\(v)") }
            }
        }
    }
    print("lpdiff done seeds \(from)..<\(from + count) bounded=\(bounded) int=\(integerData) failures=\(failures) statuses=\(statusCounts)")
}

func makeInfeasible(seed: UInt64) -> (CompiledLP, String) {
    var g = RNG(seed &+ 777)
    var o = GenOptions()
    o.boundedOnly = g.chance(0.5)
    let (base, x0) = randomLP(seed: seed, o)
    let n = base.n, m = base.m
    var entries: [(row: Int, col: Int, value: Double)] = []
    for j in 0..<n { for p in base.a.colStart[j]..<base.a.colStart[j + 1] { entries.append((Int(base.a.rowIndex[p]), j, base.a.values[p])) } }
    var rl = base.rl, ru = base.ru
    var xl = base.xl, xu = base.xu
    let kind = g.int(0, 4)
    var why = ""
    switch kind {
    case 0: // empty row excluding zero
        rl.append(1); ru.append(.infinity); why = "empty row 0 >= 1"
    case 1: // two contradicting copies of a random row
        var row: [(Int, Double)] = []
        for j in 0..<n where g.chance(0.7) { row.append((j, Double(g.int(1, 4)) * (g.chance(0.5) ? 1 : -1))) }
        if row.isEmpty { row = [(0, 1)] }
        let act = row.reduce(0.0) { $0 + $1.1 * x0[$1.0] }
        for (j, a) in row { entries.append((m, j, a)); entries.append((m + 1, j, a)) }
        rl.append(-.infinity); ru.append(act); rl.append(act + 1); ru.append(.infinity); why = "a x <= b and a x >= b+1"
    case 2: // crossed singleton rows on one column
        let j = g.int(0, n - 1)
        entries.append((m, j, 2)); entries.append((m + 1, j, -3))
        rl.append(2 * 5); ru.append(.infinity)          // 2x >= 10 -> x >= 5
        rl.append(-.infinity); ru.append(-3 * 6)         // -3x <= -18 -> x >= 6 ... make it x <= 4 instead
        ru[ru.count - 1] = .infinity; rl[rl.count - 1] = -3 * 4  // -3x >= -12 -> x <= 4
        why = "singletons x>=5 and x<=4 on col \(j)"
    case 3: // fixed column makes a row infeasible
        let j = g.int(0, n - 1)
        xl[j] = 2; xu[j] = 2
        entries.append((m, j, 1))
        for k in 0..<n where k != j && g.chance(0.3) { entries.append((m, k, 0)) }
        rl.append(3); ru.append(3); why = "fixed col \(j)=2 in row x=3"
    default: // bounds crossing beyond tolerance via singleton equality
        let j = g.int(0, n - 1)
        xl[j] = 0; xu[j] = 1
        entries.append((m, j, 1)); rl.append(1.5); ru.append(1.5); why = "x in [0,1] and x = 1.5"
    }
    let a = SparseCSC.fromTriplets(rows: rl.count, cols: n, entries)
    let lp = CompiledLP(a: a, c: base.c, c0: base.c0, sense: base.sense, xl: xl, xu: xu, rl: rl, ru: ru)
    return (lp, why)
}

func runInfeasible(from: Int, count: Int) async {
    var failures = 0
    var counts: [String: Int] = [:]
    for s in from..<(from + count) {
        let (lp, why) = makeInfeasible(seed: UInt64(s))
        for e in lpEngines {
            let a: any SolutionAnalysis
            do { a = try await e.run(lp, ctx(20)) } catch { print("seed \(s) \(e.name): THROW \(error)"); failures += 1; continue }
            let st = statusName(a.status)
            counts[st, default: 0] += 1
            switch a.status {
            case .infeasible:
                if let sa = a as? SimplexAnalysis {
                    if let ray = sa.dualRay {
                        let (ok, detail) = farkasValid(lp, ray: ray)
                        if !ok { failures += 1; print("seed \(s) \(e.name) [\(why)]: infeasible with INVALID Farkas ray: \(detail)") }
                    } else { failures += 1; print("seed \(s) \(e.name) [\(why)]: infeasible without a dual ray") }
                }
            case .infeasibleOrUnbounded: break
            default:
                failures += 1
                print("seed \(s) \(e.name) [\(why)]: status \(st) on an infeasible LP")
            }
        }
    }
    print("infeas done failures=\(failures) statuses=\(counts)")
}

func randomIP(seed: UInt64) -> CompiledLP {
    var g = RNG(seed &+ 4242)
    let n = g.int(1, 5)
    let m = g.int(0, 4)
    var xl = [Double](), xu = [Double]()
    for _ in 0..<n {
        // fractional bounds on purpose (rule 6), small boxes for brute force
        let lo = Double(g.int(-3, 2)) + (g.chance(0.4) ? Double(g.int(1, 9)) / 10 : 0)
        let hi = lo + Double(g.int(0, 4)) + (g.chance(0.4) ? Double(g.int(1, 9)) / 10 : 0)
        xl.append(lo); xu.append(hi)
    }
    var entries: [(row: Int, col: Int, value: Double)] = []
    var rl = [Double](), ru = [Double]()
    for i in 0..<m {
        var act = 0.0
        let singleton = g.chance(0.3)
        for j in 0..<n where singleton ? (j == 0) : g.chance(0.6) {
            let a = Double(g.int(-4, 4))
            if a == 0 { continue }
            entries.append((i, j, a))
            act += a * Double(g.int(-1, 2))
        }
        let t = g.int(0, 3)
        let off = Double(g.int(0, 3)) + (g.chance(0.5) ? 0.5 : 0)
        switch t {
        case 0: rl.append(-.infinity); ru.append(act + off)
        case 1: rl.append(act - off); ru.append(.infinity)
        case 2: rl.append(act - off); ru.append(act + off)
        default: rl.append(act); ru.append(act)
        }
    }
    var c = [Double]()
    for _ in 0..<n { c.append(Double(g.int(-5, 5))) }
    let maximize = g.chance(0.5)
    let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
    return CompiledLP(a: a, c: maximize ? c.map { $0 == 0 ? 0 : -$0 } : c, c0: Double(g.int(-2, 2)),
                      sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru,
                      integerColumns: (0..<n).map { Int32($0) })
}

let ipEngines: [EngineConfig] = [
    EngineConfig(name: "bnb") { try await BranchAndBound().solve($0, context: $1) },
    EngineConfig(name: "bnb-det") { try await BranchAndBound(deterministic: true).solve($0, context: $1) },
    EngineConfig(name: "bnb-dual") { try await BranchAndBound(engine: Simplex(.dual)).solve($0, context: $1) },
    EngineConfig(name: "bnb-ipm") { try await BranchAndBound(engine: InteriorPoint()).solve($0, context: $1) },
    EngineConfig(name: "cpsat") { try await CPSAT(workers: 2).solve($0, context: $1) },
    EngineConfig(name: "cpsat-det") { try await CPSAT(workers: 1, deterministic: true).solve($0, context: $1) },
    EngineConfig(name: "auto") { try await Automatic().solve($0, context: $1) },
]

func checkIP(_ lp: CompiledLP, label: String, engines: [EngineConfig] = ipEngines) async -> Int {
    var failures = 0
    let truth = bruteForceIP(lp)
    if truth.status == "too-big" { return 0 }
    for e in engines {
        let a: any SolutionAnalysis
        do { a = try await e.run(lp, ctx(20)) } catch {
            if case SolverError.unsupported = error { continue }
            print("\(label) \(e.name): THROW \(error)"); failures += 1; continue
        }
        switch (truth.status, a.status) {
        case ("infeasible", .infeasible): break
        case ("optimal", .optimal):
            guard let x = a.primal, let ov = a.objectiveValue else { failures += 1; print("\(label) \(e.name): optimal without values"); continue }
            var v = kkt(lp, x: x, y: nil, d: nil, tol: 1e-6, objective: ov)
            for j in lp.integerColumns.map({ Int($0) }) where Swift.abs(x[j] - x[j].rounded()) > 1e-6 { v.append("x[\(j)]=\(x[j]) fractional") }
            if Swift.abs(ov - truth.best!) > 1e-6 * (1 + Swift.abs(truth.best!)) { v.append("objective \(ov) != brute force \(truth.best!)") }
            if !v.isEmpty { failures += 1; print("\(label) \(e.name): WRONG \(v.prefix(4)) x=\(x) truth x=\(truth.x!)") }
        default:
            failures += 1
            print("\(label) \(e.name): status \(statusName(a.status)) but brute force says \(truth.status) \(truth.best.map { "\($0)" } ?? "")")
        }
    }
    return failures
}

func runIP(from: Int, count: Int) async {
    var failures = 0
    for s in from..<(from + count) {
        let lp = randomIP(seed: UInt64(s))
        let f = await checkIP(lp, label: "seed \(s)")
        if f > 0 { print(describeLP(lp)) }
        failures += f
    }
    print("ip done seeds \(from)..<\(from + count) failures=\(failures)")
}

func runBigInt() async {
    for mag in [1e6, 1e7, 1e8, 1e9, 1e10, 1e12, 1e14] {
        for (label, lo, hi, maximize, expect) in [
            ("min x, x>=M+0.5", mag + 0.5, mag + 10, false, mag + 1),
            ("max x, x<=M+0.5", mag - 10, mag + 0.5, true, mag),
            ("min x, x>=M+0.25", mag + 0.25, mag + 10, false, mag + 1),
        ] {
            let a = SparseCSC.fromTriplets(rows: 0, cols: 1, [])
            let lp = CompiledLP(a: a, c: [maximize ? -1 : 1], sense: maximize ? .maximize : .minimize,
                                xl: [lo], xu: [hi], rl: [], ru: [], integerColumns: [0])
            var line = "M=\(mag) \(label) expect \(expect):"
            for e in ipEngines {
                do {
                    let r = try await e.run(lp, ctx(10))
                    let x = r.primal?.first
                    let flag = (r.status == .optimal && x != nil && Swift.abs(x! - expect) > 1e-6) ? " <-- WRONG (bound violated by \(maximize ? x! - hi : lo - x!))" : ""
                    line += "\n   \(e.name): \(statusName(r.status)) x=\(x.map { String(format: "%.3f", $0) } ?? "nil")\(flag)"
                } catch { line += "\n   \(e.name): throws \(error)" }
            }
            print(line)
        }
    }
    // presolve rounding directly
    for mag in [1e8, 1e9, 1e12] {
        let a = SparseCSC.fromTriplets(rows: 0, cols: 1, [])
        let lp = CompiledLP(a: a, c: [1], xl: [mag + 0.5], xu: [mag + 10], rl: [], ru: [], integerColumns: [0])
        let pre = Presolve.run(lp, mode: .boundsOnly)
        print("Presolve.run boundsOnly M=\(mag): xl \(lp.xl[0]) -> \(pre.reduced.xl[0]) (correct ceil: \((lp.xl[0]).rounded(.up)))")
    }
}

enum Sched: LPVariable {
    case start, finish
    var domain: VariableDomain {
        switch self {
        case .start: return .integer(.atLeast(1_700_000_000))   // epoch seconds, integral bound
        case .finish: return .continuous(.free)
        }
    }
}

func runBigInt2() async {
    for X in [999_999_999.0, 1e9, 1.7e9, 2e9, 1e10] {
        for maximize in [false, true] {
            let a = SparseCSC.fromTriplets(rows: 0, cols: 1, [])
            let lp = CompiledLP(a: a, c: [maximize ? -1 : 1], sense: maximize ? .maximize : .minimize,
                                xl: maximize ? [X - 100] : [X], xu: maximize ? [X] : [X + 100], rl: [], ru: [], integerColumns: [0])
            var line = "integral bounds \(maximize ? "max x, x<=X" : "min x, x>=X") X=\(X):"
            for e in ipEngines where e.name == "bnb" || e.name == "auto" {
                let r = try! await e.run(lp, ctx(10))
                let x = r.primal?.first ?? .nan
                line += " \(e.name)=\(statusName(r.status)) x=\(String(format: "%.1f", x)) (violation \(String(format: "%.1f", maximize ? x - X : X - x)))"
            }
            print(line)
        }
    }
    // DSL: integer start >= 1.7e9 (epoch seconds), finish >= start + 3600, minimize finish
    let model = LPModel<Sched>()
        .minimizing(Sched.finish)
        .subjectTo { Sched.finish >= Sched.start + 3600 }
    for (name, solve) in [("Automatic", { try await Automatic().solve(model, context: ctx(10)) as Solution<Sched, AnySolutionAnalysis> })] {
        let sol = try! await solve()
        print("DSL \(name): status=\(statusName(sol.status)) start=\(sol.value(of: .start)) finish=\(sol.value(of: .finish)) objective=\(sol.objectiveValue ?? .nan) (expected start=1700000000, finish=1700003600)")
        let viol = sol.compiled.lp.maxViolation(at: sol.analysis.primal!)
        print("   CompiledLP.maxViolation at the reported point: bounds=\(viol.bounds) rows=\(viol.rows)")
    }
    let bnb = try! await BranchAndBound().solve(model, context: ctx(10))
    print("DSL BranchAndBound: status=\(statusName(bnb.status)) start=\(bnb.value(of: .start)) finish=\(bnb.value(of: .finish))")
    // the same model with the bound as a constraint row, read through MPS
    let mps = try! model.mpsString()
    let read = try! MPSFormat.read(mps)
    let r = try! await BranchAndBound().solve(read, context: ctx(10))
    print("MPS round trip + BranchAndBound: \(statusName(r.status)) x=\(r.primal ?? [])")
}

func showLPCase(_ seed: Int) async throws {
    let lp = randomNamedLP(seed: UInt64(seed), freeRows: false)
    print(describeLP(lp))
    let w = try LPFormat.write(lp)
    print(w)
    let back = try LPFormat.read(w)
    print(describeLP(back))
    for (name, p) in [("orig", lp.relaxed()), ("back", back.relaxed())] {
        for e in lpEngines.prefix(5) {
            let r = try await e.run(p, ctx(5))
            print("\(name) \(e.name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(r.primal ?? [])")
        }
    }
}

func exactR(_ anchor: Double, _ other: Double, plus: Bool, window: Int) -> Double? {
    let cand = abs(other - anchor)
    if (plus ? anchor + cand : anchor - cand) == other { return cand }
    var up = cand, dn = cand
    for _ in 0..<window {
        up = up.nextUp; dn = dn.nextDown
        if (plus ? anchor + up : anchor - up) == other { return up }
        if dn > 0 && (plus ? anchor + dn : anchor - dn) == other { return dn }
    }
    return nil
}

func runRangeRT(count: Int) {
    var fails = 0, impossible = 0
    var shown = 0
    var g = RNG(2024)
    for _ in 0..<count {
        let lo = [-8.0, 1.0 / 3.0, -1.2101750581751705, 2.333333333333333, 0.1, -0.7][g.int(0, 5)] * Double(g.int(1, 9))
        let hi = lo + [1e-3, 0.1, 1.0 / 3.0, 7.7, 123.456, 1e6 + 0.3][g.int(0, 5)] * (g.unit() + 0.5)
        let a = SparseCSC.fromTriplets(rows: 1, cols: 1, [(0, 0, 1.0)])
        let lp = CompiledLP(a: a, c: [1], xl: [0], xu: [10], rl: [lo], ru: [hi], names: LPNames(columns: ["x"], rows: ["r"]))
        let back = try! MPSFormat.read(MPSFormat.write(lp))
        if back.rl != lp.rl || back.ru != lp.ru {
            fails += 1
            let wide = exactR(lo, hi, plus: true, window: 100_000) ?? exactR(hi, lo, plus: false, window: 100_000)
            if wide == nil { impossible += 1 }
            if shown < 5 { shown += 1; print("range [\(lo), \(hi)] read back as [\(back.rl[0]), \(back.ru[0])]; exact R within 1e5 ulps exists: \(wide != nil)") }
        }
    }
    print("rangert: \(fails)/\(count) ranges do not read back bit-for-bit; for \(impossible) of them no R within 1e5 ulps reproduces the pair with either anchor")
}

func runCrossed() async {
    // rows with rl > ru (the LP reader produces them from `5 <= x + y <= 3`), and columns with xl > xu
    let a2 = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1.0), (0, 1, 1.0)])
    let cases: [(String, CompiledLP)] = [
        ("row 5 <= x+y <= 3, min x", CompiledLP(a: a2, c: [1, 0], xl: [0, 0], xu: [.infinity, .infinity], rl: [5], ru: [3])),
        ("row 5 <= x+y <= 3, max x+y, box [0,10]", CompiledLP(a: a2, c: [-1, -1], sense: .maximize, xl: [0, 0], xu: [10, 10], rl: [5], ru: [3])),
        ("row 3.001 <= x+y <= 3, min x", CompiledLP(a: a2, c: [1, 0], xl: [0, 0], xu: [10, 10], rl: [3.001], ru: [3])),
        ("row 5 <= x+y <= 3, integer x,y in [0,10]", CompiledLP(a: a2, c: [1, 1], xl: [0, 0], xu: [10, 10], rl: [5], ru: [3], integerColumns: [0, 1])),
        ("column xl=5 > xu=3 in a row x+y>=1", CompiledLP(a: a2, c: [1, 1], xl: [5, 0], xu: [3, 10], rl: [1], ru: [.infinity])),
    ]
    var engines = lpEngines
    engines.append(EngineConfig(name: "bnb") { try await BranchAndBound().solve($0, context: $1) })
    engines.append(EngineConfig(name: "cpsat") { try await CPSAT(workers: 1).solve($0, context: $1) })
    for (label, lp) in cases {
        print("[\(label)]")
        for e in engines {
            do {
                let r = try await e.run(lp, ctx(5))
                var s = "   \(e.name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(r.primal ?? [])"
                if r.status.hasSolution, let x = r.primal { s += " maxViolation=\(lp.maxViolation(at: x))" + (r.status == .optimal ? "  <-- OPTIMAL ON AN INFEASIBLE MODEL" : "") }
                print(s)
            } catch { print("   \(e.name): throws \(error)") }
        }
    }
    // the same through the LP reader
    let text = "Minimize\n obj: x\nSubject To\n c1: 5 <= x + y <= 3\nEnd\n"
    let lp = try! LPFormat.read(text)
    let r = try! await Automatic().solve(lp, context: ctx(5))
    print("LPFormat.read(\"c1: 5 <= x + y <= 3\") -> rl=\(lp.rl) ru=\(lp.ru); Automatic: \(statusName(r.status)) x=\(r.primal ?? []) maxViolation=\(lp.maxViolation(at: r.primal ?? [0, 0]))")
}

switch mode {
case "lpnames":
    try await runLPNames()
case "scalmin1":
    await runScalingMinimalDetail(arg(2, 20))
case "scalmin":
    await runScalingMinimal()
case "scalcase":
    let probe: [Double]? = args.count > 3 ? args[3].split(separator: ",").map { Double($0)! } : nil
    await runScalingCase(arg(2, 6), probe: probe)
case "scalext":
    await runScalingExtremes(only: args.count > 2 ? Int(args[2]) : nil)
case "dsl2":
    await runDSL2()
case "basis":
    await runBasis(from: arg(2, 0), count: arg(3, 200))
case "crossed":
    await runCrossed()
case "malformed":
    await runMalformed()
case "fuzz":
    await runFuzz(format: args[2], from: arg(3, 0), count: arg(4, 1000), solve: arg(5, 0) == 1)
case "fuzzcase":
    dumpFuzzCase(format: args[2], k: arg(3, 0))
case "showmps":
    let lp = randomNamedLP(seed: UInt64(arg(2, 167)), freeRows: false)
    let w = MPSFormat.write(lp)
    print(describeLP(lp)); print(w)
    let back = try MPSFormat.read(w)
    for i in 0..<lp.m where lp.rl[i] != back.rl[i] || lp.ru[i] != back.ru[i] {
        print("row \(i): [\(lp.rl[i]), \(lp.ru[i])] -> [\(back.rl[i]), \(back.ru[i])] bits lo=\(String(lp.rl[i].bitPattern, radix: 16)) hi=\(String(lp.ru[i].bitPattern, radix: 16))")
        print("   exact R (G anchor lo) within 1e5 ulps: \(exactR(lp.rl[i], lp.ru[i], plus: true, window: 100000).map { "\($0)" } ?? "none")  (L anchor hi): \(exactR(lp.ru[i], lp.rl[i], plus: false, window: 100000).map { "\($0)" } ?? "none")")
    }
case "rangert":
    runRangeRT(count: arg(2, 10000))
case "showlp":
    try await showLPCase(arg(2, 98))
case "mpssem":
    try await runMPSSemantics()
case "lpsem":
    try await runLPSemantics()
case "roundtrip":
    try await runRoundTrip(from: arg(2, 0), count: arg(3, 200))
case "dsl":
    try await runDSL()
case "dualfd":
    try await runDualFD(from: arg(2, 0), count: arg(3, 100))
case "bigint2":
    await runBigInt2()
case "bigint":
    await runBigInt()
case "ip":
    await runIP(from: arg(2, 0), count: arg(3, 50))
case "infeas":
    await runInfeasible(from: arg(2, 0), count: arg(3, 50))
case "lpdiff":
    await runLPDiff(from: arg(2, 0), count: arg(3, 50), bounded: arg(4, 1) == 1, integerData: arg(5, 1) == 1, verbose: arg(6, 0) == 1)
default:
    print("modes: lpdiff <from> <count> <bounded 0/1> <intdata 0/1> <verbose 0/1>")
}
