// Liveness harness (specification §12.2, §14.2).
//
// Helpers the liveness tests and the benchmark executable share: cancellation latency, event
// recording, and a stand-in for a UI timer that measures how late its ticks arrive while a
// solve is running.

import Dispatch
import Foundation
import ZTronLPCore

public enum LivenessHarness {
    /// How much slower than an ordinary build the code under test is allowed to be:
    /// `ZTRONLP_LATENCY_SCALE` when it is set to a number ≥ 1, otherwise 1. A run under Thread
    /// Sanitizer is there to find races, and instrumented code is an order of magnitude
    /// slower; the latency bounds of rule L1 and the time limits of the corpus tests are
    /// multiplied by this factor so that such a run measures nothing it was not meant to.
    public static let instrumentationScale: Double = {
        guard let text = ProcessInfo.processInfo.environment["ZTRONLP_LATENCY_SCALE"],
              let value = Double(text), value >= 1 else { return 1 }
        return value
    }()

    /// One cancellation measurement.
    public struct CancellationSample: Sendable {
        /// Seconds between `Task.cancel()` and the solve returning.
        public let latency: Double
        public let status: SolveStatus
        /// True when the solve had already finished before the cancellation reached it.
        public let finishedFirst: Bool
    }

    /// Starts `strategy` on `problem`, cancels the task after `delay` seconds and measures
    /// how long the solve takes to return (rule L1).
    public static func cancellationLatency<S: SolverStrategy>(
        _ strategy: S, problem: CompiledLP, context: SolveContext = .init(), after delay: Double
    ) async -> CancellationSample {
        let task = Task { () -> (SolveStatus, UInt64) in
            let status = (try? await strategy.solve(problem, context: context))?.status ?? .numericalFailure("threw")
            return (status, DispatchTime.now().uptimeNanoseconds)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let cancelled = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        let (status, returned) = await task.value
        let finishedFirst = returned <= cancelled
        return CancellationSample(
            latency: finishedFirst ? 0 : Double(returned - cancelled) / 1e9, status: status,
            finishedFirst: finishedFirst)
    }

    /// The `q`-quantile (0…1) of a list of samples; 0 for an empty list.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Swift.min(sorted.count - 1, Swift.max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[position]
    }

    /// Runs a solve with its events recorded, and returns them in delivery order together
    /// with the analysis (or the error it threw).
    ///
    /// The recorder closes its own stream once the solve has returned, so it terminates even
    /// when a solve breaks the contract under test and never reports `.finished`.
    public static func recordEvents<S: SolverStrategy>(
        _ strategy: S, problem: CompiledLP, context: SolveContext = .init()
    ) async -> (events: [SolverEvent], result: Result<S.Analysis, any Error>) {
        let recorder = EventRecorder(context: context)
        let result: Result<S.Analysis, any Error>
        do {
            result = .success(try await strategy.solve(problem, context: recorder.context))
        } catch {
            result = .failure(error)
        }
        return (await recorder.finish(), result)
    }

    /// Whether an event sequence obeys rule L10: `.finished` exactly once, and last.
    public static func finishesExactlyOnce(_ events: [SolverEvent]) -> Bool {
        events.filter(\.isFinished).count == 1 && events.last?.isFinished == true
    }

    /// A periodic task standing in for a UI timer (rule L8): it sleeps `interval` seconds at a
    /// time on the cooperative pool until cancelled and returns how late each wake-up was, in
    /// seconds. A starved pool shows up as large lateness.
    public static func timer(interval: Double) -> Task<[Double], Never> {
        Task {
            var lateness: [Double] = []
            let step = UInt64(interval * 1e9)
            var due = DispatchTime.now().uptimeNanoseconds &+ step
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now { try? await Task.sleep(nanoseconds: due - now) }
                if Task.isCancelled { break }
                let woke = DispatchTime.now().uptimeNanoseconds
                lateness.append(woke > due ? Double(woke - due) / 1e9 : 0)
                due = Swift.max(due &+ step, woke)
            }
            return lateness
        }
    }
}

/// Records every event of a solve, in delivery order.
///
/// Unlike `SolveContext.makeEventStream()`, which keeps only the newest 256 events and ends
/// with `.finished`, the recorder keeps everything and ends when it is told to — which is what
/// a test needs in order to check the order of the events of a solve that may misbehave.
public struct EventRecorder: Sendable {
    /// The context to hand to `solve`: the original one, with the recorder listening.
    public let context: SolveContext
    private let stream: AsyncStream<SolverEvent>
    private let continuation: AsyncStream<SolverEvent>.Continuation

    public init(context: SolveContext = .init()) {
        var created: AsyncStream<SolverEvent>.Continuation?
        let stream = AsyncStream<SolverEvent>(bufferingPolicy: .unbounded) { created = $0 }
        // The build closure runs synchronously, so the continuation exists here.
        let continuation = created!
        self.stream = stream
        self.continuation = continuation
        var listening = context
        let previous = context.progress
        listening.progress = { event in
            previous?(event)
            continuation.yield(event)
        }
        self.context = listening
    }

    /// Stops recording and returns everything that was delivered.
    public func finish() async -> [SolverEvent] {
        continuation.finish()
        var events: [SolverEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

