// The worker-owned simplex engine (specification §7).
//
// `SimplexEngine` is a bounded-variable revised simplex over the logical form of §5.5:
// every row is an equality Ax − s = 0 with r_l ≤ s ≤ r_u, columns 0..<n are structural and
// n..<n+m are logical, and the basis B is m columns of [A −I]. It offers a primal and a dual
// method on the same basis, factorization and update machinery. One engine instance owns its
// buffers and is used by one task at a time; branch-and-bound workers each hold their own
// instance (rule C4: the type is non-copyable and is passed `inout`).
//
// The engine works in the scaled space of the problem it was given; everything that leaves it
// is unscaled first (§6.5).

import ZTronLPCore
import ZTronLPNumerics

/// An internal failure that ends a solve with `.numericalFailure`.
enum EngineFailure: Error {
    case numerical(String)
}

/// Hooks that let the tests force the numerical safeguards to fire (rule L6).
package struct SimplexFaultInjection: Sendable {
    /// The next this-many residual checks report failure regardless of the residual.
    package var failingResidualChecks = 0
    /// The iteration budget of the clean-up that follows the removal of a perturbation
    /// (§7.3: bounded to 500). A test lowers it to see the budget being enforced.
    package var cleanupIterationLimit = 500
    /// Leaves out the refinement pass that ends an unlimited run, so a test can compare the
    /// answer with and without it.
    package var skipRefinement = false
    /// The pivots the refinement pass may spend; `nil` is its own bound. A test sets 0 to see
    /// the pass give up and the run return to the basis it started from.
    package var refinementIterationLimit: Int? = nil
    /// Raises a cancellation at the start of the refinement pass's own pivoting, so a test can
    /// see that the run keeps the answer it had and returns without refactoring.
    package var stopInsideRefinement = false
    package init() {}
}

/// What one engine run produced, unscaled and in the minimization form of the engine's problem.
package struct SimplexOutcome: Sendable {
    package enum Status: Sendable {
        case optimal, infeasible, unbounded
        /// The dual bound reached the cutoff before optimality (dual method only).
        case cutoff
        case iterationLimit
        /// Cancellation, a raised stop flag or the deadline.
        case stopped(StopSignal)
        case numericalFailure(String)
    }

    package var status: Status
    /// The method that performed the last iterations.
    package var finalMethod: Simplex.Method
    /// cᵀx + c₀ at `x` (minimization form).
    package var objective: Double
    /// A lower bound on the optimum of the minimization form, when the final basis is dual feasible.
    package var dualBound: Double?
    package var primalFeasible: Bool
    package var dualFeasible: Bool
    /// n structural values.
    package var x: [Double]
    /// m row duals.
    package var y: [Double]
    /// n + m reduced costs.
    package var d: [Double]
    package var basis: Basis
    package var primalRay: [Double]?
    package var dualRay: [Double]?
    package var iterations: Int
    package var phase1Iterations: Int
    package var refactorizations: Int
    package var degeneracy: Double
    package var warnings: [String]

    package var isUnbounded: Bool {
        if case .unbounded = status { return true }
        return false
    }

    /// Whether `x` is a meaningful primal point (always, except after a numerical failure).
    package var hasPrimalPoint: Bool {
        if case .numericalFailure = status { return false }
        return true
    }

    /// Whether `y` and `d` are optimal duals.
    package var hasDualPoint: Bool {
        if case .optimal = status { return true }
        return false
    }

    /// The public status this outcome maps to at the engine boundary (§12.3): internal stop
    /// signals become stop reasons, never errors.
    package var publicStatus: SolveStatus {
        switch status {
        case .optimal: return .optimal
        case .infeasible: return .infeasible
        case .unbounded: return .unbounded
        case .cutoff: return primalFeasible ? .feasible(stoppedBy: .gapReached) : .noSolution(stoppedBy: .gapReached)
        case .iterationLimit:
            return primalFeasible ? .feasible(stoppedBy: .iterationLimit) : .noSolution(stoppedBy: .iterationLimit)
        case .stopped(let signal):
            return primalFeasible ? .feasible(stoppedBy: signal.stopReason) : .noSolution(stoppedBy: signal.stopReason)
        case .numericalFailure(let message): return .numericalFailure(message)
        }
    }
}

