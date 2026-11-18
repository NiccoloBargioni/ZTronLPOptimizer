// Conflict analysis (specification §10.2): 1-UIP over the trail, explanations expanded
// lazily, recursive learned-clause minimization.
//
// The conflict is a nogood: a set of bound literals that are all true and cannot all be true.
// Because [x ≥ 5] implies [x ≥ 3], the nogood holds at most one lower-bound literal and one
// upper-bound literal per variable — the strongest asked for so far. Each literal is tied to
// the earliest trail entry that made it true. Analysis walks the trail backwards and replaces
// the latest literal of the conflict level by its reason until a single literal of that level
// is left: the first unique implication point.
//
// Reasons are never stored. A clause reason is read from the clause; a linear reason is
// rebuilt from the bounds the other variables had when the constraint propagated, and then
// relaxed: bounds are loosened, and literals dropped, for as long as the constraint still
// implies what the nogood needs. A row derived by the LP propagator is explained the same way
// (`explainCut`, LPRelaxation.swift).

import ZTronLPCore

/// The outcome of analysing a conflict; the learned clause itself is in `learnedLiterals`.
struct AnalysisResult {
    /// The level to return to before asserting the first literal of the learned clause.
    var backjumpLevel: Int
    /// The number of distinct decision levels among the learned literals.
    var lbd: Int32
}

extension CPWorker {
    // MARK: - Bounds in the past

    /// The lower bound of `x` just before trail position `index`.
    @inline(__always)
    func lowerBound(of x: Int, before index: Int) -> Int64 {
        var e = Int(lbEntry[x])
        while e >= index { e = Int(trail[e].previous) }
        return e >= 0 ? trail[e].new : model.lower[x]
    }

    /// The upper bound of `x` just before trail position `index`.
    @inline(__always)
    func upperBound(of x: Int, before index: Int) -> Int64 {
        var e = Int(ubEntry[x])
        while e >= index { e = Int(trail[e].previous) }
        return e >= 0 ? trail[e].new : model.upper[x]
    }

    /// The earliest trail entry that made the true literal `literal` true, or −1 when the
    /// literal holds at level 0 and so needs no justification.
    @inline(__always)
    func entry(of literal: BoundLiteral) -> Int {
        let x = Int(literal.variable)
        if literal.isLower {
            if literal.value <= rootLower[x] { return -1 }
            var e = Int(lbEntry[x])
            while trail[e].old >= literal.value { e = Int(trail[e].previous) }
            return e
        }
        if literal.value >= rootUpper[x] { return -1 }
        var e = Int(ubEntry[x])
        while trail[e].old <= literal.value { e = Int(trail[e].previous) }
        return e
    }

    // MARK: - Explanations

    /// Appends the literals that implied trail entry `index` — more precisely, that imply the
    /// bound `need` on its variable, which is no stronger than the bound the entry set.
    mutating func explain(entry index: Int, need: Int64, into out: inout [BoundLiteral]) {
        let e = trail[index]
        switch e.reasonKind {
        case ReasonKind.clause:
            let start = Int(e.reason)
            clauseActivity[Int(literals[start - 2])] += clauseIncrement
            for k in start..<(start + Int(literals[start - 1])) {
                let literal = literals[k]
                // Exactly one literal of a reason clause is true: the one it propagated. The
                // others were false then and bounds only tighten, so they still are.
                if value(of: literal) == 1 { continue }
                out.append(boundLiteral(literal ^ 1))
            }
        case ReasonKind.linear:
            explainLinear(Int(e.reason), pivot: Int(e.variable), pivotIsLower: e.isLower, need: need, before: index, into: &out)
        case ReasonKind.cut:
            explainCut(Int(e.reason), pivot: Int(e.variable), pivotIsLower: e.isLower, need: need, before: index, into: &out)
        default:
            break
        }
    }

    /// Appends the literals that make a conflict a conflict.
    mutating func explain(conflict: Conflict, into out: inout [BoundLiteral]) {
        switch conflict {
        case .clause(let clause):
            let start = Int(clause)
            clauseActivity[Int(literals[start - 2])] += clauseIncrement
            for k in start..<(start + Int(literals[start - 1])) {
                out.append(boundLiteral(literals[k] ^ 1))
            }
        case .linear(let constraint):
            explainLinear(Int(constraint), pivot: -1, pivotIsLower: false, need: 0, before: trail.count, into: &out)
        case .cut(let row):
            explainCut(Int(row), pivot: -1, pivotIsLower: false, need: 0, before: trail.count, into: &out)
        }
    }

