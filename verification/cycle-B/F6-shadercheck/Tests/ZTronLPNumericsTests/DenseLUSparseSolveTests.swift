import Testing
import ZTronLPCore
import ZTronLPNumerics
import ZTronLPTestSupport

/// `DenseLU.solve` takes a shortcut for right-hand sides with leading zeros (after the row
/// interchanges). Whatever path it takes, the answer must be the one `dgesv` gives.
@Suite struct DenseLUSparseSolveTests {
    static func matrix(_ n: Int, seed: UInt64) -> DenseMatrix {
        var rng = SeededGenerator(seed: seed)
        var a = DenseMatrix(rows: n, cols: n)
        for j in 0..<n {
            for i in 0..<n { a[i, j] = rng.uniform(in: -1...1) }
            a[j, j] += rng.chance(0.5) ? 3 : -3
        }
        return a
    }

    @Test(arguments: [1, 2, 7, 40, 150])
    func sparseAndDenseRightHandSidesAgreeWithDgesv(_ n: Int) throws {
        let a = Self.matrix(n, seed: UInt64(n))
        let lu = try DenseLU(a)
        var rng = SeededGenerator(seed: 99)
        var cases: [[Double]] = []
        // Unit vectors (BTRAN's right-hand side), every position for small n.
        for r in stride(from: 0, to: n, by: Swift.max(1, n / 12)) {
            var e = [Double](repeating: 0, count: n)
            e[r] = 1
            cases.append(e)
        }
        // A few sparse vectors, a dense one and the zero vector.
        for _ in 0..<6 {
            var v = [Double](repeating: 0, count: n)
            for _ in 0..<Swift.max(1, n / 10) { v[rng.integer(in: 0...(n - 1))] = rng.uniform(in: -2...2) }
            cases.append(v)
        }
        cases.append((0..<n).map { _ in rng.uniform(in: -1...1) })
        cases.append([Double](repeating: 0, count: n))

        for rhs in cases {
            for transpose in [false, true] {
                var x = rhs
                lu.solve(&x, transpose: transpose)
                let reference = try #require(denseSolve(transpose ? a.transposed() : a, rhs))
                for i in 0..<n {
                    #expect(abs(x[i] - reference[i]) <= 1e-10 * (1 + abs(reference[i])), "n \(n), transpose \(transpose), entry \(i)")
                }
            }
        }
    }
}
