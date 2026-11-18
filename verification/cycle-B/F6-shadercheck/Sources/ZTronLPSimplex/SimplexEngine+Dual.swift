// Dual iteration (specification §7.2).
//
// 1. Row selection. The leaving row r maximizes infeasibility_r² / w_r with dual
//    steepest-edge (DSE) weights; for the all-logical starting basis the weights are exact.
// 2. Pivot row. ρ_r = B⁻ᵀe_r (BTRAN), then α_r = ρ_rᵀA_N through aT.
// 3. Dual ratio test with bound flipping (long step): sort breakpoints, flip boxed nonbasics
//    while the dual slope stays positive, then apply the Harris two-pass to pick the entering
//    column among the remaining candidates. Flipped columns are applied in one FTRAN.
// 4. Update. FTRAN of the entering column, x_B update, d_N update from α_r, DSE weight update
//    (one extra FTRAN of ρ_r), eta update.
// 5. Termination. No primal-infeasible row → optimal. Infeasible row with no eligible
//    entering column → primal infeasible, with ρ_r as the dual ray.
//
// Dual phase 1 uses artificial bounds: free and one-sided nonbasics are temporarily boxed at
// ±1e6, the dual method runs, the artificial bounds are removed, and any resulting primal
// infeasibility is cleaned up by the primal method.

import ZTronLPCore
import ZTronLPNumerics

extension SimplexEngine {
    /// The magnitude of the artificial bounds of dual phase 1, in the scaled problem.
    static var artificialBound: Double { 1e6 }

    // MARK: - Dual feasibility

    /// Makes the basis dual feasible where a bound flip can do it: a boxed nonbasic whose
    /// reduced cost has the wrong sign moves to its other bound. Returns the largest dual
    /// infeasibility left on columns a flip cannot fix. `x_B` is stale afterwards when
    /// anything was flipped (the return value's `flipped`).
    mutating func restoreDualFeasibilityByFlipping() -> (remaining: Double, flipped: Bool) {
        let tolerance = tol.dualFeasibility
        var remaining = 0.0
        var flipped = false
        for j in 0..<total where pos[j] < 0 {
            let dj = d[j]
            switch status[j] {
            case .atLower where dj < -tolerance:
                if upper[j] < .infinity {
                    status[j] = .atUpper
                    basisHash ^= upperToken(j)
                    placeNonbasic(j)
                    flipped = true
                } else {
                    remaining = Swift.max(remaining, -dj)
                }
            case .atUpper where dj > tolerance:
                if lower[j] > -.infinity {
                    basisHash ^= upperToken(j)
                    status[j] = .atLower
                    placeNonbasic(j)
                    flipped = true
                } else {
                    remaining = Swift.max(remaining, dj)
                }
            case .free where Swift.abs(dj) > tolerance:
                remaining = Swift.max(remaining, Swift.abs(dj))
            default:
                break
            }
        }
        return (remaining, flipped)
    }

    /// Dual phase 1: boxes every nonbasic column that lacks a finite bound at ±1e6 and puts
    /// each nonbasic on the side its reduced cost asks for. The basis is then dual feasible.
    mutating func installArtificialBounds() {
        let big = Self.artificialBound
        for j in 0..<total where pos[j] < 0 {
            if lower[j] == -.infinity { lower[j] = Swift.min(-big, upper[j] - 1) }
            if upper[j] == .infinity { upper[j] = Swift.max(big, lower[j] + 1) }
            let before = status[j]
            let after: BasisStatus = lower[j] == upper[j] ? .fixed : (d[j] >= 0 ? .atLower : .atUpper)
            if before == .atUpper { basisHash ^= upperToken(j) }
            status[j] = after
            if after == .atUpper { basisHash ^= upperToken(j) }
            placeNonbasic(j)
        }
        artificialBounds = true
    }

    /// Removes the artificial bounds. A nonbasic column resting on one moves to a real bound
    /// (or to zero when it has none); the primal method then removes whatever infeasibility
    /// that causes.
    mutating func removeArtificialBounds() {
        guard artificialBounds else { return }
        for j in 0..<total {
            lower[j] = trueLower[j]
            upper[j] = trueUpper[j]
        }
        for j in 0..<total where pos[j] < 0 {
            let before = status[j]
            let after = nonbasicStatus(j, preferred: before)
            if before == .atUpper { basisHash ^= upperToken(j) }
            status[j] = after
            if after == .atUpper { basisHash ^= upperToken(j) }
            placeNonbasic(j)
        }
        artificialBounds = false
    }