/// Worker-owned engine behind `Simplex`: one instance per task, never shared; B&B workers each
/// hold one.
public struct SimplexEngine: ~Copyable {
    // MARK: Problem (scaled working copy)

    package let lp: CompiledLP
    let m: Int
    let n: Int
    /// n + m.
    let total: Int
    let config: Simplex
    /// The tolerances in force. They are the strategy's, except inside the refinement pass that
    /// ends an unlimited run (`refine`), which tightens them for its own duration.
    var tol: Tolerances
    var factor: any BasisFactorization

    // MARK: Bounds and costs, one entry per column of [A −I]

    /// Working bounds: the true bounds, possibly perturbed or made artificially finite.
    var lower: [Double]
    var upper: [Double]
    var trueLower: [Double]
    var trueUpper: [Double]
    /// Working costs (logical columns cost 0), possibly perturbed or shifted.
    var cost: [Double]
    var trueCost: [Double]

    // MARK: Basis

    var status: [BasisStatus]
    /// The column at each basis position.
    var head: [Int32]
    /// The basis position of each column; −1 when nonbasic.
    var pos: [Int32]
    /// True while `factor` holds the factors of the columns `head`.
    var hasFactor = false
    /// Incremental hash of the basic set and of the nonbasic-at-upper set.
    var basisHash: UInt64 = 0

    // MARK: Iterates

    var x: [Double]
    var y: [Double]
    var d: [Double]

    // MARK: Pricing state

    /// Primal pricing weights (Devex reference weights or steepest-edge norms).
    var devex: [Double]
    /// Dual steepest-edge weights, one per basis position.
    var dse: [Double]
    /// Columns rejected as entering candidates since the last successful pivot.
    var taboo: [Bool]
    var tabooCount = 0
    var partialSection = 0
    /// True while `d` holds the composite phase-1 reduced costs (nonbasic costs are zero).
    var phase1Pricing = false

    // MARK: Scratch

    var alpha: [Double]
    var rho: [Double]
    var tau: [Double]
    var work: [Double]
    /// m zeros, the additive operand of vDSP calls that only scale.
    let zeros: [Double]
    /// The pivot row ρᵀ[A −I], dense, with the list of touched columns when sparse.
    var rowAlpha: [Double]
    var rowTouched: [Int32]
    /// Marks the columns listed in `rowTouched`, so each is listed once.
    var rowMarked: [Bool]
    var rowIsSparse = true

    // MARK: Counters and state

    var iterations = 0
    var phase1Iterations = 0
    var refactorizations = 0
    var consecutiveResidualFailures = 0
    var iterationsSinceResidualCheck = 0
    var boundsPerturbed = false
    var costsPerturbed = false
    var artificialBounds = false
    /// Set while a clean-up pass runs: no new perturbation may start inside it.
    var suppressPerturbation = false
    /// Pivots taken on entries below the pivot tolerance in this run, because nothing larger
    /// could repair a row or block a step (see `fragilePivotFactor`).
    var fragilePivots = 0
    /// Columns whose true bounds differ from the problem's (branch-and-bound nodes, and the
    /// face a crossover holds).
    var modifiedColumns: [Int32] = []
    var isModified: [Bool]
    var blandRemaining = 0
    var recentHashes = [UInt64](repeating: 0, count: 64)
    var recentHashCount = 0
    var lastProgressIteration = 0
    var bestProgressValue = Double.infinity
    var lastMethod: Simplex.Method
    var warnings: [String] = []
    var rng: UInt64 = 0x5A17_C0DE_1234_5678
    var lastPrimalRay: [Double]? = nil
    var lastDualRay: [Double]? = nil
    /// The outcome of the most recent run and how long it took, for `NodeLPStrategy.rootAnalysis`.
    package var lastOutcome: SimplexOutcome? = nil
    package var lastRunSeconds = 0.0

    // MARK: Run-level resources

    package var metalPolicy: MetalPolicy = .off
    package var kernelProvider: (any CandidateKernelProvider)? = nil
    package var threads = 1
    package var budget: ConcurrencyBudget? = nil
    /// Per-iteration parallelism pays only above these sizes (§7.5): n ≥ 20,000 and
    /// nnz ≥ 200,000. Instance properties so a test can lower them and exercise the path.
    package var parallelColumns = 20_000
    package var parallelNonzeros = 200_000
    package var eventSink: EventSink? = nil
    package var faults = SimplexFaultInjection()
    var scanner: (any ReducedCostScanning)? = nil
    var scannerRequested = false
    var scannerGuard = KernelDisagreementGuard()

