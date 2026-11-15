// Specification §4.4 and §14.2 ("DSL"): comparisons, the `==` sharp edge, constant folding and
// the result builder.

import Testing
import ZTronLPCore

@Suite("DSL · constraints")
struct DSLConstraintTests {
    // MARK: Comparisons — three shapes each

    @Test func lessOrEqual() {
        let ee = XY.x + 2 * XY.y <= XY.z(1)
        #expect(ee.expr == XY.x + 2 * XY.y - XY.z(1))
        #expect(ee.lower == -inf && ee.upper == 0)

        let ed = XY.x + XY.y <= 4
        #expect(ed.expr == XY.x + XY.y && ed.lower == -inf && ed.upper == 4)

        let de = 4 <= XY.x + XY.y                   // 4 ≤ x + y  ⇔  x + y ≥ 4
        #expect(de.expr == XY.x + XY.y && de.lower == 4 && de.upper == inf)

        let vv = XY.x <= XY.y                       // two bare variables
        #expect(vv.expr == XY.x - XY.y && vv.upper == 0 && vv.lower == -inf)
    }

    @Test func greaterOrEqual() {
        let ee = XY.x + 2 * XY.y >= XY.z(1)
        #expect(ee.expr == XY.x + 2 * XY.y - XY.z(1))
        #expect(ee.lower == 0 && ee.upper == inf)

        let ed = XY.x + XY.y >= 4
        #expect(ed.lower == 4 && ed.upper == inf)

        let de = 4 >= XY.x + XY.y                   // 4 ≥ x + y  ⇔  x + y ≤ 4
        #expect(de.expr == XY.x + XY.y && de.lower == -inf && de.upper == 4)
    }

    @Test func equality() {
        let ee: LinearConstraint<XY> = XY.x + 2 * XY.y == XY.z(1) + XY.z(2)
        #expect(ee.expr == XY.x + 2 * XY.y - XY.z(1) - XY.z(2))
        #expect(ee.lower == 0 && ee.upper == 0)

        let ed = XY.x + XY.y == 4
        #expect(ed.lower == 4 && ed.upper == 4)

        let de = 4 == XY.x + XY.y
        #expect(de.expr == XY.x + XY.y && de.lower == 4 && de.upper == 4)

        // A variable against a number has no Equatable reading, so no context is needed.
        let vd = XY.x == 3
        #expect(type(of: vd) == LinearConstraint<XY>.self)
        #expect(vd.lower == 3 && vd.upper == 3)
    }

    // MARK: The `==` sharp edge (§4.4)

    @Test func equalsBetweenTwoValuesOfOneTypeIsABoolWithoutContext() {
        let a = XY.x
        let b = XY.y
        // Untyped: Equatable wins and the result is a Bool.
        let untyped = a == b
        #expect(type(of: untyped) == Bool.self)
        #expect(untyped == false)

        let e1 = XY.x + XY.y
        let e2 = XY.y + XY.x
        let untypedExpressions = e1 == e2
        #expect(type(of: untypedExpressions) == Bool.self)
        #expect(untypedExpressions == true)

        // With a LinearConstraint context the same spelling builds a constraint.
        let typed: LinearConstraint<XY> = a == b
        #expect(typed.expr == XY.x - XY.y && typed.lower == 0 && typed.upper == 0)
        let typedExpressions: LinearConstraint<XY> = e1 == e2
        #expect(typedExpressions.expr.isConstant)   // x + y − (y + x) cancels completely

        // For untyped bindings there is `.equal(to:)`.
        let spelled = a.equal(to: b)
        #expect(type(of: spelled) == LinearConstraint<XY>.self)
        #expect(spelled == typed)
        let spelledNumber = e1.equal(to: 7)
        #expect(spelledNumber.lower == 7 && spelledNumber.upper == 7 && spelledNumber.expr == e1)
    }

    @Test func equalsInsideSubjectToBuildsAConstraint() {
        // Inside the builder the LinearConstraint context selects the right overload; a stray
        // Bool would not compile because the builder has no `buildExpression(Bool)`.
        let model = LPModel<XY>().subjectTo {
            XY.x == XY.y
            XY.x + XY.y == XY.z(0) + XY.z(1)
            XY.z(2) == 3
        }
        #expect(model.constraints.count == 3)
        #expect(model.constraints[0].expr == XY.x - XY.y)
        #expect(model.constraints[0].lower == 0 && model.constraints[0].upper == 0)
        #expect(model.constraints[1].expr == XY.x + XY.y - XY.z(0) - XY.z(1))
        #expect(model.constraints[2].lower == 3 && model.constraints[2].upper == 3)

        // The single-constraint overload gives the same context.
        let single = LPModel<XY>().subjectTo(XY.x == XY.y)
        #expect(single.constraints == [model.constraints[0]])
    }

    // MARK: Constant folding

    @Test func constantsFoldIntoTheBounds() {
        let c = XY.x + 3 <= XY.y + 10               // x − y ≤ 7
        #expect(c.expr.constant == 0)
        #expect(c.expr == XY.x - XY.y)
        #expect(c.upper == 7 && c.lower == -inf)

        let range = (XY.x + XY.y + 1).within(2...5)   // 1 ≤ x + y ≤ 4
        #expect(range.expr.constant == 0 && range.lower == 1 && range.upper == 4)

        let equal = (2 * XY.x - 4).equal(to: XY.y + 6)   // 2x − y = 10
        #expect(equal.expr == 2 * XY.x - XY.y && equal.lower == 10 && equal.upper == 10)

        let numberOnTheLeft = 5 >= XY.x - 2           // x ≤ 7
        #expect(numberOnTheLeft.upper == 7 && numberOnTheLeft.expr == LinearExpr(XY.x))
    }

