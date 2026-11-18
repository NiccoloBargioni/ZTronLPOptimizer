import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// C7: iteration and time limits.
func runLimits() async {
    var bad: [String] = []
    var held = 0
    for name in ["afiro", "share2b", "scagr7", "degen2", "israel"] {
        let lp = try! NetlibFixtures.load(name)
        for method in [Simplex.Method.primal, .dual] {
            for pre in [true, false] {
                for cap in [0, 1, 3, 10, 40] {
                    let s = Simplex(method, maxIterations: cap, presolve: pre)
                    do {
                        let an = try await s.solve(lp, context: ctx(30))
                        let label = "\(name) \(method) pre\(pre) cap\(cap)"
                        if an.iterations > cap { bad.append("\(label): iterations \(an.iterations) > cap") }
                        switch an.status {
                        case .optimal: break
                        case .feasible(let why):
                            if why != .iterationLimit { bad.append("\(label): feasible stopped by \(why)") }
                            guard let x = an.primal else { bad.append("\(label): feasible without primal"); break }
                            let v = lp.maxViolation(at: x)
                            if max(v.bounds, v.rows) > 1e-6 { bad.append("\(label): .feasible point violates by \(fmt(max(v.bounds, v.rows)))") }
                            if let o = an.objectiveValue, abs(o - lp.objective(at: x)) > 1e-9 * max(1, abs(o)) { bad.append("\(label): objective \(o) != objective(at: x) \(lp.objective(at: x))") }
                            if an.objectiveValue == nil { bad.append("\(label): .feasible without objective") }
                            // A bound, when given, must be a valid bound in the model's sense
                            if let bnd = an.bound, let ref = ReferenceValues.netlib(named: name)?.optimalObjective {
                                // minimization in all these netlib models: bound <= optimum
                                if bnd > ref + 1e-6 * max(1, abs(ref)) { bad.append("\(label): bound \(bnd) above the optimum \(ref)") }
                            }
                        case .noSolution(let why):
                            if why != .iterationLimit { bad.append("\(label): noSolution stopped by \(why)") }
                            if let bnd = an.bound, let ref = ReferenceValues.netlib(named: name)?.optimalObjective {
                                if bnd > ref + 1e-6 * max(1, abs(ref)) { bad.append("\(label): bound \(bnd) above the optimum \(ref)") }
                            }
                        default: bad.append("\(label): status \(an.status)")
                        }
                        held += 1
                    } catch { bad.append("\(name): threw \(error)") }
                }
            }
        }
    }
    print("iteration-limit runs \(held), bad \(bad.count)")
    for b in bad.prefix(40) { print("BAD", b) }

    // Time limits on a big transport LP.
    let big = InstanceGenerator.transport(sources: 40, sinks: 500, seed: 3)
    print("transport m \(big.m) n \(big.n)")
    for (name, s) in [("dual-dense", Simplex(.dual, factorization: .denseLU)), ("primal-dense", Simplex(.primal, factorization: .denseLU)),
                      ("dual-qr", Simplex(.dual, factorization: .sparseQR)), ("primal-qr", Simplex(.primal, factorization: .sparseQR))] {
        for limit in [0.0, 0.01, 0.05] {
            let t0 = Date()
            do {
                let an = try await s.solve(big, context: ctx(limit))
                let dt = Date().timeIntervalSince(t0)
                var extra = ""
                if case .feasible = an.status, let x = an.primal { let v = big.maxViolation(at: x); extra = "viol \(fmt(max(v.bounds, v.rows)))" }
                print("time limit \(limit) \(name): status \(an.status) wall \(String(format: "%.3f", dt)) s iterations \(an.iterations) \(extra)")
            } catch { print("time limit \(limit) \(name): threw \(error)") }
        }
    }
}

