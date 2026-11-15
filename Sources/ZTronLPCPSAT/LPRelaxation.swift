// The LP propagator (`CPSAT(lpPropagator: true)`, the default; the hook of specification §10.4).
//
// Bounds propagation looks at one row at a time. It cannot see that a budget which pays for
// each row separately does not pay for all of them together; the linear relaxation can. An LP
// worker therefore solves the relaxation of the model over its current domains — with the
// dual simplex engine, warm-started from the previous node's basis — whenever ordinary
// propagation has reached a fixed point, and uses what the relaxation proves:
//
//   * a conflict, when the relaxation is infeasible or its optimum is worse than the
//     incumbent allows;
//   * tighter bounds, when a variable cannot move without the optimum becoming worse than
//     the incumbent allows (reduced-cost fixing);
//   * a solution, when the optimum of the relaxation happens to be integral;
//   * a branching variable, when it is not: one whose value in the relaxation is fractional.
//
// Soundness does not rest on floating point. The simplex engine only proposes multipliers —
// its row duals, or the Farkas ray of an infeasible relaxation. They are rounded to integers
// and the corresponding combination of the model's rows (and of `objective ≤ incumbent − 1`)
// is formed in exact Int64 arithmetic. Any non-negative integer combination of valid rows is
// a valid row, whatever the multipliers are, so the worst a wrong or badly rounded dual can do
// is to produce a row that proves nothing. Conflicts and bound changes are then read off that
// row by the same bounds reasoning the linear propagator uses, and explained from it, lazily,
// the same way (§10.2): the row is kept for as long as a trail entry refers to it, which is
// until the search backtracks past the point where it was derived.

import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex

/// What every LP worker of one solve shares: the relaxation, and its rows as exact integers.
///
/// The relaxation holds the rows that are linear constraints to CP-SAT. A row that is a
/// clause — Σ ℓᵢ ≥ 1 over binaries (§10.1) — is left out, as it is left out of the linear
/// propagator: the watched-literal scheme already says everything such a row can say on its
/// own, and a model made of clauses has no relaxation at all and is searched exactly as it
/// would be without the propagator.
struct RelaxationData: Sendable {
    /// The relaxed rows of the problem, without integrality, as the simplex engine solves them.
    let lp: CompiledLP
    /// Row i of `lp` scaled to integers: Σ rowCoef[t]·x[rowVar[t]] over t in rowStart[i] ..< rowStart[i + 1].
    let rowStart: [Int32]
    let rowVar: [Int32]
    let rowCoef: [Int64]
    /// The integer row is `rowScale[i]` times the row as given.
    let rowScale: [Double]
    /// The bounds of the integer activity, rounded inward; `Int64.min` / `Int64.max` for none.
    let rowLower: [Int64]
    let rowUpper: [Int64]
    /// The integer objective row of the model (empty for a feasibility problem).
    let costVar: [Int32]
    let costCoef: [Int64]
    /// max(|lower|, |upper|) of each variable's root domain.
    let reach: [UInt64]
    /// Roughly the bytes one worker's engine holds (rule L7).
    let engineBytes: Int

