// Specification §6.3 and §14.2 ("Numerics"): DenseLUBasis and SparseQRBasis against dgesv on
// random bases, eta updates against refactorization, singular bases and their repair.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

/// The two strategies, fresh.
private func strategies() -> [(name: String, basis: any BasisFactorization)] {
    [("DenseLU", DenseLUBasis()), ("SparseQR", SparseQRBasis())]
}

/// Checks `ftran` and `btran` of a factored basis against dgesv on the dense basis matrix.
private func expectSolvesMatchDense(
    _ factorization: any BasisFactorization, basic: [Int32], lp: CompiledLP, seed: UInt64, tolerance: Double = 1e-8,
    _ label: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    var rng = SeededGenerator(seed: seed)
    let b = basisMatrix(basic, lp)
    for _ in 0..<3 {
        let rhs = randomVector(lp.m, &rng, in: -5...5)
        guard let x = denseSolve(b, rhs), let y = denseSolve(b.transposed(), rhs) else {
            Issue.record("\(label): the reference solve failed", sourceLocation: sourceLocation)
            return
        }
        var forward = rhs
        factorization.ftran(&forward)
        var backward = rhs
        factorization.btran(&backward)
        let scale = 1 + Vec.maxAbs(x) + Vec.maxAbs(y)
        #expect(maxDifference(forward, x) <= tolerance * scale, "\(label): ftran", sourceLocation: sourceLocation)
        #expect(maxDifference(backward, y) <= tolerance * scale, "\(label): btran", sourceLocation: sourceLocation)
    }
}

/// Replaces the columns a `.singular` error names by the logical columns of the rows it
/// names — the repair the simplex engine performs — until the basis factors.
private func repair(_ basic: inout [Int32], lp: CompiledLP, rounds limit: Int) -> (factorization: DenseLUBasis, rounds: Int)? {
    var factorization = DenseLUBasis()
    for round in 0...limit {
        do {
            try factorization.refactor(basic: basic, lp: lp)
            return (factorization, round)
        } catch {
            guard case .singular(let positions, let rows) = error, !positions.isEmpty, positions.count == rows.count else {
                return nil
            }
            for (position, row) in zip(positions, rows) { basic[Int(position)] = Int32(lp.n) + row }
        }
    }
    return nil
}

@Suite("Basis factorization")
struct BasisFactorizationTests {
    // MARK: Against dgesv

    @Test(arguments: [
        (4, 0.5), (12, 0.05), (12, 0.9), (40, 0.1), (40, 0.6), (90, 0.03), (90, 0.3), (160, 0.02), (160, 0.15),
    ])
    func randomBasesMatchDenseSolve(_ m: Int, _ density: Double) throws {
        for trial in 0..<4 {
            let seed = UInt64(m * 1000 + trial)
            let lp = matrixLP(rows: m, density: density, seed: seed)
            // From all-structural to mostly logical.
            let basic = mixedBasis(lp, structural: [1.0, 0.7, 0.4, 0.1][trial], seed: seed &+ 7)
            for (name, fresh) in strategies() {
                var factorization = fresh
                try factorization.refactor(basic: basic, lp: lp)
                #expect(factorization.updatesSinceRefactor == 0)
                #expect(!factorization.needsRefactor)
                expectSolvesMatchDense(factorization, basic: basic, lp: lp, seed: seed &+ 11, "\(name) m=\(m) density=\(density) trial \(trial)")
            }
        }
    }

    @Test func theAllLogicalBasisIsMinusTheIdentity() throws {
        let lp = matrixLP(rows: 25, density: 0.3, seed: 1)
        let basic = (0..<lp.m).map { Int32(lp.n + $0) }
        var rng = SeededGenerator(seed: 2)
        let rhs = randomVector(lp.m, &rng)
        for (name, fresh) in strategies() {
            var factorization = fresh
            try factorization.refactor(basic: basic, lp: lp)
            var x = rhs
            factorization.ftran(&x)
            var y = rhs
            factorization.btran(&y)
            #expect(maxDifference(x, rhs.map { -$0 }) <= 1e-14, "\(name)")
            #expect(maxDifference(y, rhs.map { -$0 }) <= 1e-14, "\(name)")
        }
    }

