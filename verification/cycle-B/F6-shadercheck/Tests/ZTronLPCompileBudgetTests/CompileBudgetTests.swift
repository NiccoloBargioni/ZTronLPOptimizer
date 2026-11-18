// Specification §4.3 and §14.2: "A compile-time test asserts that a 40-term expression written
// with operators type-checks in under two seconds; model code that grows beyond that should
// use `sum` or `+=`."
//
// The assertion is made by the compiler, not at run time. This target is built with
//
//     -Xfrontend -warn-long-expression-type-checking=2000
//     -Xfrontend -warn-long-function-bodies=4000
//     -warnings-as-errors
//
// (see Package.swift), so an expression that takes two seconds or more to type-check is a
// warning, the warning is an error, and the build of the test bundle fails. The run-time
// checks below only confirm that the expressions mean what they say.

import Testing
import ZTronLPCore

/// An indexed family, as model code has: one variable per pair of indices.
private enum Flow: LPVariable {
    case arc(Int, Int)
    case slack(Int)
}

@Suite("Compile-time budget")
struct CompileBudgetTests {
    /// Forty terms, each `coefficient * variable`, joined by `+` and `-`: the shape §4.3 budgets.
    @Test func aFortyTermOperatorExpressionTypeChecksWithinTheBudget() {
        let e = 1 * Flow.arc(0, 0) + 2 * Flow.arc(0, 1) + 3 * Flow.arc(0, 2) + 4 * Flow.arc(0, 3)
            + 5 * Flow.arc(0, 4) - 6 * Flow.arc(1, 0) + 7 * Flow.arc(1, 1) + 8 * Flow.arc(1, 2)
            + 9 * Flow.arc(1, 3) + 10 * Flow.arc(1, 4) + 11 * Flow.arc(2, 0) - 12 * Flow.arc(2, 1)
            + 13 * Flow.arc(2, 2) + 14 * Flow.arc(2, 3) + 15 * Flow.arc(2, 4) + 16 * Flow.arc(3, 0)
            + 17 * Flow.arc(3, 1) - 18 * Flow.arc(3, 2) + 19 * Flow.arc(3, 3) + 20 * Flow.arc(3, 4)
            + 21 * Flow.arc(4, 0) + 22 * Flow.arc(4, 1) + 23 * Flow.arc(4, 2) - 24 * Flow.arc(4, 3)
            + 25 * Flow.arc(4, 4) + 26 * Flow.arc(5, 0) + 27 * Flow.arc(5, 1) + 28 * Flow.arc(5, 2)
            + 29 * Flow.arc(5, 3) - 30 * Flow.arc(5, 4) + 31 * Flow.arc(6, 0) + 32 * Flow.arc(6, 1)
            + 33 * Flow.arc(6, 2) + 34 * Flow.arc(6, 3) + 35 * Flow.arc(6, 4) - 36 * Flow.arc(7, 0)
            + 37 * Flow.arc(7, 1) + 38 * Flow.arc(7, 2) + 39 * Flow.arc(7, 3) + 40 * Flow.arc(7, 4)
        #expect(e.count == 40)
        #expect(e[.arc(0, 0)] == 1 && e[.arc(1, 0)] == -6 && e[.arc(7, 4)] == 40)
        #expect(e.constant == 0)
    }

    /// Forty bare variables with literal constants mixed in, and the comparison on top: what a
    /// hand-written constraint looks like.
    @Test func aFortyTermConstraintTypeChecksWithinTheBudget() {
        let c = Flow.slack(0) + Flow.slack(1) + Flow.slack(2) + Flow.slack(3) + Flow.slack(4)
            + Flow.slack(5) + Flow.slack(6) + Flow.slack(7) + Flow.slack(8) + Flow.slack(9)
            + Flow.slack(10) + Flow.slack(11) + Flow.slack(12) + Flow.slack(13) + Flow.slack(14)
            + Flow.slack(15) + Flow.slack(16) + Flow.slack(17) + Flow.slack(18) + Flow.slack(19)
            - Flow.slack(20) - Flow.slack(21) - Flow.slack(22) - Flow.slack(23) - Flow.slack(24)
            - Flow.slack(25) - Flow.slack(26) - Flow.slack(27) - Flow.slack(28) - Flow.slack(29)
            + Flow.slack(30) / 2 + Flow.slack(31) / 2 + Flow.slack(32) / 2 + Flow.slack(33) / 2
            + Flow.slack(34) * 3 + Flow.slack(35) * 3 + Flow.slack(36) * 3 + Flow.slack(37) * 3
            + Flow.slack(38) + Flow.slack(39) + 5 <= 100
        #expect(c.expr.count == 40)
        #expect(c.upper == 95 && c.lower == -.infinity)
        #expect(c.expr[.slack(20)] == -1 && c.expr[.slack(30)] == 0.5 && c.expr[.slack(34)] == 3)
    }

    /// Beyond forty terms the advice is `sum` and `+=`: their type-checking cost does not grow
    /// with the number of terms at all.
    @Test func longerExpressionsUseSumAndCompoundAssignment() {
        let rows = 40
        let columns = 25
        let total = sum(over: 0..<rows) { i in
            Double(i + 1) * Flow.slack(i) + sum(over: 0..<columns) { j in Double(i * columns + j) * Flow.arc(i, j) }
        }
        #expect(total.count == rows + rows * columns - 1)          // arc(0, 0) has coefficient 0

        var accumulated = LinearExpr<Flow>()
        for i in 0..<rows {
            accumulated += Double(i + 1) * Flow.slack(i)
            for j in 0..<columns {
                accumulated += Double(i * columns + j) * Flow.arc(i, j)
            }
        }
        #expect(accumulated == total)

        let model = LPModel<Flow>()
            .minimizing(total)
            .subjectTo {
                for i in 0..<rows {
                    sum(over: 0..<columns) { j in Flow.arc(i, j) } + Flow.slack(i) == Double(columns)
                }
                for j in 0..<columns {
                    sum(over: 0..<rows) { i in Flow.arc(i, j) } <= Double(rows) / 2
                }
            }
        #expect(model.constraints.count == rows + columns)
        #expect((try? model.compile().lp.nnz) == rows * columns * 2 + rows)
    }
}
