import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

final class EventLog: @unchecked Sendable {
    let lock = NSLock()
    var events: [SolverEvent] = []
    func add(_ e: SolverEvent) { lock.lock(); events.append(e); lock.unlock() }
}

func maxDiff(_ a: [Double]?, _ b: [Double]?) -> Double {
    guard let a, let b else { return (a == nil && b == nil) ? 0 : .infinity }
    guard a.count == b.count else { return .infinity }
    var d = 0.0
    for k in 0..<a.count { d = max(d, abs(a[k] - b[k])) }
    return d
}

func compareConditioned<S: SolverStrategy>(_ name: String, _ inner: S, _ lp: CompiledLP, _ label: String) async throws -> Bool {
    let plain = try await inner.solve(lp, context: ctx())
    let wrapped = try await Conditioned(inner).solve(lp, context: ctx())
    let sameStatus = plain.status == wrapped.status
    let objDiff = (plain.objectiveValue != nil && wrapped.objectiveValue != nil) ? abs(plain.objectiveValue! - wrapped.objectiveValue!) : ((plain.objectiveValue == nil && wrapped.objectiveValue == nil) ? 0 : .infinity)
    let xDiff = maxDiff(plain.primal, wrapped.primal)
    let yDiff = maxDiff(plain.dual, wrapped.dual)
    let plainBasis = (plain as? any BasisProviding)?.finalBasis
    let wrappedBasis = (wrapped as? any BasisProviding)?.finalBasis
    let sameBasis = plainBasis == wrappedBasis
    let ok = sameStatus && objDiff <= 1e-9 * max(1, abs(plain.objectiveValue ?? 0)) && xDiff <= 1e-7 && sameBasis
    // The report's estimate, against the exact condition number of the basis it was given.
    var kappa = ""
    if let basis = wrappedBasis, lp.m <= 450 {
        let exact = exactKappa1(basisMatrix(lp, basis), lp.m)
        kappa = " basis kappa1 exact \(e(exact)) report \(wrapped.report.basisConditionEstimate.map { e($0) } ?? "nil")"
    }
    print("\(ok ? "SAME" : "DIFF") \(label) \(name): status \(statusName(plain.status))/\(statusName(wrapped.status)) dobj \(e(objDiff)) dx \(e(xDiff)) dy \(e(yDiff)) basis same \(sameBasis) outcome \(wrapped.report.basisAnalysis)\(kappa)")
    return ok
}

/// C8: Conditioned returns the inner engine's answer; numericalFailure produces the summary warning.
func probeConditioned(_ args: [String]) async throws {
    var diffs = 0
    for name in ["afiro", "sc105", "share2b", "israel", "degen2"] {
        let lp = try NetlibFixtures.load(name)
        if !(try await compareConditioned("IPM()", InteriorPoint(), lp, name)) { diffs += 1 }
        if !(try await compareConditioned("IPM(none)", InteriorPoint(crossover: .none), lp, name)) { diffs += 1 }
        if !(try await compareConditioned("Simplex(.dual)", Simplex(.dual), lp, name)) { diffs += 1 }
        if !(try await compareConditioned("Automatic()", Automatic(), lp, name)) { diffs += 1 }
    }
    for inst in InstanceGenerator.constructedSuite(count: 10, seed: 77, maxSize: (40, 80)) {
        if !(try await compareConditioned("IPM()", InteriorPoint(), inst.lp, "constructed \(inst.seed)")) { diffs += 1 }
    }
    for order in [5, 8, 10] {
        let lp = InstanceGenerator.hilbert(order: order, form: .equality).lp
        if !(try await compareConditioned("IPM()", InteriorPoint(), lp, "hilbert \(order)")) { diffs += 1 }
        if !(try await compareConditioned("IPM(none)", InteriorPoint(crossover: .none), lp, "hilbert \(order)")) { diffs += 1 }
    }
    print("Conditioned differences: \(diffs)")
    // numericalFailure: summary warning before .finished.
    let lp = InstanceGenerator.hilbert(order: 8, form: .equality).lp
    let log = EventLog()
    var c = ctx()
    c.progress = { log.add($0) }
    let a = try await Conditioned(InteriorPoint(crossover: .none)).solve(lp, context: c)
    let events = log.events
    let finishedIndex = events.firstIndex { $0.isFinished }
    let summaryIndex = events.firstIndex { if case .warning(let t) = $0, t == a.report.summary { return true }; return false }
    print("Conditioned(IPM(none)) on hilbert 8: \(statusName(a.status)); events \(events.count); summary warning at \(String(describing: summaryIndex)), finished at \(String(describing: finishedIndex)); finished count \(events.filter { $0.isFinished }.count)")
    print("summary: \(a.report.summary)")
    for ev in events { if case .warning(let t) = ev { print("  warning event: \(t.prefix(140))") } }
    // A crossover that does not end optimal: what basis does Conditioned analyze?
}
