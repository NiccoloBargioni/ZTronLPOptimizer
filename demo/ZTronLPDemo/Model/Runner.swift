// Runs one strategy on one example and turns the result into a log.

import Foundation
import os
import ZTronLPOptimizer

enum Runner {
    /// Every run is capped, so no example can hang the app; reaching the cap is a result.
    static let defaultTimeLimit = 10.0

    /// Compiles the example, solves it with the tab's strategy and describes the result.
    /// Cancelling the calling task stops the solve; the log then says so. `@concurrent` keeps
    /// the work off the caller's actor, so a solve started from the UI never blocks it.
    @concurrent
    static func run(_ kind: StrategyKind, variant: Variant.ID, example: Example) async -> RunLog {
        let built: BuiltExample
        do {
            built = try example.build()
        } catch {
            return Report.notCompiled(error)
        }
        let strategy = kind.strategy(variant, for: example)
        var context = SolveContext()
        context.timeLimit = example.limits.seconds ?? defaultTimeLimit
        let events = EventCollector()
        context.progress = { events.record($0) }
        do {
            let analysis = try await strategy.solve(built.lp, context: context)
            return Report.make(analysis, engine: strategy.engineName, built: built, events: events.events)
        } catch {
            // `solve` throws only `SolverError`, and only for a model the engine does not accept.
            return Report.rejected(error, engine: strategy.engineName, lp: built.lp)
        }
    }
}

/// Collects the progress events of one solve. The callback runs on the solver's task, so it
/// only appends under a lock; iteration and node ticks are dropped, the log does not show them.
final class EventCollector: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [SolverEvent]())

    func record(_ event: SolverEvent) {
        switch event {
        case .simplexIteration, .ipmIteration, .nodes:
            return
        default:
            storage.withLock { events in
                if events.count < 1_000 { events.append(event) }
            }
        }
    }

    var events: [SolverEvent] { storage.withLock { $0 } }
}
