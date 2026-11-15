// The CPLEX LP reader and writer (specification §3, §4.5, §14.2). The automated check here is
// the writer's output re-read by the package's own reader and compared structurally; reading
// the export back with HiGHS is the manual check the specification asks for.

import Foundation
import Testing
@testable import ZTronLPCore
import ZTronLPTestSupport

/// Compares a problem with what `LPFormat.read(LPFormat.write(problem))` produced.
///
/// The two are matched by name, because the reader numbers columns by first appearance in
/// the file. A range row has no portable spelling in LP format, so the writer emits it as an
/// equality against an auxiliary column `Rg<row>` that carries the range as its bounds; the
/// comparison expects exactly that.
private func expectStructurallyEqual(
    _ original: CompiledLP, _ read: CompiledLP, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { Issue.record("\(label): \(message())", sourceLocation: sourceLocation) }
    }
    let columnNames = LPName.uniqued(original.names.columns.map(LPFormat.lpName))
    let rowNames = LPName.uniqued(original.names.rows.map(LPFormat.lpName))
    let readColumn = Dictionary(uniqueKeysWithValues: read.names.columns.enumerated().map { ($1, $0) })
    let readRow = Dictionary(uniqueKeysWithValues: read.names.rows.enumerated().map { ($1, $0) })
    let readInteger = read.integerMask()
    let originalInteger = original.integerMask()
    let flip: Double = original.sense == .maximize ? -1 : 1

    check(read.sense == original.sense, "sense")
    check(read.c0 == original.c0, "objective constant \(read.c0) vs \(original.c0)")
    check(read.m == original.m, "row count \(read.m) vs \(original.m)")

    var rangeRows = 0
    for i in 0..<original.m where original.rl[i] > -inf && original.ru[i] < inf && original.rl[i] != original.ru[i] {
        rangeRows += 1
    }
    // A column with no cost, no row and default bounds leaves no trace in an LP file.
    var invisible = [Bool](repeating: false, count: original.n)
    for j in 0..<original.n {
        invisible[j] = original.c[j] == 0 && original.a.count(inColumn: j) == 0
            && original.xl[j] == 0 && original.xu[j] == inf && !originalInteger[j]
    }
    let visible = invisible.filter { !$0 }.count
    check(read.n == visible + rangeRows, "column count \(read.n) vs \(visible) + \(rangeRows) range columns")

    for j in 0..<original.n {
        guard let k = readColumn[columnNames[j]] else {
            check(invisible[j], "column \(columnNames[j]) is missing")
            continue
        }
        check(read.c[k] == original.c[j], "cost of \(columnNames[j]): \(flip * read.c[k]) vs \(flip * original.c[j])")
        check(read.xl[k] == original.xl[j] && read.xu[k] == original.xu[j], "bounds of \(columnNames[j])")
        check(readInteger[k] == originalInteger[j], "integrality of \(columnNames[j])")
    }

    for i in 0..<original.m {
        guard let r = readRow[rowNames[i]] else {
            check(false, "row \(rowNames[i]) is missing")
            continue
        }
        var expected: [String: Double] = [:]
        for p in original.aT.range(ofColumn: i) { expected[columnNames[Int(original.aT.rowIndex[p])]] = original.aT.values[p] }
        var found: [String: Double] = [:]
        for p in read.aT.range(ofColumn: r) { found[read.names.column(Int(read.aT.rowIndex[p]))] = read.aT.values[p] }
        let (lo, hi) = (original.rl[i], original.ru[i])
        if lo > -inf && hi < inf && lo != hi {
            let rangeName = "Rg" + rowNames[i]
            check(found[rangeName] == -1, "row \(rowNames[i]) has no range column")
            found[rangeName] = nil
            check(read.rl[r] == 0 && read.ru[r] == 0, "range row \(rowNames[i]) is not an equality with zero")
            if let k = readColumn[rangeName] {
                check(read.xl[k] == lo && read.xu[k] == hi, "range of \(rowNames[i])")
            }
        } else {
            check(read.rl[r] == lo && read.ru[r] == hi, "bounds of row \(rowNames[i]): [\(read.rl[r]), \(read.ru[r])] vs [\(lo), \(hi)]")
        }
        check(found == expected, "coefficients of row \(rowNames[i])")
    }
}

