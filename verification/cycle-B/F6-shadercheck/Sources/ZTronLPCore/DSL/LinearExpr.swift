// Expressions (specification §4.3).
//
// Everything is generic over the variable type, so the library compiles without the user's
// enum and one module can hold any number of models. An expression is a canonical affine form:
// each variable appears at most once, no coefficient is zero, and insertion order is kept so
// that lowering is deterministic.

/// Anything that can be read as an affine expression over one variable family.
public protocol LinearExpressible<Variable>: Sendable {
    associatedtype Variable: LPVariable

    /// The value as an affine expression.
    var linearExpr: LinearExpr<Variable> { get }

    /// Customization point: adds `scale · self` to `expr`.
    ///
    /// The default implementation goes through `linearExpr`. A variable adds itself directly,
    /// so accumulating variables (in `sum`, `+=` and the operators) never builds a temporary
    /// expression per term.
    func _accumulate(into expr: inout LinearExpr<Variable>, scale: Double)
}

extension LinearExpressible {
    @inlinable
    public func _accumulate(into expr: inout LinearExpr<Variable>, scale: Double) {
        expr._addScaled(linearExpr, scale)
    }
}

/// An affine expression Σ cᵢ·vᵢ + k, canonical: each variable at most once, no zero
/// coefficients, insertion order preserved so lowering is deterministic.
///
/// Coefficients live in two parallel arrays plus an index dictionary; there is no per-term
/// object. The dictionary is only built once an expression outgrows a handful of terms, so
/// small expressions cost two array allocations.
public struct LinearExpr<V: LPVariable>: Sendable, LinearExpressible {
    @usableFromInline var _variables: [V]
    @usableFromInline var _coefficients: [Double]
    /// Position of each variable in `_variables`; `nil` while the expression is short enough
    /// for a linear scan to be faster than hashing.
    @usableFromInline var _index: [V: Int]?

    /// The constant term k.
    public var constant: Double

    /// Expressions longer than this keep a dictionary index.
    @usableFromInline static var _indexThreshold: Int { 8 }

    /// The variables, in order of first appearance.
    @inlinable public var variables: [V] { _variables }
    /// The coefficient of each entry of `variables`; never zero.
    @inlinable public var coefficients: [Double] { _coefficients }

    /// The expression `0`.
    @inlinable
    public init() {
        _variables = []
        _coefficients = []
        _index = nil
        constant = 0
    }

    /// A constant expression.
    @inlinable
    public init(_ constant: Double) {
        _variables = []
        _coefficients = []
        _index = nil
        self.constant = constant
    }

    /// `coefficient · v`.
    @inlinable
    public init(_ v: V, coefficient: Double = 1) {
        if coefficient == 0 {
            _variables = []
            _coefficients = []
        } else {
            _variables = [v]
            _coefficients = [coefficient]
        }
        _index = nil
        constant = 0
    }

    /// The coefficient of `v`; 0 when absent.
    @inlinable
    public subscript(v: V) -> Double {
        guard let i = _position(of: v) else { return 0 }
        return _coefficients[i]
    }

    /// True when the expression has no variable terms.
    @inlinable public var isConstant: Bool { _variables.isEmpty }

    /// The number of variable terms.
    @inlinable public var count: Int { _variables.count }

    @inlinable public var linearExpr: LinearExpr<V> { self }

    @inlinable
    public func _accumulate(into expr: inout LinearExpr<V>, scale: Double) {
        expr._addScaled(self, scale)
    }

    /// Adds `coefficient · v`, merging with an existing term; O(1) amortized.
    ///
    /// A term whose coefficient cancels to exactly zero is removed, which keeps the form
    /// canonical. Removal preserves the order of the remaining terms and is the one O(n)
    /// case.
    @inlinable
    public mutating func add(_ v: V, _ coefficient: Double) {
        if coefficient == 0 { return }
        if let i = _position(of: v) {
            let merged = _coefficients[i] + coefficient
            if merged == 0 {
                _remove(at: i)
            } else {
                _coefficients[i] = merged
            }
        } else {
            _append(v, coefficient)
        }
    }

    /// Adds `value` to the constant term.
    @inlinable
    public mutating func add(constant value: Double) {
        constant += value
    }

    /// Reserves room for `n` terms.
    @inlinable
    public mutating func reserveCapacity(_ n: Int) {
        _variables.reserveCapacity(n)
        _coefficients.reserveCapacity(n)
        if n > Self._indexThreshold {
            if _index == nil { _buildIndex() }
            _index!.reserveCapacity(n)
        }
    }

