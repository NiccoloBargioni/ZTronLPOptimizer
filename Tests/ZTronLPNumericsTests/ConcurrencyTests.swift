// Specification §12.1 rule C7 (ConcurrencyBudget), §2 (memory budget) and §6.4 (the
// candidate-kernel seam and its disagreement guard).

import Testing
import ZTronLPCore
import ZTronLPNumerics

/// A provider that only records that it was asked; it stands in for the GPU tier.
private struct StubKernels: CandidateKernelProvider {
    func reducedCostScanner(for lp: CompiledLP, policy: MetalPolicy) async -> (any ReducedCostScanning)? { nil }
    func activityEvaluator(for lp: CompiledLP, policy: MetalPolicy) async -> (any BatchedActivityEvaluating)? { nil }
}

/// An accelerator that is not a kernel provider.
private struct OtherAccelerator: SolveAccelerator {}

@Suite("Concurrency, memory and candidate kernels")
struct ConcurrencyTests {
    // MARK: ConcurrencyBudget

    @Test func theBudgetNeverGrantsMoreThanItsCapacity() async {
        let budget = ConcurrencyBudget(threads: 4)
        #expect(budget.capacity == 4)
        #expect(await budget.slotsInUse == 1)              // the task that starts the solve
        #expect(await budget.borrow(upTo: 2) == 2)
        #expect(await budget.slotsInUse == 3)
        #expect(await budget.borrow(upTo: 5) == 1)         // only one slot is left
        #expect(await budget.borrow(upTo: 5) == 0)         // none: the caller runs inline, it does not wait
        #expect(await budget.slotsInUse == 4)
        #expect(await budget.peakInUse == 4)
        await budget.giveBack(3)
        #expect(await budget.slotsInUse == 1)
        #expect(await budget.peakInUse == 4)               // the peak is remembered
        #expect(await budget.borrow(upTo: 0) == 0)
        #expect(await budget.borrow(upTo: -3) == 0)
        await budget.giveBack(-2)                          // ignored
        await budget.giveBack(100)                         // never below zero
        #expect(await budget.slotsInUse == 0)
    }

    @Test func degenerateBudgets() async {
        #expect(ConcurrencyBudget(threads: 0).capacity == 1)
        #expect(ConcurrencyBudget(threads: -8).capacity == 1)
        let single = ConcurrencyBudget(threads: 1)
        #expect(await single.borrow(upTo: 3) == 0)
        let unoccupied = ConcurrencyBudget(threads: 3, occupied: 0)
        #expect(await unoccupied.borrow(upTo: 9) == 3)
        let overfull = ConcurrencyBudget(threads: 2, occupied: 7)
        #expect(await overfull.slotsInUse == 2)
        #expect(await overfull.borrow(upTo: 1) == 0)
    }

    // MARK: parallelBlocks

