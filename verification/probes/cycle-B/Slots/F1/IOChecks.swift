// MPS / LP semantics and round trips (oracle: hand-derived meaning of each section).
import Foundation
import ZTronLPOptimizer

func col(_ lp: CompiledLP, _ name: String) -> Int? { lp.names.columns.firstIndex(of: name) }
func row(_ lp: CompiledLP, _ name: String) -> Int? { lp.names.rows.firstIndex(of: name) }

func runMPSSemantics() async throws {
    var f = 0
    let text = """
    NAME          SEM
    ROWS
     N  COST
     E  e1
     E  e2
     L  l1
     G  g1
     E  e3
    COLUMNS
        x         COST      1.0        e1        1.0
        x         e2        1.0        l1        1.0
        y         COST      2.0        g1        1.0
        y         e3        1.0
        MARKER                 'MARKER'                 'INTORG'
        i         COST      1.0        e1        1.0
        j         COST      1.0
        k         COST      1.0
        MARKER                 'MARKER'                 'INTEND'
        u         COST      1.0
        w         COST      1.0
        v         COST      1.0
        f         COST      1.0
        m         COST      1.0
        p         COST      1.0
        q         COST      1.0
    RHS
        RHS       COST      5.0        e1        5.0
        RHS       e2        5.0        l1        5.0
        RHS       g1        5.0        e3        5.0
    RANGES
        RNG       e1        2.0        e2        -2.0
        RNG       l1        3.0        g1        -3.0
        RNG       e3        0.0
    BOUNDS
     UP BND       u         -4.0
     MI BND       w
     PL BND       v
     BV BND       f
     LI BND       m         2
     UI BND       p         7
     FR BND       q
     FX BND       y         1.5
     UP BND       j         9
    ENDATA
    """
    let lp = try MPSFormat.read(text)
    func rowB(_ n: String) -> (Double, Double) { let i = row(lp, n)!; return (lp.rl[i], lp.ru[i]) }
    func colB(_ n: String) -> (Double, Double) { let j = col(lp, n)!; return (lp.xl[j], lp.xu[j]) }
    func chk(_ c: Bool, _ s: String) { if !c { f += 1; print("MPS FAIL: \(s)") } }
    chk(rowB("e1") == (5, 7), "E row with R=+2 -> [5,7], got \(rowB("e1"))")
    chk(rowB("e2") == (3, 5), "E row with R=-2 -> [3,5], got \(rowB("e2"))")
    chk(rowB("l1") == (2, 5), "L row with R=3 -> [2,5], got \(rowB("l1"))")
    chk(rowB("g1") == (5, 8), "G row with R=-3 -> [5,8], got \(rowB("g1"))")
    chk(rowB("e3") == (5, 5), "E row with R=0 -> [5,5], got \(rowB("e3"))")
    chk(colB("u") == (-.infinity, -4), "UP -4 with no lower -> [-inf,-4], got \(colB("u"))")
    chk(colB("w") == (-.infinity, .infinity), "MI -> [-inf, inf), got \(colB("w"))")
    chk(colB("v") == (0, .infinity), "PL -> [0, inf), got \(colB("v"))")
    chk(colB("f") == (0, 1), "BV -> [0,1], got \(colB("f"))")
    chk(colB("m") == (2, .infinity), "LI 2 -> [2, inf), got \(colB("m"))")
    chk(colB("p") == (0, 7), "UI 7 -> [0, 7], got \(colB("p"))")
    chk(colB("q") == (-.infinity, .infinity), "FR, got \(colB("q"))")
    chk(colB("y") == (1.5, 1.5), "FX 1.5, got \(colB("y"))")
    chk(colB("i") == (0, 1), "marker integer without bounds -> binary [0,1], got \(colB("i"))")
    chk(colB("j") == (0, 9), "marker integer with UP 9 -> [0,9], got \(colB("j"))")
    chk(colB("k") == (0, 1), "marker integer k -> [0,1], got \(colB("k"))")
    let ints = Set(lp.integerColumns.map { lp.names.columns[Int($0)] })
    chk(ints == ["i", "j", "k", "f", "m", "p"], "integer set \(ints)")
    chk(lp.c0 == -5, "RHS on objective row 5 -> constant -5, got c0=\(lp.c0)")
    chk(lp.sense == .minimize, "sense")
    // OBJSENSE forms and the constant under maximize
    for header in ["OBJSENSE\n    MAX\n", "OBJSENSE MAX\n", "OBJSENSE\n    MAXIMIZE\n", "OBJSENSE MAXIMIZE\n"] {
        let t = "NAME T\n" + header + "ROWS\n N obj\n L c\nCOLUMNS\n x obj 1 c 1\nRHS\n rhs obj 5 c 3\nENDATA\n"
        let p = try MPSFormat.read(t)
        let r = try await Simplex(.dual).solve(p, context: ctx(5))
        // max x - 5 s.t. x <= 3 -> 3 - 5 = -2
        chk(p.sense == .maximize && r.status == .optimal && abs((r.objectiveValue ?? .nan) - (-2)) < 1e-9,
            "\(header.debugDescription): max x - 5, x<=3 -> -2, got sense=\(p.sense) \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan)")
    }
    // negative UP after an explicit LO 0 keeps lower 0 (then crossed -> error)
    let t2 = "NAME T\nROWS\n N obj\nCOLUMNS\n x obj 1\nBOUNDS\n LO B x 0\n UP B x -1\nENDATA\n"
    do { _ = try MPSFormat.read(t2); chk(false, "LO 0 then UP -1 should be crossed bounds") } catch SolverError.invalidModel { } catch { chk(false, "LO 0 then UP -1 threw \(error)") }
    // UP then LO: lower given later wins
    let t3 = "NAME T\nROWS\n N obj\nCOLUMNS\n x obj 1\nBOUNDS\n UP B x -1\n LO B x -3\nENDATA\n"
    let p3 = try MPSFormat.read(t3)
    chk(p3.xl[0] == -3 && p3.xu[0] == -1, "UP -1 then LO -3 -> [-3,-1], got \(p3.xl[0]) \(p3.xu[0])")
    // solve check of the semantic model: objective constant included
    print("MPS semantics checks failures=\(f)")
}

