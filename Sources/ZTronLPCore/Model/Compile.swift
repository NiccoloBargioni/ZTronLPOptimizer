// Lowering (specification §5.1, §5.2 and rule 5 of §5.3).
//
// Column order is first appearance: objective terms first, then constraints in declaration
// order. Two compilations of the same model produce identical `CompiledLP` values, which the
// golden-file tests rely on.

/// Options of `LPModel.compile(options:)`.
public struct CompileOptions: Sendable {
    /// Lower a one-variable constraint to a bound instead of a row (§5.3, rule 5), so the DSL
    /// needs no separate bounding call for `subjectTo(x >= 3)`.
    public var lowerSingletonConstraints: Bool = true
    /// Coefficients smaller than this in magnitude are dropped with a warning.
    public var dropTolerance: Double = 1e-14
    /// Receives every warning the compilation produces (dropped coefficients). Errors are
    /// thrown as `SolverError.invalidModel`.
    public var diagnostics: (@Sendable (ModelDiagnostic) -> Void)? = nil

    public init() {}
}

/// A one-variable constraint waiting to be applied to its column's bounds.
private struct Singleton {
    let column: Int
    let coefficient: Double
    let lower: Double
    let upper: Double
}

extension LPModel {
    /// Lowers the model to the internal form.
    ///
    /// Throws `SolverError.invalidModel(ModelDiagnostic)` for: a non-finite coefficient or
    /// constant; a constraint with no variables whose bounds exclude its constant; lower >
    /// upper on a variable or row; a duplicate constraint name; an integer variable with a
    /// non-integral fixed bound; more than `Int32.max` rows, columns or nonzeros.
    public func compile(options: CompileOptions = .init()) throws -> CompiledModel<V> {
        var diagnostics: [ModelDiagnostic] = []
        func warn(_ kind: ModelDiagnostic.Kind) {
            let diagnostic = ModelDiagnostic.warning(kind)
            diagnostics.append(diagnostic)
            options.diagnostics?(diagnostic)
        }
        func invalid(_ kind: ModelDiagnostic.Kind) -> SolverError {
            .invalidModel(.error(kind))
        }

        // MARK: Columns, by first appearance

        var column: [V: Int] = [:]
        var variableAt: [V] = []
        column.reserveCapacity(objective.count)
        func columnIndex(_ v: V) -> Int {
            if let j = column[v] { return j }
            let j = variableAt.count
            column[v] = j
            variableAt.append(v)
            return j
        }

        // Objective terms come first.
        var cost: [Double] = []
        cost.reserveCapacity(objective.count)
        guard objective.constant.isFinite else {
            throw invalid(.nonFiniteValue(location: "the objective constant"))
        }
        for (v, coefficient) in zip(objective.variables, objective.coefficients) {
            guard coefficient.isFinite else {
                throw invalid(.nonFiniteCoefficient(variable: v.name, location: "the objective"))
            }
            let j = columnIndex(v)
            if Swift.abs(coefficient) < options.dropTolerance {
                warn(.droppedSmallCoefficient(variable: v.name, location: "the objective", value: coefficient))
                continue
            }
            if j >= cost.count { cost.append(contentsOf: repeatElement(0, count: j - cost.count + 1)) }
            cost[j] = coefficient
        }

        // MARK: Rows, in declaration order

        // Row-major scratch storage; converted to column-major below.
        var rowStart: [Int] = [0]
        var entryColumn: [Int32] = []
        var entryValue: [Double] = []
        var rowLower: [Double] = []
        var rowUpper: [Double] = []
        var rowNames: [String?] = []
        var rowNamed: [String: Int] = [:]
        var usedNames = Set<String>()
        var lowered: [String: LoweredConstraint] = [:]

        // One-variable constraints, applied to the bounds once every column is known.
        var singletons: [Singleton] = []

        var scratchColumns: [Int32] = []
        var scratchValues: [Double] = []

        for (index, constraint) in constraints.enumerated() {
            let location = constraint.name.map { "constraint \($0)" } ?? "constraint #\(index + 1)"
            if let name = constraint.name, !usedNames.insert(name).inserted {
                throw invalid(.duplicateConstraintName(name))
            }
            // A setter cannot leave a constant behind, but fold defensively anyway.
            let shift = constraint.expr.constant
            let lower = constraint.lower - shift
            let upper = constraint.upper - shift
            guard !lower.isNaN, !upper.isNaN, lower < .infinity, upper > -.infinity else {
                throw invalid(.nonFiniteValue(location: "a bound of \(location)"))
            }

            scratchColumns.removeAll(keepingCapacity: true)
            scratchValues.removeAll(keepingCapacity: true)
            for (v, coefficient) in zip(constraint.expr.variables, constraint.expr.coefficients) {
                guard coefficient.isFinite else {
                    throw invalid(.nonFiniteCoefficient(variable: v.name, location: location))
                }
                let j = columnIndex(v)
                if Swift.abs(coefficient) < options.dropTolerance {
                    warn(.droppedSmallCoefficient(variable: v.name, location: location, value: coefficient))
                    continue
                }
                scratchColumns.append(Int32(truncatingIfNeeded: j))
                scratchValues.append(coefficient)
            }

            if scratchColumns.isEmpty {
                // 0 must lie within [lower, upper]; `0 ≤ −1` is infeasible at compile time.
                if lower > 1e-9 || upper < -1e-9 {
                    throw invalid(.infeasibleConstantConstraint(name: constraint.name, index: index + 1))
                }
                if let name = constraint.name {
                    lowered[name] = LoweredConstraint(column: -1, coefficient: 0, lower: lower, upper: upper)
                }
                continue
            }
            guard lower <= upper else {
                throw invalid(.inconsistentRowBounds(row: constraint.name ?? "#\(index + 1)", lower: lower, upper: upper))
            }

            if scratchColumns.count == 1 && options.lowerSingletonConstraints {
                let j = Int(scratchColumns[0])
                singletons.append(Singleton(column: j, coefficient: scratchValues[0], lower: lower, upper: upper))
                if let name = constraint.name {
                    lowered[name] = LoweredConstraint(
                        column: j, coefficient: scratchValues[0], lower: lower, upper: upper)
                }
                continue
            }

            // Canonical row: ascending column index, which makes the CSR view sorted too.
            if scratchColumns.count > 1 {
                let order = scratchColumns.indices.sorted { scratchColumns[$0] < scratchColumns[$1] }
                for k in order {
                    entryColumn.append(scratchColumns[k])
                    entryValue.append(scratchValues[k])
                }
            } else {
                entryColumn.append(scratchColumns[0])
                entryValue.append(scratchValues[0])
            }
            if let name = constraint.name { rowNamed[name] = rowLower.count }
            rowNames.append(constraint.name)
            rowLower.append(lower)
            rowUpper.append(upper)
            rowStart.append(entryValue.count)
        }

        // MARK: Variables that only carry an override

        // They belong to the model even though no objective or constraint mentions them. A
        // dictionary has no stable order, so they are appended sorted by name.
        var extras: [V] = []
        for v in boundOverrides.keys where column[v] == nil { extras.append(v) }
        for v in kindOverrides.keys where column[v] == nil && boundOverrides[v] == nil { extras.append(v) }
        if !extras.isEmpty {
            extras.sort { lhs, rhs in
                let (a, b) = (lhs.name, rhs.name)
                return a != b ? a < b : String(reflecting: lhs) < String(reflecting: rhs)
            }
            for v in extras { _ = columnIndex(v) }
        }

        let n = variableAt.count
        let m = rowLower.count
        let nnz = entryValue.count
        guard n <= Int(Int32.max) else { throw invalid(.sizeLimitExceeded(what: "columns", count: n)) }
        guard m <= Int(Int32.max) else { throw invalid(.sizeLimitExceeded(what: "rows", count: m)) }
        guard nnz <= Int(Int32.max) else { throw invalid(.sizeLimitExceeded(what: "nonzeros", count: nnz)) }
        if cost.count < n { cost.append(contentsOf: repeatElement(0, count: n - cost.count)) }

        // MARK: Domains

        var xl = [Double](repeating: 0, count: n)
        var xu = [Double](repeating: 0, count: n)
        var integerColumns: [Int32] = []
        for (j, v) in variableAt.enumerated() {
            let domain = v.domain
            let kind = kindOverrides[v] ?? domain.kind
            var bounds = boundOverrides[v] ?? domain.bounds
            if kind == .binary { bounds = bounds.intersection(.unit) }
            guard !bounds.lower.isNaN, !bounds.upper.isNaN else {
                throw invalid(.nonFiniteValue(location: "a bound of variable \(v.name)"))
            }
            xl[j] = bounds.lower
            xu[j] = bounds.upper
            if kind != .continuous { integerColumns.append(Int32(j)) }
        }

        // One-variable constraints tighten the bounds, in declaration order.
        for singleton in singletons {
            let a = singleton.coefficient
            let impliedLower = a > 0 ? singleton.lower / a : singleton.upper / a
            let impliedUpper = a > 0 ? singleton.upper / a : singleton.lower / a
            let j = singleton.column
            if impliedLower > xl[j] { xl[j] = impliedLower }
            if impliedUpper < xu[j] { xu[j] = impliedUpper }
        }

        var isInteger = [Bool](repeating: false, count: n)
        for j in integerColumns { isInteger[Int(j)] = true }
        for j in 0..<n {
            guard xl[j] < .infinity, xu[j] > -.infinity else {
                throw invalid(.nonFiniteValue(location: "a bound of variable \(variableAt[j].name)"))
            }
            guard xl[j] <= xu[j] else {
                throw invalid(.inconsistentVariableBounds(variable: variableAt[j].name, lower: xl[j], upper: xu[j]))
            }
            if isInteger[j], xl[j] == xu[j], xl[j].rounded() != xl[j] {
                throw invalid(.nonIntegralFixedBound(variable: variableAt[j].name, value: xl[j]))
            }
        }

        // MARK: Column-major matrix

        var colStart = [Int](repeating: 0, count: n + 1)
        for j in entryColumn { colStart[Int(j) + 1] += 1 }
        for j in 0..<n { colStart[j + 1] += colStart[j] }
        var next = colStart
        var rowIndex = [Int32](repeating: 0, count: nnz)
        var values = [Double](repeating: 0, count: nnz)
        for i in 0..<m {
            for p in rowStart[i]..<rowStart[i + 1] {
                let j = Int(entryColumn[p])
                let q = next[j]
                next[j] += 1
                rowIndex[q] = Int32(i)   // rows are visited in ascending order: sorted within a column
                values[q] = entryValue[p]
            }
        }
        let a = SparseCSC(rows: Int32(m), cols: Int32(n), colStart: colStart, rowIndex: rowIndex, values: values)
        // The row-major scratch arrays already are the CSR view.
        let aT = SparseCSC(rows: Int32(n), cols: Int32(m), colStart: rowStart, rowIndex: entryColumn, values: entryValue)

        // MARK: Objective in minimization form

        let flip = sense == .maximize
        let c = flip ? cost.map { $0 == 0 ? 0 : -$0 } : cost
        let c0 = flip ? (objective.constant == 0 ? 0 : -objective.constant) : objective.constant

        // MARK: Names, materialized lazily

        let variables = variableAt
        let explicitRowNames = rowNames
        let names = LPNames(
            lazyColumns: { LPName.uniqued(variables.map(\.name)) },
            lazyRows: {
                // Explicit names are kept verbatim (they are already distinct); unnamed rows
                // get `c<k>`, with a suffix in the unlikely case that collides.
                var taken = Set(explicitRowNames.compactMap { $0 })
                return explicitRowNames.enumerated().map { i, explicit in
                    if let explicit { return explicit }
                    var candidate = "c\(i + 1)"
                    var suffix = 2
                    while !taken.insert(candidate).inserted {
                        candidate = "c\(i + 1)_\(suffix)"
                        suffix += 1
                    }
                    return candidate
                }
            })

        let lp = CompiledLP(
            a: a, c: c, c0: c0, sense: sense, xl: xl, xu: xu, rl: rowLower, ru: rowUpper,
            integerColumns: integerColumns, names: names, scaling: nil, transpose: aT)
        return CompiledModel(
            lp: lp, column: column, variableAt: variableAt, rowNamed: rowNamed, lowered: lowered,
            diagnostics: diagnostics)
    }
}