private func lpSyntaxError(_ text: String) -> String? {
    guard let diagnostic = invalidModelDiagnostic({ try LPFormat.read(text) }) else { return nil }
    guard case .syntax(_, let message) = diagnostic.kind else {
        Issue.record("expected a syntax diagnostic, got \(diagnostic.kind)")
        return nil
    }
    return message
}

@Suite("LP format")
struct LPFormatTests {
    // MARK: Writer output re-read

    @Test(arguments: ReferenceValues.netlib)
    func netlibExportReadsBack(_ instance: ReferenceInstance) throws {
        let lp = try NetlibFixtures.load(instance.name)
        let text = try LPFormat.write(lp)
        #expect(text.split(separator: "\n").allSatisfy { $0.count <= 510 })   // the format's line limit
        let read = try LPFormat.read(text)
        expectStructurallyEqual(lp, read, instance.name)
        // A second trip is stable: the reader's own output writes to the same problem.
        #expect(try LPFormat.read(LPFormat.write(read)) == read)
    }

    @Test func randomProblemsOfEveryShapeReadBack() throws {
        for seed in 0..<80 {
            let lp = RandomProblems.everyShape(
                rows: 3 + seed % 8, columns: 4 + seed % 11, seed: UInt64(seed) &* 104_729 &+ 17, freeRows: true)
            let read = try LPFormat.read(LPFormat.write(lp))
            expectStructurallyEqual(lp, read, "seed \(seed)")
        }
    }

    @Test func theFacilityModelReadsBackWithItsBinariesAndNames() throws {
        let lp = try FacilityExample.model().compile().lp
        let text = try LPFormat.write(lp)
        // Brackets are not legal in LP names; they are written as parentheses.
        #expect(text.contains("ship(Plant(id_0),Market(id_0))"))
        #expect(!text.contains("["))
        #expect(text.contains("Binaries"))
        #expect(text.hasPrefix("\\ Written by ZTronLPOptimizer\nMinimize\n"))
        #expect(text.hasSuffix("End\n"))
        let read = try LPFormat.read(text)
        expectStructurallyEqual(lp, read, "facility")
        #expect(read.integerColumns.count == 3)
        // Every column has a cost here, so the file's order of first appearance is the model's.
        #expect(read.a == lp.a && read.c == lp.c && read.xl == lp.xl && read.xu == lp.xu)
        #expect(read.rl == lp.rl && read.ru == lp.ru && read.integerColumns == lp.integerColumns)
    }

    @Test func rangeRowsBecomeAnAuxiliaryColumn() throws {
        let lp = denseLP(
            rows: [[1, 2], [1, -1]], rl: [1, -inf], ru: [5, 3], c: [1, 1], xl: [0, 0], xu: [inf, inf],
            names: LPNames(columns: ["x", "y"], rows: ["box", "cap"]))
        let text = try LPFormat.write(lp)
        #expect(text.contains(" box: x + 2.0 y - Rgbox = 0"))
        #expect(text.contains(" 1.0 <= Rgbox <= 5.0"))
        let read = try LPFormat.read(text)
        #expect(read.names.columns == ["x", "y", "Rgbox"])
        #expect(read.xl[2] == 1 && read.xu[2] == 5)
        #expect(read.rl == [0, -inf] && read.ru == [0, 3])
        expectStructurallyEqual(lp, read, "range")
    }

