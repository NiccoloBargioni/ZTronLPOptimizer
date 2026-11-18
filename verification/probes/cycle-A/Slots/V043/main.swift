// Cycle A, slot V043: sceptic of finding A2-05 (README section 5, ill-conditioned table,
// column "Answers with a warning"). Usage: V043 [table|detail] [maxOrder] [metal: off|auto]
//
// Three independent counts per order, each over the same 12 answers
// (4 Hilbert forms x Simplex(.dual), Simplex(.primal), InteriorPoint()):
//   observed  - answers whose `warnings` array is non-empty (what the column header names)
//   events    - answers for which a SolverEvent.warning arrived through SolveContext.progress
//   oracle    - prediction from the CompiledLP structure alone, by README section 4's rule
//               "a column with more than 30 % nonzeros makes the normal equations dense
//               (a warning says so)", applied to InteriorPoint() answers, plus the
//               conditioning warnings actually observed on the other warnings
// and the README value. "nonDense" = answers that keep a warning after removing the
// dense-column one, i.e. the count the README would show if it ignored that warning.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var finishedCount = 0
    func add(_ event: SolverEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .warning(let text): collected.append(text)
        case .finished: finishedCount += 1
        default: break
        }
    }
    var warnings: [String] { lock.lock(); defer { lock.unlock() }; return collected }
    var finished: Int { lock.lock(); defer { lock.unlock() }; return finishedCount }
}

func makeContext(_ box: EventBox, metal: MetalPolicy) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 30
    c.metal = metal
    c.progress = { box.add($0) }
    return c
}

/// Engine-independent structure: rows with at least one finite side, and columns whose
/// nonzero count exceeds 30 % of them (README section 4 rule, no size guard).
func structure(_ lp: CompiledLP) -> (rowsWithBound: Int, denseByReadmeRule: Int) {
    var kept = 0
    for i in 0..<lp.m where lp.rl[i].isFinite || lp.ru[i].isFinite { kept += 1 }
    var dense = 0
    for j in 0..<lp.n where Double(lp.a.colStart[j + 1] - lp.a.colStart[j]) > 0.3 * Double(kept) {
        dense += 1
    }
    return (kept, dense)
}

func isDenseColumnWarning(_ w: String) -> Bool { w.contains("more than 30%") && w.contains("normal equations") }
func classify(_ w: String) -> String {
    if isDenseColumnWarning(w) { return "DENSE" }
    if w.lowercased().contains("stall") { return "STALL" }
    if w.lowercased().contains("ill-conditioned") { return "ILLCOND" }
    return "OTHER"
}
func e2(_ v: Double) -> String { String(format: "%.1e", v) }

let readme: [Int: Int] = [3: 0, 4: 0, 5: 3, 6: 4, 7: 12, 8: 12, 9: 12, 10: 12, 11: 12, 12: 12]

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "table"
let maxOrder = args.count > 2 ? Int(args[2]) ?? 12 : 12
let metal: MetalPolicy = (args.count > 3 && args[3] == "auto") ? .automatic : .off
let minOrder = mode == "detail" ? maxOrder : 3

print("mode \(mode), orders \(minOrder)...\(maxOrder), metal \(metal)")
print("order | observed | events | oracle(readme-rule) | nonDense | readme | maxDist dual/primal/ipm | objErr | non-optimal | finished events")
for order in minOrder...maxOrder {
    var observed = 0, viaEvents = 0, nonDense = 0, oracle = 0, finishedEvents = 0
    var dist: [String: Double] = ["dual": 0, "primal": 0, "ipm": 0]
    var objErr = 0.0
    var bad: [String] = []
    var details: [String] = []
    for form in HilbertForm.allCases {
        let inst = InstanceGenerator.hilbert(order: order, form: form)
        let st = structure(inst.lp)
        let engines: [(String, any SolverStrategy)] = [
            ("dual", Simplex(.dual)), ("primal", Simplex(.primal)), ("ipm", InteriorPoint()),
        ]
        for (name, engine) in engines {
            let box = EventBox()
            do {
                let an = try await engine.solve(inst.lp, context: makeContext(box, metal: metal))
                let ws = an.warnings
                if !ws.isEmpty { observed += 1 }
                if !box.warnings.isEmpty { viaEvents += 1 }
                finishedEvents += box.finished
                let rest = ws.filter { !isDenseColumnWarning($0) }
                if !rest.isEmpty { nonDense += 1 }
                // Oracle: an IPM answer must warn when the README rule finds a dense column;
                // any other answer is predicted warned exactly when it carries a non-dense warning
                // (the conditioning warnings are not predicted structurally).
                let predictedDense = name == "ipm" && st.denseByReadmeRule > 0
                if predictedDense || !rest.isEmpty { oracle += 1 }
                if an.status != .optimal { bad.append("\(form.rawValue)/\(name):\(an.status)") }
                if let x = an.primal {
                    let d = x.map { abs($0 - 1) }.max() ?? .infinity
                    dist[name] = max(dist[name]!, d)
                } else { bad.append("\(form.rawValue)/\(name):no primal") }
                if let o = an.objectiveValue {
                    objErr = max(objErr, abs(o - inst.objective) / max(1, abs(inst.objective)))
                }
                details.append("  \(form.rawValue)/\(name): \(an.status) rowsWithBound \(st.rowsWithBound) denseColsReadmeRule \(st.denseByReadmeRule) hasDense(Automatic) \(Automatic.hasDenseColumn(inst.lp)) warnings \(ws.map(classify)) events \(box.warnings.map(classify))")
                if mode == "detail" { details.append("    text: \(ws)") }
            } catch {
                bad.append("\(form.rawValue)/\(name): threw \(error)")
            }
        }
    }
    print("\(order) | \(observed) of 12 | \(viaEvents) of 12 | \(oracle) of 12 | \(nonDense) of 12 | \(readme[order].map { "\($0) of 12" } ?? "-") | \(e2(dist["dual"]!))/\(e2(dist["primal"]!))/\(e2(dist["ipm"]!)) | \(e2(objErr)) | \(bad) | \(finishedEvents)")
    if mode == "detail" || order == 4 || order == 5 { details.forEach { print($0) } }
}
