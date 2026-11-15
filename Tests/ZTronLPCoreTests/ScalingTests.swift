// Specification §5.4 and §14.2 ("scaling by powers of two is exact").

import Testing
import ZTronLPCore
import ZTronLPTestSupport

/// max |a_ij| / min |a_ij| over the stored entries.
private func coefficientRatio(_ lp: CompiledLP) -> Double {
    var largest = 0.0
    var smallest = Double.infinity
    for v in lp.a.values where v != 0 {
        largest = max(largest, abs(v))
        smallest = min(smallest, abs(v))
    }
    return smallest.isFinite ? largest / smallest : 1
}

/// The ∞-norm of every row and of every column.
private func norms(_ lp: CompiledLP) -> (rows: [Double], columns: [Double]) {
    var rows = [Double](repeating: 0, count: lp.m)
    var columns = [Double](repeating: 0, count: lp.n)
    for j in 0..<lp.n {
        for p in lp.a.range(ofColumn: j) {
            let v = abs(lp.a.values[p])
            rows[Int(lp.a.rowIndex[p])] = max(rows[Int(lp.a.rowIndex[p])], v)
            columns[j] = max(columns[j], v)
        }
    }
    return (rows, columns)
}

private func isPowerOfTwo(_ value: Double) -> Bool {
    value > 0 && value.isFinite && value.significand == 1
}

/// A badly scaled problem: the constructed-optimum generator with rows and columns spread
/// over several decades.
private func badlyScaled(seed: UInt64, rows: Int = 14, columns: Int = 22, spread: Double = 5) -> CompiledLP {
    var options = ConstructedOptions()
    options.scaleSpread = spread
    options.rangeRows = true
    options.freeColumns = true
    return InstanceGenerator.constructedOptimum(rows: rows, columns: columns, seed: seed, options: options).lp
}

@Suite("Scaling")
struct ScalingTests {
    @Test func noScalingIsTheIdentity() {
        let lp = badlyScaled(seed: 1)
        let factors = Scaler.factors(for: lp, mode: .none)
        #expect(factors.isIdentity)
        #expect(factors.rows.count == lp.m && factors.columns.count == lp.n)
        let scaled = Scaler.scale(lp, mode: .none)
        #expect(scaled.a == lp.a && scaled.c == lp.c && scaled.xl == lp.xl && scaled.rl == lp.rl)
        #expect(scaled.scaling == factors)
        #expect(!Scaling(rows: [1, 2], columns: [1]).isIdentity)
    }

    @Test(arguments: [ScalingMode.equilibration, .geometricEquilibration])
    func everyFactorIsAPowerOfTwo(_ mode: ScalingMode) {
        for seed in 0..<25 {
            let lp = badlyScaled(seed: UInt64(seed))
            let factors = Scaler.factors(for: lp, mode: mode)
            #expect(factors.rows.allSatisfy(isPowerOfTwo), "seed \(seed)")
            #expect(factors.columns.allSatisfy(isPowerOfTwo), "seed \(seed)")
        }
        #expect(Scaler.powerOfTwo(nearest: 3) == 4)
        #expect(Scaler.powerOfTwo(nearest: 2.8) == 2)       // log₂ 2.8 ≈ 1.49
        #expect(Scaler.powerOfTwo(nearest: 0.3) == 0.25)
        #expect(Scaler.powerOfTwo(nearest: 1) == 1)
        #expect(Scaler.powerOfTwo(nearest: 0) == 1 && Scaler.powerOfTwo(nearest: -4) == 1)
        #expect(Scaler.powerOfTwo(nearest: .infinity) == 1 && Scaler.powerOfTwo(nearest: .nan) == 1)
    }

    @Test func integerColumnsKeepFactorOne() {
        // A scaled integer column would break branching.
        for seed in 0..<20 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let base = badlyScaled(seed: UInt64(seed) + 100)
            var integer: [Int32] = []
            for j in 0..<base.n where rng.chance(0.4) { integer.append(Int32(j)) }
            let lp = CompiledLP(
                a: base.a, c: base.c, xl: base.xl, xu: base.xu, rl: base.rl, ru: base.ru, integerColumns: integer)
            for mode in [ScalingMode.equilibration, .geometricEquilibration] {
                let factors = Scaler.factors(for: lp, mode: mode)
                for j in integer { #expect(factors.columns[Int(j)] == 1, "seed \(seed)") }
                let scaled = Scaler.apply(factors, to: lp)
                #expect(scaled.integerColumns == lp.integerColumns)
                for j in integer {
                    #expect(scaled.xl[Int(j)] == lp.xl[Int(j)] && scaled.xu[Int(j)] == lp.xu[Int(j)])
                }
            }
        }
    }

