// Specification §5.1, §5.2, rule 5 of §5.3 and §14.2 ("Compile"): deterministic lowering,
// golden files and every diagnostic `compile()` can produce.

import Foundation
import Testing
import ZTronLPCore

@Suite("Compile")
struct CompileTests {
    // MARK: Column order and determinism

    @Test func columnsAreOrderedByFirstAppearance() throws {
        // Objective terms first (in the order written), then constraints in declaration order.
        let model = LPModel<XY>()
            .minimizing(XY.y + 2 * XY.x)
            .subjectTo {
                XY.z(2) + XY.x >= 1
                XY.z(1) + XY.z(2) + XY.y <= 9
                XY.z(0) + XY.x + XY.y == 3
            }
        let compiled = try model.compile()
        #expect(compiled.variableAt == [.y, .x, .z(2), .z(1), .z(0)])
        #expect(compiled.column == [.y: 0, .x: 1, .z(2): 2, .z(1): 3, .z(0): 4])
        #expect(compiled.lp.names.columns == ["y", "x", "z[2]", "z[1]", "z[0]"])
        #expect(compiled.lp.names.rows == ["c1", "c2", "c3"])
        #expect(compiled.lp.c == [1, 2, 0, 0, 0])
        #expect(compiled.lp.n == 5 && compiled.lp.m == 3 && compiled.lp.nnz == 8)
        // Row 2 is z(0) + x + y; in column order that is y, x, z(0).
        #expect(compiled.lp.a[2, 0] == 1 && compiled.lp.a[2, 1] == 1 && compiled.lp.a[2, 4] == 1)
        #expect(compiled.lp.a[2, 2] == 0)
        #expect(compiled.lp.rl == [1, -inf, 3] && compiled.lp.ru == [inf, 9, 3])
    }

    @Test func theMatrixIsStoredColumnMajorWithItsRowView() throws {
        let compiled = try FacilityExample.model().compile()
        let lp = compiled.lp
        // Row indices ascend within every column, column indices within every row.
        for j in 0..<lp.n {
            let rows = lp.a.rowIndex[lp.a.range(ofColumn: j)]
            #expect(Array(rows) == rows.sorted())
        }
        for i in 0..<lp.m {
            let columns = lp.aT.rowIndex[lp.aT.range(ofColumn: i)]
            #expect(Array(columns) == columns.sorted())
        }
        #expect(lp.aT == lp.a.transposed())
        #expect(lp.a.colStart.count == lp.n + 1 && lp.aT.colStart.count == lp.m + 1)
        #expect(lp.a.rows == Int32(lp.m) && lp.a.cols == Int32(lp.n))
        #expect(lp.aT.rows == Int32(lp.n) && lp.aT.cols == Int32(lp.m))
        #expect(lp.integerColumns == lp.integerColumns.sorted())
        #expect(lp.scaling == nil)
    }

    @Test func twoCompilationsAreIdentical() throws {
        let model = FacilityExample.model()
        let first = try model.compile()
        let second = try model.compile()
        #expect(first.lp == second.lp)
        #expect(first.variableAt == second.variableAt)
        #expect(first.column == second.column)
        #expect(first.rowNamed == second.rowNamed)
        #expect(MPSFormat.write(first.lp) == MPSFormat.write(second.lp))
        // The same model built a second time, from scratch, lowers to the same problem.
        #expect(try FacilityExample.model().compile().lp == first.lp)
    }

    @Test func anEmptyModelAndAnObjectiveOnlyModelCompile() throws {
        let empty = try LPModel<XY>().compile()
        #expect(empty.lp.n == 0 && empty.lp.m == 0 && empty.lp.nnz == 0)
        #expect(empty.lp.a.colStart == [0] && empty.lp.aT.colStart == [0])
        #expect(empty.variableAt.isEmpty && empty.rowNamed.isEmpty)
        #expect(empty.lp.c0 == 0 && empty.lp.sense == .minimize)

        let objectiveOnly = try LPModel<XY>().maximizing(XY.x - XY.y + 2).compile()
        #expect(objectiveOnly.lp.n == 2 && objectiveOnly.lp.m == 0)
        #expect(objectiveOnly.lp.c == [-1, 1] && objectiveOnly.lp.c0 == -2)
        #expect(objectiveOnly.lp.aT.rows == 2 && objectiveOnly.lp.aT.cols == 0)
    }

