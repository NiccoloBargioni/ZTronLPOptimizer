// Cycle B sceptic for finding B5-05 (CP-SAT bound magnitude threshold vs README "2^53 or more").
// Build: swift build --product V133 -c release   Run: .build/release/V133
//
// Independent oracle: exact Int64 arithmetic plus the README contract.
//   README §2.5: CPSAT throws .unsupported for "bounds ... of magnitude 2^53 or more".
//   README §4:   supported class has "bounds and scaled coefficients below 2^53".
// So for a single integer column x with integral bounds L <= U, |L|,|U| < 2^53, no rows:
//   max x  -> expected .optimal with x == U exactly (Int64 compare), no throw
//   min x  -> expected .optimal with x == L exactly
// and for |bound| >= 2^53 -> expected throw .unsupported.
// Models are built three independent ways: CompiledLP by hand, the DSL, and MPS text.
import ZTronLPOptimizer
import ZTronLPTestSupport

let two53: Int64 = 1 << 53   // 9_007_199_254_740_992

enum Outcome: CustomStringConvertible {
    case threw(String)
    case result(String, Double?, Double?)
    var description: String {
        switch self {
        case .threw(let s): return "THROW \(s)"
        case .result(let st, let obj, let x):
            let xs = x.map { v -> String in
                if let i = Int64(exactly: v) { return "\(i)" } else { return "\(v)" }
            } ?? "nil"
            return "status=\(st) obj=\(obj.map { "\($0)" } ?? "nil") x=\(xs)"
        }
    }
    var xInt: Int64? {
        if case .result(_, _, let x) = self, let x { return Int64(exactly: x) }
        return nil
    }
    var threw: Bool { if case .threw = self { return true } else { return false } }
}

func describe(_ error: Error) -> String {
    if let e = error as? SolverError {
        switch e {
        case .unsupported(let s): return "unsupported: \(s)"
        case .invalidModel(let s): return "invalidModel: \(s)"
        case .internalInconsistency(let s): return "internalInconsistency: \(s)"
        @unknown default: return "\(e)"
        }
    }
    return "\(error)"
}

func ctx() -> SolveContext {
    var c = SolveContext()
    c.timeLimit = 5
    return c
}

/// One integer column, no rows. `c` is stored for minimization (README §2.2).
func handLP(lower: Int64, upper: Int64, maximize: Bool) -> CompiledLP {
    let a = SparseCSC.fromTriplets(rows: 0, cols: 1, [])
    return CompiledLP(
        a: a, c: [maximize ? -1 : 1], sense: maximize ? .maximize : .minimize,
        xl: [Double(lower)], xu: [Double(upper)], rl: [], ru: [], integerColumns: [0])
}

func runCPSAT(_ lp: CompiledLP, _ s: CPSAT) async -> Outcome {
    do {
        let r = try await s.solve(lp, context: ctx())
        return .result("\(r.status)", r.objectiveValue, r.primal?.first)
    } catch {
        return .threw(describe(error))
    }
}

func runBnB(_ lp: CompiledLP) async -> Outcome {
    do {
        let r = try await BranchAndBound().solve(lp, context: ctx())
        return .result("\(r.status)", r.objectiveValue, r.primal?.first)
    } catch {
        return .threw(describe(error))
    }
}

// Exactness of the inputs: every value used below is an exactly representable Double.
func exact(_ v: Int64) -> Bool { Int64(exactly: Double(v)) == v }

let args = CommandLine.arguments.dropFirst()
let mode = args.first ?? "all"

if mode == "all" || mode == "sweep" {
    print("== sweep: x integer in [0, U], max x, hand-built CompiledLP; oracle: README accept iff |U| < 2^53, then x == U")
    for k in [-2, 0, 1, 2, 3, 4, 5, 6, 8, 16, 1 << 20] {
        let U = two53 - Int64(k)
        let readmeAccept = U < two53
        let det = await runCPSAT(handLP(lower: 0, upper: U, maximize: true), CPSAT(deterministic: true))
        let def = await runCPSAT(handLP(lower: 0, upper: U, maximize: true), CPSAT())
        func verdict(_ o: Outcome) -> String {
            if readmeAccept {
                if o.threw { return "MISMATCH(README says accept, solver threw)" }
                if let x = o.xInt, x == U { return "ok(x==U)" }
                return "MISMATCH(accepted but x != U; x-U=\(o.xInt.map { "\($0 - U)" } ?? "?"))"
            } else {
                return o.threw ? "ok(throws as README says)" : "MISMATCH(README says throw)"
            }
        }
        print("S k=\(k) U=2^53-\(k)=\(U) exact=\(exact(U)) readmeAccept=\(readmeAccept)")
        print("   CPSAT(det)  \(det)  -> \(verdict(det))")
        print("   CPSAT()     \(def)  -> \(verdict(def))")
    }
}

