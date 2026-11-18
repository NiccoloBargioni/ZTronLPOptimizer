// The batchedActivity kernel against an fp64 CPU reference (specification §6.4, §14.2).
// Every test here needs a usable Metal device and is skipped without one.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPMetal

@Suite(.requiresMetal) struct BatchedActivityTests {
    private func makeKernel(
        for lp: CompiledLP, policy: MetalPolicy = .forced, accelerator: MetalAccelerator = .shared
    ) async throws -> MetalBatchedActivity {
        let evaluator = try #require(await accelerator.activityEvaluator(for: lp, policy: policy))
        return try #require(evaluator as? PolicyBoundActivityEvaluator).kernel
    }

    /// `count` random points inside the column bounds, one after another.
    private func randomPoints(_ lp: CompiledLP, count: Int, seed: UInt64) -> [Double] {
        var rng = SeededGenerator(seed: seed)
        var points = [Double](repeating: 0, count: count * lp.n)
        for k in 0..<count {
            for j in 0..<lp.n { points[k * lp.n + j] = rng.uniform(in: lp.xl[j]...lp.xu[j]) }
        }
        return points
    }

    @Test func activitiesMatchTheDoubleReference() async throws {
        let lp = MetalTestProblems.sparse(rows: 200, columns: 500, perColumn: 5, seed: 121)
        let kernel = try await makeKernel(for: lp)
        let count = 100
        let points = randomPoints(lp, count: count, seed: 122)
        let gpu = try #require(await kernel.activities(points: points, count: count))
        let reference = DoubleReference.activities(lp, points: points, count: count)
        #expect(gpu.count == count * lp.m)
        var worst = 0.0
        for k in 0..<count {
            for i in 0..<lp.m {
                let index = k * lp.m + i
                let length = Double(lp.aT.colStart[i + 1] - lp.aT.colStart[i])
                let bound = 2 * (length + 6) * singleEpsilon * reference.magnitude[index] + 1e-30
                let difference = abs(Double(gpu[index]) - reference.activity[index])
                #expect(difference <= bound, "point \(k), row \(i): fp32 \(gpu[index]) vs fp64 \(reference.activity[index])")
                worst = max(worst, difference / max(1, abs(reference.activity[index])))
            }
        }
        #expect(worst < 1e-4)
    }

    @Test func aPointOnItsBoundsIsNeverRejectedBySinglePrecision() async throws {
        let base = MetalTestProblems.sparse(rows: 200, columns: 500, perColumn: 5, seed: 123)
        var rng = SeededGenerator(seed: 124)
        let x0 = (0..<base.n).map { _ in rng.uniform(in: 1...9) }
        let s0 = base.a.multiply(x0)
        // Rows that hold with equality at x0, rows active on one side, rows with slack.
        var rl = [Double](repeating: -.infinity, count: base.m)
        var ru = [Double](repeating: .infinity, count: base.m)
        for i in 0..<base.m {
            switch i % 4 {
            case 0:
                rl[i] = s0[i]
                ru[i] = s0[i]
            case 1:
                rl[i] = s0[i]
            case 2:
                ru[i] = s0[i]
            default:
                rl[i] = s0[i] - 3
                ru[i] = s0[i] + 3
            }
        }
        let lp = MetalTestProblems.bounded(base, rl: rl, ru: ru)
        let kernel = try await makeKernel(for: lp)
        let tolerance = 1e-7

        // x0 sits exactly on 150 of its 200 row bounds. In Double it is feasible; rounded to
        // single precision about half of those activities land on the wrong side. The widened
        // comparison must let it through every time.
        let copies = 16
        var points: [Double] = []
        for _ in 0..<copies { points.append(contentsOf: x0) }
        // A point that breaks an equality row by a margin no rounding explains …
        var broken = x0
        let column = Int(lp.aT.rowIndex[lp.aT.colStart[0]])
        broken[column] += 0.5
        points.append(contentsOf: broken)
        // … and one that leaves a column bound.
        var outside = x0
        outside[7] = lp.xu[7] + 1e-3
        points.append(contentsOf: outside)
        let count = copies + 2

        for k in 0..<copies {
            #expect(DoubleReference.isFeasible(lp, points: points, point: k, tolerance: tolerance))
        }
        #expect(!DoubleReference.isFeasible(lp, points: points, point: copies, tolerance: tolerance))
        #expect(!DoubleReference.isFeasible(lp, points: points, point: copies + 1, tolerance: tolerance))

        let flags = try #require(await kernel.evaluate(points: points, count: count, tolerance: tolerance))
        #expect(flags.count == count)
        #expect(flags[0..<copies].allSatisfy { $0 })
        #expect(flags[copies] == false)
        #expect(flags[copies + 1] == false)

        // The column-bound violation is caught on the CPU, exactly; the GPU saw nothing wrong
        // with that point's rows beyond what moving one coordinate by 1e-3 does.
        let rows = try #require(await kernel.rowViolations(points: points, count: count, tolerance: tolerance))
        #expect(rows[0..<copies].allSatisfy { !$0 })
        #expect(rows[copies] == true)
    }

