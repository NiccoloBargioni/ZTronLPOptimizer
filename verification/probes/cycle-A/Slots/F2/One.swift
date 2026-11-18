import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// One KKT instance, one configuration, in detail. Args: seed m n max(0/1) deg(0/1) spread cfgname
func runOne() async {
    let a = CommandLine.arguments
    let seed = UInt64(a[2])!, m = Int(a[3])!, n = Int(a[4])!
    let inst = makeKKT(m: m, n: n, seed: seed, maximize: a[5] == "1", degenerate: a[6] == "1", scaleSpread: Double(a[7])!)
    let names = Set(a[8...])
    var amin = Double.infinity, amax = 0.0
    for v in inst.lp.a.values where v != 0 { amin = min(amin, abs(v)); amax = max(amax, abs(v)) }
    print("\(inst.label): |a| in [\(fmt(amin)), \(fmt(amax))], expected objective \(inst.objective)")
    for cfg in configGrid() where names.contains(cfg.name) || names.contains("all") {
        let an = try! await cfg.s.solve(inst.lp, context: ctx())
        let v = an.primal.map { inst.lp.maxViolation(at: $0) }
        let margin = an.dualRay.map { farkasMargin(inst.lp, $0) }
        print("\(cfg.name): \(an.status) obj \(an.objectiveValue.map { "\($0)" } ?? "nil") viol \(v.map { "\(fmt($0.bounds))/\(fmt($0.rows))" } ?? "-") iters \(an.iterations) farkas \(margin.map { "\($0)" } ?? "-") warnings \(an.warnings)")
    }
}
