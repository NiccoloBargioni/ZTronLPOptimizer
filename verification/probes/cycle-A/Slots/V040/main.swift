// Cycle A, sceptic V040 for finding A2-04 ("beyond a condition number of about 1e11 only the
// objective can be trusted"). Builds square equality LPs with a unique feasible point, solves
// them with several strategies, and dumps every input and output as exact bit patterns so
// that an exact rational oracle (A2-04-V040-oracle.py) can judge the objective.
//
// Usage: V040 <family> <out.jsonl>
//   family: finder   -- the finder's 24 L·D·U instances (seeds 900+k), its 40 configs + facades
//           hilbert  -- InstanceGenerator.hilbert orders 6...12, equality forms, three objectives:
//                       own (c = H·1, the package's), generic (random c), dualmod (c = Hᵀy, y ~ U[0.5,1.5])
//           randsvd  -- my own family: A = Q1·diag(σ)·Q2ᵀ, σ geometric to 10^-p, x* random,
//                       objectives generic (random c) and dualmod (c = Aᵀy, y ~ U[-1,1])
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

// MARK: - Random numbers (my own SplitMix64; the finder's generator copied verbatim below)

struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64) { s = seed ^ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func gauss() -> Double {
        let u1 = max(unit(), 1e-300), u2 = unit()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
    }
}

/// The finder's generator (Slots/F2/Common.swift `Rng`), copied so its instances are rebuilt bit for bit.
struct FinderRng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func u(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
}

// MARK: - Instances

struct Instance {
    let id: String
    let family: String
    let objectiveKind: String
    let a: [[Double]]      // dense, row-major, exactly as stored in the LP
    let b: [Double]
    let c: [Double]
    let xl: [Double]
    let xu: [Double]
    let nominal: [Double]  // the point the generator intended (oracle of a naive check)
    var lp: CompiledLP {
        let n = a.count
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in 0..<n { for j in 0..<n where a[i][j] != 0 { entries.append((i, j, a[i][j])) } }
        return CompiledLP(a: SparseCSC.fromTriplets(rows: n, cols: n, entries), c: c, xl: xl, xu: xu, rl: b, ru: b)
    }
}

/// The finder's L·D·U instance k (IllRandom.swift `illInstance`), rebuilt verbatim.
func finderInstance(_ k: Int) -> Instance {
    var r = FinderRng(UInt64(900 + k))
    let n = r.int(5, 12)
    let decades = Double(r.int(6, 13))
    var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    var U = L
    for i in 0..<n { for j in 0..<n {
        if i == j { L[i][j] = 1; U[i][j] = 1 }
        else if i > j { L[i][j] = r.u(-1, 1) } else { U[i][j] = r.u(-1, 1) }
    } }
    let d = (0..<n).map { pow(10, -decades * Double($0) / Double(max(1, n - 1))) }
    var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0..<n { var s = 0.0; for p in 0..<n { s += L[i][p] * d[p] * U[p][j] }; A[i][j] = s } }
    var b = [Double](repeating: 0, count: n), c = [Double](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<n where A[i][j] != 0 { b[i] += A[i][j]; c[j] += A[i][j] } }
    for j in 0..<n { c[j] += 1 }
    return Instance(id: "finder-k\(k)-n\(n)-d\(Int(decades))", family: "finder", objectiveKind: "finder(c=A^T1+1)",
                    a: A, b: b, c: c, xl: [Double](repeating: -10, count: n), xu: [Double](repeating: 10, count: n),
                    nominal: [Double](repeating: 1, count: n))
}

/// Reads the dense matrix back out of a compiled LP, so the oracle sees exactly what was solved.
func dense(_ lp: CompiledLP) -> [[Double]] {
    var A = [[Double]](repeating: [Double](repeating: 0, count: lp.n), count: lp.m)
    for j in 0..<lp.n {
        for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { A[Int(lp.a.rowIndex[p])][j] = lp.a.values[p] }
    }
    return A
}