    @Test func flagsHaveNoFalseNegativesOnRandomPoints() async throws {
        let base = MetalTestProblems.sparse(rows: 150, columns: 400, perColumn: 5, seed: 125)
        var rng = SeededGenerator(seed: 126)
        let center = (0..<base.n).map { _ in rng.uniform(in: 3...7) }
        let s0 = base.a.multiply(center)
        // Row bounds wide enough that small perturbations of the centre are feasible about
        // half of the time.
        let lp = MetalTestProblems.bounded(base, rl: s0.map { $0 - 1.5 }, ru: s0.map { $0 + 1.5 })
        let kernel = try await makeKernel(for: lp)
        let count = 400
        var points = [Double](repeating: 0, count: count * lp.n)
        for k in 0..<count {
            let spread = rng.uniform(in: 0...0.35)
            for j in 0..<lp.n { points[k * lp.n + j] = center[j] + rng.uniform(in: -spread...spread) }
        }
        let tolerance = 1e-7
        let flags = try #require(await kernel.evaluate(points: points, count: count, tolerance: tolerance))

        var feasible = 0
        var falsePositives = 0
        var disagreement = KernelDisagreementGuard()
        for k in 0..<count {
            let exact = DoubleReference.isFeasible(lp, points: points, point: k, tolerance: tolerance)
            if exact {
                feasible += 1
                // The screen never loses a feasible point.
                #expect(flags[k], "point \(k) is feasible in Double and was rejected in single precision")
            } else if flags[k] {
                falsePositives += 1
            }
        }
        // The batch is a real mix, and what the CPU re-check has to throw away is rare.
        #expect(feasible > count / 10 && feasible < count * 9 / 10)
        let flagged = flags.filter { $0 }.count
        #expect(disagreement.record(candidates: flagged, disagreements: falsePositives) == false)
        #expect(!disagreement.isDisabled)
    }

    @Test func infiniteRowBoundsAndColumnBoundsAreHandled() async throws {
        let free = MetalTestProblems.sparse(rows: 80, columns: 120, perColumn: 4, seed: 127)
        // Every row unbounded on both sides: only the column bounds [0, 10] can fail.
        let kernel = try await makeKernel(for: free)
        var points = randomPoints(free, count: 4, seed: 128)
        points[1 * free.n + 3] = 10 + 1e-3          // above its upper bound
        points[2 * free.n + 5] = -1e-3              // below its lower bound
        points[3 * free.n + 9] = .nan               // not a number at all
        let flags = try #require(await kernel.evaluate(points: points, count: 4, tolerance: 1e-7))
        #expect(flags == [true, false, false, false])
        // Within the tolerance of a column bound is still feasible.
        var onBound = randomPoints(free, count: 1, seed: 129)
        onBound[0] = 10 + 5e-8
        #expect(try #require(await kernel.evaluate(points: onBound, count: 1, tolerance: 1e-7)) == [true])
    }