    @Test func longRowsAreWrapped() throws {
        let n = 400
        let lp = denseLP(
            rows: [(0..<n).map { Double($0 % 7) - 3.5 }], rl: [-inf], ru: [12.5],
            c: (0..<n).map { Double($0) + 0.25 }, xl: [Double](repeating: 0, count: n),
            xu: [Double](repeating: inf, count: n))
        let text = try LPFormat.write(lp)
        let lines = text.split(separator: "\n")
        #expect(lines.count > 20)
        #expect(lines.allSatisfy { $0.count <= 255 })
        let read = try LPFormat.read(text)
        expectStructurallyEqual(lp, read, "wide")
        #expect(read.m == 1 && read.n == n && read.nnz == n)
    }

    /// A row of 30,000 terms is written over more than a thousand lines with its operator on
    /// the last one. The reader keeps a flag for "the pending constraint has its operator"
    /// instead of rescanning the tokens collected so far on every line, so this is linear.
    @Test func aRowWrappedOverAThousandLinesReadsBack() throws {
        let n = 30_000
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<n { entries.append((0, j, Double(1 + j % 7))) }
        entries.append((1, 0, 1))
        entries.append((1, n - 1, -1))
        let lp = CompiledLP(
            a: .fromTriplets(rows: 2, cols: n, entries), c: [Double](repeating: 1, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 1, count: n),
            rl: [-.infinity, 0], ru: [Double(n), 0])
        let text = try LPFormat.write(lp)
        #expect(text.split(separator: "\n").count > 1_000)
        let read = try LPFormat.read(text)
        #expect(read.m == 2 && read.n == n && read.nnz == n + 2)
        expectStructurallyEqual(lp, read, "a row of \(n) terms")
    }

    @Test func namesAreMappedToTheLPAlphabet() {
        #expect(LPFormat.lpName("x[3,7]") == "x(3,7)")
        #expect(LPFormat.lpName("ship[Plant[id_0],Market[id_1]]") == "ship(Plant(id_0),Market(id_1))")
        #expect(LPFormat.lpName("3rd") == "_3rd")
        #expect(LPFormat.lpName(".dot") == "_.dot")
        #expect(LPFormat.lpName("e5") == "_e5")             // would read as an exponent
        #expect(LPFormat.lpName("E-3x") == "E_3x")           // the minus sign is mapped first
        #expect(LPFormat.lpName("E3") == "_E3")
        #expect(LPFormat.lpName("east") == "east")
        #expect(LPFormat.lpName("a b") == "a_b")
        #expect(LPFormat.lpName("") == "_")
        #expect(LPFormat.lpName("free") == "_free")         // reserved words cannot be names
        #expect(LPFormat.lpName("Inf") == "_Inf")
        #expect(LPFormat.lpName("st") == "_st")
        #expect(LPFormat.lpName("integer") == "_integer")
        #expect(LPFormat.lpName("s.t.") == "_s.t.")
        #expect(LPFormat.lpName("interest") == "interest")   // only whole names are reserved
    }

    @Test func awkwardNamesSurviveTheTrip() throws {
        let lp = denseLP(
            rows: [[1, 1, 1, 1]], rl: [1], ru: [inf], c: [1, 2, 3, 4], xl: [0, 0, 0, 0],
            xu: [inf, inf, inf, inf], names: LPNames(columns: ["e5", "free", "x[1]", "2nd"], rows: ["end"]))
        let read = try LPFormat.read(LPFormat.write(lp))
        #expect(read.names.columns == ["_e5", "_free", "x(1)", "_2nd"])
        #expect(read.names.rows == ["_end"])
        #expect(read.c == lp.c && read.a == lp.a)
    }

    @Test func columnsNamedLikeKeywordsSurviveTheTrip() throws {
        // Each of these, alone on a line of the Generals or Binaries section, would otherwise be
        // read as the start of a section.
        let keywords = [
            "minimize", "minimum", "min", "maximize", "maximum", "max", "st", "s.t.", "st.", "bounds", "bound",
            "general", "generals", "gen", "integer", "integers", "int", "binary", "binaries", "bin", "end",
            "free", "inf", "Infinity", "INT", "End",
        ]
        for keyword in keywords {
            // One integer column and one binary column with that name's two capitalizations.
            let lp = denseLP(
                rows: [[1, 2]], rl: [1], ru: [inf], c: [3, 0], xl: [0, 0], xu: [7, 1], integer: [0, 1],
                names: LPNames(columns: [keyword, "other"], rows: [keyword]))
            let text = try LPFormat.write(lp)
            let read = try LPFormat.read(text)
            expectStructurallyEqual(lp, read, "a column named \(keyword)")
            #expect(read.n == 2 && read.m == 1 && read.integerColumns.count == 2, "\(keyword)")
            #expect(read.names.columns.first == "_" + keyword, "\(keyword)")
        }
    }

