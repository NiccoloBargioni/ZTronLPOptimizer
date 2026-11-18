import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func describe(_ r: Result<CPSATAnalysis, Error>) -> String {
    switch r {
    case .success(let a):
        let x = a.primal.map { $0.prefix(6).map { String(format: "%.17g", $0) }.joined(separator: ",") } ?? "nil"
        return "\(statusString(a.status)) obj=\(a.objectiveValue.map { String(format: "%.17g", $0) } ?? "nil") bound=\(a.bound.map { String(format: "%.17g", $0) } ?? "nil") x=[\(x)]"
    case .failure(let e): return "THROW \(e)"
    }
}

func trySolve(_ s: CPSAT, _ lp: CompiledLP, limit: Double = 20) async -> Result<CPSATAnalysis, Error> {
    do { return .success(try await s.solve(lp, context: ctx(limit))) } catch { return .failure(error) }
}

let domainLimit = Double(ProcessInfo.processInfo.environment["F5_LIMIT"] ?? "3")!
let domainOnly: [String] = (ProcessInfo.processInfo.environment["F5_ONLY"] ?? "").split(separator: ",").map(String.init)

func runDomain() async {
    let det = CPSAT(deterministic: true)
    let par = CPSAT()
    func show(_ label: String, _ lp: CompiledLP) async {
        if !domainOnly.isEmpty && !domainOnly.contains(where: { label.hasPrefix($0 + " ") }) { return }
        for (name, s) in [("det", det), ("par", par), ("detnolp", CPSAT(lpPropagator: false, deterministic: true))] {
            let r = await trySolve(s, lp, limit: domainLimit)
            var extra = ""
            if case .success(let a) = r, let x = a.primal { let v = lp.maxViolation(at: x); extra = " maxViolation(bounds=\(v.bounds), rows=\(v.rows))" }
            print("\(label) [\(name)]: \(describe(r))\(extra)")
        }
    }
    // D1: 1e-6 scaling accepted and exact: 1e-6 x + 2e-6 y >= 5e-6, min x + y, x,y in [0,10] -> 3
    await show("D1 scale1e6 (expect optimal 3)", makeLP(n: 2, rows: [[(0, 0.000001), (1, 0.000002)]], rl: [0.000005], ru: [.infinity], c: [1, 1], xl: [0, 0], xu: [10, 10]))
    // D2: 1e-7 rejected
    await show("D2 coef 1e-7 (expect unsupported)", makeLP(n: 2, rows: [[(0, 0.0000001), (1, 1)]], rl: [-.infinity], ru: [1], c: [1, 1], xl: [0, 0], xu: [10, 10]))
    // D3: tiny coefficient 1e-10 (no power of 10 up to 1e6 makes it integral) with large bound.
    //     max x + y s.t. 1e-10 x + y <= 1, x in [0,1e9], y in [0,1]. True optimum: x=1e9, y=0 -> 1e9.
    await show("D3 coef 1e-10 (README: expect unsupported)", makeLP(n: 2, rows: [[(0, 1e-10), (1, 1)]], rl: [-.infinity], ru: [1], c: [-1, -1], sense: .maximize, xl: [0, 0], xu: [1e9, 1]))
    // D3b: 1e-10 x <= 0.05, x in [0, 1e9], max x. True optimum 5e8.
    await show("D3b single coef 1e-10 (true opt 5e8)", makeLP(n: 1, rows: [[(0, 1e-10)]], rl: [-.infinity], ru: [0.05], c: [-1], sense: .maximize, xl: [0], xu: [1e9]))
    // D3c: 4e-10 x + 1e-6 y <= 1e-6 ... coefficient 4e-10 snapped? (scale 1: 4e-10 < 1e-9 -> but 1e-6 not integral at 1; scale 1e6: 4e-4 not integral) -> rejected expected
    await show("D3c 4e-10 & 1e-6 (expect unsupported)", makeLP(n: 2, rows: [[(0, 4e-10), (1, 1e-6)]], rl: [-.infinity], ru: [1e-6], c: [-1, -1], sense: .maximize, xl: [0, 0], xu: [1e9, 1]))
    // D4: continuous column rejected; integer column with infinite bound rejected
    await show("D4a continuous (expect unsupported)", makeLP(n: 2, rows: [[(0, 1), (1, 1)]], rl: [-.infinity], ru: [3], c: [1, 1], xl: [0, 0], xu: [5, 5], integer: [0]))
    await show("D4b infinite bound (expect unsupported)", makeLP(n: 2, rows: [[(0, 1), (1, 1)]], rl: [-.infinity], ru: [3], c: [1, 1], xl: [0, 0], xu: [5, .infinity]))
    // D5: column bound just above 2^50: x in [0, 2^50+1], max x. Expect 2^50+1.
    for e in [49, 50, 51, 52] {
        let b = Double(Int64(1) << Int64(e)) + 1
        await show("D5 bound 2^\(e)+1 max x (expect \(String(format: "%.0f", b)))", makeLP(n: 1, rows: [[(0, 1)]], rl: [0], ru: [.infinity], c: [-1], sense: .maximize, xl: [0], xu: [b]))
        await show("D5' bound -(2^\(e)+1) min x (expect \(String(format: "%.0f", -b)))", makeLP(n: 1, rows: [[(0, 1)]], rl: [-.infinity], ru: [0], c: [1], xl: [-b], xu: [0]))
    }
    // D6: row upper bound >= 2^50: x in [0, 2^51], row x <= 2^50 + 1 (as a row), max x
    for e in [50, 51, 52] {
        let r = Double(Int64(1) << Int64(e)) + 1
        let xu = Double(Int64(1) << Int64(e + 1)) - 2  // keep the column bound below 2^53... approximately
        await show("D6 row x <= 2^\(e)+1 (expect \(String(format: "%.0f", r)))", makeLP(n: 1, rows: [[(0, 1)]], rl: [-.infinity], ru: [r], c: [-1], sense: .maximize, xl: [0], xu: [min(xu, 9.0e15)]))
    }
    // D7: activity near 2^61: coefficient (2^30+1) * x, x in [0, 2^30]  -> accepted;  (2^31+1) -> rejected
    for a in [Double((1 << 30) + 1), Double((1 << 31) + 1)] {
        await show("D7 activity a=\(a) * x, x<=2^30 (a=2^31+1 expect unsupported)", makeLP(n: 2, rows: [[(0, a), (1, 1)]], rl: [-.infinity], ru: [a * 1000 + 0.5], c: [-1, -1], sense: .maximize, xl: [0, 0], xu: [Double(1 << 30), 1]))
    }
    // D8: large coefficient with rhs just below a multiple, near 2^59.9
    do {
        let a: Int64 = (1 << 40) + 1
        let k: Int64 = 900_000
        let T = a * k
        var R = Double(T)
        while Int64(R) >= T { R = R.nextDown }
        let exactMax = Int64(R) / a  // floor, R>0
        let lp = makeLP(n: 1, rows: [[(0, Double(a))]], rl: [-.infinity], ru: [R], c: [-1], sense: .maximize, xl: [0], xu: [1_000_000])
        await show("D8 a=2^40+1, a*x <= R=\(String(format: "%.0f", R)) (exact max x = \(exactMax); a*\(k) = \(T))", lp)
    }
    // D9: scaled data and fractional rhs: 0.5x + 0.25y <= 1.3 -> 2x + y <= 5.2 -> 2x+y<=5; max x+y, x,y in [0,5]
    await show("D9 0.5x+0.25y<=1.3 max x+y (expect 5: x=0,y=5)", makeLP(n: 2, rows: [[(0, 0.5), (1, 0.25)]], rl: [-.infinity], ru: [1.3], c: [-1, -1], sense: .maximize, xl: [0, 0], xu: [5, 5]))
    // D10: coefficient 1e15 + 0.5 (in [2^49, 2^50), ulp 0.125) - scale 10 would exceed 2^53; README: rejected?
    await show("D10 coef 1e15+0.5 (scale 10 gives >=2^53: README says unsupported)", makeLP(n: 2, rows: [[(0, 1e15 + 0.5), (1, 1)]], rl: [1e15 + 0.5], ru: [.infinity], c: [1, 1], xl: [0, 0], xu: [3, 3]))
    // D11: NaN row bound
    await show("D11 NaN row upper", makeLP(n: 1, rows: [[(0, 1)]], rl: [-.infinity], ru: [.nan], c: [-1], sense: .maximize, xl: [0], xu: [5]))
    // D12: bound fractional within snap: x <= 2.9999999999 -> 2 (since 1e-10 < 1e-9 snaps to 3?)
    await show("D12 xu=2.9999999995 (true integer max 2)", makeLP(n: 1, rows: [[(0, 1)]], rl: [0], ru: [.infinity], c: [-1], sense: .maximize, xl: [0], xu: [2.9999999995]))
    await show("D12b row x<=2.9999999995 (true integer max 2)", makeLP(n: 1, rows: [[(0, 1)]], rl: [-.infinity], ru: [2.9999999995], c: [-1], sense: .maximize, xl: [0], xu: [5]))
    // D14: coefficient 1e15+0.5 rounded to 1e15+1 -> wrong optimum at a small objective.
    //      (1e15+0.5) x + y >= 1e15+1, x in {0,1}, y in [0,3], min y. True optimum y=1 (x=1).
    await show("D14 coef 1e15+0.5, rhs 1e15+1, min y (true opt 1)", makeLP(n: 2, rows: [[(0, 1e15 + 0.5), (1, 1)]], rl: [1e15 + 1], ru: [.infinity], c: [0, 1], xl: [0, 0], xu: [1, 3]))
    // D14b: 2^52+1 bound, cost on a second variable: x <= 2^52+1 (bound), row x - y <= 2^52+1 ... y >= x - (2^52+1); min y with x forced to its upper bound by row x >= 2^52+1
    let b52 = Double(Int64(1) << 52) + 1
    await show("D14b x in [0,2^52+1], row x - y >= 2^52+1 ... min y (true opt 0)", makeLP(n: 2, rows: [[(0, 1), (1, -1)]], rl: [b52], ru: [.infinity], c: [0, 1], xl: [0, 0], xu: [b52, 10]))
    // D14c: same but the row is an upper side that is widened: x + y <= 2^52+1 with x >= 2^52+1 forced by its bound; max y (true opt 0)
    await show("D14c x in [2^52+1, 2^52+1], row x + y <= 2^52+1, max y (true opt 0)", makeLP(n: 2, rows: [[(0, 1), (1, 1)]], rl: [-.infinity], ru: [b52], c: [0, -1], sense: .maximize, xl: [b52, 0], xu: [b52, 10]))
    // D15: the 2^53 boundary for column bounds (README: rejected at 2^53 or more)
    for d in [1.0, 4.0, 5.0] {
        let b = 9007199254740992.0 - d
        await show("D15 xu=2^53-\(Int(d)) max x (README: accepted, expect \(String(format: "%.0f", b)))", makeLP(n: 1, rows: [[(0, 1)]], rl: [-.infinity], ru: [b], c: [-1], sense: .maximize, xl: [0], xu: [b]))
    }
    // D13: objective coefficients needing 1e6 and the constant
    await show("D13 obj 0.000001 x + 3.5, x in [0,7] max (expect 3.500007)", makeLP(n: 1, rows: [[(0, 1)]], rl: [0], ru: [.infinity], c: [-0.000001], c0: -3.5, sense: .maximize, xl: [0], xu: [7]))
}

