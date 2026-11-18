// CPLEX LP format writer and reader (specification §3, §4.5).
//
// The writer emits the widely supported core of the format: an objective with an optional
// constant, single-sided constraints, a Bounds section and Generals / Binaries. A range row has
// no portable spelling in LP format, so it is written the way Gurobi and CPLEX write it: as an
// equality against an auxiliary column `Rg<row>` that carries the range as its bounds. The
// reader accepts everything the writer produces plus the usual keyword spellings and
// double-sided constraints.

import Foundation

public enum LPFormat {
    // MARK: - Writing

    /// Writes a problem in CPLEX LP format.
    public static func write(_ lp: CompiledLP) throws -> String {
        let n = lp.n
        let m = lp.m
        let columnNames = LPName.uniqued(lp.names.columns.map(lpName))
        var rowNames = LPName.uniqued(lp.names.rows.map(lpName))
        let takenColumns = Set(columnNames)
        // Row and column names live in separate namespaces in LP format, but keep them apart
        // from the generated range columns anyway.
        for i in 0..<m where takenColumns.contains("Rg" + rowNames[i]) { rowNames[i] += "_" }

        var out: [String] = []
        out.append("\\ Written by ZTronLPOptimizer")
        out.append(lp.sense == .maximize ? "Maximize" : "Minimize")

        let flip = lp.sense == .maximize
        var objective: [(Double, String)] = []
        for j in 0..<n where lp.c[j] != 0 { objective.append((flip ? -lp.c[j] : lp.c[j], columnNames[j])) }
        let constant = flip ? -lp.c0 : lp.c0
        appendWrapped(&out, label: "obj", terms: objective, constant: constant, tail: "")

        out.append("Subject To")
        var rangeColumns: [(name: String, lower: Double, upper: Double)] = []
        let aT = lp.aT
        for i in 0..<m {
            var terms: [(Double, String)] = []
            for p in aT.colStart[i]..<aT.colStart[i + 1] {
                terms.append((aT.values[p], columnNames[Int(aT.rowIndex[p])]))
            }
            let (lo, hi) = (lp.rl[i], lp.ru[i])
            if lo == hi {
                appendWrapped(&out, label: rowNames[i], terms: terms, constant: 0, tail: " = \(number(lo))")
            } else if lo == -.infinity && hi == .infinity {
                // A free row constrains nothing; keep it readable as a trivially true row.
                appendWrapped(&out, label: rowNames[i], terms: terms, constant: 0, tail: " >= -1e+30")
            } else if lo == -.infinity {
                appendWrapped(&out, label: rowNames[i], terms: terms, constant: 0, tail: " <= \(number(hi))")
            } else if hi == .infinity {
                appendWrapped(&out, label: rowNames[i], terms: terms, constant: 0, tail: " >= \(number(lo))")
            } else {
                let rangeName = "Rg" + rowNames[i]
                terms.append((-1, rangeName))
                rangeColumns.append((rangeName, lo, hi))
                appendWrapped(&out, label: rowNames[i], terms: terms, constant: 0, tail: " = 0")
            }
        }

        let isInteger = lp.integerMask()
        var bounds: [String] = []
        var binaries: [String] = []
        var generals: [String] = []
        for j in 0..<n {
            let (lo, hi) = (lp.xl[j], lp.xu[j])
            if isInteger[j] {
                if lo == 0 && hi == 1 {
                    binaries.append(columnNames[j])
                    continue
                }
                generals.append(columnNames[j])
            }
            if let line = boundLine(columnNames[j], lo, hi) { bounds.append(line) }
        }
        for range in rangeColumns {
            if let line = boundLine(range.name, range.lower, range.upper) { bounds.append(line) }
        }
        if !bounds.isEmpty {
            out.append("Bounds")
            out.append(contentsOf: bounds)
        }
        if !generals.isEmpty {
            out.append("Generals")
            appendNameList(&out, generals)
        }
        if !binaries.isEmpty {
            out.append("Binaries")
            appendNameList(&out, binaries)
        }
        out.append("End")
        return out.joined(separator: "\n") + "\n"
    }

