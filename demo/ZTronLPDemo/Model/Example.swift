// One demo problem: what it is, how it is written, and how to build it.
//
// Everything in Model/ is plain Swift on top of ZTronLPOptimizer, without SwiftUI, so the
// same files can be compiled into a command-line harness that runs every example.

import ZTronLPOptimizer

struct Example: Identifiable, Sendable {
    enum ProblemClass: String, Sendable {
        case lp = "LP"
        case mixedInteger = "MILP"
        case integer = "Integer"
        case binary = "Binary"
    }

    enum Conditioning: String, Sendable {
        case well = "Well conditioned"
        case bad = "Badly conditioned"
    }

    /// Caps applied to this example only. `nodes` binds branch and bound, `seconds` every engine.
    struct Limits: Sendable, Hashable {
        var seconds: Double? = nil
        var nodes: Int? = nil
    }

    let id: String
    let title: String
    /// One line for the list row.
    let subtitle: String
    /// What the problem is and what to look for in the log.
    let summary: String
    /// The model in mathematical notation, for reading; the engine's view is generated from `build`.
    let formulation: String
    let problemClass: ProblemClass
    let conditioning: Conditioning
    var limits = Limits()
    /// Builds the model with the DSL and compiles it.
    let build: @Sendable () throws -> BuiltExample
}

/// A line that a problem-specific check adds to the log.
enum CheckLine: Sendable {
    case info(String)
    case problem(String)
}

/// A compiled example: the problem every strategy solves, and an optional problem-specific
/// check of a primal solution.
struct BuiltExample: Sendable {
    let lp: CompiledLP
    let check: (@Sendable ([Double]) -> [CheckLine])?

    init<V: LPVariable>(
        _ compiled: CompiledModel<V>,
        check: (@Sendable (CompiledModel<V>, [Double]) -> [CheckLine])? = nil
    ) {
        lp = compiled.lp
        if let check {
            self.check = { x in check(compiled, x) }
        } else {
            self.check = nil
        }
    }
}

/// A titled list of examples inside one tab.
struct ExampleGroup: Identifiable, Sendable {
    let title: String
    let examples: [Example]
    var id: String { title }

    init(_ title: String, _ examples: [Example]) {
        self.title = title
        self.examples = examples
    }
}

extension CompiledModel {
    /// The value of `v` in a primal vector; 0 when the model does not contain it.
    func value(of v: V, in x: [Double]) -> Double {
        guard let j = column[v], j < x.count else { return 0 }
        return x[j]
    }
}