/// Exact 0/1 knapsack optimum by DP over weights.
func knapsackDP(values: [Int], weights: [Int], capacity: Int) -> Int {
    var best = [Int](repeating: 0, count: capacity + 1)
    for i in values.indices {
        let w = weights[i]
        if w > capacity { continue }
        for c in stride(from: capacity, through: w, by: -1) {
            best[c] = max(best[c], best[c - w] + values[i])
        }
    }
    return best[capacity]
}

func runGap() async {
    // G1: knapsacks with large values: max sum v x, sum w x <= C. Compare with DP.
    var rng = SeededGenerator(seed: 77)
    var within = 0, nonOptimalLabelledOptimal = 0, beyondGap = 0, total = 0
    for k in 0..<60 {
        let n = rng.integer(in: 15...30)
        let magnitude = [100.0, 1_000, 10_000, 100_000, 1_000_000][k % 5]
        var v = [Int](), w = [Int]()
        for _ in 0..<n {
            let wi = rng.integer(in: 10...60)
            w.append(wi)
            v.append(Int(Double(wi) * magnitude * rng.uniform(in: 0.8...1.2)) + rng.integer(in: 0...9))
        }
        let cap = w.reduce(0, +) / 2 + rng.integer(in: 0...7)
        let truth = knapsackDP(values: v, weights: w, capacity: cap)
        let lp = makeLP(n: n, rows: [w.indices.map { ($0, Double(w[$0])) }], rl: [-.infinity], ru: [Double(cap)], c: v.map { -Double($0) }, sense: .maximize, xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n))
        for (cname, s) in [("default", CPSAT()), ("det", CPSAT(deterministic: true))] {
            let r = await trySolve(s, lp, limit: 30)
            guard case .success(let a) = r, let obj = a.objectiveValue else { print("G1 k=\(k) \(cname): \(describe(r))"); continue }
            total += 1
            let diff = Double(truth) - obj
            let allowed = max(1e-6, 1e-4 * max(1, abs(obj)))
            if a.status == .optimal {
                if diff == 0 { within += 1 } else if diff <= allowed + 1e-9 { nonOptimalLabelledOptimal += 1; print("G1 k=\(k) \(cname) mag=\(magnitude): optimal label, obj \(obj) vs true \(truth) (diff \(diff), allowed \(allowed)) bound=\(a.bound ?? .nan)") } else {
                    beyondGap += 1; print("G1 k=\(k) \(cname) mag=\(magnitude): BEYOND GAP obj \(obj) vs true \(truth) diff \(diff) allowed \(allowed) bound=\(a.bound ?? .nan)")
                }
                if let b = a.bound, b < Double(truth) - 1e-6 { print("G1 k=\(k) \(cname): bound \(b) below the true optimum \(truth) for a max problem: INVALID BOUND") }
            } else {
                print("G1 k=\(k) \(cname) mag=\(magnitude): status \(statusString(a.status)) obj \(obj) true \(truth)")
            }
        }
    }
    print("G1 knapsacks: runs=\(total) exact=\(within) nonOptimalButLabelledOptimal(withinGap)=\(nonOptimalLabelledOptimal) beyondGap=\(beyondGap)")

    // G2: objective constant: min x + 1e8 with x integer in [0, 1000] and a row forcing x >= 0 by a chain.
    // A model whose first incumbent is bad: min sum x_i subject to sum x_i >= 3 (x_i in [0,1000]),
    // plus constant 1e8.  Allowed gap = 1e4, so any incumbent <= 1e8 + 1e4 is 'optimal'.
    let n = 6
    let lpG2 = makeLP(n: n, rows: [Array((0..<n).map { ($0, 1.0) })], rl: [3], ru: [.infinity], c: [Double](repeating: 1, count: n), c0: 1e8, xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1000, count: n))
    for (cname, s) in [("default", CPSAT()), ("det", CPSAT(deterministic: true)), ("detnolp", CPSAT(lpPropagator: false, deterministic: true))] {
        print("G2 constant 1e8 (true opt 100000003) [\(cname)]: \(describe(await trySolve(s, lpG2)))")
    }
}

