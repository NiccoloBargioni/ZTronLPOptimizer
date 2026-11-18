// The CDCL core: literals, trail and propagators (specification §10.2).
//
// Every variable is an integer with a current domain [lb, ub]; a Boolean is the domain [0, 1].
//
//   * Literals. An atom is a pair (variable, value) meaning [x ≥ value], created on demand
//     and interned per (variable, value). Literal 2·atom is [x ≥ value]; literal 2·atom + 1 is
//     its negation [x ≤ value − 1]. A literal's truth value is read off the bounds, so the
//     implications between the atoms of one variable never need clauses.
//   * Trail. Each entry is one bound change with its reason (lazy clause generation): the
//     reason is the set of bound literals of the other variables that implied it, and it is
//     only spelled out when conflict analysis asks.
//   * Clause propagator. Two watched literals; problem clauses and learned clauses are over
//     Boolean and bound literals alike.
//   * Linear propagator. Bounds consistency on Σ aᵢxᵢ ≤ rhs with the minimum activity
//     maintained incrementally in Int64. A range or equality row is two such constraints, so
//     both its minimum and its maximum activity are tracked.
//
// One worker owns all of this state. It is non-copyable and lives inside one task (rule C4).

import ZTronLPCore
import ZTronLPNumerics
import ZTronLPSimplex

/// One entry of a watch list: a clause — by the position of its first literal in the clause
/// arena — and a literal of it that, when true, makes visiting the clause unnecessary.
struct Watcher {
    var clause: Int32
    var blocker: Int32
}

/// One bound change.
struct TrailEntry {
    var variable: Int32
    /// The previous entry for the same variable and side; −1 when this is the first.
    var previous: Int32
    var old: Int64
    var new: Int64
    /// A clause reference (arena position) or a constraint index, according to the reason kind.
    var reason: Int32
    var level: Int32
    /// Bit 0: a lower-bound change. Bits 1…2: the reason kind.
    var flags: UInt8

    @inline(__always) var isLower: Bool { flags & 1 != 0 }
    @inline(__always) var reasonKind: UInt8 { flags >> 1 }
}

enum ReasonKind {
    /// A decision, or a fact of level 0.
    static let none: UInt8 = 0
    static let clause: UInt8 = 1
    static let linear: UInt8 = 2
    /// A row the LP propagator derived (`Relaxation`); the reason is its index on the stack.
    static let cut: UInt8 = 3
}

/// What propagation ran into.
enum Conflict {
    /// Every literal of the clause (given by its arena position) is false.
    case clause(Int32)
    /// The minimum activity of the constraint exceeds its right-hand side.
    case linear(Int32)
    /// The same, for a row the LP propagator derived (by its index on the stack).
    case cut(Int32)
}

/// How a worker picks the side of a decision (§10.3).
enum PhaseStrategy: Sendable, Hashable {
    /// Lower-bound-first ([x ≤ lb]) with phase saving: the specification's default.
    case lowerBoundFirst
    /// Either end, at random.
    case random
    /// First toward the end the objective prefers, then phase saving.
    case objective
}

/// The configuration of one portfolio worker.
struct WorkerOptions: Sendable {
    var index = 0
    var seed: UInt64 = 0
    var phase = PhaseStrategy.lowerBoundFirst
    /// Keep learned clauses by LBD alone when the database is reduced.
    var lbdOnlyRetention = false
    var restarts = RestartPolicy.luby(unit: 100)
    var clauseSharing = false
    /// Bytes this worker may use for its own state; learned clauses are forgotten beyond it.
    var memoryAllowance = Int.max
    /// Keep a portable copy of every learned clause, for the soundness test.
    var recordLearnedClauses = false
    /// Values to steer the first decisions toward (a warm start's primal point).
    var hints: [Int64]? = nil
    /// The number of removable learned clauses (LBD > 2) at which the database is halved.
    var reductionInterval = 20_000
    /// The relaxation to propagate with (`CPSAT(lpPropagator: true)`); `nil` for a pure CDCL worker.
    var relaxation: RelaxationData? = nil
}

/// A small generator private to a worker; its stream depends only on the seed.
struct WorkerRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// A binary max-heap of variables ordered by activity, with positions so an entry can be
/// moved when its activity grows. Ties go to the lower index, which keeps runs reproducible.
struct ActivityHeap {
    private var heap: [Int32] = []
    private var position: [Int32]

