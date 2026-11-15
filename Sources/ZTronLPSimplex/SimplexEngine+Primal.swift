// Primal iteration (specification §7.1) and the shared pricing and pivoting machinery.
//
// 1. Pricing. Reduced costs d_N are maintained, not recomputed: after each pivot they are
//    updated from the pivot row. The entering column q maximizes d_q² / w_q over eligible
//    nonbasics.
// 2. FTRAN. α = B⁻¹a_q.
// 3. Ratio test. Harris two-pass; a boxed entering variable whose step would exceed its range
//    flips bound and no pivot occurs.
// 4. Update. x_B −= θα, x_q += θ, eta update, weight update from the pivot row.
// 5. Termination. No eligible entering column → optimal. No blocking row and an unboxed
//    entering column → unbounded, with the primal ray (α, −1) as the certificate.
//
// Phase 1 is the composite method: the objective is the sum of bound infeasibilities, with
// cost −1 for x_j < l_j, +1 for x_j > u_j and 0 otherwise, re-evaluated every iteration; the
// ratio test lets a step pass through breakpoints while the infeasibility sum keeps
// decreasing. Phase 2 starts from the phase-1 basis without refactorization.

import ZTronLPCore
import ZTronLPNumerics

/// The outcome of a ratio test.
enum RatioStep {
    /// No blocking row and the entering column is not boxed.
    case unbounded
    /// The entering column reaches its opposite bound first; no basis change.
    case flip(theta: Double)
    /// The basic variable at position `r` leaves at its upper (`atUpper`) or lower bound.
    case pivot(r: Int, theta: Double, atUpper: Bool)
    /// No numerically acceptable pivot for this entering column.
    case blocked

    /// True when no entry above the pivot tolerance limited the step.
    var isBlockedOrUnbounded: Bool {
        switch self {
        case .blocked, .unbounded: return true
        default: return false
        }
    }
}

extension SimplexEngine {
    // MARK: - Reduced costs

    /// d_j = base_j − a_jᵀy for every nonbasic structural column, in parallel over column
    /// blocks above the thresholds of §7.5 (each child produces its own slice).
    mutating func priceStructurals(includeCosts: Bool) async {
        let parallel = n >= parallelColumns && lp.nnz >= parallelNonzeros && threads > 1 && budget != nil
        if parallel {
            let matrix = lp.a
            let vector = y
            let parts = await parallelBlocks(count: n, blocks: Swift.min(threads, 8), budget: budget) { range in
                matrix.multiplyTranspose(vector, columns: range)
            }
            var j = 0
            for part in parts {
                for value in part {
                    d[j] = pos[j] >= 0 ? 0 : (includeCosts ? cost[j] : 0) - value
                    j += 1
                }
            }
        } else {
            for j in 0..<n {
                d[j] = pos[j] >= 0 ? 0 : (includeCosts ? cost[j] : 0) - lp.a.dot(column: j, y)
            }
        }
        for i in 0..<m {
            d[n + i] = pos[n + i] >= 0 ? 0 : (includeCosts ? cost[n + i] : 0) + y[i]
        }
    }

    /// Phase-2 duals: y = B⁻ᵀc_B, then every reduced cost.
    mutating func computeDualsAsync() async {
        for k in 0..<m { work[k] = cost[Int(head[k])] }
        factor.btran(&work)
        for i in 0..<m { y[i] = work[i] }
        await priceStructurals(includeCosts: true)
    }

    /// Phase-1 duals for the composite objective: basic cost −1 below the lower bound, +1
    /// above the upper bound, 0 otherwise; nonbasic costs are zero.
    mutating func computePhase1Duals() async {
        let feasibility = tol.primalFeasibility
        for k in 0..<m {
            let j = Int(head[k])
            let v = x[j]
            work[k] = v < lower[j] - feasibility ? -1 : (v > upper[j] + feasibility ? 1 : 0)
        }
        factor.btran(&work)
        for i in 0..<m { y[i] = work[i] }
        await priceStructurals(includeCosts: false)
    }

    // MARK: - Pricing

    /// Whether nonbasic column j can improve the objective, and in which direction it moves.
    @inline(__always)
    func entryDirection(_ j: Int) -> Double {
        let dj = d[j]
        let tolerance = tol.dualFeasibility
        switch status[j] {
        case .atLower: return dj < -tolerance ? 1 : 0
        case .atUpper: return dj > tolerance ? -1 : 0
        case .free: return dj < -tolerance ? 1 : (dj > tolerance ? -1 : 0)
        default: return 0
        }
    }

