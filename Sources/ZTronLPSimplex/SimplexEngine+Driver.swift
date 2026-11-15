// Warm and hot starts (specification §7.4) and the driver that sequences the two methods,
// dual phase 1 and the perturbation clean-up (§7.2, §7.3).

import ZTronLPCore
import ZTronLPNumerics

extension SimplexEngine {
    // MARK: - Warm starts

    /// Restores the true bounds and costs if an earlier run was interrupted while a
    /// perturbation or the artificial bounds of dual phase 1 were in place.
    mutating func restoreTrueData() {
        if boundsPerturbed || artificialBounds {
            for j in 0..<total {
                lower[j] = trueLower[j]
                upper[j] = trueUpper[j]
            }
            for j in 0..<total where pos[j] < 0 {
                status[j] = nonbasicStatus(j, preferred: status[j])
                placeNonbasic(j)
            }
            boundsPerturbed = false
            artificialBounds = false
            rebuildHash()
        }
        if costsPerturbed {
            cost = trueCost
            costsPerturbed = false
        }
    }

    /// Puts every column back on the bounds of the engine's problem.
    mutating func resetBoundsToProblem() {
        guard !modifiedColumns.isEmpty else { return }
        for column in modifiedColumns {
            let j = Int(column)
            isModified[j] = false
            let lo = j < n ? lp.xl[j] : lp.rl[j - n]
            let up = j < n ? lp.xu[j] : lp.ru[j - n]
            trueLower[j] = lo
            trueUpper[j] = up
            lower[j] = lo
            upper[j] = up
            if pos[j] < 0 {
                let before = status[j]
                let after = nonbasicStatus(j, preferred: before)
                if before == .atUpper { basisHash ^= upperToken(j) }
                status[j] = after
                if after == .atUpper { basisHash ^= upperToken(j) }
                placeNonbasic(j)
            }
        }
        modifiedColumns.removeAll(keepingCapacity: true)
    }

    /// `.basis`: validates the statuses (a nonbasic at a bound that no longer exists moves to
    /// the nearest finite bound; a basic variable outside its bounds simply is primal
    /// infeasible), and schedules one refactorization. If the basis is the one the engine
    /// already holds, the factorization is kept — the branch-and-bound hot path.
    mutating func loadBasis(_ basis: Basis) {
        guard basis.status.count == total else {
            warnings.append("the warm-start basis does not fit the problem; starting from the all-logical basis")
            installSlackBasis()
            return
        }
        if hasFactor && basis.basic == head {
            for j in 0..<total where pos[j] < 0 {
                let preferred = basis.status[j] == .basic ? status[j] : basis.status[j]
                status[j] = nonbasicStatus(j, preferred: preferred)
                placeNonbasic(j)
            }
            rebuildHash()
            return
        }

        var isBasic = [Bool](repeating: false, count: total)
        var newHead: [Int32] = []
        newHead.reserveCapacity(m)
        // The listed order first, then any other column marked basic.
        for column in basis.basic where newHead.count < m {
            let j = Int(column)
            guard j >= 0, j < total, basis.status[j] == .basic, !isBasic[j] else { continue }
            isBasic[j] = true
            newHead.append(column)
        }
        for j in 0..<total where newHead.count < m && basis.status[j] == .basic && !isBasic[j] {
            isBasic[j] = true
            newHead.append(Int32(j))
        }
        // Too few basic columns: logicals fill the rest. (Too many were cut off above.) A
        // singular result is repaired when it is factored.
        var i = 0
        while newHead.count < m && i < m {
            if !isBasic[n + i] {
                isBasic[n + i] = true
                newHead.append(Int32(n + i))
            }
            i += 1
        }
        head = newHead
        for j in 0..<total { pos[j] = -1 }
        for (k, column) in head.enumerated() {
            pos[Int(column)] = Int32(k)
            status[Int(column)] = .basic
        }
        for j in 0..<total where pos[j] < 0 {
            let preferred: BasisStatus = basis.status[j] == .basic ? .atLower : basis.status[j]
            status[j] = nonbasicStatus(j, preferred: preferred)
            placeNonbasic(j)
        }
        hasFactor = false
        for k in 0..<m { dse[k] = 1 }
        resetPricingWeights()
        rebuildHash()
    }

