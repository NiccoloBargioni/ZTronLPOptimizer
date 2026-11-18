// Cycle B, slot F5 (CP-SAT). Modes: see the switch at the bottom.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"
func arg(_ i: Int, _ d: String) -> String { args.count > i ? args[i] : d }

func listCNF(_ dir: String) -> [String] {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".cnf") }.sorted().map { dir + "/" + $0 }
}

/// Checks one CP-SAT outcome on a small exact program against enumeration. nil = agrees.
func judge(_ p: IntProgram, _ o: Outcome, _ bf: (best: Int?, count: Int, optima: Int)) -> String? {
    if let e = o.error { return "threw \(e)" }
    guard let st = o.status else { return "no status" }
    switch st {
    case .infeasible:
        if let b = bf.best { return "FALSE INFEASIBLE (true opt int \(b), \(bf.count) feasible points)" }
        return nil
    case .optimal, .feasible:
        guard let x = o.primal else { return "no primal with \(statusName(st))" }
        var xi: [Int] = []
        for v in x {
            guard v == v.rounded(), abs(v) < 1e15 else { return "non-integral primal \(x)" }
            xi.append(Int(v))
        }
        if !p.feasible(xi) { return "INFEASIBLE POINT \(xi) reported \(statusName(st))" }
        guard let best = bf.best else { return "enumeration says infeasible but point \(xi) is feasible?!" }
        let got = p.objInt(xi)
        let expectObj = p.reported(got)
        if let ob = o.objective, abs(ob - expectObj) > 1e-9 * max(1, abs(expectObj)) {
            return "objectiveValue \(ob) != objective of its own point \(expectObj)"
        }
        if case .optimal = st, got != best {
            return "NON-OPTIMAL .optimal: got int \(got) (\(expectObj)) true \(best) (\(p.reported(best))) bound \(String(describing: o.bound))"
        }
        if let b = o.bound {
            let trueOpt = p.reported(best)
            // a bound must never be beyond the true optimum
            if p.maximize ? (b < trueOpt - 1e-9 * max(1, abs(trueOpt))) : (b > trueOpt + 1e-9 * max(1, abs(trueOpt))) {
                return "INVALID BOUND \(b) vs true optimum \(trueOpt) (status \(statusName(st)))"
            }
        }
        if case .feasible = st { return "LIMIT feasible on tiny model after \(o.seconds)s" }
        return nil
    case .noSolution:
        return "LIMIT noSolution after \(o.seconds)s"
    default:
        return "unexpected status \(statusName(st))"
    }
}

switch mode {
case "sat", "unsat":
    // sat <dir> [first] [count] [configIndex]
    let dir = arg(2, "")
    let files = listCNF(dir)
    let first = Int(arg(3, "0"))!
    let count = Int(arg(4, "100000"))!
    let ci = Int(arg(5, "2"))!
    let (cname, solver) = configs[ci]
    var bad = 0
    var done = 0
    var maxSec = 0.0
    var totalConf = 0
    let t0 = Date()
    for file in files.dropFirst(first).prefix(count) {
        let f = parseDIMACS(try! String(contentsOfFile: file, encoding: .utf8))
        let lp = cnfToLP(f)
        let o = await runCP(lp, solver, timeLimit: 60)
        done += 1
        maxSec = max(maxSec, o.seconds)
        totalConf += o.conflicts
        let name = (file as NSString).lastPathComponent
        if mode == "sat" {
            guard case .optimal? = o.status, let x = o.primal else {
                bad += 1; print("FAIL \(name): status \(statusName(o.status)) \(o.error ?? "")"); continue
            }
            if let k = cnfSatisfied(f, x) { bad += 1; print("FAIL \(name): model violates clause \(k) \(f.clauses[k])") }
        } else {
            guard case .infeasible? = o.status else {
                bad += 1
                var extra = ""
                if let x = o.primal { extra = cnfSatisfied(f, x).map { "violates clause \($0)" } ?? "MODEL SATISFIES ALL CLAUSES" }
                print("FAIL \(name): status \(statusName(o.status)) \(extra) \(o.error ?? "")"); continue
            }
        }
    }
    print("\(mode) \(cname): \(done) instances, \(bad) failures, max \(String(format: "%.2f", maxSec)) s, total \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, conflicts \(totalConf)")

case "dpll":
    // dpll <dir> <first> <count>: independent DPLL verdicts on a corpus sample
    let files = listCNF(arg(2, ""))
    let first = Int(arg(3, "0"))!
    let count = Int(arg(4, "10"))!
    var sat = 0, unsat = 0, unknown = 0
    for file in files.dropFirst(first).prefix(count) {
        let f = parseDIMACS(try! String(contentsOfFile: file, encoding: .utf8))
        let r = dpll(f)
        switch r.sat {
        case true?:
            if let m = r.model, cnfSatisfied(f, m.map { $0 ? 1 : 0 }) == nil { sat += 1 } else { print("DPLL model invalid on \(file)") }
        case false?: unsat += 1
        default: unknown += 1
        }
    }
    print("dpll: sat \(sat) unsat \(unsat) unknown \(unknown)")

case "rand3sat":
    // rand3sat <seed> <count> <nmin> <nmax>
    let seed = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "200"))!
    let nmin = Int(arg(4, "10"))!
    let nmax = Int(arg(5, "40"))!
    var rng = RNG(seed)
    var stats = [String: Int]()
    var fails = 0
    for k in 0..<count {
        let n = rng.int(nmin, nmax)
        let ratio = 3.8 + Double(rng.int(0, 10)) * 0.1   // 3.8 .. 4.8
        let m = Int((Double(n) * ratio).rounded())
        let f = random3SAT(vars: n, clauses: m, rng: &rng)
        let truth = dpll(f)
        guard let t = truth.sat else { stats["dpllUnknown", default: 0] += 1; continue }
        if n <= 18 {
            // brute force validates the DPLL oracle itself
            var any = false
            for mask in 0..<(1 << n) {
                let x = (0..<n).map { Double((mask >> $0) & 1) }
                if cnfSatisfied(f, x) == nil { any = true; break }
            }
            if any != t { print("ORACLE BUG: dpll \(t) brute \(any) on \(f.clauses)"); stats["oracleBug", default: 0] += 1 }
            stats["bruteChecked", default: 0] += 1
        }
        stats[t ? "sat" : "unsat", default: 0] += 1
        let ci = k % configs.count
        let (cname, solver) = configs[ci]
        let o = await runCP(cnfToLP(f), solver, timeLimit: 20)
        var verdict = ""
        switch o.status {
        case .optimal?:
            if let x = o.primal, cnfSatisfied(f, x) == nil { verdict = t ? "" : "CP says SAT with valid model but DPLL says UNSAT (oracle bug?)" }
            else { verdict = "CP model violates a clause" }
        case .infeasible?:
            if t { verdict = "FALSE UNSAT" }
        default:
            verdict = "status \(statusName(o.status)) \(o.error ?? "")"
        }
        if !verdict.isEmpty {
            fails += 1
            print("FAIL #\(k) n=\(n) m=\(m) cfg=\(cname): \(verdict)")
            print("  clauses: \(f.clauses)")
        }
    }
    print("rand3sat seed \(seed): \(count) formulas \(stats), failures \(fails)")