    /// Chooses the entering column: the eligible nonbasic that maximizes d²/w (lowest index
    /// under Bland's rule). Returns nil when no column is eligible.
    mutating func chooseEntering() async -> (q: Int, sigma: Double)? {
        if blandRemaining > 0 {
            for j in 0..<total where pos[j] < 0 && !taboo[j] {
                let direction = entryDirection(j)
                if direction != 0 { return (j, direction) }
            }
            return nil
        }

        // The fp32 scan proposes structural candidates; the CPU verifies each in Double and
        // picks among them (§6.4). Logical columns are always priced on the CPU.
        if let candidate = await scanForEntering() { return candidate }

        var sections = 1
        if case .partial(let requested) = config.pricing, n > 50_000 { sections = Swift.max(1, requested) }
        var best = -1
        var bestScore = 0.0
        var bestDirection = 0.0
        if sections == 1 {
            for j in 0..<total where pos[j] < 0 && !taboo[j] {
                let direction = entryDirection(j)
                if direction == 0 { continue }
                let score = d[j] * d[j] / devex[j]
                if score > bestScore {
                    bestScore = score
                    best = j
                    bestDirection = direction
                }
            }
        } else {
            // One section per iteration; move on only when a section has no candidate, so
            // "no entering column" still means every column was scanned.
            for offset in 0..<sections {
                let section = (partialSection + offset) % sections
                let lo = total * section / sections
                let hi = total * (section + 1) / sections
                for j in lo..<hi where pos[j] < 0 && !taboo[j] {
                    let direction = entryDirection(j)
                    if direction == 0 { continue }
                    let score = d[j] * d[j] / devex[j]
                    if score > bestScore {
                        bestScore = score
                        best = j
                        bestDirection = direction
                    }
                }
                if best >= 0 {
                    partialSection = (section + 1) % sections
                    break
                }
            }
        }
        return best >= 0 ? (best, bestDirection) : nil
    }

    /// Asks the candidate kernel for the 64 most attractive structural columns, verifies them
    /// in Double and returns the best verified one (compared with the best logical column).
    /// Returns nil when the kernel is off, unavailable, disabled, or produced nothing usable —
    /// the caller then runs the CPU scan, which is the only path that can conclude optimality.
    mutating func scanForEntering() async -> (q: Int, sigma: Double)? {
        guard metalPolicy != .off, !scannerGuard.isDisabled, let provider = kernelProvider else { return nil }
        if !scannerRequested {
            scannerRequested = true
            if KernelThresholds.allowsReducedCostScan(columns: n, nonzeros: lp.nnz, policy: metalPolicy) {
                scanner = await provider.reducedCostScanner(for: lp, policy: metalPolicy)
            }
        }
        guard let scanner else { return nil }

        var eligibility = [UInt8](repeating: PricingEligibility.none, count: n)
        for j in 0..<n where pos[j] < 0 && !taboo[j] {
            switch status[j] {
            case .atLower: eligibility[j] = PricingEligibility.increase
            case .atUpper: eligibility[j] = PricingEligibility.decrease
            case .free: eligibility[j] = PricingEligibility.either
            default: break
            }
        }
        // d_j = c_j − a_jᵀy holds in both phases as long as the phase's costs are passed.
        let costs = phase1Pricing ? [Double](repeating: 0, count: n) : Array(cost[0..<n])
        guard let candidates = await scanner.scan(
            costs: costs, duals: y, weights: Array(devex[0..<n]), eligibility: eligibility,
            limit: KernelThresholds.reducedCostCandidates)
        else { return nil }

        var best = -1
        var bestScore = 0.0
        var bestDirection = 0.0
        var verified = 0
        var disagreements = 0
        let tolerance = tol.dualFeasibility
        for candidate in candidates {
            let j = Int(candidate)
            guard j >= 0, j < n, pos[j] < 0, status[j] != .fixed else {
                // Not a nonbasic column that can move at all: the kernel is plainly wrong.
                verified += 1
                disagreements += 1
                continue
            }
            // fp64 verification: the maintained reduced cost is the exact one.
            let direction = entryDirection(j)
            if direction != 0 {
                verified += 1
                let score = d[j] * d[j] / devex[j]
                if score > bestScore {
                    bestScore = score
                    best = j
                    bestDirection = direction
                }
                continue
            }
            // Not attractive in Double. A reduced cost within the tolerance is rounding noise
            // that single precision cannot resolve; it neither confirms nor contradicts the
            // kernel. One that is clearly on the wrong side contradicts it.
            let dj = d[j]
            if (status[j] == .atLower && dj > tolerance) || (status[j] == .atUpper && dj < -tolerance) {
                verified += 1
                disagreements += 1
            }
        }
        if scannerGuard.record(candidates: verified, disagreements: disagreements) {
            let rate = Int((scannerGuard.disagreementRate * 100).rounded())
            await warn("the reducedCostScan kernel disagreed with fp64 verification on \(rate)% of its candidates and was disabled for this solve")
        }
        // Logical columns never went to the kernel.
        for i in 0..<m {
            let j = n + i
            guard pos[j] < 0, !taboo[j] else { continue }
            let direction = entryDirection(j)
            if direction == 0 { continue }
            let score = d[j] * d[j] / devex[j]
            if score > bestScore {
                bestScore = score
                best = j
                bestDirection = direction
            }
        }
        return best >= 0 ? (best, bestDirection) : nil
    }