    init(capacity: Int) {
        position = [Int32](repeating: -1, count: capacity)
        heap.reserveCapacity(capacity)
    }

    var isEmpty: Bool { heap.isEmpty }

    @inline(__always)
    func contains(_ x: Int) -> Bool { position[x] >= 0 }

    @inline(__always)
    private func ranksAbove(_ a: Int32, _ b: Int32, _ activity: [Double]) -> Bool {
        let (x, y) = (activity[Int(a)], activity[Int(b)])
        return x > y || (x == y && a < b)
    }

    mutating func insert(_ x: Int, _ activity: [Double]) {
        guard position[x] < 0 else { return }
        heap.append(Int32(x))
        position[x] = Int32(heap.count - 1)
        siftUp(heap.count - 1, activity)
    }

    mutating func removeMax(_ activity: [Double]) -> Int? {
        guard let top = heap.first else { return nil }
        let last = heap.removeLast()
        position[Int(top)] = -1
        if !heap.isEmpty {
            heap[0] = last
            position[Int(last)] = 0
            siftDown(0, activity)
        }
        return Int(top)
    }

    /// Restores the heap after the activity of `x` grew.
    mutating func increased(_ x: Int, _ activity: [Double]) {
        let p = Int(position[x])
        if p >= 0 { siftUp(p, activity) }
    }

    private mutating func siftUp(_ start: Int, _ activity: [Double]) {
        var i = start
        let item = heap[i]
        while i > 0 {
            let parent = (i - 1) >> 1
            if !ranksAbove(item, heap[parent], activity) { break }
            heap[i] = heap[parent]
            position[Int(heap[i])] = Int32(i)
            i = parent
        }
        heap[i] = item
        position[Int(item)] = Int32(i)
    }

    private mutating func siftDown(_ start: Int, _ activity: [Double]) {
        var i = start
        let item = heap[i]
        let count = heap.count
        while true {
            var child = 2 * i + 1
            if child >= count { break }
            if child + 1 < count, ranksAbove(heap[child + 1], heap[child], activity) { child += 1 }
            if !ranksAbove(heap[child], item, activity) { break }
            heap[i] = heap[child]
            position[Int(heap[i])] = Int32(i)
            i = child
        }
        heap[i] = item
        position[Int(item)] = Int32(i)
    }
}

/// A learned clause in portable form, with the objective bound it was derived under.
struct RecordedClause: Sendable {
    let literals: [BoundLiteral]
    let objectiveBound: Int64
}

/// The worker-owned CDCL engine. One instance per task, never shared (rule C4).
struct CPWorker: ~Copyable {
    let model: CPModel
    let options: WorkerOptions
    var random: WorkerRandom

    // MARK: Domains

    var lb: [Int64]
    var ub: [Int64]
    /// The bounds as of the end of level 0: literals they imply are permanently true.
    var rootLower: [Int64]
    var rootUpper: [Int64]
    /// The latest trail entry of each variable's lower / upper bound; −1 when none.
    var lbEntry: [Int32]
    var ubEntry: [Int32]

    // MARK: Trail

    var trail: [TrailEntry] = []
    /// The trail index at which each decision level starts.
    var levelStart: [Int32] = []
    /// The next trail entry whose falsified literals have not been visited.
    var head = 0

    // MARK: Atoms and clauses

    var atomVariable: [Int32] = []
    var atomValue: [Int64] = []
    /// The interned values of each variable, ascending, with the atom of each.
    var atomValuesOf: [[Int64]]
    var atomIDsOf: [[Int32]]
    /// Per literal: the clauses that watch it.
    var watches: [[Watcher]] = []
    /// Per literal: 1 true, −1 false, 0 undecided. Derived from the bounds and kept in step
    /// with them, so the propagator reads one byte instead of two bounds.
    var literalValue: [Int8] = []

    /// Per clause index: the arena position of its first literal, and its metadata.
    var clauseStart: [Int32] = []
    var clauseSize: [Int32] = []
    var clauseLBD: [Int32] = []
    var clauseLearned: [Bool] = []
    var clauseActivity: [Float] = []
    /// The clause arena. Each clause is stored as `index, size, literal, literal, …`; a clause
    /// reference is the position of its first literal, so the propagator finds the size next
    /// to the literals it is about to read. The two watched literals come first.
    var literals: [Int32] = []
    var clauseIncrement: Float = 1
    /// Learned clauses currently in the database, and how many of them a reduction may remove
    /// (those of LBD > 2).
    var liveLearned = 0
    var reducibleLearned = 0

