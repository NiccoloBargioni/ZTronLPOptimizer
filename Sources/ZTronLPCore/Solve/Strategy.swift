// Strategy interface (specification §11.1) and the value types every engine shares.

import Foundation

// MARK: - Tolerances (§6.5)

/// Numerical tolerances. Every default is the value of the specification's table.
public struct Tolerances: Sendable, Hashable {
    /// Bound/row violation allowed, after scaling.
    public var primalFeasibility: Double = 1e-7
    /// Reduced-cost violation allowed.
    public var dualFeasibility: Double = 1e-7
    /// Minimum |α| accepted as a pivot (relative to the column's max).
    public var pivot: Double = 1e-7
    /// Ratio-test tolerance relaxation in pass 1.
    public var harris: Double = 1e-9
    /// Coefficients and eta entries below this are dropped.
    public var dropZero: Double = 1e-14
    /// Distance from an integer that counts as integral.
    public var integrality: Double = 1e-6
    /// B&B / CP-SAT stop when (incumbent − bound)/max(1, |incumbent|) ≤ gap.
    public var mipRelativeGap: Double = 1e-4
    /// As above, absolute.
    public var mipAbsoluteGap: Double = 1e-6
    /// Relative primal, dual and gap residuals of the interior-point method.
    public var ipmResidual: Double = 1e-8

    public init() {}

    public static let `default` = Tolerances()
}

/// How an engine scales the problem before solving it (§5.4).
public enum ScalingMode: Sendable, Hashable {
    /// No scaling.
    case none
    /// One equilibration pass: every row and column gets ‖·‖∞ ≈ 1.
    case equilibration
    /// Geometric-mean scaling (up to 20 passes) followed by equilibration.
    case geometricEquilibration
}

// MARK: - Basis and warm starts (§7.4)

/// The status of one column of the logical form `[A −I]`.
public enum BasisStatus: UInt8, Sendable, Hashable {
    case basic, atLower, atUpper, free, fixed
}

/// A simplex basis. Column indices `0..<n` are structural and `n..<n+m` are logical, in every
/// engine and in the solution's reduced-cost arrays (§5.5).
public struct Basis: Sendable, Hashable {
    /// `n + m` entries, structural then logical.
    public var status: [BasisStatus]
    /// The `m` basic column indices, in row order.
    public var basic: [Int32]

    public init(status: [BasisStatus], basic: [Int32]) {
        self.status = status
        self.basic = basic
    }

    /// The all-logical basis of a problem: every row's slack is basic and every structural
    /// column sits at its finite bound nearest to zero (free columns at zero).
    public static func allLogical(for lp: CompiledLP) -> Basis {
        var status = [BasisStatus](repeating: .basic, count: lp.n + lp.m)
        for j in 0..<lp.n {
            status[j] = nonbasicStatus(lower: lp.xl[j], upper: lp.xu[j])
        }
        return Basis(status: status, basic: (0..<lp.m).map { Int32(lp.n + $0) })
    }

    /// The natural nonbasic status of a column with the given bounds.
    public static func nonbasicStatus(lower: Double, upper: Double) -> BasisStatus {
        if lower == upper { return .fixed }
        let hasLower = lower > -.infinity
        let hasUpper = upper < .infinity
        if hasLower && hasUpper { return Swift.abs(lower) <= Swift.abs(upper) ? .atLower : .atUpper }
        if hasLower { return .atLower }
        if hasUpper { return .atUpper }
        return .free
    }
}

/// The bounds a branch-and-bound node imposes on one column.
public struct BoundChange: Sendable, Hashable {
    public let column: Int32
    /// The node's bounds for that column.
    public let lower: Double
    public let upper: Double

    public init(column: Int32, lower: Double, upper: Double) {
        self.column = column
        self.lower = lower
        self.upper = upper
    }
}

/// Structural crash procedures for a cold start.
public enum CrashKind: Sendable, Hashable {
    /// The all-logical basis.
    case slack
    /// A lower-triangular basis of structural columns by the classic LTSF ordering
    /// (singleton columns first).
    case triangular
}

/// How a simplex solve obtains its starting basis.
public enum WarmStart: Sendable {
    /// All-logical crash basis.
    case none
    /// Reuse a basis from a previous solve of the same problem, or of one with the same shape
    /// and changed data.
    case basis(Basis)
    /// Branch-and-bound hot start: the parent's basis plus a short list of bound changes.
    case incremental(parent: Basis, changes: [BoundChange])
    /// Crash a basis from a primal point (interior-point output, a heuristic).
    case primalPoint([Double])
    /// A structural crash.
    case crash(CrashKind)
}

// MARK: - Run-level resources (§11.1)

/// Whether an engine may use the GPU tier for candidate generation (§6.4).
public enum MetalPolicy: Sendable, Hashable {
    /// Never.
    case off
    /// Above the size thresholds of §6.4, when a kernel provider is attached and a device exists.
    case automatic
    /// Regardless of size; for tests.
    case forced
}