    @Test func scalingIntroducesNoRoundingError() {
        // Multiplying by a power of two is exact, so everything can be undone bit for bit.
        for seed in 0..<25 {
            let lp = badlyScaled(seed: UInt64(seed) + 200)
            let scaled = Scaler.scale(lp, mode: .geometricEquilibration)
            guard let s = scaled.scaling else {
                Issue.record("the scaled problem carries no factors")
                continue
            }
            // The problem data.
            for j in 0..<lp.n {
                for p in lp.a.range(ofColumn: j) {
                    let back = scaled.a.values[p] / (s.rows[Int(lp.a.rowIndex[p])] * s.columns[j])
                    #expect(back.bitPattern == lp.a.values[p].bitPattern)
                }
                #expect((scaled.c[j] / s.columns[j]).bitPattern == lp.c[j].bitPattern)
                #expect(scaled.xl[j] * s.columns[j] == lp.xl[j] && scaled.xu[j] * s.columns[j] == lp.xu[j])
            }
            for i in 0..<lp.m {
                #expect(scaled.rl[i] / s.rows[i] == lp.rl[i] && scaled.ru[i] / s.rows[i] == lp.ru[i])
            }
            #expect(scaled.a.colStart == lp.a.colStart && scaled.a.rowIndex == lp.a.rowIndex)
            #expect(scaled.c0 == lp.c0 && scaled.sense == lp.sense)

            // Primal values, duals and reduced costs through the helpers.
            var rng = SeededGenerator(seed: UInt64(seed))
            let x = (0..<lp.n).map { _ in rng.uniform(in: -1e3...1e3) }
            let y = (0..<lp.m).map { _ in rng.uniform(in: -1e3...1e3) }
            let d = (0..<(lp.n + lp.m)).map { _ in rng.uniform(in: -1e3...1e3) }
            let xScaled = s.scalePrimal(x)
            #expect(s.unscalePrimal(xScaled).map(\.bitPattern) == x.map(\.bitPattern))
            let yUnscaled = s.unscaleDual(y)
            #expect(zip(yUnscaled, s.rows).map { ($0 / $1).bitPattern } == y.map(\.bitPattern))
            let dUnscaled = s.unscaleReducedCosts(d)
            for j in 0..<lp.n { #expect((dUnscaled[j] * s.columns[j]).bitPattern == d[j].bitPattern) }
            for i in 0..<lp.m { #expect((dUnscaled[lp.n + i] / s.rows[i]).bitPattern == d[lp.n + i].bitPattern) }
            let activity = s.unscaleRowActivity(scaled.rowActivity(xScaled))
            // Row activities of the scaled problem are the original ones times the row factor,
            // exactly: the same products in the same order, each shifted by a power of two.
            #expect(activity.map(\.bitPattern) == lp.rowActivity(x).map(\.bitPattern))
            // The objective is unchanged by scaling.
            #expect(scaled.internalObjective(at: xScaled).bitPattern == lp.internalObjective(at: x).bitPattern)
        }
    }

    @Test func dualsAndReducedCostsStayConsistentAcrossScaling() {
        // d = c − Aᵀy must hold in both problems for corresponding vectors.
        for seed in 0..<10 {
            let lp = badlyScaled(seed: UInt64(seed) + 300)
            let scaled = Scaler.scale(lp, mode: .geometricEquilibration)
            let s = scaled.scaling!
            var rng = SeededGenerator(seed: UInt64(seed))
            let yScaled = (0..<lp.m).map { _ in rng.uniform(in: -2...2) }
            let dScaled = scaled.reducedCosts(forDuals: yScaled)
            let y = s.unscaleDual(yScaled)
            let d = lp.reducedCosts(forDuals: y)
            #expect(s.unscaleReducedCosts(dScaled).map(\.bitPattern) == d.map(\.bitPattern), "seed \(seed)")
        }
    }

    @Test func anOptimalPairStaysOptimalInTheScaledProblem() {
        // x' = x / columns and y' = y / rows: the conventions the engines unscale with.
        for seed in 0..<30 {
            var options = ConstructedOptions()
            options.scaleSpread = 3
            options.rangeRows = seed % 2 == 0
            options.freeColumns = seed % 3 == 0
            let instance = InstanceGenerator.constructedOptimum(rows: 8 + seed % 7, columns: 12 + seed % 9, seed: UInt64(seed) &+ 900, options: options)
            #expect(optimalityViolation(instance.lp, x: instance.primal, y: instance.dual, tolerance: 1e-7) <= 1e-6, "seed \(seed): unscaled")
            for mode in [ScalingMode.equilibration, .geometricEquilibration] {
                let scaled = Scaler.scale(instance.lp, mode: mode)
                let s = scaled.scaling!
                let x = s.scalePrimal(instance.primal)
                let y = zip(instance.dual, s.rows).map { $0 / $1 }
                #expect(optimalityViolation(scaled, x: x, y: y, tolerance: 1e-7) <= 1e-6, "seed \(seed) \(mode)")
                #expect(scaled.internalObjective(at: x) == instance.lp.internalObjective(at: instance.primal), "seed \(seed) \(mode)")
                // And back again through the helpers.
                #expect(s.unscalePrimal(x) == instance.primal && s.unscaleDual(y) == instance.dual)
            }
        }
    }

    @Test func equilibrationBringsEveryNormNearOne() {
        for seed in 0..<25 {
            let lp = badlyScaled(seed: UInt64(seed) + 400)
            for mode in [ScalingMode.equilibration, .geometricEquilibration] {
                let scaled = Scaler.scale(lp, mode: mode)
                let (rows, columns) = norms(scaled)
                // Exactly 1 before rounding to powers of two; within a factor of two after.
                #expect(rows.allSatisfy { $0 >= 0.49 && $0 <= 2.05 }, "seed \(seed) \(mode): \(rows)")
                #expect(columns.allSatisfy { $0 >= 0.49 && $0 <= 2.05 }, "seed \(seed) \(mode): \(columns)")
            }
        }
    }

    @Test func theCoefficientRatioDoesNotGetWorse() {
        for seed in 0..<40 {
            let lp = badlyScaled(seed: UInt64(seed) + 500)
            let before = coefficientRatio(lp)
            let equilibrated = coefficientRatio(Scaler.scale(lp, mode: .equilibration))
            let geometric = coefficientRatio(Scaler.scale(lp, mode: .geometricEquilibration))
            #expect(before > 1e6, "seed \(seed): the instance is not badly scaled")
            #expect(equilibrated <= before, "seed \(seed): \(before) → \(equilibrated)")
            #expect(geometric <= before, "seed \(seed): \(before) → \(geometric)")
            // Rows and columns were spread over ten decades; what is left is the spread of
            // the entries themselves (a factor of 8) and the rounding to powers of two.
            #expect(geometric <= 1e3, "seed \(seed): \(before) → \(geometric)")
        }

        // Geometric-mean passes are there to beat plain equilibration when one entry is an
        // outlier: equilibration alone leaves the ratio of this matrix at 1e8.
        let outlier = denseLP(
            rows: [[1, 1, 1], [1, 1, 1e8]], rl: [0, 0], ru: [1, 1], c: [1, 1, 1], xl: [0, 0, 0], xu: [inf, inf, inf])
        let plain = coefficientRatio(Scaler.scale(outlier, mode: .equilibration))
        let geometric = coefficientRatio(Scaler.scale(outlier, mode: .geometricEquilibration))
        #expect(plain >= 1e7)
        #expect(geometric <= 1e5 && geometric < plain)

        // A problem that is already perfectly scaled stays that way.
        let even = denseLP(rows: [[3, -3], [3, 3]], rl: [0, 0], ru: [1, 1], c: [1, 1], xl: [0, 0], xu: [inf, inf])
        #expect(coefficientRatio(Scaler.scale(even, mode: .geometricEquilibration)) == 1)
    }

    @Test func scalingsCompose() {
        let lp = badlyScaled(seed: 77)
        let first = Scaler.factors(for: lp, mode: .equilibration)
        let once = Scaler.apply(first, to: lp)
        let second = Scaler.factors(for: once, mode: .geometricEquilibration)
        let twice = Scaler.apply(second, to: once)
        // `scaling` always maps back to the unscaled problem.
        let combined = Scaling(
            rows: zip(first.rows, second.rows).map { $0 * $1 },
            columns: zip(first.columns, second.columns).map { $0 * $1 })
        #expect(twice.scaling == combined)
        let direct = Scaler.apply(combined, to: lp)
        #expect(direct.a == twice.a && direct.c == twice.c)
        #expect(direct.xl == twice.xl && direct.xu == twice.xu && direct.rl == twice.rl && direct.ru == twice.ru)
        #expect(direct.scaling == twice.scaling)
    }

    @Test func degenerateInputs() {
        // No entries at all: nothing to scale.
        let empty = denseLP(rows: [[0, 0]], rl: [0], ru: [1], c: [1, 1], xl: [0, 0], xu: [1, 1])
        #expect(Scaler.factors(for: empty, mode: .geometricEquilibration).isIdentity)
        // Empty rows and columns keep factor 1; infinite bounds stay infinite.
        let sparse = denseLP(
            rows: [[1000, 0, 0], [0, 0, 0], [0.001, 0, 8]], rl: [-inf, 0, 1], ru: [5, 0, inf], c: [1, 2, 3],
            xl: [-inf, 0, 0], xu: [inf, inf, 9])
        let factors = Scaler.factors(for: sparse, mode: .geometricEquilibration)
        #expect(factors.rows[1] == 1 && factors.columns[1] == 1)
        let scaled = Scaler.apply(factors, to: sparse)
        #expect(scaled.xl[0] == -inf && scaled.xu[0] == inf && scaled.rl[0] == -inf && scaled.ru[2] == inf)
        #expect(scaled.names == sparse.names)
    }
}
