// Analyses: the Decorator (specification §11.3).
//
// `SolutionAnalysis` is the interface every result conforms to. `SolveRecord` is the plain
// record every engine fills first; `AnalysisDecorator` forwards the record's properties and
// lets a concrete analysis add its own. A caller who only needs the status and the primal
// values reads any analysis the same way; a caller who needs the basis, the node count or the
// interior-point residuals reads the concrete type.
//
// Conventions for every analysis:
//   * all values are unscaled and refer to the problem as it was given to `solve`;
//   * `objectiveValue` and `bound` are in the model's own sense (maximization models report
//     the maximum, not its negation);
//   * `dual[i]` is the sensitivity of the reported objective to the right-hand side of row i,
//     and `reducedCosts` has n + m entries — structural columns, then logical columns — with
//     the logical entry of row i equal to `dual[i]` (§5.5).

/// The interface every result conforms to.
public protocol SolutionAnalysis: Sendable {
    var status: SolveStatus { get }
    /// `nil` without a primal solution.
    var objectiveValue: Double? { get }
    /// Proven bound; equals `objectiveValue` when optimal.
    var bound: Double? { get }
    /// `n` structural values, unscaled.
    var primal: [Double]? { get }
    /// `m` row duals (LP engines); `nil` for MIP results.
    var dual: [Double]? { get }
    /// `n + m` reduced costs, structural then logical.
    var reducedCosts: [Double]? { get }
    var seconds: Double { get }
    var warnings: [String] { get }
}

/// The base record. Engines build it; decorators wrap it.
public struct SolveRecord: SolutionAnalysis {
    public var status: SolveStatus
    public var objectiveValue: Double?
    public var bound: Double?
    public var primal: [Double]?
    public var dual: [Double]?
    public var reducedCosts: [Double]?
    public var seconds: Double
    public var warnings: [String]

    public init(
        status: SolveStatus, objectiveValue: Double? = nil, bound: Double? = nil,
        primal: [Double]? = nil, dual: [Double]? = nil, reducedCosts: [Double]? = nil,
        seconds: Double = 0, warnings: [String] = []
    ) {
        self.status = status
        self.objectiveValue = objectiveValue
        self.bound = bound
        self.primal = primal
        self.dual = dual
        self.reducedCosts = reducedCosts
        self.seconds = seconds
        self.warnings = warnings
    }
}

/// GoF Decorator: forwards the wrapped analysis, adds fields. A decorator may override a
/// forwarded property.
public protocol AnalysisDecorator: SolutionAnalysis {
    associatedtype Base: SolutionAnalysis
    var base: Base { get }
}

extension AnalysisDecorator {
    public var status: SolveStatus { base.status }
    public var objectiveValue: Double? { base.objectiveValue }
    public var bound: Double? { base.bound }
    public var primal: [Double]? { base.primal }
    public var dual: [Double]? { base.dual }
    public var reducedCosts: [Double]? { base.reducedCosts }
    public var seconds: Double { base.seconds }
    public var warnings: [String] { base.warnings }
}

/// An analysis that can supply a simplex basis of the solved problem, when it has one.
///
/// `SimplexAnalysis` conforms directly; an interior-point analysis supplies the basis of its
/// crossover; a branch-and-bound analysis supplies its root's. The conditioning analyzer uses
/// this to find a basis without knowing the concrete analysis type.
public protocol BasisProviding {
    var finalBasis: Basis? { get }
}

/// Type erasure for `Automatic` and `Portfolio`; `unwrap` recovers the concrete analysis.
public struct AnySolutionAnalysis: SolutionAnalysis, BasisProviding {
    /// The name of the engine that produced the wrapped analysis.
    public let engine: String
    private let wrapped: any SolutionAnalysis

    public init(_ wrapped: some SolutionAnalysis, engine: String) {
        if let already = wrapped as? AnySolutionAnalysis {
            // Never nest erasures: `unwrap` should reach the concrete analysis in one step.
            self.wrapped = already.wrapped
        } else {
            self.wrapped = wrapped
        }
        self.engine = engine
    }

