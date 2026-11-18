import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Hungarian algorithm (min cost perfect matching), O(n³), the independent oracle.
func hungarian(_ cost: [[Double]]) -> Double {
    let n = cost.count
    var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
    var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: n + 1)
        var used = [Bool](repeating: false, count: n + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...n where !used[j] {
                let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                if minv[j] < delta { delta = minv[j]; j1 = j }
            }
            for j in 0...n {
                if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    var total = 0.0
    for j in 1...n { total += cost[p[j] - 1][j - 1] }
    return total
}

func assignmentLP(_ cost: [[Double]], maximize: Bool) -> CompiledLP {
    let n = cost.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    var c: [Double] = []
    for i in 0..<n { for j in 0..<n {
        let col = i * n + j
        entries.append((i, col, 1)); entries.append((n + j, col, 1))
        c.append(maximize ? -cost[i][j] : cost[i][j])
    } }
    let a = SparseCSC.fromTriplets(rows: 2 * n, cols: n * n, entries)
    return CompiledLP(a: a, c: c, sense: maximize ? .maximize : .minimize,
                      xl: [Double](repeating: 0, count: n * n), xu: [Double](repeating: .infinity, count: n * n),
                      rl: [Double](repeating: 1, count: 2 * n), ru: [Double](repeating: 1, count: 2 * n))
}

func kleeMinty(_ n: Int) -> CompiledLP {
    var entries: [(row: Int, col: Int, value: Double)] = []
    var ru: [Double] = []
    for i in 0..<n {
        for j in 0..<i { entries.append((i, j, pow(2, Double(i - j + 1)))) }
        entries.append((i, i, 1))
        ru.append(pow(5, Double(i + 1)))
    }
    let c = (0..<n).map { -pow(2, Double(n - 1 - $0)) }
    return CompiledLP(a: SparseCSC.fromTriplets(rows: n, cols: n, entries), c: c, sense: .maximize,
                      xl: [Double](repeating: 0, count: n), xu: [Double](repeating: .infinity, count: n),
                      rl: [Double](repeating: -.infinity, count: n), ru: ru)
}

/// C9: degenerate problems.
func runDegenerate() async {
    var bad: [String] = []
    var maxIters = 0
    let pricings: [(String, Simplex.Pricing)] = [("dantzig", .dantzig), ("devex", .devex), ("steep", .steepestEdge), ("partial", .partial(sections: 4))]
    let perts: [(String, Simplex.Perturbation)] = [("off", .off), ("always", .always), ("onStall", .onStall)]
    for n in [8, 15, 20] {
        let lp = kleeMinty(n)
        let expected = pow(5, Double(n))
        for method in [Simplex.Method.primal, .dual] {
            for (pn, p) in pricings {
                for (qn, q) in perts {
                    for pre in [true, false] {
                        let s = Simplex(method, pricing: p, perturbation: q, presolve: pre, scaling: .none)
                        let an = try! await s.solve(lp, context: ctx(30))
                        maxIters = max(maxIters, an.iterations)
                        let o = an.objectiveValue ?? .nan
                        if an.status != .optimal || abs(o - expected) > 1e-7 * expected {
                            bad.append("KM\(n) \(method) \(pn) \(qn) pre\(pre): \(an.status) \(o) vs \(expected) iters \(an.iterations)")
                        }
                    }
                }
            }
        }
    }
    print("Klee-Minty: bad \(bad.count), max iterations \(maxIters)")
    // Assignment LPs: heavily degenerate, many ties.
    var r = Rng(99)
    var assignBad: [String] = []
    var assignRuns = 0
    for n in [6, 12, 25, 40] {
        for trial in 0..<3 {
            let range = trial == 0 ? 0 : (trial == 1 ? 2 : 9)  // trial 0: all costs equal
            let cost = (0..<n).map { _ in (0..<n).map { _ in Double(r.int(0, range)) } }
            let opt = hungarian(cost)
            for maximize in [false, true] {
                let lp = assignmentLP(maximize ? cost.map { $0.map { -$0 } } : cost, maximize: maximize)
                let expected = maximize ? -opt : opt
                for method in [Simplex.Method.primal, .dual] {
                    for (pn, p) in pricings {
                        for (qn, q) in perts {
                            for f in [Simplex.Factorization.denseLU, .sparseQR] {
                                let s = Simplex(method, pricing: p, factorization: f, perturbation: q)
                                assignRuns += 1
                                do {
                                    let an = try await s.solve(lp, context: ctx(30))
                                    maxIters = max(maxIters, an.iterations)
                                    let o = an.objectiveValue ?? .nan
                                    if an.status != .optimal || abs(o - expected) > 1e-7 * max(1, abs(expected)) {
                                        assignBad.append("assign n\(n) range\(range) max\(maximize) \(method) \(pn) \(qn) \(f): \(an.status) \(o) vs \(expected) iters \(an.iterations)")
                                    } else {
                                        let ch = checkOptimal(lp, an, expected: expected)
                                        if ch.dualSignViolation > 1e-6 || ch.gap > 1e-7 || ch.primalViolation > 1e-6 {
                                            assignBad.append("assign n\(n) \(method) \(pn) \(qn) \(f): KKT dualSign \(fmt(ch.dualSignViolation)) gap \(fmt(ch.gap)) primal \(fmt(ch.primalViolation))")
                                        }
                                    }
                                } catch { assignBad.append("assign n\(n): threw \(error)") }
                            }
                        }
                    }
                }
            }
        }
    }
    print("assignment runs \(assignRuns), bad \(assignBad.count), max iterations overall \(maxIters)")
    for b in (bad + assignBad).prefix(40) { print("BAD", b) }
}
