import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// winningWorker vs the source of the reported solution, and best-incumbent consistency.
func runWinner(count: Int) async {
    let files = Corpora.satlib("uf50-218")
    var mismatch = 0, total = 0, multiSatisfied = 0
    for url in files.prefix(count) {
        let f = try! DIMACS.read(contentsOf: url)
        let rec = Recorder()
        var c = SolveContext()
        c.timeLimit = 30
        c.progress = rec.callback
        let a = try! await CPSAT(workers: 8).solve(f.compiled(), context: c)
        let sources = rec.events().compactMap { e -> String? in if case .newIncumbent(_, _, let s) = e { return s }; return nil }
        total += 1
        let w = a.winningWorker.map { "cpsat[\($0)]" } ?? "nil"
        if sources.count != 1 || sources[0] != w {
            mismatch += 1
            if mismatch <= 5 { print("\(url.lastPathComponent): winningWorker=\(w) incumbent sources=\(sources)") }
        }
        if sources.count > 1 { multiSatisfied += 1 }
    }
    print("winner: total=\(total) mismatch=\(mismatch) multipleIncumbents=\(multiSatisfied)")
    // Optimization: the reported objective equals the last newIncumbent event; events strictly improve.
    var bad = 0
    for name in ["p0033", "stein27", "lseu", "enigma"] {
        guard let lp = try! Corpora.loadMIPLIB3(name) else { continue }
        for _ in 0..<3 {
            let rec = Recorder()
            var c = SolveContext()
            c.timeLimit = 30
            c.progress = rec.callback
            let a = try! await CPSAT(workers: 8).solve(lp, context: c)
            let inc = rec.events().compactMap { e -> (Double, String)? in if case .newIncumbent(let o, _, let s) = e { return (o, s) }; return nil }
            let fin = rec.events().last.map { e -> Bool in if case .finished = e { return true }; return false } ?? false
            let monotone = zip(inc, inc.dropFirst()).allSatisfy { $0.0 > $1.0 }
            let lastMatches = inc.last?.0 == a.objectiveValue
            if !monotone || !lastMatches || !fin { bad += 1; print("\(name): monotone=\(monotone) lastMatches=\(lastMatches) finishedLast=\(fin) obj=\(a.objectiveValue ?? .nan) last=\(inc.last?.0 ?? .nan)") }
        }
    }
    print("incumbent-consistency bad=\(bad)")
}
