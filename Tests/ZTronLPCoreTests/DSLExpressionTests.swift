// Specification §4.3 and §14.2 ("DSL"): canonical expressions, the complete operator set and
// summation.

import Testing
import ZTronLPCore

private struct Unlucky: Error {}

@Suite("DSL · expressions")
struct DSLExpressionTests {
    // MARK: Canonical form

    @Test func repeatedVariablesMerge() {
        let e = XY.x + XY.x
        #expect(e == 2 * XY.x)
        #expect(e.variables == [.x])
        #expect(e.coefficients == [2])
        #expect(e.count == 1)
        #expect(e[.x] == 2)

        var f = LinearExpr<XY>()
        f.add(.y, 1.5)
        f.add(.x, 1)
        f.add(.y, 2.5)
        #expect(f.variables == [.y, .x])          // insertion order is kept
        #expect(f.coefficients == [4, 1])
    }

    @Test func zeroCoefficientsAreNeverStored() {
        #expect((0 * XY.x).isConstant)
        #expect(LinearExpr(XY.x, coefficient: 0).variables.isEmpty)

        var noop = LinearExpr<XY>()
        noop.add(.x, 0)
        #expect(noop.isConstant && noop.count == 0)

        // Cancellation removes the term and keeps the order of the others.
        var e = XY.x + XY.y + XY.z(1)
        e -= XY.y
        #expect(e.variables == [.x, .z(1)])
        #expect(e.coefficients == [1, 1])
        #expect(e[.y] == 0)
        #expect((XY.x - XY.x).isConstant)
        #expect((XY.x - XY.x) == LinearExpr<XY>())
    }

