// Cycle A, slot V098: contract-lens sceptic of finding A4-03 (objectiveStep treats a cost
// |c| <= 1e-9 as an integral 0, so whole-step pruning discards better solutions).
// Build: swift build --product V098 -c release   Run: .build/release/V098
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let INF = Double.infinity

func makeLP(
    c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double], xu: [Double], integer: [Int]
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) }
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c, c0: 0,
        sense: .minimize, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer.sorted().map { Int32($0) })
}

func f(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.10g", v)
}

func bb<E: NodeLPStrategy>(_ name: String, _ s: BranchAndBound<E>, _ lp: CompiledLP, threads: Int? = nil) async throws -> Double? {
    var ctx = SolveContext()
    ctx.timeLimit = 30
    ctx.threads = threads
    ctx.metal = .off
    let a = try await s.solve(lp, context: ctx)
    let x = (a.primal ?? []).prefix(2).map { f($0) }
    print("  \(name): \(a.status) obj \(f(a.objectiveValue)) bound \(f(a.bound)) gap \(f(a.gap)) x[0..1] \(x) nodes \(a.nodesProcessed) src \(a.incumbentHistory.map(\.source))")
    return a.objectiveValue
}

/// The finder's model, parameterised by the tiny cost eps: min x1 + eps*x2,
/// x1 + (eps/1.5)*x2 >= 0.5, x1 in {0,1}, x2 integer in [0, xu2]. Integer optimum 0.75 at
/// x1 = 0, x2 = 0.75/eps (when xu2 allows it); x1 = 1 gives 1.
func finderModel(eps: Double, xu2: Double = 1e9) -> CompiledLP {
    makeLP(c: [1, eps], rows: [[1, eps / 1.5]], rl: [0.5], ru: [INF], xl: [0, 0], xu: [1, xu2], integer: [0, 1])
}

/// Same trade-off, but every matrix coefficient is in [1, 1.5e3]: the factor eps/1.5 is
/// spread over a chain of zero-cost continuous columns w1, w2, w3 (zero-cost continuous
/// columns do not switch objectiveStep off). Columns: x1 (binary, cost 1), x2 (integer
/// [0,1e10], cost eps), w1, w2, w3 (continuous >= 0, cost 0).
///   x1 + w1 >= 0.5;  k*w1 - w2 <= 0;  1000*w2 - w3 <= 0;  1000*w3 - x2 <= 0,  k = 1.5e-6/eps
/// so w1 <= (eps/1.5)*x2. Optimum 0.75 at x1 = 0, w1 = 0.5, x2 = 0.75/eps.
func chainModel(eps: Double) -> CompiledLP {
    let k = 1.5e-6 / eps
    return makeLP(
        c: [1, eps, 0, 0, 0],
        rows: [[1, 0, 1, 0, 0], [0, 0, k, -1, 0], [0, 0, 0, 1000, -1], [0, -1, 0, 0, 1000]],
        rl: [0.5, -INF, -INF, -INF], ru: [INF, 0, 0, 0],
        xl: [0, 0, 0, 0, 0], xu: [1, 1e10, INF, INF, INF], integer: [0, 1])
}