    // MARK: Golden files

    /// The golden files hold the MPS and LP text of the facility-location model. Run the tests
    /// with ZTRONLP_RECORD_GOLDEN=1 to rewrite them after an intended change of the lowering.
    @Test(arguments: ["mps", "lp"])
    func compiledModelMatchesTheGoldenFile(_ format: String) throws {
        let lp = try FacilityExample.model().compile().lp
        let text = format == "mps" ? MPSFormat.write(lp, name: "FACILITY") : try LPFormat.write(lp)
        if ProcessInfo.processInfo.environment["ZTRONLP_RECORD_GOLDEN"] == "1" {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
            try text.write(to: directory.appendingPathComponent("facility-location.\(format)"), atomically: true, encoding: .utf8)
            return
        }
        let url = try #require(
            Bundle.module.url(forResource: "facility-location", withExtension: format, subdirectory: "Golden"),
            "Golden/facility-location.\(format) is not bundled")
        let golden = try Data(contentsOf: url)
        // Byte for byte.
        #expect(Data(text.utf8) == golden, "the lowering of the golden model changed")
    }

    @Test func theGoldenModelHasTheDocumentedShape() throws {
        let compiled = try FacilityExample.model().compile()
        let lp = compiled.lp
        #expect(lp.n == 15 && lp.m == 7)
        // open(0), ship(0, 0…3), open(1), ship(1, 0…3), …
        #expect(compiled.variableAt[0] == .open(Plant(id: 0)))
        #expect(compiled.variableAt[1] == .ship(Plant(id: 0), Market(id: 0)))
        #expect(compiled.variableAt[5] == .open(Plant(id: 1)))
        #expect(lp.integerColumns == [0, 5, 10])
        #expect(lp.xl[0] == 0 && lp.xu[0] == 1 && lp.xu[1] == inf)
        #expect(compiled.rowNamed == [
            "supply[0]": 0, "supply[1]": 1, "supply[2]": 2,
            "demand[0]": 3, "demand[1]": 4, "demand[2]": 5, "demand[3]": 6,
        ])
        #expect(lp.names.column(1) == "ship[Plant[id_0],Market[id_0]]")
        #expect(lp.names.row(4) == "demand[1]")
        #expect(compiled.diagnostics.isEmpty && compiled.lowered.isEmpty)
    }

    // MARK: Objective sense

    @Test func maximizationIsStoredAsMinimizationOfTheNegation() throws {
        let model = LPModel<XY>()
            .maximizing(3 * XY.x - 2 * XY.y + 7)
            .subjectTo(XY.x + XY.y + XY.z(0) <= 4)
        let lp = try model.compile().lp
        #expect(lp.sense == .maximize)
        #expect(lp.c == [-3, 2, 0])
        #expect(lp.c0 == -7)
        #expect(lp.c[2].sign == .plus)                  // an absent cost is +0, never −0
        // Reported values use the model's own sense.
        #expect(lp.internalObjective(at: [1, 1, 0]) == -8)
        #expect(lp.objective(at: [1, 1, 0]) == 8)
        #expect(lp.reportedObjective(-8) == 8)

        let minimized = try model.minimizing(3 * XY.x - 2 * XY.y + 7).compile().lp
        #expect(minimized.sense == .minimize && minimized.c == [3, -2, 0] && minimized.c0 == 7)
        #expect(minimized.objective(at: [1, 1, 0]) == 8)
    }

    // MARK: Domains and overrides

    @Test func domainsComeFromTheVariableUnlessOverridden() throws {
        let model = LPModel<Mixed>()
            .minimizing(Mixed.free(0) + Mixed.count(0) + Mixed.flag(0) + Mixed.boxed(0) + Mixed.count(1) + Mixed.flag(1))
            .bounding(.count(1), .range(2...6))
            .continuous(.flag(1))
        let lp = try model.compile().lp
        #expect(lp.xl == [-inf, 0, 0, -2, 2, 0])
        #expect(lp.xu == [inf, inf, 1, 5, 6, 1])
        // free and boxed are continuous; flag(1) was relaxed by the override.
        #expect(lp.integerColumns == [1, 2, 4])
        #expect(lp.integerMask() == [false, true, true, false, true, false])
        #expect(lp.hasIntegerColumns)
        #expect(!lp.relaxed().hasIntegerColumns)
    }

    @Test func aBinaryOverrideIntersectsTheBoundsWithTheUnitInterval() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + XY.y + XY.z(0) + XY.z(1))
            .binary(.x)                                    // domain bounds [0, ∞) → [0, 1]
            .binary(.y).bounding(.y, .range(0...5))        // → [0, 1]
            .binary(.z(0)).bounding(.z(0), .fixed(1))      // → [1, 1]
            .integer(.z(1)).bounding(.z(1), .range(-3...3))
        let lp = try model.compile().lp
        #expect(lp.xl == [0, 0, 1, -3] && lp.xu == [1, 1, 1, 3])
        #expect(lp.integerColumns == [0, 1, 2, 3])
    }

    @Test func variablesThatOnlyCarryAnOverrideAreAppendedSortedByName() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x)
            .bounding(.z(7), .range(1...2))
            .bounding(.z(3), .fixed(5))
            .integer(.z(5))
            .binary(.y)
        let compiled = try model.compile()
        // x comes from the objective; the rest are ordered by name: y, z[3], z[5], z[7].
        #expect(compiled.variableAt == [.x, .y, .z(3), .z(5), .z(7)])
        #expect(compiled.lp.xl == [0, 0, 5, 0, 1] && compiled.lp.xu == [inf, 1, 5, inf, 2])
        #expect(compiled.lp.integerColumns == [1, 3])
        #expect(compiled.lp.m == 0 && compiled.lp.nnz == 0)
        // Deterministic even though the overrides live in dictionaries.
        for _ in 0..<5 { #expect(try model.compile().lp == compiled.lp) }
    }

    // MARK: Singleton constraints (§5.3, rule 5)

    @Test func oneVariableConstraintsBecomeBounds() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + XY.y + XY.z(0))
            .subjectTo {
                XY.x >= 3
                (2 * XY.y <= 10).named("cap")
                (-4 * XY.z(0) >= -8).named("flipped")       // z ≤ 2: a negative coefficient flips the side
                XY.x + XY.y <= 20
                (XY.z(1) == 1.5).named("pin")
                (3 * XY.z(2)).within(-6...9)
            }
        let compiled = try model.compile()
        let lp = compiled.lp
        #expect(lp.m == 1 && lp.n == 5)
        #expect(compiled.variableAt == [.x, .y, .z(0), .z(1), .z(2)])
        #expect(lp.xl == [3, 0, 0, 1.5, 0])            // z(2) ≥ −2 does not beat its own lower bound 0
        #expect(lp.xu == [inf, 5, 2, 1.5, 3])
        #expect(compiled.rowNamed.isEmpty)
        #expect(compiled.lowered["cap"] == LoweredConstraint(column: 1, coefficient: 2, lower: -inf, upper: 10))
        #expect(compiled.lowered["flipped"] == LoweredConstraint(column: 2, coefficient: -4, lower: -8, upper: inf))
        #expect(compiled.lowered["pin"] == LoweredConstraint(column: 3, coefficient: 1, lower: 1.5, upper: 1.5))
        #expect(compiled.lowered.count == 3)           // unnamed singletons leave no entry
    }

    @Test func singletonLoweringCanBeSwitchedOff() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + XY.y)
            .subjectTo {
                XY.x >= 3
                (2 * XY.y <= 10).named("cap")
                XY.x + XY.y <= 20
            }
        var options = CompileOptions()
        options.lowerSingletonConstraints = false
        let compiled = try model.compile(options: options)
        #expect(compiled.lp.m == 3)
        #expect(compiled.lp.xl == [0, 0] && compiled.lp.xu == [inf, inf])
        #expect(compiled.lp.rl == [3, -inf, -inf] && compiled.lp.ru == [inf, 10, 20])
        #expect(compiled.rowNamed == ["cap": 1])
        #expect(compiled.lowered.isEmpty)
        #expect(compiled.lp.names.rows == ["c1", "cap", "c3"])
    }

    @Test func singletonConstraintsIntersectWithOverridesAndWithEachOther() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + XY.y)
            .bounding(.x, .range(1...10))
            .subjectTo {
                XY.x >= 0          // weaker than the override: no effect
                XY.x <= 8
                XY.x <= 6          // the tightest wins
                XY.y >= 2
                XY.y >= 1
            }
        let lp = try model.compile().lp
        #expect(lp.xl == [1, 2] && lp.xu == [6, inf])
    }

    @Test func aFeasibleConstantConstraintIsDropped() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x)
            .subjectTo {
                (XY.x - XY.x <= 1).named("trivial")
                XY.x + XY.y >= 1
            }
        let compiled = try model.compile()
        #expect(compiled.lp.m == 1)
        #expect(compiled.rowNamed.isEmpty)
        #expect(compiled.lowered["trivial"]?.column == -1)
    }

    // MARK: Row names

    @Test func unnamedRowsGetDefaultNamesThatAvoidExplicitOnes() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x)
            .subjectTo {
                XY.x + XY.y >= 1
                (XY.x + XY.y <= 9).named("c1")              // collides with the default of row 0
                XY.x - XY.y <= 3
            }
        let compiled = try model.compile()
        let rows = compiled.lp.names.rows
        #expect(rows[1] == "c1" && rows[2] == "c3")
        #expect(rows[0] != "c1" && Set(rows).count == 3)
        #expect(compiled.rowNamed == ["c1": 1])
    }

    // MARK: Diagnostics (§5.2)

    @Test func nonFiniteCoefficientsAreRejected() {
        let objective = invalidModelDiagnostic { try LPModel<XY>().minimizing(Double.infinity * XY.x).compile() }
        #expect(objective?.kind == .nonFiniteCoefficient(variable: "x", location: "the objective"))
        #expect(objective?.severity == .error)

        let nan = invalidModelDiagnostic { try LPModel<XY>().minimizing(Double.nan * XY.z(2) + XY.x).compile() }
        #expect(nan?.kind == .nonFiniteCoefficient(variable: "z[2]", location: "the objective"))

        let row = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).subjectTo(XY.x + XY.y / 0 <= 1).compile()
        }
        #expect(row?.kind == .nonFiniteCoefficient(variable: "y", location: "constraint #1"))

        let namedRow = invalidModelDiagnostic {
            try LPModel<XY>().subjectTo((Double.nan * XY.x + XY.y <= 1).named("bad")).compile()
        }
        #expect(namedRow?.kind == .nonFiniteCoefficient(variable: "x", location: "constraint bad"))
        #expect(namedRow?.message.contains("bad") == true)
    }

    @Test func nonFiniteConstantsAndBoundsAreRejected() {
        let constant = invalidModelDiagnostic { try LPModel<XY>().minimizing(XY.x + Double.nan).compile() }
        #expect(constant?.kind == .nonFiniteValue(location: "the objective constant"))
        let infiniteConstant = invalidModelDiagnostic { try LPModel<XY>().minimizing(XY.x + Double.infinity).compile() }
        #expect(infiniteConstant?.kind == .nonFiniteValue(location: "the objective constant"))

        let nanBound = invalidModelDiagnostic { try LPModel<XY>().subjectTo(XY.x + XY.y <= Double.nan).compile() }
        #expect(nanBound?.kind == .nonFiniteValue(location: "a bound of constraint #1"))
        // x + y ≥ +∞ can never hold; an infinite bound on the wrong side is not a usable number.
        let wrongSide = invalidModelDiagnostic { try LPModel<XY>().subjectTo(XY.x + XY.y >= Double.infinity).compile() }
        #expect(wrongSide?.kind == .nonFiniteValue(location: "a bound of constraint #1"))

        let nanVariableBound = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).bounding(.x, Bounds(lower: .nan, upper: 1)).compile()
        }
        #expect(nanVariableBound?.kind == .nonFiniteValue(location: "a bound of variable x"))
        let infiniteLower = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).bounding(.x, Bounds(lower: .infinity, upper: .infinity)).compile()
        }
        #expect(infiniteLower?.kind == .nonFiniteValue(location: "a bound of variable x"))

        // The harmless side is fine: x + y ≤ +∞ is a free row.
        #expect(throws: Never.self) { try LPModel<XY>().subjectTo(XY.x + XY.y <= Double.infinity).compile() }
    }

    @Test func aConstantConstraintThatExcludesZeroIsInfeasibleAtCompileTime() {
        // 0 ≤ −1.
        let literal = invalidModelDiagnostic { try LPModel<XY>().subjectTo(LinearExpr<XY>(0) <= -1).compile() }
        #expect(literal?.kind == .infeasibleConstantConstraint(name: nil, index: 1))
        // The same after cancellation, and named.
        let cancelled = invalidModelDiagnostic {
            try LPModel<XY>().subjectTo {
                XY.x >= 0
                (XY.x - XY.x >= 1).named("never")
            }.compile()
        }
        #expect(cancelled?.kind == .infeasibleConstantConstraint(name: "never", index: 2))
        #expect(cancelled?.message.contains("infeasible") == true)
    }

    @Test func crossedBoundsAreRejected() {
        let variable = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).bounding(.x, Bounds(lower: 3, upper: 1)).compile()
        }
        #expect(variable?.kind == .inconsistentVariableBounds(variable: "x", lower: 3, upper: 1))

        // Two one-variable constraints that contradict each other end up as crossed bounds.
        let singletons = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).subjectTo {
                XY.x >= 3
                XY.x <= 2
            }.compile()
        }
        #expect(singletons?.kind == .inconsistentVariableBounds(variable: "x", lower: 3, upper: 2))

        var crossed = XY.x + XY.y <= 1
        crossed.lower = 5
        let row = invalidModelDiagnostic { try LPModel<XY>().subjectTo(crossed.named("r")).compile() }
        #expect(row?.kind == .inconsistentRowBounds(row: "r", lower: 5, upper: 1))
        let unnamedRow = invalidModelDiagnostic { try LPModel<XY>().subjectTo(crossed).compile() }
        #expect(unnamedRow?.kind == .inconsistentRowBounds(row: "#1", lower: 5, upper: 1))
    }

    @Test func duplicateConstraintNamesAreRejected() {
        let rows = invalidModelDiagnostic {
            try LPModel<XY>().subjectTo {
                (XY.x + XY.y <= 1).named("dup")
                (XY.x - XY.y <= 1).named("dup")
            }.compile()
        }
        #expect(rows?.kind == .duplicateConstraintName("dup"))
        // A lowered singleton and a row share one namespace.
        let mixed = invalidModelDiagnostic {
            try LPModel<XY>().subjectTo {
                (XY.x <= 1).named("dup")
                (XY.x - XY.y <= 1).named("dup")
            }.compile()
        }
        #expect(mixed?.kind == .duplicateConstraintName("dup"))
    }

    @Test func anIntegerVariableCannotBeFixedAtAFraction() {
        let override = invalidModelDiagnostic {
            try LPModel<XY>().minimizing(XY.x).integer(.x).bounding(.x, .fixed(2.5)).compile()
        }
        #expect(override?.kind == .nonIntegralFixedBound(variable: "x", value: 2.5))
        let singleton = invalidModelDiagnostic {
            try LPModel<Mixed>().minimizing(Mixed.count(0)).subjectTo(Mixed.count(0) == 0.5).compile()
        }
        #expect(singleton?.kind == .nonIntegralFixedBound(variable: "count[0]", value: 0.5))
        // An integral fixed value and a fractional but not fixed bound are both fine.
        #expect(throws: Never.self) {
            try LPModel<XY>().minimizing(XY.x).integer(.x).bounding(.x, .fixed(2)).compile()
        }
        #expect(throws: Never.self) {
            try LPModel<XY>().minimizing(XY.x).integer(.x).bounding(.x, .range(0.5...2.5)).compile()
        }
    }

    @Test func tinyCoefficientsAreDroppedWithAWarning() async throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + 1e-15 * XY.y)
            .subjectTo {
                XY.x + 1e-16 * XY.z(0) + XY.z(1) <= 4
                XY.y + XY.z(0) >= 1
            }
        var created: AsyncStream<ModelDiagnostic>.Continuation?
        let stream = AsyncStream<ModelDiagnostic> { created = $0 }
        let continuation = try #require(created)
        var options = CompileOptions()
        options.diagnostics = { continuation.yield($0) }
        let compiled = try model.compile(options: options)
        continuation.finish()
        var reported: [ModelDiagnostic] = []
        for await diagnostic in stream { reported.append(diagnostic) }

        #expect(reported == compiled.diagnostics)
        #expect(reported.count == 2)
        #expect(reported.allSatisfy { $0.severity == .warning })
        #expect(reported[0].kind == .droppedSmallCoefficient(variable: "y", location: "the objective", value: 1e-15))
        #expect(reported[1].kind == .droppedSmallCoefficient(variable: "z[0]", location: "constraint #1", value: 1e-16))
        // The dropped terms still claim their columns (order of first appearance) but store nothing.
        #expect(compiled.variableAt == [.x, .y, .z(0), .z(1)])
        #expect(compiled.lp.c == [1, 0, 0, 0])
        #expect(compiled.lp.a[0, 2] == 0 && compiled.lp.nnz == 4)

        // The threshold is configurable; at zero nothing is dropped.
        var keepAll = CompileOptions()
        keepAll.dropTolerance = 0
        let kept = try model.compile(options: keepAll)
        #expect(kept.diagnostics.isEmpty && kept.lp.c[1] == 1e-15 && kept.lp.nnz == 5)
    }

    @Test func diagnosticsDescribeThemselves() {
        let kinds: [ModelDiagnostic.Kind] = [
            .nonFiniteCoefficient(variable: "v", location: "the objective"),
            .nonFiniteValue(location: "the objective constant"),
            .infeasibleConstantConstraint(name: nil, index: 3),
            .inconsistentVariableBounds(variable: "v", lower: 2, upper: 1),
            .inconsistentRowBounds(row: "r", lower: 2, upper: 1),
            .duplicateConstraintName("dup"),
            .nonIntegralFixedBound(variable: "v", value: 0.5),
            .sizeLimitExceeded(what: "rows", count: 3_000_000_000),
            .droppedSmallCoefficient(variable: "v", location: "the objective", value: 1e-20),
            .syntax(line: 12, message: "oops"),
        ]
        for kind in kinds {
            let diagnostic = ModelDiagnostic(severity: .error, kind: kind, message: "custom")
            #expect(diagnostic.description == "custom")
            #expect(diagnostic.kind == kind)
        }
        let thrown = invalidModelDiagnostic { try LPModel<XY>().subjectTo(LinearExpr<XY>(0) <= -1).compile() }
        #expect(thrown?.message.isEmpty == false)
        #expect(SolverError.invalidModel(thrown!).description.hasPrefix("invalid model: "))
        #expect(SolverError.unsupported("x").description == "unsupported: x")
        #expect(SolverError.internalInconsistency("y").description == "internal inconsistency: y")
    }
}
