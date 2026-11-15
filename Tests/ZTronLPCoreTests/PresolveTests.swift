// Specification §5.3 and §14.2 ("Presolve/postsolve"): every rule and its postsolve, on
// problems small enough to solve by hand. No engine is involved: the optimal primal and dual
// values of each reduced problem are worked out in the comments and fed to the postsolve.

import Testing
import ZTronLPCore
import ZTronLPTestSupport

private func maxAbsDifference(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { Swift.max($0, abs($1.0 - $1.1)) }
}

/// The number of basic entries of a basis.
private func basicCount(_ basis: Basis) -> Int {
    basis.status.filter { $0 == .basic }.count
}

/// Σ over rows of y·(the bound the sign of y selects) plus Σ over columns of d·(the bound the
/// sign of d selects): the dual objective of the minimization form, without the constant.
/// Values within rounding noise of zero select no bound (the bound may be infinite).
private func dualObjective(_ lp: CompiledLP, _ y: [Double]) -> Double {
    let d = lp.reducedCosts(forDuals: y)
    var total = 0.0
    for i in 0..<lp.m where abs(y[i]) > 1e-9 { total += y[i] * (y[i] > 0 ? lp.rl[i] : lp.ru[i]) }
    for j in 0..<lp.n where abs(d[j]) > 1e-9 { total += d[j] * (d[j] > 0 ? lp.xl[j] : lp.xu[j]) }
    return total
}

@Suite("Presolve and postsolve")
struct PresolveTests {
    // MARK: Modes

