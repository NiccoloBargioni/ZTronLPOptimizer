// The reducedCostScan kernel against an fp64 CPU reference (specification §6.4, §14.2).
// Every test here needs a usable Metal device and is skipped without one.

import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPMetal

@Suite(.requiresMetal) struct ReducedCostScanTests {
    private func makeKernel(for lp: CompiledLP, policy: MetalPolicy = .forced) async throws -> MetalReducedCostScan {
        let scanner = try #require(await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: policy))
        return try #require(scanner as? MetalReducedCostScan)
    }

    @Test func scoresMatchTheDoubleReference() async throws {
        let lp = MetalTestProblems.sparse(rows: 300, columns: 3_000, perColumn: 8, seed: 21)
        let kernel = try await makeKernel(for: lp)
        for seed in [31, 32, 33] as [UInt64] {
            let inputs = MetalTestProblems.scanInputs(lp, seed: seed)
            let gpu = try #require(
                await kernel.scores(
                    costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility))
            let reference = DoubleReference.scores(
                lp, costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility)
            #expect(gpu.count == lp.n)
            var worst = 0.0
            var attractive = 0
            for j in 0..<lp.n {
                let difference = abs(Double(gpu[j]) - reference.score[j])
                #expect(difference <= reference.bound[j], "column \(j): fp32 \(gpu[j]) vs fp64 \(reference.score[j])")
                worst = max(worst, difference / max(1, reference.score[j]))
                if reference.score[j] > 0 { attractive += 1 }
                // A column that may not enter never gets a score.
                if inputs.eligibility[j] == PricingEligibility.none { #expect(gpu[j] == 0) }
            }
            // The data exercises the kernel: a healthy share of attractive columns, and single
            // precision agreeing to about six digits.
            #expect(attractive > lp.n / 5)
            #expect(worst < 1e-4)
        }
    }

    @Test func scanReturnsTheBestCandidatesBestFirst() async throws {
        let lp = MetalTestProblems.sparse(rows: 300, columns: 3_000, perColumn: 8, seed: 22)
        let kernel = try await makeKernel(for: lp)
        let inputs = MetalTestProblems.scanInputs(lp, seed: 41)
        let limit = KernelThresholds.reducedCostCandidates
        let candidates = try #require(
            await kernel.scan(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility,
                limit: limit))
        #expect(candidates.count == limit)
        #expect(Set(candidates).count == limit)