    /// Perturbs the costs of the nonbasic columns by a random relative 1e-6, each in the
    /// direction that keeps its reduced cost dual feasible. Removed at optimality; the primal
    /// method cleans up what the removal leaves dual infeasible.
    mutating func perturbCosts() {
        for j in 0..<total where pos[j] < 0 {
            let amount = 1e-6 * (1 + Swift.abs(cost[j])) * (0.5 + 0.5 * nextRandom())
            switch status[j] {
            case .atLower:
                cost[j] += amount
                d[j] += amount
            case .atUpper:
                cost[j] -= amount
                d[j] -= amount
            default:
                break
            }
        }
        costsPerturbed = true
    }

    /// Restores the true costs.
    mutating func removeCostPerturbation() async {
        guard costsPerturbed else { return }
        cost = trueCost
        costsPerturbed = false
        await computeDualsAsync()
    }

    // MARK: - The dual loop

    /// Runs the dual method from the current basis, which must be dual feasible (after
    /// flips). Returns `.optimal`, `.infeasible`, `.cutoff` or `.iterationLimit`.
    mutating func runDual(iterationLimit: Int, cutoff: Double?, gate: inout WorkGate) async throws -> SimplexOutcome.Status {
        lastMethod = .dual
        if !hasFactor { try refactorize() }
        computePrimals()
        await computeDualsAsync()
        phase1Pricing = false
        if restoreDualFeasibilityByFlipping().flipped { computePrimals() }
        if config.perturbation == .always && !costsPerturbed { perturbCosts() }
        var verifications = 0
        var forceRefactor = false
        var shifts = 0
        bestProgressValue = -.infinity
        lastProgressIteration = iterations
        clearCycleHistory()
        var rejectedRows = [Bool](repeating: false, count: m)
        var rejectedCount = 0

        while true {
            try await gate.tick()
            if iterations >= iterationLimit { return .iterationLimit }

            if forceRefactor || !hasFactor || factor.needsRefactor {
                forceRefactor = false
                try refactorize()
                computePrimals()
                _ = try checkResidual()
                await computeDualsAsync()
                // Drift can leave a reduced cost on the wrong side. A boxed column flips; any
                // other one has its cost shifted so that d_j = 0, which is a perturbation and
                // is cleaned up like one.
                if restoreDualFeasibilityByFlipping().flipped { computePrimals() }
                shifts += shiftCostsToDualFeasibility()
            } else if iterationsSinceResidualCheck >= 50 {
                if try checkResidual() {
                    await computeDualsAsync()
                    if restoreDualFeasibilityByFlipping().flipped { computePrimals() }
                    shifts += shiftCostsToDualFeasibility()
                }
            }

            // The dual objective only grows; once it reaches the cutoff the node is done.
            if let cutoff, !costsPerturbed, !artificialBounds, objectiveValue() >= cutoff {
                return .cutoff
            }

            // 1. Leaving row: largest infeasibility² / weight.
            var r = -1
            var bestScore = 0.0
            var infeasibilitySum = 0.0
            let feasibility = tol.primalFeasibility
            for k in 0..<m {
                let j = Int(head[k])
                let v = x[j]
                let violation = Swift.max(lower[j] - v, v - upper[j])
                if violation <= feasibility { continue }
                infeasibilitySum += violation
                if rejectedRows[k] { continue }
                let score = violation * violation / dse[k]
                if blandRemaining > 0 {
                    if r < 0 || j < Int(head[r]) { r = k }
                } else if score > bestScore {
                    bestScore = score
                    r = k
                }
            }
            await report(phase: 2, infeasibility: infeasibilitySum)
            if r < 0 {
                if factor.updatesSinceRefactor > 0 && verifications < 8 {
                    verifications += 1
                    forceRefactor = true
                    continue
                }
                if rejectedCount > 0 {
                    // Rows whose pivot was numerically unusable are still infeasible.
                    if verifications < 12 {
                        verifications += 1
                        for k in 0..<m { rejectedRows[k] = false }
                        rejectedCount = 0
                        forceRefactor = true
                        continue
                    }
                    throw EngineFailure.numerical("the dual method found no stable pivot for an infeasible row")
                }
                return .optimal
            }

            let p = Int(head[r])
            let below = x[p] < lower[p]
            // The leaving variable must move by `gap` to reach the bound it violates.
            var gap = below ? lower[p] - x[p] : x[p] - upper[p]
            // s orients the pivot row so that a candidate at its lower bound has a positive entry.
            let s: Double = below ? -1 : 1

            // 2. Pivot row.
            await computePivotRow(r)

            // 3. Ratio test with bound flipping.
            struct Candidate {
                var column: Int32
                var entry: Double      // s·α_rj, signed
                var ratio: Double
            }
            var candidates: [Candidate] = []
            var rowMax = 0.0
            func consider(_ j: Int) {
                guard pos[j] < 0 else { return }
                let entry = s * rowAlpha[j]
                let magnitude = Swift.abs(entry)
                if magnitude > rowMax { rowMax = magnitude }
                switch status[j] {
                case .atLower where entry > 0:
                    candidates.append(Candidate(column: Int32(j), entry: entry, ratio: Swift.max(d[j], 0) / entry))
                case .atUpper where entry < 0:
                    candidates.append(Candidate(column: Int32(j), entry: entry, ratio: Swift.min(d[j], 0) / entry))
                case .free where entry != 0:
                    candidates.append(Candidate(column: Int32(j), entry: entry, ratio: 0))
                default:
                    break
                }
            }
            if rowIsSparse {
                for j in rowTouched { consider(Int(j)) }
            } else {
                for j in 0..<total { consider(j) }
            }
            let pivotTolerance = Swift.max(tol.pivot * rowMax, 1e-12)
            // Entries too small for a stable pivot are set aside, not forgotten: a row that no
            // usable entry can repair proves infeasibility only if no entry can.
            var fragile = false
            if !candidates.contains(where: { Swift.abs($0.entry) > pivotTolerance }) {
                // Dual unbounded, as far as usable pivots go.
                if factor.updatesSinceRefactor > 0 && verifications < 8 {
                    verifications += 1
                    forceRefactor = true
                    continue
                }
                let floor = Swift.max(Self.fragilePivotFactor * pivotTolerance, 1e-12)
                candidates.removeAll { Swift.abs($0.entry) <= floor }
                if candidates.isEmpty {
                    // The row cannot be repaired by any nonbasic column.
                    lastDualRay = farkasRay(from: rho)
                    return .infeasible
                }
                // A column with a small entry can still repair the row. Calling the problem
                // infeasible would be wrong, so the pivot is taken, and the factorization is
                // rebuilt right after it.
                if fragilePivots >= fragilePivotLimit {
                    throw EngineFailure.numerical(
                        "the dual method found only pivots below the pivot tolerance for an infeasible row, \(fragilePivots) times")
                }
                fragile = true
            } else {
                candidates.removeAll { Swift.abs($0.entry) <= pivotTolerance }
            }
            candidates.sort { $0.ratio < $1.ratio }

            // Long step: pass breakpoints of boxed columns while the leaving variable would
            // still be infeasible after they flip.
            var firstRemaining = 0
            var flips: [Int32] = []
            while firstRemaining < candidates.count - 1 {
                let candidate = candidates[firstRemaining]
                let j = Int(candidate.column)
                let range = upper[j] - lower[j]
                guard status[j] != .free, range < .infinity else { break }
                let reduction = Swift.abs(candidate.entry) * range
                if gap - reduction <= feasibility { break }
                gap -= reduction
                flips.append(candidate.column)
                firstRemaining += 1
            }

            // Harris two-pass among the remaining candidates.
            let dualTolerance = tol.dualFeasibility
            var ratioMax = Double.infinity
            for k in firstRemaining..<candidates.count {
                let limit = candidates[k].ratio + dualTolerance / Swift.abs(candidates[k].entry)
                if limit < ratioMax { ratioMax = limit }
            }
            var chosen = -1
            var bestMagnitude = 0.0
            for k in firstRemaining..<candidates.count where candidates[k].ratio <= ratioMax {
                let magnitude = Swift.abs(candidates[k].entry)
                if blandRemaining > 0 {
                    if chosen < 0 || candidates[k].column < candidates[chosen].column { chosen = k }
                } else if magnitude > bestMagnitude {
                    bestMagnitude = magnitude
                    chosen = k
                }
            }
            if chosen < 0 { chosen = firstRemaining }
            let q = Int(candidates[chosen].column)

            // 4. FTRAN of the entering column and the consistency check on the pivot element.
            ftranColumn(q)
            let alphaR = alpha[r]
            // A small pivot must be well determined: the two computations agree on its digits.
            let agreement = fragile ? 1e-3 * Swift.abs(alphaR) : 1e-6 * (1 + Swift.abs(alphaR))
            if Swift.abs(alphaR) < 1e-11 || Swift.abs(alphaR - rowAlpha[q]) > agreement {
                if factor.updatesSinceRefactor > 0 {
                    forceRefactor = true
                } else {
                    // A fresh factorization disagrees with itself on this row: skip the row
                    // for now and come back to it after other pivots.
                    if !rejectedRows[r] {
                        rejectedRows[r] = true
                        rejectedCount += 1
                    }
                }
                continue
            }

            // Flipped columns: one FTRAN of A_F·Δx_F updates the basic values.
            if !flips.isEmpty {
                for i in 0..<m { work[i] = 0 }
                for column in flips {
                    let j = Int(column)
                    let delta = status[j] == .atLower ? upper[j] - lower[j] : lower[j] - upper[j]
                    if j < n {
                        lp.a.axpy(column: j, delta, into: &work)
                    } else {
                        work[j - n] -= delta
                    }
                    basisHash ^= upperToken(j)
                    status[j] = status[j] == .atLower ? .atUpper : .atLower
                    placeNonbasic(j)
                }
                factor.ftran(&work)
                for k in 0..<m { x[Int(head[k])] -= work[k] }
            }

            // Primal step: the leaving variable lands exactly on the bound it violated.
            let target = below ? lower[p] : upper[p]
            let thetaP = (x[p] - target) / alphaR
            if thetaP != 0 {
                for i in 0..<m where alpha[i] != 0 { x[Int(head[i])] -= thetaP * alpha[i] }
                x[q] += thetaP
            }
            x[p] = target

            // DSE weights: w_r is known exactly as ‖ρ‖²; the others need τ = B⁻¹ρ.
            var exactWeight = 0.0
            for i in 0..<m { exactWeight += rho[i] * rho[i] }
            for i in 0..<m { tau[i] = rho[i] }
            factor.ftran(&tau)
            // w_i ← max(w_i − 2κ_iτ_i + κ_i²·w_r, 1e-4) with κ = α/α_r, vectorized through
            // vDSP (§7.5); position r is overwritten with its exact value afterwards.
            Vec.scaledAdd(1 / alphaR, alpha, plus: zeros, into: &work)          // κ
            Vec.multiply(work, tau, into: &tau)                                 // κ ⊙ τ
            Vec.addScaled(-2, tau, to: &dse)
            Vec.multiply(work, work, into: &work)                               // κ²
            Vec.addScaled(exactWeight, work, to: &dse)
            Vec.clip(dse, low: 1e-4, high: .greatestFiniteMagnitude, into: &dse)
            dse[r] = Swift.max(exactWeight / (alphaR * alphaR), 1e-4)

            // Dual step and basis exchange.
            updateDuals(q: q, r: r, leaving: p)
            if !exchange(q: q, r: r, leavingStatus: below ? .atLower : .atUpper) { forceRefactor = true }
            iterations += 1
            iterationsSinceResidualCheck += 1
            if rejectedCount > 0 {
                for k in 0..<m { rejectedRows[k] = false }
                rejectedCount = 0
            }
            if blandRemaining > 0 { blandRemaining -= 1 }
            if Swift.abs(alphaR) < 1e-7 { iterationsSinceResidualCheck = 50 }
            if fragile {
                fragilePivots += 1
                forceRefactor = true
            }

            if noteBasisAndDetectCycle() && blandRemaining == 0 {
                blandRemaining = 50
                forceRefactor = true
                clearCycleHistory()
            }

            // Stall detection, every 100 iterations: the dual objective should keep growing.
            if iterations % 100 == 0 {
                let progress = objectiveValue()
                if progress > bestProgressValue + 1e-9 * (1 + Swift.abs(bestProgressValue)) {
                    bestProgressValue = progress
                    lastProgressIteration = iterations
                } else if iterations - lastProgressIteration >= 1_000, config.perturbation == .onStall,
                          !costsPerturbed, degeneracyFraction() > 0.3 {
                    perturbCosts()
                    lastProgressIteration = iterations
                }
            }
            if shifts > 0 { costsPerturbed = true }
        }
    }

    /// Shifts the cost of every nonbasic column whose reduced cost is on the wrong side (and
    /// cannot be fixed by a flip) so that the reduced cost becomes zero. Returns how many
    /// costs were shifted.
    mutating func shiftCostsToDualFeasibility() -> Int {
        let tolerance = tol.dualFeasibility
        var shifted = 0
        for j in 0..<total where pos[j] < 0 {
            let dj = d[j]
            var wrong = false
            switch status[j] {
            case .atLower: wrong = dj < -tolerance
            case .atUpper: wrong = dj > tolerance
            case .free: wrong = Swift.abs(dj) > tolerance
            default: break
            }
            if wrong {
                cost[j] -= dj
                d[j] = 0
                shifted += 1
            }
        }
        if shifted > 0 { costsPerturbed = true }
        return shifted
    }
}
