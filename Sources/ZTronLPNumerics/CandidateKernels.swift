// Candidate kernels: the seam between the engines and the optional fp32 GPU tier
// (specification §6.4).
//
// Metal computes in float32; it never decides anything. An engine asks a provider for a
// kernel, gets candidates back, and re-verifies every one of them in Double on the CPU. The
// engines know only these protocols — the Metal target implements them and the provider
// reaches the engine through `SolveContext.accelerator` — so no engine imports the GPU target
// and a test can inject a kernel that lies in order to exercise the disagreement guard.

import ZTronLPCore

/// Size thresholds of the candidate kernels under `MetalPolicy.automatic`.
public enum KernelThresholds {
    /// `reducedCostScan` needs n ≥ 3,000,000 …
    ///
    /// The specification starts from n ≥ 50,000 and nnz ≥ 500,000 and says to raise the
    /// threshold if the §14.3 benchmark does not show Metal at least 1.5× faster than the CPU
    /// scan. Measured on an M3, over eleven runs of that benchmark: 0.35–1.23× at 200,000
    /// columns / 400,000 nonzeros; 1.08–1.89× at 1,000,000 / 2,000,000, at or above 1.5× in
    /// two of them; 1.17–2.30× at 3,000,000 / 6,000,000, at or above 1.5× in nine (the two
    /// below were both taken inside the full benchmark, after minutes of all-core load). The
    /// threshold sits at the smallest of those sizes where the kernel clears 1.5× as a rule.
    /// Re-run `ZTronLPBenchmarks metal` to revise it for another device.
    public static let reducedCostScanColumns = 3_000_000
    /// … and nnz ≥ 6,000,000.
    public static let reducedCostScanNonzeros = 6_000_000
    /// The scan returns this many candidate columns.
    public static let reducedCostCandidates = 64
    /// `batchedActivity` needs a batch of at least 64 points …
    public static let batchedActivityPoints = 64
    /// … on a matrix with nnz ≥ 100,000.
    public static let batchedActivityNonzeros = 100_000
    /// The largest batch one call evaluates.
    public static let batchedActivityMaxBatch = 1_024
    /// A kernel disables itself for the solve when verification disagrees with more than 5% of
    /// its candidates.
    public static let disagreementFraction = 0.05

    /// Whether the scan kernel applies to a problem of this size under `policy`.
    public static func allowsReducedCostScan(columns: Int, nonzeros: Int, policy: MetalPolicy) -> Bool {
        switch policy {
        case .off: return false
        case .forced: return true
        case .automatic: return columns >= reducedCostScanColumns && nonzeros >= reducedCostScanNonzeros
        }
    }

    /// Whether the activity kernel applies to a batch of this size under `policy`.
    public static func allowsBatchedActivity(points: Int, nonzeros: Int, policy: MetalPolicy) -> Bool {
        switch policy {
        case .off: return false
        case .forced: return points > 0
        case .automatic: return points >= batchedActivityPoints && nonzeros >= batchedActivityNonzeros
        }
    }
}

/// How a nonbasic column may enter the basis, for the pricing scan's mask.
public enum PricingEligibility {
    /// Basic or fixed: never a candidate.
    public static let none: UInt8 = 0
    /// At its lower bound: attractive when d < 0.
    public static let increase: UInt8 = 1
    /// At its upper bound: attractive when d > 0.
    public static let decrease: UInt8 = 2
    /// Free: attractive whenever d ≠ 0.
    public static let either: UInt8 = 3
}

/// The `reducedCostScan` kernel: fp32 pricing candidates.
public protocol ReducedCostScanning: Sendable {
    /// Computes d_j = c_j − a_jᵀy for every structural column in single precision and returns
    /// up to `limit` eligible columns ranked by |d_j|/√w_j, best first.
    ///
    /// - Parameters:
    ///   - costs: n structural costs.
    ///   - duals: m row duals y.
    ///   - weights: n pricing weights w (Devex reference weights); all ≥ some positive floor.
    ///   - eligibility: n `PricingEligibility` codes.
    /// - Returns: candidate columns, or `nil` when the kernel could not run. The caller
    ///   recomputes each candidate's reduced cost in Double before using it.
    func scan(costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int) async -> [Int32]?
}

/// The `batchedActivity` kernel: fp32 feasibility screening of candidate points.
public protocol BatchedActivityEvaluating: Sendable {
    /// Computes the row activities A·x of `count` points in single precision and flags each
    /// point whose activities and values lie within the row and column bounds, up to
    /// `tolerance`.
    ///
    /// - Parameters:
    ///   - points: `count × n` values, one point after another.
    /// - Returns: one flag per point, or `nil` when the kernel could not run. The caller
    ///   re-evaluates every flagged point in Double before it becomes an incumbent.
    func evaluate(points: [Double], count: Int, tolerance: Double) async -> [Bool]?
}

/// Supplies candidate kernels for a problem. `ZTronLPMetal.MetalAccelerator` is the
/// implementation that ships; engines find the provider in `SolveContext.accelerator`.
public protocol CandidateKernelProvider: SolveAccelerator {
    /// A pricing scanner for `lp`, or `nil` when the tier is off, below its threshold or
    /// unavailable (no device, shader compilation failed).
    func reducedCostScanner(for lp: CompiledLP, policy: MetalPolicy) async -> (any ReducedCostScanning)?
    /// An activity evaluator for `lp`, or `nil` under the same conditions.
    func activityEvaluator(for lp: CompiledLP, policy: MetalPolicy) async -> (any BatchedActivityEvaluating)?
}

extension SolveContext {
    /// The attached candidate-kernel provider, when there is one and the policy allows it.
    public var candidateKernels: (any CandidateKernelProvider)? {
        guard metal != .off else { return nil }
        return accelerator as? any CandidateKernelProvider
    }
}

/// Tracks how often fp64 verification contradicts a kernel's fp32 candidates (§6.4).
///
/// A kernel whose verification disagrees on more than 5% of candidates in a solve logs a
/// warning and disables itself for that solve.
public struct KernelDisagreementGuard: Sendable {
    public private(set) var candidates = 0
    public private(set) var disagreements = 0
    public private(set) var isDisabled = false
    /// Candidates to see before the fraction means anything.
    public var minimumSample: Int

    public init(minimumSample: Int = 64) {
        self.minimumSample = minimumSample
    }

    /// Records one verified batch. Returns true exactly once: when this batch pushes the
    /// kernel over the limit and disables it.
    public mutating func record(candidates batch: Int, disagreements wrong: Int) -> Bool {
        guard !isDisabled else { return false }
        candidates += batch
        disagreements += wrong
        guard candidates >= minimumSample else { return false }
        if Double(disagreements) > KernelThresholds.disagreementFraction * Double(candidates) {
            isDisabled = true
            return true
        }
        return false
    }

    /// The fraction of candidates verification rejected.
    public var disagreementRate: Double {
        candidates == 0 ? 0 : Double(disagreements) / Double(candidates)
    }
}