/// C8: warm starts.
func runWarm(count: Int, seed0: UInt64) async {
    var bad: [String] = []
    var maxWarmIters = 0
    var runs = 0
    let grid = configGrid(full: false)
    for k in 0..<count {
        let seed = seed0 + UInt64(k)
        var r = Rng(seed &* 13)
        let inst = makeKKT(m: r.int(4, 25), n: r.int(4, 30), seed: seed, maximize: k % 2 == 0, degenerate: k % 3 == 0)
        for cfg in grid {
            do {
                let cold = try await cfg.s.solve(inst.lp, context: ctx())
                guard cold.status == .optimal else { bad.append("\(inst.label) \(cfg.name): cold \(cold.status)"); continue }
                let warm = try await cfg.s.solve(inst.lp, context: ctx(warm: .basis(cold.basis)))
                runs += 1
                maxWarmIters = max(maxWarmIters, warm.iterations)
                if warm.status != .optimal || abs((warm.objectiveValue ?? .nan) - inst.objective) > 1e-7 * max(1, abs(inst.objective)) {
                    bad.append("\(inst.label) \(cfg.name): warm \(warm.status) obj \(warm.objectiveValue ?? .nan)")
                }
                if warm.iterations > 2 { bad.append("\(inst.label) \(cfg.name): warm start from the optimal basis took \(warm.iterations) iterations (cold \(cold.iterations))") }
                // primal point warm start and crashes
                for (wn, w) in [("point", WarmStart.primalPoint(inst.x)), ("triangular", .crash(.triangular)), ("slack", .crash(.slack))] {
                    let an = try await cfg.s.solve(inst.lp, context: ctx(warm: w))
                    if an.status != .optimal || abs((an.objectiveValue ?? .nan) - inst.objective) > 1e-7 * max(1, abs(inst.objective)) {
                        bad.append("\(inst.label) \(cfg.name) \(wn): \(an.status) obj \(an.objectiveValue ?? .nan) vs \(inst.objective)")
                    }
                }
            } catch { bad.append("\(inst.label) \(cfg.name): threw \(error)") }
        }
    }
    // Netlib warm starts
    for name in ["afiro", "sc105", "share2b", "scagr7", "israel", "degen2", "beaconfd", "stocfor1"] {
        let lp = try! NetlibFixtures.load(name)
        for method in [Simplex.Method.primal, .dual] {
            for pre in [true, false] {
                let s = Simplex(method, presolve: pre)
                let cold = try! await s.solve(lp, context: ctx(60))
                let warm = try! await s.solve(lp, context: ctx(60, warm: .basis(cold.basis)))
                runs += 1
                maxWarmIters = max(maxWarmIters, warm.iterations)
                let ref = ReferenceValues.netlib(named: name)!.optimalObjective
                if warm.status != .optimal || ReferenceValues.relativeError(warm.objectiveValue ?? .nan, reference: ref) > 1e-6 { bad.append("\(name) \(method) pre\(pre): warm \(warm.status)") }
                if warm.iterations > 2 { bad.append("\(name) \(method) pre\(pre): warm from optimal basis took \(warm.iterations) iterations (cold \(cold.iterations))") }
                // incremental: tighten one column bound and compare with a cold solve of the changed problem
                let j = 0
                let change = BoundChange(column: Int32(j), lower: lp.xl[j], upper: max(lp.xl[j], (cold.primal?[j] ?? 0) * 0.5))
                let inc = try! await s.solve(lp, context: ctx(60, warm: .incremental(parent: cold.basis, changes: [change])))
                let changed = lp.applying([change])
                let coldChanged = try! await s.solve(changed, context: ctx(60))
                if inc.status != coldChanged.status || abs((inc.objectiveValue ?? 0) - (coldChanged.objectiveValue ?? 0)) > 1e-6 * max(1, abs(coldChanged.objectiveValue ?? 0)) {
                    bad.append("\(name) \(method) pre\(pre): incremental \(inc.status) \(inc.objectiveValue ?? .nan) vs cold \(coldChanged.status) \(coldChanged.objectiveValue ?? .nan)")
                }
                if let x = inc.primal, inc.status == .optimal {
                    let v = changed.maxViolation(at: x)
                    if max(v.bounds, v.rows) > 1e-6 { bad.append("\(name) \(method) pre\(pre): incremental point violates the changed problem by \(fmt(max(v.bounds, v.rows)))") }
                }
            }
        }
    }
    print("warm runs \(runs), max warm iterations \(maxWarmIters), bad \(bad.count)")
    for b in bad.prefix(50) { print("BAD", b) }
}