    /// The reason of a linear propagation or conflict, built from the bounds in force before
    /// trail position `index`.
    ///
    /// For `Σ aⱼxⱼ ≤ rhs`, let mⱼ be the smallest value of term j under those bounds. The
    /// constraint forces the pivot past `need` as soon as Σ_{j ≠ pivot} mⱼ reaches a threshold
    /// T; for a conflict (no pivot) T = rhs + 1. Whatever the actual sum has above T is
    /// surplus, and it is spent loosening the bounds the explanation quotes: a bound loosened
    /// all the way to its level-0 value needs no literal at all.
    mutating func explainLinear(
        _ c: Int, pivot: Int, pivotIsLower: Bool, need: Int64, before index: Int, into out: inout [BoundLiteral]
    ) {
        let start = Int(model.linStart[c])
        let end = Int(model.linStart[c + 1])
        boundScratch.removeAll(keepingCapacity: true)
        var sum: Int64 = 0
        var pivotCoefficient: Int64 = 0
        for t in start..<end {
            let x = Int(model.linVar[t])
            let a = model.linCoef[t]
            if x == pivot {
                pivotCoefficient = a
                boundScratch.append(0)
                continue
            }
            let bound = a > 0 ? lowerBound(of: x, before: index) : upperBound(of: x, before: index)
            boundScratch.append(bound)
            sum += a * bound
        }
        var threshold = linRHS[c] + 1
        if pivot >= 0 {
            // The value the pivot must be kept away from: need + 1 for an upper bound [x ≤ need]
            // (a > 0), need − 1 for a lower bound [x ≥ need] (a < 0).
            let excluded = pivotIsLower ? need - 1 : need + 1
            threshold -= pivotCoefficient * excluded
        }
        var surplus = sum - threshold
        assert(surplus >= 0, "a linear reason does not imply its consequence")
        if surplus < 0 { surplus = 0 }
        // Terms are stored largest first. Spending the surplus on the smallest terms first
        // drops the most literals, which leaves the shortest reason.
        for t in stride(from: end - 1, through: start, by: -1) {
            let x = Int(model.linVar[t])
            if x == pivot { continue }
            let a = model.linCoef[t]
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

    // MARK: - The nogood

    /// Adds a true literal to the nogood, merging it with a literal on the same variable and
    /// side. Literals that hold at level 0 are dropped: they are true in every solution.
    mutating func addToNogood(_ literal: BoundLiteral) {
        let e = entry(of: literal)
        if e < 0 { return }
        let x = Int(literal.variable)
        let level = trail[e].level
        if literal.isLower {
            if needLower[x] == .min {
                needLower[x] = literal.value
                needLowerEntry[x] = Int32(e)
                touched.append(Int32(x) << 1 | 1)
                if level == analysisLevel { pathCount += 1 }
                bump(x)
            } else if literal.value > needLower[x] {
                let previous = trail[Int(needLowerEntry[x])].level
                needLower[x] = literal.value
                needLowerEntry[x] = Int32(e)
                if previous != analysisLevel && level == analysisLevel { pathCount += 1 }
            }
        } else {
            if needUpper[x] == .max {
                needUpper[x] = literal.value
                needUpperEntry[x] = Int32(e)
                touched.append(Int32(x) << 1)
                if level == analysisLevel { pathCount += 1 }
                bump(x)
            } else if literal.value < needUpper[x] {
                let previous = trail[Int(needUpperEntry[x])].level
                needUpper[x] = literal.value
                needUpperEntry[x] = Int32(e)
                if previous != analysisLevel && level == analysisLevel { pathCount += 1 }
            }
        }
    }

    /// Empties the nogood.
    mutating func resetNogood() {
        for t in touched {
            let x = Int(t >> 1)
            if t & 1 == 1 { needLower[x] = .min } else { needUpper[x] = .max }
        }
        touched.removeAll(keepingCapacity: true)
        pathCount = 0
    }

    // MARK: - 1-UIP

    /// Analyses a conflict. On return `learnedLiterals` holds the learned clause with the
    /// asserting literal first and a literal of the backjump level second, and the trail has
    /// been cut back to the level the conflict actually depends on.
    ///
    /// Returns `nil` when the conflict depends on no decision: level 0 is contradictory.
    mutating func analyze(_ conflict: Conflict) -> AnalysisResult? {
        // The scratch buffer is taken out of `self` while explanations are written into it.
        var buffer: [BoundLiteral] = []
        swap(&buffer, &reasonBuffer)
        defer { swap(&buffer, &reasonBuffer) }
        buffer.removeAll(keepingCapacity: true)
        explain(conflict: conflict, into: &buffer)

        // The level the conflict lives on is the highest level among its literals. It is the
        // current level whenever propagation was complete at every earlier level.
        var top: Int32 = 0
        for literal in buffer {
            let e = entry(of: literal)
            if e >= 0, trail[e].level > top { top = trail[e].level }
        }
        if top == 0 { return nil }
        if Int(top) < currentLevel { cancelUntil(Int(top)) }
        analysisLevel = top
        pathCount = 0
        touched.removeAll(keepingCapacity: true)
        for literal in buffer { addToNogood(literal) }

        // Resolve backwards until one literal of the conflict level remains.
        var index = trail.count - 1
        var uip = BoundLiteral(variable: -1, isLower: false, value: 0)
        while index >= 0 {
            let e = trail[index]
            let x = Int(e.variable)
            let present = e.isLower
                ? (needLower[x] != .min && needLowerEntry[x] == Int32(index))
                : (needUpper[x] != .max && needUpperEntry[x] == Int32(index))
            if !present {
                index -= 1
                continue
            }
            let need = e.isLower ? needLower[x] : needUpper[x]
            if pathCount <= 1 {
                uip = BoundLiteral(variable: e.variable, isLower: e.isLower, value: need)
                break
            }
            if e.isLower { needLower[x] = .min } else { needUpper[x] = .max }
            pathCount -= 1
            buffer.removeAll(keepingCapacity: true)
            explain(entry: index, need: need, into: &buffer)
            for literal in buffer { addToNogood(literal) }
            index -= 1
        }
        if uip.variable < 0 {
            // Cannot happen: a literal of the conflict level is always found. Fall back to the
            // clause that forbids this combination of decisions, which is valid regardless.
            assertionFailure("conflict analysis ran off the trail")
            resetNogood()
            return decisionClause()
        }

        minimizeNogood(keeping: uip)

        // The learned clause is the negation of the nogood.
        learnedLiterals.removeAll(keepingCapacity: true)
        learnedLiterals.append(clauseLiteral(negating: uip))
        var backjump: Int32 = 0
        var second = -1
        stampCounter &+= 1
        if levelStamp.count <= currentLevel { levelStamp.append(contentsOf: repeatElement(0, count: currentLevel + 1 - levelStamp.count)) }
        var lbd: Int32 = 1
        levelStamp[Int(analysisLevel)] = stampCounter
        for t in touched {
            let x = Int(t >> 1)
            let isLower = t & 1 == 1
            let value = isLower ? needLower[x] : needUpper[x]
            if isLower ? value == .min : value == .max { continue }
            // Consume the entry so a variable touched twice is emitted once.
            let e = Int(isLower ? needLowerEntry[x] : needUpperEntry[x])
            if isLower { needLower[x] = .min } else { needUpper[x] = .max }
            if Int32(x) == uip.variable && isLower == uip.isLower { continue }
            let level = trail[e].level
            if levelStamp[Int(level)] != stampCounter {
                levelStamp[Int(level)] = stampCounter
                lbd += 1
            }
            if level > backjump {
                backjump = level
                second = learnedLiterals.count
            }
            learnedLiterals.append(clauseLiteral(negating: BoundLiteral(variable: Int32(x), isLower: isLower, value: value)))
        }
        touched.removeAll(keepingCapacity: true)
        pathCount = 0
        if second > 1 { learnedLiterals.swapAt(1, second) }
        return AnalysisResult(backjumpLevel: Int(backjump), lbd: lbd)
    }

    /// The interned literal that is the negation of a true bound literal.
    mutating func clauseLiteral(negating literal: BoundLiteral) -> Int32 {
        let x = Int(literal.variable)
        return literal.isLower
            ? intern(x, literal.value) << 1 | 1          // ¬[x ≥ v] = [x ≤ v − 1]
            : intern(x, literal.value + 1) << 1          // ¬[x ≤ v] = [x ≥ v + 1]
    }

    /// The clause that forbids the current decisions; a safety net for `analyze`.
    mutating func decisionClause() -> AnalysisResult? {
        learnedLiterals.removeAll(keepingCapacity: true)
        for level in stride(from: currentLevel, to: 0, by: -1) {
            let e = trail[Int(levelStart[level - 1])]
            let decided = BoundLiteral(variable: e.variable, isLower: e.isLower, value: e.new)
            learnedLiterals.append(clauseLiteral(negating: decided))
        }
        if learnedLiterals.isEmpty { return nil }
        return AnalysisResult(backjumpLevel: Swift.max(0, currentLevel - 1), lbd: Int32(learnedLiterals.count))
    }

    // MARK: - Minimization

    /// Removes from the nogood every literal that the remaining ones already imply through
    /// the reasons on the trail (recursive minimization).
    mutating func minimizeNogood(keeping uip: BoundLiteral) {
        if minimizeMark.count < trail.count {
            minimizeMark.append(contentsOf: repeatElement(0, count: trail.count - minimizeMark.count))
        }
        minimizeBudget = 4_000
        for t in touched {
            let x = Int(t >> 1)
            let isLower = t & 1 == 1
            let value = isLower ? needLower[x] : needUpper[x]
            if isLower ? value == .min : value == .max { continue }
            if Int32(x) == uip.variable && isLower == uip.isLower { continue }
            let e = Int(isLower ? needLowerEntry[x] : needUpperEntry[x])
            if trail[e].reasonKind == ReasonKind.none { continue }
            // A literal another removal relies on has to stay.
            if isLower ? pinnedLower[x] : pinnedUpper[x] { continue }
            // Take the literal out while it is examined, so that it cannot justify itself.
            if isLower { needLower[x] = .min } else { needUpper[x] = .max }
            if !entryIsRedundant(e, depth: 0) {
                if isLower { needLower[x] = value } else { needUpper[x] = value }
            }
        }
        for t in touched {
            let x = Int(t >> 1)
            if t & 1 == 1 { pinnedLower[x] = false } else { pinnedUpper[x] = false }
        }
        for e in minimizeMarked { minimizeMark[Int(e)] = 0 }
        minimizeMarked.removeAll(keepingCapacity: true)
    }

    /// Whether the bound set by trail entry `e` follows from the nogood.
    mutating func entryIsRedundant(_ e: Int, depth: Int) -> Bool {
        switch minimizeMark[e] {
        case 1: return true
        case 2: return false
        default: break
        }
        let entry = trail[e]
        var redundant = entry.reasonKind != ReasonKind.none && depth < Self.minimizeDepth && minimizeBudget > 0
        if redundant {
            minimizeBuffers[depth].removeAll(keepingCapacity: true)
            // At full strength, so the verdict is a property of the entry alone and can be cached.
            var buffer: [BoundLiteral] = []
            swap(&buffer, &minimizeBuffers[depth])
            explain(entry: e, need: entry.new, into: &buffer)
            minimizeBudget -= buffer.count + 1
            for literal in buffer where !literalIsRedundant(literal, depth: depth + 1) {
                redundant = false
                break
            }
            swap(&buffer, &minimizeBuffers[depth])
        }
        minimizeMark[e] = redundant ? 1 : 2
        minimizeMarked.append(Int32(e))
        return redundant
    }

    /// Whether a true literal follows from the nogood: it holds at level 0, a literal of the
    /// nogood is at least as strong, or the entry that made it true is itself redundant.
    ///
    /// A nogood literal that is stronger than `literal` became true at the same trail entry or
    /// at a later one. In the second case the justification points forward on the trail, so
    /// the literal that provides it is pinned: it stays in the learned clause. Without the pin
    /// two literals could each be removed on the strength of the other.
    mutating func literalIsRedundant(_ literal: BoundLiteral, depth: Int) -> Bool {
        let e = entry(of: literal)
        if e < 0 { return true }
        let x = Int(literal.variable)
        if literal.isLower {
            if needLower[x] != .min && needLower[x] >= literal.value {
                if Int(needLowerEntry[x]) != e { pinnedLower[x] = true }
                return true
            }
        } else {
            if needUpper[x] != .max && needUpper[x] <= literal.value {
                if Int(needUpperEntry[x]) != e { pinnedUpper[x] = true }
                return true
            }
        }
        return entryIsRedundant(e, depth: depth)
    }
}
