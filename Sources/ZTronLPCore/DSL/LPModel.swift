// Model (specification §4.5).

/// Whether the objective is minimized or maximized.
public enum ObjectiveSense: Sendable, Hashable {
    case minimize, maximize
}

/// A linear or mixed-integer linear program over the variable family `V`.
///
/// The model is a plain value: `Sendable` whenever `V` is, so it crosses actor boundaries
/// without copying. The chaining methods return a modified copy and each has a mutating twin
/// (`add`, `setBounds`, `setKind`, `setObjective`).
public struct LPModel<V: LPVariable>: Sendable {
    public var objective: LinearExpr<V>
    public var sense: ObjectiveSense
    public var constraints: [LinearConstraint<V>]
    /// Bounds that replace a variable's `domain.bounds` in this model.
    public var boundOverrides: [V: Bounds]
    /// Kinds that replace a variable's `domain.kind` in this model.
    public var kindOverrides: [V: VariableKind]

    /// An empty minimization model.
    public init() {
        objective = LinearExpr()
        sense = .minimize
        constraints = []
        boundOverrides = [:]
        kindOverrides = [:]
    }

    // MARK: Objective

    /// A copy that minimizes `e`.
    public consuming func minimizing(_ e: some LinearExpressible<V>) -> Self {
        var copy = self
        copy.setObjective(.minimize, e)
        return copy
    }

    /// A copy that maximizes `e`.
    public consuming func maximizing(_ e: some LinearExpressible<V>) -> Self {
        var copy = self
        copy.setObjective(.maximize, e)
        return copy
    }

    /// Replaces the objective.
    public mutating func setObjective(_ sense: ObjectiveSense, _ e: some LinearExpressible<V>) {
        self.sense = sense
        objective = e.linearExpr
    }

    // MARK: Constraints

    /// A copy with one more constraint.
    public consuming func subjectTo(_ c: LinearConstraint<V>) -> Self {
        var copy = self
        copy.add(c)
        return copy
    }

    /// A copy with the constraints the builder closure produces; the closure accepts `for`
    /// loops, `if` / `else` and `.named(_:)`.
    public consuming func subjectTo(@Constraints<V> _ body: () -> [LinearConstraint<V>]) -> Self {
        var copy = self
        copy.constraints.append(contentsOf: body())
        return copy
    }

    /// A copy with one constraint per element of `s` — an indexed constraint family.
    public consuming func subjectTo<S: Sequence>(
        forEach s: S, name: ((S.Element) -> String)? = nil,
        _ body: (S.Element) -> LinearConstraint<V>
    ) -> Self {
        var copy = self
        copy.add(forEach: s, name: name, body)
        return copy
    }

    /// Appends one constraint.
    public mutating func add(_ c: LinearConstraint<V>) {
        constraints.append(c)
    }

    /// Appends the constraints the builder closure produces.
    public mutating func add(@Constraints<V> _ body: () -> [LinearConstraint<V>]) {
        constraints.append(contentsOf: body())
    }

    /// Appends one constraint per element of `s`.
    public mutating func add<S: Sequence>(
        forEach s: S, name: ((S.Element) -> String)? = nil,
        _ body: (S.Element) -> LinearConstraint<V>
    ) {
        constraints.reserveCapacity(constraints.count + s.underestimatedCount)
        for element in s {
            var c = body(element)
            if let name { c.name = name(element) }
            constraints.append(c)
        }
    }

    // MARK: Bounds

    /// A copy in which `v` has bounds `b`.
    public consuming func bounding(_ v: V, _ b: Bounds) -> Self {
        var copy = self
        copy.setBounds(v, b)
        return copy
    }

    /// A copy in which every variable `v(element)` has bounds `b`.
    public consuming func bounding<S: Sequence>(forEach s: S, _ v: (S.Element) -> V, _ b: Bounds) -> Self {
        var copy = self
        for element in s { copy.boundOverrides[v(element)] = b }
        return copy
    }

    /// Two-index form; a case constructor passes directly:
    /// `.bounding(forEach: 0..<r, 0..<c, Vars.x, .nonNegative)`.
    public consuming func bounding<A: Sequence, B: Sequence>(
        forEach a: A, _ b: B, _ v: (A.Element, B.Element) -> V, _ bounds: Bounds
    ) -> Self {
        var copy = self
        for first in a {
            for second in b { copy.boundOverrides[v(first, second)] = bounds }
        }
        return copy
    }

    /// Three-index form.
    public consuming func bounding<A: Sequence, B: Sequence, C: Sequence>(
        forEach a: A, _ b: B, _ c: C, _ v: (A.Element, B.Element, C.Element) -> V, _ bounds: Bounds
    ) -> Self {
        var copy = self
        for first in a {
            for second in b {
                for third in c { copy.boundOverrides[v(first, second, third)] = bounds }
            }
        }
        return copy
    }

    /// Sets the bounds of `v` in this model.
    public mutating func setBounds(_ v: V, _ b: Bounds) {
        boundOverrides[v] = b
    }

    // MARK: Integrality

    /// A copy in which `v` is integer.
    public consuming func integer(_ v: V) -> Self {
        var copy = self
        copy.kindOverrides[v] = .integer
        return copy
    }

    /// A copy in which `v` is binary (integer, intersected with `[0, 1]`).
    public consuming func binary(_ v: V) -> Self {
        var copy = self
        copy.kindOverrides[v] = .binary
        return copy
    }

    /// A copy in which `v` is continuous.
    public consuming func continuous(_ v: V) -> Self {
        var copy = self
        copy.kindOverrides[v] = .continuous
        return copy
    }

    /// A copy in which every variable `v(element)` is integer.
    public consuming func integer<S: Sequence>(forEach s: S, _ v: (S.Element) -> V) -> Self {
        var copy = self
        for element in s { copy.kindOverrides[v(element)] = .integer }
        return copy
    }

    /// A copy in which every variable `v(element)` is binary.
    public consuming func binary<S: Sequence>(forEach s: S, _ v: (S.Element) -> V) -> Self {
        var copy = self
        for element in s { copy.kindOverrides[v(element)] = .binary }
        return copy
    }

    /// A copy in which every variable `v(element)` is continuous.
    public consuming func continuous<S: Sequence>(forEach s: S, _ v: (S.Element) -> V) -> Self {
        var copy = self
        for element in s { copy.kindOverrides[v(element)] = .continuous }
        return copy
    }

    /// Sets the kind of `v` in this model.
    public mutating func setKind(_ v: V, _ kind: VariableKind) {
        kindOverrides[v] = kind
    }

    // MARK: Export

    /// The model in CPLEX LP format.
    public func lpString() throws -> String {
        try LPFormat.write(compile().lp)
    }

    /// The model in MPS format; free format by default, fixed columns otherwise.
    public func mpsString(free: Bool = true) throws -> String {
        MPSFormat.write(try compile().lp, free: free)
    }
}