    /// Builds the relaxation and its exact rows. `nil` when the model has no row to relax,
    /// or when a row cannot be represented — which a model that `CPModel` accepted does not
    /// produce.
    init?(problem: CompiledLP, model: CPModel) {
        let n = problem.n
        let selected = (0..<problem.m).filter { model.rowHasLinearSide[$0] }
        let m = selected.count
        guard m > 0, n > 0 else { return nil }
        let aT = problem.aT
        var rowStart: [Int32] = [0]
        var rowVar: [Int32] = []
        var rowCoef: [Int64] = []
        var rowScale = [Double](repeating: 1, count: m)
        var rowLower = [Int64](repeating: .min, count: m)
        var rowUpper = [Int64](repeating: .max, count: m)
        var entries: [(row: Int, col: Int, value: Double)] = []
        let limit = 4.611_686_018_427_387_904e18   // 2⁶²
        for (i, row) in selected.enumerated() {
            let range = aT.colStart[row]..<aT.colStart[row + 1]
            guard let scale = CPModel.integralScale(for: range.lazy.map { aT.values[$0] }) else { return nil }
            let first = rowCoef.count
            for p in range {
                entries.append((i, Int(aT.rowIndex[p]), aT.values[p]))
                guard let a = Int64(exactly: (aT.values[p] * scale).rounded()) else { return nil }
                if a == 0 { continue }
                rowVar.append(aT.rowIndex[p])
                rowCoef.append(a)
            }
            if rowCoef.count > first {
                let divisor = CPModel.commonDivisor(Array(rowCoef[first...]))
                if divisor > 1 {
                    for k in first..<rowCoef.count { rowCoef[k] /= divisor }
                }
                let factor = scale / Double(divisor)
                rowScale[i] = factor
                // The activity is an integer, so the bounds round inward — as in `CPModel`.
                let upper = problem.ru[row] * factor
                if upper.isFinite, Swift.abs(upper) < limit {
                    rowUpper[i] = Int64((upper + CPModel.snapTolerance(upper)).rounded(.down))
                }
                let lower = problem.rl[row] * factor
                if lower.isFinite, Swift.abs(lower) < limit {
                    rowLower[i] = Int64((lower - CPModel.snapTolerance(lower)).rounded(.up))
                }
            }
            rowStart.append(Int32(rowVar.count))
        }

        var costVar: [Int32] = []
        var costCoef: [Int64] = []
        if model.objectiveRow >= 0 {
            let range = Int(model.linStart[model.objectiveRow])..<Int(model.linStart[model.objectiveRow + 1])
            costVar = Array(model.linVar[range])
            costCoef = Array(model.linCoef[range])
        }

        if m == problem.m {
            self.lp = problem.relaxed()
        } else {
            self.lp = CompiledLP(
                a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: problem.c, c0: problem.c0,
                sense: problem.sense, xl: problem.xl, xu: problem.xu, rl: selected.map { problem.rl[$0] },
                ru: selected.map { problem.ru[$0] })
        }
        self.rowStart = rowStart
        self.rowVar = rowVar
        self.rowCoef = rowCoef
        self.rowScale = rowScale
        self.rowLower = rowLower
        self.rowUpper = rowUpper
        self.costVar = costVar
        self.costCoef = costCoef
        self.reach = (0..<n).map { Swift.max(model.lower[$0].magnitude, model.upper[$0].magnitude) }
        // A dense LU of the basis up to the engine's limit, a sparse factorization beyond it;
        // plus the engine's vectors over the n + m columns of [A −I].
        let nonzeros = entries.count
        let factorization = m <= Simplex.denseBasisLimit ? 8 * m * m : 96 * nonzeros
        self.engineBytes = factorization + 160 * (n + m) + 24 * nonzeros
    }
}

/// What a look at the relaxation produced.
enum RelaxationResult {
    case nothing
    /// Bounds were tightened; ordinary propagation has to run again.
    case tightened
    /// The derived row with this index in the worker's pool is violated.
    case conflict(Int32)
    /// The optimum of the relaxation is integral and satisfies the model exactly.
    case solution([Int64])
}

/// The worker-owned state of the LP propagator: the rows derived from the duals that trail
/// entries still refer to, and the latest solution of the relaxation. The engine itself is a
/// separate, non-copyable property of the worker (`CPWorker.relaxationEngine`).
struct RelaxationState {
    /// False for a pure CDCL worker; everything below is then empty and unused.
    var enabled = false

    // MARK: Derived rows
    //
    // Row r is Σ cutCoef[t]·x[cutVar[t]] ≤ cutRHS[r] over t in cutStart[r] ..< cutStart[r + 1].
    // Only the terms an explanation can need are kept — those whose bound had moved off its
    // level-0 value when the row was derived, and the variables the row tightened; the others
    // are folded into the right-hand side at the bound they had. Terms are stored in increasing
    // order of what loosening them costs, which is the order explanations spend their surplus in.
    // The rows form a stack: `cutMark[r]` is the length of the trail when row r was derived,
    // and backtracking below that length removes the row.

    var cutStart: [Int32] = [0]
    var cutVar: [Int32] = []
    var cutCoef: [Int64] = []
    var cutRHS: [Int64] = []
    var cutMark: [Int32] = []

    // MARK: Scratch

    /// The combination under construction, dense over the variables.
    var dense: [Int64] = []
    var touched: [Int32] = []
    var isTouched: [Bool] = []
    /// Per row: the multiplier in the row's own integer units, and which side it applies to
    /// (−1 the lower bound, +1 the upper bound, 0 none).
    var lambda: [Double] = []
    var side: [Int8] = []
    var changes: [BoundChange] = []

    // MARK: The latest solve

