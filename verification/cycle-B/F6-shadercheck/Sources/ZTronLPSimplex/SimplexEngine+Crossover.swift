// Crossover support (specification §8.4).
//
// An interior-point method ends in the middle of the optimal face, with duals in the middle of
// the dual optimal face. Crossover-lite turns that into a vertex and a basis in three steps,
// all on this engine:
//
// 1. The crash from the primal point (`crashFromPoint`), with the columns the duals pin to a
//    bound held there (`applyFace`). Phase 1 then ends on a vertex of the optimal face.
// 2. The dual push (`pushDuals`). On a degenerate problem the basis of that vertex contains
//    held columns, and its own duals are not the interior-point duals: they can be far from
//    dual feasible, and repairing them by primal pivots costs one degenerate pivot after the
//    other. The interior-point duals are feasible already, so they are moved towards the
//    duals of the basis in a straight line instead; each time a nonbasic reduced cost reaches
//    zero on the way, that column replaces a held one in the basis and the line is redrawn.
// 3. The method on the real bounds, which finds nothing left to do when 1 and 2 went well and
//    is still correct when they did not.

import ZTronLPCore
import ZTronLPNumerics

extension SimplexEngine {
    /// Holds columns of [A −I] on the given bounds (unscaled): structural columns by their
    /// index, the logical of row i as n + i.
    mutating func applyFace(_ changes: [BoundChange]) {
        for change in changes {
            let j = Int(change.column)
            guard j >= 0, j < total else { continue }
            if j < n {
                let scale = lp.scaling?.columns[j] ?? 1
                setTrueBounds(column: j, lower: change.lower / scale, upper: change.upper / scale)
            } else {
                let scale = lp.scaling?.rows[j - n] ?? 1
                setTrueBounds(column: j, lower: change.lower * scale, upper: change.upper * scale)
            }
        }
    }

