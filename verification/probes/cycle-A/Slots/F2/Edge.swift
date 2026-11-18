import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func lpDense(c: [Double], rows: [[Double]], rl: [Double], ru: [Double], xl: [Double]? = nil, xu: [Double]? = nil,
             sense: ObjectiveSense = .minimize, c0: Double = 0) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() { for (j, v) in row.enumerated() where v != 0 { entries.append((i, j, v)) } }
    let flip: Double = sense == .maximize ? -1 : 1
    return CompiledLP(a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c.map { flip * $0 }, c0: flip * c0, sense: sense,
                      xl: xl ?? [Double](repeating: 0, count: n), xu: xu ?? [Double](repeating: .infinity, count: n), rl: rl, ru: ru)
}

/// Edge cases: inconsistent bounds, empty problems, presolve-solved problems and their duals.
func runEdge() async {
    let inf = Double.infinity
    var cases: [(String, CompiledLP, String)] = []   // name, lp, expected status
    // column with xl > xu, alone and with a row
    cases.append(("xl>xu no rows", CompiledLP(a: SparseCSC(rows: 0, cols: 2), c: [1, 1], xl: [0, 2], xu: [1, 1], rl: [], ru: []), "infeasible"))
    cases.append(("xl>xu with row", lpDense(c: [1, 1], rows: [[1, 1]], rl: [0], ru: [10], xl: [0, 2], xu: [5, 1]), "infeasible"))
    cases.append(("rl>ru row", lpDense(c: [1, 1], rows: [[1, 1]], rl: [3], ru: [1], xl: [0, 0], xu: [5, 5]), "infeasible"))
    cases.append(("rl>ru row, free cols", lpDense(c: [1, 1], rows: [[1, 1], [1, -1]], rl: [3, 0], ru: [1, 0], xl: [-inf, -inf], xu: [inf, inf]), "infeasible"))
    cases.append(("no columns, rows feasible", CompiledLP(a: SparseCSC(rows: 2, cols: 0), c: [], c0: 3, xl: [], xu: [], rl: [-1, -inf], ru: [1, 0]), "optimal"))
    cases.append(("no columns, row infeasible", CompiledLP(a: SparseCSC(rows: 1, cols: 0), c: [], xl: [], xu: [], rl: [1], ru: [2]), "infeasible"))
    cases.append(("no rows, unbounded col", CompiledLP(a: SparseCSC(rows: 0, cols: 2), c: [1, -1], xl: [0, 0], xu: [1, inf], rl: [], ru: []), "unbounded"))
    cases.append(("no rows, max unbounded col", CompiledLP(a: SparseCSC(rows: 0, cols: 2), c: [-1, -1], sense: .maximize, xl: [0, -inf], xu: [1, 0], rl: [], ru: []), "optimal"))
    cases.append(("max empty column unbounded", lpDense(c: [1, 1, 1], rows: [[1, 1, 0]], rl: [-inf], ru: [4], xl: [0, 0, 0], sense: .maximize), "unbounded"))
    cases.append(("free column, equality", lpDense(c: [1, 2], rows: [[1, 1]], rl: [3], ru: [3], xl: [-inf, 0], xu: [inf, inf]), "optimal"))
    cases.append(("all fixed, row slack", lpDense(c: [1, 2], rows: [[1, 1]], rl: [0], ru: [10], xl: [1, 2], xu: [1, 2]), "optimal"))
    cases.append(("all fixed, row violated", lpDense(c: [1, 2], rows: [[1, 1]], rl: [5], ru: [10], xl: [1, 2], xu: [1, 2]), "infeasible"))
    cases.append(("singleton rows max", lpDense(c: [3, 2], rows: [[1, 0], [0, 2], [1, 1]], rl: [-inf, -inf, -inf], ru: [4, 6, 5], sense: .maximize), "optimal"))
    cases.append(("free row only", lpDense(c: [1], rows: [[1]], rl: [-inf], ru: [inf], xl: [2], xu: [3]), "optimal"))
    cases.append(("degenerate tie max", lpDense(c: [1, 1], rows: [[1, 1], [1, 0], [0, 1]], rl: [-inf, -inf, -inf], ru: [2, 1, 1], sense: .maximize), "optimal"))
    cases.append(("tiny infeasibility 1e-6", lpDense(c: [1, 1], rows: [[1, 1], [1, 1]], rl: [-inf, 1 + 1e-6], ru: [1, inf], xl: [0, 0], xu: [inf, inf]), "infeasible"))
    cases.append(("huge bounds", lpDense(c: [-1, -1], rows: [[1, 1]], rl: [-inf], ru: [1e9], xl: [0, 0], xu: [1e10, 1e10]), "optimal"))
    let configs = configGrid(full: false)
    for (name, lp, expected) in cases {
        var statuses: [String: Int] = [:]
        var issues: [String] = []
        for cfg in configs {
            do {
                let an = try await cfg.s.solve(lp, context: ctx(10))
                let st: String
                switch an.status {
                case .optimal: st = "optimal"
                case .infeasible: st = "infeasible"
                case .unbounded: st = "unbounded"
                default: st = "\(an.status)"
                }
                statuses[st, default: 0] += 1
                if st != expected { issues.append("\(cfg.name): \(st)") }
                if st == "infeasible" {
                    if let ray = an.dualRay {
                        let mg = farkasMargin(lp, ray)
                        if !(mg > 1e-9) { issues.append("\(cfg.name): dual ray does not certify (margin \(mg), ray \(ray))") }
                    } else { issues.append("\(cfg.name): infeasible without dual ray") }
                }
                if st == "unbounded" {
                    if let ray = an.primalRay {
                        let (s, v) = rayCheck(lp, ray)
                        if !(s < -1e-9) || v > 1e-7 { issues.append("\(cfg.name): ray slope \(s) viol \(v) ray \(ray)") }
                    } else { issues.append("\(cfg.name): unbounded without primal ray") }
                }
                if st == "optimal" {
                    let ch = checkOptimal(lp, an, expected: nil)
                    if ch.primalViolation > 1e-7 || ch.dualSignViolation > 1e-7 || ch.gap > 1e-7 || !ch.missing.isEmpty || ch.logicalMismatch > 1e-9 {
                        issues.append("\(cfg.name): KKT primal \(fmt(ch.primalViolation)) dualSign \(fmt(ch.dualSignViolation)) gap \(fmt(ch.gap)) logical \(fmt(ch.logicalMismatch)) missing '\(ch.missing)' x \(an.primal ?? []) y \(an.dual ?? []) d \(an.reducedCosts ?? []) obj \(an.objectiveValue ?? .nan)")
                    }
                }
            } catch { issues.append("\(cfg.name): threw \(error)") }
        }
        print("CASE \(name) expected \(expected): \(statuses)")
        for i in Array(Set(issues)).sorted().prefix(6) { print("   ISSUE", i) }
        if issues.count > 6 { print("   ... \(issues.count) issues") }
    }
}