case "enum":
    // enum <seed> <count> [maxExp] [costExpMax] [binaryOnly] [bigCoefs]
    let seed = UInt64(arg(2, "1"))!
    let count = Int(arg(3, "100"))!
    var o = GenOptions()
    o.maxExp = Int(arg(4, "6"))!
    o.costExpMax = Int(arg(5, "0"))!
    o.binaryOnly = arg(6, "0") == "1"
    o.bigCoefs = arg(7, "0") == "1"
    var rng = RNG(seed)
    var fails = 0
    var limits = 0
    var infeasibleCount = 0
    var solves = 0
    for k in 0..<count {
        let p = randomIP(&rng, o)
        let bf = p.bruteForce()
        if bf.best == nil { infeasibleCount += 1 }
        let lp = p.lp()
        for (cname, solver) in configs {
            let out = await runCP(lp, solver, timeLimit: 10)
            solves += 1
            if let msg = judge(p, out, bf) {
                if msg.hasPrefix("LIMIT") { limits += 1; print("limit #\(k) \(cname): \(msg)"); continue }
                fails += 1
                print("FAIL seed \(seed) #\(k) cfg \(cname): \(msg)")
                print(p.describe())
            }
        }
    }
    print("enum seed \(seed) count \(count) maxExp \(o.maxExp) costExp \(o.costExpMax) binary \(o.binaryOnly) big \(o.bigCoefs): \(solves) solves, \(infeasibleCount) infeasible models, \(fails) failures, \(limits) limit hits")

case "domain":
    await domainProbes()
case "gap":
    await gapProbes()
case "dioph":
    await diophantineProbes(count: Int(arg(2, "100"))!, seed: UInt64(arg(3, "1"))!, verbose: arg(4, "0") == "1", onlyIndex: Int(arg(5, "x")))
case "invariance":
    await invarianceProbes(count: Int(arg(2, "20"))!, seed: UInt64(arg(3, "1"))!)
case "pingpong":
    // pingpong a b c U cfg limit [budget]
    await pingPong(a: Double(arg(2, "652"))!, b: Double(arg(3, "552"))!, c: Double(arg(4, "-1505"))!, U: Double(arg(5, "1e9"))!, cfg: arg(6, "detnolp"), limit: Double(arg(7, "2"))!, budget: Int(arg(8, "x")))
case "pingcancel":
    let lp = makeLP(xl: [0, 0], xu: [1e9, 1e9], rows: [([(0, 652), (1, -552)], -1505, -1505)], cost: [1, 0])
    let task = Task { () -> String in
        var ctx = SolveContext(); ctx.timeLimit = 60
        let r = try? await CPSAT(deterministic: true).solve(lp, context: ctx)
        return statusName(r?.status)
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
    let tc = Date()
    task.cancel()
    print("cancelled at 0.5 s; waiting...")
    let st = await task.value
    print("[pingcancel] returned \(st) \(String(format: "%.3f", Date().timeIntervalSince(tc))) s after cancel")
case "strip":
    // x - y >= 1 and x - y <= 0 over [0, U]^2: infeasible, no rounding involved
    let U = Double(arg(2, "1e7"))!
    let lp = makeLP(xl: [0, 0], xu: [U, U], rows: [([(0, 1), (1, -1)], 1, inf), ([(0, 1), (1, -1)], -inf, 0)], cost: [1, 1])
    let (r, err, _, wall) = await solveRecorded(lp, CPSAT(deterministic: true), limit: 1)
    print("[strip U=\(U)] \(statusName(r?.status)) \(err ?? "") wall \(String(format: "%.2f", wall)) s propagations \(r?.propagations ?? -1)")
case "min":
    await minimalRepros()
case "limits":
    await limitProbes()
case "miplib":
    // miplib <file.mps> <cfg default|nolp|det|detnolp> <limit>
    await miplib(arg(2, ""), arg(3, "default"), Double(arg(4, "60"))!)
default:
    print("modes: sat unsat dpll rand3sat enum domain gap")
}