    @Test func blocksPartitionTheRangeAndComeBackInOrder() async {
        for (count, blocks) in [(100, 8), (7, 3), (5, 5), (3, 10), (1, 4), (64, 1), (1_000, 7)] {
            for threads in [1, 2, 4] {
                let budget = ConcurrencyBudget(threads: threads)
                let ranges = await parallelBlocks(count: count, blocks: blocks, budget: budget) { $0 }
                #expect(ranges.count == min(blocks, count), "\(count) in \(blocks)")
                // Contiguous, in order, covering 0..<count exactly once.
                #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == count)
                for k in 1..<ranges.count { #expect(ranges[k].lowerBound == ranges[k - 1].upperBound) }
                #expect(ranges.allSatisfy { !$0.isEmpty })
                #expect(await budget.slotsInUse == 1)      // every borrowed slot was given back
            }
        }
        // No budget: everything runs inline on the caller, same result.
        let inline = await parallelBlocks(count: 10, blocks: 4, budget: nil) { $0.reduce(0, +) }
        #expect(inline == [1, 9, 11, 24])                  // 0..<2, 2..<5, 5..<7, 7..<10
        // Nothing to do: one empty block.
        let nothing = await parallelBlocks(count: 0, blocks: 4, budget: nil) { $0.count }
        #expect(nothing == [0])
    }

    @Test(arguments: [1, 2, 3, 4, 8])
    func peakConcurrencyNeverExceedsThreads(_ threads: Int) async {
        // Rule C7. The bodies themselves count how many of them run at once.
        let budget = ConcurrencyBudget(threads: threads)
        let meter = ConcurrencyMeter()
        let results = await parallelBlocks(count: 240, blocks: 24, budget: budget) { range -> Int in
            await meter.enter()
            // Stay "in flight" across several suspension points so overlaps are observed.
            for _ in 0..<6 { await Task.yield() }
            spin(nanoseconds: 300_000)
            await meter.leave()
            return range.reduce(0, +)
        }
        #expect(results.reduce(0, +) == (0..<240).reduce(0, +))
        #expect(await meter.entries == 24)
        let measuredPeak = await meter.peak
        #expect(measuredPeak <= threads, "measured \(measuredPeak) bodies at once with threads = \(threads)")
        #expect(await budget.peakInUse <= threads)
        #expect(await budget.peakInUse == min(threads, 24))    // it used what it was allowed
        #expect(await budget.slotsInUse == 1)
    }

    @Test func withThreadsEqualToTwoTheMeasuredPeakIsAtMostTwo() async {
        // The exact case the specification names, repeated to give races a chance to show.
        for round in 0..<25 {
            let budget = ConcurrencyBudget(threads: 2)
            let meter = ConcurrencyMeter()
            _ = await parallelBlocks(count: 64, blocks: 16, budget: budget) { range -> Int in
                await meter.enter()
                await Task.yield()
                spin(nanoseconds: 50_000)
                await meter.leave()
                return range.count
            }
            #expect(await meter.peak <= 2, "round \(round)")
            #expect(await meter.entries == 16, "round \(round)")
        }
    }

    @Test func nestedRegionsShareOneBudget() async {
        // Workers × probes: an outer region whose bodies open inner regions on the same
        // budget. In-flight leaf bodies never exceed the thread count; an inner borrow that
        // cannot be satisfied runs inline.
        for threads in [2, 3, 4] {
            let budget = ConcurrencyBudget(threads: threads)
            let meter = ConcurrencyMeter()
            let totals = await parallelBlocks(count: 6, blocks: 6, budget: budget) { outer -> Int in
                let inner = await parallelBlocks(count: 12, blocks: 4, budget: budget) { range -> Int in
                    await meter.enter()
                    await Task.yield()
                    spin(nanoseconds: 100_000)
                    await meter.leave()
                    return range.count
                }
                return inner.reduce(0, +) + outer.count
            }
            #expect(totals == [13, 13, 13, 13, 13, 13])
            #expect(await meter.entries == 24)
            #expect(await meter.peak <= threads, "threads = \(threads)")
            #expect(await budget.peakInUse <= threads)
            #expect(await budget.slotsInUse == 1)
        }
    }

    @Test func anExhaustedBudgetRunsTheWorkInline() async {
        let budget = ConcurrencyBudget(threads: 4, occupied: 4)
        let meter = ConcurrencyMeter()
        let results = await parallelBlocks(count: 40, blocks: 8, budget: budget) { range -> Int in
            await meter.enter()
            await Task.yield()
            await meter.leave()
            return range.lowerBound
        }
        #expect(results == [0, 5, 10, 15, 20, 25, 30, 35])
        #expect(await meter.peak == 1)                     // strictly one at a time
        #expect(await budget.slotsInUse == 4)
    }

    @Test func resultsDoNotDependOnTheBudget() async {
        func run(_ budget: ConcurrencyBudget?) async -> [Double] {
            await parallelBlocks(count: 1_000, blocks: 13, budget: budget) { range in
                range.reduce(0.0) { $0 + 1 / Double($1 + 1) }
            }
        }
        let sequential = await run(nil)
        for threads in [1, 2, 5, 16] {
            #expect(await run(ConcurrencyBudget(threads: threads)) == sequential)
        }
    }

    // MARK: Memory budget

    @Test func theMemoryBudgetDefaultsToAQuarterOfWhatIsAvailable() {
        let available = MemoryBudget.availableBytes()
        #expect(available > 0)
        var context = SolveContext()
        let automatic = MemoryBudget.resolve(context)
        #expect(automatic > 0 && automatic <= available)
        // A quarter of what is available (the amount can move slightly between two readings).
        #expect(abs(Double(automatic) - Double(available) / 4) <= Double(available) * 0.05)
        context.memoryBudgetBytes = 16 << 20
        #expect(MemoryBudget.resolve(context) == 16 << 20)
        context.memoryBudgetBytes = 0
        #expect(MemoryBudget.resolve(context) == 0)
        context.memoryBudgetBytes = -1
        #expect(MemoryBudget.resolve(context) == 0)
    }

    @Test func secondsSinceMeasuresForward() {
        let start = Deadline.now
        spin(nanoseconds: 2_000_000)
        let elapsed = secondsSince(start)
        #expect(elapsed >= 0.002 && elapsed < 5)
    }

    // MARK: Candidate kernels (§6.4)

    @Test func thresholdsAreTheOnesOfTheSpecification() {
        // The scan thresholds are the specification's 50,000 / 500,000 raised to where the
        // §14.3 benchmark shows Metal 1.5× faster than the CPU as a rule ("or the threshold is
        // raised"); everything else is the specification's value.
        #expect(KernelThresholds.reducedCostScanColumns == 3_000_000)
        #expect(KernelThresholds.reducedCostScanNonzeros == 6_000_000)
        #expect(KernelThresholds.reducedCostCandidates == 64)
        #expect(KernelThresholds.batchedActivityPoints == 64)
        #expect(KernelThresholds.batchedActivityNonzeros == 100_000)
        #expect(KernelThresholds.batchedActivityMaxBatch == 1_024)
        #expect(KernelThresholds.disagreementFraction == 0.05)

        // Automatic: both conditions; forced: always; off: never.
        let columns = KernelThresholds.reducedCostScanColumns
        let nonzeros = KernelThresholds.reducedCostScanNonzeros
        #expect(KernelThresholds.allowsReducedCostScan(columns: columns, nonzeros: nonzeros, policy: .automatic))
        #expect(!KernelThresholds.allowsReducedCostScan(columns: columns - 1, nonzeros: 10 * nonzeros, policy: .automatic))
        #expect(!KernelThresholds.allowsReducedCostScan(columns: 10 * columns, nonzeros: nonzeros - 1, policy: .automatic))
        #expect(KernelThresholds.allowsReducedCostScan(columns: 3, nonzeros: 5, policy: .forced))
        #expect(!KernelThresholds.allowsReducedCostScan(columns: 10 * columns, nonzeros: 10 * nonzeros, policy: .off))

        #expect(KernelThresholds.allowsBatchedActivity(points: 64, nonzeros: 100_000, policy: .automatic))
        #expect(!KernelThresholds.allowsBatchedActivity(points: 63, nonzeros: 1_000_000, policy: .automatic))
        #expect(!KernelThresholds.allowsBatchedActivity(points: 1_024, nonzeros: 99_999, policy: .automatic))
        #expect(KernelThresholds.allowsBatchedActivity(points: 1, nonzeros: 1, policy: .forced))
        #expect(!KernelThresholds.allowsBatchedActivity(points: 0, nonzeros: 1, policy: .forced))
        #expect(!KernelThresholds.allowsBatchedActivity(points: 1_024, nonzeros: 1_000_000, policy: .off))

        #expect(Set([PricingEligibility.none, PricingEligibility.increase, PricingEligibility.decrease, PricingEligibility.either]).count == 4)
        #expect(PricingEligibility.none == 0)
    }

    @Test func theProviderTravelsInTheContext() {
        var context = SolveContext()
        #expect(context.candidateKernels == nil)           // nothing attached
        context.accelerator = StubKernels()
        #expect(context.candidateKernels != nil)
        context.metal = .forced
        #expect(context.candidateKernels != nil)
        context.metal = .off
        #expect(context.candidateKernels == nil)           // the policy wins over the attachment
        context.metal = .automatic
        context.accelerator = OtherAccelerator()
        #expect(context.candidateKernels == nil)           // an accelerator that supplies no kernels
        // Nested and silenced copies keep the attachment.
        context.accelerator = StubKernels()
        #expect(context.nested().candidateKernels != nil && context.silenced().candidateKernels != nil)
    }

    @Test func theDisagreementGuardDisablesAKernelAboveFivePercent() {
        // (`record` is mutating, so its result is taken into a local before it is checked.)
        var steady = KernelDisagreementGuard()
        // 3 wrong of 64 is 4.7%: tolerated, however long it goes on.
        for _ in 0..<50 {
            let tripped = steady.record(candidates: 64, disagreements: 3)
            #expect(!tripped)
        }
        #expect(!steady.isDisabled)
        #expect(abs(steady.disagreementRate - 3.0 / 64) < 1e-15)
        #expect(steady.candidates == 3_200 && steady.disagreements == 150)

        // 4 wrong of 64 is 6.25%: disabled, and reported exactly once.
        var noisy = KernelDisagreementGuard()
        let first = noisy.record(candidates: 64, disagreements: 4)
        #expect(first && noisy.isDisabled)
        let second = noisy.record(candidates: 64, disagreements: 64)
        #expect(!second)
        #expect(noisy.candidates == 64 && noisy.disagreements == 4)     // nothing is counted after that

        // The fraction means nothing before a minimum sample.
        var early = KernelDisagreementGuard()
        let tooEarly = early.record(candidates: 10, disagreements: 10)
        #expect(!tooEarly && !early.isDisabled)
        let atSixtyFour = early.record(candidates: 54, disagreements: 0)  // 10 of 64 now
        #expect(atSixtyFour)
        var patient = KernelDisagreementGuard(minimumSample: 1_000)
        let belowSample = patient.record(candidates: 999, disagreements: 999)
        let atSample = patient.record(candidates: 1, disagreements: 0)
        #expect(!belowSample && atSample)
        // Exactly five percent is not "more than five percent".
        var borderline = KernelDisagreementGuard(minimumSample: 100)
        let exactlyFive = borderline.record(candidates: 100, disagreements: 5)
        let aboveFive = borderline.record(candidates: 100, disagreements: 6)
        #expect(!exactlyFive && aboveFive)
        #expect(KernelDisagreementGuard().disagreementRate == 0)
    }
}
