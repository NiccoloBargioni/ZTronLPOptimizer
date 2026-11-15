// The interior-point worker (specification §8.1–§8.3, §8.5).
//
// Mehrotra's predictor–corrector primal-dual method on the logical form. After the bound
// treatment of §8.1 the engine sees one shape:
//
//     min cᵀx   s.t.   Ax = b,   x + w = u (j ∈ U),   x, w ≥ 0
//
// and factors the normal equations M = AΘAᵀ + δ_d·I with Accelerate's sparse Cholesky, reusing
// the symbolic analysis across iterations. The worker owns its buffers and its Accelerate
// handles and is used by one task (rule C4: the type is non-copyable).

import ZTronLPCore
import ZTronLPNumerics

/// What one interior-point run produced, unscaled and in the minimization form.
package struct IPMOutcome: Sendable {
    package enum Status: Sendable, Equatable {
        case converged
        case iterationLimit
        case infeasibleOrUnbounded
        /// Complementarity is closed but a residual is stuck above the tolerance, and not far
        /// above: the normal equations have reached the accuracy their conditioning allows.
        /// The problem is neither shown infeasible nor solved; the simplex can decide it.
        case stalled
        case stopped(StopSignal)
        case numericalFailure(String)
    }

    package var status: Status
    /// n structural values.
    package var x: [Double]
    /// m row duals.
    package var y: [Double]
    /// cᵀx + c₀.
    package var objective: Double
    package var iterations: Int
    package var mu: Double
    package var primalResidual: Double
    package var dualResidual: Double
    package var gap: Double
    package var warnings: [String]
    /// Columns of [A −I] (structural j, or n + row for a logical) that the duals mark as
    /// resting on their lower bound at the optimum …
    package var restingAtLower: [Int32] = []
    /// … and on their upper bound. Together they identify the optimal face (§8.4).
    package var restingAtUpper: [Int32] = []
}

/// The standard form of §8.1 and the map back to the logical form.
struct StandardForm {
    enum Kind: UInt8 {
        /// x = l + x̃.
        case shifted
        /// x = u − x̃ (only an upper bound).
        case reflected
        /// x = x⁺ − x⁻: the positive half …
        case freePlus
        /// … and the negative half.
        case freeMinus
        /// A row's logical, s = r_l + s̃.
        case logicalShifted
        /// A row's logical with only an upper bound, s = r_u − s̃.
        case logicalReflected
    }

    /// The working-problem row of each standard-form row (free rows are dropped).
    var rowOrigin: [Int32] = []
    var kind: [Kind] = []
    /// The structural column or the row each standard-form column comes from.
    var source: [Int32] = []
    var a = SparseCSC(rows: 0, cols: 0)
    var aT = SparseCSC(rows: 0, cols: 0)
    var b: [Double] = []
    var c: [Double] = []
    /// Upper bounds; +∞ where there is none.
    var upper: [Double] = []
    /// Primal regularization per column (free halves get 1e-8 so Θ stays bounded).
    var regularization: [Double] = []
    /// Objective constant after the shifts.
    var constant = 0.0
    /// The value of every structural column that does not move: fixed columns, and the shift
    /// of the others.
    var shift: [Double] = []
    /// Columns with more than 30% nonzeros (§8.3).
    var denseColumns = 0

    var rows: Int { Int(a.rows) }
    var columns: Int { Int(a.cols) }