func runLPSemantics() async throws {
    var f = 0
    func chk(_ c: Bool, _ s: String) { if !c { f += 1; print("LP FAIL: \(s)") } }
    let text = """
    \\ comment
    Maximize
     obj: 3 x + 2 y - z + 4
    Subject To
     c1: x + y + z <= 10
     c2: 2 x - y >= -3
     c3: x - z = 1
     c4: -2 <= x + 2 y <= 8
     c5: 3 x + 2 >= y + 1
     - x + y <= 7
    Bounds
     x <= 6
     -1 <= y <= 5
     z free
     w >= -2
     3 <= u
     t = 2.5
    Generals
     g
    Binaries
     b
    End
    """
    let lp = try LPFormat.read(text)
    let j = { (n: String) in col(lp, n)! }
    chk(lp.sense == .maximize, "sense")
    chk(lp.c[j("x")] == -3 && lp.c[j("y")] == -2 && lp.c[j("z")] == 1 && lp.c0 == -4, "objective stored for min: c=\(lp.c) c0=\(lp.c0)")
    func rb(_ n: String) -> (Double, Double) { let i = row(lp, n)!; return (lp.rl[i], lp.ru[i]) }
    chk(rb("c1") == (-.infinity, 10), "c1 \(rb("c1"))")
    chk(rb("c2") == (-3, .infinity), "c2 \(rb("c2"))")
    chk(rb("c3") == (1, 1), "c3 \(rb("c3"))")
    chk(rb("c4") == (-2, 8), "c4 \(rb("c4"))")
    let i5 = row(lp, "c5")!
    chk(lp.rl[i5] == -1 && lp.ru[i5] == .infinity && lp.a[i5, j("x")] == 3 && lp.a[i5, j("y")] == -1, "c5: 3x - y >= -1, got [\(lp.rl[i5]),\(lp.ru[i5])] a=\(lp.a[i5, j("x")]),\(lp.a[i5, j("y")])")
    chk(lp.m == 6 && lp.names.rows[5] == "c6", "unlabelled 6th row named c6: \(lp.names.rows)")
    func cb(_ n: String) -> (Double, Double) { (lp.xl[j(n)], lp.xu[j(n)]) }
    chk(cb("x") == (0, 6), "x \(cb("x"))")
    chk(cb("y") == (-1, 5), "y \(cb("y"))")
    chk(cb("z") == (-.infinity, .infinity), "z \(cb("z"))")
    chk(cb("w") == (-2, .infinity), "w \(cb("w"))")
    chk(cb("u") == (3, .infinity), "u \(cb("u"))")
    chk(cb("t") == (2.5, 2.5), "t \(cb("t"))")
    chk(cb("b") == (0, 1), "b \(cb("b"))")
    let ints = Set(lp.integerColumns.map { lp.names.columns[Int($0)] })
    chk(ints == ["g", "b"], "integers \(ints)")
    // ranged row written as equality + Rg column
    let a = SparseCSC.fromTriplets(rows: 1, cols: 2, [(0, 0, 1.0), (0, 1, 2.0)])
    let rlp = CompiledLP(a: a, c: [1, 1], xl: [0, 0], xu: [10, 10], rl: [2], ru: [7], names: LPNames(columns: ["x", "y"], rows: ["r"]))
    let w = try LPFormat.write(rlp)
    let back = try LPFormat.read(w)
    let rg = col(back, "Rgr")
    chk(back.m == 1 && back.n == 3 && rg != nil && back.rl[0] == 0 && back.ru[0] == 0 && back.a[0, rg!] == -1 && back.xl[rg!] == 2 && back.xu[rg!] == 7,
        "range row -> equality with Rg column: \(w)")
    let s1 = try await Simplex(.dual).solve(rlp, context: ctx(5)), s2 = try await Simplex(.dual).solve(back, context: ctx(5))
    chk(abs((s1.objectiveValue ?? .nan) - (s2.objectiveValue ?? .nan)) < 1e-12, "range row optimum preserved \(s1.objectiveValue ?? .nan) vs \(s2.objectiveValue ?? .nan)")
    print("LP semantics checks failures=\(f)")
}