    // MARK: Linear constraints

    var linRHS: [Int64]
    var linMinAct: [Int64]
    var linQueued: [Bool]
    var linQueue: [Int32] = []
    var linQueueHead = 0

    // MARK: Decisions

    var activity: [Double]
    var activityIncrement = 1.0
    var heap: ActivityHeap
    var savedValue: [Int64]
    var hasSavedValue: [Bool]

    // MARK: Conflict analysis scratch

    /// The nogood under construction: per variable, the bound literal it contains (none when
    /// `Int64.min` / `Int64.max`) and the trail entry that made that literal true.
    var needLower: [Int64]
    var needUpper: [Int64]
    var needLowerEntry: [Int32]
    var needUpperEntry: [Int32]
    /// Nogood literals that minimization may not remove (see `literalIsRedundant`).
    var pinnedLower: [Bool]
    var pinnedUpper: [Bool]
    /// (variable << 1 | isLower) of everything put into the nogood, for cleanup.
    var touched: [Int32] = []
    var pathCount = 0
    var analysisLevel: Int32 = 0
    var reasonBuffer: [BoundLiteral] = []
    var boundScratch: [Int64] = []
    var learnedLiterals: [Int32] = []
    /// Per trail entry: 0 unknown, 1 redundant, 2 not redundant.
    var minimizeMark: [UInt8] = []
    var minimizeMarked: [Int32] = []
    var minimizeBuffers: [[BoundLiteral]]
    var minimizeBudget = 0
    var levelStamp: [Int32] = []
    var stampCounter: Int32 = 0
    var clauseScratch: [Int32] = []

    // MARK: Bookkeeping

    /// True once level 0 is contradictory: the search is over.
    var rootConflict = false
    var conflicts = 0
    var decisions = 0
    var propagations = 0
    var restarts = 0
    var learnedTotal = 0
    /// How many times the clause database was reduced, and how many of those reductions
    /// freed and renumbered bound literals.
    var reductions = 0
    var renumberings = 0
    var pendingExports: [[BoundLiteral]] = []
    var recorded: [RecordedClause] = []

    // MARK: LP propagator

    /// The derived rows and the latest relaxation of an LP worker (LPRelaxation.swift), and
    /// the engine that solves it — owned by this worker like everything else (rule C4).
    var relaxation = RelaxationState()
    var relaxationEngine: SimplexEngine? = nil

    static let minimizeDepth = 16

    init(model: CPModel, options: WorkerOptions) {
        self.model = model
        self.options = options
        random = WorkerRandom(seed: options.seed)
        let n = model.variableCount
        lb = model.lower
        ub = model.upper
        rootLower = model.lower
        rootUpper = model.upper
        lbEntry = [Int32](repeating: -1, count: n)
        ubEntry = [Int32](repeating: -1, count: n)
        atomValuesOf = [[Int64]](repeating: [], count: n)
        atomIDsOf = [[Int32]](repeating: [], count: n)
        linRHS = model.linRHS
        linMinAct = model.linMinActivity
        linQueued = [Bool](repeating: false, count: model.constraintCount)
        activity = [Double](repeating: 0, count: n)
        heap = ActivityHeap(capacity: n)
        savedValue = [Int64](repeating: 0, count: n)
        hasSavedValue = [Bool](repeating: false, count: n)
        needLower = [Int64](repeating: .min, count: n)
        needUpper = [Int64](repeating: .max, count: n)
        needLowerEntry = [Int32](repeating: -1, count: n)
        needUpperEntry = [Int32](repeating: -1, count: n)
        pinnedLower = [Bool](repeating: false, count: n)
        pinnedUpper = [Bool](repeating: false, count: n)
        minimizeBuffers = [[BoundLiteral]](repeating: [], count: Self.minimizeDepth + 1)

        // Worker 0 starts from the natural order; the others from a seeded shuffle of it, so
        // the portfolio explores different parts of the tree from the first decision on.
        if options.index != 0 {
            for x in 0..<n { activity[x] = random.uniform() * 1e-3 }
        }
        if let hints = options.hints, hints.count == n {
            for x in 0..<n {
                savedValue[x] = Swift.min(Swift.max(hints[x], model.lower[x]), model.upper[x])
                hasSavedValue[x] = true
            }
        }
        for x in 0..<n { heap.insert(x, activity) }

        if model.infeasibleReason != nil { rootConflict = true }
        for clause in model.clauses where !rootConflict {
            if !addRootClause(clause, learned: false, lbd: 0, activity: 0) { rootConflict = true }
        }
        // Every constraint gets one look at the root domains.
        for c in 0..<model.constraintCount {
            linQueued[c] = true
            linQueue.append(Int32(c))
        }
        if let data = options.relaxation, !rootConflict {
            relaxation = RelaxationState(data: data)
            relaxationEngine = RelaxationState.makeEngine(for: data)
        }
    }