        // The selection is exactly the top of the kernel's own scores …
        let gpu = try #require(
            await kernel.scores(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility))
        let ownTop = gpu.withUnsafeBufferPointer { KernelSupport.topCandidates($0, limit: limit) }
        #expect(candidates == ownTop)
        for k in 1..<candidates.count {
            #expect(gpu[Int(candidates[k - 1])] >= gpu[Int(candidates[k])])
        }

        // … and agrees with the Double ranking up to near-ties: every candidate is eligible,
        // attractive in Double, and at least as good as the 64th best Double score.
        let reference = DoubleReference.scores(
            lp, costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility)
        let referenceTop = DoubleReference.topCandidates(reference.score, limit: limit)
        let cutoff = reference.score[referenceTop[limit - 1]]
        for candidate in candidates {
            let j = Int(candidate)
            #expect(inputs.eligibility[j] != PricingEligibility.none)
            #expect(reference.score[j] >= cutoff * (1 - 1e-4))
        }
        #expect(Int(candidates[0]) == referenceTop[0])
        #expect(Set(candidates.map { Int($0) }).intersection(referenceTop).count >= limit - 2)
    }

    @Test func verificationAgreesWithTheRealKernel() async throws {
        let lp = MetalTestProblems.sparse(rows: 200, columns: 4_000, perColumn: 6, seed: 23)
        let kernel = try await makeKernel(for: lp)
        var disagreement = KernelDisagreementGuard()
        for step in 0..<10 {
            let inputs = MetalTestProblems.scanInputs(lp, seed: 50 + UInt64(step))
            let candidates = try #require(
                await kernel.scan(
                    costs: inputs.costs, duals: inputs.duals, weights: inputs.weights,
                    eligibility: inputs.eligibility, limit: KernelThresholds.reducedCostCandidates))
            let verified = verifyCandidates(
                candidates, lp: lp, costs: inputs.costs, duals: inputs.duals, eligibility: inputs.eligibility,
                guard: &disagreement)
            #expect(!verified.justDisabled)
        }
        #expect(disagreement.candidates == 640)
        #expect(!disagreement.isDisabled)
        #expect(disagreement.disagreementRate <= KernelThresholds.disagreementFraction)
    }

    @Test func columnsThatMayNotEnterAreNeverReturned() async throws {
        let lp = MetalTestProblems.sparse(rows: 100, columns: 800, perColumn: 5, seed: 24)
        let kernel = try await makeKernel(for: lp)
        let inputs = MetalTestProblems.scanInputs(lp, seed: 61)

        // Nothing eligible: nothing returned.
        let nobody = [UInt8](repeating: PricingEligibility.none, count: lp.n)
        let none = try #require(
            await kernel.scan(costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: nobody, limit: 64))
        #expect(none.isEmpty)

        // Everything at its lower bound: only columns with d < 0 in Double may come back.
        let atLower = [UInt8](repeating: PricingEligibility.increase, count: lp.n)
        let lower = try #require(
            await kernel.scan(costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: atLower, limit: 64))
        #expect(!lower.isEmpty)
        for candidate in lower {
            #expect(DoubleReference.reducedCost(lp, column: Int(candidate), costs: inputs.costs, duals: inputs.duals).d < 0)
        }

        // Everything at its upper bound: only d > 0.
        let atUpper = [UInt8](repeating: PricingEligibility.decrease, count: lp.n)
        let upper = try #require(
            await kernel.scan(costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: atUpper, limit: 64))
        #expect(!upper.isEmpty)
        for candidate in upper {
            #expect(DoubleReference.reducedCost(lp, column: Int(candidate), costs: inputs.costs, duals: inputs.duals).d > 0)
        }
        #expect(Set(lower).isDisjoint(with: upper))

        // Zero duals and zero costs: every reduced cost is exactly zero, nothing is attractive.
        let free = [UInt8](repeating: PricingEligibility.either, count: lp.n)
        let flat = try #require(
            await kernel.scan(
                costs: [Double](repeating: 0, count: lp.n), duals: [Double](repeating: 0, count: lp.m),
                weights: inputs.weights, eligibility: free, limit: 64))
        #expect(flat.isEmpty)
    }

    @Test func theLimitAndTheInputSizesAreChecked() async throws {
        let lp = MetalTestProblems.sparse(rows: 100, columns: 800, perColumn: 5, seed: 25)
        let kernel = try await makeKernel(for: lp)
        let inputs = MetalTestProblems.scanInputs(lp, seed: 71)
        let five = try #require(
            await kernel.scan(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility, limit: 5))
        #expect(five.count == 5)
        let zero = try #require(
            await kernel.scan(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility, limit: 0))
        #expect(zero.isEmpty)

        // Vectors of the wrong length: the kernel declines instead of reading out of bounds.
        #expect(
            await kernel.scan(
                costs: Array(inputs.costs.dropLast()), duals: inputs.duals, weights: inputs.weights,
                eligibility: inputs.eligibility, limit: 64) == nil)
        #expect(
            await kernel.scan(
                costs: inputs.costs, duals: inputs.duals + [0], weights: inputs.weights,
                eligibility: inputs.eligibility, limit: 64) == nil)
    }

    @Test func concurrentScansOnOneKernelDoNotInterfere() async throws {
        let lp = MetalTestProblems.sparse(rows: 200, columns: 5_000, perColumn: 6, seed: 26)
        let kernel = try await makeKernel(for: lp)
        let seeds: [UInt64] = Array(80..<96)
        var sequential: [UInt64: [Int32]] = [:]
        for seed in seeds {
            let inputs = MetalTestProblems.scanInputs(lp, seed: seed)
            sequential[seed] = await kernel.scan(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility, limit: 64)
        }
        // Sixteen workers share the kernel, as branch-and-bound workers share it.
        let concurrent = await withTaskGroup(of: (UInt64, [Int32]?).self) { group -> [UInt64: [Int32]] in
            for seed in seeds {
                group.addTask {
                    let inputs = MetalTestProblems.scanInputs(lp, seed: seed)
                    let result = await kernel.scan(
                        costs: inputs.costs, duals: inputs.duals, weights: inputs.weights,
                        eligibility: inputs.eligibility, limit: 64)
                    return (seed, result)
                }
            }
            var collected: [UInt64: [Int32]] = [:]
            for await (seed, result) in group {
                if let result { collected[seed] = result }
            }
            return collected
        }
        #expect(concurrent.count == seeds.count)
        for seed in seeds {
            #expect(concurrent[seed] == sequential[seed])
        }
    }

    @Test func theCopyOfAIsBuiltOncePerProblemAndReleasedAfterwards() async throws {
        let lp = MetalTestProblems.sparse(rows: 120, columns: 900, perColumn: 5, seed: 27)
        weak var released: MetalReducedCostScan?
        do {
            let first = try await makeKernel(for: lp)
            released = first
            // The same problem again, as a second worker would ask.
            let second = try await makeKernel(for: lp)
            #expect(first === second)
            // An equal problem assembled separately (each worker scales its own copy).
            let rebuilt = CompiledLP(
                a: SparseCSC(
                    rows: lp.a.rows, cols: lp.a.cols, colStart: Array(lp.a.colStart), rowIndex: lp.a.rowIndex.map { $0 },
                    values: lp.a.values.map { $0 }),
                c: lp.c, xl: lp.xl, xu: lp.xu, rl: lp.rl, ru: lp.ru)
            let third = try await makeKernel(for: rebuilt)
            #expect(first === third)
            // A different matrix gets its own copy.
            let other = MetalTestProblems.sparse(rows: 120, columns: 900, perColumn: 5, seed: 28)
            let fourth = try await makeKernel(for: other)
            #expect(first !== fourth)
        }
        // The provider only remembers kernels weakly: with the last engine gone, so is the copy.
        #expect(released == nil)
        // And a new request simply builds it again.
        let again = try await makeKernel(for: lp)
        #expect(again.columns == lp.n)
    }

    @Test func anExplicitDeviceWorksLikeTheSharedProvider() async throws {
        let device = try #require(await MetalAccelerator.shared.context()).device
        let own = MetalAccelerator(device: device)
        #expect(await own.status().isReady)
        let lp = MetalTestProblems.sparse(rows: 100, columns: 800, perColumn: 5, seed: 30)
        let inputs = MetalTestProblems.scanInputs(lp, seed: 95)
        let mine = try #require(await own.reducedCostScanner(for: lp, policy: .forced))
        let shared = try #require(await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced))
        // Two providers keep separate copies, and both kernels give the same candidates.
        #expect((mine as? MetalReducedCostScan) !== (shared as? MetalReducedCostScan))
        let first = await mine.scan(
            costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility, limit: 64)
        let second = await shared.scan(
            costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility, limit: 64)
        #expect(first != nil && first == second)
    }

    @Test func automaticPolicyGrantsTheKernelAtTheThresholds() async throws {
        // Exactly at the thresholds in force: n = 3,000,000 and nnz = 6,000,000.
        let lp = MetalTestProblems.sparse(
            rows: 400, columns: KernelThresholds.reducedCostScanColumns,
            perColumn: KernelThresholds.reducedCostScanNonzeros / KernelThresholds.reducedCostScanColumns, seed: 29)
        #expect(lp.n == KernelThresholds.reducedCostScanColumns)
        #expect(lp.nnz == KernelThresholds.reducedCostScanNonzeros)
        let kernel = try await makeKernel(for: lp, policy: .automatic)
        let inputs = MetalTestProblems.scanInputs(lp, seed: 91)
        let candidates = try #require(
            await kernel.scan(
                costs: inputs.costs, duals: inputs.duals, weights: inputs.weights, eligibility: inputs.eligibility,
                limit: KernelThresholds.reducedCostCandidates))
        #expect(candidates.count == KernelThresholds.reducedCostCandidates)
        // The CPU picks the entering column from verified candidates only.
        var disagreement = KernelDisagreementGuard()
        let verified = verifyCandidates(
            candidates, lp: lp, costs: inputs.costs, duals: inputs.duals, eligibility: inputs.eligibility,
            guard: &disagreement)
        #expect(verified.kept.count == candidates.count)
        #expect(!disagreement.isDisabled)
    }
}