    /// The basis the engine stopped on; `nil` before the first solve.
    var basis: Basis? = nil
    /// True while `attemptTrail` is the trail length the relaxation was last looked at with.
    var attempted = false
    var attemptTrail = -1
    /// True while `fractional` describes the optimum of the relaxation over the current domains.
    var fresh = false
    var fractional: [(variable: Int32, value: Double)] = []
    /// A lower bound on the integer objective proven at level 0, to be reported.
    var rootBound = Int64.min

    // MARK: Policy and statistics

    /// The multipliers are scaled by 2^shift before rounding; lowered when a row overflows.
    var shift = 30
    /// How many looks at the relaxation in a row proved nothing, and how many of the coming
    /// fixed points to pass without looking.
    var idle = 0
    var skip = 0
    var failures = 0
    var solves = 0
    var conflicts = 0
    var tightenings = 0
    var solutions = 0

    init() {}

    init(data: RelaxationData) {
        enabled = true
        let n = data.lp.n
        dense = [Int64](repeating: 0, count: n)
        isTouched = [Bool](repeating: false, count: n)
        lambda = [Double](repeating: 0, count: data.lp.m)
        side = [Int8](repeating: 0, count: data.lp.m)
    }

    /// The engine an LP worker solves the relaxation with: dual simplex, one thread, no GPU.
    static func makeEngine(for data: RelaxationData) -> SimplexEngine {
        var context = SolveContext()
        context.threads = 1
        context.metal = .off
        return Simplex(.dual, presolve: false).makeEngine(for: data.lp, context: context)
    }

    /// Removes the rows derived at or after trail length `target`.
    @inline(__always)
    mutating func popRows(from target: Int) {
        attempted = false
        fresh = false
        guard let last = cutMark.last, Int(last) >= target else { return }
        var keep = cutMark.count
        while keep > 0, Int(cutMark[keep - 1]) >= target { keep -= 1 }
        cutMark.removeSubrange(keep...)
        cutRHS.removeSubrange(keep...)
        let terms = Int(cutStart[keep])
        cutStart.removeSubrange((keep + 1)...)
        cutVar.removeSubrange(terms...)
        cutCoef.removeSubrange(terms...)
    }

    /// Bytes held beyond the shared data and the engine (rule L7).
    var approximateBytes: Int {
        cutVar.capacity * 12 + cutRHS.capacity * 16 + dense.count * 9 + lambda.count * 9
    }
}

extension CPWorker {
    /// Whether the relaxation should be looked at before the next decision.
    @inline(__always)
    var relaxationIsDue: Bool {
        relaxation.enabled && !(relaxation.attempted && relaxation.attemptTrail == trail.count)
    }

    // MARK: - Solving

