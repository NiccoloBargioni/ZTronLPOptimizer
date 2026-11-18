// V104 — cycle A, contract sceptic for finding A4-05 (a stop during the root expansion of
// BranchAndBound loses the root node, so bound collapses to the incumbent and gap reads 0).
//
// Modes:
//   ref                 reference solves of randomMILP(30x120, seed 77, upper 1): B&B dual and
//                       CPSAT, each solution checked independently (bounds, rows, integrality).
//   stop  <bestKnown>   short time limits and early cancellations with the default B&B and the
//                       dual node engine; each result's incumbent checked, its bound compared
//                       with a verified feasible objective (bestKnown).
//   wide                corpus and larger random MILPs: sweep the time limit and report every
//                       run that shows the lost-root signature (feasible, 1 node, 0 open,
//                       bound == incumbent while the root LP differs).
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func f(_ x: Double?) -> String { x.map { String(format: "%.6f", $0) } ?? "nil" }

func pointCheck(_ lp: CompiledLP, _ x: [Double]?) -> String {
    guard let x else { return "no point" }
    let v = lp.maxViolation(at: x)
    var frac = 0.0
    for j in lp.integerColumns { let t = x[Int(j)]; frac = max(frac, abs(t - t.rounded())) }
    return "viol(bounds \(f(v.bounds)), rows \(f(v.rows))) frac \(f(frac)) objective(at:) \(f(lp.objective(at: x)))"
}

func ctx(_ t: Double, threads: Int? = nil) -> SolveContext {
    var c = SolveContext(); c.timeLimit = t; c.metal = .off
    if let threads { c.threads = threads }
    return c
}

let instance = InstanceGenerator.randomMILP(rows: 30, columns: 120, seed: 77, upper: 1)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "ref"

switch mode {
case "ref":
    let lp = instance
    print("instance m \(lp.m) n \(lp.n) sense \(lp.sense) integer columns \(lp.integerColumns.count)")
    let t0 = Date()
    let d = try await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: ctx(150, threads: 8))
    print("B&B dual 150 s: \(d.status) obj \(f(d.objectiveValue)) bound \(f(d.bound)) gap \(f(d.gap)) nodes \(d.nodesProcessed) open \(d.nodesOpen) rootLP \(f(d.root.objectiveValue)) wall \(f(Date().timeIntervalSince(t0)))")
    print("  point: \(pointCheck(lp, d.primal))")
    let t1 = Date()
    let c = try await CPSAT().solve(lp, context: ctx(150))
    print("CPSAT 150 s: \(c.status) obj \(f(c.objectiveValue)) bound \(f(c.bound)) wall \(f(Date().timeIntervalSince(t1)))")
    print("  point: \(pointCheck(lp, c.primal))")

case "stop":
    let lp = instance
    let bestKnown = args.count > 2 ? Double(args[2])! : 1097
    var bad = 0, total = 0
    func report(_ label: String, _ a: BranchAndBoundAnalysis<SimplexAnalysis>) {
        total += 1
        // Maximisation: a proven bound must be >= every feasible objective.
        let invalid = (a.bound ?? .infinity) < bestKnown - 1e-6
        if invalid { bad += 1 }
        print("\(label): \(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) nodes \(a.nodesProcessed) open \(a.nodesOpen) rootLP \(f(a.root.objectiveValue)) incumbents \(a.incumbentHistory.map { "\($0.source)@\($0.node)" }) BOUND_INVALID \(invalid)")
        if a.status.hasSolution { print("    incumbent point: \(pointCheck(lp, a.primal))") }
    }
    for (engineName, dual) in [("primal", false), ("dual", true)] {
        for t in [0.0005, 0.001, 0.002, 0.003, 0.005, 0.01] {
            for threads in [1, 8] {
                for rep in 0..<2 {
                    let a = dual
                        ? try await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: ctx(t, threads: threads))
                        : try await BranchAndBound().solve(lp, context: ctx(t, threads: threads))
                    report("\(engineName) T \(t) threads \(threads) rep \(rep)", a)
                }
            }
        }
    }
    for delay in [UInt64(200_000), 500_000, 1_000_000, 2_000_000, 5_000_000] {
        let task = Task { () -> BranchAndBoundAnalysis<SimplexAnalysis> in
            try await BranchAndBound().solve(lp, context: ctx(60))
        }
        try await Task.sleep(nanoseconds: delay)
        task.cancel()
        report("primal cancel after \(Double(delay) / 1e6) ms", try await task.value)
    }
    print("SUMMARY stop: \(bad) of \(total) results report a bound below the verified feasible objective \(bestKnown)")

case "wide":
    var cases: [(String, CompiledLP, Double?)] = []
    for ref in ReferenceValues.miplib3 {
        if let lp = try Corpora.loadMIPLIB3(ref.name) { cases.append((ref.name, lp, ref.optimalObjective)) }
    }
    cases.append(("randomMILP(80x400,s5)", InstanceGenerator.randomMILP(rows: 80, columns: 400, seed: 5, upper: 1), nil))
    cases.append(("randomMILP(120x800,s9,upper3)", InstanceGenerator.randomMILP(rows: 120, columns: 800, seed: 9, upper: 3), nil))
    let limits = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
    var hits = 0
    for (name, lp, opt) in cases {
        var line = "\(name) (sense \(lp.sense), opt \(f(opt))):"
        for t in limits {
            let a = try await BranchAndBound().solve(lp, context: ctx(t, threads: 8))
            let lost = a.status.stopReason != nil && a.status.hasSolution && a.nodesProcessed == 1 && a.nodesOpen == 0
            if lost {
                hits += 1
                var invalid = "unknown"
                if let opt, let b = a.bound {
                    invalid = String(lp.sense == .maximize ? b < opt - 1e-6 : b > opt + 1e-6)
                }
                line += "\n   T \(t): LOST-ROOT \(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) rootLP \(f(a.root.objectiveValue)) boundInvalidVsOpt \(invalid)"
            } else {
                line += "\n   T \(t): \(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) nodes \(a.nodesProcessed) open \(a.nodesOpen)"
            }
        }
        print(line)
    }
    print("SUMMARY wide: \(hits) lost-root results")

case "big":
    // big <rows> <cols> <seed> <upper> <limits...>: how wide the window is on a larger model.
    let m = Int(args[2])!, n = Int(args[3])!, seed = UInt64(args[4])!, upper = Int(args[5])!
    let lp = InstanceGenerator.randomMILP(rows: m, columns: n, seed: seed, upper: upper)
    for t in args.dropFirst(6).map({ Double($0)! }) {
        let t0 = Date()
        let a = try await BranchAndBound().solve(lp, context: ctx(t, threads: 8))
        let lost = a.status.stopReason != nil && a.status.hasSolution && a.nodesProcessed == 1 && a.nodesOpen == 0
        print("randomMILP(\(m)x\(n),s\(seed),u\(upper)) T \(t): \(lost ? "LOST-ROOT " : "")\(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) nodes \(a.nodesProcessed) open \(a.nodesOpen) rootLP \(f(a.root.objectiveValue)) incumbents \(a.incumbentHistory.map { "\($0.source)@\($0.node)" }) wall \(f(Date().timeIntervalSince(t0)))")
        if a.status.hasSolution { print("    incumbent point: \(pointCheck(lp, a.primal))") }
    }

default:
    print("unknown mode \(mode)")
}
