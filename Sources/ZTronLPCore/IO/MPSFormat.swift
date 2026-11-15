// MPS reader and writer (specification §3, §4.5, §14.2).
//
// The reader accepts free and fixed MPS (sections NAME, OBJSENSE, OBJSENSE MAX, ROWS, COLUMNS
// with integer markers, RHS, RANGES, BOUNDS, ENDATA). The writer emits free MPS by default
// with shortest round-trip number formatting, so `read(write(lp)) == lp`.

import Foundation

/// MPS and LP files have no spelling for "no bound" where a number is expected, so by
/// long-standing convention a bound or right-hand side of magnitude 1e20 or more means exactly
/// that. Both readers map such values to ±∞ on the side where an infinite bound makes sense
/// (an upper bound of +1e30, a lower bound of −1e30); read as finite numbers they would
/// poison ratio tests and bound flips. Coefficients are never reinterpreted.
let conventionalInfinity = 1e20

public enum MPSFormat {
    /// Options of the reader.
    public struct ReadOptions: Sendable {
        /// Keep `N` rows after the first as free rows. The default drops them, as every
        /// mainstream reader does: they constrain nothing.
        public var keepFreeRows: Bool = false
        /// Force fixed-column parsing (names may then contain spaces). The default tries free
        /// tokenization first and falls back to fixed columns when that fails.
        public var fixedColumns: Bool = false
        public init() {}
    }

    // MARK: - Reading

    /// Parses an MPS document.
    ///
    /// Throws `SolverError.invalidModel` with a `.syntax` diagnostic for malformed input and
    /// `SolverError.unsupported` for sections outside linear programming (quadratic terms,
    /// SOS, indicators, semi-continuous bounds).
    public static func read(_ text: String, options: ReadOptions = .init()) throws -> CompiledLP {
        if options.fixedColumns {
            return try parse(text, fixed: true, options: options)
        }
        do {
            return try parse(text, fixed: false, options: options)
        } catch let first as SolverError {
            // Fixed-format files may have names with embedded spaces, which whitespace
            // tokenization cannot read. Retry by column position; report the original error
            // if that fails as well.
            guard case .invalidModel = first else { throw first }
            if let retried = try? parse(text, fixed: true, options: options) { return retried }
            throw first
        }
    }

