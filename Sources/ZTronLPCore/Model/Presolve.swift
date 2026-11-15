// Presolve-lite (specification §5.3).
//
// The presolve is deliberately small; each rule has a postsolve that restores primal and dual
// values. Rules run to a fixed point (at most 10 passes):
//
//   1. Fixed columns (xl == xu): substitute, move to c₀, remove.
//   2. Singleton rows: become a bound on the variable; the row's dual is reconstructed from
//      the reduced cost in postsolve.
//   3. Empty rows: check feasibility of the constant, remove.
//   4. Empty columns: fix at the bound that improves the objective.
//   5. Singleton constraints from the DSL are lowered to bounds by `compile()` itself.
//   6. Bound tightening on integer columns: round fractional bounds inward.
//
// Duplicate rows, dominated columns and doubleton equations are out of scope for v1.

/// The result of presolving a problem, and the means to map a solution of the reduced problem
/// back to the original one.
public struct Presolve: Sendable {
    /// What the presolve concluded.
    public enum Outcome: Sendable, Hashable {
        /// Solve `reduced`, then postsolve.
        case reduced
        /// Every row and column was removed; `expandPrimal([])` is an optimal solution.
        case solved
        /// The model has no feasible point; the string says why.
        case infeasible(String)
    }

    /// How much the presolve is allowed to do.
    public enum Mode: Sendable, Hashable {
        /// Nothing: the reduced problem is the original one.
        case off
        /// Tighten bounds (rules 2 and 6) but keep every row and column, so indices are
        /// unchanged. Branch and bound uses this: its node LPs, bases and bound changes all
        /// live in the original column space.
        case boundsOnly
        /// Every rule.
        case full
    }

    public let outcome: Outcome
    public let original: CompiledLP
    public let reduced: CompiledLP
    /// The original column of each reduced column.
    public let columnOrigin: [Int32]
    /// The original row of each reduced row.
    public let rowOrigin: [Int32]
    /// Set when an empty column can improve the objective without bound. The model is
    /// unbounded if the rest of it is feasible and infeasible otherwise, so the caller still
    /// solves `reduced` to tell the two apart; `direction` is the sign of the ray on that column.
    public let unboundedColumn: Int?
    public let unboundedDirection: Double

    private let steps: [Step]
    /// Value of every removed column, indexed by original column; 0 for kept columns.
    private let removedValue: [Double]

    public var removedRows: Int { original.m - reduced.m }
    public var removedColumns: Int { original.n - reduced.n }

    /// True when the reduced problem has the original's rows and columns.
    public var isIdentityMapping: Bool { steps.isEmpty }

    enum Step: Sendable {
        case fixedColumn(column: Int, value: Double)
        case emptyColumn(column: Int, value: Double, status: BasisStatus)
        case emptyRow(row: Int)
        case singletonRow(row: Int, column: Int, coefficient: Double, tightenedLower: Bool, tightenedUpper: Bool)
    }

    private init(
        outcome: Outcome, original: CompiledLP, reduced: CompiledLP, columnOrigin: [Int32],
        rowOrigin: [Int32], steps: [Step], removedValue: [Double], unboundedColumn: Int?,
        unboundedDirection: Double
    ) {
        self.outcome = outcome
        self.original = original
        self.reduced = reduced
        self.columnOrigin = columnOrigin
        self.rowOrigin = rowOrigin
        self.steps = steps
        self.removedValue = removedValue
        self.unboundedColumn = unboundedColumn
        self.unboundedDirection = unboundedDirection
    }

    /// The presolve that changes nothing.
    public static func identity(_ lp: CompiledLP) -> Presolve {
        Presolve(
            outcome: .reduced, original: lp, reduced: lp,
            columnOrigin: (0..<lp.n).map { Int32($0) }, rowOrigin: (0..<lp.m).map { Int32($0) },
            steps: [], removedValue: [Double](repeating: 0, count: lp.n), unboundedColumn: nil,
            unboundedDirection: 0)
    }

    // MARK: - Running the rules