func hilbertInstances() -> [Instance] {
    var out: [Instance] = []
    for order in 6...12 {
        for form in [HilbertForm.equality, .equalityFree] {
            let inst = InstanceGenerator.hilbert(order: order, form: form)
            let lp = inst.lp
            let A = dense(lp)
            precondition(lp.rl == lp.ru, "equality form expected")
            let ones = [Double](repeating: 1, count: order)
            out.append(Instance(id: "hilbert-\(order)-\(form.rawValue)-own", family: "hilbert", objectiveKind: "own(c=H1)",
                                a: A, b: lp.rl, c: lp.c, xl: lp.xl, xu: lp.xu, nominal: ones))
            for s in 0..<3 {
                var r = SplitMix(UInt64(1000 * order + 10 * s + (form == .equality ? 1 : 2)))
                let cg = (0..<order).map { _ in r.uniform(0.5, 1.5) }
                out.append(Instance(id: "hilbert-\(order)-\(form.rawValue)-generic\(s)", family: "hilbert", objectiveKind: "generic",
                                    a: A, b: lp.rl, c: cg, xl: lp.xl, xu: lp.xu, nominal: ones))
                let y = (0..<order).map { _ in r.uniform(0.5, 1.5) }
                var cd = [Double](repeating: 0, count: order)
                for j in 0..<order { for i in 0..<order { cd[j] += A[i][j] * y[i] } }
                out.append(Instance(id: "hilbert-\(order)-\(form.rawValue)-dualmod\(s)", family: "hilbert", objectiveKind: "dualmod",
                                    a: A, b: lp.rl, c: cd, xl: lp.xl, xu: lp.xu, nominal: ones))
            }
        }
    }
    return out
}

func randomOrthogonal(_ n: Int, _ r: inout SplitMix) -> [[Double]] {
    var Q = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
    for _ in 0..<n {
        let v = (0..<n).map { _ in r.gauss() }
        let vv = v.reduce(0) { $0 + $1 * $1 }
        for i in 0..<n {
            var qv = 0.0
            for j in 0..<n { qv += Q[i][j] * v[j] }
            for j in 0..<n { Q[i][j] -= 2 * qv * v[j] / vv }
        }
    }
    return Q
}

func randsvdInstances() -> [Instance] {
    var out: [Instance] = []
    for n in [6, 9, 12] {
        for p in [6, 8, 10, 11, 12, 13, 14, 15] {
            for s in 0..<3 {
                var r = SplitMix(UInt64(77_000 + 1000 * n + 10 * p + s))
                let q1 = randomOrthogonal(n, &r), q2 = randomOrthogonal(n, &r)
                let sigma = (0..<n).map { pow(10, -Double(p) * Double($0) / Double(n - 1)) }
                var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
                for i in 0..<n { for j in 0..<n { var t = 0.0; for k in 0..<n { t += q1[i][k] * sigma[k] * q2[j][k] }; A[i][j] = t } }
                let xs = (0..<n).map { _ in r.uniform(-5, 5) }
                var b = [Double](repeating: 0, count: n)
                for i in 0..<n { for j in 0..<n { b[i] += A[i][j] * xs[j] } }
                let lo = [Double](repeating: -10, count: n), hi = [Double](repeating: 10, count: n)
                let cg = (0..<n).map { _ in r.uniform(-1, 1) }
                out.append(Instance(id: "randsvd-n\(n)-p\(p)-s\(s)-generic", family: "randsvd", objectiveKind: "generic",
                                    a: A, b: b, c: cg, xl: lo, xu: hi, nominal: xs))
                let y = (0..<n).map { _ in r.uniform(-1, 1) }
                var cd = [Double](repeating: 0, count: n)
                for j in 0..<n { for i in 0..<n { cd[j] += A[i][j] * y[i] } }
                out.append(Instance(id: "randsvd-n\(n)-p\(p)-s\(s)-dualmod", family: "randsvd", objectiveKind: "dualmod",
                                    a: A, b: b, c: cd, xl: lo, xu: hi, nominal: xs))
            }
        }
    }
    return out
}

// MARK: - Strategies

func facades() -> [(String, any SolverStrategy)] {
    [("Simplex()", Simplex()), ("Simplex(.primal)", Simplex(.primal)), ("InteriorPoint()", InteriorPoint()),
     ("Automatic()", Automatic()), ("Conditioned(Automatic())", Conditioned(Automatic()))]
}