    @Test func cancellationInALongExpressionKeepsTheIndexConsistent() {
        // Twenty terms: long enough for the dictionary index to exist.
        var e = sum(over: 0..<20) { i in Double(i + 1) * XY.z(i) }
        #expect(e.count == 20)
        e -= 5 * XY.z(4)
        #expect(e.count == 19)
        #expect(e.variables == (0..<20).filter { $0 != 4 }.map { XY.z($0) })
        for i in 0..<20 { #expect(e[.z(i)] == (i == 4 ? 0 : Double(i + 1))) }
        // The removed variable can come back; it is appended at the end.
        e.add(.z(4), 7)
        #expect(e.variables.last == .z(4))
        #expect(e[.z(4)] == 7)
        // Merging into entries that moved still finds them.
        e.add(.z(19), 1)
        #expect(e[.z(19)] == 21)
        // Shrink below the index threshold and grow again.
        for i in 0..<19 { e.add(.z(i), -e[.z(i)]) }
        #expect(e.variables == [.z(19)])
        for i in 0..<12 { e.add(.z(100 + i), 1) }
        #expect(e.count == 13)
        #expect(e[.z(111)] == 1 && e[.z(19)] == 21)
    }

    @Test func multiplyingByZeroClearsEverything() {
        var e = XY.x + 2 * XY.y + 3
        e *= 0
        #expect(e == LinearExpr<XY>())
        #expect(e.isConstant && e.constant == 0 && e.variables.isEmpty && e.coefficients.isEmpty)

        #expect((0 * (XY.x + 5)) == LinearExpr<XY>())
        #expect(((XY.x + 5) * 0) == LinearExpr<XY>())
    }

    @Test func underflowToZeroIsDropped() {
        var e = Double.leastNonzeroMagnitude * XY.x + XY.y
        #expect(e.count == 2)
        e *= 0.25                                   // the first coefficient underflows to zero
        #expect(e.variables == [.y])
        #expect(e.coefficients == [0.25])
        // The same through the operator: a product that underflows adds nothing.
        let f = 0.25 * (Double.leastNonzeroMagnitude * XY.x)
        #expect(f.isConstant)
    }

    @Test func equalityAndHashingIgnoreOrder() {
        let a = XY.x + 2 * XY.y + 3
        let b = 3 + 2 * XY.y + XY.x
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
        #expect(a.variables != b.variables)        // the order really differs

        #expect(a != XY.x + 2 * XY.y + 4)          // constant
        #expect(a != XY.x + 3 * XY.y + 3)          // coefficient
        #expect(a != XY.x + 2 * XY.z(0) + 3)       // variable
        #expect(a != XY.x + 3)                     // term count

        // Long expressions (dictionary index) in opposite orders.
        let forward = sum(over: 0..<40) { i in Double(i + 1) * XY.z(i) }
        let backward = sum(over: (0..<40).reversed()) { i in Double(i + 1) * XY.z(i) }
        #expect(forward == backward)
        #expect(forward.hashValue == backward.hashValue)
        var dictionary: [LinearExpr<XY>: Int] = [forward: 1]
        dictionary[backward, default: 0] += 1
        #expect(dictionary.count == 1 && dictionary[forward] == 2)
    }

    @Test func subscriptEvaluationAndDescription() {
        let e = 2 * XY.x - 3 * XY.y + XY.z(4) - 1.5
        #expect(e[.x] == 2 && e[.y] == -3 && e[.z(4)] == 1 && e[.z(5)] == 0)
        #expect(e.constant == -1.5)
        #expect(!e.isConstant)
        let value = e.evaluated { v in
            switch v {
            case .x: return 1
            case .y: return 2
            case .z(let i): return Double(i)
            }
        }
        #expect(value == 2 - 6 + 4 - 1.5)
        #expect(e.description == "2.0 x - 3.0 y + z[4] - 1.5")
        #expect(LinearExpr<XY>().description == "0.0")
        #expect((-XY.x).description == "- x")
        #expect(LinearExpr<XY>(-2).description == "- 2.0")
    }

    @Test func initializers() {
        #expect(LinearExpr<XY>().isConstant)
        #expect(LinearExpr<XY>().constant == 0)
        #expect(LinearExpr<XY>(4.5).constant == 4.5)
        #expect(LinearExpr<XY>(4.5).isConstant)
        #expect(LinearExpr(XY.y) == 1 * XY.y)
        #expect(LinearExpr(XY.y, coefficient: -2.5)[.y] == -2.5)
        #expect(XY.x.linearExpr == LinearExpr(XY.x))
        var reserved = LinearExpr<XY>()
        reserved.reserveCapacity(64)
        for i in 0..<64 { reserved.add(.z(i), 1) }
        #expect(reserved.count == 64 && reserved[.z(63)] == 1)
        reserved.add(constant: 2)
        #expect(reserved.constant == 2)
    }

    // MARK: Operators — exactly three shapes of + and −, prefix −, two of *, one of /

    @Test func additionHasThreeShapes() {
        // expression ∘ expression, in every pairing of variable and LinearExpr.
        let vv = XY.x + XY.y
        #expect(vv[.x] == 1 && vv[.y] == 1 && vv.constant == 0)
        let ev = vv + XY.z(1)
        #expect(ev.variables == [.x, .y, .z(1)])
        let ve = XY.z(2) + vv
        #expect(ve.variables == [.z(2), .x, .y])
        let ee = vv + ev
        #expect(ee[.x] == 2 && ee[.y] == 2 && ee[.z(1)] == 1)
        // expression ∘ Double.
        let ed = vv + 3.5
        #expect(ed.constant == 3.5 && ed.count == 2)
        let vd = XY.x + 1.25
        #expect(vd.constant == 1.25 && vd[.x] == 1)
        // Double ∘ expression.
        let de = 3.5 + vv
        #expect(de == ed)
        let dv = 1.25 + XY.x
        #expect(dv == vd)
    }

    @Test func subtractionHasThreeShapes() {
        let vv = XY.x - XY.y
        #expect(vv[.x] == 1 && vv[.y] == -1)
        let ee = (XY.x + 2 * XY.y + 1) - (XY.y + 4)
        #expect(ee[.x] == 1 && ee[.y] == 1 && ee.constant == -3)
        let ed = vv - 2
        #expect(ed.constant == -2)
        let vd = XY.x - 2.5
        #expect(vd.constant == -2.5 && vd[.x] == 1)
        let de = 10 - (XY.x + 2 * XY.y + 1)
        #expect(de[.x] == -1 && de[.y] == -2 && de.constant == 9)
        let dv = 10 - XY.x
        #expect(dv[.x] == -1 && dv.constant == 10)
    }

    @Test func negationMultiplicationAndDivision() {
        let negatedVariable = -XY.x
        #expect(negatedVariable[.x] == -1)
        let negated = -(XY.x - 2 * XY.y + 3)
        #expect(negated[.x] == -1 && negated[.y] == 2 && negated.constant == -3)

        let left = 2.5 * XY.x
        let right = XY.x * 2.5
        #expect(left == right && left[.x] == 2.5)
        let scaled = 2 * (XY.x + 3 * XY.y + 1)
        #expect(scaled[.x] == 2 && scaled[.y] == 6 && scaled.constant == 2)
        #expect((XY.x + 3 * XY.y + 1) * 2 == scaled)

        let quotient = XY.x / 4
        #expect(quotient[.x] == 0.25)
        let quotientOfSum = (2 * XY.x + 6) / 2
        #expect(quotientOfSum[.x] == 1 && quotientOfSum.constant == 3)
    }

    @Test func compoundAssignment() {
        var e = LinearExpr<XY>()
        e += XY.x                       // a variable
        e += 2 * XY.y                   // an expression
        e += XY.x
        #expect(e[.x] == 2 && e[.y] == 2)
        e -= XY.x
        e -= (XY.y + 1)
        #expect(e[.x] == 1 && e[.y] == 1 && e.constant == -1)
        e *= 3
        #expect(e[.x] == 3 && e[.y] == 3 && e.constant == -3)
        e += 3
        #expect(e.constant == 0)
        e -= 0.5
        #expect(e.constant == -0.5)
        e /= 2
        #expect(e[.x] == 1.5 && e.constant == -0.25)

        // Adding an expression to itself doubles it.
        var doubled = XY.x + 2 * XY.y + 1
        doubled += doubled
        #expect(doubled[.x] == 2 && doubled[.y] == 4 && doubled.constant == 2)
    }

    @Test func integerLiteralsResolveThroughDouble() {
        // Integer literals are Double here; an `Int` variable needs an explicit conversion.
        let e = 2 * XY.x + XY.y * 3 - XY.z(1) / 2 + 7 - 1
        #expect(e[.x] == 2 && e[.y] == 3 && e[.z(1)] == -0.5 && e.constant == 6)
        let k = 3
        let converted = Double(k) * XY.x
        #expect(converted[.x] == 3)
        #expect(type(of: 2 * XY.x) == LinearExpr<XY>.self)
        #expect(type(of: XY.x + 1) == LinearExpr<XY>.self)
    }

    // MARK: Summation

    @Test func sumOverASequence() {
        let e = sum(over: 0..<5) { i in Double(i) * XY.z(i) }
        #expect(e.count == 4)                       // the i = 0 term has a zero coefficient
        #expect(e.variables == [.z(1), .z(2), .z(3), .z(4)])
        let variables = sum(over: [XY.x, XY.y, XY.x]) { $0 }
        #expect(variables[.x] == 2 && variables[.y] == 1)
        let empty = sum(over: [Int]()) { XY.z($0) }
        #expect(empty == LinearExpr<XY>())
        let constants = sum(over: 1...4) { i in XY.x + Double(i) }
        #expect(constants[.x] == 4 && constants.constant == 10)
    }

    @Test func nestedSumAtDepthThree() {
        // No contextual type anywhere: the result type is inferred bottom-up from the closures.
        let e = sum(over: 0..<2) { i in
            sum(over: 0..<3) { j in
                sum(over: 0..<4) { k in Double(100 * i + 10 * j + k + 1) * Grid.cube(i, j, k) }
            }
        }
        #expect(e.count == 24)
        #expect(e[.cube(1, 2, 3)] == 124)
        #expect(e[.cube(0, 0, 0)] == 1)
        #expect(e.variables.first == .cube(0, 0, 0) && e.variables.last == .cube(1, 2, 3))

        // Mixed with operators, as in the specification's worked example.
        let mixed = sum(over: 0..<2) { i in
            10 * Grid.line(i) + sum(over: 0..<3) { j in
                Grid.cell(i, j) + sum(over: 0..<2) { k in 0.5 * Grid.cube(i, j, k) }
            }
        }
        #expect(mixed.count == 2 + 6 + 12)
        #expect(mixed[.line(1)] == 10 && mixed[.cell(1, 2)] == 1 && mixed[.cube(1, 2, 1)] == 0.5)
    }

    @Test func staticSumAlias() {
        let e: LinearExpr<XY> = .sum(over: 0..<3) { XY.z($0) }
        #expect(e == sum(over: 0..<3) { XY.z($0) })
        let scaled = LinearExpr<XY>.sum(over: 0..<3) { i in 2 * XY.z(i) }
        #expect(scaled[.z(2)] == 2)
    }

    @Test func sumRethrows() {
        func term(_ i: Int) throws -> LinearExpr<XY> {
            if i == 2 { throw Unlucky() }
            return 1 * XY.z(i)
        }
        #expect(throws: Unlucky.self) { try sum(over: 0..<4) { try term($0) } }
        #expect(throws: Unlucky.self) { try LinearExpr<XY>.sum(over: 0..<4) { try term($0) } }
        let fine = try? sum(over: 0..<2) { try term($0) }
        #expect(fine?.count == 2)
    }

    @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
    @Test(.timeLimit(.minutes(1)))
    func sumIsLinearTime() {
        // 200,000 terms in one pass; a quadratic implementation would not finish in the limit.
        let n = 200_000
        let e = sum(over: 0..<n) { i in Double(i % 7 + 1) * XY.z(i) }
        #expect(e.count == n)
        #expect(e[.z(n - 1)] == Double((n - 1) % 7 + 1))
        var accumulated = LinearExpr<XY>()
        for i in 0..<n { accumulated += XY.z(i) }
        #expect(accumulated.count == n)
    }

    // MARK: A user-defined expression type

    @Test func customLinearExpressibleTypesJoinTheAlgebra() {
        struct Twice: LinearExpressible {
            let variable: XY
            var linearExpr: LinearExpr<XY> { 2 * variable }
        }
        let e = Twice(variable: .x) + XY.y - Twice(variable: .y) + 3 * Twice(variable: .z(0))
        #expect(e[.x] == 2 && e[.y] == -1 && e[.z(0)] == 6)
        var acc = LinearExpr<XY>()
        acc += Twice(variable: .x)
        acc -= Twice(variable: .x)
        #expect(acc.isConstant)
        let total = sum(over: [XY.x, XY.y]) { Twice(variable: $0) }
        #expect(total[.x] == 2 && total[.y] == 2)
    }

    @Test func expressionsAreSendableValues() {
        requireSendable(LinearExpr<XY>.self)
        requireSendable(LinearConstraint<XY>.self)
        requireSendable(LPModel<XY>.self)
        // Value semantics: a copy does not see later mutations.
        var original = XY.x + XY.y
        let copy = original
        original += XY.z(1)
        #expect(copy.count == 2 && original.count == 3)
    }
}