if mode == "all" || mode == "lower" {
    print("== lower side: x integer in [L, 0], min x, L = -(2^53-k); oracle: accept iff |L| < 2^53, then x == L")
    for k in [1, 4, 5, 8] {
        let L = -(two53 - Int64(k))
        let o = await runCPSAT(handLP(lower: L, upper: 0, maximize: false), CPSAT(deterministic: true))
        let ok = o.threw ? "MISMATCH(README says accept, solver threw)" : (o.xInt == L ? "ok(x==L)" : "MISMATCH(x-L=\(o.xInt.map { "\($0 - L)" } ?? "?"))")
        print("L k=\(k) L=\(L) exact=\(exact(L)) \(o) -> \(ok)")
    }
    let sym = await runCPSAT(handLP(lower: -(two53 - 1), upper: two53 - 1, maximize: true), CPSAT(deterministic: true))
    print("SYM x in [-(2^53-1), 2^53-1], max x: \(sym)")
}

if mode == "all" || mode == "paths" {
    print("== other construction paths for x in [0, 2^53-1], max x")
    // DSL
    enum V: LPVariable {
        case x
        var domain: VariableDomain { .integer(.range(0...9_007_199_254_740_991)) }
    }
    let model = LPModel<V>().maximizing(1.0 * V.x)
    do {
        let compiled = try model.compile()
        print("DSL compiled: xl=\(compiled.lp.xl) xu=\(compiled.lp.xu.map { Int64(exactly: $0).map { "\($0)" } ?? "\($0)" }) c=\(compiled.lp.c) sense=\(compiled.lp.sense) ints=\(compiled.lp.integerColumns)")
    } catch { print("DSL compile THROW \(describe(error))") }
    do {
        let sol = try await CPSAT(deterministic: true).solve(model, context: ctx())
        print("DSL CPSAT(det): status=\(sol.status) x=\(sol.value(of: .x))")
    } catch { print("DSL CPSAT(det): THROW \(describe(error))") }

    // MPS text, free format, minimize -x
    let mps = """
    NAME B505
    ROWS
     N obj
    COLUMNS
     MARKER 'MARKER' 'INTORG'
     x1 obj -1
     MARKER 'MARKER' 'INTEND'
    RHS
    BOUNDS
     LO BND x1 0
     UP BND x1 9007199254740991
    ENDATA
    """
    do {
        let lp = try MPSFormat.read(mps)
        print("MPS read: xl=\(lp.xl) xu=\(lp.xu.map { Int64(exactly: $0).map { "\($0)" } ?? "\($0)" }) c=\(lp.c) ints=\(lp.integerColumns)")
        print("MPS CPSAT(det): \(await runCPSAT(lp, CPSAT(deterministic: true)))")
        print("MPS BranchAndBound(): \(await runBnB(lp))")
    } catch { print("MPS read THROW \(describe(error))") }

    // Cross-engine sanity: the same hand-built model through branch and bound.
    print("HAND BranchAndBound(): \(await runBnB(handLP(lower: 0, upper: two53 - 1, maximize: true)))")
    print("HAND BranchAndBound() U=2^53-4: \(await runBnB(handLP(lower: 0, upper: two53 - 4, maximize: true)))")

    // Double arithmetic that the guard sees (README-independent arithmetic, printed for the record):
    for k: Int64 in [1, 4, 5] {
        let u = Double(two53 - k)
        let shifted = u + 4 * u.ulp
        print("ARITH U=2^53-\(k): ulp=\(u.ulp) U+4ulp=\(Int64(exactly: shifted).map { "\($0)" } ?? "\(shifted)") (>= 2^53: \(shifted >= Double(two53)))")
    }
}

if mode == "all" || mode == "coef" {
    // Contrast: the README's 2^53 threshold is exact for coefficients (guard on |scaled| < 2^53 without a shift).
    // Objective coefficient 2^53-1 on a binary: expect accepted per README.
    let a = SparseCSC.fromTriplets(rows: 0, cols: 1, [])
    let c = Double(two53 - 1)
    let lp = CompiledLP(a: a, c: [-c], sense: .maximize, xl: [0], xu: [1], rl: [], ru: [], integerColumns: [0])
    print("COEF objective coef 2^53-1 on binary, max: \(await runCPSAT(lp, CPSAT(deterministic: true)))")
    let lp2 = CompiledLP(a: a, c: [-Double(two53)], sense: .maximize, xl: [0], xu: [1], rl: [], ru: [], integerColumns: [0])
    print("COEF objective coef 2^53 on binary, max: \(await runCPSAT(lp2, CPSAT(deterministic: true)))")
}