    /// `.primalPoint`: a triangular crash from a primal vector.
    ///
    /// Columns are ranked by distance from their nearest bound; up to m columns are accepted
    /// greedily when each adds a pivot of relative size ≥ 0.01 in a still-uncovered row;
    /// logicals fill the rest. Every accepted column is matched to a row of its own, so the
    /// basis is structurally nonsingular; when it is numerically singular all the same, the
    /// factorization's repair swaps the dependent columns for logicals. Primal phase 1 removes
    /// the residual infeasibility.
    mutating func crashFromPoint(_ point: [Double]) {
        guard point.count == n else {
            warnings.append("the warm-start point does not fit the problem; starting from the all-logical basis")
            installSlackBasis()
            return
        }
        var scaled = point
        if let scaling = lp.scaling { scaled = scaling.scalePrimal(point) }
        let feasibility = tol.primalFeasibility

        // Every column of [A −I] is a candidate, logicals included: where a row's activity at
        // the point is away from both row bounds, its logical is far from its bounds.
        let a = lp.a
        let activity = a.multiply(scaled)
        var ranked: [(column: Int32, distance: Double)] = []
        for j in 0..<n where lower[j] < upper[j] {
            let v = scaled[j]
            let distance = Swift.min(v - lower[j], upper[j] - v)
            if distance > feasibility * (1 + Swift.abs(v)) { ranked.append((Int32(j), distance)) }
        }
        for i in 0..<m where lower[n + i] < upper[n + i] {
            let s = activity[i]
            let distance = Swift.min(s - lower[n + i], upper[n + i] - s)
            if distance > feasibility * (1 + Swift.abs(s)) { ranked.append((Int32(n + i), distance)) }
        }
        ranked.sort { $0.distance != $1.distance ? $0.distance > $1.distance : $0.column < $1.column }

        // Row states: 0 = uncovered, 1 = held by an accepted structural column (`columnAtRow`),
        // 2 = held by its own logical.
        //
        // Columns are taken best-ranked first. A structural column takes its largest usable
        // entry (relative size ≥ 0.01) in an uncovered row; a logical takes its own row. When
        // the rows a column could use are all held, an augmenting path may move earlier
        // structural columns to other rows of theirs to make room. Accepting in rank order
        // along augmenting paths keeps the best-ranked set of columns that can be matched at
        // all (the matchable sets form a matroid); a first-come assignment does not.
        var rowState = [UInt8](repeating: 0, count: m)
        var columnAtRow = [Int32](repeating: -1, count: m)
        var visitedRow = [Int32](repeating: -1, count: m)
        var searchBudget = 64 * Swift.max(a.nnz, 1)   // bounds the total work of the searches
        var stackColumn: [Int32] = []
        var stackPointer: [Int] = []
        var pathRow: [Int32] = []
        var columnMaxCache = [Double](repeating: -1, count: n)
        var accepted = 0

        func columnMax(_ j: Int) -> Double {
            if columnMaxCache[j] < 0 { columnMaxCache[j] = a.maxAbs(inColumn: j) }
            return columnMaxCache[j]
        }

        /// Finds a row for structural column `start`, moving other structural columns along an
        /// augmenting path if needed. Depth-first with an explicit stack: task stacks are small.
        /// On success every column on the path holds the row it chose; the row `start` held
        /// before, if any, is the caller's to release.
        func findRow(for start: Int, stamp: Int32) -> Bool {
            stackColumn.removeAll(keepingCapacity: true)
            stackPointer.removeAll(keepingCapacity: true)
            pathRow.removeAll(keepingCapacity: true)
            stackColumn.append(Int32(start))
            stackPointer.append(a.colStart[start])
            while let top = stackColumn.last {
                let depth = stackColumn.count - 1
                let k = Int(top)
                let limit = 0.01 * columnMax(k)
                var p = stackPointer[depth]
                let end = a.colStart[k + 1]
                var descended = false
                while p < end {
                    let i = Int(a.rowIndex[p])
                    let magnitude = Swift.abs(a.values[p])
                    p += 1
                    searchBudget -= 1
                    if rowState[i] == 2 || magnitude < limit || magnitude == 0 || visitedRow[i] == stamp { continue }
                    visitedRow[i] = stamp
                    if rowState[i] == 0 {
                        pathRow.append(Int32(i))
                        for level in 0...depth { columnAtRow[Int(pathRow[level])] = stackColumn[level] }
                        rowState[i] = 1
                        return true
                    }
                    // The row is held by another structural column: try to move that one.
                    stackPointer[depth] = p
                    pathRow.append(Int32(i))
                    stackColumn.append(columnAtRow[i])
                    stackPointer.append(a.colStart[Int(columnAtRow[i])])
                    descended = true
                    break
                }
                if !descended {
                    stackColumn.removeLast()
                    stackPointer.removeLast()
                    if !pathRow.isEmpty { pathRow.removeLast() }
                }
                if searchBudget <= 0 { return false }
            }
            return false
        }

        for (order, candidate) in ranked.enumerated() {
            if accepted == m { break }
            let stamp = Int32(order)
            let column = Int(candidate.column)
            if column >= n {
                // A logical can only cover its own row.
                let i = column - n
                if rowState[i] == 0 {
                    rowState[i] = 2
                    accepted += 1
                } else if rowState[i] == 1, searchBudget > 0 {
                    let holder = Int(columnAtRow[i])
                    visitedRow[i] = stamp
                    if findRow(for: holder, stamp: stamp) {
                        columnAtRow[i] = -1
                        rowState[i] = 2
                        accepted += 1
                    }
                }
                continue
            }
            let threshold = 0.01 * columnMax(column)
            guard threshold > 0 else { continue }
            // The direct case: the largest usable entry in a row nobody holds.
            var bestRow = -1
            var best = 0.0
            for p in a.colStart[column]..<a.colStart[column + 1] {
                let i = Int(a.rowIndex[p])
                let magnitude = Swift.abs(a.values[p])
                if rowState[i] == 0 && magnitude >= threshold && magnitude > best {
                    best = magnitude
                    bestRow = i
                }
            }
            if bestRow >= 0 {
                rowState[bestRow] = 1
                columnAtRow[bestRow] = Int32(column)
                accepted += 1
            } else if searchBudget > 0, findRow(for: column, stamp: stamp) {
                accepted += 1
            }
        }

        // Values: nonbasic structurals on the bound nearest to the point; nonbasic logicals
        // on the bound nearest to the row's activity at the point.
        for j in 0..<total { pos[j] = -1 }
        for i in 0..<m {
            let column = columnAtRow[i] >= 0 ? Int(columnAtRow[i]) : n + i
            head[i] = Int32(column)
            pos[column] = Int32(i)
            status[column] = .basic
        }
        for j in 0..<n where pos[j] < 0 {
            x[j] = scaled[j]
            status[j] = nonbasicStatus(j, preferred: .free)
            placeNonbasic(j)
        }
        for i in 0..<m where pos[n + i] < 0 {
            x[n + i] = activity[i]
            status[n + i] = nonbasicStatus(n + i, preferred: .free)
            placeNonbasic(n + i)
        }
        hasFactor = false
        for k in 0..<m { dse[k] = 1 }
        resetPricingWeights()
        rebuildHash()
    }