    init(_ lp: CompiledLP, primalRegularization: Double) {
        let m = lp.m
        let n = lp.n
        var rowIndexOf = [Int32](repeating: -1, count: m)
        for i in 0..<m where !(lp.rl[i] == -.infinity && lp.ru[i] == .infinity) {
            rowIndexOf[i] = Int32(rowOrigin.count)
            rowOrigin.append(Int32(i))
        }
        let keptRows = rowOrigin.count
        shift = [Double](repeating: 0, count: n)
        constant = lp.c0
        var colStart: [Int] = [0]
        var rowIndex: [Int32] = []
        var values: [Double] = []
        b = [Double](repeating: 0, count: keptRows)

        func appendColumn(_ j: Int, sign: Double) {
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                let row = rowIndexOf[Int(lp.a.rowIndex[p])]
                if row >= 0 {
                    rowIndex.append(row)
                    values.append(sign * lp.a.values[p])
                }
            }
            colStart.append(values.count)
        }
        func moveToRightHandSide(_ j: Int, value: Double) {
            if value == 0 { return }
            for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] {
                let row = rowIndexOf[Int(lp.a.rowIndex[p])]
                if row >= 0 { b[Int(row)] -= lp.a.values[p] * value }
            }
        }

        let denseLimit = 0.3 * Double(keptRows)
        for j in 0..<n {
            let lo = lp.xl[j]
            let up = lp.xu[j]
            if keptRows > 3, Double(lp.a.colStart[j + 1] - lp.a.colStart[j]) > denseLimit { denseColumns += 1 }
            if lo == up {
                // Fixed: not a variable of the standard form at all.
                shift[j] = lo
                constant += lp.c[j] * lo
                moveToRightHandSide(j, value: lo)
            } else if lo > -.infinity {
                shift[j] = lo
                constant += lp.c[j] * lo
                moveToRightHandSide(j, value: lo)
                kind.append(.shifted)
                source.append(Int32(j))
                c.append(lp.c[j])
                upper.append(up < .infinity ? up - lo : .infinity)
                regularization.append(0)
                appendColumn(j, sign: 1)
            } else if up < .infinity {
                shift[j] = up
                constant += lp.c[j] * up
                moveToRightHandSide(j, value: up)
                kind.append(.reflected)
                source.append(Int32(j))
                c.append(-lp.c[j])
                upper.append(.infinity)
                regularization.append(0)
                appendColumn(j, sign: -1)
            } else {
                kind.append(.freePlus)
                source.append(Int32(j))
                c.append(lp.c[j])
                upper.append(.infinity)
                regularization.append(primalRegularization)
                appendColumn(j, sign: 1)
                kind.append(.freeMinus)
                source.append(Int32(j))
                c.append(-lp.c[j])
                upper.append(.infinity)
                regularization.append(primalRegularization)
                appendColumn(j, sign: -1)
            }
        }
        // Logical columns: Σ a_ij·x_j − s_i = 0.
        for (k, origin) in rowOrigin.enumerated() {
            let i = Int(origin)
            let lo = lp.rl[i]
            let up = lp.ru[i]
            if lo == up {
                b[k] += lo                       // equality: the logical is a constant
            } else if lo > -.infinity {
                b[k] += lo                       // s = lo + s̃  →  … − s̃ = lo − …
                kind.append(.logicalShifted)
                source.append(origin)
                c.append(0)
                upper.append(up < .infinity ? up - lo : .infinity)
                regularization.append(0)
                rowIndex.append(Int32(k))
                values.append(-1)
                colStart.append(values.count)
            } else {
                b[k] += up                       // s = up − s̃  →  … + s̃ = up − …
                kind.append(.logicalReflected)
                source.append(origin)
                c.append(0)
                upper.append(.infinity)
                regularization.append(0)
                rowIndex.append(Int32(k))
                values.append(1)
                colStart.append(values.count)
            }
        }
        a = SparseCSC(
            rows: Int32(keptRows), cols: Int32(kind.count), colStart: colStart, rowIndex: rowIndex,
            values: values)
        aT = a.transposed()
    }

    /// The structural values that go with a standard-form point.
    func structuralValues(_ x: [Double]) -> [Double] {
        var result = shift
        for (k, kind) in kind.enumerated() {
            let j = Int(source[k])
            switch kind {
            case .shifted: result[j] = shift[j] + x[k]
            case .reflected: result[j] = shift[j] - x[k]
            case .freePlus: result[j] += x[k]
            case .freeMinus: result[j] -= x[k]
            case .logicalShifted, .logicalReflected: break
            }
        }
        return result
    }

    /// Row duals of the working problem from the standard form's duals (dropped rows get 0).
    func rowDuals(_ y: [Double], rows m: Int) -> [Double] {
        var result = [Double](repeating: 0, count: m)
        for (k, origin) in rowOrigin.enumerated() { result[Int(origin)] = y[k] }
        return result
    }
}

