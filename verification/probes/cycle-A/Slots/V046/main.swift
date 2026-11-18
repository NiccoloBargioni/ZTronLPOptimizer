// V046, cycle A sceptic of A2-06: SparseQRBasis doc comment says "Chosen when m > 1,500 or the
// basis density is below 2%" (Sources/ZTronLPNumerics/BasisFactorization.swift:204-205).
//
// Independent oracles (the finder only type-checked makeFactorization(rows:)):
//  1. Behavioural fingerprint of the factorization a REAL solve used. DenseLUBasis refactors every
//     100 updates, SparseQRBasis every 50 (their doc comments; README 2.7 refactorInterval 100 / 50;
//     README 5 transport table: 1,000 pivots -> 11 vs 21 refactorizations). So
//     SimplexAnalysis.refactorizations (+ pivots, objective bits, primal bits) of .automatic is
//     matched against the forced .denseLU and .sparseQR runs on the same low-density LP.
//  2. Peak resident memory in a fresh process (mode `rss`): DenseLUBasis holds an m x m dense
//     matrix (8 m^2 bytes = 18 MB at m = 1,500, twice that while refactoring); sparse QR of a basis
//     with <= 2 nonzeros per column is O(m).
//  3. Basis density computed independently: every entry of the dense m x m basis probed through
//     SparseCSC's subscript (not colStart differences), compared with basisDensity(basic:lp:).
//
// Usage: V046                         fingerprint table (m = 200, 1000, 1500, 1501)
//        V046 rss <auto|dense|sparse> <sources> <sinks>
//        V046 sweep                   switch points of makeFactorization(rows:) over 0...5000
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func peakRSS() -> Int {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Int(u.ru_maxrss)   // bytes on Darwin
}

/// Density of the basis by probing all m*m entries of B = [A | -I] restricted to the basic columns.
func probedBasisDensity(_ basic: [Int32], _ lp: CompiledLP) -> Double {
    let m = lp.m, n = lp.n
    guard m > 0 else { return 0 }
    var nonzeros = 0
    for col in basic {
        let j = Int(col)
        if j < n {
            for i in 0..<m where lp.a[i, j] != 0 { nonzeros += 1 }
        } else {
            nonzeros += 1   // logical column of row j - n: a single -1
        }
    }
    return Double(nonzeros) / (Double(m) * Double(m))
}

func bitsHash(_ v: [Double]?) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for x in v ?? [] { h = (h ^ x.bitPattern) &* 0x100000001b3 }
    return h
}

func factorizationName(_ f: Simplex.Factorization) -> String {
    switch f {
    case .automatic: return "automatic"
    case .denseLU: return "denseLU"
    case .sparseQR: return "sparseQR"
    }
}

struct Fingerprint: Equatable {
    let status: String
    let iterations: Int
    let refactorizations: Int
    let objectiveBits: UInt64
    let primalBits: UInt64
}

func solve(_ lp: CompiledLP, _ f: Simplex.Factorization) async throws -> (SimplexAnalysis, Double) {
    var context = SolveContext()
    context.timeLimit = 150
    let strategy = Simplex(.dual, factorization: f, presolve: false)
    let start = Date()
    let analysis = try await strategy.solve(lp, context: context)
    return (analysis, Date().timeIntervalSince(start))
}

func fingerprint(_ a: SimplexAnalysis) -> Fingerprint {
    Fingerprint(status: "\(a.status)", iterations: a.iterations, refactorizations: a.refactorizations,
                objectiveBits: (a.objectiveValue ?? .nan).bitPattern, primalBits: bitsHash(a.primal))
}

/// What the doc comment predicts for `.automatic`, and what the code (Simplex.swift:84-88) does.
func docRule(m: Int, density: Double) -> String { (m > 1_500 || density < 0.02) ? "sparseQR" : "denseLU" }