    /// Reads an MPS file.
    public static func read(contentsOf url: URL, options: ReadOptions = .init()) throws -> CompiledLP {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SolverError.invalidModel(.error(.syntax(line: 0, message: "the file is not text")))
        }
        return try read(text, options: options)
    }

    private enum Section {
        case none, name, objsense, objsect, rows, columns, rhs, ranges, bounds, end
    }

    private static func syntax(_ line: Int, _ message: String) -> SolverError {
        .invalidModel(.error(.syntax(line: line, message: message)))
    }

    private static func number(_ token: Substring, line: Int) throws -> Double {
        if let value = Double(token) { return value }
        // Fortran-style exponents: 1.5D+02.
        let patched = token.replacingOccurrences(of: "D", with: "e").replacingOccurrences(of: "d", with: "e")
        if let value = Double(patched) { return value }
        let lowered = token.lowercased()
        if lowered == "inf" || lowered == "+inf" || lowered == "infinity" || lowered == "+infinity" || lowered == "1e+30" {
            return .infinity
        }
        if lowered == "-inf" || lowered == "-infinity" { return -.infinity }
        throw syntax(line, "'\(token)' is not a number")
    }

    /// Splits a data line into fields: by whitespace, or by the fixed MPS column positions
    /// (2–3, 5–12, 15–22, 25–36, 40–47, 50–61).
    private static func fields(of line: Substring, fixed: Bool) -> [Substring] {
        if !fixed {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        }
        let characters = Array(line)
        func slice(_ from: Int, _ to: Int) -> Substring? {
            guard characters.count >= from else { return nil }
            let end = Swift.min(to, characters.count)
            let text = String(characters[(from - 1)..<end]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Substring(text)
        }
        var result: [Substring] = []
        for (from, to) in [(2, 3), (5, 12), (15, 22), (25, 36), (40, 47), (50, 61)] {
            if let field = slice(from, to) { result.append(field) }
        }
        return result
    }

    private static func parse(_ text: String, fixed: Bool, options: ReadOptions) throws -> CompiledLP {
        var section = Section.none
        var sense = ObjectiveSense.minimize

        // Rows.
        var rowIndex: [String: Int] = [:]          // constraint rows only
        var rowNames: [String] = []
        var rowType: [Character] = []
        var objectiveRow: String? = nil
        var ignoredRows = Set<String>()

        // Columns.
        var columnIndex: [String: Int] = [:]
        var columnNames: [String] = []
        var cost: [Double] = []
        var isInteger: [Bool] = []
        var entries: [(row: Int, col: Int, value: Double)] = []
        var inIntegerBlock = false

        // Right-hand sides, ranges, bounds.
        var rhs: [Double] = []
        var range: [Double?] = []
        var objectiveConstant = 0.0
        var lower: [Double] = []
        var upper: [Double] = []
        var boundSeen: [Bool] = []

        func column(named name: Substring, line: Int) throws -> Int {
            guard let j = columnIndex[String(name)] else { throw syntax(line, "unknown column '\(name)'") }
            return j
        }

        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            var line = rawLine
            if line.last == "\r" { line = line.dropLast() }
            if line.isEmpty || line.first == "*" { continue }
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }

            let isHeader = line.first != " " && line.first != "\t"
            if isHeader {
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                let keyword = tokens[0].uppercased()
                switch keyword {
                case "NAME":
                    section = .name
                case "OBJSENSE":
                    section = .objsense
                    if tokens.count > 1 {
                        let value = tokens[1].uppercased()
                        if value.hasPrefix("MAX") { sense = .maximize } else if value.hasPrefix("MIN") { sense = .minimize }
                    }
                case "OBJSECT":
                    section = .objsect
                case "ROWS":
                    section = .rows
                case "COLUMNS":
                    section = .columns
                case "RHS":
                    section = .rhs
                    rhs = [Double](repeating: 0, count: rowNames.count)
                    range = [Double?](repeating: nil, count: rowNames.count)
                case "RANGES":
                    section = .ranges
                    if rhs.count != rowNames.count { rhs = [Double](repeating: 0, count: rowNames.count) }
                    if range.count != rowNames.count { range = [Double?](repeating: nil, count: rowNames.count) }
                case "BOUNDS":
                    section = .bounds
                case "ENDATA":
                    section = .end
                case "QUADOBJ", "QMATRIX", "QSECTION", "QCMATRIX", "SOS", "INDICATORS", "PWLOBJ", "GENCONS", "CSECTION", "LAZYCONS", "USERCUTS":
                    throw SolverError.unsupported("the MPS section \(keyword) is outside linear programming")
                default:
                    throw syntax(lineNumber, "unknown section '\(tokens[0])'")
                }
                if section == .end { break }
                continue
            }

            let tokens = fields(of: line, fixed: fixed)
            if tokens.isEmpty { continue }

            switch section {
            case .none, .name, .end:
                continue

            case .objsense:
                let value = tokens[0].uppercased()
                if value.hasPrefix("MAX") {
                    sense = .maximize
                } else if value.hasPrefix("MIN") {
                    sense = .minimize
                } else {
                    throw syntax(lineNumber, "OBJSENSE must be MIN or MAX, found '\(tokens[0])'")
                }

            case .objsect:
                objectiveRow = String(tokens[0])

            case .rows:
                guard tokens.count >= 2 else { throw syntax(lineNumber, "a ROWS line needs a type and a name") }
                let type = tokens[0].uppercased()
                let name = String(tokens[1])
                switch type {
                case "N":
                    if objectiveRow == nil {
                        objectiveRow = name
                    } else if name != objectiveRow {
                        if options.keepFreeRows {
                            guard rowIndex[name] == nil else { throw syntax(lineNumber, "duplicate row '\(name)'") }
                            rowIndex[name] = rowNames.count
                            rowNames.append(name)
                            rowType.append("N")
                        } else {
                            ignoredRows.insert(name)
                        }
                    }
                case "L", "G", "E":
                    guard rowIndex[name] == nil, name != objectiveRow else {
                        throw syntax(lineNumber, "duplicate row '\(name)'")
                    }
                    rowIndex[name] = rowNames.count
                    rowNames.append(name)
                    rowType.append(type.first!)
                default:
                    throw syntax(lineNumber, "unknown row type '\(tokens[0])'")
                }

            case .columns:
                // Integer markers: <name> 'MARKER' 'INTORG' / 'INTEND'.
                if tokens.count >= 3, tokens[1].uppercased() == "'MARKER'" {
                    let kind = tokens[2].uppercased()
                    if kind == "'INTORG'" {
                        inIntegerBlock = true
                    } else if kind == "'INTEND'" {
                        inIntegerBlock = false
                    } else {
                        throw syntax(lineNumber, "unknown marker \(tokens[2])")
                    }
                    continue
                }
                guard tokens.count == 3 || tokens.count == 5 else {
                    throw syntax(lineNumber, "a COLUMNS line needs a column and one or two (row, value) pairs")
                }
                let name = String(tokens[0])
                let j: Int
                if let existing = columnIndex[name] {
                    j = existing
                } else {
                    j = columnNames.count
                    columnIndex[name] = j
                    columnNames.append(name)
                    cost.append(0)
                    isInteger.append(inIntegerBlock)
                    lower.append(0)
                    upper.append(.infinity)
                    boundSeen.append(false)
                }
                var k = 1
                while k + 1 < tokens.count {
                    let row = String(tokens[k])
                    let value = try number(tokens[k + 1], line: lineNumber)
                    guard value.isFinite else { throw syntax(lineNumber, "the coefficient of '\(name)' in '\(row)' is not finite") }
                    if row == objectiveRow {
                        cost[j] += value
                    } else if let i = rowIndex[row] {
                        if value != 0 { entries.append((i, j, value)) }
                    } else if !ignoredRows.contains(row) {
                        throw syntax(lineNumber, "unknown row '\(row)'")
                    }
                    k += 2
                }

            case .rhs, .ranges:
                // [set] row value [row value]: an odd token count means the set name is present.
                var k = tokens.count % 2 == 1 ? 1 : 0
                guard tokens.count >= 2 else { throw syntax(lineNumber, "incomplete line") }
                while k + 1 < tokens.count {
                    let row = String(tokens[k])
                    let value = try number(tokens[k + 1], line: lineNumber)
                    if row == objectiveRow {
                        // The objective's right-hand side is the negated objective constant.
                        if section == .rhs { objectiveConstant = -value }
                    } else if let i = rowIndex[row] {
                        if section == .rhs { rhs[i] = value } else { range[i] = value }
                    } else if !ignoredRows.contains(row) {
                        throw syntax(lineNumber, "unknown row '\(row)'")
                    }
                    k += 2
                }

            case .bounds:
                let type = tokens[0].uppercased()
                let needsValue: Bool
                switch type {
                case "UP", "LO", "FX", "LI", "UI": needsValue = true
                case "FR", "MI", "PL", "BV": needsValue = false
                case "SC", "SI":
                    throw SolverError.unsupported("semi-continuous bounds (\(type)) are outside linear programming")
                default:
                    throw syntax(lineNumber, "unknown bound type '\(tokens[0])'")
                }
                // type [set] column [value]
                var columnToken: Substring
                var valueToken: Substring? = nil
                if needsValue {
                    guard tokens.count >= 3 else { throw syntax(lineNumber, "a \(type) bound needs a column and a value") }
                    if tokens.count >= 4 {
                        columnToken = tokens[2]
                        valueToken = tokens[3]
                    } else {
                        columnToken = tokens[1]
                        valueToken = tokens[2]
                    }
                } else {
                    guard tokens.count >= 2 else { throw syntax(lineNumber, "a \(type) bound needs a column") }
                    if tokens.count == 2 {
                        columnToken = tokens[1]
                    } else if columnIndex[String(tokens[2])] != nil {
                        columnToken = tokens[2]          // type set column [dummy value]
                    } else {
                        columnToken = tokens[1]          // type column dummy-value
                    }
                }
                let j = try column(named: columnToken, line: lineNumber)
                let value = try valueToken.map { try number($0, line: lineNumber) } ?? 0
                if value.isNaN { throw syntax(lineNumber, "a bound of '\(columnToken)' is not a number") }
                switch type {
                case "UP":
                    upper[j] = value
                    // An upper bound below zero on a column whose lower bound was never given
                    // makes the lower bound −∞ (the long-standing MPS convention).
                    if value < 0 && lower[j] == 0 && !boundSeen[j] { lower[j] = -.infinity }
                case "LO":
                    lower[j] = value
                case "FX":
                    lower[j] = value
                    upper[j] = value
                case "FR":
                    lower[j] = -.infinity
                    upper[j] = .infinity
                case "MI":
                    lower[j] = -.infinity
                case "PL":
                    upper[j] = .infinity
                case "BV":
                    isInteger[j] = true
                    lower[j] = 0
                    upper[j] = 1
                case "LI":
                    isInteger[j] = true
                    lower[j] = value
                case "UI":
                    isInteger[j] = true
                    upper[j] = value
                default:
                    break
                }
                boundSeen[j] = true
            }
        }

        guard section == .end || !rowNames.isEmpty || !columnNames.isEmpty else {
            throw syntax(lineNumber, "the document has no ROWS or COLUMNS section")
        }

        let m = rowNames.count
        let n = columnNames.count
        if rhs.count != m { rhs = [Double](repeating: 0, count: m) }
        if range.count != m { range = [Double?](repeating: nil, count: m) }

        // Integer columns declared between markers and given no bound are binary.
        for j in 0..<n where isInteger[j] && !boundSeen[j] {
            lower[j] = 0
            upper[j] = 1
        }

        var rl = [Double](repeating: 0, count: m)
        var ru = [Double](repeating: 0, count: m)
        for i in 0..<m {
            let b = rhs[i]
            switch rowType[i] {
            case "L":
                rl[i] = -.infinity
                ru[i] = b
                if let r = range[i] { rl[i] = b - Swift.abs(r) }
            case "G":
                rl[i] = b
                ru[i] = .infinity
                if let r = range[i] { ru[i] = b + Swift.abs(r) }
            case "E":
                rl[i] = b
                ru[i] = b
                if let r = range[i] {
                    if r >= 0 { ru[i] = b + Swift.abs(r) } else { rl[i] = b - Swift.abs(r) }
                }
            default:   // "N": a free row kept on request
                rl[i] = -.infinity
                ru[i] = .infinity
            }
        }
        // Magnitudes of 1e20 and more mean "no bound" (`conventionalInfinity`).
        for i in 0..<m {
            if rl[i] <= -conventionalInfinity { rl[i] = -.infinity }
            if ru[i] >= conventionalInfinity { ru[i] = .infinity }
        }
        for j in 0..<n {
            if lower[j] <= -conventionalInfinity { lower[j] = -.infinity }
            if upper[j] >= conventionalInfinity { upper[j] = .infinity }
        }
        for j in 0..<n where lower[j] > upper[j] {
            throw SolverError.invalidModel(
                .error(.inconsistentVariableBounds(variable: columnNames[j], lower: lower[j], upper: upper[j])))
        }
        guard n <= Int(Int32.max), m <= Int(Int32.max), entries.count <= Int(Int32.max) else {
            throw SolverError.invalidModel(.error(.sizeLimitExceeded(what: "rows, columns or nonzeros", count: Swift.max(n, m, entries.count))))
        }

        let a = SparseCSC.fromTriplets(rows: m, cols: n, entries)
        let flip = sense == .maximize
        let c = flip ? cost.map { $0 == 0 ? 0 : -$0 } : cost
        let c0 = flip ? (objectiveConstant == 0 ? 0 : -objectiveConstant) : objectiveConstant
        var integerColumns: [Int32] = []
        for j in 0..<n where isInteger[j] { integerColumns.append(Int32(j)) }
        return CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: lower, xu: upper, rl: rl, ru: ru,
            integerColumns: integerColumns, names: LPNames(columns: columnNames, rows: rowNames))
    }

    // MARK: - Writing

    /// Writes a problem as MPS.
    ///
    /// Free format (the default) keeps every name and prints numbers with the shortest
    /// representation that reads back to the same `Double`, so the output round-trips. Fixed
    /// format places fields in the classic column positions; it cannot hold more than twelve
    /// characters per number or eight per name, so it is lossy and replaces longer names by
    /// generated ones.
    public static func write(_ lp: CompiledLP, free: Bool = true, name: String = "ZTRONLP") -> String {
        let m = lp.m
        let n = lp.n
        var columnNames = lp.names.columns
        var rowNames = lp.names.rows
        var objectiveName = "COST"

        func usable(_ s: String) -> Bool {
            !s.isEmpty && !s.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
        }
        if free {
            columnNames = LPName.uniqued(columnNames.map { usable($0) ? $0 : $0.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\t", with: "_") })
            rowNames = LPName.uniqued(rowNames.map { usable($0) ? $0 : $0.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\t", with: "_") })
        } else {
            if columnNames.contains(where: { $0.count > 8 || !usable($0) }) || Set(columnNames).count != n {
                columnNames = (0..<n).map { "C" + String(format: "%07d", $0 + 1) }
            }
            if rowNames.contains(where: { $0.count > 8 || !usable($0) }) || Set(rowNames).count != m {
                rowNames = (0..<m).map { "R" + String(format: "%07d", $0 + 1) }
            }
        }
        let taken = Set(rowNames)
        while taken.contains(objectiveName) { objectiveName += "_" }

        func format(_ value: Double) -> String {
            if free { return "\(value)" }
            // At most 12 characters: reduce precision until the text fits.
            var precision = 12
            while precision > 1 {
                let text = String(format: "%.\(precision)g", value)
                if text.count <= 12 { return text }
                precision -= 1
            }
            return String(format: "%.1g", value)
        }
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        /// One data line with fields 2…6 (field 1 is the two-character type code).
        func dataLine(_ code: String, _ f2: String, _ f3: String, _ f4: String? = nil) -> String {
            if free {
                var parts = [code.isEmpty ? "   " : " " + code, f2, f3]
                if let f4 { parts.append(f4) }
                return parts.joined(separator: " ")
            }
            // Columns 2–3, 5–12, 15–22, 25–36.
            var line = " " + pad(code, 2) + " " + pad(f2, 8) + "  " + pad(f3, 8)
            if let f4 { line += "  " + pad(f4, 12) }
            return line
        }

        let flip = lp.sense == .maximize
        var out: [String] = []
        out.reserveCapacity(n + m + lp.nnz + 16)
        out.append("NAME          \(name)")
        if flip {
            out.append("OBJSENSE")
            out.append("    MAX")
        }

        // Row types and right-hand sides.
        var type = [String](repeating: "E", count: m)
        var rhs = [Double](repeating: 0, count: m)
        var range = [Double?](repeating: nil, count: m)
        for i in 0..<m {
            let (lo, hi) = (lp.rl[i], lp.ru[i])
            if lo == hi {
                type[i] = "E"
                rhs[i] = lo
            } else if lo == -.infinity && hi == .infinity {
                type[i] = "N"
            } else if lo == -.infinity {
                type[i] = "L"
                rhs[i] = hi
            } else if hi == .infinity {
                type[i] = "G"
                rhs[i] = lo
            } else if let r = exactRange(anchor: lo, other: hi, plus: true), Swift.abs(lo) <= Swift.abs(hi) || exactRange(anchor: hi, other: lo, plus: false) == nil {
                // G row anchored at the lower bound: upper = lower + |R|.
                type[i] = "G"
                rhs[i] = lo
                range[i] = r
            } else {
                // L row anchored at the upper bound: lower = upper − |R|.
                type[i] = "L"
                rhs[i] = hi
                range[i] = exactRange(anchor: hi, other: lo, plus: false) ?? (hi - lo)
            }
        }

        out.append("ROWS")
        out.append(free ? " N \(objectiveName)" : " N  \(objectiveName)")
        for i in 0..<m {
            out.append(free ? " \(type[i]) \(rowNames[i])" : " \(type[i])  \(rowNames[i])")
        }

        out.append("COLUMNS")
        let isInteger = lp.integerMask()
        var inInteger = false
        var marker = 0
        for j in 0..<n {
            if isInteger[j] != inInteger {
                marker += 1
                let kind = isInteger[j] ? "'INTORG'" : "'INTEND'"
                out.append(free ? "    MARKER\(marker) 'MARKER' \(kind)" : "    " + pad("MARKER\(marker)", 8) + "  " + pad("'MARKER'", 8) + "                 " + kind)
                inInteger = isInteger[j]
            }
            var wrote = false
            let cost = flip ? -lp.c[j] : lp.c[j]
            if cost != 0 {
                out.append(dataLine("", columnNames[j], objectiveName, format(cost)))
                wrote = true
            }
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                out.append(dataLine("", columnNames[j], rowNames[Int(lp.a.rowIndex[p])], format(lp.a.values[p])))
                wrote = true
            }
            if !wrote {
                // An empty column still has to be declared; a zero cost entry does that.
                out.append(dataLine("", columnNames[j], objectiveName, format(0)))
            }
        }
        if inInteger {
            marker += 1
            out.append(free ? "    MARKER\(marker) 'MARKER' 'INTEND'" : "    " + pad("MARKER\(marker)", 8) + "  " + pad("'MARKER'", 8) + "                 'INTEND'")
        }

        out.append("RHS")
        let constant = flip ? -lp.c0 : lp.c0
        if constant != 0 {
            out.append(dataLine("", "RHS", objectiveName, format(-constant)))
        }
        for i in 0..<m where rhs[i] != 0 {
            out.append(dataLine("", "RHS", rowNames[i], format(rhs[i])))
        }

        if range.contains(where: { $0 != nil }) {
            out.append("RANGES")
            for i in 0..<m {
                if let r = range[i] { out.append(dataLine("", "RNG", rowNames[i], format(r))) }
            }
        }

        var boundLines: [String] = []
        for j in 0..<n {
            let (lo, hi) = (lp.xl[j], lp.xu[j])
            let cname = columnNames[j]
            if lo == hi {
                boundLines.append(dataLine("FX", "BND", cname, format(lo)))
                continue
            }
            if lo == -.infinity && hi == .infinity {
                boundLines.append(dataLine("FR", "BND", cname))
                continue
            }
            if lo == -.infinity {
                boundLines.append(dataLine("MI", "BND", cname))
            } else if lo != 0 {
                boundLines.append(dataLine("LO", "BND", cname, format(lo)))
            }
            if hi != .infinity {
                boundLines.append(dataLine("UP", "BND", cname, format(hi)))
            } else if isInteger[j] {
                // Without any bound line an integer column would be read back as binary.
                boundLines.append(dataLine("PL", "BND", cname))
            }
        }
        if !boundLines.isEmpty {
            out.append("BOUNDS")
            out.append(contentsOf: boundLines)
        }
        out.append("ENDATA")
        return out.joined(separator: "\n") + "\n"
    }

    /// A range value `R ≥ 0` for which `anchor ± R` reproduces `other` exactly in floating
    /// point, so a range row reads back bit-for-bit. Searches a few ulps around the obvious
    /// candidate; `nil` when none of them works.
    private static func exactRange(anchor: Double, other: Double, plus: Bool) -> Double? {
        let candidate = Swift.abs(other - anchor)
        func reproduces(_ r: Double) -> Bool {
            (plus ? anchor + r : anchor - r) == other
        }
        if reproduces(candidate) { return candidate }
        var up = candidate
        var down = candidate
        for _ in 0..<8 {
            up = up.nextUp
            down = down.nextDown
            if reproduces(up) { return up }
            if down > 0 && reproduces(down) { return down }
        }
        return nil
    }
}