    @Test func aBasisWithNoRowsIsTrivial() throws {
        // A problem with bounds only: the basis is empty and every operation is a no-op.
        let lp = CompiledLP(a: SparseCSC(rows: 0, cols: 3), c: [1, 1, 1], xl: [0, 0, 0], xu: [1, 1, 1], rl: [], ru: [])
        for (name, fresh) in strategies() {
            var factorization = fresh
            try factorization.refactor(basic: [], lp: lp)
            var empty: [Double] = []
            factorization.ftran(&empty)
            factorization.btran(&empty)
            #expect(empty.isEmpty && factorization.updatesSinceRefactor == 0 && !factorization.needsRefactor, "\(name)")
        }
    }

    @Test func aFactorizationIsUnusableBeforeItsFirstRefactor() {
        // ftran and btran leave the vector alone rather than trap.
        for (name, factorization) in strategies() {
            var x = [1.0, 2, 3]
            factorization.ftran(&x)
            factorization.btran(&x)
            #expect(x == [1, 2, 3], "\(name)")
            #expect(factorization.conditionEstimate() == nil, "\(name)")
            #expect(factorization.updatesSinceRefactor == 0, "\(name)")
        }
    }

    // MARK: Eta updates against refactorization

    @Test(arguments: [(30, 0.3, 140), (70, 0.08, 260)])
    func etaUpdatesMatchRefactorization(_ m: Int, _ density: Double, _ pivots: Int) throws {
        let lp = matrixLP(rows: m, groups: 3, density: density, seed: UInt64(m))
        var rng = SeededGenerator(seed: UInt64(m) &+ 99)
        var basic = (0..<m).map { Int32(lp.n + $0) }
        var inBasis = [Bool](repeating: false, count: lp.n + m)
        for column in basic { inBasis[Int(column)] = true }
        var lu = DenseLUBasis()
        var qr = SparseQRBasis()
        try lu.refactor(basic: basic, lp: lp)
        try qr.refactor(basic: basic, lp: lp)
        var luRefactors = 0
        var qrRefactors = 0
        var luLongestRun = 0
        var qrLongestRun = 0

        for step in 0..<pivots {
            // A random nonbasic column of [A −I] enters …
            var entering = rng.integer(in: 0...(lp.n + m - 1))
            while inBasis[entering] { entering = rng.integer(in: 0...(lp.n + m - 1)) }
            var alpha = logicalFormColumn(entering, lp)
            var alphaQR = alpha
            lu.ftran(&alpha)
            qr.ftran(&alphaQR)
            #expect(maxDifference(alpha, alphaQR) <= 1e-7 * (1 + Vec.maxAbs(alpha)), "step \(step): the strategies disagree on the entering column")
            // … at the position with the largest pivot, which keeps the basis well conditioned.
            var r = 0
            for i in 1..<m where abs(alpha[i]) > abs(alpha[r]) { r = i }
            try lu.update(alpha: alpha, leaving: r)
            try qr.update(alpha: alphaQR, leaving: r)
            inBasis[Int(basic[r])] = false
            inBasis[entering] = true
            basic[r] = Int32(entering)
            luLongestRun = max(luLongestRun, lu.updatesSinceRefactor)
            qrLongestRun = max(qrLongestRun, qr.updatesSinceRefactor)

            // The updated factorizations still solve with the current basis matrix.
            if step % 7 == 0 || lu.needsRefactor || qr.needsRefactor {
                expectSolvesMatchDense(lu, basic: basic, lp: lp, seed: UInt64(step), tolerance: 1e-7, "DenseLU after \(lu.updatesSinceRefactor) updates")
                expectSolvesMatchDense(qr, basic: basic, lp: lp, seed: UInt64(step), tolerance: 1e-7, "SparseQR after \(qr.updatesSinceRefactor) updates")
            }
            // Refactor when the strategy asks for it, as the engine does.
            if lu.needsRefactor {
                try lu.refactor(basic: basic, lp: lp)
                luRefactors += 1
                #expect(lu.updatesSinceRefactor == 0 && !lu.needsRefactor)
            }
            if qr.needsRefactor {
                try qr.refactor(basic: basic, lp: lp)
                qrRefactors += 1
                #expect(qr.updatesSinceRefactor == 0 && !qr.needsRefactor)
            }
        }
        // Every 100 updates for dense LU and every 50 for sparse QR, or earlier on growth.
        #expect(luLongestRun <= 100 && qrLongestRun <= 50)
        #expect(luRefactors >= pivots / 100 && qrRefactors >= pivots / 50)
        expectSolvesMatchDense(lu, basic: basic, lp: lp, seed: 5, tolerance: 1e-7, "DenseLU at the end")
        expectSolvesMatchDense(qr, basic: basic, lp: lp, seed: 5, tolerance: 1e-7, "SparseQR at the end")
    }