    /// `.crash(.triangular)`: structural columns are chosen to form a triangular basis by the
    /// classic LTSF ordering — singleton columns first — giving far fewer phase-1 iterations
    /// than the all-logical basis on structured models.
    ///
    /// A column's count is the number of its entries in rows that are still free to be pivot
    /// rows. The column with the smallest count goes first; its largest entry in a free row
    /// becomes the pivot, that row is covered, and the column's other free rows are handed to
    /// their logicals. Ties prefer free columns, then one-sided, then boxed ones.
    mutating func triangularCrash() {
        let a = lp.a
        let aT = lp.aT
        var rowState = [UInt8](repeating: 0, count: m)
        for i in 0..<m where lower[n + i] == -.infinity && upper[n + i] == .infinity { rowState[i] = 2 }
        var count = [Int](repeating: 0, count: n)
        var maxCount = 0
        for j in 0..<n where lower[j] < upper[j] {
            var c = 0
            for p in a.colStart[j]..<a.colStart[j + 1] where rowState[Int(a.rowIndex[p])] == 0 { c += 1 }
            count[j] = c
            if c > maxCount { maxCount = c }
        }
        /// Lower is better: free columns first, then one-sided, then boxed.
        func preference(_ j: Int) -> Int {
            let hasLower = lower[j] > -.infinity
            let hasUpper = upper[j] < .infinity
            return (hasLower ? 1 : 0) + (hasUpper ? 1 : 0)
        }
        // Bucket queue by count, with lazy deletion.
        var buckets = [[Int32]](repeating: [], count: maxCount + 1)
        for preferenceClass in 0...2 {
            for j in 0..<n where lower[j] < upper[j] && count[j] > 0 && preference(j) == preferenceClass {
                buckets[count[j]].append(Int32(j))
            }
        }
        var cursor = [Int](repeating: 0, count: maxCount + 1)
        var used = [Bool](repeating: false, count: n)
        var columnAtRow = [Int32](repeating: -1, count: m)
        var level = 1
        while level <= maxCount {
            guard cursor[level] < buckets[level].count else {
                level += 1
                continue
            }
            let j = Int(buckets[level][cursor[level]])
            cursor[level] += 1
            if used[j] || count[j] != level { continue }   // stale entry
            used[j] = true
            var columnMax = 0.0
            var bestRow = -1
            var best = 0.0
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let magnitude = Swift.abs(a.values[p])
                if magnitude > columnMax { columnMax = magnitude }
                let i = Int(a.rowIndex[p])
                if rowState[i] == 0 && magnitude > best {
                    best = magnitude
                    bestRow = i
                }
            }
            guard bestRow >= 0, best >= 0.01 * columnMax else { continue }
            // Cover the pivot row and retire the column's other free rows.
            var changedRows: [Int] = []
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let i = Int(a.rowIndex[p])
                if rowState[i] == 0 {
                    rowState[i] = i == bestRow ? 1 : 2
                    changedRows.append(i)
                }
            }
            columnAtRow[bestRow] = Int32(j)
            // Every other column with an entry in a retired row loses one candidate row.
            var lowest = level
            for i in changedRows {
                for p in aT.colStart[i]..<aT.colStart[i + 1] {
                    let k = Int(aT.rowIndex[p])
                    if used[k] || count[k] == 0 { continue }
                    count[k] -= 1
                    if count[k] > 0 {
                        buckets[count[k]].append(Int32(k))
                        if count[k] < lowest { lowest = count[k] }
                    }
                }
            }
            level = lowest
        }

        for j in 0..<total { pos[j] = -1 }
        for i in 0..<m {
            let column = columnAtRow[i] >= 0 ? Int(columnAtRow[i]) : n + i
            head[i] = Int32(column)
            pos[column] = Int32(i)
            status[column] = .basic
        }
        for j in 0..<total where pos[j] < 0 {
            status[j] = Basis.nonbasicStatus(lower: lower[j], upper: upper[j])
            placeNonbasic(j)
        }
        hasFactor = false
        for k in 0..<m { dse[k] = 1 }
        resetPricingWeights()
        rebuildHash()
    }

    /// Installs the starting basis a warm start asks for.
    mutating func prepare(_ warmStart: WarmStart) {
        restoreTrueData()
        switch warmStart {
        case .none, .crash(.slack):
            resetBoundsToProblem()
            installSlackBasis()
        case .crash(.triangular):
            resetBoundsToProblem()
            triangularCrash()
        case .basis(let basis):
            loadBasis(basis)
        case .incremental(let parent, let changes):
            // The changes are the node's bounds relative to the engine's problem.
            resetBoundsToProblem()
            loadBasis(parent)
            applyBoundChanges(changes)
        case .primalPoint(let point):
            resetBoundsToProblem()
            crashFromPoint(point)
        }
    }

    // MARK: - Driver

    /// One engine run: prepares the start, runs the method, removes perturbations and maps
    /// every way of stopping to an outcome. Only `SolverError` is thrown.
    ///
    /// `face` and `faceDuals` are for crossover (§8.4): bound changes that hold a set of
    /// columns on the bounds an interior-point solution says they rest on, and that solution's
    /// row duals. The method first runs with the face in place, which ends on a vertex of it;
    /// the duals are then pushed onto that vertex's basis (`pushDuals`); the run on the
    /// engine's real bounds that follows decides the answer whatever the first two did.
    package mutating func run(
        method: Simplex.Method, warmStart: WarmStart, cutoff: Double?, iterationLimit: Int?,
        gate: inout WorkGate, face: [BoundChange] = [], faceDuals: [Double]? = nil
    ) async throws -> SimplexOutcome {
        iterations = 0
        phase1Iterations = 0
        refactorizations = 0
        consecutiveResidualFailures = 0
        blandRemaining = 0
        fragilePivots = 0
        warnings.removeAll()
        lastPrimalRay = nil
        lastDualRay = nil
        clearTaboo()
        lastMethod = method
        let cap = Swift.min(iterationLimit ?? Int.max, config.iterationCap(rows: m, columns: n))
        let runStarted = Deadline.now
        defer { lastRunSeconds = secondsSince(runStarted) }
        prepare(warmStart)

        do {
            if !face.isEmpty {
                applyFace(face)
                // Whatever this pass concludes — a vertex of the face, or that the face was
                // misidentified — the pass on the real bounds below decides the answer.
                let onFace = try await drive(method: method, cutoff: nil, cap: cap, gate: &gate)
                resetBoundsToProblem()
                if onFace == .optimal, let faceDuals {
                    try await pushDuals(faceDuals, iterationLimit: cap, gate: &gate)
                }
            }
            let status = try await drive(method: method, cutoff: cutoff, cap: cap, gate: &gate)
            // A whole solve (no cutoff, no iteration budget of a caller that solves many related
            // problems) ends with a second look at tighter tolerances.
            if status == .optimal, cutoff == nil, iterationLimit == nil, !faults.skipRefinement {
                try await refine(gate: &gate)
            }
            return conclude(status)
        } catch let signal as StopSignal {
            return conclude(.stopped(signal))
        } catch let failure as EngineFailure {
            guard case .numerical(let message) = failure else {
                throw SolverError.internalInconsistency("unexpected engine failure")
            }
            return conclude(.numericalFailure(message))
        } catch let error as SolverError {
            throw error
        } catch {
            throw SolverError.internalInconsistency("\(error)")
        }
    }

    /// Runs the requested method, with dual phase 1 when the start is not dual feasible, then
    /// removes any perturbation and lets the other method clean up (at most 500 iterations).
    mutating func drive(
        method: Simplex.Method, cutoff: Double?, cap: Int, gate: inout WorkGate
    ) async throws -> SimplexOutcome.Status {
        var status: SimplexOutcome.Status
        switch method {
        case .primal:
            status = try await runPrimal(iterationLimit: cap, gate: &gate)
        case .dual:
            status = try await runDualFromAnyStart(cutoff: cutoff, cap: cap, gate: &gate)
        }

        guard status == .optimal else { return status }

        // Bounds were perturbed by the primal method: the basis is dual feasible for the true
        // costs, so the dual method repairs whatever the true bounds make infeasible.
        if boundsPerturbed {
            removeBoundPerturbation()
            if primalInfeasibility().max > 0 {
                let cleaned = try await runDual(iterationLimit: iterations + faults.cleanupIterationLimit, cutoff: nil, gate: &gate)
                if cleaned == .iterationLimit {
                    throw EngineFailure.numerical("the clean-up after bound perturbation exceeded \(faults.cleanupIterationLimit) iterations")
                }
                status = cleaned
            }
        }
        // Costs were perturbed (or shifted) by the dual method: the basis is primal feasible,
        // so the primal method repairs whatever the true costs make dual infeasible.
        if costsPerturbed, status == .optimal {
            await removeCostPerturbation()
            if dualInfeasibility() > tol.dualFeasibility {
                let cleaned = try await runPrimalCleanup(iterationLimit: iterations + faults.cleanupIterationLimit, gate: &gate)
                if cleaned == .iterationLimit {
                    throw EngineFailure.numerical("the clean-up after cost perturbation exceeded \(faults.cleanupIterationLimit) iterations")
                }
                status = cleaned
            }
        }
        return status
    }

    // MARK: - Refinement

    /// The feasibility tolerance the refinement pass aims for, on the scaled problem: three
    /// decades under the default tolerance.
    static var refinedTolerance: Double { 1e-10 }

    /// How far above unit roundoff, relative to the size of the terms it is computed from, a
    /// violation must lie to count as a property of the vertex and not of its arithmetic.
    static var refinementNoiseFactor: Double { 1e4 }

    /// The largest sum of magnitudes a basic value (per row: Σ|a_ij·x_j| and the logical) and
    /// a reduced cost (per nonbasic column: |c_j| + Σ|a_ij·y_i|) are computed from. Rounding
    /// leaves errors proportional to these in a recomputed vertex.
    func refinementScales() -> (primal: Double, dual: Double) {
        var rowTerms = [Double](repeating: 0, count: m)
        var dualScale = 0.0
        let a = lp.a
        for j in 0..<n {
            let xj = Swift.abs(x[j])
            var terms = Swift.abs(cost[j])
            for p in a.colStart[j]..<a.colStart[j + 1] {
                let i = Int(a.rowIndex[p])
                let magnitude = Swift.abs(a.values[p])
                rowTerms[i] += magnitude * xj
                terms += magnitude * Swift.abs(y[i])
            }
            if pos[j] < 0, terms > dualScale { dualScale = terms }
        }
        var primalScale = 0.0
        for i in 0..<m {
            let terms = rowTerms[i] + Swift.abs(x[n + i])
            if terms > primalScale { primalScale = terms }
            if pos[n + i] < 0 {
                let logical = Swift.abs(cost[n + i]) + Swift.abs(y[i])
                if logical > dualScale { dualScale = logical }
            }
        }
        return (primalScale, dualScale)
    }

    /// A second look at an optimal basis, at tolerances near what double precision supports.
    ///
    /// "Optimal" means that no bound and no reduced-cost sign is violated by more than the
    /// tolerances. On an ill-conditioned problem that is true of several neighbouring bases
    /// whose vertices lie far apart: the residual that tells them apart is smaller than the
    /// tolerance. (The 8 × 8 Hilbert matrix as an equality system is the textbook case: with
    /// seven of its eight columns basic every row holds to 2e-10, at a point whose distance
    /// from the only solution is 1.) So when the recomputed vertex still shows a violation
    /// that stands clear of rounding — above `refinedTolerance`, and above
    /// `refinementNoiseFactor` units of roundoff on the terms it was computed from — the
    /// method goes on with the tolerances lowered to that level, and with pivots down to the
    /// same relative size allowed, for a bounded number of pivots.
    ///
    /// The pass can only replace an optimal answer by a better one. If it ends in anything
    /// but an optimal basis — a limit, a stop signal, a numerical failure, or a verdict of
    /// infeasible or unbounded, which at these tolerances is not to be trusted — the engine
    /// returns to the basis it started from, and that answer stands.
    mutating func refine(gate: inout WorkGate) async throws {
        let target = Self.refinedTolerance
        guard tol.primalFeasibility > target || tol.dualFeasibility > target, m > 0 else { return }
        // The verdict was reached on a fresh factorization; if not, make it one, so that what
        // is measured below is the vertex and not the drift of the updates.
        if !hasFactor || factor.updatesSinceRefactor > 0 {
            try refactorize()
            computePrimals()
            await computeDualsAsync()
        }
        let scales = refinementScales()
        let roundoff = Self.refinementNoiseFactor * Double.ulpOfOne
        let strict = Tolerances.refined(
            from: tol, primal: Swift.max(target, roundoff * scales.primal),
            dual: Swift.max(target, roundoff * scales.dual), pivot: target)
        guard strict.primalFeasibility < tol.primalFeasibility || strict.dualFeasibility < tol.dualFeasibility else {
            await warnIfIllConditioned()
            return
        }
        let entry = tol
        tol = strict
        let primalViolation = primalInfeasibility().max
        let dualViolation = dualInfeasibility()
        guard primalViolation > 0 || dualViolation > strict.dualFeasibility else {
            // Optimal at the tighter tolerances as well: the usual case.
            tol = entry
            await warnIfIllConditioned()
            return
        }

        let start = Basis(status: status, basic: head)
        let startX = x
        let startMethod = lastMethod
        let savedSuppression = suppressPerturbation
        suppressPerturbation = true
        var accepted = false
        do {
            let budget = iterations + (faults.refinementIterationLimit ?? Swift.min(500, Swift.max(50, 2 * m)))
            // Dual feasible: the dual method repairs the bounds. Otherwise the primal method,
            // whose composite phase 1 takes any start.
            let method: Simplex.Method = dualViolation <= strict.dualFeasibility ? .dual : .primal
            let status = try await drive(method: method, cutoff: nil, cap: budget, gate: &gate)
            accepted = status == .optimal
        } catch {
            // A stop signal or a numerical failure inside the pass does not undo the answer
            // the run already has.
            accepted = false
        }
        tol = entry
        suppressPerturbation = savedSuppression
        lastMethod = startMethod
        lastPrimalRay = nil
        lastDualRay = nil

        if accepted {
            var moved = 0.0
            for j in 0..<n { moved = Swift.max(moved, Swift.abs(x[j] - startX[j]) / (1 + Swift.abs(startX[j]))) }
            if moved > 1e-6 {
                await warn(
                    "the first optimal basis was optimal only within the tolerances; pivoting on at tolerance "
                        + "\(Swift.min(strict.primalFeasibility, strict.dualFeasibility)) moved the solution by up to \(moved) "
                        + "(relative, scaled problem): the problem is ill-conditioned or has alternative optima")
            }
        } else {
            // Back to the basis the run had proved optimal.
            restoreTrueData()
            loadBasis(start)
            if !hasFactor { try refactorize() }
            computePrimals()
            await computeDualsAsync()
            let remaining = Swift.max(primalViolation, dualViolation)
            if remaining > 10 * Swift.max(strict.primalFeasibility, strict.dualFeasibility) {
                await warn(
                    "the solution is optimal within the tolerances, but a violation of \(remaining) remains that pivoting at "
                        + "tighter tolerances could not remove: the problem is ill-conditioned")
            }
        }
        await warnIfIllConditioned()
    }

    /// Says so when the optimal basis is too ill-conditioned for the values to be accurate to
    /// the tolerance: an error of about κ·ε in the basic variables.
    mutating func warnIfIllConditioned() async {
        guard hasFactor, factor.updatesSinceRefactor == 0, let kappa = factor.conditionEstimate(), kappa.isFinite else { return }
        guard kappa * Double.ulpOfOne * 10 > tol.primalFeasibility else { return }
        await warn(
            "the optimal basis is ill-conditioned (condition estimate \(kappa)): the values may be wrong by about "
                + "\(kappa * Double.ulpOfOne) relative")
    }

    /// The primal method as a clean-up pass: no new perturbation may start inside it, or the
    /// clean-up would never end (rule L6).
    mutating func runPrimalCleanup(iterationLimit: Int, gate: inout WorkGate) async throws -> SimplexOutcome.Status {
        let saved = suppressPerturbation
        suppressPerturbation = true
        defer { suppressPerturbation = saved }
        let status = try await runPrimal(iterationLimit: iterationLimit, gate: &gate)
        if boundsPerturbed { removeBoundPerturbation() }
        return status
    }

    /// The dual method from a start that need not be dual feasible.
    ///
    /// Boxed columns flip to the bound their reduced cost wants. If that is not enough and
    /// the start is primal feasible, the primal method takes over (it needs no phase 1).
    /// Otherwise dual phase 1 boxes the offending columns at ±1e6, the dual method runs, the
    /// artificial bounds are removed, and the primal method cleans up.
    mutating func runDualFromAnyStart(cutoff: Double?, cap: Int, gate: inout WorkGate) async throws -> SimplexOutcome.Status {
        if !hasFactor { try refactorize() }
        computePrimals()
        await computeDualsAsync()
        phase1Pricing = false
        let restored = restoreDualFeasibilityByFlipping()
        if restored.flipped { computePrimals() }
        if restored.remaining <= tol.dualFeasibility {
            return try await runDual(iterationLimit: cap, cutoff: cutoff, gate: &gate)
        }
        if primalInfeasibility().max == 0 {
            return try await runPrimal(iterationLimit: cap, gate: &gate)
        }
        installArtificialBounds()
        let boxed = try await runDual(iterationLimit: cap, cutoff: nil, gate: &gate)
        removeArtificialBounds()
        if costsPerturbed {
            cost = trueCost
            costsPerturbed = false
        }
        switch boxed {
        case .optimal, .infeasible:
            // "Infeasible inside the box" proves nothing about the real problem; the primal
            // method decides, and usually needs only a few iterations.
            return try await runPrimal(iterationLimit: cap, gate: &gate)
        default:
            return boxed
        }
    }

    /// Leaves the engine on true data and packs the final state.
    mutating func conclude(_ status: SimplexOutcome.Status) -> SimplexOutcome {
        if boundsPerturbed || artificialBounds || costsPerturbed {
            restoreTrueData()
            if hasFactor { computePrimals() }
        }
        let primalFeasible: Bool
        switch status {
        case .optimal, .unbounded: primalFeasible = true
        case .infeasible, .numericalFailure: primalFeasible = false
        default: primalFeasible = hasFactor && primalInfeasibility().max == 0 && boundsRespected()
        }
        let dualFeasible: Bool
        switch status {
        case .optimal: dualFeasible = true
        case .cutoff: dualFeasible = true
        case .iterationLimit, .stopped:
            // The dual method keeps its basis dual feasible throughout; the primal method
            // only reaches that at optimality.
            dualFeasible = lastMethod == .dual && !phase1Pricing && dualInfeasibility() <= tol.dualFeasibility
        default: dualFeasible = false
        }
        let outcome = makeOutcome(status, dualFeasible: dualFeasible, primalFeasible: primalFeasible)
        lastOutcome = outcome
        return outcome
    }

    /// Whether every nonbasic column sits within its true bounds (it does unless a run was
    /// interrupted in an unusual state).
    func boundsRespected() -> Bool {
        let feasibility = tol.primalFeasibility
        for j in 0..<total where pos[j] < 0 {
            if x[j] < trueLower[j] - feasibility || x[j] > trueUpper[j] + feasibility { return false }
        }
        return true
    }
}