// Random CompiledLPs with names, integer columns, ranges, free rows; write then read.
func randomNamedLP(seed: UInt64, freeRows: Bool) -> CompiledLP {
    var g = RNG(seed &+ 31337)
    let n = g.int(0, 6), m = g.int(0, 5)
    var entries: [(row: Int, col: Int, value: Double)] = []
    func num() -> Double {
        switch g.int(0, 5) {
        case 0: return Double(g.int(-9, 9))
        case 1: return (g.unit() - 0.5) * 1e-7
        case 2: return (g.unit() - 0.5) * 1e12
        case 3: return Double(bitPattern: 0x3FF0_0000_0000_0000 | (g.next() & 0x000F_FFFF_FFFF_FFFF)) * (g.chance(0.5) ? -1 : 1)
        case 4: return 1.0 / 3.0 * Double(g.int(1, 7))
        default: return g.unit() * 100 - 50
        }
    }
    for i in 0..<m { for jj in 0..<n where g.chance(0.5) { let v = num(); if v != 0 { entries.append((i, jj, v)) } } }
    var xl = [Double](), xu = [Double](), c = [Double]()
    var ints: [Int32] = []
    for jj in 0..<n {
        let isInt = g.chance(0.3)
        if isInt { ints.append(Int32(jj)) }
        switch g.int(0, 6) {
        case 0: xl.append(0); xu.append(.infinity)
        case 1: xl.append(-.infinity); xu.append(.infinity)
        case 2: let v = isInt ? Double(g.int(-5, 5)) : num(); xl.append(v); xu.append(v)
        case 3: xl.append(-.infinity); xu.append(isInt ? Double(g.int(-5, 5)) : num())
        case 4: let a = isInt ? Double(g.int(-5, 0)) : -abs(num()); xl.append(a); xu.append(isInt ? Double(g.int(1, 5)) : abs(num()) + 1)
        case 5: xl.append(0); xu.append(1)
        default: xl.append(isInt ? Double(g.int(-5, 5)) : num()); xu.append(.infinity)
        }
        c.append(g.chance(0.3) ? 0 : num())
    }
    var rl = [Double](), ru = [Double]()
    for _ in 0..<m {
        let t = g.int(0, freeRows ? 4 : 3)
        let b = num()
        switch t {
        case 0: rl.append(-.infinity); ru.append(b)
        case 1: rl.append(b); ru.append(.infinity)
        case 2: rl.append(b); ru.append(b)
        case 3: rl.append(b); ru.append(b + abs(num()) + 0.1)
        default: rl.append(-.infinity); ru.append(.infinity)
        }
    }
    let maximize = g.chance(0.5)
    let names = LPNames(columns: (0..<n).map { "col\($0)_\(g.int(0, 99))" }, rows: (0..<m).map { "row\($0)" })
    return CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: c, c0: g.chance(0.5) ? num() : 0,
                      sense: maximize ? .maximize : .minimize, xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: ints, names: names)
}