    /// Presolves `lp`.
    public static func run(_ lp: CompiledLP, tolerances: Tolerances = .default, mode: Mode = .full) -> Presolve {
        if mode == .off { return identity(lp) }
        let n = lp.n
        let m = lp.m
        let a = lp.a
        let aT = lp.aT
        let feasibility = tolerances.primalFeasibility

        var xl = lp.xl
        var xu = lp.xu
        var rl = lp.rl
        var ru = lp.ru
        var c0 = lp.c0
        let isInteger = lp.integerMask()
        var columnActive = [Bool](repeating: true, count: n)
        var rowActive = [Bool](repeating: true, count: m)
        var rowCount = [Int](repeating: 0, count: m)
        var columnCount = [Int](repeating: 0, count: n)
        for j in 0..<n {
            columnCount[j] = a.colStart[j + 1] - a.colStart[j]
            for p in a.colStart[j]..<a.colStart[j + 1] { rowCount[Int(a.rowIndex[p])] += 1 }
        }
        // Magnitude moved into each row's bounds by substituted columns; scales the tolerance
        // of the empty-row feasibility check.
        var rowShift = [Double](repeating: 0, count: m)
        var steps: [Step] = []
        var removedValue = [Double](repeating: 0, count: n)
        var unboundedColumn: Int? = nil
        var unboundedDirection = 0.0
        let removing = mode == .full

        func failed(_ reason: String) -> Presolve {
            Presolve(
                outcome: .infeasible(reason), original: lp, reduced: lp,
                columnOrigin: (0..<n).map { Int32($0) }, rowOrigin: (0..<m).map { Int32($0) },
                steps: [], removedValue: [Double](repeating: 0, count: n), unboundedColumn: nil,
                unboundedDirection: 0)
        }

        /// Rule 6, plus the consistency check every column needs. Returns a reason on failure.
        func normalizeBounds(_ j: Int) -> String? {
            if isInteger[j] {
                if xl[j] > -.infinity {
                    let rounded = (xl[j] - 1e-9 * Swift.max(1, Swift.abs(xl[j]))).rounded(.up)
                    if rounded != xl[j] { xl[j] = rounded }
                }
                if xu[j] < .infinity {
                    let rounded = (xu[j] + 1e-9 * Swift.max(1, Swift.abs(xu[j]))).rounded(.down)
                    if rounded != xu[j] { xu[j] = rounded }
                }
            }
            if xl[j] > xu[j] {
                let gap = xl[j] - xu[j]
                if !isInteger[j] && gap <= feasibility * (1 + Swift.abs(xl[j])) {
                    // Bounds that cross by rounding noise describe a fixed column.
                    let middle = 0.5 * (xl[j] + xu[j])
                    xl[j] = middle
                    xu[j] = middle
                } else {
                    return "column \(lp.names.column(j)) has lower bound \(xl[j]) above upper bound \(xu[j])"
                }
            }
            return nil
        }

        var changed = true
        var pass = 0
        while changed && pass < 10 {
            changed = false
            pass += 1

            // Rules 6 and 1: integer rounding, then fixed columns.
            for j in 0..<n where columnActive[j] {
                let before = (xl[j], xu[j])
                if let reason = normalizeBounds(j) { return failed(reason) }
                if before != (xl[j], xu[j]) { changed = true }
                guard removing, xl[j] == xu[j] else { continue }
                let value = xl[j]
                for p in a.colStart[j]..<a.colStart[j + 1] {
                    let i = Int(a.rowIndex[p])
                    guard rowActive[i] else { continue }
                    let shift = a.values[p] * value
                    rl[i] -= shift
                    ru[i] -= shift
                    rowShift[i] += Swift.abs(shift)
                    rowCount[i] -= 1
                }
                c0 += lp.c[j] * value
                columnActive[j] = false
                removedValue[j] = value
                steps.append(.fixedColumn(column: j, value: value))
                changed = true
            }

            // Rules 3 and 2: empty rows, then singleton rows.
            for i in 0..<m where rowActive[i] {
                if rowCount[i] == 0 {
                    guard removing else { continue }
                    let tolerance = feasibility * (1 + rowShift[i])
                    if rl[i] > tolerance || ru[i] < -tolerance {
                        return failed("row \(lp.names.row(i)) has no variables left and requires \(rl[i]) <= 0 <= \(ru[i])")
                    }
                    rowActive[i] = false
                    steps.append(.emptyRow(row: i))
                    changed = true
                } else if rowCount[i] == 1 {
                    // Find the one active column of this row.
                    var column = -1
                    var coefficient = 0.0
                    for p in aT.colStart[i]..<aT.colStart[i + 1] where columnActive[Int(aT.rowIndex[p])] {
                        column = Int(aT.rowIndex[p])
                        coefficient = aT.values[p]
                        break
                    }
                    guard column >= 0, coefficient != 0 else { continue }
                    let impliedLower = coefficient > 0 ? rl[i] / coefficient : ru[i] / coefficient
                    let impliedUpper = coefficient > 0 ? ru[i] / coefficient : rl[i] / coefficient
                    let tightenedLower = impliedLower > xl[column]
                    let tightenedUpper = impliedUpper < xu[column]
                    if tightenedLower { xl[column] = impliedLower }
                    if tightenedUpper { xu[column] = impliedUpper }
                    if removing {
                        rowActive[i] = false
                        columnCount[column] -= 1
                        steps.append(
                            .singletonRow(
                                row: i, column: column, coefficient: coefficient,
                                tightenedLower: tightenedLower, tightenedUpper: tightenedUpper))
                        changed = true
                    } else if tightenedLower || tightenedUpper {
                        changed = true
                    }
                }
            }

            // Rule 4: empty columns.
            guard removing else { continue }
            for j in 0..<n where columnActive[j] && columnCount[j] == 0 {
                if let reason = normalizeBounds(j) { return failed(reason) }
                let cost = lp.c[j]
                var value: Double
                var status: BasisStatus
                if cost > 0 {
                    value = xl[j]
                    status = .atLower
                } else if cost < 0 {
                    value = xu[j]
                    status = .atUpper
                } else if xl[j] > -.infinity {
                    value = xl[j]
                    status = .atLower
                } else if xu[j] < .infinity {
                    value = xu[j]
                    status = .atUpper
                } else {
                    value = 0
                    status = .free
                }
                if value.isInfinite {
                    // A cost that improves forever. Whether the model is unbounded or
                    // infeasible depends on the rest of it, so record the column and park it
                    // at a finite value.
                    if unboundedColumn == nil {
                        unboundedColumn = j
                        unboundedDirection = cost > 0 ? -1 : 1
                    }
                    if cost > 0 {
                        value = xu[j] < .infinity ? xu[j] : 0
                        status = xu[j] < .infinity ? .atUpper : .free
                    } else {
                        value = xl[j] > -.infinity ? xl[j] : 0
                        status = xl[j] > -.infinity ? .atLower : .free
                    }
                }
                if xl[j] == xu[j] { status = .fixed }
                c0 += cost * value
                columnActive[j] = false
                removedValue[j] = value
                steps.append(.emptyColumn(column: j, value: value, status: status))
                changed = true
            }
        }

        for j in 0..<n where columnActive[j] {
            if let reason = normalizeBounds(j) { return failed(reason) }
        }

        // MARK: Assemble the reduced problem

        if !removing {
            let reduced = CompiledLP(
                a: a, c: lp.c, c0: lp.c0, sense: lp.sense, xl: xl, xu: xu, rl: rl, ru: ru,
                integerColumns: lp.integerColumns, names: lp.names, scaling: lp.scaling, transpose: aT)
            return Presolve(
                outcome: .reduced, original: lp, reduced: reduced,
                columnOrigin: (0..<n).map { Int32($0) }, rowOrigin: (0..<m).map { Int32($0) },
                steps: [], removedValue: removedValue, unboundedColumn: nil, unboundedDirection: 0)
        }

        var columnOrigin: [Int32] = []
        var rowOrigin: [Int32] = []
        var newRow = [Int32](repeating: -1, count: m)
        for i in 0..<m where rowActive[i] {
            newRow[i] = Int32(rowOrigin.count)
            rowOrigin.append(Int32(i))
        }
        for j in 0..<n where columnActive[j] { columnOrigin.append(Int32(j)) }
        let reducedN = columnOrigin.count
        let reducedM = rowOrigin.count

        var colStart = [Int](repeating: 0, count: reducedN + 1)
        var rowIndex: [Int32] = []
        var values: [Double] = []
        rowIndex.reserveCapacity(a.nnz)
        values.reserveCapacity(a.nnz)
        for (k, origin) in columnOrigin.enumerated() {
            let j = Int(origin)
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let i = Int(a.rowIndex[p])
                guard rowActive[i] else { continue }
                rowIndex.append(newRow[i])
                values.append(a.values[p])
            }
            colStart[k + 1] = values.count
        }
        let reducedA = SparseCSC(
            rows: Int32(reducedM), cols: Int32(reducedN), colStart: colStart, rowIndex: rowIndex,
            values: values)
        var integerColumns: [Int32] = []
        for (k, origin) in columnOrigin.enumerated() where isInteger[Int(origin)] {
            integerColumns.append(Int32(k))
        }
        let originalNames = lp.names
        let keptColumns = columnOrigin
        let keptRows = rowOrigin
        let names = LPNames(
            lazyColumns: {
                let all = originalNames.columns
                return keptColumns.map { all[Int($0)] }
            },
            lazyRows: {
                let all = originalNames.rows
                return keptRows.map { all[Int($0)] }
            })
        let reduced = CompiledLP(
            a: reducedA, c: columnOrigin.map { lp.c[Int($0)] }, c0: c0, sense: lp.sense,
            xl: columnOrigin.map { xl[Int($0)] }, xu: columnOrigin.map { xu[Int($0)] },
            rl: rowOrigin.map { rl[Int($0)] }, ru: rowOrigin.map { ru[Int($0)] },
            integerColumns: integerColumns, names: names, scaling: nil)
        return Presolve(
            outcome: reducedN == 0 && reducedM == 0 ? .solved : .reduced, original: lp, reduced: reduced,
            columnOrigin: columnOrigin, rowOrigin: rowOrigin, steps: steps, removedValue: removedValue,
            unboundedColumn: unboundedColumn, unboundedDirection: unboundedDirection)
    }

    // MARK: - Postsolve

    /// Maps a primal vector of the reduced problem to the original columns.
    public func expandPrimal(_ x: [Double]) -> [Double] {
        if isIdentityMapping { return x }
        var full = removedValue
        for (k, origin) in columnOrigin.enumerated() { full[Int(origin)] = x[k] }
        return full
    }

    /// Maps a primal ray of the reduced problem to the original columns; removed columns do
    /// not move.
    public func expandPrimalRay(_ ray: [Double]) -> [Double] {
        if isIdentityMapping { return ray }
        var full = [Double](repeating: 0, count: original.n)
        for (k, origin) in columnOrigin.enumerated() { full[Int(origin)] = ray[k] }
        return full
    }

    /// Restricts a primal vector of the original problem to the reduced columns.
    public func reducePrimal(_ x: [Double]) -> [Double] {
        if isIdentityMapping { return x }
        return columnOrigin.map { x[Int($0)] }
    }

    /// Maps row duals of the reduced problem (minimization form) to the original rows.
    ///
    /// Removed empty rows get a zero dual. A removed singleton row gets the reduced cost of
    /// its column when the bound it implied is the one the column rests on; the steps are
    /// undone in reverse, so of several rows that bound the same column the last and tightest
    /// claims the reduced cost and the others see none left.
    ///
    /// With `objective: false` the same reconstruction is applied to a dual ray, whose
    /// "reduced cost" is `−Aᵀy`: the ray's use of a tightened column bound is handed back to
    /// the row that created that bound.
    public func expandDual(_ y: [Double], objective: Bool = true) -> [Double] {
        if isIdentityMapping { return y }
        var full = [Double](repeating: 0, count: original.m)
        for (k, origin) in rowOrigin.enumerated() { full[Int(origin)] = y[k] }
        let a = original.a
        for step in steps.reversed() {
            guard case .singletonRow(let row, let column, let coefficient, let tightenedLower, let tightenedUpper) = step
            else { continue }
            var reducedCost = objective ? original.c[column] : 0
            for p in a.colStart[column]..<a.colStart[column + 1] {
                reducedCost -= a.values[p] * full[Int(a.rowIndex[p])]
            }
            if (tightenedLower && reducedCost > 0) || (tightenedUpper && reducedCost < 0) {
                full[row] = reducedCost / coefficient
            }
        }
        return full
    }

    /// Maps a basis of the reduced problem to a basis of the original one.
    public func expandBasis(_ basis: Basis) -> Basis {
        if isIdentityMapping { return basis }
        let n = original.n
        let m = original.m
        let reducedN = reduced.n
        var status = [BasisStatus](repeating: .basic, count: n + m)
        var placed = [Bool](repeating: false, count: n + m)
        for (k, origin) in columnOrigin.enumerated() {
            status[Int(origin)] = basis.status[k]
            placed[Int(origin)] = true
        }
        for (k, origin) in rowOrigin.enumerated() {
            status[n + Int(origin)] = basis.status[reducedN + k]
            placed[n + Int(origin)] = true
        }
        for step in steps.reversed() {
            switch step {
            case .fixedColumn(let column, _):
                status[column] = .fixed
            case .emptyColumn(let column, _, let columnStatus):
                status[column] = columnStatus
            case .emptyRow(let row):
                status[n + row] = .basic
            case .singletonRow(let row, let column, let coefficient, let tightenedLower, let tightenedUpper):
                // If the column rests on the bound this row created, the original problem has
                // no such bound: the column is basic there and the row's logical is the one
                // that is nonbasic.
                let current = status[column]
                var logical: BasisStatus? = nil
                if tightenedLower && (current == .atLower || current == .fixed) {
                    logical = coefficient > 0 ? .atLower : .atUpper
                } else if tightenedUpper && (current == .atUpper || current == .fixed) {
                    logical = coefficient > 0 ? .atUpper : .atLower
                }
                if let logical {
                    status[column] = .basic
                    status[n + row] = original.rl[row] == original.ru[row] ? .fixed : logical
                } else {
                    status[n + row] = .basic
                }
            }
        }
        // Kept basic columns first, in the reduced basis's row order, then the ones postsolve added.
        var basic: [Int32] = []
        basic.reserveCapacity(m)
        var listed = [Bool](repeating: false, count: n + m)
        for k in basis.basic {
            let index = Int(k) < reducedN ? Int(columnOrigin[Int(k)]) : n + Int(rowOrigin[Int(k) - reducedN])
            if status[index] == .basic && !listed[index] {
                listed[index] = true
                basic.append(Int32(index))
            }
        }
        for index in 0..<(n + m) where status[index] == .basic && !listed[index] {
            basic.append(Int32(index))
        }
        return Basis(status: status, basic: basic)
    }

    /// Maps a basis of the original problem to a starting basis of the reduced one.
    ///
    /// The result is a hint: it can have more or fewer than `reduced.m` basic columns when the
    /// two problems differ in which rows were removed, and the simplex engine repairs it.
    public func reduceBasis(_ basis: Basis) -> Basis {
        if isIdentityMapping { return basis }
        let n = original.n
        guard basis.status.count == n + original.m else { return .allLogical(for: reduced) }
        var status = basis.status
        for step in steps {
            guard case .singletonRow(let row, let column, let coefficient, _, _) = step else { continue }
            // The inverse of `expandBasis`: a column that was basic because the row's logical
            // was nonbasic rests, in the reduced problem, on the bound the row implies.
            let logical = status[n + row]
            guard logical != .basic, status[column] == .basic else { continue }
            switch logical {
            case .atLower: status[column] = coefficient > 0 ? .atLower : .atUpper
            case .atUpper: status[column] = coefficient > 0 ? .atUpper : .atLower
            default: status[column] = .atLower
            }
        }
        var reducedStatus: [BasisStatus] = []
        reducedStatus.reserveCapacity(reduced.n + reduced.m)
        for origin in columnOrigin { reducedStatus.append(status[Int(origin)]) }
        for origin in rowOrigin { reducedStatus.append(status[n + Int(origin)]) }
        var basic: [Int32] = []
        for (k, s) in reducedStatus.enumerated() where s == .basic { basic.append(Int32(k)) }
        return Basis(status: reducedStatus, basic: basic)
    }
}

extension CompiledLP {
    /// Reduced costs `d = c − Aᵀy` of the minimization form for the given row duals: `n`
    /// structural entries followed by the `m` logical ones, which equal `y` (§5.5).
    public func reducedCosts(forDuals y: [Double]) -> [Double] {
        var d = [Double](repeating: 0, count: n + m)
        for j in 0..<n {
            var value = c[j]
            for p in a.colStart[j]..<a.colStart[j + 1] {
                value -= a.values[p] * y[Int(a.rowIndex[p])]
            }
            d[j] = value
        }
        for i in 0..<m { d[n + i] = y[i] }
        return d
    }
}
