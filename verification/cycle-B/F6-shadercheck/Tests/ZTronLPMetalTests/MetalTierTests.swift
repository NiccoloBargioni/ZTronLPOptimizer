// The parts of the GPU tier that must hold on every machine, with or without a Metal device
// (specification §6.4, §14.2): graceful disabling, the policy and the thresholds, the bundled
// shader, the candidate selection and the disagreement guard.

import Foundation
import Metal
import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

@testable import ZTronLPMetal

@Suite struct MetalTierTests {
    // MARK: Disabled gracefully without a device

    @Test func noDeviceDisablesTheTier() async {
        let accelerator = MetalAccelerator(device: nil)
        #expect(await accelerator.status() == .noDevice)
        #expect(await accelerator.isAvailable == false)
        #expect(await accelerator.context() == nil)

        // Even a forced request gets no kernel, and nothing traps or waits.
        let lp = MetalTestProblems.sparse(rows: 20, columns: 40, perColumn: 3, seed: 1)
        #expect(await accelerator.reducedCostScanner(for: lp, policy: .forced) == nil)
        #expect(await accelerator.activityEvaluator(for: lp, policy: .forced) == nil)
        #expect(await accelerator.reducedCostScanner(for: lp, policy: .automatic) == nil)
        #expect(await accelerator.activityEvaluator(for: lp, policy: .automatic) == nil)
    }

    @Test func statusIsAlwaysOneOfTheThreeOutcomes() async {
        // Whatever this machine has, asking must not trap, and asking twice gives one answer.
        let first = await MetalAccelerator.shared.status()
        let second = await MetalAccelerator.shared.status()
        #expect(first == second)
        switch first {
        case .ready(let device, let library):
            #expect(!device.isEmpty)
            #expect(library == .precompiled || library == .compiledFromSource)
            #expect(await MetalAccelerator.shared.context() != nil)
        case .noDevice, .libraryUnavailable:
            #expect(await MetalAccelerator.shared.context() == nil)
        }
    }

    // MARK: Policy and thresholds

    @Test func policyOffNeverYieldsAKernel() async {
        let lp = MetalTestProblems.sparse(rows: 20, columns: 40, perColumn: 3, seed: 2)
        #expect(await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .off) == nil)
        #expect(await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .off) == nil)
    }

    @Test func automaticPolicyDeclinesProblemsBelowTheThresholds() async {
        // Far below both thresholds: no kernel, with or without a device.
        let small = MetalTestProblems.sparse(rows: 50, columns: 200, perColumn: 4, seed: 3)
        #expect(await MetalAccelerator.shared.reducedCostScanner(for: small, policy: .automatic) == nil)
        #expect(await MetalAccelerator.shared.activityEvaluator(for: small, policy: .automatic) == nil)

        // The specification's original scan size (n = 50,000, nnz = 500,000) is below the
        // measured threshold now in force, and one nonzero short of the activity threshold
        // declines too. The exact boundary of the scan gate is pinned on
        // `KernelThresholds.allowsReducedCostScan` in the numerics tests.
        let specified = MetalTestProblems.sparse(rows: 100, columns: 50_000, perColumn: 10, seed: 4)
        #expect(specified.nnz == 500_000)
        #expect(await MetalAccelerator.shared.reducedCostScanner(for: specified, policy: .automatic) == nil)
        let nonzerosShort = MetalTestProblems.sparse(rows: 100, columns: 33_333, perColumn: 3, seed: 5)
        #expect(nonzerosShort.nnz == 99_999)
        #expect(await MetalAccelerator.shared.activityEvaluator(for: nonzerosShort, policy: .automatic) == nil)
    }

    @Test func thresholdsAreTheOnesOfTheSpecification() {
        // Raised from 50,000 / 500,000 by the §14.3 benchmark; see `KernelThresholds`.
        #expect(KernelThresholds.reducedCostScanColumns == 3_000_000)
        #expect(KernelThresholds.reducedCostScanNonzeros == 6_000_000)
        #expect(KernelThresholds.reducedCostCandidates == 64)
        #expect(KernelThresholds.batchedActivityPoints == 64)
        #expect(KernelThresholds.batchedActivityNonzeros == 100_000)
        #expect(KernelThresholds.batchedActivityMaxBatch == 1_024)
        #expect(KernelThresholds.disagreementFraction == 0.05)
    }

    @Test func attachingMetalRespectsThePolicyAndAnExistingProvider() {
        var context = SolveContext()
        #expect(context.accelerator == nil)
        context.attachMetal()
        #expect(context.accelerator is MetalAccelerator)
        #expect(context.candidateKernels != nil)

        var off = SolveContext()
        off.metal = .off
        #expect(off.attachingMetal().accelerator == nil)
        #expect(off.attachingMetal().candidateKernels == nil)

        // A provider that is already attached stays.
        let own = MetalAccelerator(device: nil)
        var custom = SolveContext()
        custom.accelerator = own
        custom.attachMetal()
        #expect(custom.accelerator as? MetalAccelerator === own)
    }

    // MARK: Shader resources