/// LP-format comparison by column name (the reader numbers columns by first appearance).
func lpDiffByName(_ p: CompiledLP, _ q: CompiledLP) -> String? {
    if p.m != q.m { return "rows \(p.m) vs \(q.m)" }
    if p.sense != q.sense { return "sense" }
    if p.c0 != q.c0 { return "c0 \(p.c0) vs \(q.c0)" }
    if p.rl != q.rl || p.ru != q.ru { return "row bounds" }
    let qn = q.names.columns
    let pnames = p.names.columns.map { LPName.sanitized($0) }
    let pIsInt = p.integerMask(), qIsInt = q.integerMask()
    var seen = 0
    for j in 0..<p.n {
        guard let k = qn.firstIndex(of: p.names.columns[j]) else {
            // a column that appears nowhere in the file cannot be declared in LP format
            let empty = p.a.colStart[j] == p.a.colStart[j + 1] && p.c[j] == 0
            if empty && p.xl[j] == 0 && p.xu[j] == .infinity && !pIsInt[j] { continue }
            return "column \(p.names.columns[j]) (\(pnames[j])) lost: empty=\(empty) bounds [\(p.xl[j]),\(p.xu[j])] int=\(pIsInt[j])"
        }
        seen += 1
        if p.c[j] != q.c[k] { return "cost of \(p.names.columns[j]) \(p.c[j]) vs \(q.c[k])" }
        if p.xl[j] != q.xl[k] || p.xu[j] != q.xu[k] { return "bounds of \(p.names.columns[j]) [\(p.xl[j]),\(p.xu[j])] vs [\(q.xl[k]),\(q.xu[k])]" }
        if pIsInt[j] != qIsInt[k] { return "integrality of \(p.names.columns[j])" }
        for i in 0..<p.m where p.a[i, j] != q.a[i, k] { return "a[\(i),\(p.names.columns[j])] \(p.a[i, j]) vs \(q.a[i, k])" }
    }
    if seen != q.n { return "extra columns in read-back: \(q.n - seen)" }
    return nil
}

func runRoundTrip(from: Int, count: Int) async throws {
    var mpsFail = 0, lpFail = 0, fixedFail = 0
    var shown = 0
    for s in from..<(from + count) {
        let lp = randomNamedLP(seed: UInt64(s), freeRows: false)
        let text = MPSFormat.write(lp)
        do {
            let back = try MPSFormat.read(text)
            if let d = structuralDiff(lp, back) { mpsFail += 1; if shown < 30 { shown += 1; print("seed \(s) free MPS round trip differs: \(d)") } }
        } catch { mpsFail += 1; if shown < 6 { shown += 1; print("seed \(s) free MPS read-back threw \(error)\n\(text)") } }
        // LP: compare after mapping (no ranges -> exact, ranges -> Rg columns)
        let hasRange = (0..<lp.m).contains { lp.rl[$0] > -.infinity && lp.ru[$0] < .infinity && lp.rl[$0] != lp.ru[$0] }
        do {
            let ltext = try LPFormat.write(lp)
            let back = try LPFormat.read(ltext)
            if !hasRange {
                if let d = lpDiffByName(lp, back) { lpFail += 1; if shown < 40 { shown += 1; print("seed \(s) LP round trip differs: \(d)") } }
            } else {
                // equal optimum as an LP (relaxed) is the documented guarantee
                let r1 = try await Simplex(.dual).solve(lp.relaxed(), context: ctx(5))
                let r2 = try await Simplex(.dual).solve(back.relaxed(), context: ctx(5))
                if statusName(r1.status) != statusName(r2.status) || (r1.objectiveValue != nil && abs(r1.objectiveValue! - (r2.objectiveValue ?? .nan)) > 1e-7 * (1 + abs(r1.objectiveValue!))) {
                    lpFail += 1; if shown < 12 { shown += 1; print("seed \(s) LP range round trip changes the LP: \(statusName(r1.status)) \(r1.objectiveValue ?? .nan) vs \(statusName(r2.status)) \(r2.objectiveValue ?? .nan)") }
                }
            }
        } catch { lpFail += 1; if shown < 12 { shown += 1; print("seed \(s) LP round trip threw \(error)") } }
        // fixed format: only check it reads back with the same shape
        let ftext = MPSFormat.write(lp, free: false)
        do {
            let back = try MPSFormat.read(ftext, options: { var o = MPSFormat.ReadOptions(); o.fixedColumns = true; return o }())
            if back.m != lp.m || back.n != lp.n || back.integerColumns != lp.integerColumns || back.sense != lp.sense { fixedFail += 1; if shown < 16 { shown += 1; print("seed \(s) fixed MPS shape differs \(back.m)x\(back.n) vs \(lp.m)x\(lp.n)") } }
        } catch { fixedFail += 1; if shown < 16 { shown += 1; print("seed \(s) fixed MPS read-back threw \(error)") } }
    }
    print("roundtrip seeds \(from)..<\(from + count): freeMPS fail=\(mpsFail) LP fail=\(lpFail) fixedMPS shape fail=\(fixedFail)")
}

