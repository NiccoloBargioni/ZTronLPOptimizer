// Variables (specification §4.2).
//
// A variable family is a type — normally an enum — and each value of the type is one decision
// variable. The enum synthesizes `Hashable` and `Sendable` when its associated values have
// them, and that is everything `LPVariable` asks for: a bare case (`case v`) is a complete
// variable and an indexed case becomes one when constructed (`Vars.x(3, 7)`).

/// Whether a variable takes real, integer or 0/1 values.
public enum VariableKind: Sendable, Hashable {
    case continuous, integer, binary
}

/// A closed interval `[lower, upper]`; either end may be infinite.
public struct Bounds: Sendable, Hashable {
    /// May be `-.infinity`.
    public var lower: Double
    /// May be `.infinity`.
    public var upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    /// `x ≥ 0`.
    public static let nonNegative = Bounds(lower: 0, upper: .infinity)
    /// `−∞ < x < ∞`.
    public static let free = Bounds(lower: -.infinity, upper: .infinity)
    /// `0 ≤ x ≤ 1`.
    public static let unit = Bounds(lower: 0, upper: 1)

    /// `x = value`.
    public static func fixed(_ value: Double) -> Bounds { Bounds(lower: value, upper: value) }
    /// `r.lowerBound ≤ x ≤ r.upperBound`.
    public static func range(_ r: ClosedRange<Double>) -> Bounds {
        Bounds(lower: r.lowerBound, upper: r.upperBound)
    }
    /// `x ≥ lower`.
    public static func atLeast(_ lower: Double) -> Bounds { Bounds(lower: lower, upper: .infinity) }
    /// `x ≤ upper`.
    public static func atMost(_ upper: Double) -> Bounds { Bounds(lower: -.infinity, upper: upper) }

    /// The intersection of two intervals; it may be empty (`lower > upper`).
    public func intersection(_ other: Bounds) -> Bounds {
        Bounds(lower: Swift.max(lower, other.lower), upper: Swift.min(upper, other.upper))
    }

    /// True when both ends are finite and equal.
    public var isFixed: Bool { lower == upper && lower.isFinite }
}

/// The kind and default bounds of a variable.
public struct VariableDomain: Sendable, Hashable {
    public var kind: VariableKind
    public var bounds: Bounds

    public init(kind: VariableKind, bounds: Bounds) {
        self.kind = kind
        self.bounds = bounds
    }

    /// Continuous, `x ≥ 0`.
    public static let continuous = VariableDomain(kind: .continuous, bounds: .nonNegative)
    /// Continuous and unbounded.
    public static let free = VariableDomain(kind: .continuous, bounds: .free)
    /// Integer, `x ≥ 0`.
    public static let integer = VariableDomain(kind: .integer, bounds: .nonNegative)
    /// 0/1.
    public static let binary = VariableDomain(kind: .binary, bounds: .unit)

    /// Continuous with the given bounds.
    public static func continuous(_ b: Bounds) -> VariableDomain {
        VariableDomain(kind: .continuous, bounds: b)
    }
    /// Integer with the given bounds.
    public static func integer(_ b: Bounds) -> VariableDomain {
        VariableDomain(kind: .integer, bounds: b)
    }
}

/// A variable family is a type; each value of the type is one decision variable.
public protocol LPVariable: Hashable, Sendable, LinearExpressible where Variable == Self {
    /// Domain used unless the model overrides it. Default implementation: `.continuous` (x ≥ 0).
    var domain: VariableDomain { get }
    /// Name for LP/MPS export and diagnostics. Default: derived from `String(describing: self)`,
    /// sanitized to `[A-Za-z0-9_.\[\],]` and made unique at compile time.
    var name: String { get }
}

extension LPVariable {
    public var domain: VariableDomain { .continuous }

    public var name: String { LPName.derived(fromDescription: String(describing: self)) }

    /// A variable is the expression `1·self`.
    @inlinable
    public var linearExpr: LinearExpr<Self> { LinearExpr(self) }

    /// Adds `scale·self` to an expression without building an intermediate expression.
    @inlinable
    public func _accumulate(into expr: inout LinearExpr<Self>, scale: Double) {
        expr.add(self, scale)
    }
}