/// Marker for the object that supplies optional candidate-generation kernels to an engine.
///
/// Engines never import the GPU target (§3). The kernel protocols live in the numerics layer
/// and refine this marker; the provider travels in `SolveContext.accelerator`. The facade's
/// strategies attach the Metal provider on their own; a direct engine call opts in with
/// `context.accelerator = MetalAccelerator.shared`.
public protocol SolveAccelerator: Sendable {}

/// The few resources that belong to one run rather than to an engine's configuration.
public struct SolveContext: Sendable {
    /// Seconds, wall clock.
    public var timeLimit: Double? = nil
    /// `nil` → `ProcessInfo.processInfo.activeProcessorCount`.
    public var threads: Int? = nil
    /// `nil` → 25% of the memory available to the process.
    public var memoryBudgetBytes: Int? = nil
    /// `.off`, `.automatic`, `.forced` (tests only).
    public var metal: MetalPolicy = .automatic
    /// An engine ignores kinds it cannot use.
    public var warmStart: WarmStart = .none
    /// Runs on the solver's task; must be cheap.
    public var progress: (@Sendable (SolverEvent) -> Void)? = nil
    /// Optional candidate-kernel provider (the GPU tier); `nil` keeps every kernel on the CPU.
    public var accelerator: (any SolveAccelerator)? = nil

    public init() {}

    /// The number of worker threads this run may use; at least 1.
    public var resolvedThreads: Int {
        Swift.max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Routes this context's progress into an `AsyncStream`.
    ///
    /// The stream buffers the newest 256 events (rule C8): a consumer that never reads can
    /// neither block the solver nor grow memory. The stream ends after `.finished`. A
    /// previously installed `progress` callback keeps receiving every event.
    public mutating func makeEventStream() -> AsyncStream<SolverEvent> {
        var created: AsyncStream<SolverEvent>.Continuation?
        let stream = AsyncStream<SolverEvent>(bufferingPolicy: .bufferingNewest(256)) { created = $0 }
        guard let continuation = created else { return stream }
        let previous = progress
        progress = { event in
            previous?(event)
            continuation.yield(event)
            if event.isFinished { continuation.finish() }
        }
        return stream
    }
}

// MARK: - The strategy protocol

/// Every solver is a value conforming to this protocol: configured in its initializer, run
/// with `solve(_:)`, reusable and safe to run concurrently.
public protocol SolverStrategy: Sendable {
    associatedtype Analysis: SolutionAnalysis

    /// Solves a compiled problem. Limits and cancellation end in the analysis's status; only
    /// model errors throw.
    func solve(_ problem: CompiledLP, context: SolveContext) async throws -> Analysis

    /// A short human-readable name, used for events and for type-erased analyses. The default
    /// is the type's name; a strategy overrides it to show its configuration.
    var engineName: String { get }
}

extension SolverStrategy {
    /// Solves with the default context.
    public func solve(_ problem: CompiledLP) async throws -> Analysis {
        try await solve(problem, context: SolveContext())
    }

    /// Typed convenience: compiles the model, solves it, keys the result by variable.
    public func solve<V: LPVariable>(
        _ model: LPModel<V>, context: SolveContext = .init()
    ) async throws -> Solution<V, Analysis> {
        let compiled = try model.compile()
        let analysis = try await solve(compiled.lp, context: context)
        return Solution(analysis: analysis, compiled: compiled)
    }

    public var engineName: String { String(describing: Self.self) }
}

// MARK: - Events

/// Serializes the events of one solve (rule C2) and enforces their order (rule L10):
/// `.finished` is the last event delivered and is delivered exactly once, whatever the exit
/// path, and anything emitted after it is dropped.
public actor EventSink {
    private let progress: (@Sendable (SolverEvent) -> Void)?
    private var finished = false
    private var collectedWarnings: [String] = []

    /// False when nobody listens, so engines can skip building events.
    public nonisolated let hasListener: Bool

    public init(_ progress: (@Sendable (SolverEvent) -> Void)?) {
        self.progress = progress
        self.hasListener = progress != nil
    }

    /// Delivers an event unless the solve has already finished.
    public func emit(_ event: SolverEvent) {
        guard !finished else { return }
        if case .warning(let text) = event { collectedWarnings.append(text) }
        if event.isFinished { finished = true }
        progress?(event)
    }

    /// Records a warning and reports it.
    public func warn(_ text: String) {
        emit(.warning(text))
    }

    /// Delivers `.finished` if it has not been delivered yet.
    public func finish(status: SolveStatus, seconds: Double) {
        emit(.finished(status: status, seconds: seconds))
    }

    /// Every warning emitted so far, in order.
    public var warnings: [String] { collectedWarnings }

    /// True once `.finished` has been delivered.
    public var isFinished: Bool { finished }
}

extension SolveContext {
    /// A copy for a nested solve that belongs to an enclosing one: its events reach the same
    /// listener, except `.started` and `.finished`, which only the enclosing solve reports.
    public func nested() -> SolveContext {
        var copy = self
        if let progress {
            copy.progress = { event in
                switch event {
                case .started, .finished: return
                default: progress(event)
                }
            }
        }
        return copy
    }

    /// A copy that reports nothing.
    public func silenced() -> SolveContext {
        var copy = self
        copy.progress = nil
        return copy
    }
}
