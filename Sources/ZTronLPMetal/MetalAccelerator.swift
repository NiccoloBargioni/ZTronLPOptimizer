// MetalAccelerator: the candidate-kernel provider of the GPU tier (specification §6.4).
//
// No engine imports this target (§3). An engine knows the kernel protocols of the numerics
// layer and finds a provider in `SolveContext.accelerator`; this is the provider that ships.
// The facade's strategies attach it on their own; a direct engine call opts in with
//
//     var context = SolveContext()
//     context.accelerator = MetalAccelerator.shared      // or: context.attachMetal()

import Metal
import ZTronLPCore
import ZTronLPNumerics

/// Supplies the `reducedCostScan` and `batchedActivity` kernels.
///
/// A request returns `nil` — and the engine stays on its CPU path — when the policy is `.off`,
/// when the problem is below the thresholds of §6.4 under `.automatic`, or when the tier is
/// unavailable: no device, or the shaders could neither be loaded nor compiled. `.forced`
/// ignores the thresholds and is meant for tests.
///
/// The Metal context is created lazily by the first request that gets past the policy and the
/// thresholds. The fp32 copy of A is built once per problem and shared by every worker that
/// asks for it; the provider only remembers kernels weakly, so the copy is released as soon as
/// the last engine of the solve lets go of its kernel.
public final class MetalAccelerator: CandidateKernelProvider {
    /// The provider on the system's default Metal device.
    public static let shared = MetalAccelerator()

    private let state: MetalTierState

    /// A provider on the system's default device, asked for at first use.
    public init() {
        state = MetalTierState(choice: .systemDefault, scratchByteLimit: MetalTierState.defaultScratchByteLimit)
    }

    /// A provider on an explicit device. `nil` stands for a machine without a Metal device:
    /// every request then returns `nil`.
    public init(device: (any MTLDevice)?) {
        state = MetalTierState(choice: .explicit(device), scratchByteLimit: MetalTierState.defaultScratchByteLimit)
    }

    /// A provider whose activity kernel splits batches at `scratchByteLimit` bytes of scratch
    /// memory per dispatch; lets a test exercise the chunked path on a small problem.
    init(choice: MetalDeviceChoice, scratchByteLimit: Int) {
        state = MetalTierState(choice: choice, scratchByteLimit: scratchByteLimit)
    }

    public func reducedCostScanner(for lp: CompiledLP, policy: MetalPolicy) async -> (any ReducedCostScanning)? {
        guard KernelThresholds.allowsReducedCostScan(columns: lp.n, nonzeros: lp.nnz, policy: policy) else {
            return nil
        }
        return await state.scanner(for: lp)
    }

    public func activityEvaluator(for lp: CompiledLP, policy: MetalPolicy) async -> (any BatchedActivityEvaluating)? {
        // The batch size is only known per call; the matrix size decides here.
        guard KernelThresholds.allowsBatchedActivity(
            points: KernelThresholds.batchedActivityPoints, nonzeros: lp.nnz, policy: policy)
        else { return nil }
        guard let kernel = await state.evaluator(for: lp) else { return nil }
        return PolicyBoundActivityEvaluator(kernel: kernel, policy: policy, nonzeros: lp.nnz)
    }

    /// Whether the tier is usable, creating the context if no request has done so yet.
    public func status() async -> MetalTierStatus {
        await state.status()
    }

    /// True when the kernels are loaded and ready.
    public var isAvailable: Bool {
        get async { await state.status().isReady }
    }

    /// The Metal context, when the tier is usable.
    public func context() async -> MetalContext? {
        await state.context()
    }
}

/// The provider's mutable state (rule C2): the lazily created context and the kernels that
/// are currently alive.
actor MetalTierState {
    /// Scratch memory one `batchedActivity` dispatch may use.
    static let defaultScratchByteLimit = 64 << 20

    private let choice: MetalDeviceChoice
    private let scratchByteLimit: Int
    /// The one attempt at creating the context. Requests that arrive while it is running
    /// await the same task, so the device is asked for and the shaders are compiled once.
    private var startup: Task<(context: MetalContext?, status: MetalTierStatus), Never>?

    private struct LiveScanner {
        weak var kernel: MetalReducedCostScan?
    }
    private struct LiveEvaluator {
        weak var kernel: MetalBatchedActivity?
    }
    private var scanners: [LiveScanner] = []
    private var evaluators: [LiveEvaluator] = []

    init(choice: MetalDeviceChoice, scratchByteLimit: Int) {
        self.choice = choice
        self.scratchByteLimit = scratchByteLimit
    }

    private func resolved() async -> (context: MetalContext?, status: MetalTierStatus) {
        if let startup { return await startup.value }
        let choice = self.choice
        let task = Task { await MetalContext.make(choice) }
        startup = task
        return await task.value
    }

    func status() async -> MetalTierStatus {
        await resolved().status
    }

    func context() async -> MetalContext? {
        await resolved().context
    }

    /// True when a static copy of `bytes` bytes fits the default memory budget of a solve
    /// (25% of what the process may still allocate, §2).
    private func fits(_ bytes: Int) -> Bool {
        bytes <= MemoryBudget.availableBytes() / 4
    }

    /// The scan kernel for `lp`'s matrix: the live one when a kernel for an equal matrix
    /// exists, a new one otherwise.
    func scanner(for lp: CompiledLP) async -> MetalReducedCostScan? {
        guard let context = await resolved().context else { return nil }
        // No suspension from here on: lookup and insertion are one atomic step.
        scanners.removeAll { $0.kernel == nil }
        for entry in scanners {
            // Array equality is O(1) for two copies of one problem and a full comparison for
            // equal problems built separately, e.g. the same scaling computed by each worker.
            if let kernel = entry.kernel, kernel.rows == lp.m, kernel.columns == lp.n, kernel.matrix == lp.a {
                return kernel
            }
        }
        guard fits(MetalReducedCostScan.staticBytes(for: lp.a)),
              let kernel = MetalReducedCostScan(context: context, matrix: lp.a)
        else { return nil }
        scanners.append(LiveScanner(kernel: kernel))
        return kernel
    }

    /// The activity kernel for `lp`'s matrix and bounds, shared in the same way.
    func evaluator(for lp: CompiledLP) async -> MetalBatchedActivity? {
        guard let context = await resolved().context else { return nil }
        evaluators.removeAll { $0.kernel == nil }
        for entry in evaluators {
            if let kernel = entry.kernel, kernel.serves(lp) { return kernel }
        }
        guard fits(MetalBatchedActivity.staticBytes(for: lp)),
              let kernel = MetalBatchedActivity(context: context, lp: lp, scratchByteLimit: scratchByteLimit)
        else { return nil }
        evaluators.append(LiveEvaluator(kernel: kernel))
        return kernel
    }
}

extension SolveContext {
    /// Attaches the Metal kernel provider, unless the policy is `.off` or a provider is
    /// already attached.
    public mutating func attachMetal(_ accelerator: MetalAccelerator = .shared) {
        guard metal != .off, self.accelerator == nil else { return }
        self.accelerator = accelerator
    }

    /// A copy with the Metal kernel provider attached, unless the policy is `.off` or a
    /// provider is already attached.
    public func attachingMetal(_ accelerator: MetalAccelerator = .shared) -> SolveContext {
        var copy = self
        copy.attachMetal(accelerator)
        return copy
    }
}