    @inline(__always) var currentLevel: Int { levelStart.count }

    // MARK: - Literals

    /// 1 when the literal is true, −1 when false, 0 when the bounds do not decide it.
    @inline(__always)
    func value(of literal: Int32) -> Int8 {
        literalValue[Int(literal)]
    }

    /// Sets the cached truth value of every atom [x ≥ v] with `above < v ≤ upTo`: `truth` for
    /// the atom itself and its opposite for the negation.
    @inline(__always)
    mutating func markAtoms(of x: Int, above: Int64, upTo: Int64, truth: Int8) {
        let count = atomValuesOf[x].count
        if count == 0 { return }
        var k = 0
        if count > 1 {
            var lo = 0
            var hi = count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if atomValuesOf[x][mid] <= above { lo = mid + 1 } else { hi = mid }
            }
            k = lo
        } else if atomValuesOf[x][0] <= above {
            return
        }
        while k < count, atomValuesOf[x][k] <= upTo {
            let positive = Int(atomIDsOf[x][k]) << 1
            literalValue[positive] = truth
            literalValue[positive | 1] = -truth
            k += 1
        }
    }

    /// The atom [x ≥ value], created on first use. `value` must lie in (root lb, root ub].
    mutating func intern(_ x: Int, _ value: Int64) -> Int32 {
        // Binary search in the variable's sorted values.
        var lo = 0
        var hi = atomValuesOf[x].count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if atomValuesOf[x][mid] < value { lo = mid + 1 } else { hi = mid }
        }
        if lo < atomValuesOf[x].count, atomValuesOf[x][lo] == value { return atomIDsOf[x][lo] }
        let atom = Int32(atomVariable.count)
        atomVariable.append(Int32(x))
        atomValue.append(value)
        atomValuesOf[x].insert(value, at: lo)
        atomIDsOf[x].insert(atom, at: lo)
        watches.append([])
        watches.append([])
        let truth: Int8 = lb[x] >= value ? 1 : (ub[x] < value ? -1 : 0)
        literalValue.append(truth)
        literalValue.append(-truth)
        return atom
    }

    /// The portable form of an interned literal.
    func boundLiteral(_ literal: Int32) -> BoundLiteral {
        let atom = Int(literal >> 1)
        return literal & 1 == 0
            ? BoundLiteral(variable: atomVariable[atom], isLower: true, value: atomValue[atom])
            : BoundLiteral(variable: atomVariable[atom], isLower: false, value: atomValue[atom] - 1)
    }

    // MARK: - Bound changes

    /// Raises the lower bound of `x` to `value`. Requires `lb[x] < value ≤ ub[x]`.
    @inline(__always)
    mutating func setLower(_ x: Int, _ value: Int64, _ kind: UInt8, _ reason: Int32) {
        let old = lb[x]
        trail.append(
            TrailEntry(
                variable: Int32(x), previous: lbEntry[x], old: old, new: value, reason: reason,
                level: Int32(levelStart.count), flags: 1 | (kind << 1)))
        lbEntry[x] = Int32(trail.count - 1)
        lb[x] = value
        if levelStart.isEmpty { rootLower[x] = value }
        markAtoms(of: x, above: old, upTo: value, truth: 1)
        let delta = value - old
        var t = Int(model.occPosStart[x])
        let end = Int(model.occPosStart[x + 1])
        while t < end {
            let c = Int(model.occPosRow[t])
            linMinAct[c] += model.occPosCoef[t] * delta
            // Only a constraint whose slack fell below its largest term can do anything.
            if !linQueued[c] && linRHS[c] - linMinAct[c] < model.linMaxTerm[c] {
                linQueued[c] = true
                linQueue.append(Int32(c))
            }
            t += 1
        }
    }

    /// Lowers the upper bound of `x` to `value`. Requires `lb[x] ≤ value < ub[x]`.
    @inline(__always)
    mutating func setUpper(_ x: Int, _ value: Int64, _ kind: UInt8, _ reason: Int32) {
        let old = ub[x]
        trail.append(
            TrailEntry(
                variable: Int32(x), previous: ubEntry[x], old: old, new: value, reason: reason,
                level: Int32(levelStart.count), flags: kind << 1))
        ubEntry[x] = Int32(trail.count - 1)
        ub[x] = value
        if levelStart.isEmpty { rootUpper[x] = value }
        markAtoms(of: x, above: value, upTo: old, truth: -1)
        let delta = value - old   // negative
        var t = Int(model.occNegStart[x])
        let end = Int(model.occNegStart[x + 1])
        while t < end {
            let c = Int(model.occNegRow[t])
            linMinAct[c] += model.occNegCoef[t] * delta
            if !linQueued[c] && linRHS[c] - linMinAct[c] < model.linMaxTerm[c] {
                linQueued[c] = true
                linQueue.append(Int32(c))
            }
            t += 1
        }
    }

    /// Makes an unassigned literal true.
    @inline(__always)
    mutating func assign(_ literal: Int32, _ kind: UInt8, _ reason: Int32) {
        let atom = Int(literal >> 1)
        let x = Int(atomVariable[atom])
        if literal & 1 == 0 {
            setLower(x, atomValue[atom], kind, reason)
        } else {
            setUpper(x, atomValue[atom] - 1, kind, reason)
        }
    }

    /// Makes a literal true at level 0. Returns false when it is already false there.
    mutating func enqueueRoot(_ literal: Int32) -> Bool {
        switch value(of: literal) {
        case 1: return true
        case -1: return false
        default:
            assign(literal, ReasonKind.none, -1)
            return true
        }
    }

    mutating func newDecisionLevel() {
        levelStart.append(Int32(trail.count))
    }

    /// Undoes every bound change above `level`.
    mutating func cancelUntil(_ level: Int) {
        guard levelStart.count > level else { return }
        let target = Int(levelStart[level])
        var i = trail.count - 1
        while i >= target {
            let e = trail[i]
            let x = Int(e.variable)
            if lb[x] == ub[x] {
                // Phase saving: remember the value the variable is about to lose.
                savedValue[x] = lb[x]
                hasSavedValue[x] = true
                if !heap.contains(x) { heap.insert(x, activity) }
            }
            if e.isLower {
                lb[x] = e.old
                lbEntry[x] = e.previous
                markAtoms(of: x, above: e.old, upTo: e.new, truth: 0)
                let delta = e.new - e.old
                var t = Int(model.occPosStart[x])
                let end = Int(model.occPosStart[x + 1])
                while t < end {
                    linMinAct[Int(model.occPosRow[t])] -= model.occPosCoef[t] * delta
                    t += 1
                }
            } else {
                ub[x] = e.old
                ubEntry[x] = e.previous
                markAtoms(of: x, above: e.new, upTo: e.old, truth: 0)
                let delta = e.new - e.old
                var t = Int(model.occNegStart[x])
                let end = Int(model.occNegStart[x + 1])
                while t < end {
                    linMinAct[Int(model.occNegRow[t])] -= model.occNegCoef[t] * delta
                    t += 1
                }
            }
            i -= 1
        }
        trail.removeSubrange(target...)
        levelStart.removeSubrange(level...)
        head = Swift.min(head, target)
        clearLinearQueue()
        // Derived rows that no remaining trail entry can refer to go with the entries.
        if relaxation.enabled { relaxation.popRows(from: target) }
    }

    mutating func clearLinearQueue() {
        while linQueueHead < linQueue.count {
            linQueued[Int(linQueue[linQueueHead])] = false
            linQueueHead += 1
        }
        linQueue.removeAll(keepingCapacity: true)
        linQueueHead = 0
    }

    // MARK: - Clauses

    /// Stores a clause of at least two literals and watches its first two. Returns the clause
    /// reference: the arena position of its first literal.
    @discardableResult
    mutating func attachClause(_ lits: [Int32], learned: Bool, lbd: Int32, activity: Float) -> Int32 {
        literals.append(Int32(clauseStart.count))
        literals.append(Int32(lits.count))
        let reference = Int32(literals.count)
        clauseStart.append(reference)
        clauseSize.append(Int32(lits.count))
        clauseLBD.append(lbd)
        clauseLearned.append(learned)
        clauseActivity.append(activity)
        literals.append(contentsOf: lits)
        watches[Int(lits[0])].append(Watcher(clause: reference, blocker: lits[1]))
        watches[Int(lits[1])].append(Watcher(clause: reference, blocker: lits[0]))
        if learned {
            liveLearned += 1
            if lbd > 2 { reducibleLearned += 1 }
        }
        return reference
    }

    /// Adds a clause at level 0, simplified against the root domains: literals that are false
    /// forever are dropped and a clause that is true forever is not stored. Returns false when
    /// the clause is violated at level 0.
    mutating func addRootClause(_ clause: [BoundLiteral], learned: Bool, lbd: Int32, activity: Float) -> Bool {
        clauseScratch.removeAll(keepingCapacity: true)
        for literal in clause {
            let x = Int(literal.variable)
            if literal.isLower {
                if lb[x] >= literal.value { return true }
                if ub[x] < literal.value { continue }
                clauseScratch.append(intern(x, literal.value) << 1)
            } else {
                if ub[x] <= literal.value { return true }
                if lb[x] > literal.value { continue }
                clauseScratch.append(intern(x, literal.value + 1) << 1 | 1)
            }
        }
        if clauseScratch.count > 1 {
            clauseScratch.sort()
            var kept: [Int32] = []
            kept.reserveCapacity(clauseScratch.count)
            for literal in clauseScratch {
                if let last = kept.last {
                    if last == literal { continue }                    // duplicate
                    if last ^ 1 == literal { return true }             // ℓ ∨ ¬ℓ
                }
                kept.append(literal)
            }
            clauseScratch = kept
        }
        if clauseScratch.isEmpty { return false }
        if clauseScratch.count == 1 { return enqueueRoot(clauseScratch[0]) }
        attachClause(clauseScratch, learned: learned, lbd: lbd, activity: activity)
        return true
    }

    // MARK: - Propagation

    /// Runs both propagators to a fixed point. Returns the conflict, if there is one.
    mutating func propagate() -> Conflict? {
        while true {
            if let clause = propagateClauses() { return .clause(clause) }
            guard linQueueHead < linQueue.count else {
                linQueue.removeAll(keepingCapacity: true)
                linQueueHead = 0
                return nil
            }
            let c = Int(linQueue[linQueueHead])
            linQueueHead += 1
            linQueued[c] = false
            if !propagateLinear(c) { return .linear(Int32(c)) }
        }
    }

    /// Visits the clauses watching every literal the unprocessed bound changes falsified.
    mutating func propagateClauses() -> Int32? {
        while head < trail.count {
            let e = trail[head]
            head += 1
            propagations += 1
            let x = Int(e.variable)
            let count = atomValuesOf[x].count
            if count == 0 { continue }
            // A lower bound rising from `old` to `new` falsifies [x ≤ v − 1] for old < v ≤ new;
            // an upper bound falling from `old` to `new` falsifies [x ≥ v] for new < v ≤ old.
            let above = e.isLower ? e.old : e.new
            let upTo = e.isLower ? e.new : e.old
            var k = 0
            if count > 1 {
                var lo = 0
                var hi = count
                while lo < hi {
                    let mid = (lo + hi) >> 1
                    if atomValuesOf[x][mid] <= above { lo = mid + 1 } else { hi = mid }
                }
                k = lo
            } else if atomValuesOf[x][0] <= above {
                k = 1
            }
            while k < count, atomValuesOf[x][k] <= upTo {
                let atom = atomIDsOf[x][k]
                let falsified = e.isLower ? (atom << 1 | 1) : (atom << 1)
                if let conflict = visitWatchers(of: falsified) { return conflict }
                k += 1
            }
        }
        return nil
    }

    /// The two-watched-literal step for a literal that just became false.
    mutating func visitWatchers(of falsified: Int32) -> Int32? {
        let slot = Int(falsified)
        if watches[slot].isEmpty { return nil }
        // Take the clause arena and the watch lists out of `self` for the duration of the
        // visit. The loop below then works on plain buffers, and asserting a literal — which
        // touches neither — cannot alias them.
        var arena: [Int32] = []
        swap(&arena, &literals)
        var lists: [[Watcher]] = []
        swap(&lists, &watches)
        var conflict: Int32? = nil
        arena.withUnsafeMutableBufferPointer { lits in
            lists.withUnsafeMutableBufferPointer { all in
                var list: [Watcher] = []
                swap(&list, &all[slot])
                let count = list.count
                var kept = 0
                list.withUnsafeMutableBufferPointer { watchers in
                    var i = 0
                    var j = 0
                    while i < count {
                        let watcher = watchers[i]
                        i += 1
                        if literalValue[Int(watcher.blocker)] == 1 {
                            watchers[j] = watcher
                            j += 1
                            continue
                        }
                        let start = Int(watcher.clause)
                        // Keep the falsified literal in position 1.
                        if lits[start] == falsified {
                            lits[start] = lits[start + 1]
                            lits[start + 1] = falsified
                        }
                        let first = lits[start]
                        let firstValue = literalValue[Int(first)]
                        if firstValue == 1 {
                            watchers[j] = Watcher(clause: watcher.clause, blocker: first)
                            j += 1
                            continue
                        }
                        // Look for another literal that is not false.
                        var replaced = false
                        var k = start + 2
                        let end = start + Int(lits[start - 1])
                        while k < end {
                            let candidate = lits[k]
                            if literalValue[Int(candidate)] != -1 {
                                lits[start + 1] = candidate
                                lits[k] = falsified
                                all[Int(candidate)].append(Watcher(clause: watcher.clause, blocker: first))
                                replaced = true
                                break
                            }
                            k += 1
                        }
                        if replaced { continue }
                        // The clause is unit under `first`, or violated.
                        watchers[j] = Watcher(clause: watcher.clause, blocker: first)
                        j += 1
                        if firstValue == -1 {
                            conflict = watcher.clause
                            while i < count {
                                watchers[j] = watchers[i]
                                j += 1
                                i += 1
                            }
                            break
                        }
                        assign(first, ReasonKind.clause, watcher.clause)
                    }
                    kept = j
                }
                list.removeLast(count - kept)
                swap(&list, &all[slot])
            }
        }
        swap(&arena, &literals)
        swap(&lists, &watches)
        return conflict
    }

    /// Bounds consistency for constraint `c`. Returns false on a conflict.
    mutating func propagateLinear(_ c: Int) -> Bool {
        let slack = linRHS[c] - linMinAct[c]
        if slack < 0 { return false }
        if slack >= model.linMaxTerm[c] { return true }
        var t = Int(model.linStart[c])
        let end = Int(model.linStart[c + 1])
        while t < end {
            // Terms are sorted by decreasing |a|·(ub − lb): the rest are too small to tighten.
            if model.linTermMax[t] <= slack { break }
            let a = model.linCoef[t]
            let x = Int(model.linVar[t])
            t += 1
            let span = ub[x] - lb[x]
            if span == 0 { continue }
            if a > 0 {
                // a·(x − lb) ≤ slack
                if a * span > slack { setUpper(x, lb[x] + slack / a, ReasonKind.linear, Int32(c)) }
            } else {
                // |a|·(ub − x) ≤ slack
                let magnitude = -a
                if magnitude * span > slack { setLower(x, ub[x] - slack / magnitude, ReasonKind.linear, Int32(c)) }
            }
        }
        return true
    }

    // MARK: - Activities

    mutating func bump(_ x: Int) {
        activity[x] += activityIncrement
        if activity[x] > 1e100 {
            for i in activity.indices { activity[i] *= 1e-100 }
            activityIncrement *= 1e-100
        }
        heap.increased(x, activity)
    }

    /// EVSIDS: instead of decaying every activity by 0.95, grow the increment by 1 / 0.95.
    mutating func decayActivities() {
        activityIncrement *= 1 / 0.95
        clauseIncrement *= 1 / 0.999
        if clauseIncrement > 1e20 {
            for i in clauseActivity.indices { clauseActivity[i] *= 1e-20 }
            clauseIncrement *= 1e-20
        }
    }

    // MARK: - Memory

    /// A rough count of the bytes this worker's own state occupies (rule L7).
    var approximateBytes: Int {
        let n = model.variableCount
        let clauseCount = clauseStart.count
        let atomCount = atomVariable.count
        return n * 160
            + model.constraintCount * 17
            + trail.capacity * MemoryLayout<TrailEntry>.stride
            + literals.capacity * MemoryLayout<Int32>.size
            + clauseCount * (17 + 2 * MemoryLayout<Watcher>.stride * 2)
            + atomCount * (12 + 12 + 64)
            + recorded.count * 64
            + (relaxation.enabled ? relaxation.approximateBytes + (options.relaxation?.engineBytes ?? 0) : 0)
    }
}
