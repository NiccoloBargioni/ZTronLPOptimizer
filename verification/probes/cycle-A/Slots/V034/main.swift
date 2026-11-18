// V034 — cycle A, sceptic of finding A2-02 (lens: REPRODUCE).
// Usage: V034 one [k] | grid [k] | det [k] [reps] | family | fresh [count] [seed0]
// Every solve has SolveContext.timeLimit set; run under perl alarm.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "one"
func iarg(_ i: Int, _ d: Int) -> Int { argv.count > i ? Int(argv[i]) ?? d : d }

func context(_ seconds: Double = 30, threads: Int? = nil) -> SolveContext {
    var c = SolveContext()
    c.timeLimit = seconds
    c.metal = .off
    c.threads = threads
    return c
}

/// The ray a result carries: the simplex's own, or the crossover simplex's for the IPM.
func rayOf(_ an: any SolutionAnalysis) -> [Double]? {
    if let s = an as? SimplexAnalysis { return s.dualRay }
    if let i = an as? InteriorPointAnalysis { return i.crossover?.dualRay }
    if let c = an as? ConditionedAnalysis<SimplexAnalysis> { return c.base.dualRay }
    return nil
}

/// Both signs of y through the exact Farkas value; the better one, normalised by ‖y‖∞.
func farkasBoth(_ inst: Instance, _ y: [Double]) -> (best: Double, sign: Int, relToTerms: Double) {
    let p = exactFarkas(a: inst.A, rl: inst.b, ru: inst.b, xl: inst.xl, xu: inst.xu, y: y)
    let q = exactFarkas(a: inst.A, rl: inst.b, ru: inst.b, xl: inst.xl, xu: inst.xu, y: y.map { -$0 })
    let best = p.value >= q.value ? p : q
    let norm = y.map { abs($0) }.max() ?? 0
    return (best.value / max(norm, 1e-300), best.sign, best.value / max(best.termScale, 1e-300))
}

/// Exact maximum violation of a point: rows (equalities) and bounds.
func violation(_ inst: Instance, _ x: [Double]) -> Double {
    let r = exactResidual(inst.A, x, inst.b).map { abs($0) }.max() ?? 0
    var bv = 0.0
    for j in 0..<inst.n { bv = max(bv, inst.xl[j] - x[j], x[j] - inst.xu[j]) }
    return max(r, bv)
}

func line(_ name: String, _ an: any SolutionAnalysis, _ inst: Instance, _ o: Oracle) -> String {
    var s = "  \(name): status \(an.status)"
    if let v = an.objectiveValue { s += " obj \(v) (objErr \(sci(abs(v - o.objective))))" }
    if let x = an.primal, x.count == inst.n {
        let d = zip(x, o.xStar).map { abs($0 - $1) }.max() ?? 0
        s += " |x-x*| \(sci(d)) viol \(sci(violation(inst, x)))"
    }
    if an.status == .infeasible {
        if let y = rayOf(an) {
            let f = farkasBoth(inst, y)
            s += " RAY exact Farkas (better sign) \(f.best) sign \(f.sign) [rel. to terms \(sci(f.relToTerms))] -> \(f.sign > 0 ? "CERTIFIES" : "certifies NOTHING")"
        } else {
            s += " RAY none"
        }
    }
    if let sa = an as? SimplexAnalysis { s += " iters \(sa.iterations) ph1 \(sa.phase1Iterations)" }
    s += " warnings \(an.warnings)"
    return s
}

func oracleReport(_ inst: Instance, _ o: Oracle) {
    print("\(inst.label): n \(inst.n), D spans 1e-\(inst.decades), sum(c) \(inst.c.reduce(0, +))")
    print("  my inverse: kappa1 \(sci(o.kappa1)) kappaInf \(sci(o.kappaInf)) kappa2 \(sci(o.kappa2)); ‖I − R·A‖∞ (exact entries) \(sci(o.normE))")
    print("  exact ‖b − A·1‖∞ \(sci(o.residualOfOnes)); rigorous bound ‖x* − 1‖∞ ≤ \(sci(o.distanceBound)) -> FEASIBLE (proven): \(o.feasible)")
    print("  refined x*: exact residual \(sci(o.xStarResidual)), max|x*−1| \(sci(o.xStar.map { abs($0 - 1) }.max() ?? .nan)), min x* \(o.xStar.min() ?? .nan), max x* \(o.xStar.max() ?? .nan), c·x* \(o.objective)")
}

// Every mode is a function: top-level code that built an existential array and awaited in a
// loop read uninitialized boxes here (MallocScribble 0xAA), so nothing runs at top level.
switch mode {
case "one":
    try await mode_one()
case "grid":
    try await mode_grid()
case "det":
    try await mode_det()
case "family":
    try await mode_family()
case "fresh":
    try await mode_fresh()
case "diag1", "diag2", "diag3":
    try await mode_diag1()
case "diag0":
    try await mode_diag0()
case "debug":
    try await mode_debug()
default:
    print("modes: one [k] | grid [k] | det [k] [reps] | family | fresh [count] [seed0]")
}