    @Test func offIsTheIdentity() {
        let lp = denseLP(rows: [[1, 1]], rl: [1], ru: [inf], c: [1, 2], xl: [0, 3], xu: [inf, 3])
        let pre = Presolve.run(lp, mode: .off)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced == lp && pre.original == lp)
        #expect(pre.isIdentityMapping && pre.removedRows == 0 && pre.removedColumns == 0)
        #expect(pre.columnOrigin == [0, 1] && pre.rowOrigin == [0])
        #expect(pre.expandPrimal([4, 3]) == [4, 3])
        #expect(pre.expandDual([1.5]) == [1.5])
        #expect(pre.reducePrimal([4, 3]) == [4, 3])
        let basis = Basis.allLogical(for: lp)
        #expect(pre.expandBasis(basis) == basis && pre.reduceBasis(basis) == basis)
        #expect(Presolve.identity(lp).reduced == lp)
    }

    // MARK: Rule 1 — fixed columns (and the singleton row they leave behind)

    /// min x + 2y + 3z   s.t.  x + y + z ≥ 4,  x − z ≤ 1,  z = 1,  x, y ≥ 0.
    ///
    /// Substituting z = 1 leaves x + y ≥ 3 and the singleton row x ≤ 2, which becomes a bound.
    /// Reduced problem: min x + 2y + 3 s.t. x + y ≥ 3, 0 ≤ x ≤ 2, y ≥ 0. Its optimum is
    /// x = 2, y = 1 (objective 7); the row's dual is 2 (y is basic: 2 − dual = 0) and x rests
    /// on its upper bound with reduced cost 1 − 2 = −1.
    private static let fixedColumnProblem = denseLP(
        rows: [[1, 1, 1], [1, 0, -1]], rl: [4, -inf], ru: [inf, 1], c: [1, 2, 3], xl: [0, 0, 1], xu: [inf, inf, 1])

    @Test func fixedColumnsAreSubstituted() {
        let lp = Self.fixedColumnProblem
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.n == 2 && pre.reduced.m == 1)
        #expect(pre.removedColumns == 1 && pre.removedRows == 1)
        #expect(pre.columnOrigin == [0, 1] && pre.rowOrigin == [0])
        #expect(pre.reduced.c == [1, 2] && pre.reduced.c0 == 3)
        #expect(pre.reduced.rl == [3] && pre.reduced.ru == [inf])
        #expect(pre.reduced.xl == [0, 0] && pre.reduced.xu == [2, inf])
        #expect(pre.reduced.a[0, 0] == 1 && pre.reduced.a[0, 1] == 1 && pre.reduced.nnz == 2)
        #expect(pre.reduced.names.columns == ["x1", "x2"] && pre.reduced.names.rows == ["c1"])
        #expect(pre.unboundedColumn == nil)
        #expect(!pre.isIdentityMapping)

        // Primal.
        let x = pre.expandPrimal([2, 1])
        #expect(x == [2, 1, 1])
        #expect(lp.internalObjective(at: x) == 7)
        #expect(pre.reduced.internalObjective(at: [2, 1]) == 7)
        #expect(pre.reducePrimal(x) == [2, 1])
        let violation = lp.maxViolation(at: x)
        #expect(violation.bounds == 0 && violation.rows == 0)
    }

    @Test func theDualOfARemovedSingletonRowComesFromTheReducedCost() {
        let lp = Self.fixedColumnProblem
        let pre = Presolve.run(lp)
        // The removed row x − z ≤ 1 created the bound x ≤ 2 that x rests on, so it takes x's
        // reduced cost: −1 / (+1) = −1. A row at its upper bound has a nonpositive dual.
        let y = pre.expandDual([2])
        #expect(y == [2, -1])
        let d = lp.reducedCosts(forDuals: y)
        #expect(d == [0, 0, 0, 2, -1])                    // x is basic in the original problem
        // Strong duality in the original problem: 2·4 + (−1)·1 = 7.
        #expect(dualObjective(lp, y) == 7)
    }

    @Test func aBasisIsMappedBothWays() {
        let lp = Self.fixedColumnProblem
        let pre = Presolve.run(lp)
        // Optimal basis of the reduced problem: y basic, x at its upper bound, the row's
        // logical at its lower bound.
        let reduced = Basis(status: [.atUpper, .basic, .atLower], basic: [1])
        let expanded = pre.expandBasis(reduced)
        // In the original problem x has no upper bound: it is basic and the logical of the
        // removed row is the one that is nonbasic, at the row's upper bound. z is fixed.
        #expect(expanded.status == [.basic, .basic, .fixed, .atLower, .atUpper])
        #expect(basicCount(expanded) == lp.m)
        #expect(expanded.basic.count == lp.m && Set(expanded.basic) == [0, 1])
        #expect(expanded.basic.first == 1)                // kept basics first, in the reduced order

        let back = pre.reduceBasis(expanded)
        #expect(back.status == reduced.status)
        #expect(back.basic == reduced.basic)

        // A basis of the wrong size is answered with the all-logical basis of the reduced problem.
        let nonsense = Basis(status: [.basic], basic: [0])
        #expect(pre.reduceBasis(nonsense) == Basis.allLogical(for: pre.reduced))
    }

    // MARK: Rule 2 — singleton rows

    /// min 3x + y   s.t.  x ≥ 1,  2x ≥ 4,  x + y ≥ 5,  x, y ≥ 0.
    ///
    /// Both singleton rows become bounds; the second is the tighter one (x ≥ 2). Reduced
    /// problem: min 3x + y s.t. x + y ≥ 5, x ≥ 2, y ≥ 0, optimum x = 2, y = 3 (objective 9),
    /// row dual 1, reduced cost of x = 3 − 1 = 2.
    private static let twoSingletons = denseLP(
        rows: [[1, 0], [2, 0], [1, 1]], rl: [1, 4, 5], ru: [inf, inf, inf], c: [3, 1], xl: [0, 0], xu: [inf, inf])

    @Test func ofSeveralRowsOnOneColumnTheTightestClaimsTheDual() {
        let lp = Self.twoSingletons
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.m == 1 && pre.reduced.n == 2 && pre.rowOrigin == [2])
        #expect(pre.reduced.xl == [2, 0] && pre.reduced.xu == [inf, inf])

        // 2x ≥ 4 is the active one: its dual is 2 / 2 = 1; x ≥ 1 is slack and gets 0.
        let y = pre.expandDual([1])
        #expect(y == [0, 1, 1])
        #expect(lp.reducedCosts(forDuals: y) == [0, 0, 0, 1, 1])
        #expect(dualObjective(lp, y) == 9)                // 1·4 + 1·5
        #expect(lp.internalObjective(at: pre.expandPrimal([2, 3])) == 9)

        // The same rows in the opposite order: the weaker one, now second, tightens nothing.
        let swapped = denseLP(
            rows: [[2, 0], [1, 0], [1, 1]], rl: [4, 1, 5], ru: [inf, inf, inf], c: [3, 1], xl: [0, 0], xu: [inf, inf])
        #expect(Presolve.run(swapped).expandDual([1]) == [1, 0, 1])
    }

    @Test func aSlackSingletonRowGetsAZeroDual() {
        // With cost x + y the reduced optimum has x strictly above its bound (any point of
        // x + y = 5 with x ≥ 2): the reduced cost of x is 0 and no removed row takes anything.
        let lp = denseLP(
            rows: [[1, 0], [2, 0], [1, 1]], rl: [1, 4, 5], ru: [inf, inf, inf], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        #expect(Presolve.run(lp).expandDual([1]) == [0, 0, 1])
    }

    @Test func aNegativeCoefficientFlipsTheSideOfTheBound() {
        // min −x  s.t.  −2x ≥ −6,  x ≥ 0.   The row is x ≤ 3; everything is presolved away.
        let lp = denseLP(rows: [[-2]], rl: [-6], ru: [inf], c: [-1], xl: [0], xu: [inf])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .solved)
        #expect(pre.reduced.n == 0 && pre.reduced.m == 0)
        #expect(pre.reduced.c0 == -3)
        #expect(pre.expandPrimal([]) == [3])
        // d = −1 on the upper bound the row created: dual = −1 / −2 = 0.5 ≥ 0, as it must be
        // for a row resting on its lower bound. Dual objective: 0.5 · (−6) = −3.
        let y = pre.expandDual([])
        #expect(y == [0.5])
        #expect(dualObjective(lp, y) == -3)
        // Basis: x is basic (its value is set by the row); the row's logical is at its lower bound.
        let basis = pre.expandBasis(Basis(status: [], basic: []))
        #expect(basis.status == [.basic, .atLower])
        #expect(basis.basic == [0])
        #expect(pre.reduceBasis(basis) == Basis(status: [], basic: []))
    }

    @Test func anEqualitySingletonFixesItsColumn() {
        // min x + y  s.t.  2x = 3,  x + y ≥ 4.   x = 1.5 is substituted, then y ≥ 2.5 is a bound.
        let lp = denseLP(rows: [[2, 0], [1, 1]], rl: [3, 4], ru: [3, inf], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .solved)
        #expect(pre.expandPrimal([]) == [1.5, 2.5])
        #expect(pre.reduced.c0 == 4)
        // Duals: y basic ⇒ dual of row 2 is 1; x basic ⇒ 1 − 2·y₁ − 1 = 0 ⇒ y₁ = 0.
        #expect(pre.expandDual([]) == [0, 1])
        let basis = pre.expandBasis(Basis(status: [], basic: []))
        #expect(basis.status == [.basic, .basic, .fixed, .atLower])
        #expect(basicCount(basis) == 2)
    }

    // MARK: Rule 3 — empty rows

    @Test func emptyRowsAreCheckedAndRemoved() {
        // Row 0 has no entries and allows zero; row 1 is an ordinary row.
        let feasible = denseLP(rows: [[0, 0], [1, 1]], rl: [-1, 2], ru: [2, inf], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        let pre = Presolve.run(feasible)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.m == 1 && pre.rowOrigin == [1])
        #expect(pre.expandDual([1]) == [0, 1])
        let basis = pre.expandBasis(Basis(status: [.basic, .atLower, .atLower], basic: [0]))
        #expect(basis.status == [.basic, .atLower, .basic, .atLower])      // the empty row's logical is basic
        #expect(basicCount(basis) == 2)

        // 1 ≤ 0 ≤ 2 cannot hold.
        let infeasible = denseLP(rows: [[0, 0], [1, 1]], rl: [1, 2], ru: [2, inf], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        guard case .infeasible(let reason) = Presolve.run(infeasible).outcome else {
            Issue.record("an infeasible empty row was accepted")
            return
        }
        #expect(reason.contains("c1"))
    }

    @Test func aRowEmptiedBySubstitutionIsChecked() {
        // z is fixed at 1. "z ≤ 1.5" becomes "0 ≤ 0.5" and is dropped; "z ≤ 0.5" becomes
        // "0 ≤ −0.5" and proves infeasibility.
        let fine = denseLP(rows: [[1, 1, 0], [0, 0, 1]], rl: [1, -inf], ru: [inf, 1.5], c: [1, 1, 1], xl: [0, 0, 1], xu: [inf, inf, 1])
        let pre = Presolve.run(fine)
        #expect(pre.outcome == .reduced && pre.reduced.m == 1 && pre.reduced.n == 2)
        #expect(pre.expandPrimal([1, 0]) == [1, 0, 1])

        let broken = denseLP(rows: [[1, 1, 0], [0, 0, 1]], rl: [1, -inf], ru: [inf, 0.5], c: [1, 1, 1], xl: [0, 0, 1], xu: [inf, inf, 1])
        guard case .infeasible = Presolve.run(broken).outcome else {
            Issue.record("0 <= -0.5 was accepted")
            return
        }
    }

    // MARK: Rule 4 — empty columns

    @Test func emptyColumnsGoToTheBoundThatImprovesTheObjective() {
        // No rows at all: every column is empty.
        let lp = denseLP(
            rows: [], rl: [], ru: [], c: [2, -3, 0, 0, 0, 0], xl: [1, 1, -inf, -inf, 5, 2],
            xu: [4, 4, 7, inf, inf, 2], c0: 1)
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .solved)
        #expect(pre.unboundedColumn == nil)
        // cost > 0 → lower; cost < 0 → upper; cost 0 → a finite bound, or 0 for a free column.
        #expect(pre.expandPrimal([]) == [1, 4, 7, 0, 5, 2])
        #expect(pre.reduced.c0 == 1 + 2 - 12)
        let basis = pre.expandBasis(Basis(status: [], basic: []))
        #expect(basis.status == [.atLower, .atUpper, .atUpper, .free, .atLower, .fixed])
        #expect(basis.basic.isEmpty)
    }

    @Test func anEmptyColumnThatImprovesForeverIsRecordedNotDecided() {
        // min −x, x ≥ 0 and nothing else: unbounded if the rest is feasible, which presolve
        // cannot know in general. The column is parked at a finite value and reported.
        let up = denseLP(rows: [], rl: [], ru: [], c: [-1], xl: [0], xu: [inf])
        let preUp = Presolve.run(up)
        #expect(preUp.outcome == .solved)
        #expect(preUp.unboundedColumn == 0 && preUp.unboundedDirection == 1)
        #expect(preUp.expandPrimal([]) == [0])
        #expect(preUp.expandPrimalRay([]) == [0])

        let down = denseLP(rows: [[1, 1, 0]], rl: [1], ru: [inf], c: [1, 1, 1], xl: [0, 0, -inf], xu: [inf, inf, 5])
        let preDown = Presolve.run(down)
        #expect(preDown.outcome == .reduced)
        #expect(preDown.unboundedColumn == 2 && preDown.unboundedDirection == -1)
        #expect(preDown.reduced.n == 2)
        #expect(preDown.expandPrimal([1, 0]) == [1, 0, 5])            // parked at its finite bound
        // A ray of the reduced problem does not move the removed column.
        #expect(preDown.expandPrimalRay([1, -1]) == [1, -1, 0])
    }

    // MARK: Rule 6 — integer bounds

    @Test func fractionalBoundsOfIntegerColumnsAreRoundedInward() {
        let lp = denseLP(
            rows: [[1, 1, 1, 1]], rl: [1], ru: [inf], c: [1, 1, 1, 1], xl: [0.2, -2.5, 1.0000000001, 0.5],
            xu: [3.7, -0.5, 4.9999999999, 9.5], integer: [0, 1, 2])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.xl == [1, -2, 1, 0.5])        // the continuous column is left alone
        #expect(pre.reduced.xu == [3, -1, 5, 9.5])
        #expect(pre.reduced.integerColumns == [0, 1, 2])

        // No integer fits between 0.3 and 0.6.
        let empty = denseLP(rows: [[1, 1]], rl: [1], ru: [inf], c: [1, 1], xl: [0.3, 0], xu: [0.6, inf], integer: [0])
        guard case .infeasible = Presolve.run(empty).outcome else {
            Issue.record("an integer column with no integer in its range was accepted")
            return
        }

        // Rounding can fix a column, which is then substituted.
        let fixing = denseLP(rows: [[1, 1]], rl: [4], ru: [inf], c: [1, 1], xl: [1.5, 0], xu: [2.5, inf], integer: [0])
        let fixed = Presolve.run(fixing)
        #expect(fixed.outcome == .solved)
        #expect(fixed.expandPrimal([]) == [2, 2])         // x = 2, then y ≥ 2 from the singleton row
    }

    @Test func aSingletonRowOnAnIntegerColumnIsRoundedOnTheNextPass() {
        // 2x ≥ 3 gives x ≥ 1.5; x is integer, so x ≥ 2.
        let lp = denseLP(rows: [[2, 0], [1, 1]], rl: [3, 0], ru: [inf, 10], c: [1, 1], xl: [0, 0], xu: [inf, inf], integer: [0])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.xl == [2, 0] && pre.reduced.m == 1)
        #expect(Presolve.run(lp, mode: .boundsOnly).reduced.xl == [2, 0])
    }

    @Test func boundsThatCrossByRoundingNoiseDescribeAFixedColumn() {
        // lower = 1 + 1e-9 and upper = 1: within the feasibility tolerance, so the column is
        // fixed (at the midpoint) instead of making the problem infeasible.
        let lp = denseLP(rows: [[1, 1]], rl: [3], ru: [inf], c: [1, 1], xl: [1 + 1e-9, 0], xu: [1, inf])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .solved)
        let x = pre.expandPrimal([])
        #expect(abs(x[0] - 1) <= 1e-9 && abs(x[1] - 2) <= 1e-9)
        // A real crossing is infeasible.
        let crossed = denseLP(rows: [[1, 1]], rl: [3], ru: [inf], c: [1, 1], xl: [1.5, 0], xu: [1, inf])
        guard case .infeasible(let reason) = Presolve.run(crossed).outcome else {
            Issue.record("crossed bounds were accepted")
            return
        }
        #expect(reason.contains("x1"))
    }

    // MARK: Fixed point

    @Test func theRulesRunToAFixedPoint() {
        // x₀ = 1,  x₀ + x₁ = 3,  x₁ + x₂ = 5,  x₂ + x₃ = 7: each pass fixes one more column.
        let lp = denseLP(
            rows: [[1, 0, 0, 0], [1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1]], rl: [1, 3, 5, 7], ru: [1, 3, 5, 7],
            c: [1, 1, 1, 1], xl: [0, 0, 0, 0], xu: [inf, inf, inf, inf])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .solved)
        #expect(pre.removedRows == 4 && pre.removedColumns == 4)
        let x = pre.expandPrimal([])
        #expect(x == [1, 2, 3, 4])
        #expect(pre.reduced.c0 == 10)
        // Aᵀy = c from the last row back: y₃ = 1, y₂ = 0, y₁ = 1, y₀ = 0.
        let y = pre.expandDual([])
        #expect(y == [0, 1, 0, 1])
        #expect(lp.reducedCosts(forDuals: y)[0..<4].allSatisfy { $0 == 0 })
        #expect(dualObjective(lp, y) == 10)
        // Every column is basic and every (equality) logical is fixed.
        let basis = pre.expandBasis(Basis(status: [], basic: []))
        #expect(basis.status == [.basic, .basic, .basic, .basic, .fixed, .fixed, .fixed, .fixed])
        #expect(Set(basis.basic) == [0, 1, 2, 3])
    }

    @Test func aChainLongerThanThePassLimitLeavesAConsistentRemainder() {
        // The same chain with 16 links needs more than the 10 passes the rules are given.
        let n = 16
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var rhs = [Double](repeating: 0, count: n)
        for i in 0..<n {
            rows[i][i] = 1
            if i > 0 { rows[i][i - 1] = 1 }
            rhs[i] = Double(2 * i + 1)                    // solution x_i = i + 1
        }
        let lp = denseLP(
            rows: rows, rl: rhs, ru: rhs, c: [Double](repeating: 1, count: n),
            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: inf, count: n))
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.n > 0 && pre.reduced.n < n)
        #expect(pre.reduced.n + pre.removedColumns == n && pre.reduced.m + pre.removedRows == n)
        // The remainder is still the chain: its solution extends to the original one.
        let truth = (0..<n).map { Double($0 + 1) }
        let x = pre.expandPrimal(pre.reducePrimal(truth))
        #expect(x == truth)
        let violation = pre.reduced.maxViolation(at: pre.reducePrimal(truth))
        #expect(violation.bounds == 0 && violation.rows == 0)
    }

    // MARK: Bounds-only mode

    @Test func boundsOnlyKeepsEveryRowAndColumn() {
        // An integer column with fractional bounds, a singleton row and a fixed column.
        let lp = denseLP(
            rows: [[2, 0, 0], [1, 1, 1]], rl: [3, 2], ru: [inf, inf], c: [1, 1, 1], xl: [0, 0.5, 4],
            xu: [inf, 2.5, 4], integer: [1])
        let pre = Presolve.run(lp, mode: .boundsOnly)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.n == 3 && pre.reduced.m == 2)
        #expect(pre.isIdentityMapping && pre.removedRows == 0 && pre.removedColumns == 0)
        #expect(pre.reduced.a == lp.a && pre.reduced.c == lp.c && pre.reduced.c0 == lp.c0)
        #expect(pre.reduced.rl == lp.rl && pre.reduced.ru == lp.ru)        // rows are untouched
        #expect(pre.reduced.xl == [1.5, 1, 4])                              // singleton row, rounding
        #expect(pre.reduced.xu == [inf, 2, 4])
        #expect(pre.expandPrimal([1.5, 1, 4]) == [1.5, 1, 4])
        #expect(pre.columnOrigin == [0, 1, 2] && pre.rowOrigin == [0, 1])

        let infeasible = denseLP(
            rows: [[1, 0], [1, 1]], rl: [5, 0], ru: [inf, inf], c: [1, 1], xl: [0, 0], xu: [3, inf])
        guard case .infeasible = Presolve.run(infeasible, mode: .boundsOnly).outcome else {
            Issue.record("x >= 5 with x <= 3 was accepted")
            return
        }
    }

    // MARK: Rays

    @Test func aDualRayIsHandedBackToTheRowThatCreatedTheBound() {
        // x ≥ 5 (a singleton row), x + y ≤ 3, x, y ≥ 0: infeasible.
        let lp = denseLP(rows: [[1, 0], [1, 1]], rl: [5, -inf], ru: [inf, 3], c: [0, 0], xl: [0, 0], xu: [inf, inf])
        let pre = Presolve.run(lp)
        #expect(pre.outcome == .reduced)
        #expect(pre.reduced.m == 1 && pre.reduced.xl == [5, 0])
        // In the reduced problem y' = −1 on x + y ≤ 3 is a Farkas ray: it needs x ≥ 5.
        let ray = pre.expandDual([-1], objective: false)
        #expect(ray == [1, -1])
        // The certificate in the original problem: Σ y·(bound the sign selects) > 0 while
        // Aᵀy uses only bounds that exist.
        let z = lp.a.multiplyTranspose(ray)
        #expect(z == [0, -1])                             // y's coefficient is negative: uses its lower bound 0
        var value = 0.0
        for i in 0..<lp.m { value += ray[i] * (ray[i] > 0 ? lp.rl[i] : lp.ru[i]) }
        for j in 0..<lp.n where z[j] != 0 { value -= z[j] * (z[j] > 0 ? lp.xu[j] : lp.xl[j]) }
        #expect(value == 2)
    }

    // MARK: Consistency on random problems

    @Test func postsolveInvariantsHoldOnRandomProblems() {
        for seed in 0..<60 {
            let lp = RandomProblems.everyShape(rows: 3 + seed % 7, columns: 4 + seed % 9, seed: UInt64(seed) &* 31 &+ 5)
            let pre = Presolve.run(lp)
            if case .infeasible = pre.outcome { continue }
            let reduced = pre.reduced
            #expect(reduced.n == pre.columnOrigin.count && reduced.m == pre.rowOrigin.count, "seed \(seed)")
            #expect(pre.columnOrigin == pre.columnOrigin.sorted() && pre.rowOrigin == pre.rowOrigin.sorted())
            #expect(reduced.integerColumns == reduced.integerColumns.sorted(), "seed \(seed)")
            #expect(reduced.aT == reduced.a.transposed(), "seed \(seed)")

            // A point of the reduced problem expands to a point with the same objective and
            // the same row activities on the kept rows (up to the substituted constants).
            var rng = SeededGenerator(seed: UInt64(seed))
            let point = (0..<reduced.n).map { j -> Double in
                let lo = reduced.xl[j] > -inf ? reduced.xl[j] : -3
                let hi = reduced.xu[j] < inf ? reduced.xu[j] : lo + 6
                return rng.uniform(in: Swift.min(lo, hi)...Swift.max(lo, hi))
            }
            let full = pre.expandPrimal(point)
            #expect(full.count == lp.n)
            #expect(pre.reducePrimal(full) == point, "seed \(seed)")
            let scale = 1 + abs(lp.internalObjective(at: full))
            #expect(abs(lp.internalObjective(at: full) - reduced.internalObjective(at: point)) <= 1e-9 * scale, "seed \(seed)")

            // Any basis of the reduced problem expands to one with exactly m basic columns,
            // and comes back unchanged.
            var status = [BasisStatus](repeating: .atLower, count: reduced.n + reduced.m)
            var basic: [Int32] = []
            for k in 0..<reduced.m {
                // Alternate between logical and structural basics where a structural exists.
                let index = (k % 2 == 0 || k >= reduced.n) ? reduced.n + k : k
                status[index] = .basic
                basic.append(Int32(index))
            }
            for j in 0..<reduced.n where status[j] != .basic {
                status[j] = Basis.nonbasicStatus(lower: reduced.xl[j], upper: reduced.xu[j])
            }
            let basis = Basis(status: status, basic: basic)
            let expanded = pre.expandBasis(basis)
            #expect(expanded.status.count == lp.n + lp.m, "seed \(seed)")
            #expect(basicCount(expanded) == lp.m, "seed \(seed)")
            #expect(expanded.basic.count == lp.m && Set(expanded.basic).count == lp.m, "seed \(seed)")
            #expect(expanded.basic.allSatisfy { expanded.status[Int($0)] == .basic }, "seed \(seed)")
            let back = pre.reduceBasis(expanded)
            #expect(back.status == basis.status, "seed \(seed)")
            #expect(Set(back.basic) == Set(basis.basic), "seed \(seed)")
        }
    }

    /// Oracle: problems with a known optimal primal-dual pair (§14.1, oracle 1), decorated
    /// with everything the presolve removes — bounds moved into singleton rows of either sign
    /// and side, fixed columns, an empty row. The reduced problem must keep the pair optimal,
    /// and the postsolved duals must be optimal for the original problem.
    @Test func postsolvedDualsAreOptimalOnConstructedProblems() {
        var singletonRows = 0
        var removedColumns = 0
        for seed in 0..<120 {
            var rng = SeededGenerator(seed: UInt64(seed) &* 977 &+ 13)
            var options = ConstructedOptions()
            options.density = 0.35
            options.rangeRows = seed % 3 == 0
            options.freeColumns = seed % 4 == 0
            options.degenerate = seed % 5 == 0
            let base = InstanceGenerator.constructedOptimum(
                rows: 4 + seed % 9, columns: 6 + seed % 13, seed: UInt64(seed), options: options)
            let lp = base.lp
            var x = base.primal
            var y = base.dual
            let d = lp.reducedCosts(forDuals: y)

            var entries: [(row: Int, col: Int, value: Double)] = []
            for j in 0..<lp.n {
                for p in lp.a.range(ofColumn: j) { entries.append((Int(lp.a.rowIndex[p]), j, lp.a.values[p])) }
            }
            var c = lp.c
            var xl = lp.xl
            var xu = lp.xu
            var rl = lp.rl
            var ru = lp.ru

            // Move the bound a column rests on into a singleton row; its dual is d / a.
            for j in 0..<lp.n where rng.chance(0.45) {
                let a = (rng.chance(0.5) ? 1.0 : -1.0) * rng.uniform(in: 0.5...3)
                let row = rl.count
                if d[j] > 1e-9, x[j] == xl[j] {
                    // a·x ≥ a·l for a > 0, a·x ≤ a·l for a < 0.
                    rl.append(a > 0 ? a * xl[j] : -inf)
                    ru.append(a > 0 ? inf : a * xl[j])
                    xl[j] = rng.chance(0.5) ? -inf : xl[j] - rng.uniform(in: 0.5...2)
                } else if d[j] < -1e-9, x[j] == xu[j] {
                    rl.append(a > 0 ? -inf : a * xu[j])
                    ru.append(a > 0 ? a * xu[j] : inf)
                    xu[j] = rng.chance(0.5) ? inf : xu[j] + rng.uniform(in: 0.5...2)
                } else {
                    continue
                }
                entries.append((row, j, a))
                y.append(d[j] / a)
                singletonRows += 1
            }
            // A fixed column with entries in a few rows: shift those rows by its contribution.
            if seed % 2 == 0 {
                let column = c.count
                let value = rng.uniform(in: -2...2)
                for i in 0..<lp.m where rng.chance(0.4) {
                    let a = rng.uniform(in: -2...2)
                    entries.append((i, column, a))
                    rl[i] += a * value
                    ru[i] += a * value
                }
                c.append(rng.uniform(in: -3...3))
                xl.append(value)
                xu.append(value)
                x.append(value)
            }
            // An empty row that allows zero.
            rl.append(-1)
            ru.append(2)
            y.append(0)

            let decorated = CompiledLP(
                a: SparseCSC.fromTriplets(rows: rl.count, cols: c.count, entries), c: c, xl: xl, xu: xu, rl: rl, ru: ru)
            // The decoration kept the pair optimal (this checks the test, not the presolve).
            #expect(optimalityViolation(decorated, x: x, y: y) <= 1e-7, "seed \(seed): the decorated pair is not optimal")

            let pre = Presolve.run(decorated)
            if case .infeasible(let reason) = pre.outcome {
                Issue.record("seed \(seed): a feasible problem was declared infeasible: \(reason)")
                continue
            }
            removedColumns += pre.removedColumns
            #expect(pre.removedRows >= 1, "seed \(seed)")                        // at least the empty row

            // The reduced problem keeps the pair optimal …
            let reducedX = pre.reducePrimal(x)
            let reducedY = pre.rowOrigin.map { y[Int($0)] }
            #expect(optimalityViolation(pre.reduced, x: reducedX, y: reducedY) <= 1e-7, "seed \(seed): reduced problem")
            let objective = decorated.internalObjective(at: x)
            #expect(abs(pre.reduced.internalObjective(at: reducedX) - objective) <= 1e-8 * (1 + abs(objective)), "seed \(seed)")

            // … and the postsolve gives back an optimal pair of the original one.
            let expandedX = pre.expandPrimal(reducedX)
            #expect(maxAbsDifference(expandedX, x) <= 1e-9, "seed \(seed): primal")
            let expandedY = pre.expandDual(reducedY)
            #expect(optimalityViolation(decorated, x: expandedX, y: expandedY) <= 1e-7, "seed \(seed): postsolved duals")
            #expect(abs(dualObjective(decorated, expandedY) - objective) <= 1e-7 * (1 + abs(objective)), "seed \(seed): dual objective")
        }
        // The decoration really produced what this test is about.
        #expect(singletonRows > 150 && removedColumns > 40)
    }

    @Test func reducedCostsForDuals() {
        // d = c − Aᵀy on the structural columns, y on the logical ones.
        let lp = denseLP(rows: [[1, 2, 0], [0, 1, 3]], rl: [0, 0], ru: [inf, inf], c: [5, 6, 7], xl: [0, 0, 0], xu: [inf, inf, inf])
        #expect(lp.reducedCosts(forDuals: [2, -1]) == [3, 3, 10, 2, -1])
    }
}