func runDeterminism(name: String, runs: Int, cfg: String) async {
    guard let lp = try! Corpora.loadMIPLIB3(name) else { print("missing \(name)"); return }
    let s = config(cfg).strategy
    var signatures: [String] = []
    for r in 0..<runs {
        let recorder = Recorder()
        var c = SolveContext()
        c.timeLimit = 120
        c.threads = [1, 4, 8][r % 3]
        c.progress = recorder.callback
        let t = Date()
        let a = try! await s.solve(lp, context: c)
        let ev = recorder.events()
        let evSig = ev.map { e -> String in
            switch e {
            case .newIncumbent(let o, let node, let src): return "inc(\(o),\(node),\(src))"
            case .boundImproved(let b, _): return "bnd(\(b))"
            case .started: return "start"
            case .finished(let st, _): return "fin(\(statusString(st)))"
            case .warning(let w): return "warn(\(w))"
            default: return "other"
            }
        }.joined(separator: ";")
        let sig = "\(statusString(a.status)) obj=\(a.objectiveValue ?? .nan) conflicts=\(a.conflicts) decisions=\(a.decisions) props=\(a.propagations) lp=\(a.lpSolves) x=\(a.primal?.hashValue ?? 0) evhash=\(evSig.hashValue) nev=\(ev.count)"
        print("run \(r) threads=\(c.threads!) \(String(format: "%.2f", Date().timeIntervalSince(t)))s: \(sig)")
        signatures.append("\(statusString(a.status)) \(a.objectiveValue ?? .nan) \(a.conflicts) \(a.decisions) \(a.propagations) \(a.lpSolves) \(a.primal ?? []) \(evSig)")
    }
    print("identical=\(Set(signatures).count == 1)")
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SolverEvent] = []
    var callback: @Sendable (SolverEvent) -> Void {
        { [self] e in lock.lock(); list.append(e); lock.unlock() }
    }
    func events() -> [SolverEvent] { lock.lock(); defer { lock.unlock() }; return list }
}