    // MARK: Hand-written samples

    @Test func aHandWrittenModel() throws {
        let text = """
            \\ a comment line
            Maximize
             obj: 3 x + 2 y - z + 10       \\ trailing comment
            Subject To
             c1: x + y + z <= 10
             c2: x - y >= -2.5
             c3: x + 3 y
                 + z = 7
             c4: -1 <= x - z <= 4
             x + w >= 1
             - x + v <= 3
             c7: 2 x + 1 >= y + 4
            Bounds
             x <= 4
             -inf <= y <= 5
             z free
             w >= 1
             2 <= v <= 8
             u = 3
            General
             v
            Binary
             w2
            End
            this text after End is ignored
            """
        let lp = try LPFormat.read(text)
        #expect(lp.names.columns == ["x", "y", "z", "w", "v", "u", "w2"])
        #expect(lp.names.rows == ["c1", "c2", "c3", "c4", "c5", "c6", "c7"])
        #expect(lp.sense == .maximize)
        #expect(lp.c == [-3, -2, 1, 0, 0, 0, 0])            // stored as the minimization of −objective
        #expect(lp.c0 == -10)
        #expect(lp.objective(at: [1, 1, 1, 0, 0, 0, 0]) == 14)
        #expect(lp.rl == [-inf, -2.5, 7, -1, 1, -inf, 3])
        #expect(lp.ru == [10, inf, 7, 4, inf, 3, inf])
        #expect(lp.a[2, 0] == 1 && lp.a[2, 1] == 3 && lp.a[2, 2] == 1)      // the wrapped row
        #expect(lp.a[3, 0] == 1 && lp.a[3, 2] == -1)
        #expect(lp.a[5, 0] == -1 && lp.a[5, 4] == 1)                        // a row that starts with a sign
        #expect(lp.a[6, 0] == 2 && lp.a[6, 1] == -1)                        // variables on both sides
        #expect(lp.xl == [0, -inf, -inf, 1, 2, 3, 0])
        #expect(lp.xu == [4, 5, inf, inf, 8, 3, 1])
        #expect(lp.integerColumns == [4, 6])
    }

    @Test func columnsAreNumberedByFirstAppearanceInTheFile() throws {
        let lp = try LPFormat.read("""
            Minimize
             cost: 2 b + a
            Subject To
             r: c + a + b >= 1
            End
            """)
        // The objective comes first in the file, so its variables come first.
        #expect(lp.names.columns == ["b", "a", "c"])
        #expect(lp.c == [2, 1, 0])
    }

    @Test func bracketedNamesFromOtherWritersAreAccepted() throws {
        // Gurobi writes indexed names verbatim; a bracket inside a name is not a quadratic term.
        let lp = try LPFormat.read("""
            Minimize
              2 x[1,2] + y[3]
            Subject To
              c[1]: x[1,2] + y[3] >= 1
              c[2]: x[1,2] - 3 y[3] <= 4
            Bounds
              x[1,2] <= 5
            Generals
              y[3]
            End
            """)
        #expect(lp.names.columns == ["x[1,2]", "y[3]"])
        #expect(lp.names.rows == ["c[1]", "c[2]"])
        #expect(lp.c == [2, 1] && lp.xu == [5, inf] && lp.integerColumns == [1])
        #expect(lp.a[1, 1] == -3)
        // The writer still maps them to the CPLEX alphabet.
        #expect(try LPFormat.write(lp).contains("x(1,2)"))
    }

