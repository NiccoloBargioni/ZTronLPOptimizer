// Compiled model (specification §5).
//
// `compile()` turns an `LPModel<V>` into an immutable `CompiledLP` that every engine consumes;
// the DSL types never reach an engine. The internal form is
//
//     min cᵀx + c₀   s.t.   r_l ≤ Ax ≤ r_u,   x_l ≤ x ≤ x_u,   x_j ∈ ℤ (j ∈ I)
//
// with maximization stored as minimization of −c and the sense remembered for reporting.

import Atomics

/// Row and column scale factors (§5.4). `A' = diag(rows)·A·diag(columns)`.
///
/// Every factor is a power of two, so scaling and unscaling introduce no rounding error.
public struct Scaling: Sendable, Hashable {
    public let rows: [Double]
    public let columns: [Double]

    public init(rows: [Double], columns: [Double]) {
        self.rows = rows
        self.columns = columns
    }

    /// True when every factor is exactly 1.
    public var isIdentity: Bool {
        rows.allSatisfy { $0 == 1 } && columns.allSatisfy { $0 == 1 }
    }
}

/// Column and row names, materialized lazily.
///
/// A model compiled from the DSL derives its names from `String(describing:)`, which is far
/// too slow to run for every variable of a large model that nobody exports. The names are
/// therefore produced on first use, once, and cached lock-free.
public struct LPNames: Sendable {
    private let storage: Storage

    /// Names known up front (MPS/LP readers).
    public init(columns: [String], rows: [String]) {
        let table = Table(columns: columns, rows: rows)
        storage = Storage { table }
    }

    /// Names computed on first use. Both closures must be deterministic.
    public init(
        lazyColumns: @escaping @Sendable () -> [String], lazyRows: @escaping @Sendable () -> [String]
    ) {
        storage = Storage { Table(columns: lazyColumns(), rows: lazyRows()) }
    }

    /// Default names `x1 … xn` and `c1 … cm`.
    public static func `default`(columns n: Int, rows m: Int) -> LPNames {
        LPNames(
            lazyColumns: { (0..<n).map { "x\($0 + 1)" } },
            lazyRows: { (0..<m).map { "c\($0 + 1)" } })
    }

    public var columns: [String] { storage.table.columns }
    public var rows: [String] { storage.table.rows }

    public func column(_ j: Int) -> String { storage.table.columns[j] }
    public func row(_ i: Int) -> String { storage.table.rows[i] }

    private final class Table: Sendable {
        let columns: [String]
        let rows: [String]
        init(columns: [String], rows: [String]) {
            self.columns = columns
            self.rows = rows
        }
    }

    private final class Storage: Sendable {
        let make: @Sendable () -> Table
        let cache = ManagedAtomicLazyReference<Table>()

        init(make: @escaping @Sendable () -> Table) {
            self.make = make
        }

        var table: Table {
            if let existing = cache.load() { return existing }
            // Two racing first readers may both build the table; one wins, both see the winner.
            return cache.storeIfNilThenLoad(make())
        }
    }
}

extension LPNames: Equatable {
    public static func == (lhs: LPNames, rhs: LPNames) -> Bool {
        lhs.storage === rhs.storage || (lhs.columns == rhs.columns && lhs.rows == rhs.rows)
    }
}

/// An immutable linear or mixed-integer linear program in the internal form.
public struct CompiledLP: Sendable, Equatable {
    /// Rows.
    public let m: Int
    /// Structural columns.
    public let n: Int
    /// `m × n`, column-major (simplex pricing, FTRAN gathers).
    public let a: SparseCSC
    /// `n × m`: the CSR view of A, built once (dual pivot rows, IPM AΘAᵀ).
    public let aT: SparseCSC
    /// Objective coefficients of the minimization form (negated for a maximization model).
    public let c: [Double]
    /// Objective constant of the minimization form.
    public let c0: Double
    /// The sense the model was written in; reported values use it.
    public let sense: ObjectiveSense
    public let xl: [Double]
    public let xu: [Double]
    public let rl: [Double]
    public let ru: [Double]
    /// Sorted indices of the integer columns.
    public let integerColumns: [Int32]
    /// Column and row names, materialized lazily.
    public let names: LPNames
    /// The scale factors applied to this problem, when it is the scaled working copy of
    /// another one (§5.4); `nil` for a problem as compiled or read.
    public let scaling: Scaling?

    public init(
        a: SparseCSC, c: [Double], c0: Double = 0, sense: ObjectiveSense = .minimize,
        xl: [Double], xu: [Double], rl: [Double], ru: [Double], integerColumns: [Int32] = [],
        names: LPNames? = nil, scaling: Scaling? = nil, transpose: SparseCSC? = nil
    ) {
        let m = Int(a.rows)
        let n = Int(a.cols)
        precondition(c.count == n && xl.count == n && xu.count == n, "column data must have n entries")
        precondition(rl.count == m && ru.count == m, "row data must have m entries")
        self.m = m
        self.n = n
        self.a = a
        self.aT = transpose ?? a.transposed()
        self.c = c
        self.c0 = c0
        self.sense = sense
        self.xl = xl
        self.xu = xu
        self.rl = rl
        self.ru = ru
        self.integerColumns = integerColumns
        self.names = names ?? .default(columns: n, rows: m)
        self.scaling = scaling
    }