func runMIPLIB(names: [String], cfg: String, limit: Double) async {
    let s = config(cfg).strategy
    for name in names {
        guard let lp = try! Corpora.loadMIPLIB3(name), let ref = ReferenceValues.miplib3(named: name) else { print("missing \(name)"); continue }
        let t = Date()
        let r = await trySolve(s, lp, limit: limit)
        let dt = Date().timeIntervalSince(t)
        if case .success(let a) = r {
            let viol = a.primal.map { pointViolation(lp, $0) } ?? .nan
            let objAt = a.primal.map { lp.objective(at: $0) } ?? .nan
            print("\(name) cfg=\(cfg): \(statusString(a.status)) obj=\(a.objectiveValue ?? .nan) ref=\(ref.optimalObjective) bound=\(a.bound ?? .nan) objAtX=\(objAt) viol=\(viol) conflicts=\(a.conflicts) lpSolves=\(a.lpSolves) workers=\(a.workers) winner=\(a.winningWorker.map(String.init) ?? "nil") wall=\(String(format: "%.2f", dt))s reported=\(String(format: "%.2f", a.seconds))s")
        } else { print("\(name): \(describe(r))") }
    }
}

func runLimit(name: String, cfg: String, limit: Double) async {
    guard let lp = try! Corpora.loadMIPLIB3(name) else { print("missing"); return }
    let s = config(cfg).strategy
    for _ in 0..<3 {
        let t = Date()
        let r = await trySolve(s, lp, limit: limit)
        let dt = Date().timeIntervalSince(t)
        print("limit=\(limit) \(name) cfg=\(cfg): wall=\(String(format: "%.3f", dt))s overshoot=\(String(format: "%.3f", dt - limit))s \(describe(r))")
    }
}