    @Test func assigningAnExpressionFoldsItsConstant() {
        var c = XY.x <= 5
        c.expr = XY.x + 2 * XY.y + 3                  // x + 2y + 3 ≤ 5  ⇔  x + 2y ≤ 2
        #expect(c.expr.constant == 0)
        #expect(c.expr == XY.x + 2 * XY.y)
        #expect(c.upper == 2 && c.lower == -inf)

        // Mutating the expression in place goes through the same observer.
        var range = XY.x.within(0...10)
        range.expr.add(constant: 4)                    // 0 ≤ x + 4 ≤ 10  ⇔  −4 ≤ x ≤ 6
        #expect(range.expr.constant == 0 && range.lower == -4 && range.upper == 6)
        range.expr += 1
        #expect(range.expr.constant == 0 && range.lower == -5 && range.upper == 5)
        range.expr *= 2                                // no constant: bounds are untouched
        #expect(range.expr == 2 * XY.x && range.lower == -5 && range.upper == 5)
    }

    // MARK: within, named, value semantics

    @Test func withinNamedAndDescription() {
        let c = (XY.x + XY.y).within(1...9)
        #expect(c.lower == 1 && c.upper == 9 && c.name == nil)
        let named = c.named("box")
        #expect(named.name == "box" && c.name == nil)   // `named` returns a copy
        #expect(named.expr == c.expr && named.lower == 1 && named.upper == 9)
        #expect(named != c)
        #expect(named == c.named("box"))
        #expect(Set([named, c.named("box"), c]).count == 2)

        #expect(named.description == "box: 1.0 <= x + y <= 9.0")
        #expect((XY.x <= 2).description == "x <= 2.0")
        #expect((XY.x >= 2).description == "x >= 2.0")
        #expect((XY.x == 2).description == "x = 2.0")
        #expect(XY.x.within(3...3).description == "x = 3.0")

        // The bounds stay editable; `compile()` validates them.
        var edited = XY.x + XY.y <= 4
        edited.lower = 1
        edited.name = "edited"
        #expect(edited.lower == 1 && edited.upper == 4 && edited.name == "edited")
    }

    // MARK: Result builder

    @Test func builderAcceptsLoopsConditionsAndArrays() {
        let enabled = true
        let prebuilt: [LinearConstraint<XY>] = [XY.x >= 1, XY.y >= 2]
        let model = LPModel<XY>().subjectTo {
            XY.x + XY.y <= 10
            for i in 0..<3 {
                XY.z(i) <= Double(i) + XY.x
            }
            if enabled {
                (XY.x - XY.y >= -5).named("gap")
            }
            if !enabled {
                XY.x <= 0
            } else {
                XY.y <= 100
            }
            prebuilt
        }
        #expect(model.constraints.count == 1 + 3 + 1 + 1 + 2)
        #expect(model.constraints[0].upper == 10)
        #expect(model.constraints[1].expr == XY.z(0) - XY.x && model.constraints[1].upper == 0)
        #expect(model.constraints[3].upper == 2)       // z(2) − x ≤ 2
        #expect(model.constraints[4].name == "gap" && model.constraints[4].lower == -5)
        #expect(model.constraints[5].expr == LinearExpr(XY.y) && model.constraints[5].upper == 100)
        #expect(model.constraints[6] == prebuilt[0] && model.constraints[7] == prebuilt[1])
    }

    @Test func builderHandlesEmptyOptionalAndNestedBlocks() {
        let off = false
        let empty = LPModel<XY>().subjectTo {
            if off { XY.x <= 1 }
            for _ in 0..<0 { XY.y <= 1 }
        }
        #expect(empty.constraints.isEmpty)
        let blank = LPModel<XY>().subjectTo {}
        #expect(blank.constraints.isEmpty)

        let nested = LPModel<XY>().subjectTo {
            for i in 0..<2 {
                for j in 0..<3 {
                    if (i + j) % 2 == 0 {
                        (XY.z(10 * i + j) <= 1).named("even[\(i),\(j)]")
                    } else {
                        (XY.z(10 * i + j) >= 1).named("odd[\(i),\(j)]")
                    }
                }
            }
        }
        #expect(nested.constraints.count == 6)
        #expect(nested.constraints.map(\.name) == ["even[0,0]", "odd[0,1]", "even[0,2]", "odd[1,0]", "even[1,1]", "odd[1,2]"])
        #expect(nested.constraints[1].lower == 1 && nested.constraints[1].upper == inf)

        // The builder is usable on its own, too.
        @Constraints<XY> func block(_ k: Int) -> [LinearConstraint<XY>] {
            XY.x <= Double(k)
            XY.y <= Double(k)
        }
        #expect(block(3).count == 2 && block(3)[1].upper == 3)
    }

    @Test func theWorkedExampleOfTheSpecificationTypeChecks() {
        // §4.6: nested sums in the objective, a `for` loop per family, `.named`.
        let model = FacilityExample.model()
        #expect(model.sense == .minimize)
        #expect(model.objective.count == 3 + 12)
        #expect(model.constraints.count == 3 + 4)
        #expect(model.constraints[0].name == "supply[0]")
        // sum_m ship(0, m) − supply(0)·open(0) ≤ 0
        #expect(model.constraints[0].expr[.open(Plant(id: 0))] == -FacilityExample.supply(Plant(id: 0)))
        #expect(model.constraints[0].upper == 0)
        #expect(model.constraints[3].lower == FacilityExample.demand(Market(id: 0)))
        #expect(model.constraints[3].expr.count == 3)
    }
}