    /// Solves the relaxation over the current domains and acts on what it proves.
    ///
    /// Called when ordinary propagation is at a fixed point without a conflict. Only a stop
    /// signal is thrown; a failure of the engine switches the propagator off for this worker
    /// after a few tries, which costs strength and nothing else.
    mutating func propagateRelaxation(gate: inout WorkGate) async throws(StopSignal) -> RelaxationResult {
        relaxation.attempted = true
        relaxation.attemptTrail = trail.count
        relaxation.fresh = false
        guard let data = options.relaxation else { return .nothing }
        if relaxation.skip > 0 {
            relaxation.skip -= 1
            return .nothing
        }

        // The domains, as changes against the bounds of the problem the engine holds.
        let n = model.variableCount
        var changes: [BoundChange] = []
        swap(&changes, &relaxation.changes)
        changes.removeAll(keepingCapacity: true)
        do {
            let lower = data.lp.xl
            let upper = data.lp.xu
            for x in 0..<n {
                let lo = Double(lb[x])
                let hi = Double(ub[x])
                if lo != lower[x] || hi != upper[x] {
                    changes.append(BoundChange(column: Int32(x), lower: lo, upper: hi))
                }
            }
        }

        // With an incumbent, the dual method may stop as soon as its bound passes what the
        // incumbent allows; a quarter of a unit of the integer objective is far more than the
        // rounding of the multipliers loses.
        var cutoff: Double? = nil
        let objectiveRow = model.objectiveRow
        if objectiveRow >= 0, linRHS[objectiveRow] < model.linRHS[objectiveRow] {
            cutoff = (Double(linRHS[objectiveRow]) + 0.25) / model.objectiveScale + model.objectiveConstant
        }

        // From the basis the engine stopped on last time: its factorization is still in
        // place, and the bounds are what changed. Every look is bounded; a relaxation that
        // needs more iterations than that — a large one, from a cold start — is continued at
        // the next look instead of holding the search up.
        let rows = data.lp.m
        let parent = relaxation.basis ?? Basis.allLogical(for: data.lp)
        let outcome: SimplexOutcome
        do {
            outcome = try await relaxationEngine!.run(
                method: .dual, warmStart: .incremental(parent: parent, changes: changes), cutoff: cutoff,
                iterationLimit: Swift.max(1_000, 4 * rows), gate: &gate)
        } catch {
            swap(&changes, &relaxation.changes)
            relaxation.basis = nil
            relaxationFailed()
            return .nothing
        }
        swap(&changes, &relaxation.changes)
        relaxation.solves += 1
        relaxation.basis = outcome.basis
        // The engine ticked the gate while it ran; what follows is a pass over the rows.
        try await gate.tick()

        var result = RelaxationResult.nothing
        switch outcome.status {
        case .stopped(let signal):
            throw signal
        case .optimal:
            relaxation.failures = 0
            // The optimum over these domains: which variables are fractional in it, and, if
            // none is, whether it is a solution.
            relaxation.fractional.removeAll(keepingCapacity: true)
            for x in 0..<n where lb[x] < ub[x] {
                let v = outcome.x[x]
                if Swift.abs(v - v.rounded()) > 1e-6 { relaxation.fractional.append((Int32(x), v)) }
            }
            if relaxation.fractional.isEmpty, let values = integralSolution(outcome.x) {
                relaxation.solutions += 1
                relaxation.idle = 0
                return .solution(values)
            }
            if objectiveRow >= 0 {
                result = deriveRow(weights: outcome.y, withObjective: true)
            }
            if case .conflict = result {
                // The integer objective rounds the optimum up past the incumbent's limit.
            } else {
                relaxation.fresh = true
            }
        case .cutoff:
            relaxation.failures = 0
            result = deriveRow(weights: outcome.y, withObjective: true)
        case .infeasible:
            relaxation.failures = 0
            if let ray = outcome.dualRay {
                result = deriveRow(weights: ray, withObjective: false)
            }
        case .iterationLimit:
            // Unfinished, not unhelpful: it does not count towards backing off.
            relaxation.attemptTrail = trail.count
            return .nothing
        case .unbounded, .numericalFailure:
            relaxationFailed()
        }

        // Ordinary propagation follows a tightening and leaves the optimum where it is: the
        // relaxation is up to date for the trail as it now stands.
        relaxation.attemptTrail = trail.count
        switch result {
        case .nothing:
            // A relaxation that keeps proving nothing is looked at less and less often — on a
            // model where it has nothing to say (clauses, say) an LP worker ends up working
            // as a CDCL worker. Anything it does prove brings it back to every node.
            relaxation.idle += 1
            if relaxation.idle >= 256 {
                relaxation.skip = 1 << Swift.min(10, (relaxation.idle - 256) / 64)
            }
        case .tightened:
            relaxation.idle = 0
            relaxation.tightenings += 1
        case .conflict:
            relaxation.idle = 0
            relaxation.conflicts += 1
        case .solution:
            break
        }
        return result
    }

    /// Counts a failure of the engine; after three in a row the propagator is switched off.
    mutating func relaxationFailed() {
        relaxation.failures += 1
        if relaxation.failures >= 3 {
            // Rows that trail entries refer to must stay; nothing new is derived.
            relaxation.skip = .max
        }
    }

    /// The optimum of the relaxation as integers, when it is integral and satisfies the model
    /// — every row and clause exactly, and the objective bound in force.
    func integralSolution(_ x: [Double]) -> [Int64]? {
        let n = model.variableCount
        var values = [Int64](repeating: 0, count: n)
        for j in 0..<n {
            let rounded = x[j].rounded()
            guard Swift.abs(x[j] - rounded) <= 1e-6, Swift.abs(rounded) < 9e15 else { return nil }
            let value = Int64(rounded)
            guard value >= lb[j], value <= ub[j] else { return nil }
            values[j] = value
        }
        guard model.isSatisfied(by: values) else { return nil }
        if model.objectiveRow >= 0, model.objectiveValue(of: values) > linRHS[model.objectiveRow] { return nil }
        return values
    }

