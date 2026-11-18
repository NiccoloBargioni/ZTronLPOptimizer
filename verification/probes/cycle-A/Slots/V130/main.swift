// V130: sceptic probe for finding A5-04 (CPSATAnalysis.winningWorker on parallel feasibility solves).
//
// The finder's oracle was the `source` of the single `.newIncumbent` event. This probe uses two
// oracles that do not depend on that event:
//   synthetic: n binaries, no rows, zero costs. Read from CPSAT.swift / CPWorker.swift / CPSearch.swift:
//     workers with index % 4 != 1 (lower-bound-first, or objective phase with all costs 0, which
//     prefers the lower end) can only produce the all-zero point; workers with index % 4 == 1 use
//     the random phase, whose point is replicated here from WorkerRandom (seeded shuffle of the
//     activities, then one next() & 1 per decision in activity order).
//   uf50: CPSAT(deterministic: true) is worker 0 of a parallel run (same index, seed, phase, order,
//     no relaxation for a clause model); clauses are exchanged only at restarts, so when the
//     deterministic run needs no restart, worker 0 of the parallel run, if it reports a solution,
//     reports exactly that point S0.
// The event source is recorded as well, only to cross-validate the oracles.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SolverEvent] = []
    var callback: @Sendable (SolverEvent) -> Void {
        { [self] e in lock.lock(); list.append(e); lock.unlock() }
    }
    func incumbentSources() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return list.compactMap { e -> String? in
            if case .newIncumbent(_, _, let s) = e { return s }
            return nil
        }
    }
}

func sourceIndex(_ sources: [String]) -> Int? {
    guard sources.count == 1, sources[0].hasPrefix("cpsat["), sources[0].hasSuffix("]") else { return nil }
    return Int(sources[0].dropFirst(6).dropLast())
}

/// Replica of WorkerRandom (CPWorker.swift).
struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