    // MARK: Init

    /// Creates an engine on `lp` with the all-logical basis.
    ///
    /// If `lp` is a scaled problem (`lp.scaling != nil`) the engine works on the scaled data
    /// and reports unscaled values. No presolve happens here.
    public init(lp: CompiledLP, strategy: Simplex, factorization: any BasisFactorization) {
        self.lp = lp
        m = lp.m
        n = lp.n
        total = lp.n + lp.m
        config = strategy
        tol = strategy.tolerances.consistent
        factor = factorization
        trueLower = lp.xl + lp.rl
        trueUpper = lp.xu + lp.ru
        lower = trueLower
        upper = trueUpper
        trueCost = lp.c + [Double](repeating: 0, count: lp.m)
        cost = trueCost
        status = [BasisStatus](repeating: .atLower, count: total)
        head = [Int32](repeating: 0, count: lp.m)
        pos = [Int32](repeating: -1, count: total)
        x = [Double](repeating: 0, count: total)
        y = [Double](repeating: 0, count: lp.m)
        d = [Double](repeating: 0, count: total)
        devex = [Double](repeating: 1, count: total)
        dse = [Double](repeating: 1, count: lp.m)
        taboo = [Bool](repeating: false, count: total)
        alpha = [Double](repeating: 0, count: lp.m)
        rho = [Double](repeating: 0, count: lp.m)
        tau = [Double](repeating: 0, count: lp.m)
        work = [Double](repeating: 0, count: lp.m)
        zeros = [Double](repeating: 0, count: lp.m)
        rowAlpha = [Double](repeating: 0, count: total)
        rowTouched = []
        rowMarked = [Bool](repeating: false, count: total)
        isModified = [Bool](repeating: false, count: lp.n + lp.m)
        lastMethod = strategy.method
        installSlackBasis()
    }

    // MARK: Public surface (§7)

    /// Solves from `warmStart` and returns the analysis for the engine's problem.
    ///
    /// Cancellation, the gate's deadline and the iteration limit end in the analysis's
    /// status; nothing but `SolverError` is thrown. `cutoff` is a value of the minimization
    /// objective: the dual method stops as soon as its bound reaches it.
    public mutating func solve(
        method: Simplex.Method, warmStart: WarmStart, cutoff: Double? = nil, gate: inout WorkGate
    ) async throws -> SimplexAnalysis {
        let started = Deadline.now
        let outcome = try await run(method: method, warmStart: warmStart, cutoff: cutoff, iterationLimit: nil, gate: &gate)
        return analysis(from: outcome, seconds: secondsSince(started))
    }