let args = CommandLine.arguments
if args.count >= 2, args[1] == "sweep" {
    let s = Simplex()
    print("Simplex().factorization == .automatic: \(s.factorization == .automatic); denseBasisLimit \(Simplex.denseBasisLimit)")
    var last = ""
    for m in 0...5_000 {
        let f = s.makeFactorization(rows: m)
        let name = f is DenseLUBasis ? "DenseLUBasis" : (f is SparseQRBasis ? "SparseQRBasis" : "other")
        if name != last { print("from m = \(m): \(name)"); last = name }
    }
} else if args.count >= 5, args[1] == "rss" {
    let f: Simplex.Factorization = args[2] == "dense" ? .denseLU : (args[2] == "sparse" ? .sparseQR : .automatic)
    let lp = InstanceGenerator.transport(sources: Int(args[3])!, sinks: Int(args[4])!, seed: 46)
    let before = peakRSS()
    let (a, secs) = try await solve(lp, f)
    let after = peakRSS()
    let initialDensity = 1.0 / Double(lp.m)
    print(String(format: "rss %@ m=%d n=%d: status %@ pivots %d refactorizations %d obj %.6f %.2fs | peak RSS before %.1f MB after %.1f MB, growth %.1f MB (8m^2 = %.1f MB) | slack-basis density %.4f%%, final basis density %.4f%%",
                 factorizationName(f), lp.m, lp.n, "\(a.status)", a.iterations, a.refactorizations, a.objectiveValue ?? Double.nan, secs,
                 Double(before) / 1e6, Double(after) / 1e6, Double(after - before) / 1e6, 8 * Double(lp.m * lp.m) / 1e6,
                 100 * initialDensity, 100 * basisDensity(basic: a.basis.basic, lp: lp)))
} else {
    // m = sources + sinks; every column has 2 nonzeros, so every basis has density <= 2/m.
    let shapes: [(sources: Int, sinks: Int)] = [(20, 180), (20, 980), (20, 1_480), (20, 1_481)]
    for shape in shapes {
        let lp = InstanceGenerator.transport(sources: shape.sources, sinks: shape.sinks, seed: 46)
        var runs: [String: (Fingerprint, SimplexAnalysis, Double)] = [:]
        for f in [Simplex.Factorization.denseLU, .sparseQR, .automatic] {
            let (a, secs) = try await solve(lp, f)
            runs[factorizationName(f)] = (fingerprint(a), a, secs)
        }
        let auto = runs["automatic"]!
        let dense = runs["denseLU"]!
        let sparse = runs["sparseQR"]!
        let finalBasic = auto.1.basis.basic
        let packageDensity = basisDensity(basic: finalBasic, lp: lp)
        let probed = probedBasisDensity(finalBasic, lp)
        let slack = probedBasisDensity((0..<lp.m).map { Int32(lp.n + $0) }, lp)
        let matrixDensity = Double(lp.a.nnz) / (Double(lp.m) * Double(lp.n))
        let maxDensity = max(packageDensity, probed, slack)
        let observed = auto.0 == dense.0 && auto.0 != sparse.0 ? "denseLU"
            : (auto.0 == sparse.0 && auto.0 != dense.0 ? "sparseQR" : "ambiguous")
        print("m=\(lp.m) n=\(lp.n) nnz=\(lp.a.nnz): A density \(String(format: "%.4f%%", 100 * matrixDensity)); slack basis \(String(format: "%.4f%%", 100 * slack)); final basis probed \(String(format: "%.4f%%", 100 * probed)) package basisDensity \(String(format: "%.4f%%", 100 * packageDensity))")
        for name in ["denseLU", "sparseQR", "automatic"] {
            let r = runs[name]!
            print("   \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) status \(r.0.status) pivots \(r.0.iterations) refactorizations \(r.0.refactorizations) obj \(r.1.objectiveValue ?? .nan) primalBits \(String(r.0.primalBits, radix: 16)) \(String(format: "%.2fs", r.2))")
        }
        print("   => .automatic behaved as \(observed); doc comment predicts \(docRule(m: lp.m, density: maxDensity)); code rule (m <= 1500 -> denseLU) predicts \(lp.m <= Simplex.denseBasisLimit ? "denseLU" : "sparseQR"); makeFactorization(rows: \(lp.m)) is \(Simplex().makeFactorization(rows: lp.m) is DenseLUBasis ? "DenseLUBasis" : "SparseQRBasis")")
    }
}