enum V: LPVariable {
    case open, units
    var domain: VariableDomain {
        switch self {
        case .open: return .binary
        case .units: return .integer(.range(0...1e9))
        }
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"

if mode == "all" || mode == "repro" {
    print("E1 finder's model eps=1e-9 (true optimum 0.75 at (0, 7.5e8))")
    let lp = finderModel(eps: 1e-9)
    _ = try await bb("P-default", BranchAndBound(), lp)
    _ = try await bb("D-default", BranchAndBound(engine: Simplex(.dual)), lp)
    _ = try await bb("P-det", BranchAndBound(deterministic: true), lp)
    _ = try await bb("I-default", BranchAndBound(engine: InteriorPoint()), lp)
    _ = try await bb("D-mostfrac-noheur", BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none), lp)
    _ = try await bb("P-noheur", BranchAndBound(heuristics: .none), lp)
    // Oracle: the point and the LP with x1 fixed at 0 (a lower bound for that branch).
    print("  point (0, 7.5e8): maxViolation \(lp.maxViolation(at: [0, 7.5e8])) objective \(f(lp.objective(at: [0, 7.5e8])))")
    print("  point (1, 0):     maxViolation \(lp.maxViolation(at: [1, 0])) objective \(f(lp.objective(at: [1, 0])))")
    var ctx = SolveContext(); ctx.timeLimit = 30; ctx.metal = .off
    let fixed0 = try await Simplex(.dual).solve(lp.relaxed().withColumnBounds(xl: [0, 0], xu: [0, 1e9]), context: ctx)
    let fixed1 = try await Simplex(.dual).solve(lp.relaxed().withColumnBounds(xl: [1, 0], xu: [1, 1e9]), context: ctx)
    let root = try await Simplex(.dual).solve(lp.relaxed(), context: ctx)
    print("  LP x1=0: \(fixed0.status) obj \(f(fixed0.objectiveValue)) x \(fixed0.primal?.map { f($0) } ?? [])")
    print("  LP x1=1: \(fixed1.status) obj \(f(fixed1.objectiveValue)) x \(fixed1.primal?.map { f($0) } ?? [])")
    print("  LP root: \(root.status) obj \(f(root.objectiveValue)) x \(root.primal?.map { f($0) } ?? [])")
}

if mode == "all" || mode == "threshold" {
    print("E2 threshold scan, finder's model, x2 in [0,1e10]; optimum 0.75 for every eps")
    for eps in [5e-10, 1e-9, 1.0000001e-9, 1.1e-9, 2e-9, 1e-8] {
        print(" eps \(eps):")
        let lp = finderModel(eps: eps, xu2: 1e10)
        _ = try await bb("P-default", BranchAndBound(), lp)
        _ = try await bb("D-default", BranchAndBound(engine: Simplex(.dual)), lp)
    }
}

if mode == "all" || mode == "chain" {
    print("E3 well-scaled chain model (matrix coefficients in [1, 1.5e3]); optimum 0.75")
    for eps in [1e-9, 1.1e-9] {
        let lp = chainModel(eps: eps)
        let x2 = 0.75 / eps
        let pt = [0, x2, 0.5, 0.5 * 1.5e-6 / eps, 0.5 * 1.5e-6 / eps * 1000]
        print(" eps \(eps): point x2=\(f(x2)) maxViolation \(lp.maxViolation(at: pt)) objective \(f(lp.objective(at: pt)))")
        _ = try await bb("P-default", BranchAndBound(), lp)
        _ = try await bb("D-default", BranchAndBound(engine: Simplex(.dual)), lp)
        _ = try await bb("D-mostfrac-noheur", BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none), lp)
    }
}

if mode == "all" || mode == "gap" {
    print("E4 README risk 10 mitigation: a tighter Gap (finder's model, eps=1e-9)")
    let lp = finderModel(eps: 1e-9)
    _ = try await bb("P Gap(1e-9,1e-9)", BranchAndBound(gap: Gap(relative: 1e-9, absolute: 1e-9)), lp)
    _ = try await bb("P Gap(0,0)", BranchAndBound(gap: Gap(relative: 0, absolute: 0)), lp)
    _ = try await bb("D Gap(0,0)", BranchAndBound(engine: Simplex(.dual), gap: Gap(relative: 0, absolute: 0)), lp)
}

if mode == "all" || mode == "dsl" {
    print("E5 DSL path: LPModel compiled with default CompileOptions (dropTolerance 1e-14)")
    let model = LPModel<V>()
        .minimizing(1 * V.open + 1e-9 * V.units)
        .subjectTo { (V.open + (1e-9 / 1.5) * V.units >= 0.5).named("cover") }
    let compiled = try model.compile()
    print("  compiled c \(compiled.lp.c) diagnostics \(compiled.diagnostics.count)")
    var ctx = SolveContext(); ctx.timeLimit = 30; ctx.metal = .off
    let s1 = try await Automatic().solve(model, context: ctx)
    print("  Automatic: \(s1.status) obj \(f(s1.objectiveValue)) open \(s1.value(of: .open)) units \(s1.value(of: .units)) bound \(f(s1.analysis.bound)) engine \(s1.analysis.engine)")
    let s2 = try await BranchAndBound().solve(model, context: ctx)
    print("  BranchAndBound(): \(s2.status) obj \(f(s2.objectiveValue)) open \(s2.value(of: .open)) units \(s2.value(of: .units)) bound \(f(s2.analysis.bound))")
    let s3 = try await Conditioned(BranchAndBound()).solve(model, context: ctx)
    print("  Conditioned(BranchAndBound()): \(s3.status) obj \(f(s3.objectiveValue)) warnings \(s3.analysis.warnings.prefix(3))")
}