    /// Hot path for branch and bound: replaces the bounds of the named columns. Bounds are
    /// given for the unscaled problem; nonbasic columns move to their new bounds.
    public mutating func applyBoundChanges(_ changes: [BoundChange]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            let j = Int(change.column)
            guard j >= 0, j < n else { continue }
            let scale = lp.scaling?.columns[j] ?? 1
            setTrueBounds(column: j, lower: change.lower / scale, upper: change.upper / scale)
        }
    }

    /// The current basis.
    public var basis: Basis {
        Basis(status: status, basic: head)
    }

    /// Builds the public analysis from an outcome of this engine.
    package func analysis(from outcome: SimplexOutcome, seconds: Double) -> SimplexAnalysis {
        let flip: Double = lp.sense == .maximize ? -1 : 1
        let status = outcome.publicStatus
        var objective: Double? = nil
        var bound: Double? = nil
        if outcome.primalFeasible, outcome.hasPrimalPoint { objective = lp.reportedObjective(outcome.objective) }
        if case .optimal = status {
            bound = objective
        } else if let dualBound = outcome.dualBound {
            bound = lp.reportedObjective(dualBound)
        }
        return SimplexAnalysis(
            base: SolveRecord(
                status: status, objectiveValue: objective, bound: bound,
                primal: outcome.hasPrimalPoint ? outcome.x : nil,
                dual: outcome.hasDualPoint ? outcome.y.map { flip * $0 } : nil,
                reducedCosts: outcome.hasDualPoint ? outcome.d.map { flip * $0 } : nil,
                seconds: seconds, warnings: outcome.warnings),
            method: outcome.finalMethod, basis: outcome.basis, iterations: outcome.iterations,
            phase1Iterations: outcome.phase1Iterations, refactorizations: outcome.refactorizations,
            degeneracy: outcome.degeneracy, primalRay: outcome.primalRay, dualRay: outcome.dualRay)
    }

    // MARK: - Basis bookkeeping

    @inline(__always)
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Hash contribution of column j being basic.
    @inline(__always)
    func basicToken(_ j: Int) -> UInt64 { Self.mix(UInt64(j)) }

    /// Hash contribution of column j being nonbasic at its upper bound.
    @inline(__always)
    func upperToken(_ j: Int) -> UInt64 { Self.mix(UInt64(j) | (1 << 40)) }

    mutating func rebuildHash() {
        var h: UInt64 = 0
        for j in 0..<total {
            if pos[j] >= 0 {
                h ^= basicToken(j)
            } else if status[j] == .atUpper {
                h ^= upperToken(j)
            }
        }
        basisHash = h
    }

    /// The nonbasic status that fits column j's working bounds, as close as possible to `preferred`.
    func nonbasicStatus(_ j: Int, preferred: BasisStatus) -> BasisStatus {
        let lo = lower[j]
        let up = upper[j]
        if lo == up { return .fixed }
        let hasLower = lo > -.infinity
        let hasUpper = up < .infinity
        switch preferred {
        case .atLower where hasLower: return .atLower
        case .atUpper where hasUpper: return .atUpper
        default: break
        }
        if hasLower && hasUpper {
            // Nearest bound to the current value.
            return Swift.abs(x[j] - lo) <= Swift.abs(up - x[j]) ? .atLower : .atUpper
        }
        if hasLower { return .atLower }
        if hasUpper { return .atUpper }
        return .free
    }

    /// Puts a nonbasic column on the value its status names.
    mutating func placeNonbasic(_ j: Int) {
        switch status[j] {
        case .atLower, .fixed: x[j] = lower[j]
        case .atUpper: x[j] = upper[j]
        case .free: x[j] = 0
        case .basic: break
        }
    }

    /// The all-logical basis: always available, trivially nonsingular (§5.5).
    mutating func installSlackBasis() {
        for j in 0..<n {
            pos[j] = -1
            status[j] = Basis.nonbasicStatus(lower: lower[j], upper: upper[j])
            placeNonbasic(j)
        }
        for i in 0..<m {
            head[i] = Int32(n + i)
            pos[n + i] = Int32(i)
            status[n + i] = .basic
        }
        hasFactor = false
        for i in 0..<m { dse[i] = 1 }
        resetPricingWeights()
        rebuildHash()
    }

    /// Reference weights for a fresh framework: 1 for Devex and Dantzig, 1 + ‖a_j‖² for
    /// steepest edge (exact for the all-logical basis).
    mutating func resetPricingWeights() {
        if case .steepestEdge = config.pricing {
            for j in 0..<n {
                var norm = 1.0
                for p in lp.a.colStart[j]..<lp.a.colStart[j + 1] { norm += lp.a.values[p] * lp.a.values[p] }
                devex[j] = norm
            }
            for i in 0..<m { devex[n + i] = 2 }
        } else {
            for j in 0..<total { devex[j] = 1 }
        }
    }

    /// Replaces the true bounds of a column (in the engine's scaled space), keeping the
    /// working bounds, status and value consistent.
    mutating func setTrueBounds(column j: Int, lower lo: Double, upper up: Double) {
        if !isModified[j] {
            isModified[j] = true
            modifiedColumns.append(Int32(j))
        }
        trueLower[j] = lo
        trueUpper[j] = up
        lower[j] = lo
        upper[j] = up
        guard pos[j] < 0 else { return }
        let before = status[j]
        let after = nonbasicStatus(j, preferred: before)
        if before == .atUpper { basisHash ^= upperToken(j) }
        status[j] = after
        if after == .atUpper { basisHash ^= upperToken(j) }
        placeNonbasic(j)
    }

    // MARK: - Pivots below the tolerance

    /// A ratio test that finds no entry above the pivot tolerance looks once more at entries
    /// down to this fraction of it. Without that second look a row that only a small entry can
    /// repair would be read as a proof of infeasibility, and a step that only a small entry
    /// blocks as unbounded. Such a pivot is followed by a refactorization.
    static var fragilePivotFactor: Double { 1e-3 }

    /// How many such pivots one run may take before it gives up with a numerical failure.
    var fragilePivotLimit: Int { m + 50 }

    // MARK: - Linear algebra on the basis

    /// (Re)factors the basis. A singular basis is repaired by swapping deficient columns for
    /// logicals; if that keeps failing the engine falls back to the all-logical basis, which
    /// cannot fail, so this never loops (rule L6).
    mutating func refactorize() throws {
        var attempts = 0
        while true {
            do throws(NumericalError) {
                try factor.refactor(basic: head, lp: lp)
                break
            } catch {
                attempts += 1
                if attempts > 6 {
                    throw EngineFailure.numerical("the basis could not be factored: \(error)")
                }
                if attempts <= 4, case .singular(let positions, let rows) = error, !positions.isEmpty {
                    repairBasis(positions: positions, rows: rows)
                } else {
                    installSlackBasis()
                }
            }
        }
        hasFactor = true
        refactorizations += 1
        iterationsSinceResidualCheck = 0
    }

    /// Replaces each deficient basic column by the logical of the row it failed to cover.
    mutating func repairBasis(positions: [Int32], rows: [Int32]) {
        for (k, position) in positions.enumerated() {
            let r = Int(position)
            var logical = n + Int(rows[k])
            if pos[logical] >= 0 {
                // That logical is already basic: take any nonbasic logical instead.
                guard let other = (0..<m).first(where: { pos[n + $0] < 0 }) else { continue }
                logical = n + other
            }
            let evicted = Int(head[r])
            if status[logical] == .atUpper { basisHash ^= upperToken(logical) }
            head[r] = Int32(logical)
            pos[logical] = Int32(r)
            status[logical] = .basic
            basisHash ^= basicToken(logical)
            pos[evicted] = -1
            basisHash ^= basicToken(evicted)
            status[evicted] = nonbasicStatus(evicted, preferred: .atLower)
            if status[evicted] == .atUpper { basisHash ^= upperToken(evicted) }
            placeNonbasic(evicted)
        }
        for i in 0..<m { dse[i] = 1 }
    }

    /// x_B = B⁻¹(−N·x_N): the basic values that go with the current nonbasic values.
    mutating func computePrimals() {
        for i in 0..<m { work[i] = 0 }
        for j in 0..<n where pos[j] < 0 {
            let xj = x[j]
            if xj != 0 { lp.a.axpy(column: j, -xj, into: &work) }
        }
        for i in 0..<m where pos[n + i] < 0 {
            work[i] += x[n + i]
        }
        factor.ftran(&work)
        for k in 0..<m { x[Int(head[k])] = work[k] }
    }

    /// y = B⁻ᵀc_B and d = c − [A −I]ᵀy for the working costs.
    mutating func computeDuals() {
        for k in 0..<m { work[k] = cost[Int(head[k])] }
        factor.btran(&work)
        for i in 0..<m { y[i] = work[i] }
        for j in 0..<n {
            d[j] = pos[j] >= 0 ? 0 : cost[j] - lp.a.dot(column: j, y)
        }
        for i in 0..<m {
            d[n + i] = pos[n + i] >= 0 ? 0 : cost[n + i] + y[i]
        }
    }

    /// α = B⁻¹a_q into `alpha`.
    mutating func ftranColumn(_ q: Int) {
        for i in 0..<m { alpha[i] = 0 }
        if q < n {
            lp.a.scatter(column: q, into: &alpha)
        } else {
            alpha[q - n] = -1
        }
        factor.ftran(&alpha)
    }

    /// ρ = B⁻ᵀe_r into `rho`, then the pivot row ρᵀ[A −I] into `rowAlpha`.
    ///
    /// A sparse ρ is multiplied row-wise through the CSR view (the hyper-sparse path, §6.2);
    /// a dense one column-wise, in parallel over column blocks above the thresholds of §7.5.
    mutating func computePivotRow(_ r: Int) async {
        for i in 0..<m { rho[i] = 0 }
        rho[r] = 1
        factor.btran(&rho)
        await computeRowProduct()
    }

    /// `rowAlpha` = ρᵀ[A −I] for the current `rho`.
    mutating func computeRowProduct() async {
        clearPivotRow()
        var nonzeros = 0
        for i in 0..<m where rho[i] != 0 { nonzeros += 1 }
        let dense = Double(nonzeros) > IndexedVector.sparseDensity * Double(m)
        if dense {
            rowIsSparse = false
            let parallel = n >= parallelColumns && lp.nnz >= parallelNonzeros && threads > 1 && budget != nil
            if parallel {
                let matrix = lp.a
                let vector = rho
                let blocks = Swift.min(threads, 8)
                let parts = await parallelBlocks(count: n, blocks: blocks, budget: budget) { range in
                    matrix.multiplyTranspose(vector, columns: range)
                }
                var offset = 0
                for part in parts {
                    for value in part {
                        rowAlpha[offset] = value
                        offset += 1
                    }
                }
            } else {
                for j in 0..<n { rowAlpha[j] = lp.a.dot(column: j, rho) }
            }
            for i in 0..<m { rowAlpha[n + i] = -rho[i] }
        } else {
            rowIsSparse = true
            let aT = lp.aT
            for i in 0..<m {
                let ri = rho[i]
                if ri == 0 { continue }
                for p in aT.colStart[i]..<aT.colStart[i + 1] {
                    let j = Int(aT.rowIndex[p])
                    if !rowMarked[j] {
                        rowMarked[j] = true
                        rowTouched.append(Int32(j))
                    }
                    rowAlpha[j] += ri * aT.values[p]
                }
                rowAlpha[n + i] = -ri
                rowMarked[n + i] = true
                rowTouched.append(Int32(n + i))
            }
        }
    }

    mutating func clearPivotRow() {
        if rowIsSparse {
            for j in rowTouched {
                rowAlpha[Int(j)] = 0
                rowMarked[Int(j)] = false
            }
        } else {
            for j in 0..<total { rowAlpha[j] = 0 }
        }
        rowTouched.removeAll(keepingCapacity: true)
        rowIsSparse = true
    }

    /// ‖B·x_B − b‖∞ ≤ 1e-6·(1 + ‖b‖∞) with b = −N·x_N (§6.3).
    func residualIsAcceptable() -> Bool {
        var residual = [Double](repeating: 0, count: m)
        var rhs = [Double](repeating: 0, count: m)
        for j in 0..<n {
            let xj = x[j]
            if xj == 0 { continue }
            lp.a.axpy(column: j, xj, into: &residual)
            if pos[j] < 0 { lp.a.axpy(column: j, xj, into: &rhs) }
        }
        for i in 0..<m {
            residual[i] -= x[n + i]
            if pos[n + i] < 0 { rhs[i] -= x[n + i] }
        }
        return Vec.maxAbs(residual) <= 1e-6 * (1 + Vec.maxAbs(rhs))
    }

    /// The residual check of §6.3 and §7.3. A failure triggers an immediate refactorization
    /// and a recomputation of x_B; three consecutive failures end the solve.
    /// Returns true when the iterates were recomputed.
    mutating func checkResidual() throws -> Bool {
        iterationsSinceResidualCheck = 0
        var recomputed = false
        while true {
            var acceptable = residualIsAcceptable()
            if faults.failingResidualChecks > 0 {
                faults.failingResidualChecks -= 1
                acceptable = false
            }
            if acceptable {
                consecutiveResidualFailures = 0
                return recomputed
            }
            consecutiveResidualFailures += 1
            if consecutiveResidualFailures >= 3 {
                throw EngineFailure.numerical("the basis residual check failed three times in a row")
            }
            try refactorize()
            computePrimals()
            recomputed = true
        }
    }

    // MARK: - Measures

    /// The sum and the maximum of the bound violations of the basic variables.
    func primalInfeasibility() -> (sum: Double, max: Double) {
        var sum = 0.0
        var largest = 0.0
        for k in 0..<m {
            let j = Int(head[k])
            let v = x[j]
            let violation = Swift.max(lower[j] - v, v - upper[j], 0)
            if violation > tol.primalFeasibility {
                sum += violation
                if violation > largest { largest = violation }
            }
        }
        return (sum, largest)
    }

    /// The largest reduced-cost sign violation over the nonbasic columns.
    func dualInfeasibility() -> Double {
        var largest = 0.0
        for j in 0..<total where pos[j] < 0 {
            let dj = d[j]
            let violation: Double
            switch status[j] {
            case .atLower: violation = -dj
            case .atUpper: violation = dj
            case .free: violation = Swift.abs(dj)
            default: violation = 0
            }
            if violation > largest { largest = violation }
        }
        return largest
    }

    /// cᵀx + c₀ with the true costs.
    func objectiveValue() -> Double {
        var total = lp.c0
        for j in 0..<n { total += trueCost[j] * x[j] }
        return total
    }

    /// Fraction of basic variables sitting on a bound.
    func degeneracyFraction() -> Double {
        guard m > 0 else { return 0 }
        var count = 0
        for k in 0..<m {
            let j = Int(head[k])
            let v = x[j]
            if Swift.abs(v - lower[j]) <= tol.primalFeasibility || Swift.abs(upper[j] - v) <= tol.primalFeasibility {
                count += 1
            }
        }
        return Double(count) / Double(m)
    }

    mutating func nextRandom() -> Double {
        rng = Self.mix(rng)
        return Double(rng >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    // MARK: - Cycling and stalling (§7.3)

    /// Records the current basis in the ring buffer. A basis seen among the last 64 means the
    /// method is cycling: refactor and switch to Bland's rule for 50 iterations.
    mutating func noteBasisAndDetectCycle() -> Bool {
        let h = basisHash
        let filled = Swift.min(recentHashCount, 64)
        var repeated = false
        for k in 0..<filled where recentHashes[k] == h {
            repeated = true
            break
        }
        recentHashes[recentHashCount % 64] = h
        recentHashCount += 1
        return repeated
    }

    mutating func clearCycleHistory() {
        recentHashCount = 0
    }

    // MARK: - Events

    func report(phase: Int, infeasibility: Double) async {
        guard let eventSink, eventSink.hasListener, iterations % 100 == 0 else { return }
        await eventSink.emit(
            .simplexIteration(
                iteration: iterations, objective: lp.reportedObjective(objectiveValue()),
                infeasibility: infeasibility, phase: phase))
    }

    mutating func warn(_ text: String) async {
        warnings.append(text)
        if let eventSink { await eventSink.warn(text) }
    }

    // MARK: - Results

    /// Packs the current iterates into an outcome, unscaled.
    func makeOutcome(_ status: SimplexOutcome.Status, dualFeasible: Bool, primalFeasible: Bool) -> SimplexOutcome {
        var xs = Array(x[0..<n])
        var ys = y
        var ds = d
        var primalRay = lastPrimalRay
        var dualRay = lastDualRay
        if let scaling = lp.scaling {
            xs = scaling.unscalePrimal(xs)
            ys = scaling.unscaleDual(ys)
            ds = scaling.unscaleReducedCosts(ds)
            primalRay = primalRay.map { scaling.unscalePrimal($0) }
            dualRay = dualRay.map { scaling.unscaleDual($0) }
        }
        let objective = objectiveValue()
        return SimplexOutcome(
            status: status, finalMethod: lastMethod, objective: objective,
            dualBound: dualFeasible && !costsPerturbed && !artificialBounds ? objective : nil,
            primalFeasible: primalFeasible, dualFeasible: dualFeasible, x: xs, y: ys, d: ds,
            basis: Basis(status: status == .optimal ? cleanedStatuses() : self.status, basic: head),
            primalRay: primalRay, dualRay: dualRay, iterations: iterations,
            phase1Iterations: phase1Iterations, refactorizations: refactorizations,
            degeneracy: degeneracyFraction(), warnings: warnings)
    }

    /// Statuses with fixed columns labelled as such, for the reported basis.
    func cleanedStatuses() -> [BasisStatus] {
        var result = status
        for j in 0..<total where pos[j] < 0 && trueLower[j] == trueUpper[j] { result[j] = .fixed }
        return result
    }
}

extension SimplexOutcome.Status: Equatable {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.optimal, .optimal), (.infeasible, .infeasible), (.unbounded, .unbounded),
             (.cutoff, .cutoff), (.iterationLimit, .iterationLimit):
            return true
        case (.stopped(let a), .stopped(let b)): return a == b
        case (.numericalFailure(let a), .numericalFailure(let b)): return a == b
        default: return false
        }
    }
}