/// The first point worker `index` reaches on n binaries without rows or objective.
func predicted(index: Int, baseSeed: UInt64, n: Int) -> [Double] {
    if index % 4 != 1 { return [Double](repeating: 0, count: n) }
    var rng = Rng(seed: baseSeed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
    var act = [Double](repeating: 0, count: n)
    for x in 0..<n { act[x] = rng.uniform() * 1e-3 }      // index != 0: seeded shuffle
    let order = (0..<n).sorted { act[$0] != act[$1] ? act[$0] > act[$1] : $0 < $1 }  // max-heap, ties to lower index
    var v = [Double](repeating: 0, count: n)
    for x in order { v[x] = rng.next() & 1 == 1 ? 1 : 0 }
    return v
}

func runSynthetic(runs: Int, n: Int, workers: Int) async {
    let zeros = [Double](repeating: 0, count: n)
    let lp = CompiledLP(
        a: SparseCSC(rows: 0, cols: n), c: zeros, xl: zeros, xu: [Double](repeating: 1, count: n),
        rl: [], ru: [], integerColumns: (0..<n).map { Int32($0) })
    var total = 0, notOptimal = 0, contentMismatch = 0, eventMismatch = 0, oracleFail = 0, bothMismatch = 0
    var contentOnly = 0, eventOnly = 0
    var winnerHist = [Int: Int](), sourceHist = [Int: Int]()
    var examples: [String] = []
    for r in 0..<runs {
        let seed: UInt64 = r % 2 == 0 ? 0 : UInt64(r)
        let preds = (0..<workers).map { predicted(index: $0, baseSeed: seed, n: n) }
        let rec = Recorder()
        var c = SolveContext()
        c.timeLimit = 10
        c.progress = rec.callback
        let a: CPSATAnalysis
        do { a = try await CPSAT(workers: workers, seed: seed).solve(lp, context: c) } catch {
            print("run \(r): threw \(error)"); continue
        }
        total += 1
        guard a.status == .optimal, let p = a.primal else { notOptimal += 1; print("run \(r): status \(a.status)"); continue }
        let finders = Set((0..<workers).filter { preds[$0] == p })
        let sources = rec.incumbentSources()
        let src = sourceIndex(sources)
        let w = a.winningWorker
        winnerHist[w ?? -1, default: 0] += 1
        sourceHist[src ?? -1, default: 0] += 1
        if finders.isEmpty || src == nil || !finders.contains(src!) {
            oracleFail += 1
            print("ORACLE-FAIL run \(r) seed \(seed): finders=\(finders.sorted()) sources=\(sources) ones=\(Int(p.reduce(0, +)))")
        }
        let cm = w == nil || !finders.contains(w!)
        let em = src == nil || src != w
        if cm { contentMismatch += 1 }
        if em { eventMismatch += 1 }
        if cm && em { bothMismatch += 1 }
        if cm && !em { contentOnly += 1 }
        if em && !cm { eventOnly += 1 }
        if cm && examples.count < 6 {
            examples.append(
                "run \(r) seed \(seed): winningWorker=\(w.map(String.init) ?? "nil"); returned point has \(Int(p.reduce(0, +))) ones of \(n); workers whose own first point it is: \(finders.sorted()); .newIncumbent sources=\(sources)")
        }
    }
    for e in examples { print(e) }
    print("synthetic n=\(n) workers=\(workers): total=\(total) notOptimal=\(notOptimal) oracleFail=\(oracleFail) contentMismatch=\(contentMismatch) eventMismatch=\(eventMismatch) both=\(bothMismatch) contentOnly=\(contentOnly) eventOnly=\(eventOnly)")
    print("  winningWorker histogram: \(winnerHist.sorted { $0.key < $1.key })")
    print("  incumbent-source histogram: \(sourceHist.sorted { $0.key < $1.key })")
}

/// Own clause check (literal v > 0 true when x[v-1] == 1, v < 0 true when x[|v|-1] == 0).
func satisfies(_ clauses: [[Int]], _ x: [Double]) -> Bool {
    clauses.allSatisfy { clause in
        clause.contains { lit in lit > 0 ? x[lit - 1] == 1 : x[-lit - 1] == 0 }
    }
}

func runUF50(count: Int, repeats: Int, workers: Int) async {
    let files = Corpora.satlib("uf50-218")
    print("uf50-218 files available: \(files.count)")
    var runs = 0, invalid = 0, notOptimal = 0, eventMismatch = 0, multi = 0
    var eligible = 0, proven = 0, consistent = 0, noRestartFiles = 0
    var srcZeroEligible = 0, srcZeroMatchesS0 = 0
    var examples: [String] = []
    for url in files.prefix(count) {
        let f = try! DIMACS.read(contentsOf: url)
        let lp = f.compiled()
        var dc = SolveContext()
        dc.timeLimit = 30
        let d = try! await CPSAT(deterministic: true).solve(lp, context: dc)
        let s0 = d.primal
        let noRestart = d.status == .optimal && d.restarts == 0 && s0 != nil
        if noRestart { noRestartFiles += 1 }
        for _ in 0..<repeats {
            let rec = Recorder()
            var c = SolveContext()
            c.timeLimit = 30
            c.progress = rec.callback
            let a = try! await CPSAT(workers: workers).solve(lp, context: c)
            runs += 1
            guard a.status == .optimal, let p = a.primal else { notOptimal += 1; continue }
            if !satisfies(f.clauses, p) { invalid += 1 }
            let sources = rec.incumbentSources()
            if sources.count != 1 { multi += 1 }
            let src = sourceIndex(sources)
            let w = a.winningWorker
            if src == nil || src != w { eventMismatch += 1 }
            if noRestart, src == 0 {
                srcZeroEligible += 1
                if p == s0! { srcZeroMatchesS0 += 1 }
            }
            if noRestart, w == 0 {
                eligible += 1
                if p == s0! {
                    consistent += 1
                } else {
                    proven += 1
                    if examples.count < 8 {
                        let hamming = zip(p, s0!).filter { $0 != $1 }.count
                        examples.append(
                            "\(url.lastPathComponent): winningWorker=0 but returned point differs from worker 0's point S0 in \(hamming) of \(p.count) variables (det run: \(d.conflicts) conflicts, \(d.restarts) restarts); .newIncumbent sources=\(sources); returned point satisfies CNF: \(satisfies(f.clauses, p)), S0 satisfies CNF: \(satisfies(f.clauses, s0!))")
                    }
                }
            }
        }
    }
    for e in examples { print(e) }
    print("uf50 workers=\(workers): files=\(min(count, files.count)) runs=\(runs) notOptimal=\(notOptimal) invalidPoint=\(invalid) multipleIncumbentEvents=\(multi) eventMismatch=\(eventMismatch)")
    print("  files whose deterministic run needs no restart: \(noRestartFiles)")
    print("  oracle validation: runs with source cpsat[0] on such files=\(srcZeroEligible), returned point == S0 in \(srcZeroMatchesS0)")
    print("  winningWorker==0 on such files: \(eligible); returned point == S0 (consistent) \(consistent); != S0 (proven mismatch) \(proven)")
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "synthetic"
func arg(_ i: Int, _ d: Int) -> Int { args.count > i ? (Int(args[i]) ?? d) : d }
switch mode {
case "synthetic":
    await runSynthetic(runs: arg(2, 200), n: arg(3, 64), workers: arg(4, 8))
case "uf50":
    await runUF50(count: arg(2, 100), repeats: arg(3, 1), workers: arg(4, 8))
case "rng":
    let n = arg(2, 16)
    for w in 0..<8 { print("worker \(w):", predicted(index: w, baseSeed: UInt64(arg(3, 0)), n: n).map { Int($0) }) }
default:
    print("usage: V130 synthetic [runs n workers] | uf50 [count repeats workers] | rng [n seed]")
}
