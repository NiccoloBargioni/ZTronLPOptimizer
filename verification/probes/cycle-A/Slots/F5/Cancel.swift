import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func runCancel(name: String, cfg: String, after: Double, reps: Int) async {
    guard let lp = try! Corpora.loadMIPLIB3(name) else { print("missing"); return }
    let s = config(cfg).strategy
    var lat: [Double] = []
    for _ in 0..<reps {
        let task = Task { () -> (CPSATAnalysis?, Date) in
            var c = SolveContext()
            c.timeLimit = 120
            let a = try? await s.solve(lp, context: c)
            return (a, Date())
        }
        try? await Task.sleep(nanoseconds: UInt64(after * 1e9))
        let cancelAt = Date()
        task.cancel()
        let (a, done) = await task.value
        let ms = done.timeIntervalSince(cancelAt) * 1000
        lat.append(ms)
        print("cancel \(name) \(cfg): latency=\(String(format: "%.2f", ms)) ms status=\(a.map { statusString($0.status) } ?? "throw") obj=\(a?.objectiveValue ?? .nan)")
    }
    lat.sort()
    print("cancel summary: max=\(String(format: "%.2f", lat.last ?? .nan)) ms median=\(String(format: "%.2f", lat[lat.count / 2])) ms")
}