    // MARK: - Ratio tests

    /// Harris two-pass ratio test for phase 2.
    ///
    /// Pass 1 computes the largest step allowed when every bound is relaxed by the harris
    /// tolerance; pass 2 picks, among candidates whose unrelaxed ratio is at most that step,
    /// the one with the largest |α_r|.
    func phase2RatioTest(q: Int, sigma: Double, pivotFactor: Double = 1) -> RatioStep {
        let alphaMax = Vec.maxAbs(alpha)
        let pivotTolerance = Swift.max(pivotFactor * tol.pivot * alphaMax, 1e-12)
        let harris = tol.harris
        let range = status[q] == .free ? Double.infinity : upper[q] - lower[q]

        var thetaMax = Double.infinity
        for i in 0..<m {
            // x_i changes at rate −σ·α_i.
            let rate = -sigma * alpha[i]
            if rate < -pivotTolerance {
                let lo = lower[Int(head[i])]
                if lo > -.infinity {
                    let slack = Swift.max(x[Int(head[i])] - lo, 0)
                    let t = (slack + harris) / -rate
                    if t < thetaMax { thetaMax = t }
                }
            } else if rate > pivotTolerance {
                let up = upper[Int(head[i])]
                if up < .infinity {
                    let slack = Swift.max(up - x[Int(head[i])], 0)
                    let t = (slack + harris) / rate
                    if t < thetaMax { thetaMax = t }
                }
            }
        }
        if thetaMax == .infinity {
            return range == .infinity ? .unbounded : .flip(theta: range)
        }
        if range <= thetaMax { return .flip(theta: range) }

        var r = -1
        var bestMagnitude = 0.0
        var theta = 0.0
        var atUpper = false
        let bland = blandRemaining > 0
        var blandRatio = Double.infinity
        for i in 0..<m {
            let rate = -sigma * alpha[i]
            let j = Int(head[i])
            var t = Double.infinity
            var hitsUpper = false
            if rate < -pivotTolerance {
                let lo = lower[j]
                if lo > -.infinity { t = Swift.max(x[j] - lo, 0) / -rate }
            } else if rate > pivotTolerance {
                let up = upper[j]
                if up < .infinity {
                    t = Swift.max(up - x[j], 0) / rate
                    hitsUpper = true
                }
            }
            guard t <= thetaMax else { continue }
            let magnitude = Swift.abs(rate)
            if bland {
                // Smallest ratio, ties to the lowest variable index.
                if t < blandRatio - 1e-12 || (Swift.abs(t - blandRatio) <= 1e-12 && (r < 0 || j < Int(head[r]))) {
                    blandRatio = Swift.min(blandRatio, t)
                    r = i
                    theta = t
                    atUpper = hitsUpper
                }
            } else if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                r = i
                theta = t
                atUpper = hitsUpper
            }
        }
        guard r >= 0 else { return .blocked }
        return .pivot(r: r, theta: theta, atUpper: atUpper)
    }

    /// Long-step ratio test for the composite phase 1: the step passes through breakpoints
    /// while the slope of the infeasibility sum stays negative.
    func phase1RatioTest(q: Int, sigma: Double, pivotFactor: Double = 1) -> RatioStep {
        struct Breakpoint {
            var t: Double
            var row: Int32
            var magnitude: Double
            var atUpper: Bool
        }
        let alphaMax = Vec.maxAbs(alpha)
        let pivotTolerance = Swift.max(pivotFactor * tol.pivot * alphaMax, 1e-12)
        let feasibility = tol.primalFeasibility
        var breakpoints: [Breakpoint] = []
        for i in 0..<m {
            let rate = -sigma * alpha[i]
            let magnitude = Swift.abs(rate)
            if magnitude <= pivotTolerance { continue }
            let j = Int(head[i])
            let v = x[j]
            let lo = lower[j]
            let up = upper[j]
            if rate > 0 {
                if v < lo - feasibility {
                    // Infeasible below and rising: feasible at lo, infeasible again past up.
                    breakpoints.append(Breakpoint(t: (lo - v) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: false))
                    if up < .infinity {
                        breakpoints.append(Breakpoint(t: (up - v) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: true))
                    }
                } else if v <= up + feasibility {
                    if up < .infinity {
                        breakpoints.append(Breakpoint(t: Swift.max(up - v, 0) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: true))
                    }
                }
                // Above the upper bound and rising: the infeasibility only grows; no breakpoint.
            } else {
                if v > up + feasibility {
                    breakpoints.append(Breakpoint(t: (v - up) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: true))
                    if lo > -.infinity {
                        breakpoints.append(Breakpoint(t: (v - lo) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: false))
                    }
                } else if v >= lo - feasibility {
                    if lo > -.infinity {
                        breakpoints.append(Breakpoint(t: Swift.max(v - lo, 0) / magnitude, row: Int32(i), magnitude: magnitude, atUpper: false))
                    }
                }
            }
        }
        let range = status[q] == .free ? Double.infinity : upper[q] - lower[q]
        if breakpoints.isEmpty {
            return range == .infinity ? .blocked : .flip(theta: range)
        }
        breakpoints.sort { $0.t < $1.t }

        // The slope of the infeasibility sum starts at −|d_q| and gains |rate| at every breakpoint.
        var slope = -Swift.abs(d[q])
        var chosen = -1
        for (k, breakpoint) in breakpoints.enumerated() {
            if breakpoint.t >= range { return .flip(theta: range) }
            slope += breakpoint.magnitude
            if slope >= -1e-12 {
                chosen = k
                break
            }
        }
        if chosen < 0 {
            if range < .infinity { return .flip(theta: range) }
            // Entries below the pivot tolerance were left out, so the slope never turned.
            // Stop at the last breakpoint: the sum has decreased all the way there.
            chosen = breakpoints.count - 1
        }
        // Among breakpoints at (numerically) the same step, leave on the largest pivot.
        var best = chosen
        let pivotStep = breakpoints[chosen].t
        let window = tol.harris * (1 + pivotStep)
        var k = chosen - 1
        while k >= 0, pivotStep - breakpoints[k].t <= window {
            if breakpoints[k].magnitude > breakpoints[best].magnitude { best = k }
            k -= 1
        }
        k = chosen + 1
        while k < breakpoints.count, breakpoints[k].t - pivotStep <= window {
            if breakpoints[k].magnitude > breakpoints[best].magnitude { best = k }
            k += 1
        }
        if blandRemaining > 0 { best = chosen }
        return .pivot(r: Int(breakpoints[best].row), theta: breakpoints[best].t, atUpper: breakpoints[best].atUpper)
    }

    // MARK: - Updates

    /// Moves the entering column to its opposite bound; no basis change.
    mutating func applyFlip(q: Int, sigma: Double, theta: Double) {
        if theta != 0 {
            let step = sigma * theta
            for i in 0..<m where alpha[i] != 0 { x[Int(head[i])] -= step * alpha[i] }
        }
        if status[q] == .atUpper { basisHash ^= upperToken(q) }
        status[q] = sigma > 0 ? .atUpper : .atLower
        if status[q] == .atUpper { basisHash ^= upperToken(q) }
        placeNonbasic(q)
    }

    /// Weight update from the pivot row. Devex: w_j ← max(w_j, (α_rj/α_rq)²·w_q). Steepest
    /// edge: the exact recurrence with v = B⁻ᵀα_q (the extra solve per iteration).
    mutating func updatePricingWeights(q: Int, r: Int, leaving p: Int) {
        let alphaR = alpha[r]
        if case .dantzig = config.pricing { return }
        if case .steepestEdge = config.pricing {
            // γ_q is known exactly: 1 + ‖α_q‖².
            var gammaQ = 1.0
            for i in 0..<m { gammaQ += alpha[i] * alpha[i] }
            for i in 0..<m { tau[i] = alpha[i] }
            factor.btran(&tau)
            func update(_ j: Int) {
                guard pos[j] < 0, j != q else { return }
                let ratio = rowAlpha[j] / alphaR
                if ratio == 0 { return }
                let product = j < n ? lp.a.dot(column: j, tau) : -tau[j - n]
                devex[j] = Swift.max(devex[j] - 2 * ratio * product + ratio * ratio * gammaQ, 1 + ratio * ratio)
            }
            if rowIsSparse {
                for j in rowTouched { update(Int(j)) }
            } else {
                for j in 0..<total { update(j) }
            }
            devex[p] = Swift.max(gammaQ / (alphaR * alphaR), 1)
            return
        }
        let reference = devex[q]
        func update(_ j: Int) {
            guard pos[j] < 0, j != q else { return }
            let ratio = rowAlpha[j] / alphaR
            let candidate = ratio * ratio * reference
            if candidate > devex[j] { devex[j] = candidate }
        }
        if rowIsSparse {
            for j in rowTouched { update(Int(j)) }
        } else {
            for j in 0..<total { update(j) }
        }
        devex[p] = Swift.max(reference / (alphaR * alphaR), 1)
        // A runaway reference weight means the framework is stale: start a new one.
        if devex[p] > 1e12 || reference > 1e12 { resetPricingWeights() }
    }

    /// Updates d and y from the pivot row: θ_d = d_q/α_rq, d_j −= θ_d·α_rj, y += θ_d·ρ.
    mutating func updateDuals(q: Int, r: Int, leaving p: Int) {
        let thetaD = d[q] / alpha[r]
        if thetaD != 0 {
            if rowIsSparse {
                for j in rowTouched where pos[Int(j)] < 0 { d[Int(j)] -= thetaD * rowAlpha[Int(j)] }
            } else {
                for j in 0..<total where pos[j] < 0 { d[j] -= thetaD * rowAlpha[j] }
            }
            for i in 0..<m where rho[i] != 0 { y[i] += thetaD * rho[i] }
        }
        d[q] = 0
        d[p] = -thetaD
    }

    /// Exchanges column q for the basic variable at position r and records the eta.
    /// Returns false when the factorization refused the update; the basis has changed
    /// regardless and must be refactored.
    mutating func exchange(q: Int, r: Int, leavingStatus: BasisStatus) -> Bool {
        let p = Int(head[r])
        if status[q] == .atUpper { basisHash ^= upperToken(q) }
        basisHash ^= basicToken(q) ^ basicToken(p)
        head[r] = Int32(q)
        pos[q] = Int32(r)
        pos[p] = -1
        status[q] = .basic
        status[p] = lower[p] == upper[p] ? .fixed : leavingStatus
        if status[p] == .atUpper { basisHash ^= upperToken(p) }
        do throws(NumericalError) {
            try factor.update(alpha: alpha, leaving: r)
            return true
        } catch {
            hasFactor = false
            return false
        }
    }

    // MARK: - Certificates

    /// The primal ray (α, −1) of an unbounded direction, over the structural columns.
    func primalRay(q: Int, sigma: Double) -> [Double] {
        var ray = [Double](repeating: 0, count: n)
        if q < n { ray[q] = sigma }
        for k in 0..<m {
            let j = Int(head[k])
            if j < n { ray[j] = -sigma * alpha[k] }
        }
        return ray
    }

    /// How strongly a row combination r certifies infeasibility: with z = Aᵀr, the lower
    /// bound of rᵀs over the row bounds minus the upper bound of zᵀx over the column bounds.
    /// Positive means r proves the model infeasible; −∞ means r leans on a bound that does
    /// not exist.
    func farkasValue(_ r: [Double]) -> Double {
        let small = 1e-9
        var value = 0.0
        let scale = Swift.max(Vec.maxAbs(r), 1e-300)
        for i in 0..<m {
            let ri = r[i]
            if Swift.abs(ri) <= small * scale { continue }
            let bound = ri > 0 ? trueLower[n + i] : trueUpper[n + i]
            if bound.isInfinite { return -.infinity }
            value += ri * bound
        }
        for j in 0..<n {
            let zj = lp.a.dot(column: j, r)
            if Swift.abs(zj) <= small * scale { continue }
            let bound = zj > 0 ? trueUpper[j] : trueLower[j]
            if bound.isInfinite { return -.infinity }
            value -= zj * bound
        }
        return value
    }

    /// The sign of `candidate` that certifies infeasibility best, normalized to unit ∞-norm.
    func farkasRay(from candidate: [Double]) -> [Double] {
        let norm = Vec.maxAbs(candidate)
        guard norm > 0 else { return candidate }
        let positive = candidate.map { $0 / norm }
        let negative = positive.map { -$0 }
        return farkasValue(positive) >= farkasValue(negative) ? positive : negative
    }

    // MARK: - Perturbation (§7.3)

    /// Relaxes the finite bounds of the basic variables by a random relative 1e-6, so that
    /// degenerate steps become strictly positive. Removed at optimality; the dual method
    /// cleans up what the removal leaves infeasible.
    mutating func perturbBounds() {
        for k in 0..<m {
            let j = Int(head[k])
            if lower[j] == upper[j] && lower[j].isFinite {
                continue   // keep fixed variables fixed
            }
            if lower[j] > -.infinity {
                lower[j] -= 1e-6 * (1 + Swift.abs(lower[j])) * (0.5 + 0.5 * nextRandom())
            }
            if upper[j] < .infinity {
                upper[j] += 1e-6 * (1 + Swift.abs(upper[j])) * (0.5 + 0.5 * nextRandom())
            }
        }
        boundsPerturbed = true
    }

    /// Restores the true bounds and puts every nonbasic column back on them.
    mutating func removeBoundPerturbation() {
        guard boundsPerturbed else { return }
        lower = trueLower
        upper = trueUpper
        for j in 0..<total where pos[j] < 0 { placeNonbasic(j) }
        boundsPerturbed = false
        computePrimals()
    }

    // MARK: - The primal loop

    /// Runs the primal method from the current basis until it is optimal, proves the problem
    /// infeasible or unbounded, or hits the iteration limit. Stop signals and numerical
    /// failures are thrown and mapped by `run`.
    mutating func runPrimal(iterationLimit: Int, gate: inout WorkGate) async throws -> SimplexOutcome.Status {
        lastMethod = .primal
        if !hasFactor { try refactorize() }
        computePrimals()
        var phase = primalInfeasibility().max > 0 ? 1 : 2
        if phase == 2 { await computeDualsAsync() }
        if config.perturbation == .always && !boundsPerturbed && !suppressPerturbation { perturbBounds() }
        var verifications = 0
        var phaseReturns = 0
        var tabooResets = 0
        var forceRefactor = false
        bestProgressValue = .infinity
        lastProgressIteration = iterations
        clearCycleHistory()

        while true {
            try await gate.tick()
            if iterations >= iterationLimit { return .iterationLimit }

            if forceRefactor || !hasFactor || factor.needsRefactor {
                forceRefactor = false
                try refactorize()
                computePrimals()
                _ = try checkResidual()
                if phase == 2 { await computeDualsAsync() }
            } else if iterationsSinceResidualCheck >= 50 {
                if try checkResidual(), phase == 2 { await computeDualsAsync() }
            }

            let infeasibility = primalInfeasibility()
            if phase == 2 && infeasibility.max > 0 {
                // Drift, or a bound that moved under a basic variable.
                phaseReturns += 1
                if phaseReturns > 25 {
                    throw EngineFailure.numerical("primal feasibility could not be maintained")
                }
                phase = 1
            }
            if phase == 1 {
                if infeasibility.max == 0 {
                    phase = 2
                    await computeDualsAsync()
                    bestProgressValue = .infinity
                    lastProgressIteration = iterations
                } else {
                    await computePhase1Duals()
                }
            }
            phase1Pricing = phase == 1
            await report(phase: phase, infeasibility: infeasibility.sum)

            guard let (q, sigma) = await chooseEntering() else {
                // Nothing prices out. Trust that only on iterates that come straight from a
                // fresh factorization.
                if factor.updatesSinceRefactor > 0 && verifications < 8 {
                    verifications += 1
                    forceRefactor = true
                    continue
                }
                if tabooCount > 0 && tabooResets < 3 {
                    tabooResets += 1
                    clearTaboo()
                    forceRefactor = true
                    continue
                }
                if phase == 1 {
                    lastDualRay = farkasRay(from: y)
                    return .infeasible
                }
                return .optimal
            }

            ftranColumn(q)
            var step = phase == 1 ? phase1RatioTest(q: q, sigma: sigma) : phase2RatioTest(q: q, sigma: sigma)
            // No entry above the pivot tolerance limits the step. Before that is read as
            // "blocked" or "unbounded", entries a little below the tolerance get a look: if one
            // of them does limit the step, that is the pivot, and the factorization is rebuilt
            // right after it.
            var fragile = false
            if step.isBlockedOrUnbounded, fragilePivots < fragilePivotLimit {
                let second = phase == 1
                    ? phase1RatioTest(q: q, sigma: sigma, pivotFactor: Self.fragilePivotFactor)
                    : phase2RatioTest(q: q, sigma: sigma, pivotFactor: Self.fragilePivotFactor)
                if case .pivot = second {
                    step = second
                    fragile = true
                }
            }
            switch step {
            case .blocked:
                markTaboo(q)
                continue

            case .unbounded:
                if phase == 1 {
                    markTaboo(q)
                    continue
                }
                if factor.updatesSinceRefactor > 0 && verifications < 8 {
                    verifications += 1
                    forceRefactor = true
                    continue
                }
                lastPrimalRay = primalRay(q: q, sigma: sigma)
                return .unbounded

            case .flip(let theta):
                applyFlip(q: q, sigma: sigma, theta: theta)
                iterations += 1
                if phase == 1 { phase1Iterations += 1 }
                iterationsSinceResidualCheck += 1

            case .pivot(let r, let theta, let atUpper):
                let alphaR = alpha[r]
                if Swift.abs(alphaR) < 1e-11 {
                    markTaboo(q)
                    continue
                }
                await computePivotRow(r)
                // The same pivot element computed two ways must agree; if it does not, the
                // factorization has drifted. A small pivot must agree in its own digits.
                let agreement = fragile ? 1e-3 * Swift.abs(alphaR) : 1e-6 * (1 + Swift.abs(alphaR))
                if Swift.abs(alphaR - rowAlpha[q]) > agreement {
                    if factor.updatesSinceRefactor > 0 {
                        forceRefactor = true
                    } else {
                        markTaboo(q)
                    }
                    continue
                }
                let p = Int(head[r])
                // Primal step.
                let move = sigma * theta
                if move != 0 {
                    for i in 0..<m where alpha[i] != 0 { x[Int(head[i])] -= move * alpha[i] }
                    x[q] += move
                }
                x[p] = atUpper ? upper[p] : lower[p]
                if phase == 2 { updateDuals(q: q, r: r, leaving: p) }
                updatePricingWeights(q: q, r: r, leaving: p)
                if !exchange(q: q, r: r, leavingStatus: atUpper ? .atUpper : .atLower) { forceRefactor = true }
                iterations += 1
                if phase == 1 { phase1Iterations += 1 }
                iterationsSinceResidualCheck += 1
                if tabooCount > 0 { clearTaboo() }
                if blandRemaining > 0 { blandRemaining -= 1 }
                // A small pivot is checked right away (§6.3).
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
            }

            // Stall detection, every 100 iterations.
            if iterations % 100 == 0 {
                let progress = phase == 1 ? primalInfeasibility().sum : objectiveValue()
                if progress < bestProgressValue - 1e-9 * (1 + Swift.abs(bestProgressValue)) {
                    bestProgressValue = progress
                    lastProgressIteration = iterations
                } else if iterations - lastProgressIteration >= 1_000, config.perturbation == .onStall,
                          !boundsPerturbed, !suppressPerturbation, degeneracyFraction() > 0.3 {
                    perturbBounds()
                    lastProgressIteration = iterations
                }
            }
        }
    }

    mutating func markTaboo(_ j: Int) {
        if !taboo[j] {
            taboo[j] = true
            tabooCount += 1
        }
    }

    mutating func clearTaboo() {
        if tabooCount == 0 { return }
        for j in 0..<total { taboo[j] = false }
        tabooCount = 0
    }
}
