// Specification §6.1 and §6.2: every dense vector kernel against a scalar loop, and the
// hyper-sparse result container.

import Testing
import ZTronLPNumerics
import ZTronLPTestSupport

/// The lengths every kernel is exercised at: empty, one element, below and above the widths
/// vectorized code handles specially, and a long vector.
private let lengths = [0, 1, 2, 3, 7, 8, 9, 31, 64, 257, 1_000]

/// Relative closeness for kernels whose summation order or fused multiply-add may differ from
/// the scalar loop.
private func close(_ a: Double, _ b: Double, _ scale: Double = 1) -> Bool {
    abs(a - b) <= 1e-12 * max(1, scale, abs(a), abs(b))
}

@Suite("Vector kernels")
struct KernelTests {
    @Test(arguments: lengths)
    func blasLevelOne(_ n: Int) {
        var rng = SeededGenerator(seed: UInt64(n) &+ 1)
        let x = randomVector(n, &rng, in: -3...3)
        let y = randomVector(n, &rng, in: -3...3)

        var dot = 0.0
        var sumOfSquares = 0.0
        var largest = 0.0
        for i in 0..<n {
            dot += x[i] * y[i]
            sumOfSquares += x[i] * x[i]
            largest = max(largest, abs(x[i]))
        }
        #expect(close(Vec.dot(x, y), dot, Double(n)))
        #expect(close(Vec.norm2(x), sumOfSquares.squareRoot()))
        #expect(Vec.maxAbs(x) == largest)

        var axpy = y
        Vec.axpy(-1.75, x, into: &axpy)
        for i in 0..<n { #expect(close(axpy[i], y[i] - 1.75 * x[i])) }
        var untouched = y
        Vec.axpy(0, x, into: &untouched)
        #expect(untouched == y)

        var scaled = x
        Vec.scale(2.5, &scaled)
        #expect(scaled == x.map { $0 * 2.5 })
    }

    @Test(arguments: lengths)
    func elementwise(_ n: Int) {
        var rng = SeededGenerator(seed: UInt64(n) &+ 100)
        let a = randomVector(n, &rng, in: -3...3)
        let b = randomVector(n, &rng, in: 0.5...4)          // nonzero, for the division
        var out = [Double](repeating: .nan, count: n)

        Vec.add(a, b, into: &out)
        #expect(out == zip(a, b).map { $0 + $1 })
        // vDSP's subtraction and division take their operands in the opposite order; the
        // wrappers present them the natural way round.
        Vec.subtract(a, b, into: &out)
        #expect(out == zip(a, b).map { $0 - $1 })
        Vec.multiply(a, b, into: &out)
        #expect(out == zip(a, b).map { $0 * $1 })
        // vDSP's vector division is accurate to an ulp or so, not correctly rounded.
        Vec.divide(a, b, into: &out)
        for i in 0..<n { #expect(abs(out[i] - a[i] / b[i]) <= 4 * (a[i] / b[i]).ulp) }
        Vec.abs(a, into: &out)
        #expect(out == a.map { abs($0) })
        Vec.clip(a, low: -1, high: 0.5, into: &out)
        #expect(out == a.map { min(max($0, -1), 0.5) })

        Vec.scaledAdd(1.5, a, plus: b, into: &out)
        for i in 0..<n { #expect(close(out[i], 1.5 * a[i] + b[i])) }
        var x = b
        Vec.addScaled(-0.5, a, to: &x)
        for i in 0..<n { #expect(close(x[i], b[i] - 0.5 * a[i])) }
        var same = b
        Vec.addScaled(0, a, to: &same)
        #expect(same == b)

        // An output that is also an input.
        var inPlace = a
        Vec.add(inPlace, b, into: &inPlace)
        #expect(inPlace == zip(a, b).map { $0 + $1 })
    }

    @Test(arguments: lengths)
    func reductionsAndConversions(_ n: Int) {
        var rng = SeededGenerator(seed: UInt64(n) &+ 200)
        let x = randomVector(n, &rng, in: -10...10)
        #expect(Vec.minimum(x) == (x.min() ?? .infinity))
        #expect(close(Vec.sum(x), x.reduce(0, +), Double(n) * 10))

        let single = Vec.toSingle(x)
        #expect(single == x.map { Float($0) })
        let back = Vec.toDouble(single)
        #expect(back == single.map { Double($0) })
        for i in 0..<n { #expect(abs(back[i] - x[i]) <= 1e-6 * max(1, abs(x[i]))) }
    }

    @Test func emptyVectors() {
        #expect(Vec.dot([], []) == 0)
        #expect(Vec.norm2([]) == 0)
        #expect(Vec.maxAbs([]) == 0)
        #expect(Vec.sum([]) == 0)
        #expect(Vec.minimum([]) == .infinity)
        #expect(Vec.toSingle([]).isEmpty && Vec.toDouble([]).isEmpty)
        var empty: [Double] = []
        Vec.scale(3, &empty)
        Vec.axpy(1, [], into: &empty)
        Vec.add([], [], into: &empty)
        #expect(empty.isEmpty)
    }

    @Test func specialValues() {
        #expect(Vec.maxAbs([-7, 3, 5]) == 7)
        #expect(Vec.minimum([4, -2, 9]) == -2)
        #expect(Vec.dot([1, 2, 3], [4, 5, 6]) == 32)
        #expect(Vec.norm2([3, 4]) == 5)
        // norm2 does not overflow where the naive sum of squares would.
        #expect(abs(Vec.norm2([3e200, 4e200]) - 5e200) <= 1e188)
        var out = [0.0, 0, 0]
        Vec.divide([1, -1, 0], [0, 0, 1], into: &out)
        #expect(out[0] == .infinity && out[1] == -.infinity && out[2] == 0)
        Vec.clip([-.infinity, .infinity, 2], low: -1, high: 1, into: &out)
        #expect(out == [-1, 1, 1])
    }

    // MARK: IndexedVector

    @Test func anIndexedVectorKeepsItsIndexListBelowTenPercent() {
        var v = IndexedVector(count: 100)
        #expect(v.count == 100 && v.isSparse && v.indices.isEmpty)
        #expect(IndexedVector.sparseDensity == 0.10)

        // Five nonzeros of 100: sparse, with the positions listed in ascending order.
        for i in [90, 3, 42, 17, 64] { v.values[i] = Double(i) + 0.5 }
        v.reindex()
        #expect(v.isSparse)
        #expect(v.indices == [3, 17, 42, 64, 90])
        var visited: [Double] = []
        for i in v.indices { visited.append(v.values[Int(i)]) }
        #expect(visited == [3.5, 17.5, 42.5, 64.5, 90.5])

        // Twenty nonzeros of 100: dense, no index list.
        for i in 0..<20 { v.values[i] = 1 }
        v.reindex()
        #expect(!v.isSparse && v.indices.isEmpty)

        // Clearing restores the all-zero sparse state in both modes.
        v.clear()
        #expect(v.isSparse && v.indices.isEmpty && v.values.allSatisfy { $0 == 0 })
        v.values[7] = 2
        v.values[8] = -2
        v.reindex()
        #expect(v.indices == [7, 8])
        v.clear()
        #expect(v.values.allSatisfy { $0 == 0 } && v.indices.isEmpty && v.isSparse)
    }

    @Test func reindexDropsEntriesBelowTheTolerance() {
        var v = IndexedVector(count: 50)
        v.values[1] = 1e-15
        v.values[2] = -1e-15
        v.values[3] = 0.25
        v.values[4] = -1e-12
        v.reindex(dropTolerance: 1e-14)
        #expect(v.values[1] == 0 && v.values[2] == 0)
        #expect(v.indices == [3, 4])
        #expect(v.values[3] == 0.25 && v.values[4] == -1e-12)
        // Without a tolerance nothing is dropped.
        var w = IndexedVector(count: 50)
        w.values[1] = 1e-300
        w.reindex()
        #expect(w.indices == [1] && w.values[1] == 1e-300)
    }

    @Test func aTinyVectorIsDenseAsSoonAsItHasAnEntry() {
        // Ten percent of five entries is less than one entry.
        var v = IndexedVector(count: 5)
        v.reindex()
        #expect(v.isSparse)
        v.values[2] = 1
        v.reindex()
        #expect(!v.isSparse && v.indices.isEmpty)
        v.clear()
        #expect(v.values == [0, 0, 0, 0, 0] && v.isSparse)
    }
}