    @Test func largeBatchesAreSplitAcrossDispatches() async throws {
        let base = MetalTestProblems.sparse(rows: 60, columns: 90, perColumn: 4, seed: 130)
        var rng = SeededGenerator(seed: 131)
        let center = (0..<base.n).map { _ in rng.uniform(in: 3...7) }
        let s0 = base.a.multiply(center)
        let lp = MetalTestProblems.bounded(base, rl: s0.map { $0 - 2 }, ru: s0.map { $0 + 2 })
        let count = 20
        var points = [Double](repeating: 0, count: count * lp.n)
        for k in 0..<count {
            let spread = rng.uniform(in: 0...0.6)
            for j in 0..<lp.n { points[k * lp.n + j] = center[j] + rng.uniform(in: -spread...spread) }
        }

        let whole = try await makeKernel(for: lp)
        let reference = try #require(await whole.evaluate(points: points, count: count, tolerance: 1e-7))
        #expect(await whole.dispatches == 1)

        // Room for three points per dispatch: the same batch takes seven.
        let tight = MetalAccelerator(choice: .systemDefault, scratchByteLimit: 3 * lp.n * MemoryLayout<Float>.stride)
        let chunked = try await makeKernel(for: lp, accelerator: tight)
        let split = try #require(await chunked.evaluate(points: points, count: count, tolerance: 1e-7))
        #expect(split == reference)
        #expect(await chunked.dispatches == 7)
        // The activities come back in the same order whichever way the batch is cut.
        let wholeActivities = try #require(await whole.activities(points: points, count: count))
        let splitActivities = try #require(await chunked.activities(points: points, count: count))
        #expect(wholeActivities == splitActivities)

        // More than 1,024 points: one kernel batch never exceeds the specified maximum.
        let many = 1_100
        var morePoints = [Double](repeating: 0, count: many * lp.n)
        for k in 0..<many {
            for j in 0..<lp.n { morePoints[k * lp.n + j] = center[j] + rng.uniform(in: -0.3...0.3) }
        }
        let before = await whole.dispatches
        let flags = try #require(await whole.evaluate(points: morePoints, count: many, tolerance: 1e-7))
        #expect(flags.count == many)
        #expect(await whole.dispatches == before + 2)
        for k in stride(from: 0, to: many, by: 37) {
            if DoubleReference.isFeasible(lp, points: morePoints, point: k, tolerance: 1e-7) { #expect(flags[k]) }
        }
    }

    @Test func automaticPolicyDeclinesSmallBatches() async throws {
        // nnz = 100,000: the matrix is large enough for the tier under the automatic policy.
        let lp = MetalTestProblems.sparse(rows: 200, columns: 20_000, perColumn: 5, seed: 132)
        #expect(lp.nnz == KernelThresholds.batchedActivityNonzeros)
        let evaluator = try #require(await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .automatic))

        // 63 points: below the batch threshold, the caller evaluates on the CPU.
        let small = randomPoints(lp, count: 63, seed: 133)
        #expect(await evaluator.evaluate(points: small, count: 63, tolerance: 1e-7) == nil)
        // 64 points: the kernel runs.
        let enough = randomPoints(lp, count: 64, seed: 134)
        let flags = try #require(await evaluator.evaluate(points: enough, count: 64, tolerance: 1e-7))
        #expect(flags.count == 64)
        #expect(flags.allSatisfy { $0 })          // rows are unbounded, points are inside the box

        // A forced request takes any batch.
        let forced = try #require(await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .forced))
        let one = randomPoints(lp, count: 1, seed: 135)
        #expect(try #require(await forced.evaluate(points: one, count: 1, tolerance: 1e-7)) == [true])
    }

    @Test func theCopyOfAIsSharedPerProblemAndBounds() async throws {
        let lp = MetalTestProblems.sparse(rows: 70, columns: 110, perColumn: 4, seed: 136)
        let first = try await makeKernel(for: lp)
        let second = try await makeKernel(for: lp)
        #expect(first === second)
        // The same matrix with other column bounds is another screen.
        let narrowed = MetalTestProblems.bounded(lp, xu: [Double](repeating: 5, count: lp.n))
        let third = try await makeKernel(for: narrowed)
        #expect(first !== third)
        #expect(third.columnUpper == narrowed.xu)
    }

    @Test func theInputSizeIsChecked() async throws {
        let lp = MetalTestProblems.sparse(rows: 70, columns: 110, perColumn: 4, seed: 137)
        let kernel = try await makeKernel(for: lp)
        let points = randomPoints(lp, count: 3, seed: 138)
        #expect(await kernel.evaluate(points: points, count: 4, tolerance: 1e-7) == nil)
        #expect(await kernel.evaluate(points: Array(points.dropLast()), count: 3, tolerance: 1e-7) == nil)
        #expect(await kernel.activities(points: points, count: 2) == nil)
        #expect(try #require(await kernel.evaluate(points: [], count: 0, tolerance: 1e-7)).isEmpty)
    }
}