    @Test func needsRefactorTripsAtTheDocumentedCounts() throws {
        // A pivot sequence that stays perfectly conditioned: the entering column is a signed
        // unit vector scaled by 2, so α has one entry and no growth.
        let m = 8
        let lp = matrixLP(rows: m, density: 0, seed: 3)
        let basic = (0..<m).map { Int32(lp.n + $0) }
        func alpha(_ r: Int) -> [Double] {
            var a = [Double](repeating: 0, count: m)
            a[r] = 2
            return a
        }

        var lu = DenseLUBasis()
        try lu.refactor(basic: basic, lp: lp)
        for k in 0..<99 {
            try lu.update(alpha: alpha(k % m), leaving: k % m)
            #expect(!lu.needsRefactor, "after \(k + 1) updates")
        }
        try lu.update(alpha: alpha(0), leaving: 0)
        #expect(lu.updatesSinceRefactor == 100 && lu.needsRefactor)
        try lu.refactor(basic: basic, lp: lp)
        #expect(lu.updatesSinceRefactor == 0 && !lu.needsRefactor)

        var qr = SparseQRBasis()
        try qr.refactor(basic: basic, lp: lp)
        for k in 0..<49 {
            try qr.update(alpha: alpha(k % m), leaving: k % m)
            #expect(!qr.needsRefactor, "after \(k + 1) updates")
        }
        try qr.update(alpha: alpha(0), leaving: 0)
        #expect(qr.updatesSinceRefactor == 50 && qr.needsRefactor)

        // The interval is configurable.
        var eager = DenseLUBasis(refactorInterval: 3)
        try eager.refactor(basic: basic, lp: lp)
        try eager.update(alpha: alpha(1), leaving: 1)
        try eager.update(alpha: alpha(2), leaving: 2)
        #expect(!eager.needsRefactor)
        try eager.update(alpha: alpha(3), leaving: 3)
        #expect(eager.needsRefactor)
    }

    @Test func denseLURefactorsWhenTheEtaFileOutgrowsTheMatrix() throws {
        // Dense eta columns in a small basis: m − 1 entries each, so the file passes m² entries
        // long before the update count does.
        let m = 5
        let lp = matrixLP(rows: m, density: 0, seed: 4)
        var lu = DenseLUBasis(refactorInterval: 10_000)
        try lu.refactor(basic: (0..<m).map { Int32(lp.n + $0) }, lp: lp)
        var updates = 0
        while !lu.needsRefactor && updates < 100 {
            var alpha = [Double](repeating: 0.5, count: m)
            alpha[updates % m] = 2
            try lu.update(alpha: alpha, leaving: updates % m)
            updates += 1
        }
        #expect(lu.needsRefactor)
        #expect(updates == 7)                       // 7 · 4 = 28 > 25 = m²
    }

    @Test func aPivotWithLargeGrowthAsksForARefactor() throws {
        let m = 6
        let lp = matrixLP(rows: m, density: 0, seed: 5)
        let basic = (0..<m).map { Int32(lp.n + $0) }
        for (name, fresh) in strategies() {
            var factorization = fresh
            try factorization.refactor(basic: basic, lp: lp)
            var alpha = [Double](repeating: 0, count: m)
            alpha[0] = 1e8                          // eight orders of magnitude above the pivot
            alpha[2] = 1
            try factorization.update(alpha: alpha, leaving: 2)
            #expect(factorization.needsRefactor, "\(name)")
            #expect(factorization.updatesSinceRefactor == 1, "\(name)")
        }
    }

    @Test func aZeroOrNonFinitePivotIsRefused() throws {
        let m = 4
        let lp = matrixLP(rows: m, density: 0, seed: 6)
        let basic = (0..<m).map { Int32(lp.n + $0) }
        for (name, fresh) in strategies() {
            var factorization = fresh
            try factorization.refactor(basic: basic, lp: lp)
            for bad in [0.0, Double.nan, Double.infinity] {
                do {
                    try factorization.update(alpha: [1, bad, 1, 1], leaving: 1)
                    Issue.record("\(name): a pivot of \(bad) was accepted")
                } catch {
                    guard case .unstableUpdate = error else {
                        Issue.record("\(name): unexpected error \(error)")
                        continue
                    }
                }
            }
            #expect(factorization.updatesSinceRefactor == 0, "\(name)")
        }
    }