    @Test(arguments: [
        ("minimize", "subject to", "bounds", "general", "binary"),
        ("MINIMUM", "Such That", "BOUND", "Generals", "Binaries"),
        ("min", "st", "Bounds", "gen", "bin"),
        ("Maximize", "s.t.", "bounds", "integer", "BINARY"),
        ("MAXIMUM", "ST.", "bound", "integers", "bin"),
        ("max", "Subject   To", "BOUNDS", "int", "Binaries"),
    ])
    func keywordSpellings(_ objective: String, _ constraints: String, _ bounds: String, _ generals: String, _ binaries: String) throws {
        let text = [
            objective, " x + 2 y", constraints, " x + y + g + b <= 4", bounds, " y <= 3", generals, " g",
            binaries, " b", "END",
        ].joined(separator: "\n")
        let lp = try LPFormat.read(text)
        let maximize = objective.lowercased().hasPrefix("max")
        #expect(lp.sense == (maximize ? .maximize : .minimize))
        #expect(lp.names.columns == ["x", "y", "g", "b"])
        #expect(lp.objective(at: [1, 1, 0, 0]) == 3)
        #expect(lp.ru == [4] && lp.xu == [inf, 3, inf, 1])
        #expect(lp.integerColumns == [2, 3])
    }

    @Test func constraintForms() throws {
        let lp = try LPFormat.read("""
            min
             x
            st
             a1: x + y <= 4
             a2: x + y =< 4
             a3: x + y < 4
             b1: x + y >= 1
             b2: x + y => 1
             b3: x + y > 1
             e1: x + y = 2
             d1: 1 <= x + y <= 3
             d2: 3 >= x + y >= 1
             d3: 0.5 <= 2 x
             n1: 3 x - 2 y + 0.5 z - z <= 1e2
             n2: 4 >= x
             k1: x + 2 <= 5
            end
            """)
        #expect(lp.names.rows == ["a1", "a2", "a3", "b1", "b2", "b3", "e1", "d1", "d2", "d3", "n1", "n2", "k1"])
        #expect(Array(lp.ru[0..<3]) == [4, 4, 4] && Array(lp.rl[0..<3]) == [-inf, -inf, -inf])
        #expect(Array(lp.rl[3..<6]) == [1, 1, 1] && Array(lp.ru[3..<6]) == [inf, inf, inf])
        #expect(lp.rl[6] == 2 && lp.ru[6] == 2)
        #expect(lp.rl[7] == 1 && lp.ru[7] == 3)
        #expect(lp.rl[8] == 1 && lp.ru[8] == 3)
        // A single-sided row with the number on the left: the variables move to the left-hand
        // side, as CPLEX does, so 0.5 <= 2 x is stored as -2 x <= -0.5.
        #expect(lp.rl[9] == -inf && lp.ru[9] == -0.5 && lp.a[9, 0] == -2)
        #expect(lp.a[10, 0] == 3 && lp.a[10, 1] == -2 && lp.a[10, 2] == -0.5 && lp.ru[10] == 100)
        #expect(lp.rl[11] == -4 && lp.ru[11] == inf && lp.a[11, 0] == -1)
        #expect(lp.ru[12] == 3)                          // the constant moves to the right-hand side
    }

    @Test func boundForms() throws {
        let lp = try LPFormat.read("""
            minimize
             a + b + c + d + e + f + g + h + i
            subject to
             a + b + c + d + e + f + g + h + i >= 1
            bounds
             a >= -2
             b <= 9
             -3 <= c <= 3
             d = 1.5
             e free
             -infinity <= f <= +infinity
             g >= -inf
             7 >= h
             1 <= i
             i <= 6
            end
            """)
        #expect(lp.xl == [-2, 0, -3, 1.5, -inf, -inf, -inf, 0, 1])
        #expect(lp.xu == [inf, 9, 3, 1.5, inf, inf, inf, 7, 6])
    }