    @Test func theShaderIsBundledAsALibraryOrAsSource() throws {
        let bundle = try #require(ShaderResources.bundle, "the ZTronLPMetal resource bundle was not found")
        if ShaderResources.hasPrecompiledLibrary(in: bundle) {
            // Xcode compiled Shaders/Kernels.metal into default.metallib.
            return
        }
        // A command-line build copies the source; it must name both kernels.
        let source = try #require(ShaderResources.source(in: bundle), "neither default.metallib nor Kernels.metal is bundled")
        #expect(source.contains("kernel void \(MetalContext.scanFunction)("))
        #expect(source.contains("kernel void \(MetalContext.activityFunction)("))
    }

    // MARK: Candidate selection

    @Test func topCandidatesAreTheLargestPositiveScoresBestFirst() {
        let scores: [Float] = [0, 3, 0.5, .nan, 7, 3, -1, 0, 9, 0.25]
        let all = scores.withUnsafeBufferPointer { KernelSupport.topCandidates($0, limit: 64) }
        // Ties go to the lower index; zeros, negatives and NaN are never candidates.
        #expect(all == [8, 4, 1, 5, 2, 9])
        let three = scores.withUnsafeBufferPointer { KernelSupport.topCandidates($0, limit: 3) }
        #expect(three == [8, 4, 1])
        let none = scores.withUnsafeBufferPointer { KernelSupport.topCandidates($0, limit: 0) }
        #expect(none.isEmpty)

        // Against a full sort on random data.
        var rng = SeededGenerator(seed: 77)
        let random: [Float] = (0..<5_000).map { _ in rng.chance(0.3) ? 0 : Float(rng.uniform(in: 0...100)) }
        let selected = random.withUnsafeBufferPointer { KernelSupport.topCandidates($0, limit: 64) }
        let expected = random.indices.filter { random[$0] > 0 }
            .sorted { random[$0] > random[$1] || (random[$0] == random[$1] && $0 < $1) }
            .prefix(64).map { Int32($0) }
        #expect(selected == Array(expected))
    }

    // MARK: Auto-disable on disagreement

    @Test func aLyingKernelIsDisabledForTheSolve() async throws {
        let lp = MetalTestProblems.sparse(rows: 60, columns: 600, perColumn: 5, seed: 9)
        let kernel: any ReducedCostScanning = LyingScanner(lp: lp)
        var disagreement = KernelDisagreementGuard()
        var trips = 0
        var pricingCalls = 0
        // What the simplex does every pricing step: scan, verify in Double, record.
        for step in 0..<20 where !disagreement.isDisabled {
            let inputs = MetalTestProblems.scanInputs(lp, seed: 100 + UInt64(step))
            let candidates = try #require(
                await kernel.scan(
                    costs: inputs.costs, duals: inputs.duals, weights: inputs.weights,
                    eligibility: inputs.eligibility, limit: KernelThresholds.reducedCostCandidates))
            let verified = verifyCandidates(
                candidates, lp: lp, costs: inputs.costs, duals: inputs.duals, eligibility: inputs.eligibility,
                guard: &disagreement)
            // The GPU decides nothing: none of the lies survives verification.
            #expect(verified.kept.isEmpty)
            if verified.justDisabled { trips += 1 }
            pricingCalls += 1
        }
        #expect(disagreement.isDisabled)
        #expect(trips == 1)
        #expect(disagreement.disagreementRate > KernelThresholds.disagreementFraction)
        // With 64 candidates per scan the very first verified batch is enough.
        #expect(pricingCalls == 1)
        // Once disabled the guard stays disabled and does not report again.
        #expect(disagreement.record(candidates: 64, disagreements: 0) == false)
        #expect(disagreement.isDisabled)
    }

    @Test func anHonestKernelIsNeverDisabled() async throws {
        let lp = MetalTestProblems.sparse(rows: 60, columns: 600, perColumn: 5, seed: 10)
        let kernel: any ReducedCostScanning = ReferenceScanner(lp: lp)
        var disagreement = KernelDisagreementGuard()
        for step in 0..<20 {
            let inputs = MetalTestProblems.scanInputs(lp, seed: 200 + UInt64(step))
            let candidates = try #require(
                await kernel.scan(
                    costs: inputs.costs, duals: inputs.duals, weights: inputs.weights,
                    eligibility: inputs.eligibility, limit: KernelThresholds.reducedCostCandidates))
            let verified = verifyCandidates(
                candidates, lp: lp, costs: inputs.costs, duals: inputs.duals, eligibility: inputs.eligibility,
                guard: &disagreement)
            #expect(verified.kept.count == candidates.count)
            #expect(!verified.justDisabled)
        }
        #expect(!disagreement.isDisabled)
        #expect(disagreement.disagreements == 0)
    }

    @Test func theGuardWaitsForAMinimumSampleAndForMoreThanFivePercent() {
        // Too few candidates to judge, even when all of them are wrong.
        var few = KernelDisagreementGuard()
        #expect(few.record(candidates: 63, disagreements: 63) == false)
        #expect(!few.isDisabled)
        #expect(few.record(candidates: 1, disagreements: 0) == true)
        #expect(few.isDisabled)

        // Exactly 5% is not "more than 5%".
        var exact = KernelDisagreementGuard()
        #expect(exact.record(candidates: 100, disagreements: 5) == false)
        #expect(!exact.isDisabled)
        #expect(exact.record(candidates: 100, disagreements: 6) == true)
        #expect(exact.isDisabled)
        #expect(exact.disagreementRate == 0.055)
    }
}