    @Test func etaEntriesBelowTheDropToleranceAreDropped() throws {
        // An α whose off-pivot entries are all below the tolerance acts as a pure scaling.
        let m = 5
        let lp = matrixLP(rows: m, density: 0, seed: 8)
        let basic = (0..<m).map { Int32(lp.n + $0) }
        var lu = DenseLUBasis(dropTolerance: 1e-3)
        try lu.refactor(basic: basic, lp: lp)
        try lu.update(alpha: [1e-4, 4, -1e-4, 1e-5, 0], leaving: 1)
        var x = [1.0, 1, 1, 1, 1]
        lu.ftran(&x)                               // base solve gives −1; the eta divides position 1 by 4
        #expect(x == [-1, -0.25, -1, -1, -1])
    }

    // MARK: Singular bases

    @Test func aRepeatedColumnIsReportedAndRepaired() throws {
        for seed in 0..<12 {
            let lp = matrixLP(rows: 14, density: 0.3, seed: UInt64(seed))
            var basic = mixedBasis(lp, structural: 0.8, seed: UInt64(seed) &+ 50)
            // Make two (or three) positions hold the same structural column.
            basic[3] = 2
            basic[9] = 2
            if seed % 3 == 0 { basic[12] = 2 }
            var lu = DenseLUBasis()
            do {
                try lu.refactor(basic: basic, lp: lp)
                Issue.record("seed \(seed): a singular basis factored")
                continue
            } catch {
                guard case .singular(let positions, let rows) = error else {
                    Issue.record("seed \(seed): unexpected error \(error)")
                    continue
                }
                #expect(!positions.isEmpty && positions.count == rows.count, "seed \(seed)")
                #expect(positions.allSatisfy { $0 >= 0 && $0 < 14 } && rows.allSatisfy { $0 >= 0 && $0 < 14 })
                #expect(Set(positions).count == positions.count && Set(rows).count == rows.count)
            }
            // Logical-replacement repair: at most a few rounds, never a loop.
            guard let repaired = repair(&basic, lp: lp, rounds: 6) else {
                Issue.record("seed \(seed): the repair did not converge")
                continue
            }
            #expect(repaired.rounds >= 1)
            expectSolvesMatchDense(repaired.factorization, basic: basic, lp: lp, seed: UInt64(seed), "repaired basis, seed \(seed)")
        }
    }

