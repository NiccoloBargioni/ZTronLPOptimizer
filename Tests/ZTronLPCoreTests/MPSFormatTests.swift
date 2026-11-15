// Specification §14.2 ("Compile"): the MPS reader and writer — round trips and hand-written
// samples in fixed and free format.

import Foundation
import Testing
import ZTronLPCore
import ZTronLPTestSupport

/// One line of fixed-format MPS: fields at columns 2–3, 5–12, 15–22, 25–36, 40–47 and 50–61.
private func fixed(
    _ f1: String = "", _ f2: String = "", _ f3: String = "", _ f4: String = "", _ f5: String = "",
    _ f6: String = ""
) -> String {
    func pad(_ s: String, _ width: Int) -> String {
        precondition(s.count <= width, "'\(s)' does not fit a \(width)-character field")
        return s + String(repeating: " ", count: width - s.count)
    }
    let line = " " + pad(f1, 2) + " " + pad(f2, 8) + "  " + pad(f3, 8) + "  " + pad(f4, 12) + "   " + pad(f5, 8) + "  " + pad(f6, 12)
    var trimmed = Substring(line)
    while trimmed.last == " " { trimmed = trimmed.dropLast() }
    return String(trimmed)
}

private func syntaxError(_ text: String, options: MPSFormat.ReadOptions = .init()) -> (line: Int, message: String)? {
    guard let diagnostic = invalidModelDiagnostic({ try MPSFormat.read(text, options: options) }) else { return nil }
    guard case .syntax(let line, let message) = diagnostic.kind else {
        Issue.record("expected a syntax diagnostic, got \(diagnostic.kind)")
        return nil
    }
    return (line, message)
}

@Suite("MPS format")
struct MPSFormatTests {
    // MARK: Round trips

    @Test(arguments: ReferenceValues.netlib)
    func netlibFixturesRoundTrip(_ instance: ReferenceInstance) throws {
        let lp = try NetlibFixtures.load(instance.name)
        let text = MPSFormat.write(lp)
        let again = try MPSFormat.read(text)
        #expect(again == lp)
        // Writing is a pure function of the problem.
        #expect(MPSFormat.write(again) == text)
    }

