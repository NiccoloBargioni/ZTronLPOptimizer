import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

enum Api2Probe {
    enum V: LPVariable { case a, b, c, ghost }
    static func run() async throws {
        print("Simplex() default method dual:", Simplex().method == .dual)
        // Portfolio with no strategies: README "an empty list throws .unsupported".
        do {
            let empty: [any SolverStrategy] = []
            _ = try await Portfolio(empty).solve(try NetlibFixtures.load("afiro"))
            print("Portfolio([]) did not throw")
        } catch { print("Portfolio([]) threw:", error) }
        // Solution.value(of:) for a variable the model does not contain -> 0.
        let model = LPModel<V>().minimizing(V.a + V.b).subjectTo { (V.a + V.b >= 1).named("r") }
        let sol = try await Simplex().solve(model)
        print("value(of: ghost) =", sol.value(of: .ghost), " reducedCost(of: ghost) =", sol.reducedCost(of: .ghost), " dual(nope) =", String(describing: sol.dual(ofConstraintNamed: "nope")))
        // Event stream: newest 256 events kept, .finished last and unique; simplex iterations at most every 100.
        let lp = try NetlibFixtures.load("degen2")
        var ctx = SolveContext()
        let stream = ctx.makeEventStream()
        let an = try await Simplex(.primal).solve(lp, context: ctx)
        var events: [SolverEvent] = []
        for await e in stream { events.append(e) }
        let iterEvents = events.filter { if case .simplexIteration = $0 { return true } else { return false } }.count
        print("degen2 primal: iterations \(an.iterations), events \(events.count), simplexIteration events \(iterEvents), finished count \(events.filter(\.isFinished).count), last finished \(events.last?.isFinished == true)")
        // SparseCSC.fromTriplets: duplicates summed, zeros dropped.
        let m = SparseCSC.fromTriplets(rows: 2, cols: 2, [(row: 0, col: 0, value: 1), (row: 0, col: 0, value: 2), (row: 1, col: 1, value: 0), (row: 1, col: 0, value: 3), (row: 1, col: 0, value: -3)])
        print("fromTriplets nnz \(m.nnz) (expect 1), a00 \(m[0, 0]) (expect 3)")
        // MemoryBudget.resolve(SolveContext()) is a quarter of the available memory.
        print("MemoryBudget.availableBytes \(MemoryBudget.availableBytes()) resolve(nil) \(MemoryBudget.resolve(SolveContext())) ratio \(Double(MemoryBudget.availableBytes()) / Double(MemoryBudget.resolve(SolveContext())))")
    }
}