/// Name sanitation shared by the DSL and the MPS/LP writers.
public enum LPName {
    /// The default name of a variable, from `String(describing:)` of its value.
    ///
    /// `String(describing:)` qualifies the types of associated values with their module
    /// (`ship(MyApp.Plant(id: 0))`). The qualifiers carry no information inside one model, so
    /// they are removed before sanitizing: the example becomes `ship[Plant[id_0]]`, and the
    /// plain indexed case `x(3, 7)` becomes `x[3,7]`.
    public static func derived(fromDescription description: String) -> String {
        sanitized(strippingQualifiers(description))
    }

    /// Reduces every qualified name to its last component, outside string literals:
    /// `App.Model.Plant(id: 0)` becomes `Plant(id: 0)` and `App.Color.red` becomes `red`.
    ///
    /// The runtime prints private types as `Module.(unknown context at $1082d6924).Type`.
    /// That segment is a qualifier as well, and it has to go: its address changes from one
    /// run to the next, and names must be deterministic.
    static func strippingQualifiers(_ text: String) -> String {
        guard text.contains(".") else { return text }
        let scalars = Array(text.unicodeScalars)
        func isIdentifierStart(_ s: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(s) || ("a"..."z").contains(s) || s == "_"
        }
        func isIdentifierBody(_ s: Unicode.Scalar) -> Bool {
            isIdentifierStart(s) || ("0"..."9").contains(s)
        }
        let unknownContext = Array("(unknown context at ".unicodeScalars)
        /// The index just past `(unknown context at $…)` when that segment starts at `i`.
        func endOfUnknownContext(at i: Int) -> Int? {
            guard i + unknownContext.count <= scalars.count else { return nil }
            for k in unknownContext.indices where scalars[i + k] != unknownContext[k] { return nil }
            var j = i + unknownContext.count
            while j < scalars.count, scalars[j] != ")" { j += 1 }
            return j < scalars.count ? j + 1 : nil
        }
        var out = String.UnicodeScalarView()
        var i = 0
        var inQuotes = false
        while i < scalars.count {
            let s = scalars[i]
            if s == "\"" {
                inQuotes.toggle()
                out.append(s)
                i += 1
                continue
            }
            let previousIsBody = i > 0 && (isIdentifierBody(scalars[i - 1]) || scalars[i - 1] == ".")
            if !inQuotes && isIdentifierStart(s) && !previousIsBody {
                // Walk the dotted chain and keep only its last component.
                var start = i
                var j = i
                while true {
                    while j < scalars.count, isIdentifierBody(scalars[j]) { j += 1 }
                    guard j + 1 < scalars.count, scalars[j] == "." else { break }
                    if isIdentifierStart(scalars[j + 1]) {
                        j += 1
                        start = j
                    } else if let past = endOfUnknownContext(at: j + 1), past + 1 < scalars.count,
                              scalars[past] == ".", isIdentifierStart(scalars[past + 1]) {
                        j = past + 1
                        start = j
                    } else {
                        break
                    }
                }
                out.append(contentsOf: scalars[start..<j])
                i = j
                continue
            }
            out.append(s)
            i += 1
        }
        return String(out)
    }

    /// Maps an arbitrary description to the alphabet `[A-Za-z0-9_.\[\],]`.
    ///
    /// Parentheses become brackets, so the case `x(3, 7)` is named `x[3,7]`; whitespace and
    /// quotes are dropped; every other character becomes an underscore. A name that would be
    /// empty, or would start with a character an LP file cannot start a name with, gets a
    /// leading underscore.
    public static func sanitized(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "[", "]", ",":
                out.append(scalar)
            case "(":
                out.append("[")
            case ")":
                out.append("]")
            case " ", "\t", "\n", "\r", "\"", "'":
                continue
            default:
                out.append("_")
            }
        }
        var result = String(out)
        if let first = result.unicodeScalars.first {
            switch first {
            case "A"..."Z", "a"..."z", "_":
                break
            default:
                result = "_" + result
            }
        } else {
            result = "_"
        }
        return result
    }

    /// Makes every name in the list distinct by appending `_2`, `_3`, … to later duplicates.
    /// The result depends only on the input order, so it is deterministic.
    public static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>(minimumCapacity: names.count)
        var nextSuffix: [String: Int] = [:]
        var result: [String] = []
        result.reserveCapacity(names.count)
        for name in names {
            if seen.insert(name).inserted {
                result.append(name)
                continue
            }
            var suffix = nextSuffix[name] ?? 2
            var candidate = "\(name)_\(suffix)"
            while !seen.insert(candidate).inserted {
                suffix += 1
                candidate = "\(name)_\(suffix)"
            }
            nextSuffix[name] = suffix + 1
            result.append(candidate)
        }
        return result
    }
}
