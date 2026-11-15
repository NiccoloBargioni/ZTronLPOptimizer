// What the app remembers for every example on every tab: the configuration picked, the run in
// progress, and the log of the last run. Each tab keeps its own logs, so the same problem can
// be compared across strategies.

import Foundation
import Observation

@MainActor
@Observable
final class RunStore {
    struct Key: Hashable {
        let kind: StrategyKind
        let example: Example.ID
    }

    enum Phase {
        case idle
        case running(since: Date)
        case finished(RunLog)
    }

    private var phases: [Key: Phase] = [:]
    private var variants: [Key: Variant.ID] = [:]
    @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]

    func phase(_ kind: StrategyKind, _ example: Example) -> Phase {
        phases[Key(kind: kind, example: example.id)] ?? .idle
    }

    func isRunning(_ kind: StrategyKind, _ example: Example) -> Bool {
        if case .running = phase(kind, example) { return true }
        return false
    }

    func variant(_ kind: StrategyKind, _ example: Example) -> Variant.ID {
        variants[Key(kind: kind, example: example.id)] ?? kind.defaultVariant
    }

    func setVariant(_ variant: Variant.ID, _ kind: StrategyKind, _ example: Example) {
        variants[Key(kind: kind, example: example.id)] = variant
    }

    /// Runs the tab's strategy on the example. The solve itself runs off the main actor.
    func solve(_ kind: StrategyKind, _ example: Example) {
        let key = Key(kind: kind, example: example.id)
        guard tasks[key] == nil else { return }
        let variant = variant(kind, example)
        phases[key] = .running(since: .now)
        tasks[key] = Task {
            let log = await Runner.run(kind, variant: variant, example: example)
            self.phases[key] = .finished(log)
            self.tasks[key] = nil
        }
    }

    /// Cancels the run; the engine stops at its next check and reports what it has.
    func stop(_ kind: StrategyKind, _ example: Example) {
        tasks[Key(kind: kind, example: example.id)]?.cancel()
    }
}