    public static func += (lhs: inout Self, rhs: some LinearExpressible<V>) {
        rhs._accumulate(into: &lhs, scale: 1)
    }

    public static func -= (lhs: inout Self, rhs: some LinearExpressible<V>) {
        rhs._accumulate(into: &lhs, scale: -1)
    }

    public static func += (lhs: inout Self, rhs: Double) {
        lhs.constant += rhs
    }

    public static func -= (lhs: inout Self, rhs: Double) {
        lhs.constant -= rhs
    }

    public static func *= (lhs: inout Self, rhs: Double) {
        if rhs == 0 {
            lhs = LinearExpr()
            return
        }
        lhs.constant *= rhs
        var underflowed = false
        for i in lhs._coefficients.indices {
            lhs._coefficients[i] *= rhs
            if lhs._coefficients[i] == 0 { underflowed = true }
        }
        // A product can underflow to zero; restore the "no zero coefficients" invariant.
        if underflowed { lhs._dropZeros() }
    }

    public static func /= (lhs: inout Self, rhs: Double) {
        lhs *= (1 / rhs)
    }

    /// The value of the expression at a point; variables the closure does not know are
    /// treated as whatever it returns for them.
    public func evaluated(_ value: (V) -> Double) -> Double {
        var total = constant
        for i in _variables.indices { total += _coefficients[i] * value(_variables[i]) }
        return total
    }

    // MARK: Internals

    @inlinable
    func _position(of v: V) -> Int? {
        if let index = _index { return index[v] }
        for i in _variables.indices where _variables[i] == v { return i }
        return nil
    }

    @inlinable
    mutating func _append(_ v: V, _ coefficient: Double) {
        let position = _variables.count
        _variables.append(v)
        _coefficients.append(coefficient)
        if _index != nil {
            _index![v] = position
        } else if position + 1 > Self._indexThreshold {
            _buildIndex()
        }
    }

    @usableFromInline
    mutating func _buildIndex() {
        var index = [V: Int](minimumCapacity: Swift.max(_variables.count * 2, 16))
        for (i, v) in _variables.enumerated() { index[v] = i }
        _index = index
    }

    @usableFromInline
    mutating func _remove(at position: Int) {
        let removed = _variables.remove(at: position)
        _coefficients.remove(at: position)
        if _index != nil {
            _index![removed] = nil
            for k in position..<_variables.count { _index![_variables[k]] = k }
        }
    }

    @usableFromInline
    mutating func _dropZeros() {
        var keptVariables: [V] = []
        var keptCoefficients: [Double] = []
        keptVariables.reserveCapacity(_variables.count)
        keptCoefficients.reserveCapacity(_variables.count)
        for i in _variables.indices where _coefficients[i] != 0 {
            keptVariables.append(_variables[i])
            keptCoefficients.append(_coefficients[i])
        }
        _variables = keptVariables
        _coefficients = keptCoefficients
        if _variables.count > Self._indexThreshold { _buildIndex() } else { _index = nil }
    }

    @inlinable
    mutating func _addScaled(_ other: LinearExpr<V>, _ scale: Double) {
        if scale == 0 { return }
        if _variables.isEmpty && scale == 1 {
            // Adopt the other expression's storage; no per-term work.
            let k = constant
            self = other
            constant += k
            return
        }
        constant += scale * other.constant
        for i in other._variables.indices {
            add(other._variables[i], scale * other._coefficients[i])
        }
    }
}

// Equality and hashing are order-insensitive: two expressions are equal when their coefficient
// maps and constants are equal (§4.3).
extension LinearExpr: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.constant == rhs.constant, lhs._variables.count == rhs._variables.count else {
            return false
        }
        for i in lhs._variables.indices {
            guard let j = rhs._position(of: lhs._variables[i]),
                  rhs._coefficients[j] == lhs._coefficients[i]
            else { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        // A commutative combination of the per-term hashes makes the result independent of
        // insertion order.
        var combined = 0
        for i in _variables.indices {
            var term = Hasher()
            term.combine(_variables[i])
            term.combine(_coefficients[i])
            combined = combined &+ term.finalize()
        }
        hasher.combine(constant)
        hasher.combine(_variables.count)
        hasher.combine(combined)
    }
}