func runLPNames() async throws {
    // rows "a" and "a_" are both range rows and a column is called "Rga"
    let a = SparseCSC.fromTriplets(rows: 2, cols: 3, [(0, 0, 1.0), (1, 1, 1.0)])
    let lp = CompiledLP(a: a, c: [1, 1, 1], xl: [0, 0, 0], xu: [10, 10, 10], rl: [1, 3], ru: [2, 4],
                        names: LPNames(columns: ["x", "y", "Rga"], rows: ["a", "a_"]))
    let w = try LPFormat.write(lp)
    print(w)
    let back = try LPFormat.read(w)
    print("read back: n=\(back.n) columns=\(back.names.columns) rows=\(back.names.rows)")
    let r1 = try await Simplex(.dual).solve(lp, context: ctx(5)), r2 = try await Simplex(.dual).solve(back, context: ctx(5))
    print("optimum original \(statusName(r1.status)) \(r1.objectiveValue ?? .nan) vs read back \(statusName(r2.status)) \(r2.objectiveValue ?? .nan)")
}

func runScalingExtremes(only: Int? = nil) async {
    var fails = 0
    var g = RNG(77)
    for s in 0..<300 {
        let verbose = only == s
        let n = g.int(1, 4), m = g.int(1, 4)
        var e: [(row: Int, col: Int, value: Double)] = []
        let x0 = (0..<n).map { _ in Double(g.int(1, 5)) }
        var rl = [Double](), ru = [Double]()
        let colScale = (0..<n).map { _ in pow(10.0, Double(g.int(-120, 120))) }
        for i in 0..<m {
            let rs = pow(10.0, Double(g.int(-120, 120)))
            var act = 0.0
            for j in 0..<n where g.chance(0.8) {
                let v = Double(g.int(1, 9)) * rs * colScale[j] * (g.chance(0.5) ? 1 : -1)
                guard v.isFinite, v != 0, abs(v) > 1e-290, abs(v) < 1e290 else { continue }
                e.append((i, j, v)); act += v * x0[j] / colScale[j] * colScale[j]
            }
            rl.append(act - abs(act) * 0.1 - 1e-300); ru.append(act + abs(act) * 0.1 + 1e-300)
        }
        // variables in [0, 10] (in user units)
        let lp = CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, e), c: (0..<n).map { _ in Double(g.int(-3, 3)) },
                            xl: [Double](repeating: 0, count: n), xu: [Double](repeating: 10, count: n), rl: rl, ru: ru)
        var results: [(String, String, Double)] = []
        for (name, st) in [("none", Simplex(.dual, scaling: .none)), ("equil", Simplex(.dual, scaling: .equilibration)), ("geom", Simplex(.dual))] {
            if let r = try? await st.solve(lp, context: ctx(5)) {
                results.append((name, statusName(r.status), r.objectiveValue ?? .nan))
                if verbose {
                    let x = r.primal ?? []
                    let v = x.count == lp.n ? kkt(lp, x: x, y: r.dual, d: r.reducedCosts, tol: 1e-6, objective: r.status.hasSolution ? r.objectiveValue : nil) : ["no x"]
                    print("  \(name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(x) KKT/feas violations: \(v.prefix(4)) warnings=\(r.warnings.prefix(2))")
                }
                if r.status == .optimal, let x = r.primal {
                    let v = kkt(lp, x: x, y: nil, d: nil, tol: 1e-6)
                    if !v.isEmpty { fails += 1; if fails < 8 { print("seed \(s) \(name): optimal but \(v.prefix(2))") } }
                }
            }
        }
        if verbose { print(describeLP(lp)) }
        let st = Set(results.map { $0.1 })
        if st.count > 1 { fails += 1; if fails < 8 { print("seed \(s): status disagreement \(results)") } }
    }
    print("scaling extremes: failures=\(fails)")
}