    // MARK: - Derived rows

    /// Forms the integer combination of the model's rows that the multipliers `weights` ask
    /// for — row i on its lower side when weights[i] > 0, on its upper side when < 0 — plus,
    /// with `withObjective`, the row `objective ≤ incumbent − 1`, and acts on it.
    mutating func deriveRow(weights: [Double], withObjective: Bool) -> RelaxationResult {
        guard let data = options.relaxation else { return .nothing }
        let rows = data.lp.m
        guard weights.count == rows else { return .nothing }
        let objectiveRow = model.objectiveRow
        let includeObjective = withObjective && objectiveRow >= 0
        let limit = linRHS.isEmpty || objectiveRow < 0 ? Int64(0) : linRHS[objectiveRow]

        // Multipliers in each row's integer units, on the side the sign names.
        var largestWeight = 0.0
        for i in 0..<rows { largestWeight = Swift.max(largestWeight, Swift.abs(weights[i])) }
        var largest = 0.0
        for i in 0..<rows {
            let w = weights[i]
            var chosen: Int8 = 0
            if w > 1e-11 * largestWeight, data.rowLower[i] != .min {
                chosen = -1
            } else if w < -1e-11 * largestWeight, data.rowUpper[i] != .max {
                chosen = 1
            }
            relaxation.side[i] = chosen
            let value = chosen == 0 ? 0 : Swift.abs(w) / data.rowScale[i]
            relaxation.lambda[i] = value
            if value > largest { largest = value }
        }
        if !includeObjective && largest == 0 { return .nothing }

        // The scratch buffers leave `self` while the combination is built, so that the helper
        // below works on plain local arrays.
        var dense: [Int64] = []
        var touched: [Int32] = []
        var isTouched: [Bool] = []
        swap(&dense, &relaxation.dense)
        swap(&touched, &relaxation.touched)
        swap(&isTouched, &relaxation.isTouched)
        let lambda = relaxation.lambda
        let side = relaxation.side
        let objectiveScale = model.objectiveScale
        defer {
            for j in touched {
                dense[Int(j)] = 0
                isTouched[Int(j)] = false
            }
            touched.removeAll(keepingCapacity: true)
            swap(&dense, &relaxation.dense)
            swap(&touched, &relaxation.touched)
            swap(&isTouched, &relaxation.isTouched)
        }

        /// One attempt at scale 2^shift; `nil` when something does not fit in Int64.
        func combine(_ shift: Int) -> (rhs: Int64, objective: Int64)? {
            for j in touched {
                dense[Int(j)] = 0
                isTouched[Int(j)] = false
            }
            touched.removeAll(keepingCapacity: true)
            let unit = Int64(1) << Int64(shift)
            var rhs: Int64 = 0
            var objectiveMultiplier: Int64 = 0
            let factor: Double
            if includeObjective {
                objectiveMultiplier = unit
                factor = objectiveScale * Double(unit)
                let (bound, overflow) = unit.multipliedReportingOverflow(by: limit)
                if overflow { return nil }
                rhs = bound
                for k in data.costVar.indices {
                    let (term, overflowTerm) = unit.multipliedReportingOverflow(by: data.costCoef[k])
                    if overflowTerm { return nil }
                    let j = Int(data.costVar[k])
                    dense[j] = term
                    isTouched[j] = true
                    touched.append(Int32(j))
                }
            } else {
                factor = Double(unit) / largest
            }
            for i in 0..<rows where side[i] != 0 {
                let scaled = lambda[i] * factor
                guard scaled < 4e18 else { return nil }
                let multiplier = Int64(scaled.rounded())
                if multiplier == 0 { continue }
                let upperSide = side[i] > 0
                let (bound, overflowBound) = multiplier.multipliedReportingOverflow(by: upperSide ? data.rowUpper[i] : data.rowLower[i])
                if overflowBound { return nil }
                let (newRHS, overflowRHS) = upperSide ? rhs.addingReportingOverflow(bound) : rhs.subtractingReportingOverflow(bound)
                if overflowRHS { return nil }
                rhs = newRHS
                for t in Int(data.rowStart[i])..<Int(data.rowStart[i + 1]) {
                    let (term, overflowTerm) = multiplier.multipliedReportingOverflow(by: data.rowCoef[t])
                    if overflowTerm { return nil }
                    let j = Int(data.rowVar[t])
                    let (sum, overflowSum) = upperSide ? dense[j].addingReportingOverflow(term) : dense[j].subtractingReportingOverflow(term)
                    if overflowSum { return nil }
                    dense[j] = sum
                    if !isTouched[j] {
                        isTouched[j] = true
                        touched.append(Int32(j))
                    }
                }
            }
            // Every activity the row can have over the root domains, and so every sum an
            // explanation forms, has to stay well inside Int64 — the headroom `CPModel` keeps.
            var magnitude = rhs.magnitude
            for j in touched {
                let g = dense[Int(j)]
                if g == 0 { continue }
                let (term, overflowTerm) = g.magnitude.multipliedReportingOverflow(by: data.reach[Int(j)] &+ 1)
                if overflowTerm { return nil }
                let (sum, overflowSum) = magnitude.addingReportingOverflow(term)
                if overflowSum { return nil }
                magnitude = sum
            }
            if magnitude > UInt64(1) << 60 { return nil }
            return (rhs, objectiveMultiplier)
        }

        var shift = relaxation.shift
        var combined = combine(shift)
        while combined == nil && shift > 0 {
            shift = Swift.max(0, shift - 6)
            combined = combine(shift)
        }
        guard let (rhs, objectiveMultiplier) = combined else { return .nothing }
        relaxation.shift = shift

        // The smallest activity of the row over the current domains.
        var minimum: Int64 = 0
        for j in touched {
            let g = dense[Int(j)]
            if g > 0 { minimum += g * lb[Int(j)] } else if g < 0 { minimum += g * ub[Int(j)] }
        }

        // At level 0 the row bounds the objective itself: m·Z ≥ minimum − (rhs − m·limit).
        if currentLevel == 0, objectiveMultiplier > 0 {
            let numerator = minimum - (rhs - objectiveMultiplier * limit)
            var bound = numerator / objectiveMultiplier
            if numerator > 0 && numerator % objectiveMultiplier != 0 { bound += 1 }   // round up
            if bound > relaxation.rootBound { relaxation.rootBound = bound }
        }

        if minimum > rhs {
            return .conflict(storeRow(dense: dense, touched: touched, rhs: rhs, minimum: minimum, pivots: []))
        }

        // Bounds the row tightens: a·(x − lb) ≤ slack for a > 0, |a|·(ub − x) ≤ slack for a < 0.
        let slack = rhs - minimum
        var pivots: [Int32] = []
        for j in touched {
            let x = Int(j)
            let g = dense[x]
            if g == 0 { continue }
            let span = ub[x] - lb[x]
            if span == 0 { continue }
            if slack / (g > 0 ? g : -g) < span { pivots.append(j) }
        }
        if pivots.isEmpty { return .nothing }

        if currentLevel == 0 {
            // Facts: no reason is ever asked for, so no row is kept.
            for j in pivots {
                let x = Int(j)
                let g = dense[x]
                if g > 0 {
                    setUpper(x, lb[x] + slack / g, ReasonKind.none, -1)
                } else {
                    setLower(x, ub[x] - slack / (-g), ReasonKind.none, -1)
                }
            }
            return .tightened
        }
        let row = storeRow(dense: dense, touched: touched, rhs: rhs, minimum: minimum, pivots: pivots)
        for j in pivots {
            let x = Int(j)
            let g = dense[x]
            if g > 0 {
                setUpper(x, lb[x] + slack / g, ReasonKind.cut, row)
            } else {
                setLower(x, ub[x] - slack / (-g), ReasonKind.cut, row)
            }
        }
        return .tightened
    }

