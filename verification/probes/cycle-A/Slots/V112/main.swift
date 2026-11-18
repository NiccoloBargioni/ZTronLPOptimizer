// Probe V112, cycle A: independent sceptic of finding A4-08 (lens: reproduce and contract).
// Question: can Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:241
// `memoryBudgetDegradesThenStops` fail when the memory budget is ignored, and is the
// "degrades" step observable (so a test could have asserted it)?
//
// Build: swift build --product V112 -c release
// Run:   perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V112 [test|oracle|scan|degrade|all]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let mode = CommandLine.arguments.dropFirst().first ?? "all"

/// The instance of the test (BranchAndBoundLimitsTests.hardInstance).
let lp = InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1)

/// The test's predicate, line 246, evaluated on a status.
func testPredicate(_ s: SolveStatus) -> Bool { s.stopReason == .memoryBudget || s == .optimal }

struct Row {
    var status: SolveStatus
    var objective: Double?
    var nodes: Int
    var open: Int
    var iterations: Int
    var wall: Double
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.6g", $0) } ?? "nil" }
func budgetName(_ b: Int?) -> String { b.map(String.init) ?? "nil(=25% RAM)" }

func solve<E: NodeLPStrategy>(
    _ s: BranchAndBound<E>, budget: Int?, threads: Int? = nil, timeLimit: Double = 120
) async throws -> Row {
    var ctx = SolveContext()
    ctx.timeLimit = timeLimit
    ctx.threads = threads
    ctx.memoryBudgetBytes = budget
    ctx.metal = .off
    let t0 = Date()
    let a = try await s.solve(lp, context: ctx)
    return Row(status: a.status, objective: a.objectiveValue, nodes: a.nodesProcessed, open: a.nodesOpen,
               iterations: a.lpIterations, wall: Date().timeIntervalSince(t0))
}

func line(_ tag: String, _ b: Int?, _ r: Row) -> String {
    "\(tag) budget \(budgetName(b)): \(r.status) obj \(fmt(r.objective)) nodes \(r.nodes) open \(r.open) lpIter \(r.iterations) wall \(String(format: "%.2f", r.wall))s predicate(line246)=\(testPredicate(r.status))"
}

// The exact configuration of the test's first solve.
func testConfig() -> BranchAndBound<Simplex> { BranchAndBound(nodeSelection: .bestBound, heuristics: .none) }

var unbudgetedObjective: Double? = nil

if mode == "test" || mode == "all" {
    print("== 1. The test's own two solves (test config: nodeSelection .bestBound, heuristics .none; default threads)")
    for k in 1...3 {
        let r = try await solve(testConfig(), budget: 2_000)
        print(line("T1 run \(k)", 2_000, r))
    }
    let r2 = try await solve(BranchAndBound(), budget: 16 * 1024 * 1024)
    print(line("T2 default config", 16 * 1024 * 1024, r2) + " second expect(status == .optimal)=\(r2.status == .optimal)")

    print("== 2. What a solver that ignores the budget returns: the same solve with no binding budget")
    for b in [nil, Int.max] as [Int?] {
        let r = try await solve(testConfig(), budget: b)
        print(line("T1-unbudgeted", b, r))
        if unbudgetedObjective == nil { unbudgetedObjective = r.objective }
    }
}

if mode == "oracle" || mode == "all" {
    print("== 3. Independent optimum (CP-SAT, a different algorithm), pure binary model")
    var ctx = SolveContext()
    ctx.timeLimit = 120
    ctx.metal = .off
    let sat = try await CPSAT().solve(lp, context: ctx)
    print("CPSAT(): \(sat.status) obj \(fmt(sat.objectiveValue))")
    var ctx2 = ctx
    ctx2.threads = 1
    let sat2 = try await CPSAT(lpPropagator: false, deterministic: true).solve(lp, context: ctx2)
    print("CPSAT(lpPropagator: false, deterministic): \(sat2.status) obj \(fmt(sat2.objectiveValue))")
    if let u = unbudgetedObjective, let o = sat.objectiveValue {
        print("unbudgeted B&B obj \(fmt(u)) vs CP-SAT \(fmt(o)): agree=\(abs(u - o) <= 1e-6 * max(1, abs(o)))")
    }
}

let grid: [Int?] = [1, 500, 1_000, 1_500, 2_000, 2_500, 3_000, 4_000, 6_000, 8_000, 12_000, 16_000, 24_000,
                    32_000, 48_000, 64_000, 128_000, 256_000, 1_048_576, nil]

if mode == "scan" || mode == "all" {
    print("== 4. Test config over budgets: is the line-246 predicate ever false?")
    var falseCount = 0
    var firstOptimal: Int?? = .none
    for b in grid {
        let r = try await solve(testConfig(), budget: b)
        print(line("scan", b, r))
        if !testPredicate(r.status) { falseCount += 1 }
        if case .none = firstOptimal, r.status == .optimal { firstOptimal = .some(b) }
    }
    print("predicate false for \(falseCount) of \(grid.count) budgets; smallest budget in the grid that completes .optimal: \(firstOptimal.map { budgetName($0) } ?? "none")")
}

if mode == "degrade" || mode == "all" {
    print("== 5. Is the 'degrade' step observable through the public API? deterministic: true, threads 1")
    // Only the tree reads the budget in B&B (BranchAndBound.swift:208 -> SearchTree); over budget it
    // first strips parent states (SearchTree.swift:436-458), which changes warm starts but not
    // the answer. So an .optimal run whose path differs from the unbudgeted one has degraded.
    let det = { BranchAndBound(nodeSelection: .bestBound, heuristics: .none, deterministic: true) }
    let ref = try await solve(det(), budget: nil, threads: 1)
    print(line("det-ref", nil, ref))
    var degradedOptimal: [Int] = []
    for b in grid.dropLast() {
        let r = try await solve(det(), budget: b, threads: 1)
        let differs = r.iterations != ref.iterations || r.nodes != ref.nodes
        var tag = "det"
        if r.status == .optimal && differs { tag = "det DEGRADED-BUT-OPTIMAL"; degradedOptimal.append(b!) }
        if r.status == .optimal, let o = r.objective, let ro = ref.objective, abs(o - ro) > 1e-6 * max(1, abs(ro)) {
            tag += " WRONG-OBJECTIVE"
        }
        print(line(tag, b, r) + " differsFromUnbudgeted=\(differs)")
    }
    print("budgets where the run degraded (path changed) yet completed .optimal: \(degradedOptimal)")
}

if mode == "repeat" {
    print("== 6. Reproducibility of the degrade signature (deterministic: true, threads 1), 3 runs each")
    let det = { BranchAndBound(nodeSelection: .bestBound, heuristics: .none, deterministic: true) }
    for b in [nil, 64_000, 32_000, 24_000] as [Int?] {
        for k in 1...3 {
            let r = try await solve(det(), budget: b, threads: 1)
            print(line("det run \(k)", b, r))
        }
    }
}