    /// An oracle that does not come from this package: the netlib README lists, for every
    /// instance, its rows (with the objective row), columns and nonzeros (with the objective's).
    /// A reader that dropped, duplicated or misplaced entries would not reproduce them.
    @Test(arguments: ReferenceValues.netlib)
    func parsedNetlibFixturesHaveTheCountsOfTheReadme(_ instance: ReferenceInstance) throws {
        let readme = try #require(NetlibFixtures.readme())
        var published: (rows: Int, columns: Int, nonzeros: Int)? = nil
        for line in readme.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            guard tokens.count >= 5, tokens[0] == instance.name.uppercased()[...],
                  let rows = Int(tokens[1]), let columns = Int(tokens[2]), let nonzeros = Int(tokens[3])
            else { continue }
            published = (rows, columns, nonzeros)
            break
        }
        let counts = try #require(published, "\(instance.name) is not in the README's summary table")
        let lp = try NetlibFixtures.load(instance.name)
        #expect(lp.m == counts.rows - 1)                         // the README counts the objective row
        #expect(lp.n == counts.columns)
        #expect(lp.nnz + lp.c.filter { $0 != 0 }.count == counts.nonzeros)
        #expect(lp.c0 == 0 && lp.integerColumns.isEmpty)
        #expect(Set(lp.names.columns).count == lp.n && Set(lp.names.rows).count == lp.m)
    }

    @Test func randomProblemsOfEveryShapeRoundTrip() throws {
        var rangeRows = 0
        var integerColumns = 0
        for seed in 0..<120 {
            let lp = RandomProblems.everyShape(rows: 4 + seed % 9, columns: 5 + seed % 13, seed: UInt64(seed) &* 7919 &+ 3)
            for i in 0..<lp.m where lp.rl[i] > -inf && lp.ru[i] < inf && lp.rl[i] < lp.ru[i] { rangeRows += 1 }
            integerColumns += lp.integerColumns.count
            let again = try MPSFormat.read(MPSFormat.write(lp))
            #expect(again == lp, "seed \(seed)")
            if again != lp {
                // Say where the round trip broke; a bare inequality is no help.
                #expect(again.rl == lp.rl, "seed \(seed): row lower bounds")
                #expect(again.ru == lp.ru, "seed \(seed): row upper bounds")
                #expect(again.xl == lp.xl && again.xu == lp.xu, "seed \(seed): column bounds")
                #expect(again.c == lp.c && again.c0 == lp.c0, "seed \(seed): objective")
                #expect(again.a == lp.a, "seed \(seed): matrix")
                #expect(again.integerColumns == lp.integerColumns, "seed \(seed): integrality")
            }
        }
        // The generator really produced the shapes this test is about.
        #expect(rangeRows > 50 && integerColumns > 100)
    }

    @Test func rangeRowsReadBackBitForBit() throws {
        // Range rows are written as an anchor and a width; the width is chosen so that the
        // other bound is reproduced exactly even when the subtraction is inexact.
        let pairs: [(Double, Double)] = [
            (0.1, 0.3), (-0.3, 0.3), (-0.2, 0.3), (1e-9, 1e9), (-1e9, -1e-9), (0, 5), (-5, 0),
            (1.0 / 3.0, 2.0 / 3.0), (-7.123456789012345, 9.87654321098765e-5), (1e15, 1.5e15 + 0.25),
            (-1e-300, 1e-300), (123456.789, 123456.7890001),
        ]
        let n = 2
        var entries: [(row: Int, col: Int, value: Double)] = []
        for i in pairs.indices {
            entries.append((i, 0, 1))
            entries.append((i, 1, Double(i + 1)))
        }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: pairs.count, cols: n, entries), c: [1, 1],
            xl: [0, 0], xu: [inf, inf], rl: pairs.map(\.0), ru: pairs.map(\.1))
        let again = try MPSFormat.read(MPSFormat.write(lp))
        for i in pairs.indices {
            #expect(again.rl[i].bitPattern == lp.rl[i].bitPattern, "row \(i) lower")
            #expect(again.ru[i].bitPattern == lp.ru[i].bitPattern, "row \(i) upper")
        }
    }

    @Test func freeRowsSurviveOnlyWhenAskedFor() throws {
        let lp = denseLP(
            rows: [[1, 2], [3, 0], [1, 1]], rl: [-inf, -inf, 1], ru: [inf, 4, inf], c: [1, 1],
            xl: [0, 0], xu: [inf, inf])
        let text = MPSFormat.write(lp)
        // By default a free row is dropped, as every mainstream reader does.
        let dropped = try MPSFormat.read(text)
        #expect(dropped.m == 2 && dropped.names.rows == ["c2", "c3"])
        #expect(dropped.ru == [4, inf] && dropped.rl == [-inf, 1])
        var options = MPSFormat.ReadOptions()
        options.keepFreeRows = true
        #expect(try MPSFormat.read(text, options: options) == lp)
    }

    @Test func aMaximizationProblemWithAConstantRoundTrips() throws {
        let model = LPModel<XY>()
            .maximizing(3 * XY.x - 2 * XY.y + 7.5)
            .subjectTo {
                (XY.x + XY.y + XY.z(0) <= 4).named("cap")
                (XY.x - XY.z(0)).within(-1...2.5)
            }
            .integer(.z(0))
            .bounding(.y, .free)
        let lp = try model.compile().lp
        let text = MPSFormat.write(lp)
        #expect(text.contains("OBJSENSE"))
        #expect(text.contains("MARKER"))
        #expect(text.contains("RANGES"))
        let again = try MPSFormat.read(text)
        #expect(again == lp)
        #expect(again.sense == .maximize && again.c0 == -7.5 && again.c == [-3, 2, 0])
        #expect(again.names.columns == ["x", "y", "z[0]"])
        #expect(again.objective(at: [1, 1, 0]) == 8.5)
    }

    @Test func emptyColumnsAndAnEmptyProblemRoundTrip() throws {
        let empty = denseLP(rows: [], rl: [], ru: [], c: [], xl: [], xu: [])
        #expect(try MPSFormat.read(MPSFormat.write(empty)) == empty)
        // Columns that appear in no row and have no cost still have to be declared.
        let lonely = denseLP(rows: [[0, 1, 0]], rl: [1], ru: [inf], c: [0, 2, 0], xl: [0, 0, -1], xu: [inf, inf, 1])
        let again = try MPSFormat.read(MPSFormat.write(lonely))
        #expect(again == lonely)
        #expect(again.n == 3)
    }

    @Test func fixedFormatOutputIsReadableByColumnPosition() throws {
        var options = MPSFormat.ReadOptions()
        options.fixedColumns = true
        for instance in ReferenceValues.netlib {
            let lp = try NetlibFixtures.load(instance.name)
            let text = MPSFormat.write(lp, free: false)
            let again = try MPSFormat.read(text, options: options)
            #expect(again.m == lp.m && again.n == lp.n && again.nnz == lp.nnz, "\(instance.name)")
            #expect(again.names == lp.names, "\(instance.name)")          // netlib names fit eight characters
            #expect(again.a.colStart == lp.a.colStart && again.a.rowIndex == lp.a.rowIndex, "\(instance.name)")
            // Twelve characters per number: values agree to the precision that fits.
            for p in 0..<lp.nnz {
                #expect(abs(again.a.values[p] - lp.a.values[p]) <= 1e-6 * max(1, abs(lp.a.values[p])), "\(instance.name)")
            }
            for j in 0..<lp.n {
                #expect(abs(again.c[j] - lp.c[j]) <= 1e-6 * max(1, abs(lp.c[j])), "\(instance.name)")
                #expect(again.xl[j] == lp.xl[j] || abs(again.xl[j] - lp.xl[j]) <= 1e-6 * max(1, abs(lp.xl[j])))
                #expect(again.xu[j] == lp.xu[j] || abs(again.xu[j] - lp.xu[j]) <= 1e-6 * max(1, abs(lp.xu[j])))
            }
            for i in 0..<lp.m {
                #expect(again.rl[i] == lp.rl[i] || abs(again.rl[i] - lp.rl[i]) <= 1e-6 * max(1, abs(lp.rl[i])))
                #expect(again.ru[i] == lp.ru[i] || abs(again.ru[i] - lp.ru[i]) <= 1e-6 * max(1, abs(lp.ru[i])))
            }
            // The automatic fallback reaches the same result without the option.
            #expect(try MPSFormat.read(text).a.colStart == lp.a.colStart, "\(instance.name)")
        }
    }

    @Test func fixedFormatWriterReplacesNamesThatDoNotFit() throws {
        let lp = try FacilityExample.model().compile().lp      // names such as ship[Plant[id_0],Market[id_0]]
        let text = MPSFormat.write(lp, free: false)
        var options = MPSFormat.ReadOptions()
        options.fixedColumns = true
        let again = try MPSFormat.read(text, options: options)
        #expect(again.names.columns == (1...lp.n).map { "C" + String(format: "%07d", $0) })
        #expect(again.names.rows == (1...lp.m).map { "R" + String(format: "%07d", $0) })
        #expect(again.a == lp.a && again.c == lp.c)
        #expect(again.xl == lp.xl && again.xu == lp.xu && again.rl == lp.rl && again.ru == lp.ru)
        #expect(again.integerColumns == lp.integerColumns)
        for line in text.split(separator: "\n") { #expect(line.count <= 61) }
    }

    // MARK: Hand-written fixed format

    private static let fixedSample: String = [
        "NAME          TESTFIX",
        "ROWS",
        " N  COST",
        " L  LIM1",
        " G  LIM2",
        " E  MYEQN",
        " E  EQ2",
        " L  PLAIN",
        "COLUMNS",
        fixed("", "X ONE", "COST", "1.0", "LIM1", "1.0"),
        fixed("", "X ONE", "LIM2", "1.0"),
        fixed("", "MARKER", "'MARKER'", "", "'INTORG'"),
        fixed("", "YTWO", "COST", "2.0", "LIM1", "1.0"),
        fixed("", "YTWO", "MYEQN", "-1.0"),
        fixed("", "MARKER", "'MARKER'", "", "'INTEND'"),
        fixed("", "ZTHREE", "COST", "-1.0", "MYEQN", "1.0"),
        fixed("", "ZTHREE", "EQ2", "1.0", "PLAIN", "1.D0"),
        "RHS",
        fixed("", "RHS", "COST", "-5.0", "LIM1", "4.0"),
        fixed("", "RHS", "LIM2", "1.0", "MYEQN", "7.0"),
        fixed("", "RHS", "EQ2", "2.0", "PLAIN", "9.0"),
        "RANGES",
        fixed("", "RNG", "LIM1", "2.5", "LIM2", "3.0"),
        fixed("", "RNG", "MYEQN", "4.0", "EQ2", "-1.5"),
        "BOUNDS",
        fixed("UP", "BND", "X ONE", "4.0"),
        fixed("LO", "BND", "YTWO", "-1.0"),
        fixed("UP", "BND", "YTWO", "1.0"),
        "ENDATA",
    ].joined(separator: "\n") + "\n"

    @Test func fixedFormatWithRangesMarkersAndSpacesInNames() throws {
        // "X ONE" has an embedded space: whitespace tokenization fails and the reader falls
        // back to the fixed column positions on its own.
        let lp = try MPSFormat.read(Self.fixedSample)
        #expect(lp.names.columns == ["X ONE", "YTWO", "ZTHREE"])
        #expect(lp.names.rows == ["LIM1", "LIM2", "MYEQN", "EQ2", "PLAIN"])
        #expect(lp.sense == .minimize)
        #expect(lp.c == [1, 2, -1])
        #expect(lp.c0 == 5)                              // RHS on the objective row is −c₀
        // RANGES: L → [rhs − |R|, rhs]; G → [rhs, rhs + |R|]; E with R ≥ 0 → [rhs, rhs + R];
        // E with R < 0 → [rhs − |R|, rhs].
        #expect(lp.rl == [1.5, 1, 7, 0.5, -inf])
        #expect(lp.ru == [4, 4, 11, 2, 9])
        #expect(lp.xl == [0, -1, 0] && lp.xu == [4, 1, inf])
        #expect(lp.integerColumns == [1])
        #expect(lp.a[0, 0] == 1 && lp.a[1, 0] == 1 && lp.a[0, 1] == 1 && lp.a[2, 1] == -1)
        #expect(lp.a[2, 2] == 1 && lp.a[3, 2] == 1 && lp.a[4, 2] == 1)   // 1.D0: a Fortran exponent
        #expect(lp.nnz == 7)

        // The explicit option gives the same problem.
        var options = MPSFormat.ReadOptions()
        options.fixedColumns = true
        #expect(try MPSFormat.read(Self.fixedSample, options: options) == lp)

        // Free format cannot carry the space; the writer replaces it and the result round-trips.
        let rewritten = try MPSFormat.read(MPSFormat.write(lp))
        #expect(rewritten.names.columns == ["X_ONE", "YTWO", "ZTHREE"])
        #expect(rewritten.a == lp.a && rewritten.rl == lp.rl && rewritten.ru == lp.ru)
    }

    @Test func fixedFormatWithBlankSetNames() throws {
        // RHS, RANGES and BOUNDS lines may leave the set name blank.
        let text = [
            "NAME",
            "ROWS",
            " N  OBJ",
            " L  R1",
            " G  R2",
            "COLUMNS",
            fixed("", "A", "OBJ", "1.", "R1", "1."),
            fixed("", "A", "R2", "2."),
            fixed("", "B", "OBJ", ".5", "R1", "-3."),
            "RHS",
            fixed("", "", "R1", "6.", "R2", "1."),
            "RANGES",
            fixed("", "", "R2", "2."),
            "BOUNDS",
            fixed("UP", "", "A", "10."),
            fixed("FR", "", "B"),
            "ENDATA",
        ].joined(separator: "\n")
        let lp = try MPSFormat.read(text)
        #expect(lp.names.columns == ["A", "B"])
        #expect(lp.c == [1, 0.5])
        #expect(lp.rl == [-inf, 1] && lp.ru == [6, 3])
        #expect(lp.xl == [0, -inf] && lp.xu == [10, inf])
        #expect(lp.a[0, 1] == -3 && lp.a[1, 0] == 2)
    }

    // MARK: Hand-written free format

    private static let freeSample = """
        * comment lines start with an asterisk
        NAME sample in free format
        OBJSENSE
            MAX
        ROWS
         N obj
         L c1
         G c2
         E c3
         N freebie

        COLUMNS
            x obj 3 c1 1
            x c2 1
            M1 'MARKER' 'INTORG'
            b obj 1 c1 2
            i obj 1.5 c3 1
            M2 'MARKER' 'INTEND'
            y obj -2 c2 1
            y c3 -1 freebie 4
            w c1 1
            v c2 1
            u c3 1
            t c1 1
            s c2 1
        RHS
            rhs c1 10 c2 -3
            rhs c3 1.5e1
            rhs obj 4
        BOUNDS
         UP bnd x -2
         MI bnd y
         UP bnd y 5
         FR bnd w
         BV bnd v
         LI bnd u -3
         UI bnd u 7
         PL bnd t
         FX bnd s 2.5
         LO bnd i 1
        ENDATA
        """

    @Test func freeFormatWithEveryBoundType() throws {
        let lp = try MPSFormat.read(Self.freeSample)
        #expect(lp.names.columns == ["x", "b", "i", "y", "w", "v", "u", "t", "s"])
        #expect(lp.names.rows == ["c1", "c2", "c3"])       // the second N row is dropped
        #expect(lp.sense == .maximize)
        // Stored as the minimization of the negated objective.
        #expect(lp.c == [-3, -1, -1.5, 2, 0, 0, 0, 0, 0])
        #expect(lp.c0 == 4)                               // maximize … − 4, negated
        #expect(lp.objective(at: [1, 0, 0, 0, 0, 0, 0, 0, 0]) == -1)
        #expect(lp.rl == [-inf, -3, 15] && lp.ru == [10, inf, 15])
        // UP with a negative value and no lower bound makes the lower bound −∞; an integer
        // column between markers with no bound at all is binary; LO on such a column keeps it
        // a general integer.
        #expect(lp.xl == [-inf, 0, 1, -inf, -inf, 0, -3, 0, 2.5])
        #expect(lp.xu == [-2, 1, inf, 5, inf, 1, 7, inf, 2.5])
        #expect(lp.integerColumns == [1, 2, 5, 6])
        #expect(lp.a[0, 0] == 1 && lp.a[1, 0] == 1 && lp.a[0, 1] == 2 && lp.a[2, 2] == 1)
        #expect(lp.a[1, 3] == 1 && lp.a[2, 3] == -1)
        #expect(lp.nnz == 11)
        #expect(try MPSFormat.read(MPSFormat.write(lp)) == lp)

        var options = MPSFormat.ReadOptions()
        options.keepFreeRows = true
        let kept = try MPSFormat.read(Self.freeSample, options: options)
        #expect(kept.names.rows == ["c1", "c2", "c3", "freebie"])
        #expect(kept.rl[3] == -inf && kept.ru[3] == inf && kept.a[3, 3] == 4)
    }

    @Test(arguments: [
        ("OBJSENSE\n    MAX", ObjectiveSense.maximize),
        ("OBJSENSE\n    MAXIMIZE", .maximize),
        ("OBJSENSE MAX", .maximize),
        ("OBJSENSE MAXIMIZE", .maximize),
        ("OBJSENSE\n    MIN", .minimize),
        ("OBJSENSE MINIMIZE", .minimize),
        ("", .minimize),
    ])
    func objectiveSenseSpellings(_ header: String, _ expected: ObjectiveSense) throws {
        let text = "NAME t\n" + (header.isEmpty ? "" : header + "\n") + """
            ROWS
             N obj
             L c1
            COLUMNS
                x obj 2 c1 1
            RHS
                rhs c1 3
            ENDATA
            """
        let lp = try MPSFormat.read(text)
        #expect(lp.sense == expected)
        #expect(lp.c == [expected == .maximize ? -2 : 2])
        #expect(lp.objective(at: [3]) == 6)
    }

    @Test func rhsAndBoundLinesWithoutSetNames() throws {
        let text = """
            NAME t
            ROWS
             N obj
             L c1
             G c2
            COLUMNS
                x obj 1 c1 1
                y obj 1 c2 1
            RHS
                c1 5 c2 2
                obj -1.5
            RANGES
                c1 4
            BOUNDS
             UP x 9
             FR y
            ENDATA
            """
        let lp = try MPSFormat.read(text)
        #expect(lp.rl == [1, 2] && lp.ru == [5, inf])
        #expect(lp.c0 == 1.5)
        #expect(lp.xu == [9, inf] && lp.xl == [0, -inf])
    }

    @Test func duplicateEntriesAreSummedAndAnObjectiveIsOptional() throws {
        let text = """
            ROWS
             L c1
             G c2
            COLUMNS
                x c1 1 c1 2
                x c2 1
                y c2 4
            RHS
                rhs c1 5
            ENDATA
            """
        let lp = try MPSFormat.read(text)
        #expect(lp.c == [0, 0] && lp.c0 == 0)
        #expect(lp.a[0, 0] == 3)
        #expect(lp.rl == [-inf, 0] && lp.ru == [5, inf])
    }

    @Test func readingFromAFile() throws {
        let lp = try NetlibFixtures.load("afiro")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ztronlp-\(UUID().uuidString).mps")
        defer { try? FileManager.default.removeItem(at: url) }
        try MPSFormat.write(lp).write(to: url, atomically: true, encoding: .utf8)
        #expect(try MPSFormat.read(contentsOf: url) == lp)
        #expect(throws: (any Error).self) {
            try MPSFormat.read(contentsOf: url.appendingPathExtension("missing"))
        }
    }

    // MARK: Errors

    @Test func syntaxErrorsCarryTheirLineNumber() {
        let prefix = "NAME t\nROWS\n N obj\n L c1\nCOLUMNS\n"          // five lines
        #expect(syntaxError(prefix + "    x obj 1 nosuchrow 2\nENDATA\n")?.line == 6)
        #expect(syntaxError(prefix + "    x obj 1 nosuchrow 2\nENDATA\n")?.message.contains("nosuchrow") == true)
        #expect(syntaxError(prefix + "    x obj 1\n    x c1 abc\nENDATA\n")?.line == 7)
        #expect(syntaxError(prefix + "    x obj 1\n    x c1 abc\nENDATA\n")?.message.contains("abc") == true)
        #expect(syntaxError(prefix + "    x obj\nENDATA\n")?.line == 6)
        #expect(syntaxError(prefix + "    x obj 1\nRHS\n    rhs nosuchrow 1\nENDATA\n")?.line == 8)
        #expect(syntaxError(prefix + "    x obj 1\nBOUNDS\n UP bnd nosuchcolumn 1\nENDATA\n")?.line == 8)
        #expect(syntaxError(prefix + "    x obj 1\nBOUNDS\n ZZ bnd x 1\nENDATA\n")?.line == 8)
        #expect(syntaxError(prefix + "    x obj 1\nBOUNDS\n UP bnd x\nENDATA\n")?.line == 8)
        #expect(syntaxError(prefix + "    x obj 1\n    M 'MARKER' 'WHAT'\nENDATA\n")?.line == 7)
        #expect(syntaxError("NAME t\nROWS\n N obj\n Q c1\nENDATA\n")?.line == 4)
        #expect(syntaxError("NAME t\nROWS\n N obj\n L c1\n L c1\nENDATA\n")?.line == 5)
        #expect(syntaxError("NAME t\nROWS\n N obj\nNONSENSE\nENDATA\n")?.line == 4)
        #expect(syntaxError("NAME t\nOBJSENSE\n    SIDEWAYS\nROWS\nENDATA\n")?.line == 3)
        #expect(syntaxError("") != nil)

        // Bounds that cross are a model error, not a syntax error.
        let crossed = invalidModelDiagnostic {
            try MPSFormat.read(prefix + "    x obj 1 c1 1\nBOUNDS\n LO bnd x 5\n UP bnd x 2\nENDATA\n")
        }
        #expect(crossed?.kind == .inconsistentVariableBounds(variable: "x", lower: 5, upper: 2))
    }

    @Test func sectionsOutsideLinearProgrammingAreUnsupported() {
        let prefix = "NAME t\nROWS\n N obj\n L c1\nCOLUMNS\n    x obj 1 c1 1\n"
        for section in ["QUADOBJ", "QMATRIX", "QCMATRIX", "SOS", "INDICATORS"] {
            let message = unsupportedMessage { try MPSFormat.read(prefix + "\(section)\n    x x 1\nENDATA\n") }
            #expect(message?.contains(section) == true)
        }
        let semicontinuous = unsupportedMessage { try MPSFormat.read(prefix + "BOUNDS\n SC bnd x 5\nENDATA\n") }
        #expect(semicontinuous?.contains("SC") == true)
    }

    @Test func hugeBoundsAndRightHandSidesAreInfinite() throws {
        // By long-standing convention a bound or right-hand side of magnitude 1e20 or more
        // means "none": a "finite" 1e30 bound would poison ratio tests and bound flips.
        let text = """
            NAME t
            ROWS
             N obj
             L c1
             G c2
            COLUMNS
                x obj 1 c1 1
                x c2 1
                y obj 1 c1 1
                y c2 1
                z obj 1 c1 1
            RHS
                rhs c1 1e30 c2 -1e+30
            BOUNDS
             UP bnd x 1e30
             LO bnd y -1.0E+30
             UP bnd y 1e20
             UP bnd z 9.9e19
            ENDATA
            """
        let lp = try MPSFormat.read(text)
        #expect(lp.ru[0] == inf && lp.rl[1] == -inf)
        #expect(lp.xu[0] == inf && lp.xl[0] == 0)
        #expect(lp.xl[1] == -inf && lp.xu[1] == inf)
        #expect(lp.xu[2] == 9.9e19)                       // below the threshold: a real bound
        // Coefficients are never reinterpreted.
        #expect(lp.a[0, 0] == 1)
    }
}