    /// Pushes the derived row on the stack and returns its index. Kept are the terms whose
    /// bound is off its level-0 value (their literals are what a reason quotes) and the
    /// pivots; every other term is folded into the right-hand side at its bound.
    mutating func storeRow(dense: [Int64], touched: [Int32], rhs: Int64, minimum: Int64, pivots: [Int32]) -> Int32 {
        var kept: [(cost: Int64, variable: Int32, coefficient: Int64)] = []
        var keptActivity: Int64 = 0
        var isPivot: Set<Int32> = []
        if pivots.count > 8 { isPivot = Set(pivots) }
        for j in touched {
            let x = Int(j)
            let g = dense[x]
            if g == 0 { continue }
            // What loosening this term to its level-0 bound would take off the minimum.
            let cost = g > 0 ? g * (lb[x] - rootLower[x]) : (-g) * (rootUpper[x] - ub[x])
            let pivot = pivots.count > 8 ? isPivot.contains(j) : pivots.contains(j)
            if cost > 0 || pivot {
                kept.append((cost, j, g))
                keptActivity += g > 0 ? g * lb[x] : g * ub[x]
            }
        }
        kept.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.variable < $1.variable }
        let index = Int32(relaxation.cutRHS.count)
        for term in kept {
            relaxation.cutVar.append(term.variable)
            relaxation.cutCoef.append(term.coefficient)
        }
        relaxation.cutStart.append(Int32(relaxation.cutVar.count))
        relaxation.cutRHS.append(rhs - (minimum - keptActivity))
        relaxation.cutMark.append(Int32(trail.count))
        return index
    }

    /// The reason of a propagation or a conflict of derived row `row`, built from the bounds in
    /// force before trail position `index` — `explainLinear`, on a row of the stack.
    mutating func explainCut(
        _ row: Int, pivot: Int, pivotIsLower: Bool, need: Int64, before index: Int, into out: inout [BoundLiteral]
    ) {
        let variables = relaxation.cutVar
        let coefficients = relaxation.cutCoef
        let start = Int(relaxation.cutStart[row])
        let end = Int(relaxation.cutStart[row + 1])
        boundScratch.removeAll(keepingCapacity: true)
        var sum: Int64 = 0
        var pivotCoefficient: Int64 = 0
        for t in start..<end {
            let x = Int(variables[t])
            let a = coefficients[t]
            if x == pivot {
                pivotCoefficient = a
                boundScratch.append(0)
                continue
            }
            let bound = a > 0 ? lowerBound(of: x, before: index) : upperBound(of: x, before: index)
            boundScratch.append(bound)
            sum += a * bound
        }
        var threshold = relaxation.cutRHS[row] + 1
        if pivot >= 0 {
            let excluded = pivotIsLower ? need - 1 : need + 1
            threshold -= pivotCoefficient * excluded
        }
        var surplus = sum - threshold
        assert(surplus >= 0, "a derived row does not imply its consequence")
        if surplus < 0 { surplus = 0 }
        // Cheapest terms first: spending the surplus there drops the most literals.
        for t in start..<end {
            let x = Int(variables[t])
            if x == pivot { continue }
            let a = coefficients[t]
            let bound = boundScratch[t - start]
            if a > 0 {
                let base = rootLower[x]
                if bound <= base { continue }
                let loosen = Swift.min(bound - base, surplus / a)
                surplus -= a * loosen
                if bound - loosen > base {
                    out.append(BoundLiteral(variable: Int32(x), isLower: true, value: bound - loosen))
                }
            } else {
                let base = rootUpper[x]
                if bound >= base { continue }
                let magnitude = -a
                let loosen = Swift.min(base - bound, surplus / magnitude)
                surplus -= magnitude * loosen
                if bound + loosen < base {
                    out.append(BoundLiteral(variable: Int32(x), isLower: false, value: bound + loosen))
                }
            }
        }
    }

    // MARK: - Branching

    /// Branches on a variable that is fractional in the optimum of the relaxation, when that
    /// optimum is for the current domains: the most active such variable, split at its value.
    /// The side taken first is the one its saved value lies on — the phase it had last, or
    /// the hint of a warm start (§10.2) — and the nearer one when it has none. Returns false
    /// when no variable is fractional, and VSIDS decides as usual.
    mutating func decideOnRelaxation() -> Bool {
        guard relaxation.fresh, relaxation.attemptTrail == trail.count else { return false }
        var chosen = -1
        var chosenValue = 0.0
        var best = -Double.infinity
        for (variable, value) in relaxation.fractional {
            let x = Int(variable)
            if lb[x] < ub[x], activity[x] > best {
                best = activity[x]
                chosen = x
                chosenValue = value
            }
        }
        guard chosen >= 0 else { return false }
        let x = chosen
        var floor = Int64(chosenValue.rounded(.down))
        floor = Swift.min(Swift.max(floor, lb[x]), ub[x] - 1)
        var upward = chosenValue - Double(floor) > 0.5
        if options.phase != .random, hasSavedValue[x] { upward = savedValue[x] > floor }
        decisions += 1
        newDecisionLevel()
        if upward {
            setLower(x, floor + 1, ReasonKind.none, -1)
        } else {
            setUpper(x, floor, ReasonKind.none, -1)
        }
        return true
    }
}
