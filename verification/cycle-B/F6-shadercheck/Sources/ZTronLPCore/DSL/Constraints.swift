// Constraints (specification §4.4).

/// A row `lower ≤ expr ≤ upper`.
///
/// A constraint can only be formed by a comparison (`<=`, `>=`, `==`), by `within(_:)` or by
/// `equal(to:)`; the constant of the expression is folded into the bounds, so `expr.constant`
/// is always zero.
public struct LinearConstraint<V: LPVariable>: Sendable, Hashable {
    /// The variable part of the row. Its constant is zero: assigning an expression that has
    /// one folds the constant into `lower` and `upper`.
    public var expr: LinearExpr<V> {
        didSet { foldConstant() }
    }
    /// `-.infinity` for a `≤` row.
    public var lower: Double
    /// `.infinity` for a `≥` row.
    public var upper: Double
    /// Optional name, used for duals (`Solution.dual(ofConstraintNamed:)`) and for export.
    public var name: String?

    @usableFromInline
    init(expr: LinearExpr<V>, lower: Double, upper: Double, name: String? = nil) {
        var folded = expr
        let k = folded.constant
        folded.constant = 0
        self.expr = folded
        self.lower = lower - k
        self.upper = upper - k
        self.name = name
    }

    /// A copy of the constraint carrying `name`.
    public func named(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    private mutating func foldConstant() {
        let k = expr.constant
        guard k != 0 else { return }
        // Assigning inside the observer does not re-enter it.
        expr.constant = 0
        lower -= k
        upper -= k
    }
}

extension LinearConstraint: CustomStringConvertible {
    public var description: String {
        let label = name.map { "\($0): " } ?? ""
        if lower == upper { return "\(label)\(expr) = \(upper)" }
        if lower == -.infinity { return "\(label)\(expr) <= \(upper)" }
        if upper == .infinity { return "\(label)\(expr) >= \(lower)" }
        return "\(label)\(lower) <= \(expr) <= \(upper)"
    }
}

// MARK: - Comparisons
//
// Three shapes per comparison, mirroring the arithmetic operators.
//
// One known sharp edge: when both operands of `==` have the same Hashable type (two variables,
// or two `LinearExpr`), an untyped `let c = a == b` resolves to `Equatable` and yields a
// `Bool`. Inside `subjectTo` the `LinearConstraint` context selects the right overload, and
// the result builder rejects a stray `Bool` at compile time; for untyped bindings use
// `.equal(to:)`.

@inlinable
public func <= <L: LinearExpressible, R: LinearExpressible>(_ l: L, _ r: R) -> LinearConstraint<L.Variable>
where R.Variable == L.Variable {
    var difference = l.linearExpr
    r._accumulate(into: &difference, scale: -1)
    return LinearConstraint(expr: difference, lower: -.infinity, upper: 0)
}

@inlinable
public func <= <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearConstraint<L.Variable> {
    LinearConstraint(expr: l.linearExpr, lower: -.infinity, upper: r)
}

@inlinable
public func <= <R: LinearExpressible>(_ l: Double, _ r: R) -> LinearConstraint<R.Variable> {
    LinearConstraint(expr: r.linearExpr, lower: l, upper: .infinity)
}

@inlinable
public func >= <L: LinearExpressible, R: LinearExpressible>(_ l: L, _ r: R) -> LinearConstraint<L.Variable>
where R.Variable == L.Variable {
    var difference = l.linearExpr
    r._accumulate(into: &difference, scale: -1)
    return LinearConstraint(expr: difference, lower: 0, upper: .infinity)
}

@inlinable
public func >= <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearConstraint<L.Variable> {
    LinearConstraint(expr: l.linearExpr, lower: r, upper: .infinity)
}

@inlinable
public func >= <R: LinearExpressible>(_ l: Double, _ r: R) -> LinearConstraint<R.Variable> {
    LinearConstraint(expr: r.linearExpr, lower: -.infinity, upper: l)
}

@inlinable
public func == <L: LinearExpressible, R: LinearExpressible>(_ l: L, _ r: R) -> LinearConstraint<L.Variable>
where R.Variable == L.Variable {
    var difference = l.linearExpr
    r._accumulate(into: &difference, scale: -1)
    return LinearConstraint(expr: difference, lower: 0, upper: 0)
}

@inlinable
public func == <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearConstraint<L.Variable> {
    LinearConstraint(expr: l.linearExpr, lower: r, upper: r)
}

@inlinable
public func == <R: LinearExpressible>(_ l: Double, _ r: R) -> LinearConstraint<R.Variable> {
    LinearConstraint(expr: r.linearExpr, lower: l, upper: l)
}

extension LinearExpressible {
    /// The range row `r.lowerBound ≤ self ≤ r.upperBound`.
    @inlinable
    public func within(_ r: ClosedRange<Double>) -> LinearConstraint<Variable> {
        LinearConstraint(expr: linearExpr, lower: r.lowerBound, upper: r.upperBound)
    }

    /// `self = rhs`, spelled out for bindings without a contextual type.
    @inlinable
    public func equal(to rhs: some LinearExpressible<Variable>) -> LinearConstraint<Variable> {
        var difference = linearExpr
        rhs._accumulate(into: &difference, scale: -1)
        return LinearConstraint(expr: difference, lower: 0, upper: 0)
    }

    /// `self = rhs`.
    @inlinable
    public func equal(to rhs: Double) -> LinearConstraint<Variable> {
        LinearConstraint(expr: linearExpr, lower: rhs, upper: rhs)
    }
}

// MARK: - Result builder

/// Collects constraints from a closure; accepts `for` loops, `if` / `else` and arrays.
@resultBuilder
public enum Constraints<V: LPVariable> {
    public static func buildExpression(_ c: LinearConstraint<V>) -> [LinearConstraint<V>] { [c] }

    public static func buildExpression(_ cs: [LinearConstraint<V>]) -> [LinearConstraint<V>] { cs }

    public static func buildBlock(_ parts: [LinearConstraint<V>]...) -> [LinearConstraint<V>] {
        if parts.count == 1 { return parts[0] }
        var all: [LinearConstraint<V>] = []
        all.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { all.append(contentsOf: part) }
        return all
    }

    /// Enables `for … in`.
    public static func buildArray(_ parts: [[LinearConstraint<V>]]) -> [LinearConstraint<V>] {
        var all: [LinearConstraint<V>] = []
        all.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { all.append(contentsOf: part) }
        return all
    }

    public static func buildOptional(_ part: [LinearConstraint<V>]?) -> [LinearConstraint<V>] {
        part ?? []
    }

    public static func buildEither(first: [LinearConstraint<V>]) -> [LinearConstraint<V>] { first }

    public static func buildEither(second: [LinearConstraint<V>]) -> [LinearConstraint<V>] { second }
}