    /// Stored entries of A.
    public var nnz: Int { a.nnz }

    /// True when at least one column is integer.
    public var hasIntegerColumns: Bool { !integerColumns.isEmpty }

    /// One flag per column: true for integer columns.
    public func integerMask() -> [Bool] {
        var mask = [Bool](repeating: false, count: n)
        for j in integerColumns { mask[Int(j)] = true }
        return mask
    }

    /// Converts a value of the internal minimization objective to the model's own sense.
    public func reportedObjective(_ internalValue: Double) -> Double {
        sense == .maximize ? -internalValue : internalValue
    }

    /// The internal (minimization) objective `cᵀx + c₀` at a point.
    public func internalObjective(at x: [Double]) -> Double {
        var total = c0
        for j in 0..<n { total += c[j] * x[j] }
        return total
    }

    /// The objective in the model's own sense at a point.
    public func objective(at x: [Double]) -> Double {
        reportedObjective(internalObjective(at: x))
    }

    /// Row activities `A·x`.
    public func rowActivity(_ x: [Double]) -> [Double] {
        a.multiply(x)
    }

    /// The largest violation of a column bound and of a row bound at `x`, both ≥ 0.
    public func maxViolation(at x: [Double]) -> (bounds: Double, rows: Double) {
        var boundViolation = 0.0
        for j in 0..<n {
            boundViolation = Swift.max(boundViolation, xl[j] - x[j], x[j] - xu[j])
        }
        var rowViolation = 0.0
        let activity = rowActivity(x)
        for i in 0..<m {
            rowViolation = Swift.max(rowViolation, rl[i] - activity[i], activity[i] - ru[i])
        }
        return (boundViolation, rowViolation)
    }

    /// A copy with different column bounds.
    public func withColumnBounds(xl: [Double], xu: [Double]) -> CompiledLP {
        CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru,
            integerColumns: integerColumns, names: names, scaling: scaling, transpose: aT)
    }

    /// A copy with different row bounds.
    public func withRowBounds(rl: [Double], ru: [Double]) -> CompiledLP {
        CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru,
            integerColumns: integerColumns, names: names, scaling: scaling, transpose: aT)
    }

    /// A copy with a different objective, given in the model's own sense.
    public func withObjective(_ coefficients: [Double], constant: Double = 0) -> CompiledLP {
        let flip = sense == .maximize
        return CompiledLP(
            a: a, c: flip ? coefficients.map { $0 == 0 ? 0 : -$0 } : coefficients,
            c0: flip ? (constant == 0 ? 0 : -constant) : constant, sense: sense, xl: xl, xu: xu,
            rl: rl, ru: ru, integerColumns: integerColumns, names: names, scaling: scaling,
            transpose: aT)
    }

    /// The LP relaxation: the same problem with no integer columns.
    public func relaxed() -> CompiledLP {
        CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: [],
            names: names, scaling: scaling, transpose: aT)
    }

    /// A copy with the given bound changes applied (`lower` / `upper` replace the bounds of
    /// each named column).
    public func applying(_ changes: [BoundChange]) -> CompiledLP {
        if changes.isEmpty { return self }
        var lower = xl
        var upper = xu
        for change in changes {
            lower[Int(change.column)] = change.lower
            upper[Int(change.column)] = change.upper
        }
        return withColumnBounds(xl: lower, xu: upper)
    }
}

/// The result of compiling an `LPModel<V>`: the problem plus the maps between variables and
/// columns.
public struct CompiledModel<V: LPVariable>: Sendable {
    public let lp: CompiledLP
    /// Column index of each variable.
    public let column: [V: Int]
    /// The variable of each column.
    public let variableAt: [V]
    /// Row index of each named constraint that became a row.
    public let rowNamed: [String: Int]
    /// Named one-variable constraints that were lowered to bounds instead of rows (§5.3).
    public let lowered: [String: LoweredConstraint]
    /// Warnings produced by the compilation (dropped coefficients, …).
    public let diagnostics: [ModelDiagnostic]

    public init(
        lp: CompiledLP, column: [V: Int], variableAt: [V], rowNamed: [String: Int],
        lowered: [String: LoweredConstraint] = [:], diagnostics: [ModelDiagnostic] = []
    ) {
        self.lp = lp
        self.column = column
        self.variableAt = variableAt
        self.rowNamed = rowNamed
        self.lowered = lowered
        self.diagnostics = diagnostics
    }
}

/// A one-variable constraint `lower ≤ coefficient·x ≤ upper` that compilation turned into a
/// bound on `x`.
public struct LoweredConstraint: Sendable, Hashable {
    /// The column of `x`; −1 for a constraint with no variables at all.
    public let column: Int
    public let coefficient: Double
    public let lower: Double
    public let upper: Double

    public init(column: Int, coefficient: Double, lower: Double, upper: Double) {
        self.column = column
        self.coefficient = coefficient
        self.lower = lower
        self.upper = upper
    }
}