/// Worker-owned interior-point engine: one instance per task, never shared.
package struct IPMWorker: ~Copyable {
    let lp: CompiledLP
    let form: StandardForm
    let config: InteriorPoint
    let m: Int
    let n: Int
    /// Columns with an upper bound.
    let bounded: [Int32]
    let hasUpper: [Bool]

    // Normal equations.
    let patternStart: [Int]
    let patternRows: [Int32]
    /// Position of each diagonal entry in the pattern.
    let diagonalPosition: [Int]
    let useDense: Bool
    var sparse: SparseSymmetricSolver?
    var denseCholesky: DenseCholesky?
    var denseLU: DenseLU?
    var usingLDLT = false
    var choleskyRetries = 0
    var dualRegularization: Double

    // Iterates.
    var x: [Double]
    var w: [Double]
    var y: [Double]
    var z: [Double]
    var s: [Double]
    var theta: [Double]

    package var threads = 1
    package var budget: ConcurrencyBudget? = nil
    package var eventSink: EventSink? = nil
    /// Forces this many Cholesky factorizations to fail, for the L6 tests.
    package var failingFactorizations = 0
    var warnings: [String] = []

    /// Builds the standard form and analyses the pattern of AΘAᵀ once.
    package init(lp: CompiledLP, config: InteriorPoint) throws {
        self.lp = lp
        self.config = config
        let form = StandardForm(lp, primalRegularization: config.regularization.primal)
        self.form = form
        m = form.rows
        n = form.columns
        var bounded: [Int32] = []
        var hasUpper = [Bool](repeating: false, count: form.columns)
        for k in 0..<form.columns where form.upper[k] < .infinity {
            bounded.append(Int32(k))
            hasUpper[k] = true
        }
        self.bounded = bounded
        self.hasUpper = hasUpper
        dualRegularization = config.regularization.dual

        // Pattern of the lower triangle of A·Aᵀ, column by column.
        var start = [Int](repeating: 0, count: form.rows + 1)
        var rows: [Int32] = []
        var diagonal = [Int](repeating: 0, count: form.rows)
        var mark = [Int32](repeating: -1, count: form.rows)
        var scratch: [Int32] = []
        for j in 0..<form.rows {
            scratch.removeAll(keepingCapacity: true)
            mark[j] = Int32(j)
            scratch.append(Int32(j))   // the diagonal is always present (regularization)
            for p in form.aT.colStart[j]..<form.aT.colStart[j + 1] {
                let k = Int(form.aT.rowIndex[p])
                for q in form.a.colStart[k]..<form.a.colStart[k + 1] {
                    let i = Int(form.a.rowIndex[q])
                    if i > j && mark[i] != Int32(j) {
                        mark[i] = Int32(j)
                        scratch.append(Int32(i))
                    }
                }
            }
            scratch.sort()
            diagonal[j] = rows.count
            rows.append(contentsOf: scratch)
            start[j + 1] = rows.count
        }
        patternStart = start
        patternRows = rows
        diagonalPosition = diagonal

        // Dense dpotrf instead of the sparse solver when m ≤ 300 or M is ≥ 25% dense (§8.2).
        let lowerEntries = Double(form.rows) * Double(form.rows + 1) / 2
        useDense = form.rows <= 300 || Double(rows.count) >= 0.25 * lowerEntries
        if !useDense && form.rows > 0 {
            do throws(NumericalError) {
                sparse = try SparseSymmetricSolver(n: form.rows, lowerColStart: start, lowerRowIndex: rows, kind: .cholesky)
            } catch {
                throw SolverError.internalInconsistency("the normal-equations pattern could not be analysed: \(error)")
            }
        } else {
            sparse = nil
        }
        denseCholesky = nil
        denseLU = nil
        x = [Double](repeating: 1, count: form.columns)
        w = [Double](repeating: 1, count: form.columns)
        y = [Double](repeating: 0, count: form.rows)
        z = [Double](repeating: 1, count: form.columns)
        s = [Double](repeating: 0, count: form.columns)
        theta = [Double](repeating: 1, count: form.columns)
    }

    /// The number of dense columns found while building the standard form (§8.3).
    package var denseColumnCount: Int { form.denseColumns }

    // MARK: - Normal equations

    /// Values of the lower triangle of AΘAᵀ + δ·I for the pattern, formed in parallel over
    /// row blocks: each child owns a block of rows of the lower triangle and returns its own
    /// slice, which is then merged into the shared storage (§8.2 step 1).
    func normalMatrixValues(theta: [Double], delta: Double) async -> [Double] {
        let a = form.a
        let aT = form.aT
        let start = patternStart
        let rows = patternRows
        let size = m
        let blocks = budget != nil && size >= 2_000 ? Swift.min(threads, 8) : 1
        let parts = await parallelBlocks(count: size, blocks: blocks, budget: budget) { range -> [Double] in
            var values = [Double](repeating: 0, count: start[range.upperBound] - start[range.lowerBound])
            var accumulator = [Double](repeating: 0, count: size)
            let base = start[range.lowerBound]
            for j in range {
                for p in aT.colStart[j]..<aT.colStart[j + 1] {
                    let k = Int(aT.rowIndex[p])
                    let weight = theta[k] * aT.values[p]
                    if weight == 0 { continue }
                    for q in a.colStart[k]..<a.colStart[k + 1] {
                        let i = Int(a.rowIndex[q])
                        if i >= j { accumulator[i] += weight * a.values[q] }
                    }
                }
                for t in start[j]..<start[j + 1] {
                    let i = Int(rows[t])
                    values[t - base] = accumulator[i]
                    accumulator[i] = 0
                }
                values[start[j] - base] += delta   // the diagonal is the first entry of its column
            }
            return values
        }
        var merged: [Double] = []
        merged.reserveCapacity(rows.count)
        for part in parts { merged.append(contentsOf: part) }
        return merged
    }

    /// Factors M for the current Θ. A failed Cholesky retries once with δ × 100 and then
    /// switches to LDLᵀ for the remainder of the solve; if that fails as well the solve ends
    /// with a numerical failure (rule L6: at most two retries, never a loop).
    mutating func factorNormalEquations() async throws {
        if m == 0 { return }
        while true {
            // δ_d is scaled to M. Near the solution Θ spans twenty orders of magnitude and so
            // do the pivots of M, so one scalar δ·‖M‖ would swamp the small pivots and stall
            // the primal residual. Each diagonal entry is instead perturbed relative to itself
            // (the regularization of the Jacobi-scaled matrix), with a floor far below ‖M‖
            // that only matters for a row whose pivot has vanished.
            var values = await normalMatrixValues(theta: theta, delta: 0)
            var scale = 0.0
            for j in 0..<m { scale = Swift.max(scale, values[diagonalPosition[j]]) }
            let floor = dualRegularization * 1e-10 * Swift.max(scale, 1e-300)
            for j in 0..<m {
                let position = diagonalPosition[j]
                values[position] += dualRegularization * values[position] + floor
            }

            let injected = failingFactorizations > 0 && !usingLDLT
            if injected { failingFactorizations -= 1 }
            var failed = injected
            if !failed {
                if useDense {
                    var dense = DenseMatrix(rows: m, cols: m)
                    for j in 0..<m {
                        for t in patternStart[j]..<patternStart[j + 1] {
                            let i = Int(patternRows[t])
                            dense.storage[j * m + i] = values[t]
                            if usingLDLT { dense.storage[i * m + j] = values[t] }
                        }
                    }
                    do throws(NumericalError) {
                        if usingLDLT {
                            denseLU = try DenseLU(dense)
                            denseCholesky = nil
                        } else {
                            denseCholesky = try DenseCholesky(lowerTriangleOf: dense)
                        }
                    } catch {
                        failed = true
                    }
                } else {
                    do throws(NumericalError) {
                        try sparse?.factor(values: values)
                    } catch {
                        failed = true
                    }
                }
            }
            if !failed {
                // The boost of a retry is for that factorization only: a larger δ costs
                // accuracy in the primal residual, so the next iteration starts from the
                // configured value again.
                dualRegularization = config.regularization.dual
                return
            }

            if usingLDLT {
                throw IPMFailure.numerical("the normal equations could not be factored, even with LDLᵀ")
            }
            choleskyRetries += 1
            if choleskyRetries == 1 {
                dualRegularization *= 100
                warnings.append("Cholesky broke down; retrying with the dual regularization × 100")
            } else {
                usingLDLT = true
                dualRegularization = config.regularization.dual
                warnings.append("Cholesky broke down twice; switching to LDLᵀ for the rest of the solve")
                if !useDense {
                    do throws(NumericalError) {
                        try sparse?.switchKind(to: .ldlt)
                    } catch {
                        throw IPMFailure.numerical("the LDLᵀ analysis failed: \(error)")
                    }
                }
            }
        }
    }

    /// Solves M·v = rhs in place with the current factors.
    func solveFactored(_ rhs: inout [Double]) {
        if m == 0 { return }
        if useDense {
            if let denseLU {
                denseLU.solve(&rhs)
            } else if let denseCholesky {
                denseCholesky.solve(&rhs)
            }
        } else {
            sparse?.solve(&rhs)
        }
    }

    /// M·v = A·(Θ·(Aᵀv)) + δ·v, for the refinement residual.
    func applyNormalMatrix(_ v: [Double], delta: Double) -> [Double] {
        var t = [Double](repeating: 0, count: n)
        form.a.multiplyTranspose(v, into: &t)
        Vec.multiply(t, theta, into: &t)
        var result = [Double](repeating: 0, count: m)
        form.a.multiply(t, into: &result)
        if delta != 0 { Vec.addScaled(delta, v, to: &result) }
        return result
    }

    /// Solves M·v = rhs with two steps of iterative refinement from the fp64 residual (§8.2 step 4).
    func solveNormalEquations(_ rhs: [Double]) -> [Double] {
        var v = rhs
        solveFactored(&v)
        for _ in 0..<2 {
            let product = applyNormalMatrix(v, delta: 0)
            var residual = [Double](repeating: 0, count: m)
            Vec.subtract(rhs, product, into: &residual)
            if Vec.maxAbs(residual) <= 1e-14 * (1 + Vec.maxAbs(rhs)) { break }
            solveFactored(&residual)
            Vec.add(v, residual, into: &v)
        }
        return v
    }

    // MARK: - Newton direction

    /// One Newton solve for complementarity targets `rxz` and `rws`.
    func direction(
        rp: [Double], ru: [Double], rd: [Double], rxz: [Double], rws: [Double]
    ) -> (dx: [Double], dw: [Double], dy: [Double], dz: [Double], ds: [Double]) {
        // h = r_d − r_xz/x + (r_ws − s·r_u)/w
        var h = [Double](repeating: 0, count: n)
        for k in 0..<n {
            var value = rd[k] - rxz[k] / x[k]
            if hasUpper[k] { value += (rws[k] - s[k] * ru[k]) / w[k] }
            h[k] = value
        }
        // AΘAᵀ·dy = r_p + AΘh
        var thetaH = [Double](repeating: 0, count: n)
        Vec.multiply(theta, h, into: &thetaH)
        var rhs = rp
        form.a.multiply(thetaH, into: &rhs, accumulate: true)
        let dy = solveNormalEquations(rhs)
        // dx = Θ(Aᵀdy − h)
        var dx = [Double](repeating: 0, count: n)
        form.a.multiplyTranspose(dy, into: &dx)
        Vec.subtract(dx, h, into: &dx)
        Vec.multiply(dx, theta, into: &dx)
        var dz = [Double](repeating: 0, count: n)
        var dw = [Double](repeating: 0, count: n)
        var ds = [Double](repeating: 0, count: n)
        for k in 0..<n {
            dz[k] = (rxz[k] - z[k] * dx[k]) / x[k]
            if hasUpper[k] {
                dw[k] = ru[k] - dx[k]
                ds[k] = (rws[k] - s[k] * dw[k]) / w[k]
            }
        }
        return (dx, dw, dy, dz, ds)
    }

    /// The largest step α ≤ 1 that keeps v + α·dv ≥ 0 over the listed entries.
    func stepToBoundary(_ v: [Double], _ dv: [Double], onlyBounded: Bool) -> Double {
        var alpha = Double.infinity
        if onlyBounded {
            for index in bounded {
                let k = Int(index)
                if dv[k] < 0 { alpha = Swift.min(alpha, -v[k] / dv[k]) }
            }
        } else {
            for k in 0..<n where dv[k] < 0 {
                alpha = Swift.min(alpha, -v[k] / dv[k])
            }
        }
        return alpha
    }

    // MARK: - Starting point

    /// Mehrotra's least-squares heuristic through one extra factorization of AAᵀ (§8.2 step 6).
    mutating func startingPoint() async throws {
        for k in 0..<n { theta[k] = 1 }
        try await factorNormalEquations()
        // x̂ = Aᵀ(AAᵀ)⁻¹b
        let v = solveNormalEquations(form.b)
        form.a.multiplyTranspose(v, into: &x)
        // ŷ = (AAᵀ)⁻¹Ac, ẑ = c − Aᵀŷ
        var ac = [Double](repeating: 0, count: m)
        form.a.multiply(form.c, into: &ac)
        y = solveNormalEquations(ac)
        var zHat = [Double](repeating: 0, count: n)
        form.a.multiplyTranspose(y, into: &zHat)
        Vec.subtract(form.c, zHat, into: &zHat)

        // Upper-bound slacks, and the split of ẑ into z − s on bounded columns.
        for k in 0..<n {
            if hasUpper[k] {
                w[k] = form.upper[k] - x[k]
                z[k] = Swift.max(zHat[k], 0)
                s[k] = Swift.max(-zHat[k], 0)
            } else {
                w[k] = 1
                z[k] = zHat[k]
                s[k] = 0
            }
        }
        // Shift to positivity, then towards centrality.
        var minPrimal = Double.infinity
        var minDual = Double.infinity
        for k in 0..<n {
            minPrimal = Swift.min(minPrimal, x[k])
            minDual = Swift.min(minDual, z[k])
            if hasUpper[k] {
                minPrimal = Swift.min(minPrimal, w[k])
                minDual = Swift.min(minDual, s[k])
            }
        }
        if n == 0 { return }
        let primalShift = Swift.max(-1.5 * minPrimal, 0)
        let dualShift = Swift.max(-1.5 * minDual, 0)
        var complementarity = 0.0
        var sumPrimal = 0.0
        var sumDual = 0.0
        for k in 0..<n {
            x[k] += primalShift
            z[k] += dualShift
            complementarity += x[k] * z[k]
            sumPrimal += x[k]
            sumDual += z[k]
            if hasUpper[k] {
                w[k] += primalShift
                s[k] += dualShift
                complementarity += w[k] * s[k]
                sumPrimal += w[k]
                sumDual += s[k]
            }
        }
        let centerPrimal = sumDual > 0 ? 0.5 * complementarity / sumDual : 1
        let centerDual = sumPrimal > 0 ? 0.5 * complementarity / sumPrimal : 1
        let floorPrimal = Swift.max(centerPrimal, 1e-4)
        let floorDual = Swift.max(centerDual, 1e-4)
        for k in 0..<n {
            x[k] += floorPrimal
            z[k] += floorDual
            if hasUpper[k] {
                w[k] += floorPrimal
                s[k] += floorDual
            }
        }
    }

    // MARK: - Main loop

    package mutating func run(gate: inout WorkGate) async throws -> IPMOutcome {
        var iterations = 0
        var mu = 0.0
        var primalResidual = Double.infinity
        var dualResidual = Double.infinity
        var gap = Double.infinity
        var status = IPMOutcome.Status.iterationLimit

        if form.denseColumns > 0 {
            let text = "\(form.denseColumns) column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"
            warnings.append(text)
            if let eventSink { await eventSink.warn(text) }
        }
        if n == 0 {
            // Nothing can move: the problem is feasible exactly when b = 0.
            let feasible = Vec.maxAbs(form.b) <= config.tolerances.primalFeasibility
            mu = 0
            primalResidual = Vec.maxAbs(form.b)
            dualResidual = 0
            gap = 0
            return makeOutcome(
                feasible ? .converged : .infeasibleOrUnbounded, iterations: 0, mu: mu,
                primalResidual: primalResidual, dualResidual: dualResidual, gap: gap)
        }

        do {
            try await startingPoint()
            let bNorm = 1 + Vec.maxAbs(form.b)
            let cNorm = 1 + Vec.maxAbs(form.c)
            var rp = [Double](repeating: 0, count: m)
            var ru = [Double](repeating: 0, count: n)
            var rd = [Double](repeating: 0, count: n)
            var rxz = [Double](repeating: 0, count: n)
            var rws = [Double](repeating: 0, count: n)
            let tolerance = config.tolerances.ipmResidual
            let pairs = Double(n + bounded.count)
            // Stall detection once complementarity is closed: the best residual seen there and
            // the iterations since it last halved.
            var bestResidual = Double.infinity
            var stagnant = 0

            while true {
                // One interior-point iteration is a whole factorization, far more than the
                // millisecond a tick stands for: check on every iteration (rule L1).
                try await gate.check()

                // Residuals.
                form.a.multiply(x, into: &rp)
                Vec.subtract(form.b, rp, into: &rp)
                form.a.multiplyTranspose(y, into: &rd)
                for k in 0..<n {
                    rd[k] = form.c[k] - rd[k] - z[k] + (hasUpper[k] ? s[k] : 0)
                    ru[k] = hasUpper[k] ? form.upper[k] - x[k] - w[k] : 0
                }
                var complementarity = 0.0
                var primalObjective = 0.0
                var dualObjective = Vec.dot(form.b, y)
                for k in 0..<n {
                    complementarity += x[k] * z[k]
                    primalObjective += form.c[k] * x[k]
                    if hasUpper[k] {
                        complementarity += w[k] * s[k]
                        dualObjective -= form.upper[k] * s[k]
                    }
                }
                mu = complementarity / pairs
                primalResidual = Swift.max(Vec.maxAbs(rp), Vec.maxAbs(ru)) / bNorm
                dualResidual = Vec.maxAbs(rd) / cNorm
                gap = Swift.abs(primalObjective - dualObjective) / (1 + Swift.abs(primalObjective))
                if let eventSink, eventSink.hasListener {
                    await eventSink.emit(
                        .ipmIteration(iteration: iterations, mu: mu, primalResidual: primalResidual, dualResidual: dualResidual))
                }

                if primalResidual <= tolerance && dualResidual <= tolerance && gap <= tolerance {
                    status = .converged
                    break
                }
                if iterations >= config.maxIterations {
                    status = .iterationLimit
                    break
                }
                // Without a homogeneous self-dual embedding the method cannot tell infeasible
                // from unbounded; it can only notice that it is not converging (§8.2).
                let xNorm = Vec.maxAbs(x)
                let yNorm = Vec.maxAbs(y)
                if xNorm > 1e12 || yNorm > 1e12 || !mu.isFinite {
                    status = .infeasibleOrUnbounded
                    break
                }
                if mu < 1e-10 {
                    // Complementarity is spent, so the residuals will not come down by much any
                    // more. Far from feasible, that is how an infeasible or unbounded problem
                    // looks. Close to it — a residual of 1e-6 on an ill-conditioned matrix is
                    // what the factorization of AΘAᵀ leaves behind — it only says that this
                    // method has reached its accuracy, and calling the problem infeasible
                    // would be wrong.
                    let worst = Swift.max(primalResidual, dualResidual)
                    if worst > Self.stallCeiling {
                        status = .infeasibleOrUnbounded
                        break
                    }
                    if worst < 0.5 * bestResidual {
                        bestResidual = worst
                        stagnant = 0
                    } else {
                        stagnant += 1
                    }
                    if worst > 1e-6 || stagnant >= 3 {
                        status = .stalled
                        break
                    }
                }

                // 1–2. Θ and the factorization of AΘAᵀ + δ·I.
                for k in 0..<n {
                    var inverse = z[k] / x[k] + form.regularization[k]
                    if hasUpper[k] { inverse += s[k] / w[k] }
                    theta[k] = 1 / inverse
                }
                try await factorNormalEquations()

                // 3. Predictor: the affine-scaling direction and its steps to the boundary.
                for k in 0..<n {
                    rxz[k] = -x[k] * z[k]
                    rws[k] = hasUpper[k] ? -w[k] * s[k] : 0
                }
                let affine = direction(rp: rp, ru: ru, rd: rd, rxz: rxz, rws: rws)
                let affinePrimal = Swift.min(
                    1, stepToBoundary(x, affine.dx, onlyBounded: false), stepToBoundary(w, affine.dw, onlyBounded: true))
                let affineDual = Swift.min(
                    1, stepToBoundary(z, affine.dz, onlyBounded: false), stepToBoundary(s, affine.ds, onlyBounded: true))
                var affineComplementarity = 0.0
                for k in 0..<n {
                    affineComplementarity += (x[k] + affinePrimal * affine.dx[k]) * (z[k] + affineDual * affine.dz[k])
                    if hasUpper[k] {
                        affineComplementarity += (w[k] + affinePrimal * affine.dw[k]) * (s[k] + affineDual * affine.ds[k])
                    }
                }
                let affineMu = affineComplementarity / pairs

                // 4. Corrector: Mehrotra's centering σ = (μ_aff/μ)³, same factorization.
                let ratio = mu > 0 ? affineMu / mu : 0
                let sigma = Swift.min(1, ratio * ratio * ratio)
                for k in 0..<n {
                    rxz[k] = sigma * mu - x[k] * z[k] - affine.dx[k] * affine.dz[k]
                    rws[k] = hasUpper[k] ? sigma * mu - w[k] * s[k] - affine.dw[k] * affine.ds[k] : 0
                }
                let step = direction(rp: rp, ru: ru, rd: rd, rxz: rxz, rws: rws)

                // 5. Step: η = 0.9 for the first five iterations, 0.99 after; separate steps.
                let eta = iterations < 5 ? 0.9 : 0.99
                let primalStep = Swift.min(
                    1, eta * Swift.min(stepToBoundary(x, step.dx, onlyBounded: false), stepToBoundary(w, step.dw, onlyBounded: true)))
                let dualStep = Swift.min(
                    1, eta * Swift.min(stepToBoundary(z, step.dz, onlyBounded: false), stepToBoundary(s, step.ds, onlyBounded: true)))
                guard primalStep.isFinite, dualStep.isFinite, !primalStep.isNaN, !dualStep.isNaN else {
                    throw IPMFailure.numerical("the search direction is not a number")
                }
                Vec.addScaled(primalStep, step.dx, to: &x)
                Vec.addScaled(dualStep, step.dy, to: &y)
                Vec.addScaled(dualStep, step.dz, to: &z)
                for index in bounded {
                    let k = Int(index)
                    w[k] += primalStep * step.dw[k]
                    s[k] += dualStep * step.ds[k]
                }
                iterations += 1
            }
        } catch let signal as StopSignal {
            status = .stopped(signal)
        } catch let failure as IPMFailure {
            switch failure {
            case .numerical(let message): status = .numericalFailure(message)
            }
        } catch let error as SolverError {
            throw error
        } catch {
            throw SolverError.internalInconsistency("\(error)")
        }
        return makeOutcome(
            status, iterations: iterations, mu: mu, primalResidual: primalResidual,
            dualResidual: dualResidual, gap: gap)
    }

    /// Packs the current iterate, mapped back to the working problem and unscaled.
    func makeOutcome(
        _ status: IPMOutcome.Status, iterations: Int, mu: Double, primalResidual: Double,
        dualResidual: Double, gap: Double
    ) -> IPMOutcome {
        var xs = form.structuralValues(x)
        var ys = form.rowDuals(y, rows: lp.m)
        var objective = lp.c0
        for j in 0..<lp.n { objective += lp.c[j] * xs[j] }
        if let scaling = lp.scaling {
            xs = scaling.unscalePrimal(xs)
            ys = scaling.unscaleDual(ys)
        }
        var result = IPMOutcome(
            status: status, x: xs, y: ys, objective: objective, iterations: iterations, mu: mu,
            primalResidual: primalResidual, dualResidual: dualResidual, gap: gap, warnings: warnings)
        if status == .converged {
            // At a strictly complementary solution exactly one of x_k and z_k vanishes: a
            // column whose dual slack dominates its primal value rests on its bound in every
            // optimal solution. Logical columns are reported as n + row.
            let structurals = Int32(lp.n)
            for (k, kind) in form.kind.enumerated() {
                switch kind {
                case .shifted:
                    if z[k] > x[k] {
                        result.restingAtLower.append(form.source[k])
                    } else if hasUpper[k], s[k] > w[k] {
                        result.restingAtUpper.append(form.source[k])
                    }
                case .reflected:
                    if z[k] > x[k] { result.restingAtUpper.append(form.source[k]) }
                case .logicalShifted:
                    if z[k] > x[k] {
                        result.restingAtLower.append(structurals + form.source[k])
                    } else if hasUpper[k], s[k] > w[k] {
                        result.restingAtUpper.append(structurals + form.source[k])
                    }
                case .logicalReflected:
                    if z[k] > x[k] { result.restingAtUpper.append(structurals + form.source[k]) }
                case .freePlus, .freeMinus:
                    break
                }
            }
        }
        return result
    }
}

extension IPMWorker {
    /// The relative residual above which a run whose complementarity is closed counts as
    /// "infeasible or unbounded" rather than as stalled near a solution.
    static var stallCeiling: Double { 1e-4 }
}

/// An internal failure that ends an interior-point solve with `.numericalFailure`.
enum IPMFailure: Error {
    case numerical(String)
}