/// The finder's 40-configuration grid (configGrid(full: false)), rebuilt.
func finderGrid() -> [(String, any SolverStrategy)] {
    var out: [(String, any SolverStrategy)] = []
    let facts: [(String, Simplex.Factorization)] = [("auto", .automatic), ("dense", .denseLU), ("qr", .sparseQR)]
    let scs: [(String, ScalingMode)] = [("none", .none), ("geo", .geometricEquilibration)]
    for method in [Simplex.Method.primal, .dual] {
        for (fn, f) in facts { for pre in [true, false] { for (sn, sc) in scs {
            out.append(("\(method)/\(fn)/pre\(pre)/\(sn)", Simplex(method, factorization: f, presolve: pre, scaling: sc)))
        } } }
    }
    let pricings: [(String, Simplex.Pricing)] = [("dantzig", .dantzig), ("steep", .steepestEdge), ("partial3", .partial(sections: 3))]
    for (pn, p) in pricings { for pre in [true, false] {
        out.append(("primal/\(pn)/pre\(pre)", Simplex(.primal, pricing: p, presolve: pre)))
    } }
    let perts: [(String, Simplex.Perturbation)] = [("off", .off), ("always", .always)]
    for method in [Simplex.Method.primal, .dual] { for (pn, p) in perts {
        out.append(("\(method)/pert-\(pn)", Simplex(method, perturbation: p)))
        out.append(("\(method)/pert-\(pn)/qr/nopre", Simplex(method, factorization: .sparseQR, perturbation: p, presolve: false)))
    } }
    var tight = Tolerances()
    tight.primalFeasibility = 1e-9
    tight.dualFeasibility = 1e-9
    for method in [Simplex.Method.primal, .dual] { out.append(("\(method)/tol1e-9", Simplex(method, tolerances: tight))) }
    return out
}

// MARK: - Dump

func hex(_ v: Double) -> String { String(v.bitPattern, radix: 16) }

func context() -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 20
    c.metal = .off
    return c
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: V040 finder|hilbert|randsvd <out.jsonl>")
    exit(2)
}
let family = args[1]
let instances: [Instance]
let strategies: [(String, any SolverStrategy)]
switch family {
case "finder":
    instances = (0..<24).map(finderInstance)
    strategies = finderGrid() + facades()
case "hilbert":
    instances = hilbertInstances()
    strategies = facades()
case "randsvd":
    instances = randsvdInstances()
    strategies = facades()
default:
    print("unknown family \(family)")
    exit(2)
}

FileManager.default.createFile(atPath: args[2], contents: nil)
let handle = FileHandle(forWritingAtPath: args[2])!
var solves = 0, optimal = 0
let started = Date()
for inst in instances {
    let lp = inst.lp
    var results: [[String: Any]] = []
    for (name, strategy) in strategies {
        var entry: [String: Any] = ["strategy": name]
        do {
            let an = try await strategy.solve(lp, context: context())
            entry["status"] = "\(an.status)"
            entry["optimal"] = an.status == .optimal
            entry["obj"] = an.objectiveValue.map(hex) ?? NSNull()
            entry["x"] = an.primal.map { $0.map(hex) } ?? NSNull()
            entry["warnings"] = an.warnings
            entry["seconds"] = an.seconds
            if an.status == .optimal { optimal += 1 }
        } catch {
            entry["status"] = "error: \(error)"
            entry["optimal"] = false
        }
        solves += 1
        results.append(entry)
    }
    let record: [String: Any] = [
        "id": inst.id, "family": inst.family, "objectiveKind": inst.objectiveKind, "n": inst.a.count,
        "A": inst.a.map { $0.map(hex) }, "b": inst.b.map(hex), "c": inst.c.map(hex),
        "xl": inst.xl.map(hex), "xu": inst.xu.map(hex), "nominal": inst.nominal.map(hex), "results": results,
    ]
    var data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    data.append(0x0A)
    handle.write(data)
}
handle.closeFile()
print("family \(family): \(instances.count) instances, \(strategies.count) strategies, \(solves) solves, \(optimal) optimal, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