    @Test func linearlyDependentColumnsAreReportedAndRepaired() throws {
        // Column 2 = column 0 + column 1: no two columns are equal, yet the basis is singular.
        var rng = SeededGenerator(seed: 77)
        let m = 9
        var dense = randomDense(rows: m, cols: m, &rng)
        for i in 0..<m { dense[i, 2] = dense[i, 0] + dense[i, 1] }
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<m { for i in 0..<m { entries.append((i, j, dense[i, j])) } }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: [Double](repeating: 0, count: m),
            xl: [Double](repeating: 0, count: m), xu: [Double](repeating: inf, count: m),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 0, count: m))
        var basic = (0..<m).map { Int32($0) }
        var lu = DenseLUBasis()
        do {
            try lu.refactor(basic: basic, lp: lp)
            Issue.record("a rank-deficient basis factored")
        } catch {
            guard case .singular(let positions, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(positions.count == 1)
        }
        let repaired = try #require(repair(&basic, lp: lp, rounds: 4))
        #expect(basic.filter { Int($0) >= lp.n }.count == repaired.rounds)   // one logical per round here
        expectSolvesMatchDense(repaired.factorization, basic: basic, lp: lp, seed: 1, tolerance: 1e-6, "repaired dependent basis")
    }

    @Test func sparseQRRejectsASingularBasis() {
        let lp = matrixLP(rows: 10, density: 0.3, seed: 21)
        var basic = mixedBasis(lp, structural: 1, seed: 22)
        basic[4] = basic[1]
        var qr = SparseQRBasis()
        do {
            try qr.refactor(basic: basic, lp: lp)
            Issue.record("a singular basis factored")
        } catch {
            // Accelerate's QR can say that the matrix is singular, not where.
            #expect(error == .singular(positions: [], rows: []))
        }
        // The strategy is usable again with a sound basis.
        #expect(throws: Never.self) { try qr.refactor(basic: mixedBasis(lp, structural: 1, seed: 22), lp: lp) }
    }

    @Test func sparseQRTreatsANumericallySingularBasisAsSingularButKeepsIllConditionedOnes() throws {
        // B = [[1, 1], [1, 1 + δ]] embedded in a larger identity-like basis: κ ≈ 4 / δ.
        func problem(delta: Double) -> (lp: CompiledLP, basic: [Int32]) {
            let m = 8
            var entries: [(row: Int, col: Int, value: Double)] = [(0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1 + delta)]
            for j in 2..<m { entries.append((j, j, 2)) }
            let lp = CompiledLP(
                a: SparseCSC.fromTriplets(rows: m, cols: m, entries), c: [Double](repeating: 0, count: m),
                xl: [Double](repeating: 0, count: m), xu: [Double](repeating: inf, count: m),
                rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 0, count: m))
            return (lp, (0..<m).map { Int32($0) })
        }
        // κ around 4e7: badly conditioned, but a basis the simplex must be able to use.
        let usable = problem(delta: 1e-7)
        var qr = SparseQRBasis()
        try qr.refactor(basic: usable.basic, lp: usable.lp)
        expectSolvesMatchDense(qr, basic: usable.basic, lp: usable.lp, seed: 3, tolerance: 1e-6, "ill-conditioned but usable")
        // κ around 4e14: Accelerate reports success, the probe does not.
        let hopeless = problem(delta: 1e-14)
        do {
            try qr.refactor(basic: hopeless.basic, lp: hopeless.lp)
            Issue.record("a numerically singular basis factored")
        } catch {
            #expect(error == .singular(positions: [], rows: []))
        }
        // After a failed refactor the strategy holds no stale factors.
        var x = [Double](repeating: 1, count: 8)
        qr.ftran(&x)
        #expect(x == [Double](repeating: 1, count: 8))
        #expect(qr.updatesSinceRefactor == 0)
    }

    @Test func aNearlySingularBasisIsTreatedAsSingularByDenseLU() {
        // Two columns that differ by 1e-13: a pivot below the relative tolerance.
        let m = 6
        var entries: [(row: Int, col: Int, value: Double)] = []
        for j in 0..<m {
            for i in 0..<m { entries.append((i, j, i == j ? 3 : 1 / Double(1 + i + j))) }
        }
        for i in 0..<m { entries.append((i, m, (i == 0 ? 3 : 1 / Double(1 + i)) + (i == 2 ? 1e-13 : 0))) }
        let lp = CompiledLP(
            a: SparseCSC.fromTriplets(rows: m, cols: m + 1, entries), c: [Double](repeating: 0, count: m + 1),
            xl: [Double](repeating: 0, count: m + 1), xu: [Double](repeating: inf, count: m + 1),
            rl: [Double](repeating: 0, count: m), ru: [Double](repeating: 0, count: m))
        let basic: [Int32] = [0, 6, 2, 3, 4, 5]          // columns 0 and 6 are almost equal
        var strict = DenseLUBasis()
        #expect(throws: NumericalError.self) { try strict.refactor(basic: basic, lp: lp) }
        // With the tolerance switched off the same basis factors (and is useless).
        var lax = DenseLUBasis(singularityTolerance: 0)
        #expect(throws: Never.self) { try lax.refactor(basic: basic, lp: lp) }
        #expect((lax.conditionEstimate() ?? 0) > 1e11)
    }

    // MARK: Condition estimate

    @Test func theConditionEstimateIsCloseToTheTruth() throws {
        for seed in 0..<10 {
            let m = 6 + seed
            let lp = matrixLP(rows: m, density: 0.5, seed: UInt64(seed) &+ 300)
            let basic = mixedBasis(lp, structural: 0.8, seed: UInt64(seed))
            var lu = DenseLUBasis()
            try lu.refactor(basic: basic, lp: lp)
            let estimate = try #require(lu.conditionEstimate())
            // The exact κ₁ = ‖B‖₁·‖B⁻¹‖₁, with the inverse built column by column.
            let b = basisMatrix(basic, lp)
            var inverse = DenseMatrix(rows: m, cols: m)
            for k in 0..<m {
                var unit = [Double](repeating: 0, count: m)
                unit[k] = 1
                let column = try #require(denseSolve(b, unit))
                for i in 0..<m { inverse[i, k] = column[i] }
            }
            let exact = b.oneNorm() * inverse.oneNorm()
            // dgecon never overestimates and is rarely off by more than a small factor.
            #expect(estimate <= exact * (1 + 1e-8), "seed \(seed): \(estimate) vs \(exact)")
            #expect(estimate >= exact / 10, "seed \(seed): \(estimate) vs \(exact)")
        }
        // −I has condition number 1; sparse QR offers no estimate.
        let lp = matrixLP(rows: 7, density: 0.2, seed: 9)
        let logical = (0..<lp.m).map { Int32(lp.n + $0) }
        var lu = DenseLUBasis()
        try lu.refactor(basic: logical, lp: lp)
        #expect(lu.conditionEstimate() == 1)
        var qr = SparseQRBasis()
        try qr.refactor(basic: logical, lp: lp)
        #expect(qr.conditionEstimate() == nil)
    }

    // MARK: Value semantics and sharing

    @Test func aCopyIsIndependentOfLaterUpdates() throws {
        let lp = matrixLP(rows: 12, density: 0.3, seed: 31)
        let basic = mixedBasis(lp, structural: 0.5, seed: 32)
        for (name, fresh) in strategies() {
            var original = fresh
            try original.refactor(basic: basic, lp: lp)
            var copy = original
            // Pivot a new column into the copy only.
            var entering = 0
            while basic.contains(Int32(entering)) { entering += 1 }
            var alpha = logicalFormColumn(entering, lp)
            copy.ftran(&alpha)
            var r = 0
            for i in 1..<lp.m where abs(alpha[i]) > abs(alpha[r]) { r = i }
            try copy.update(alpha: alpha, leaving: r)
            var updated = basic
            updated[r] = Int32(entering)

            #expect(original.updatesSinceRefactor == 0 && copy.updatesSinceRefactor == 1, "\(name)")
            expectSolvesMatchDense(original, basic: basic, lp: lp, seed: 1, "\(name): the original")
            expectSolvesMatchDense(copy, basic: updated, lp: lp, seed: 1, "\(name): the copy")
            // Refactoring the copy leaves the original's factors alone, too.
            try copy.refactor(basic: updated, lp: lp)
            expectSolvesMatchDense(original, basic: basic, lp: lp, seed: 2, "\(name): the original after the copy refactored")
        }
    }

    @Test func oneFactorizationServesConcurrentSolves() async throws {
        // BasisFactorization is Sendable: copies of one factored basis are read from several
        // tasks at once. (The sparse QR handle is the one documented exception to checked
        // sendability; this is the use that exception has to be safe for.)
        let lp = matrixLP(rows: 40, density: 0.1, seed: 41)
        let basic = mixedBasis(lp, structural: 0.7, seed: 42)
        let b = basisMatrix(basic, lp)
        for (name, fresh) in strategies() {
            var factorization = fresh
            try factorization.refactor(basic: basic, lp: lp)
            let shared = factorization
            let worst = await withTaskGroup(of: Double.self) { group -> Double in
                for task in 0..<8 {
                    group.addTask {
                        var rng = SeededGenerator(seed: UInt64(task))
                        var worst = 0.0
                        for _ in 0..<60 {
                            let rhs = randomVector(lp.m, &rng)
                            var x = rhs
                            shared.ftran(&x)
                            worst = max(worst, residual(b, x, rhs))
                            var y = rhs
                            shared.btran(&y)
                            worst = max(worst, residual(b.transposed(), y, rhs))
                        }
                        return worst
                    }
                }
                var overall = 0.0
                for await value in group { overall = max(overall, value) }
                return overall
            }
            #expect(worst <= 1e-9, "\(name): residual \(worst)")
        }
    }

    @Test func basisDensityCountsStoredEntries() {
        let lp = matrixLP(rows: 10, density: 0, seed: 51)          // one entry per column
        let logical = (0..<lp.m).map { Int32(lp.n + $0) }
        #expect(basisDensity(basic: logical, lp: lp) == 0.1)        // 10 entries of 100
        #expect(basisDensity(basic: (0..<10).map { Int32($0) }, lp: lp) == 0.1)
        let dense = matrixLP(rows: 10, density: 1, seed: 52)
        #expect(basisDensity(basic: (0..<10).map { Int32($0) }, lp: dense) == 1)
        let empty = CompiledLP(a: SparseCSC(rows: 0, cols: 1), c: [0], xl: [0], xu: [1], rl: [], ru: [])
        #expect(basisDensity(basic: [], lp: empty) == 0)
    }
}
