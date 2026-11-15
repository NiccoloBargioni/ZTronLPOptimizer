// Statuses, errors and events (specification §11.4).

/// How a solve ended.
public enum SolveStatus: Sendable, Hashable {
    /// An optimal solution was found and proven (within the gap, for MILP).
    case optimal
    /// The model has no feasible point.
    case infeasible
    /// The objective is unbounded over a nonempty feasible set.
    case unbounded
    /// The solve could not tell infeasible from unbounded (interior point without a
    /// homogeneous self-dual embedding).
    case infeasibleOrUnbounded
    /// An incumbent exists; optimality was not proven.
    case feasible(stoppedBy: StopReason)
    /// The solve stopped before finding any feasible point.
    case noSolution(stoppedBy: StopReason)
    /// A numerical safeguard was exhausted.
    case numericalFailure(String)

    public var isOptimal: Bool {
        if case .optimal = self { return true }
        return false
    }

    /// True when a primal solution accompanies the status.
    public var hasSolution: Bool {
        switch self {
        case .optimal, .feasible: return true
        default: return false
        }
    }

    /// The reason the solve stopped early, when it did.
    public var stopReason: StopReason? {
        switch self {
        case .feasible(let reason), .noSolution(let reason): return reason
        default: return nil
        }
    }
}

/// Why a solve stopped before proving optimality.
public enum StopReason: Sendable, Hashable {
    case timeLimit, iterationLimit, nodeLimit, cancelled, gapReached, memoryBudget
}

/// The only errors `solve` throws. Limits and cancellation are results, never errors.
public enum SolverError: Error, Sendable {
    /// Thrown by `compile()`.
    case invalidModel(ModelDiagnostic)
    /// The model is outside what the engine accepts, e.g. continuous columns given to CP-SAT.
    case unsupported(String)
    /// A bug in the solver; never caused by user data.
    case internalInconsistency(String)
}

extension SolverError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidModel(let diagnostic): return "invalid model: \(diagnostic.message)"
        case .unsupported(let what): return "unsupported: \(what)"
        case .internalInconsistency(let what): return "internal inconsistency: \(what)"
        }
    }
}

/// A problem found while compiling or reading a model.
public struct ModelDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: Sendable, Hashable { case warning, error }

    public enum Kind: Sendable, Hashable {
        /// A coefficient is NaN or infinite.
        case nonFiniteCoefficient(variable: String, location: String)
        /// A constant, bound or right-hand side is NaN, or infinite on the wrong side.
        case nonFiniteValue(location: String)
        /// A constraint with no variables whose bounds exclude its constant (`0 ≤ −1`).
        case infeasibleConstantConstraint(name: String?, index: Int)
        /// `lower > upper` on a variable.
        case inconsistentVariableBounds(variable: String, lower: Double, upper: Double)
        /// `lower > upper` on a row.
        case inconsistentRowBounds(row: String, lower: Double, upper: Double)
        /// Two constraints share a name.
        case duplicateConstraintName(String)
        /// An integer variable is fixed at a non-integral value.
        case nonIntegralFixedBound(variable: String, value: Double)
        /// More than `Int32.max` rows, columns or nonzeros.
        case sizeLimitExceeded(what: String, count: Int)
        /// A coefficient with |a| < 1e-14 was dropped (warning).
        case droppedSmallCoefficient(variable: String, location: String, value: Double)
        /// A file could not be parsed (MPS/LP readers).
        case syntax(line: Int, message: String)
    }

    public let severity: Severity
    public let kind: Kind
    public let message: String

    public init(severity: Severity, kind: Kind, message: String) {
        self.severity = severity
        self.kind = kind
        self.message = message
    }

    public var description: String { message }

    static func error(_ kind: Kind) -> ModelDiagnostic {
        ModelDiagnostic(severity: .error, kind: kind, message: describe(kind))
    }

    static func warning(_ kind: Kind) -> ModelDiagnostic {
        ModelDiagnostic(severity: .warning, kind: kind, message: describe(kind))
    }

    private static func describe(_ kind: Kind) -> String {
        switch kind {
        case .nonFiniteCoefficient(let variable, let location):
            return "the coefficient of \(variable) in \(location) is not finite"
        case .nonFiniteValue(let location):
            return "\(location) is not a usable number"
        case .infeasibleConstantConstraint(let name, let index):
            return "constraint \(name ?? "#\(index)") has no variables and its bounds exclude zero; the model is infeasible"
        case .inconsistentVariableBounds(let variable, let lower, let upper):
            return "variable \(variable) has lower bound \(lower) above upper bound \(upper)"
        case .inconsistentRowBounds(let row, let lower, let upper):
            return "row \(row) has lower bound \(lower) above upper bound \(upper)"
        case .duplicateConstraintName(let name):
            return "the constraint name \(name) is used more than once"
        case .nonIntegralFixedBound(let variable, let value):
            return "integer variable \(variable) is fixed at the non-integral value \(value)"
        case .sizeLimitExceeded(let what, let count):
            return "the model has \(count) \(what), more than the 2,147,483,647 an Int32 index can address"
        case .droppedSmallCoefficient(let variable, let location, let value):
            return "dropped the coefficient \(value) of \(variable) in \(location) (below 1e-14 in magnitude)"
        case .syntax(let line, let message):
            return "line \(line): \(message)"
        }
    }
}

/// Progress reported through `SolveContext.progress`.
///
/// Iterations are reported at most every 100 (simplex) or every one (interior point) and nodes
/// at most every 100 ms. `.finished` is the last event of a solve and is delivered exactly once
/// on every exit path.
public enum SolverEvent: Sendable, Hashable {
    case started(engine: String, rows: Int, columns: Int, nonzeros: Int)
    case presolved(rows: Int, columns: Int, removedRows: Int, removedColumns: Int)
    case simplexIteration(iteration: Int, objective: Double, infeasibility: Double, phase: Int)
    case ipmIteration(iteration: Int, mu: Double, primalResidual: Double, dualResidual: Double)
    case newIncumbent(objective: Double, node: Int, source: String)
    case boundImproved(bound: Double, gap: Double)
    case nodes(processed: Int, open: Int)
    case warning(String)
    case finished(status: SolveStatus, seconds: Double)

    /// True for `.finished`.
    public var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