    /// Maps a name to the LP-format alphabet. Brackets are not legal there, so `x[3,7]`
    /// becomes `x(3,7)`; a name may not start with a digit or a period, nor look like the
    /// start of an exponent.
    static func lpName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", ".", ",", "(", ")", "!", "#", "$", "%", "&", ";", "?", "@", "{", "}", "~", "'":
                scalars.append(scalar)
            case "[":
                scalars.append("(")
            case "]":
                scalars.append(")")
            default:
                scalars.append("_")
            }
        }
        var name = String(scalars)
        guard let first = name.unicodeScalars.first else { return "_" }
        var needsPrefix = false
        switch first {
        case "0"..."9", ".":
            needsPrefix = true
        case "e", "E":
            // "e5" would read as an exponent.
            let rest = name.unicodeScalars.dropFirst()
            if let second = rest.first, ("0"..."9").contains(second) || second == "+" || second == "-" {
                needsPrefix = true
            }
        default:
            break
        }
        if needsPrefix { name = "_" + name }
        // Every one-word section keyword the reader recognizes, plus the words with a meaning
        // inside a section. A name equal to one of them, alone on its line, would open a section.
        let reserved: Set<String> = [
            "free", "inf", "infinity", "st", "s.t.", "st.", "end", "bounds", "bound", "general", "generals", "gen",
            "integer", "integers", "int", "binary", "binaries", "bin", "max", "min", "maximize", "minimize",
            "maximum", "minimum",
        ]
        if reserved.contains(name.lowercased()) { name = "_" + name }
        return name
    }

    private static func number(_ value: Double) -> String {
        if value == .infinity { return "+inf" }
        if value == -.infinity { return "-inf" }
        return "\(value)"
    }

    private static func boundLine(_ name: String, _ lo: Double, _ hi: Double) -> String? {
        if lo == 0 && hi == .infinity { return nil }
        if lo == -.infinity && hi == .infinity { return " \(name) free" }
        if lo == hi { return " \(name) = \(number(lo))" }
        return " \(number(lo)) <= \(name) <= \(number(hi))"
    }

    /// Appends `label: terms + constant tail`, wrapped well below the format's 510-character
    /// line limit.
    private static func appendWrapped(
        _ out: inout [String], label: String, terms: [(Double, String)], constant: Double, tail: String
    ) {
        var line = " \(label):"
        var first = true
        func flushIfLong(_ addition: String) {
            if line.count + addition.count > 200 {
                out.append(line)
                line = "  "
            }
        }
        for (coefficient, name) in terms {
            let magnitude = Swift.abs(coefficient)
            var piece: String
            if first {
                piece = coefficient < 0 ? " -" : ""
            } else {
                piece = coefficient < 0 ? " -" : " +"
            }
            piece += magnitude == 1 ? " \(name)" : " \(magnitude) \(name)"
            flushIfLong(piece)
            line += piece
            first = false
        }
        if constant != 0 || first {
            let magnitude = Swift.abs(constant)
            let piece = first ? (constant < 0 ? " - \(magnitude)" : " \(magnitude)") : (constant < 0 ? " - \(magnitude)" : " + \(magnitude)")
            // An expression with no variables still needs something to the left of the operator.
            if !(first && !tail.isEmpty && constant == 0) {
                flushIfLong(piece)
                line += piece
            } else {
                line += " 0"
            }
        }
        line += tail
        out.append(line)
    }

    private static func appendNameList(_ out: inout [String], _ names: [String]) {
        var line = ""
        for name in names {
            if line.count + name.count > 200 {
                out.append(line)
                line = ""
            }
            line += " " + name
        }
        if !line.isEmpty { out.append(line) }
    }

    // MARK: - Reading

    /// Parses a CPLEX LP document: objective, constraints (single- or double-sided), Bounds,
    /// Generals and Binaries. Quadratic terms, SOS sets and semi-continuous variables are
    /// outside linear programming and throw `SolverError.unsupported`.
    public static func read(_ text: String) throws -> CompiledLP {
        var parser = Parser()
        return try parser.parse(text)
    }

    /// Reads an LP file.
    public static func read(contentsOf url: URL) throws -> CompiledLP {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SolverError.invalidModel(.error(.syntax(line: 0, message: "the file is not text")))
        }
        return try read(text)
    }

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case plus, minus, colon
        case lessEqual, greaterEqual, equal
    }

    private enum Section {
        case none, objective, constraints, bounds, generals, binaries, end
    }

    private struct Parser {
        var columnIndex: [String: Int] = [:]
        var columnNames: [String] = []
        var cost: [Double] = []
        var lower: [Double] = []
        var upper: [Double] = []
        var isInteger: [Bool] = []
        var sense = ObjectiveSense.minimize
        var constant = 0.0
        var rowNames: [String?] = []
        var rowLower: [Double] = []
        var rowUpper: [Double] = []
        var entries: [(row: Int, col: Int, value: Double)] = []

        func syntax(_ line: Int, _ message: String) -> SolverError {
            .invalidModel(.error(.syntax(line: line, message: message)))
        }

        mutating func column(_ name: String) -> Int {
            if let j = columnIndex[name] { return j }
            let j = columnNames.count
            columnIndex[name] = j
            columnNames.append(name)
            cost.append(0)
            lower.append(0)
            upper.append(.infinity)
            isInteger.append(false)
            return j
        }

        /// The section a line opens, if it is a section keyword.
        func sectionKeyword(_ line: String) -> (Section, ObjectiveSense?)? {
            let key = line.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            switch key {
            case "minimize", "minimum", "min": return (.objective, .minimize)
            case "maximize", "maximum", "max": return (.objective, .maximize)
            case "subject to", "such that", "st", "s.t.", "st.": return (.constraints, nil)
            case "bounds", "bound": return (.bounds, nil)
            case "general", "generals", "gen", "integer", "integers", "int": return (.generals, nil)
            case "binary", "binaries", "bin": return (.binaries, nil)
            case "end": return (.end, nil)
            default: return nil
            }
        }

        func isNameStart(_ c: Character) -> Bool {
            c.isLetter || "_!\"#$%&(),;?@'`{}~".contains(c)
        }

        /// Brackets are accepted inside a name, though not at its start: other writers (Gurobi)
        /// emit names such as `x[1,2]` verbatim. A bracket that starts a token still opens a
        /// quadratic expression, which is rejected.
        func isNameBody(_ c: Character) -> Bool {
            isNameStart(c) || c.isNumber || c == "." || c == "[" || c == "]"
        }

        func tokenize(_ line: Substring, lineNumber: Int) throws -> [Token] {
            var tokens: [Token] = []
            let characters = Array(line)
            var i = 0
            while i < characters.count {
                let c = characters[i]
                if c == " " || c == "\t" {
                    i += 1
                } else if c == "+" {
                    tokens.append(.plus)
                    i += 1
                } else if c == "-" {
                    tokens.append(.minus)
                    i += 1
                } else if c == ":" {
                    tokens.append(.colon)
                    i += 1
                } else if c == "<" || c == ">" || c == "=" {
                    // <=, =<, <, >=, =>, >, =
                    var op = String(c)
                    if i + 1 < characters.count, "<>=".contains(characters[i + 1]) {
                        op.append(characters[i + 1])
                        i += 1
                    }
                    i += 1
                    if op.contains("<") {
                        tokens.append(.lessEqual)
                    } else if op.contains(">") {
                        tokens.append(.greaterEqual)
                    } else {
                        tokens.append(.equal)
                    }
                } else if c.isNumber || c == "." {
                    var j = i
                    while j < characters.count, characters[j].isNumber || characters[j] == "." { j += 1 }
                    if j < characters.count, characters[j] == "e" || characters[j] == "E" {
                        var k = j + 1
                        if k < characters.count, characters[k] == "+" || characters[k] == "-" { k += 1 }
                        if k < characters.count, characters[k].isNumber {
                            while k < characters.count, characters[k].isNumber { k += 1 }
                            j = k
                        }
                    }
                    guard let value = Double(String(characters[i..<j])) else {
                        throw syntax(lineNumber, "'\(String(characters[i..<j]))' is not a number")
                    }
                    tokens.append(.number(value))
                    i = j
                } else if c == "[" || c == "^" || c == "*" {
                    throw SolverError.unsupported("quadratic terms in an LP file are outside linear programming")
                } else if isNameStart(c) {
                    var j = i
                    while j < characters.count, isNameBody(characters[j]) { j += 1 }
                    let name = String(characters[i..<j])
                    let lowered = name.lowercased()
                    if lowered == "inf" || lowered == "infinity" {
                        tokens.append(.number(.infinity))
                    } else {
                        tokens.append(.name(name))
                    }
                    i = j
                } else {
                    throw syntax(lineNumber, "unexpected character '\(c)'")
                }
            }
            return tokens
        }

        /// Parses `[sign] [number] name` terms and stand-alone numbers from `tokens[start...]`
        /// up to the next relational operator or the end.
        mutating func expression(
            _ tokens: [Token], from start: Int, line: Int
        ) throws -> (terms: [(col: Int, value: Double)], constant: Double, next: Int) {
            var terms: [(col: Int, value: Double)] = []
            var constant = 0.0
            var i = start
            while i < tokens.count {
                var sign = 1.0
                var sawSign = false
                while i < tokens.count, tokens[i] == .plus || tokens[i] == .minus {
                    if tokens[i] == .minus { sign = -sign }
                    sawSign = true
                    i += 1
                }
                guard i < tokens.count else {
                    if sawSign { throw syntax(line, "a sign is not followed by a term") }
                    break
                }
                switch tokens[i] {
                case .number(let value):
                    if i + 1 < tokens.count, case .name(let name) = tokens[i + 1] {
                        terms.append((column(name), sign * value))
                        i += 2
                    } else {
                        constant += sign * value
                        i += 1
                    }
                case .name(let name):
                    terms.append((column(name), sign))
                    i += 1
                case .lessEqual, .greaterEqual, .equal:
                    if sawSign { throw syntax(line, "a sign is not followed by a term") }
                    return (terms, constant, i)
                case .colon:
                    throw syntax(line, "unexpected ':'")
                case .plus, .minus:
                    break
                }
            }
            return (terms, constant, i)
        }

        mutating func addConstraint(_ tokens: [Token], name: String?, line: Int) throws {
            // expr op expr [op expr]; variables may appear on either side.
            let first = try expression(tokens, from: 0, line: line)
            guard first.next < tokens.count else { throw syntax(line, "a constraint has no relational operator") }
            let op1 = tokens[first.next]
            let second = try expression(tokens, from: first.next + 1, line: line)

            var coefficients: [Int: Double] = [:]
            var order: [Int] = []
            func accumulate(_ terms: [(col: Int, value: Double)], _ scale: Double) {
                for term in terms {
                    if coefficients[term.col] == nil { order.append(term.col) }
                    coefficients[term.col, default: 0] += scale * term.value
                }
            }
            var lo = -Double.infinity
            var hi = Double.infinity

            if second.next < tokens.count {
                // Double-sided: L op expr op U, with constants on the outside.
                guard first.terms.isEmpty else { throw syntax(line, "a double-sided constraint must have the form 'number <= expression <= number'") }
                let op2 = tokens[second.next]
                let third = try expression(tokens, from: second.next + 1, line: line)
                guard third.terms.isEmpty, third.next == tokens.count else {
                    throw syntax(line, "a double-sided constraint must have the form 'number <= expression <= number'")
                }
                accumulate(second.terms, 1)
                let leftValue = first.constant - second.constant
                let rightValue = third.constant - second.constant
                switch op1 {
                case .lessEqual: lo = Swift.max(lo, leftValue)
                case .greaterEqual: hi = Swift.min(hi, leftValue)
                default:
                    lo = leftValue
                    hi = leftValue
                }
                switch op2 {
                case .lessEqual: hi = Swift.min(hi, rightValue)
                case .greaterEqual: lo = Swift.max(lo, rightValue)
                default:
                    lo = rightValue
                    hi = rightValue
                }
            } else {
                accumulate(first.terms, 1)
                accumulate(second.terms, -1)
                let rhs = second.constant - first.constant
                switch op1 {
                case .lessEqual: hi = rhs
                case .greaterEqual: lo = rhs
                default:
                    lo = rhs
                    hi = rhs
                }
            }
            let row = rowLower.count
            rowNames.append(name)
            // A right-hand side of magnitude 1e20 or more means "no bound" (`conventionalInfinity`).
            rowLower.append(lo <= -conventionalInfinity ? -.infinity : lo)
            rowUpper.append(hi >= conventionalInfinity ? .infinity : hi)
            for col in order {
                if let value = coefficients[col], value != 0 { entries.append((row, col, value)) }
            }
        }

        mutating func addBound(_ tokens: [Token], line: Int) throws {
            func value(_ index: inout Int) throws -> Double {
                var sign = 1.0
                while index < tokens.count, tokens[index] == .plus || tokens[index] == .minus {
                    if tokens[index] == .minus { sign = -sign }
                    index += 1
                }
                guard index < tokens.count, case .number(let v) = tokens[index] else {
                    throw syntax(line, "a bound needs a number")
                }
                index += 1
                return sign * v
            }
            guard !tokens.isEmpty else { return }
            if case .name(let name) = tokens[0] {
                let j = column(name)
                if tokens.count == 2, case .name(let word) = tokens[1], word.lowercased() == "free" {
                    lower[j] = -.infinity
                    upper[j] = .infinity
                    return
                }
                guard tokens.count >= 3 else { throw syntax(line, "incomplete bound") }
                var index = 2
                let v = try value(&index)
                switch tokens[1] {
                case .lessEqual: upper[j] = v
                case .greaterEqual: lower[j] = v
                case .equal:
                    lower[j] = v
                    upper[j] = v
                default: throw syntax(line, "a bound needs <=, >= or =")
                }
                return
            }
            // number op name [op number]
            var index = 0
            let left = try value(&index)
            guard index + 1 < tokens.count, case .name(let name) = tokens[index + 1] else {
                throw syntax(line, "a bound needs a variable")
            }
            let op1 = tokens[index]
            let j = column(name)
            switch op1 {
            case .lessEqual: lower[j] = left
            case .greaterEqual: upper[j] = left
            case .equal:
                lower[j] = left
                upper[j] = left
            default: throw syntax(line, "a bound needs <=, >= or =")
            }
            index += 2
            if index < tokens.count {
                let op2 = tokens[index]
                index += 1
                let right = try value(&index)
                switch op2 {
                case .lessEqual: upper[j] = right
                case .greaterEqual: lower[j] = right
                default: throw syntax(line, "a bound needs <= or >=")
                }
            }
        }

        mutating func parse(_ text: String) throws -> CompiledLP {
            var section = Section.none
            var pending: [Token] = []        // tokens of the statement being assembled
            // Whether `pending` holds a relational operator; kept beside it so that a constraint
            // wrapped over many lines is not rescanned on every line.
            var pendingHasRelational = false
            var pendingLine = 0
            var objectiveTokens: [Token] = []
            var objectiveLine = 0
            var lineNumber = 0

            /// Splits accumulated constraint tokens into statements: a new statement starts
            /// at `name :` or, without a label, once the previous one is complete.
            func flushConstraints() throws {
                guard !pending.isEmpty else { return }
                var statements: [(name: String?, tokens: [Token])] = []
                var current: [Token] = []
                var currentName: String? = nil
                var i = 0
                while i < pending.count {
                    if case .name(let label) = pending[i], i + 1 < pending.count, pending[i + 1] == .colon {
                        if !current.isEmpty { statements.append((currentName, current)) }
                        current = []
                        currentName = label
                        i += 2
                        continue
                    }
                    current.append(pending[i])
                    i += 1
                }
                if !current.isEmpty { statements.append((currentName, current)) }
                pending = []
                pendingHasRelational = false
                for statement in statements {
                    try addConstraint(statement.tokens, name: statement.name, line: pendingLine)
                }
            }

            /// Parses the objective collected so far: an optional label, then an expression.
            /// It runs when the objective section ends, so the objective's variables are
            /// numbered before those of the constraints: columns are in order of first
            /// appearance in the file.
            func finishObjective() throws {
                guard !objectiveTokens.isEmpty else { return }
                var start = 0
                if objectiveTokens.count >= 2, case .name = objectiveTokens[0], objectiveTokens[1] == .colon { start = 2 }
                let objective = try expression(objectiveTokens, from: start, line: objectiveLine)
                guard objective.next == objectiveTokens.count else {
                    throw syntax(objectiveLine, "the objective contains a relational operator")
                }
                for term in objective.terms { cost[term.col] += term.value }
                constant += objective.constant
                objectiveTokens = []
            }

            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                lineNumber += 1
                var line = rawLine
                if let comment = line.firstIndex(of: "\\") { line = line[..<comment] }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let (next, newSense) = sectionKeyword(trimmed) {
                    if section == .constraints { try flushConstraints() }
                    if section == .objective { try finishObjective() }
                    section = next
                    if let newSense { sense = newSense }
                    if section == .end { break }
                    continue
                }
                let tokens = try tokenize(Substring(trimmed), lineNumber: lineNumber)
                switch section {
                case .none:
                    throw syntax(lineNumber, "expected 'Minimize' or 'Maximize'")
                case .objective:
                    if objectiveTokens.isEmpty { objectiveLine = lineNumber }
                    objectiveTokens.append(contentsOf: tokens)
                case .constraints:
                    // A constraint may wrap over several lines. A line continues the pending
                    // constraint while that one is incomplete (no relational operator yet, or
                    // a dangling operator or sign). Once it is complete, a line continues it
                    // only if it starts with a relational operator (the second half of a
                    // double-sided row) or with a sign and has no relational operator of its
                    // own (more terms of the right-hand side). A line such as "- x + y <= 3"
                    // is therefore a new, unlabelled constraint.
                    let startsLabelled = tokens.count >= 2 && tokens[1] == .colon
                    let previousComplete = pendingHasRelational
                        && !(pending.last == .lessEqual || pending.last == .greaterEqual || pending.last == .equal)
                        && !(pending.last == .plus || pending.last == .minus)
                    let startsWithRelational = tokens.first == .lessEqual || tokens.first == .greaterEqual || tokens.first == .equal
                    let startsWithSign = tokens.first == .plus || tokens.first == .minus
                    let hasRelational = tokens.contains { $0 == .lessEqual || $0 == .greaterEqual || $0 == .equal }
                    let continues = !startsLabelled && (startsWithRelational || (startsWithSign && !hasRelational))
                    if !pending.isEmpty && (startsLabelled || (previousComplete && !continues)) {
                        try flushConstraints()
                    }
                    if pending.isEmpty { pendingLine = lineNumber }
                    pending.append(contentsOf: tokens)
                    if hasRelational { pendingHasRelational = true }
                case .bounds:
                    try addBound(tokens, line: lineNumber)
                case .generals, .binaries:
                    for token in tokens {
                        guard case .name(let name) = token else {
                            throw syntax(lineNumber, "expected a variable name")
                        }
                        let j = column(name)
                        isInteger[j] = true
                        if section == .binaries {
                            lower[j] = Swift.max(lower[j], 0)
                            upper[j] = Swift.min(upper[j], 1)
                        }
                    }
                case .end:
                    break
                }
            }
            if section == .constraints { try flushConstraints() }
            try finishObjective()

            let n = columnNames.count
            let m = rowLower.count
            // A bound of magnitude 1e20 or more means "no bound" (`conventionalInfinity`).
            for j in 0..<n {
                if lower[j] <= -conventionalInfinity { lower[j] = -.infinity }
                if upper[j] >= conventionalInfinity { upper[j] = .infinity }
            }
            for j in 0..<n where lower[j] > upper[j] {
                throw SolverError.invalidModel(
                    .error(.inconsistentVariableBounds(variable: columnNames[j], lower: lower[j], upper: upper[j])))
            }
            let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
            let flip = sense == .maximize
            var integerColumns: [Int32] = []
            for j in 0..<n where isInteger[j] { integerColumns.append(Int32(j)) }
            var taken = Set(rowNames.compactMap { $0 })
            let names = rowNames.enumerated().map { i, explicit -> String in
                if let explicit { return explicit }
                var candidate = "c\(i + 1)"
                while !taken.insert(candidate).inserted { candidate += "_" }
                return candidate
            }
            return CompiledLP(
                a: a, c: flip ? cost.map { $0 == 0 ? 0 : -$0 } : cost,
                c0: flip ? (constant == 0 ? 0 : -constant) : constant, sense: sense, xl: lower, xu: upper,
                rl: rowLower, ru: rowUpper, integerColumns: integerColumns,
                names: LPNames(columns: columnNames, rows: names))
        }
    }
}