    /// The concrete analysis, when it has type `A`.
    public func unwrap<A: SolutionAnalysis>(as: A.Type = A.self) -> A? {
        wrapped as? A
    }

    public var status: SolveStatus { wrapped.status }
    public var objectiveValue: Double? { wrapped.objectiveValue }
    public var bound: Double? { wrapped.bound }
    public var primal: [Double]? { wrapped.primal }
    public var dual: [Double]? { wrapped.dual }
    public var reducedCosts: [Double]? { wrapped.reducedCosts }
    public var seconds: Double { wrapped.seconds }
    public var warnings: [String] { wrapped.warnings }

    public var finalBasis: Basis? { (wrapped as? any BasisProviding)?.finalBasis }
}

/// Variable-keyed view returned by the typed `solve`.
public struct Solution<V: LPVariable, A: SolutionAnalysis>: Sendable {
    public let analysis: A
    public let compiled: CompiledModel<V>

    public init(analysis: A, compiled: CompiledModel<V>) {
        self.analysis = analysis
        self.compiled = compiled
    }

    /// `analysis.status`.
    public var status: SolveStatus { analysis.status }

    public var objectiveValue: Double? { analysis.objectiveValue }

    /// The value of a variable; 0 for a variable absent from the model or when the solve
    /// produced no primal solution.
    public func value(of v: V) -> Double {
        guard let j = compiled.column[v], let primal = analysis.primal, j < primal.count else {
            return 0
        }
        return primal[j]
    }

    /// The values of every variable of the model the predicate accepts.
    public func values(where predicate: (V) -> Bool) -> [V: Double] {
        guard let primal = analysis.primal else { return [:] }
        var result: [V: Double] = [:]
        for (j, v) in compiled.variableAt.enumerated() where j < primal.count && predicate(v) {
            result[v] = primal[j]
        }
        return result
    }

    /// The dual of a named constraint; `nil` when the name is unknown or the analysis has no
    /// duals (MIP results).
    ///
    /// A one-variable constraint is lowered to a bound at compile time (§5.3) and has no row.
    /// Its dual is reconstructed from the reduced cost of its variable: the constraint
    /// receives the reduced cost when the bound it implies is the active one.
    public func dual(ofConstraintNamed name: String) -> Double? {
        if let row = compiled.rowNamed[name] {
            guard let dual = analysis.dual, row < dual.count else { return nil }
            return dual[row]
        }
        guard let lowered = compiled.lowered[name] else { return nil }
        guard analysis.dual != nil, let reduced = analysis.reducedCosts, let primal = analysis.primal
        else { return nil }
        let j = lowered.column
        guard j >= 0, j < primal.count, j < reduced.count, lowered.coefficient != 0 else { return 0 }
        let a = lowered.coefficient
        let impliedLower = a > 0 ? lowered.lower / a : lowered.upper / a
        let impliedUpper = a > 0 ? lowered.upper / a : lowered.lower / a
        let x = primal[j]
        let tolerance = 1e-7 * (1 + Swift.abs(x))
        // Work in the minimization form, where a column at its lower bound has d ≥ 0.
        let flip: Double = compiled.lp.sense == .maximize ? -1 : 1
        let d = flip * reduced[j]
        let lp = compiled.lp
        if d > 0, impliedLower == lp.xl[j], Swift.abs(x - impliedLower) <= tolerance {
            return flip * d / a
        }
        if d < 0, impliedUpper == lp.xu[j], Swift.abs(x - impliedUpper) <= tolerance {
            return flip * d / a
        }
        return 0
    }

    /// The reduced cost of a variable; 0 for a variable absent from the model or when the
    /// analysis has no reduced costs.
    public func reducedCost(of v: V) -> Double {
        guard let j = compiled.column[v], let reduced = analysis.reducedCosts, j < reduced.count else {
            return 0
        }
        return reduced[j]
    }
}
