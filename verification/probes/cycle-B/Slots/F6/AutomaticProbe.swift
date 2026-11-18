// Automatic routing: thresholds, engine actually run, answer checked against a known optimum.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Cycle-cover LP: rows i: x_i + x_{(i+1) mod m} >= 1, x >= 0, min sum x. n = m (+1 optional dense column).
/// Optimum m/2 (x = 1/2 everywhere is optimal; for even m also alternating 0/1).
func cycleLP(m: Int, denseColumn: Bool) -> CompiledLP {
    var e: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m {
        e.append((i, i, 1)); e.append((i, (i + 1) % m, 1))
    }
    var n = m
    if denseColumn {
        // a column present in 40% of the rows, expensive so it stays at zero
        for i in 0..<m where i % 5 < 2 { e.append((i, m, 1)) }
        n += 1
    }
    let a = SparseCSC.fromTriplets(rows: m, cols: n, e)
    var c = [Double](repeating: 1, count: n)
    if denseColumn { c[m] = 1000 }
    return CompiledLP(a: a, c: c, xl: .init(repeating: 0, count: n), xu: .init(repeating: .infinity, count: n),
                      rl: .init(repeating: 1, count: m), ru: .init(repeating: .infinity, count: m))
}

func runAutomatic(_ args: [String]) async {
    let sizes: [(Int, Bool)] = args.isEmpty ? [(4000, false), (4001, false), (4002, true), (10_000, true), (10_002, false), (10_002, true)] : args.map { (Int($0)!, true) }
    for (m, dense) in sizes {
        let lp = cycleLP(m: m, denseColumn: dense)
        let choice = Automatic.choice(for: lp)
        var ctx = SolveContext()
        ctx.timeLimit = 120
        let t = nowNs()
        do {
            let a = try await Automatic().solve(lp, context: ctx)
            let pc = checkPrimal(lp, a)
            let expect = Double(m) / 2
            let err = a.objectiveValue.map { abs($0 - expect) / expect } ?? .infinity
            print("AUTO m=\(m) dense=\(dense) choice=\(choice) engine=\(a.engine) status=\(statusName(a.status)) obj=\(f(a.objectiveValue)) expected=\(expect) relErr=\(String(format: "%.1e", err)) \(pc?.description ?? "") t=\(String(format: "%.2f", secs(t)))")
        } catch {
            print("AUTO m=\(m) dense=\(dense) choice=\(choice) threw \(error)")
        }
    }
    // integer models: pure integer and mixed both go to BranchAndBound(Simplex(.primal))
    let ip = smallIP(seed: 5, rows: 5, cols: 10)
    if let a = try? await Automatic().solve(ip) {
        print("AUTO pure-integer choice=\(Automatic.choice(for: ip)) engine=\(a.engine) status=\(statusName(a.status)) obj=\(f(a.objectiveValue)) enum=\(f(enumerateOptimum(ip)))")
    }
    let mixed = InstanceGenerator.randomMILP(rows: 6, columns: 12, seed: 6, integerFraction: 0.5)
    if let a = try? await Automatic().solve(mixed) {
        print("AUTO mixed choice=\(Automatic.choice(for: mixed)) engine=\(a.engine) status=\(statusName(a.status)) obj=\(f(a.objectiveValue))")
    }
    // empty model and a model with zero rows
    let empty = CompiledLP(a: SparseCSC(rows: 0, cols: 0), c: [], xl: [], xu: [], rl: [], ru: [])
    do { let a = try await Automatic().solve(empty); print("AUTO empty: engine=\(a.engine) status=\(statusName(a.status)) obj=\(f(a.objectiveValue))") } catch { print("AUTO empty threw \(error)") }
    let noRows = CompiledLP(a: SparseCSC(rows: 0, cols: 2), c: [1, -1], xl: [0, 0], xu: [3, 4], rl: [], ru: [])
    do { let a = try await Automatic().solve(noRows); print("AUTO noRows (min x0 - x1, x in [0,3]x[0,4], expect -4): engine=\(a.engine) status=\(statusName(a.status)) obj=\(f(a.objectiveValue))") } catch { print("AUTO noRows threw \(error)") }
    do { let a = try await Portfolio([Simplex(.dual), InteriorPoint()]).solve(noRows); print("PORT noRows: \(describe(a))") } catch { print("PORT noRows threw \(error)") }
}