extension LinearExpr: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        for i in _variables.indices {
            let c = _coefficients[i]
            let magnitude = Swift.abs(c)
            let term = magnitude == 1 ? _variables[i].name : "\(magnitude) \(_variables[i].name)"
            if parts.isEmpty {
                parts.append(c < 0 ? "- \(term)" : term)
            } else {
                parts.append(c < 0 ? "- \(term)" : "+ \(term)")
            }
        }
        if constant != 0 || parts.isEmpty {
            let magnitude = Swift.abs(constant)
            if parts.isEmpty {
                parts.append(constant < 0 ? "- \(magnitude)" : "\(magnitude)")
            } else {
                parts.append(constant < 0 ? "- \(magnitude)" : "+ \(magnitude)")
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Operators
//
// Exactly three overloads per binary operator: expression ∘ expression, expression ∘ Double
// and Double ∘ expression. Nonlinearity (term × term, division by an expression) has no
// overload and is a compile error. Integer literals resolve through the Double overload; an
// `Int` variable must be converted explicitly, which keeps the overload set small and the
// type checker fast.

@inlinable
public func + <L: LinearExpressible, R: LinearExpressible>(_ l: L, _ r: R) -> LinearExpr<L.Variable>
where R.Variable == L.Variable {
    var result = l.linearExpr
    r._accumulate(into: &result, scale: 1)
    return result
}

@inlinable
public func + <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearExpr<L.Variable> {
    var result = l.linearExpr
    result.constant += r
    return result
}

@inlinable
public func + <R: LinearExpressible>(_ l: Double, _ r: R) -> LinearExpr<R.Variable> {
    var result = r.linearExpr
    result.constant += l
    return result
}

@inlinable
public func - <L: LinearExpressible, R: LinearExpressible>(_ l: L, _ r: R) -> LinearExpr<L.Variable>
where R.Variable == L.Variable {
    var result = l.linearExpr
    r._accumulate(into: &result, scale: -1)
    return result
}

@inlinable
public func - <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearExpr<L.Variable> {
    var result = l.linearExpr
    result.constant -= r
    return result
}

@inlinable
public func - <R: LinearExpressible>(_ l: Double, _ r: R) -> LinearExpr<R.Variable> {
    var result = LinearExpr<R.Variable>(l)
    r._accumulate(into: &result, scale: -1)
    return result
}

@inlinable
public prefix func - <L: LinearExpressible>(_ l: L) -> LinearExpr<L.Variable> {
    var result = LinearExpr<L.Variable>()
    l._accumulate(into: &result, scale: -1)
    return result
}

@inlinable
public func * <L: LinearExpressible>(_ l: Double, _ r: L) -> LinearExpr<L.Variable> {
    var result = LinearExpr<L.Variable>()
    r._accumulate(into: &result, scale: l)
    return result
}

@inlinable
public func * <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearExpr<L.Variable> {
    var result = LinearExpr<L.Variable>()
    l._accumulate(into: &result, scale: r)
    return result
}

@inlinable
public func / <L: LinearExpressible>(_ l: L, _ r: Double) -> LinearExpr<L.Variable> {
    var result = LinearExpr<L.Variable>()
    l._accumulate(into: &result, scale: 1 / r)
    return result
}

// MARK: - Summation

/// Σ over any sequence, at any nesting depth, in linear time.
///
/// The result type is inferred bottom-up from the closure, so nested sums type-check without a
/// contextual type:
///
///     sum(over: plants) { p in
///         fixedCost[p] * Vars.open(p) + sum(over: markets) { m in cost[p, m] * Vars.ship(p, m) }
///     }
@inlinable
public func sum<S: Sequence, T: LinearExpressible>(
    over s: S, _ body: (S.Element) throws -> T
) rethrows -> LinearExpr<T.Variable> {
    var total = LinearExpr<T.Variable>()
    for element in s {
        try body(element)._accumulate(into: &total, scale: 1)
    }
    return total
}

extension LinearExpr {
    /// Static alias of the free function `sum(over:_:)`, kept for call sites that already have
    /// a contextual type (`let e: LinearExpr<Vars> = .sum(over: items) { … }`).
    @inlinable
    public static func sum<S: Sequence, T: LinearExpressible>(
        over s: S, _ body: (S.Element) throws -> T
    ) rethrows -> LinearExpr<V> where T.Variable == V {
        var total = LinearExpr<V>()
        for element in s {
            try body(element)._accumulate(into: &total, scale: 1)
        }
        return total
    }
}
