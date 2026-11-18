// DIMACS CNF reader (specification §14.2: CDCL on SATLIB uf50 / uuf50).
//
// A satisfiability instance becomes a pure 0–1 program: one binary column per variable, one
// row Σ ℓᵢ ≥ 1 per clause and no objective. CP-SAT recognizes rows of that form and stores
// them as clauses, so a CNF file exercises the CDCL core end to end.

import Foundation
import ZTronLPCore

/// A formula in conjunctive normal form.
public struct CNFFormula: Sendable, Hashable {
    /// The number of variables; they are numbered from 1.
    public let variables: Int
    /// Each clause is a list of nonzero literals: `+v` for variable v, `−v` for its negation.
    public let clauses: [[Int]]

    public init(variables: Int, clauses: [[Int]]) {
        self.variables = variables
        self.clauses = clauses
    }

    /// Whether the assignment (`assignment[v − 1]` is the value of variable v) satisfies every clause.
    public func isSatisfied(by assignment: [Bool]) -> Bool {
        guard assignment.count >= variables else { return false }
        for clause in clauses {
            let satisfied = clause.contains { literal in
                literal > 0 ? assignment[literal - 1] : !assignment[-literal - 1]
            }
            if !satisfied { return false }
        }
        return true
    }

    /// Whether a 0/1 point, as a solver returns it, satisfies every clause.
    public func isSatisfied(byValues values: [Double]) -> Bool {
        isSatisfied(by: values.map { $0 > 0.5 })
    }

    /// The first clause the assignment violates, for diagnostics.
    public func firstViolatedClause(by assignment: [Bool]) -> Int? {
        for (index, clause) in clauses.enumerated() {
            let satisfied = clause.contains { literal in
                literal > 0 ? assignment[literal - 1] : !assignment[-literal - 1]
            }
            if !satisfied { return index }
        }
        return nil
    }

    /// The formula as a pure 0–1 program with a zero objective.
    ///
    /// A clause with positive literals P and negative literals N is the row
    /// `Σ_{v ∈ P} x_v − Σ_{v ∈ N} x_v ≥ 1 − |N|`, that is Σ ℓᵢ ≥ 1 with ℓ = x or 1 − x.
    /// Repeated literals are merged and a clause that contains a variable in both polarities
    /// is dropped, since it is always true. An empty clause becomes an empty row that demands
    /// 0 ≥ 1, which makes the program infeasible, as it should.
    public func compiled() -> CompiledLP {
        var entries: [(row: Int, col: Int, value: Double)] = []
        var rl: [Double] = []
        var row = 0
        for clause in clauses {
            var sign: [Int: Double] = [:]
            var order: [Int] = []
            var tautology = false
            for literal in clause {
                let variable = Swift.abs(literal) - 1
                let s: Double = literal > 0 ? 1 : -1
                if let existing = sign[variable] {
                    if existing != s { tautology = true }
                } else {
                    sign[variable] = s
                    order.append(variable)
                }
            }
            if tautology { continue }
            var negatives = 0.0
            for variable in order {
                let s = sign[variable] ?? 1
                entries.append((row, variable, s))
                if s < 0 { negatives += 1 }
            }
            rl.append(1 - negatives)
            row += 1
        }
        let n = variables
        return CompiledLP(
            a: SparseCSC.fromTriplets(rows: row, cols: n, entries),
            c: [Double](repeating: 0, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
            rl: rl, ru: [Double](repeating: .infinity, count: row),
            integerColumns: (0..<n).map { Int32($0) })
    }

    /// A uniform random 3-SAT formula: every clause has three distinct variables with random
    /// signs. At `clauses / variables ≈ 4.26` such formulas sit at the satisfiability threshold,
    /// which is where SATLIB's uf / uuf families were drawn from.
    public static func random3SAT(variables: Int, clauses: Int, seed: UInt64) -> CNFFormula {
        precondition(variables >= 3, "3-SAT needs at least three variables")
        var rng = SeededGenerator(seed: seed)
        var result: [[Int]] = []
        result.reserveCapacity(clauses)
        for _ in 0..<clauses {
            var chosen: [Int] = []
            while chosen.count < 3 {
                let v = rng.integer(in: 1...variables)
                if !chosen.contains(v) { chosen.append(v) }
            }
            result.append(chosen.map { rng.chance(0.5) ? $0 : -$0 })
        }
        return CNFFormula(variables: variables, clauses: result)
    }
}

public enum DIMACS {
    /// Parses a DIMACS CNF document.
    ///
    /// Comment lines start with `c`; the problem line is `p cnf <variables> <clauses>`; clauses
    /// are whitespace-separated literals terminated by `0` and may span lines. SATLIB files end
    /// with a `%` line followed by a lone `0`: everything from the `%` on is ignored.
    public static func parse(_ text: String) throws -> CNFFormula {
        var declaredVariables: Int? = nil
        var declaredClauses: Int? = nil
        var clauses: [[Int]] = []
        var current: [Int] = []
        var largest = 0
        var lineNumber = 0
        func syntax(_ message: String) -> SolverError {
            .invalidModel(ModelDiagnostic(
                severity: .error, kind: .syntax(line: lineNumber, message: message),
                message: "line \(lineNumber): \(message)"))
        }
        lines: for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            switch line.first {
            case "c":
                continue
            case "%":
                break lines
            case "p":
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard tokens.count >= 4, tokens[1] == "cnf", let v = Int(tokens[2]), let c = Int(tokens[3]), v >= 0, c >= 0 else {
                    throw syntax("expected 'p cnf <variables> <clauses>'")
                }
                declaredVariables = v
                declaredClauses = c
            default:
                for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    guard let literal = Int(token) else { throw syntax("'\(token)' is not a literal") }
                    if literal == 0 {
                        clauses.append(current)
                        current.removeAll(keepingCapacity: true)
                    } else {
                        current.append(literal)
                        largest = Swift.max(largest, Swift.abs(literal))
                    }
                }
            }
        }
        if !current.isEmpty { clauses.append(current) }
        guard let variables = declaredVariables else {
            lineNumber = 0
            throw syntax("the problem line 'p cnf …' is missing")
        }
        guard largest <= variables else {
            throw syntax("literal \(largest) exceeds the declared \(variables) variables")
        }
        if let declared = declaredClauses, declared != clauses.count {
            throw syntax("the problem line declares \(declared) clauses but the file has \(clauses.count)")
        }
        return CNFFormula(variables: variables, clauses: clauses)
    }

    /// Reads a DIMACS CNF file.
    public static func read(contentsOf url: URL) throws -> CNFFormula {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SolverError.invalidModel(ModelDiagnostic(
                severity: .error, kind: .syntax(line: 0, message: "the file is not text"),
                message: "the file is not text"))
        }
        return try parse(text)
    }

    /// Writes a formula as DIMACS CNF.
    public static func write(_ formula: CNFFormula) -> String {
        var lines = ["p cnf \(formula.variables) \(formula.clauses.count)"]
        for clause in formula.clauses {
            lines.append(clause.map(String.init).joined(separator: " ") + " 0")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
