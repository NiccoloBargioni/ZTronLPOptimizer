import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

/// Reads a DIMACS file with an independent minimal parser (does not use the package's).
func independentParse(_ url: URL) -> (Int, [[Int]]) {
    let text = try! String(contentsOf: url, encoding: .utf8)
    var nv = 0
    var clauses: [[Int]] = []
    var current: [Int] = []
    var expected = 0
    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("c") { continue }
        if t.hasPrefix("%") { break }
        if t.hasPrefix("p") {
            let f = t.split(separator: " ").filter { !$0.isEmpty }
            nv = Int(f[2])!
            expected = Int(f[3])!
            continue
        }
        for tok in t.split(separator: " ").filter({ !$0.isEmpty }) {
            let v = Int(tok)!
            if v == 0 { clauses.append(current); current = [] } else { current.append(v) }
        }
    }
    if !current.isEmpty { clauses.append(current) }
    precondition(clauses.count == expected, "clause count mismatch in \(url.lastPathComponent): \(clauses.count) vs \(expected)")
    return (nv, clauses)
}

func checkModel(_ clauses: [[Int]], _ values: [Double]) -> Int? {
    for (k, c) in clauses.enumerated() {
        let sat = c.contains { l in l > 0 ? values[l - 1] > 0.5 : values[-l - 1] < 0.5 }
        if !sat { return k }
    }
    return nil
}

func runSAT(family: String, cfg: String, start: Int, count: Int, dpll: Bool) async {
    let files = Corpora.satlib(family)
    let strategy = config(cfg).strategy
    let expectSAT = family.hasPrefix("uf")
    var ok = 0, bad = 0, timeouts = 0
    var worst = 0.0
    let t0 = Date()
    let end = min(files.count, start + count)
    for url in files[start..<end] {
        let (nv, clauses) = independentParse(url)
        // Cross-check the package's parser too.
        let formula = try! DIMACS.read(contentsOf: url)
        if formula.variables != nv || formula.clauses != clauses {
            print("PARSER-MISMATCH \(url.lastPathComponent)")
        }
        let lp = formula.compiled()
        let t = Date()
        let a: CPSATAnalysis
        do { a = try await strategy.solve(lp, context: ctx(30)) } catch {
            print("THROW \(url.lastPathComponent): \(error)"); bad += 1; continue
        }
        let dt = Date().timeIntervalSince(t)
        worst = max(worst, dt)
        var verdict = "ok"
        if expectSAT {
            if a.status == .optimal, let p = a.primal {
                if let k = checkModel(clauses, p) { verdict = "WRONG-MODEL clause \(k)" }
            } else if case .noSolution = a.status { verdict = "TIMEOUT"; timeouts += 1 } else { verdict = "WRONG-STATUS \(statusString(a.status))" }
        } else {
            if a.status == .infeasible {
                if dpll {
                    var d = DPLL(variables: nv, clauses: clauses)
                    if d.solve() { verdict = "FALSE-UNSAT (dpll found model)" }
                }
            } else if case .noSolution = a.status { verdict = "TIMEOUT"; timeouts += 1 } else {
                verdict = "WRONG-STATUS \(statusString(a.status))"
                if let p = a.primal, let k = checkModel(clauses, p) { verdict += " and model violates clause \(k)" }
            }
        }
        if verdict == "ok" { ok += 1 } else if verdict != "TIMEOUT" { bad += 1; print("\(url.lastPathComponent): \(verdict)") } else { print("\(url.lastPathComponent): \(verdict)") }
    }
    print("family=\(family) cfg=\(cfg) files=\(end - start) ok=\(ok) bad=\(bad) timeouts=\(timeouts) worst=\(String(format: "%.3f", worst))s total=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
}

func runRandom3SAT(n: Int, count: Int, seed: UInt64, cfg: String) async {
    let strategy = config(cfg).strategy
    var sat = 0, unsat = 0, bad = 0, timeouts = 0
    let clausesPerVar = [3.8, 4.0, 4.26, 4.5, 5.0]
    for k in 0..<count {
        let ratio = clausesPerVar[k % clausesPerVar.count]
        let m = Int((Double(n) * ratio).rounded())
        let f = CNFFormula.random3SAT(variables: n, clauses: m, seed: seed &* 1_000_003 &+ UInt64(k))
        var d = DPLL(variables: n, clauses: f.clauses)
        let truth = d.solve()
        if truth { precondition(f.isSatisfied(by: d.model)) }
        let a: CPSATAnalysis
        do { a = try await strategy.solve(f.compiled(), context: ctx(30)) } catch { print("THROW \(k): \(error)"); bad += 1; continue }
        switch a.status {
        case .optimal:
            if !truth { print("k=\(k) FALSE-SAT (dpll says unsat)"); bad += 1 }
            else if let p = a.primal, checkModel(f.clauses, p) != nil { print("k=\(k) BAD MODEL"); bad += 1 } else { sat += 1 }
        case .infeasible:
            if truth { print("k=\(k) FALSE-UNSAT"); bad += 1 } else { unsat += 1 }
        case .noSolution:
            timeouts += 1
        default:
            print("k=\(k) status \(statusString(a.status))"); bad += 1
        }
    }
    print("rand3sat n=\(n) count=\(count) seed=\(seed) cfg=\(cfg): sat=\(sat) unsat=\(unsat) bad=\(bad) timeouts=\(timeouts)")
}