func runBig() async {
    // Several rows with activities near 2^61 together with an objective with a large range,
    // to look for overflow traps during search and in the LP propagator.
    var rng = SeededGenerator(seed: 5)
    for k in 0..<30 {
        let n = rng.integer(in: 2...4)
        var rows: [[(Int, Double)]] = []
        var rl = [Double](), ru = [Double]()
        let xb = Double(1 << 20)
        for _ in 0..<2 {
            var r: [(Int, Double)] = []
            for j in 0..<n {
                // coefficients near 2^38 so that activities reach ~2^60
                let a = Double(Int64(rng.integer(in: 1...100)) * (Int64(1) << 30) + Int64(rng.integer(in: 1...1000))) * (rng.chance(0.5) ? 1 : -1)
                r.append((j, a))
            }
            rows.append(r)
            var amin = 0.0, amax = 0.0
            for (_, a) in r { amin += min(a * -xb, a * xb); amax += max(a * -xb, a * xb) }
            rl.append(amin * 0.3); ru.append(amax * 0.5)
        }
        let c = (0..<n).map { _ in Double(rng.integer(in: -1000...1000)) * Double(1 << 28) }
        let lp = makeLP(n: n, rows: rows, rl: rl, ru: ru, c: c, xl: [Double](repeating: -xb, count: n), xu: [Double](repeating: xb, count: n))
        for (cname, s) in [("det", CPSAT(deterministic: true)), ("detnolp", CPSAT(lpPropagator: false, deterministic: true)), ("par", CPSAT())] {
            let r = await trySolve(s, lp, limit: 5)
            var extra = ""
            if case .success(let a) = r, let x = a.primal { extra = " viol=\(pointViolation(lp, x))" }
            print("B k=\(k) \(cname): \(describe(r))\(extra)")
        }
    }
}