    /// Moves a dual-feasible point onto the current basis, which must be primal feasible.
    ///
    /// `duals` are row duals (unscaled) under which every nonbasic column has a reduced cost
    /// of the right sign, but under which basic columns may have a nonzero one, δ — which is
    /// what keeps them from being the duals of the basis. The duals of the basis are
    /// y + B⁻ᵀδ, and the straight line towards them shrinks every δ at the same rate. If the
    /// whole line is dual feasible, the basis is optimal as it stands. Otherwise the line
    /// stops where a nonbasic column's reduced cost reaches zero: that column enters the
    /// basis, and a basic column with δ ≠ 0 that the entering column depends on leaves it, on
    /// the bound it rests on. The vertex does not move, dual feasibility is never lost, and
    /// the basis holds one column with δ ≠ 0 less — so there is at most one pivot per such
    /// column, against the unbounded number of degenerate pivots the primal method may need
    /// for the same repair.
    ///
    /// Only columns that can leave without moving the vertex take part (they sit on the bound
    /// their reduced cost asks for, or are fixed). Whatever is left — columns that could not
    /// take part, drift, duals that were not feasible after all — is for the run that
    /// follows; the push changes the basis and nothing else, so it cannot do harm.
    mutating func pushDuals(_ duals: [Double], iterationLimit: Int, gate: inout WorkGate) async throws {
        guard duals.count == m, m > 0 else { return }
        if costsPerturbed || boundsPerturbed || artificialBounds { restoreTrueData() }
        if !hasFactor { try refactorize() }
        computePrimals()
        guard primalInfeasibility().max == 0 else { return }

        // The starting point: y, and the reduced cost of every column under it. The nonbasic
        // ones live in `d`, as everywhere else; noise on the wrong side counts as zero.
        if let rows = lp.scaling?.rows {
            for i in 0..<m { y[i] = duals[i] / rows[i] }
        } else {
            for i in 0..<m { y[i] = duals[i] }
        }
        let dualTolerance = tol.dualFeasibility
        let feasibility = tol.primalFeasibility
        // δ by basis position, for the columns that take part.
        var residual = [Double](repeating: 0, count: m)
        var remaining = 0
        for j in 0..<total {
            let value = j < n ? cost[j] - lp.a.dot(column: j, y) : cost[j] + y[j - n]
            let position = Int(pos[j])
            if position < 0 {
                switch status[j] {
                case .atLower: d[j] = Swift.max(value, 0)
                case .atUpper: d[j] = Swift.min(value, 0)
                case .free: d[j] = 0
                default: d[j] = value
                }
                continue
            }
            d[j] = 0
            guard Swift.abs(value) > dualTolerance else { continue }
            // Can j leave the basis where it is? Only from the bound its reduced cost asks for.
            let leaves = lower[j] == upper[j]
                || (value > 0 && Swift.abs(x[j] - lower[j]) <= feasibility * (1 + Swift.abs(lower[j])))
                || (value < 0 && Swift.abs(x[j] - upper[j]) <= feasibility * (1 + Swift.abs(upper[j])))
            if leaves {
                residual[position] = value
                remaining += 1
            }
        }

        while remaining > 0 {
            try await gate.tick()
            if iterations >= iterationLimit { break }
            if factor.needsRefactor || !hasFactor {
                let before = basisHash
                try refactorize()
                // A repaired basis is not the one these duals were being moved onto.
                if basisHash != before { break }
            }

            // The direction: w = B⁻ᵀδ, and g = wᵀ[A −I] for the nonbasic reduced costs, which
            // move as d − θ·g while δ shrinks as (1 − θ)·δ.
            for i in 0..<m { rho[i] = residual[i] }
            factor.btran(&rho)
            await computeRowProduct()

            // How far the line stays dual feasible: Harris two-pass, the largest entry among
            // the columns that stop it first.
            var limitMax = Double.infinity
            var rowMax = 0.0
            func ratio(_ j: Int) -> Double? {
                let g = rowAlpha[j]
                switch status[j] {
                case .atLower where g > 0: return d[j] / g
                case .atUpper where g < 0: return d[j] / g
                case .free where g != 0: return 0
                default: return nil
                }
            }
            func bound(_ j: Int) {
                guard pos[j] < 0 else { return }
                let magnitude = Swift.abs(rowAlpha[j])
                if magnitude > rowMax { rowMax = magnitude }
                guard let value = ratio(j) else { return }
                let limit = value + dualTolerance / magnitude
                if limit < limitMax { limitMax = limit }
            }
            if rowIsSparse {
                for j in rowTouched { bound(Int(j)) }
            } else {
                for j in 0..<total { bound(j) }
            }
            var entering = -1
            var enteringRatio = 0.0
            var bestMagnitude = 1e-9 * rowMax
            func choose(_ j: Int) {
                guard pos[j] < 0, let value = ratio(j), value <= limitMax else { return }
                let magnitude = Swift.abs(rowAlpha[j])
                if magnitude > bestMagnitude {
                    bestMagnitude = magnitude
                    entering = j
                    enteringRatio = value
                }
            }
            if limitMax < .infinity {
                if rowIsSparse {
                    for j in rowTouched { choose(Int(j)) }
                } else {
                    for j in 0..<total { choose(j) }
                }
            }

            // Within the tolerance the whole line may be feasible even if a column stops it.
            let theta = entering >= 0 && enteringRatio < 1 && limitMax < 1 ? Swift.max(enteringRatio, 0) : 1
            var leavingRow = -1
            if theta < 1 {
                // The leaving column: among the basic columns with δ ≠ 0 the entering column
                // leans on, the one that pulls its reduced cost down the hardest.
                ftranColumn(entering)
                var largest = 0.0
                for r in 0..<m where residual[r] != 0 { largest = Swift.max(largest, Swift.abs(alpha[r])) }
                let sign: Double = rowAlpha[entering] > 0 ? 1 : -1
                var best = -Double.infinity
                for r in 0..<m where residual[r] != 0 {
                    let magnitude = Swift.abs(alpha[r])
                    guard magnitude >= 0.1 * largest, magnitude > 1e-9 else { continue }
                    let pull = sign * residual[r] * alpha[r]
                    if pull > best {
                        best = pull
                        leavingRow = r
                    }
                }
                // No usable pivot: the line cannot be continued from here.
                if leavingRow < 0 { break }
            }

            // The move.
            if theta > 0 {
                func move(_ j: Int) {
                    guard pos[j] < 0 else { return }
                    var value = d[j] - theta * rowAlpha[j]
                    // What the Harris tolerance let through is noise.
                    switch status[j] {
                    case .atLower: if value < 0 { value = 0 }
                    case .atUpper: if value > 0 { value = 0 }
                    case .free: value = 0
                    default: break
                    }
                    d[j] = value
                }
                if rowIsSparse {
                    for j in rowTouched { move(Int(j)) }
                } else {
                    for j in 0..<total { move(j) }
                }
                for i in 0..<m where rho[i] != 0 { y[i] += theta * rho[i] }
                for r in 0..<m where residual[r] != 0 { residual[r] *= 1 - theta }
            }
            guard theta < 1 else {
                // The duals of the basis are dual feasible: nothing is left to push.
                remaining = 0
                break
            }

            // The exchange. The vertex stays where it is: the entering column joins the basis
            // on the bound it rests on, the leaving one stays on its own.
            let k = Int(head[leavingRow])
            let leavingStatus: BasisStatus = residual[leavingRow] > 0 ? .atLower : .atUpper
            d[entering] = 0
            d[k] = residual[leavingRow]
            residual[leavingRow] = 0
            remaining -= 1
            if !exchange(q: entering, r: leavingRow, leavingStatus: leavingStatus) {
                let before = basisHash
                try refactorize()
                if basisHash != before { break }
            }
            placeNonbasic(k)
            iterations += 1
            iterationsSinceResidualCheck += 1
        }

        // The run that follows starts from this basis with everything recomputed from it.
        for k in 0..<m { dse[k] = 1 }
        resetPricingWeights()
        clearPivotRow()
        if !hasFactor { try refactorize() }
        computePrimals()
    }
}