    @Test func hugeBoundsAreInfinite() throws {
        // The writer spells a free row as `>= -1e+30`; by convention magnitudes of 1e20 and
        // more mean "no bound".
        let free = denseLP(rows: [[1, 1]], rl: [-inf], ru: [inf], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        #expect(try LPFormat.write(free).contains(">= -1e+30"))
        let read = try LPFormat.read(LPFormat.write(free))
        #expect(read.rl == [-inf] && read.ru == [inf])

        let lp = try LPFormat.read("""
            min
             x + y
            st
             r1: x + y <= 1e30
            bounds
             -1e30 <= x <= 1e+20
             y <= 9e19
            end
            """)
        #expect(lp.ru == [inf])
        #expect(lp.xl == [-inf, 0] && lp.xu == [inf, 9e19])
    }

    @Test func anEmptyObjectiveAndAnObjectiveConstant() throws {
        let constantOnly = try LPFormat.read("min\n obj: 12.5\nst\n c: x + y >= 1\nend\n")
        #expect(constantOnly.c == [0, 0] && constantOnly.c0 == 12.5)
        let empty = try LPFormat.read("max\nst\n c: x >= 1\nend\n")
        #expect(empty.c == [0] && empty.c0 == 0 && empty.sense == .maximize)
        // A problem with no rows and no columns writes and reads.
        let nothing = denseLP(rows: [], rl: [], ru: [], c: [], xl: [], xu: [], c0: 3)
        let read = try LPFormat.read(LPFormat.write(nothing))
        #expect(read.n == 0 && read.m == 0 && read.c0 == 3)
    }

    @Test func readingFromAFile() throws {
        let lp = try NetlibFixtures.load("afiro")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ztronlp-\(UUID().uuidString).lp")
        defer { try? FileManager.default.removeItem(at: url) }
        try LPFormat.write(lp).write(to: url, atomically: true, encoding: .utf8)
        expectStructurallyEqual(lp, try LPFormat.read(contentsOf: url), "afiro from a file")
    }

    // MARK: Errors

    @Test func malformedInputIsRejected() {
        #expect(lpSyntaxError("x + y >= 1\n")?.contains("Minimize") == true)            // no objective section
        #expect(lpSyntaxError("min\n x\nst\n c1: x + y\nend\n")?.contains("relational") == true)
        #expect(lpSyntaxError("min\n x\nst\n c1: x + <= 3\nend\n") != nil)              // dangling sign
        #expect(lpSyntaxError("min\n x\nst\n c1: x | y <= 3\nend\n")?.contains("|") == true)
        #expect(lpSyntaxError("min\n x <= 3\nst\n c1: x >= 1\nend\n")?.contains("objective") == true)
        #expect(lpSyntaxError("min\n x\nst\n c1: x >= 1\nbounds\n x >=\nend\n") != nil)
        #expect(lpSyntaxError("min\n x\nst\n c1: x >= 1\nbounds\n x free 3\nend\n") != nil)
        #expect(lpSyntaxError("min\n x\nst\n c1: x >= 1\ngeneral\n 3\nend\n") != nil)
        #expect(lpSyntaxError("min\n x\nst\n c1: 1 <= x + y <= 3 <= 9\nend\n") != nil)
        #expect(lpSyntaxError("min\n x\nst\n c1: x <= y <= 3\nend\n") != nil)           // variables outside a double-sided row

        let crossed = invalidModelDiagnostic { try LPFormat.read("min\n x\nst\n c1: x >= 1\nbounds\n 5 <= x <= 2\nend\n") }
        #expect(crossed?.kind == .inconsistentVariableBounds(variable: "x", lower: 5, upper: 2))
    }

    @Test func quadraticTermsAreUnsupported() {
        for text in [
            "min\n obj: x + [ x ^ 2 ] / 2\nst\n c: x >= 1\nend\n",
            "min\n obj: x\nst\n c: [ x * y ] <= 1\nend\n",
        ] {
            #expect(unsupportedMessage { try LPFormat.read(text) }?.contains("quadratic") == true)
        }
    }
}
