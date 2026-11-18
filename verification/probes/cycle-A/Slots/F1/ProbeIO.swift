// MPS / LP reader semantics, round trips, fuzzing.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

func colIndex(_ lp: CompiledLP, _ name: String) -> Int? { lp.names.columns.firstIndex(of: name) }
func rowIndexNamed(_ lp: CompiledLP, _ name: String) -> Int? { lp.names.rows.firstIndex(of: name) }

func readMPS(_ text: String) -> Result<CompiledLP, Error> {
    do { return .success(try MPSFormat.read(text)) } catch { return .failure(error) }
}
func readLP(_ text: String) -> Result<CompiledLP, Error> {
    do { return .success(try LPFormat.read(text)) } catch { return .failure(error) }
}

/// Validity of a CompiledLP that a reader returned (what compile() would refuse).
func invalidities(_ lp: CompiledLP) -> [String] {
    var out: [String] = []
    for j in 0..<lp.n {
        if lp.c[j].isNaN || lp.c[j].isInfinite { out.append("c[\(j)]=\(lp.c[j])") }
        if lp.xl[j].isNaN || lp.xu[j].isNaN { out.append("NaN bound col \(j)") }
        if lp.xl[j] == .infinity || lp.xu[j] == -.infinity { out.append("col \(j) bounds [\(lp.xl[j]),\(lp.xu[j])]") }
        if lp.xl[j] > lp.xu[j] { out.append("col \(j) xl>xu") }
    }
    for i in 0..<lp.m {
        if lp.rl[i].isNaN || lp.ru[i].isNaN { out.append("NaN bound row \(i) [\(lp.rl[i]),\(lp.ru[i])]") }
        if lp.rl[i] == .infinity || lp.ru[i] == -.infinity { out.append("row \(i) bounds [\(lp.rl[i]),\(lp.ru[i])]") }
        if lp.rl[i] > lp.ru[i] { out.append("row \(i) rl>ru [\(lp.rl[i]),\(lp.ru[i])]") }
    }
    if lp.c0.isNaN || lp.c0.isInfinite { out.append("c0=\(lp.c0)") }
    if lp.a.values.contains(where: { !$0.isFinite }) { out.append("non-finite coefficient") }
    return out
}

func mpsDoc(_ objsense: String = "", rows: String, columns: String, rhs: String = "", ranges: String = "", bounds: String = "") -> String {
    var s = "NAME TEST\n"
    if !objsense.isEmpty { s += objsense + "\n" }
    s += "ROWS\n" + rows + "COLUMNS\n" + columns
    if !rhs.isEmpty { s += "RHS\n" + rhs }
    if !ranges.isEmpty { s += "RANGES\n" + ranges }
    if !bounds.isEmpty { s += "BOUNDS\n" + bounds }
    return s + "ENDATA\n"
}

var ioFails = 0
func ioCheck(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "HELD" : "FAIL") | \(label) \(ok ? "" : "| " + detail())")
    if !ok { ioFails += 1 }
}

func probeMPS() async {
    // RANGES semantics
    let rows = " N COST\n E e1\n E e2\n L l1\n G g1\n E e0\n"
    let cols = "    x COST 1 e1 1\n    x e2 1 l1 1\n    x g1 1 e0 1\n"
    let rhs = "    RHS e1 5 e2 5\n    RHS l1 5 g1 5\n    RHS e0 5\n"
    let ranges = "    RNG e1 2 e2 -2\n    RNG l1 -2 g1 -2\n    RNG e0 0\n"
    switch readMPS(mpsDoc(rows: rows, columns: cols, rhs: rhs, ranges: ranges)) {
    case .success(let lp):
        let b = (0..<lp.m).map { "[\(lp.rl[$0]),\(lp.ru[$0])]" }
        ioCheck(lp.rl == [5, 3, 3, 5, 5] && lp.ru == [7, 5, 5, 7, 5], "MPS RANGES: E+R->[b,b+R], E-R->[b-|R|,b], L->[b-|R|,b], G->[b,b+|R|], E R=0->[b,b]", "\(b)")
    case .failure(let e): ioCheck(false, "MPS RANGES parse", "\(e)")
    }
    // Bound types
    let bcols = "    a COST 1 r 1\n    b COST 1 r 1\n    c COST 1 r 1\n    d COST 1 r 1\n    e COST 1 r 1\n    f COST 1 r 1\n    g COST 1 r 1\n    h COST 1 r 1\n    k COST 1 r 1\n    p COST 1 r 1\n    q COST 1 r 1\n"
    let bnds = " MI BND a\n PL BND b\n BV BND c\n LI BND d 2\n UI BND e 7\n FR BND f\n FX BND g 3.5\n UP BND h -4\n LO BND k -2\n UP BND k -1\n UP BND p 0\n UP BND q 1e30\n"
    switch readMPS(mpsDoc(rows: " N COST\n G r\n", columns: bcols, rhs: "    RHS r 1\n", bounds: bnds)) {
    case .success(let lp):
        func bounds(_ n: String) -> (Double, Double, Bool) { let j = colIndex(lp, n)!; return (lp.xl[j], lp.xu[j], lp.integerColumns.contains(Int32(j))) }
        ioCheck(bounds("a") == (-inf, inf, false), "MPS MI: lower -inf, upper stays +inf", "\(bounds("a"))")
        ioCheck(bounds("b") == (0, inf, false), "MPS PL", "\(bounds("b"))")
        ioCheck(bounds("c") == (0, 1, true), "MPS BV", "\(bounds("c"))")
        ioCheck(bounds("d") == (2, inf, true), "MPS LI", "\(bounds("d"))")
        ioCheck(bounds("e") == (0, 7, true), "MPS UI", "\(bounds("e"))")
        ioCheck(bounds("f") == (-inf, inf, false), "MPS FR", "\(bounds("f"))")
        ioCheck(bounds("g") == (3.5, 3.5, false), "MPS FX", "\(bounds("g"))")
        ioCheck(bounds("h") == (-inf, -4, false), "MPS negative UP with no lower -> lower -inf", "\(bounds("h"))")
        ioCheck(bounds("k") == (-2, -1, false), "MPS LO then negative UP keeps LO", "\(bounds("k"))")
        ioCheck(bounds("p") == (0, 0, false), "MPS UP 0 keeps lower 0", "\(bounds("p"))")
        ioCheck(bounds("q") == (0, inf, false), "MPS UP 1e30 is +inf", "\(bounds("q"))")
    case .failure(let e): ioCheck(false, "MPS bounds parse", "\(e)")
    }
    // UI negative with no lower (comment says 'an upper bound below zero ... makes the lower bound -inf')
    switch readMPS(mpsDoc(rows: " N COST\n G r\n", columns: "    x COST 1 r 1\n", rhs: "    RHS r -10\n", bounds: " UI BND x -3\n")) {
    case .success(let lp): print("INFO | MPS UI -3 with no lower: [\(lp.xl[0]),\(lp.xu[0])] integer=\(lp.integerColumns)")
    case .failure(let e): print("INFO | MPS UI -3 with no lower: throws \(e)")
    }
    // RHS on the objective row and OBJSENSE
    for (header, sense) in [("", ObjectiveSense.minimize), ("OBJSENSE MAX", .maximize), ("OBJSENSE\n    MAX", .maximize), ("OBJSENSE\n    MAXIMIZE", .maximize), ("OBJSENSE MAXIMIZE", .maximize), ("OBJSENSE\n    MIN", .minimize)] {
        let doc = mpsDoc(header, rows: " N COST\n L r\n", columns: "    x COST 2 r 1\n", rhs: "    RHS r 4 COST 5\n")
        switch readMPS(doc) {
        case .success(let lp):
            let atZero = lp.objective(at: [0]), atOne = lp.objective(at: [1])
            ioCheck(lp.sense == sense && atZero == -5 && atOne == -3, "MPS objective RHS 5 means constant -5 (\(header.replacingOccurrences(of: "\n", with: "/")))", "sense \(lp.sense) obj(0)=\(atZero) obj(1)=\(atOne)")
            if let r = try? await Simplex().solve(lp, context: ctx()) {
                let expected: Double = sense == .maximize ? 2 * 4 - 5 : -5
                ioCheck(r.status == .optimal && abs((r.objectiveValue ?? .nan) - expected) < 1e-9, "MPS solve with constant (\(header.replacingOccurrences(of: "\n", with: "/")))", "\(r.status) \(String(describing: r.objectiveValue)) expected \(expected)")
            }
        case .failure(let e): ioCheck(false, "MPS OBJSENSE \(header)", "\(e)")
        }
    }
    // Markers
    let mcols = "    m1 'MARKER' 'INTORG'\n    i1 COST 1 r 1\n    i2 COST 1 r 1\n    m2 'MARKER' 'INTEND'\n    y COST 1 r 1\n"
    switch readMPS(mpsDoc(rows: " N COST\n G r\n", columns: mcols, rhs: "    RHS r 1\n", bounds: " UP BND i2 10\n")) {
    case .success(let lp):
        let i1 = colIndex(lp, "i1")!, i2 = colIndex(lp, "i2")!, y = colIndex(lp, "y")!
        ioCheck(lp.integerColumns == [Int32(i1), Int32(i2)].sorted() && !lp.integerColumns.contains(Int32(y)), "MPS MARKER INTORG/INTEND", "\(lp.integerColumns)")
        ioCheck(lp.xl[i1] == 0 && lp.xu[i1] == 1 && lp.xu[i2] == 10, "MPS integer without bounds is binary (documented); with UP keeps it", "i1 [\(lp.xl[i1]),\(lp.xu[i1])] i2 [\(lp.xl[i2]),\(lp.xu[i2])]")
    case .failure(let e): ioCheck(false, "MPS markers", "\(e)")
    }
    // Non-finite / huge values: README: malformed inputs yield SolverError.invalidModel
    let nonFinite: [(String, String, String, String)] = [
        ("RHS nan", "    RHS r nan\n", "", ""),
        ("RHS inf on G row", "    RHS r inf\n", "", ""),
        ("RHS -inf on L row", "    RHS l -inf\n", "", ""),
        ("RANGES nan", "    RHS r 1\n", "    RNG r nan\n", ""),
        ("RANGES inf on E row", "    RHS e 1\n", "    RNG e inf\n", ""),
        ("RHS 1e400 on E row", "    RHS e 1e400\n", "", ""),
        ("RHS on objective nan", "    RHS COST nan\n", "", ""),
        ("RHS on objective inf", "    RHS COST inf\n", "", ""),
        ("LO inf", "", "", " LO BND x inf\n"),
        ("UP -inf", "", "", " UP BND x -inf\n"),
        ("FX inf", "", "", " FX BND x inf\n"),
        ("FX 1e30", "", "", " FX BND x 1e30\n"),
        ("LO 1e30", "", "", " LO BND x 1e30\n"),
        ("UP -1e30", "", "", " UP BND x -1e30\n"),
        ("coefficient 1e400", "", "", ""),
    ]
    for (label, rhsText, rngText, bndText) in nonFinite {
        var columns = "    x COST 1 r 1\n    x e 1 l 1\n"
        if label == "coefficient 1e400" { columns = "    x COST 1 r 1e400\n    x e 1 l 1\n" }
        let doc = mpsDoc(rows: " N COST\n G r\n E e\n L l\n", columns: columns, rhs: rhsText, ranges: rngText, bounds: bndText)
        switch readMPS(doc) {
        case .failure(let e):
            let invalid: Bool
            if case SolverError.invalidModel = e { invalid = true } else { invalid = false }
            ioCheck(invalid, "MPS \(label) rejected with invalidModel", "\(e)")
        case .success(let lp):
            let bad = invalidities(lp)
            var solved = ""
            if let r = try? await Simplex().solve(lp, context: ctx(3)) { solved = "Simplex -> \(statusKey(r.status)) obj=\(String(describing: r.objectiveValue)) x=\(String(describing: r.primal))" }
            if let r = try? await InteriorPoint().solve(lp, context: ctx(3)) { solved += "; IPM -> \(statusKey(r.status)) obj=\(String(describing: r.objectiveValue))" }
            ioCheck(bad.isEmpty, "MPS \(label) accepted: model valid", "accepted invalid model \(bad); \(solved)")
            if bad.isEmpty { print("      (\(label) accepted: [\(lp.xl[0]),\(lp.xu[0])] rows \((0..<lp.m).map { "[\(lp.rl[$0]),\(lp.ru[$0])]" }) c0=\(lp.c0); \(solved))") }
        }
    }
    // Truncation: missing ENDATA / truncated COLUMNS accepted silently?
    let full = mpsDoc(rows: " N COST\n G r\n", columns: "    x COST 1 r 1\n    y COST 1 r 1\n", rhs: "    RHS r 3\n")
    let truncated = full.components(separatedBy: "\n").prefix(6).joined(separator: "\n") + "\n"
    switch readMPS(truncated) {
    case .success(let lp): print("INFO | MPS truncated after first COLUMNS line accepted: n=\(lp.n) m=\(lp.m) rl=\(lp.rl) (text: \(truncated.replacingOccurrences(of: "\n", with: "/")))")
    case .failure(let e): print("INFO | MPS truncated rejected: \(e)")
    }
    // RHS section before RANGES wipe (non-standard order)
    let order = "NAME T\nROWS\n N COST\n L r\nCOLUMNS\n    x COST -1 r 1\nRANGES\n    RNG r 2\nRHS\n    RHS r 5\nENDATA\n"
    switch readMPS(order) {
    case .success(let lp): print("INFO | MPS RANGES before RHS: row r [\(lp.rl[0]),\(lp.ru[0])] (standard reading [3,5])")
    case .failure(let e): print("INFO | MPS RANGES before RHS: \(e)")
    }
    print("MPS probe: \(ioFails) failures")
}

func probeLP() async {
    let text = """
    \\ comment
    Maximize
     obj: 3 x + 2 y - z + 4
    Subject To
     c1: x + y + z <= 10
     c2: 2 <= x - y
     c3: -2 <= y - z <= 3
     c4: x + 2 >= y + 5 - z
     c5: x + x + y >= 1
    Bounds
     x <= 8
     -inf <= y <= 3
     z free
     w = 2
     -1 <= v <= 1
     u >= -5
    Generals
     g
    Binaries
     b
    End
    """
    // note: w, v, u, g, b appear only in sections (not in objective/rows)
    switch readLP(text) {
    case .success(let lp):
        func col(_ n: String) -> Int? { colIndex(lp, n) }
        print("INFO | LP columns \(lp.names.columns) rows \(lp.names.rows)")
        ioCheck(lp.sense == .maximize && lp.objective(at: [Double](repeating: 0, count: lp.n)) == 4, "LP objective constant 4 under Maximize", "c0=\(lp.c0) sense=\(lp.sense)")
        if let x = col("x"), let y = col("y"), let z = col("z") {
            ioCheck(lp.xl[x] == 0 && lp.xu[x] == 8, "LP bound x <= 8 keeps lower 0", "[\(lp.xl[x]),\(lp.xu[x])]")
            ioCheck(lp.xl[y] == -inf && lp.xu[y] == 3, "LP -inf <= y <= 3", "[\(lp.xl[y]),\(lp.xu[y])]")
            ioCheck(lp.xl[z] == -inf && lp.xu[z] == inf, "LP z free", "[\(lp.xl[z]),\(lp.xu[z])]")
            let A = dense(lp)
            if let r2 = rowIndexNamed(lp, "c2") { ioCheck(A[r2][x] == 1 && A[r2][y] == -1 && lp.rl[r2] == 2 && lp.ru[r2] == inf, "LP 2 <= x - y", "\(A[r2]) [\(lp.rl[r2]),\(lp.ru[r2])]") }
            if let r3 = rowIndexNamed(lp, "c3") { ioCheck(lp.rl[r3] == -2 && lp.ru[r3] == 3, "LP double-sided -2 <= y - z <= 3", "[\(lp.rl[r3]),\(lp.ru[r3])]") }
            if let r4 = rowIndexNamed(lp, "c4") { ioCheck(A[r4][x] == 1 && A[r4][y] == -1 && A[r4][z] == 1 && lp.rl[r4] == 3, "LP x + 2 >= y + 5 - z is x - y + z >= 3", "\(A[r4]) [\(lp.rl[r4]),\(lp.ru[r4])]") }
            if let r5 = rowIndexNamed(lp, "c5") { ioCheck(A[r5][x] == 2, "LP x + x merged to 2x", "\(A[r5])") }
        } else { ioCheck(false, "LP columns x,y,z present") }
        if let w = col("w") { ioCheck(lp.xl[w] == 2 && lp.xu[w] == 2, "LP w = 2", "[\(lp.xl[w]),\(lp.xu[w])]") } else { print("INFO | LP: column w declared only in Bounds is absent") }
        if let u = col("u") { ioCheck(lp.xl[u] == -5 && lp.xu[u] == inf, "LP u >= -5", "[\(lp.xl[u]),\(lp.xu[u])]") }
        if let b = col("b") { ioCheck(lp.xl[b] == 0 && lp.xu[b] == 1 && lp.integerColumns.contains(Int32(b)), "LP Binaries", "[\(lp.xl[b]),\(lp.xu[b])]") } else { print("INFO | LP: binary b only in Binaries is absent") }
        if let g = col("g") { ioCheck(lp.integerColumns.contains(Int32(g)) && lp.xl[g] == 0 && lp.xu[g] == inf, "LP Generals", "[\(lp.xl[g]),\(lp.xu[g])]") } else { print("INFO | LP: general g only in Generals is absent") }
    case .failure(let e): ioCheck(false, "LP hand model parses", "\(e)")
    }
    // negative upper bound with default lower
    switch readLP("Minimize\n obj: x\nSubject To\n c: x + y >= -10\nBounds\n x <= -3\nEnd\n") {
    case .success(let lp): print("INFO | LP 'x <= -3' with default lower: [\(lp.xl[0]),\(lp.xu[0])]")
    case .failure(let e): print("INFO | LP 'x <= -3' with default lower: throws \(e)")
    }
    // Binaries with an explicit bound, Generals with negative bounds
    switch readLP("Maximize\n obj: x + y\nSubject To\n c: x + y <= 10\nBounds\n -3 <= y <= 2.5\nGenerals\n y\nBinaries\n x\nEnd\n") {
    case .success(let lp):
        if let r = try? await BranchAndBound().solve(lp, context: ctx()) {
            ioCheck(abs((r.objectiveValue ?? .nan) - 3) < 1e-9, "LP Binaries+Generals solve: max x+y, x bin, y int <= 2.5 -> 3", "\(r.status) \(String(describing: r.objectiveValue)) \(String(describing: r.primal))")
        }
    case .failure(let e): ioCheck(false, "LP binaries/generals", "\(e)")
    }
    // Ranged row: write -> equality + Rg column; optimum preserved
    let lp = buildLP([[1, 2], [1, -1]], rl: [1, -inf], ru: [5, 3], c: [-1, -1], xl: [0, 0], xu: [inf, inf],
                     names: LPNames(columns: ["x", "y"], rows: ["box", "cap"]))
    if let text = try? LPFormat.write(lp), case .success(let back) = readLP(text) {
        ioCheck(back.n == 3 && back.names.columns.contains("Rgbox"), "LP range row written as equality with Rg column", text)
        let r1 = try? await Simplex().solve(lp, context: ctx()), r2 = try? await Simplex().solve(back, context: ctx())
        ioCheck(abs((r1?.objectiveValue ?? .nan) - (r2?.objectiveValue ?? .nan)) < 1e-9, "LP range round trip keeps optimum", "\(String(describing: r1?.objectiveValue)) vs \(String(describing: r2?.objectiveValue))")
    }
    // LP: invisible column and column order
    let lp2 = buildLP([[0, 1, 1]], rl: [1], ru: [inf], c: [0, 1, 0], xl: [0, 0, 0], xu: [inf, inf, inf],
                      names: LPNames(columns: ["a", "b", "c"], rows: ["r"]))
    let lp3 = buildLP([[1, 1, 0]], rl: [1], ru: [inf], c: [0, 1, 0], xl: [0, 0, 0], xu: [inf, inf, inf],
                      names: LPNames(columns: ["a", "b", "c"], rows: ["r"]))
    for (tag, l) in [("a has no cost/row", lp2), ("c has no cost/row", lp3)] {
        if let t = try? LPFormat.write(l), case .success(let back) = readLP(t) {
            print("INFO | LP round trip (\(tag)): columns \(l.names.columns) -> \(back.names.columns)")
        }
    }
    print("LP probe: \(ioFails) failures")
}

/// Random CompiledLP with every feature the writers must carry.
func randomModel(seed: UInt64, tricky: Bool) -> CompiledLP {
    var g = SeededGenerator(seed: seed)
    let m = Int(g.integer(in: 0...7)), n = Int(g.integer(in: 1...9))
    func num() -> Double {
        switch g.integer(in: 0...6) {
        case 0: return Double(g.integer(in: -9...9))
        case 1: return g.uniform(in: -1...1) * pow(10, Double(g.integer(in: -12...12)))
        case 2: return 0.1 * Double(g.integer(in: -30...30))
        case 3: return Double(g.integer(in: -9...9)) / 3
        case 4: return g.uniform(in: -1e6...1e6)
        case 5: return -0.0
        default: return 1.0 / Double(g.integer(in: 1...97))
        }
    }
    var entries: [(row: Int, col: Int, value: Double)] = []
    for i in 0..<m { for j in 0..<n where g.chance(0.4) { var v = num(); if v == 0 { v = 1 }; entries.append((i, j, v)) } }
    var xl = [Double](), xu = [Double]()
    for _ in 0..<n {
        let a = num(), b = num()
        switch g.integer(in: 0...6) {
        case 0: xl.append(0); xu.append(inf)
        case 1: xl.append(-inf); xu.append(inf)
        case 2: xl.append(min(a, b)); xu.append(max(a, b))
        case 3: xl.append(a); xu.append(a)
        case 4: xl.append(-inf); xu.append(a)
        case 5: xl.append(a); xu.append(inf)
        default: xl.append(0); xu.append(abs(a))
        }
    }
    var rl = [Double](), ru = [Double]()
    for _ in 0..<m {
        let a = num(), b = num()
        switch g.integer(in: 0...4) {
        case 0: rl.append(a); ru.append(a)
        case 1: rl.append(-inf); ru.append(a)
        case 2: rl.append(a); ru.append(inf)
        default: rl.append(min(a, b)); ru.append(max(a, b))
        }
    }
    let c = (0..<n).map { _ in g.chance(0.3) ? 0 : num() }
    let integer = (0..<n).filter { _ in g.chance(0.3) }.map { Int32($0) }
    var colNames = (0..<n).map { "x\($0)" }
    var rowNames = (0..<m).map { "r\($0)" }
    if tricky {
        let pool = ["RHS", "RANGES", "BOUNDS", "ENDATA", "COST", "MARKER", "'MARKER'", "obj", "x y", "*star", "Rgr0", "r0_", "e5", "inf", "free", "x[1,2]", "a:b", "-x", "N", "1e3"]
        for j in 0..<n where g.chance(0.4) { colNames[j] = pool[g.integer(in: 0...(pool.count - 1))] + (g.chance(0.5) ? "" : "\(j)") }
        for i in 0..<m where g.chance(0.4) { rowNames[i] = pool[g.integer(in: 0...(pool.count - 1))] + (g.chance(0.5) ? "" : "\(i)") }
        colNames = LPName.uniqued(colNames); rowNames = LPName.uniqued(rowNames)
    }
    let sense: ObjectiveSense = g.chance(0.5) ? .maximize : .minimize
    let c0 = g.chance(0.5) ? num() : 0
    return CompiledLP(a: SparseCSC.fromTriplets(rows: m, cols: n, entries), c: c, c0: c0, sense: sense,
                      xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer,
                      names: LPNames(columns: colNames, rows: rowNames))
}

func describeDiff(_ a: CompiledLP, _ b: CompiledLP) -> String {
    var d: [String] = []
    if a.m != b.m || a.n != b.n { d.append("dims \(a.m)x\(a.n) vs \(b.m)x\(b.n)") ; return d.joined(separator: ", ") }
    if a.a != b.a { d.append("matrix") }
    if a.c != b.c { d.append("c \(a.c) vs \(b.c)") }
    if a.c0 != b.c0 { d.append("c0 \(a.c0) vs \(b.c0)") }
    if a.sense != b.sense { d.append("sense") }
    if a.xl != b.xl { d.append("xl \(a.xl) vs \(b.xl)") }
    if a.xu != b.xu { d.append("xu \(a.xu) vs \(b.xu)") }
    if a.rl != b.rl { d.append("rl \(a.rl) vs \(b.rl)") }
    if a.ru != b.ru { d.append("ru \(a.ru) vs \(b.ru)") }
    if a.integerColumns != b.integerColumns { d.append("int \(a.integerColumns) vs \(b.integerColumns)") }
    if a.names.columns != b.names.columns { d.append("colnames \(a.names.columns) vs \(b.names.columns)") }
    if a.names.rows != b.names.rows { d.append("rownames \(a.names.rows) vs \(b.names.rows)") }
    return d.joined(separator: ", ")
}

func probeRoundTrip(seeds: Range<UInt64>) async {
    var mpsFail = 0, mpsTrickyFail = 0, lpFail = 0, lpThrow = 0
    var examples: [String] = []
    for seed in seeds {
        let lp = randomModel(seed: seed, tricky: false)
        let text = MPSFormat.write(lp)
        switch readMPS(text) {
        case .success(let back):
            if back != lp {
                mpsFail += 1
                // classify: only range-row bounds off by a few ulps?
                var onlyRange = back.a == lp.a && back.c == lp.c && back.c0 == lp.c0 && back.xl == lp.xl && back.xu == lp.xu && back.integerColumns == lp.integerColumns && back.names.columns == lp.names.columns && back.names.rows == lp.names.rows && back.sense == lp.sense
                var maxAbs = 0.0
                for i in 0..<lp.m where back.rl[i] != lp.rl[i] || back.ru[i] != lp.ru[i] {
                    let isRange = lp.rl[i] > -inf && lp.ru[i] < inf && lp.rl[i] != lp.ru[i]
                    if !isRange { onlyRange = false }
                    maxAbs = max(maxAbs, abs(back.rl[i] - lp.rl[i]) / max(abs(lp.rl[i]), abs(lp.ru[i])), abs(back.ru[i] - lp.ru[i]) / max(abs(lp.rl[i]), abs(lp.ru[i])))
                }
                print("MPSDIFF seed \(seed) onlyRangeRows=\(onlyRange) maxErrRelToLargerEnd=\(maxAbs) \(onlyRange ? "" : describeDiff(lp, back))")
            }
        case .failure(let e): mpsFail += 1; if examples.count < 6 { examples.append("MPS seed \(seed) read failed: \(e)\n\(text)") }
        }
        let tricky = randomModel(seed: seed, tricky: true)
        let t2 = MPSFormat.write(tricky)
        switch readMPS(t2) {
        case .success(let back):
            // names may legitimately be sanitized (spaces -> _); compare everything else
            let same = back.a == tricky.a && back.c == tricky.c && back.c0 == tricky.c0 && back.xl == tricky.xl && back.xu == tricky.xu && back.rl == tricky.rl && back.ru == tricky.ru && back.integerColumns == tricky.integerColumns && back.sense == tricky.sense
            if !same {
                var rangeOnly = back.a == tricky.a && back.c == tricky.c && back.c0 == tricky.c0 && back.xl == tricky.xl && back.xu == tricky.xu && back.integerColumns == tricky.integerColumns && back.sense == tricky.sense && back.m == tricky.m
                if rangeOnly { for i in 0..<tricky.m where back.rl[i] != tricky.rl[i] || back.ru[i] != tricky.ru[i] { if !(tricky.rl[i] > -inf && tricky.ru[i] < inf && tricky.rl[i] != tricky.ru[i]) { rangeOnly = false } } }
                if !rangeOnly { print("TRICKYDIFF seed \(seed): \(describeDiff(tricky, back)) names \(tricky.names.columns)/\(tricky.names.rows)") }
            }
            if !same { mpsTrickyFail += 1; if examples.count < 10 { examples.append("MPS tricky seed \(seed): \(describeDiff(tricky, back)) names \(tricky.names.columns)/\(tricky.names.rows)") } }
        case .failure(let e): mpsTrickyFail += 1; if examples.count < 10 { examples.append("MPS tricky seed \(seed) read failed: \(e) names \(tricky.names.columns)/\(tricky.names.rows)") }
        }
        // LP: compare optimum of LP relaxation (structure is name-matched and reordered by design)
        for model in [lp, tricky] {
            do {
                let t = try LPFormat.write(model)
                let back = try LPFormat.read(t)
                let r1 = try await Simplex().solve(model.relaxed(), context: ctx(5))
                let r2 = try await Simplex().solve(back.relaxed(), context: ctx(5))
                let s1 = statusKey(r1.status), s2 = statusKey(r2.status)
                let unb = s1 == "unbounded" && s2 == "unbounded"
                let same = s1 == s2 && (unb || ((r1.objectiveValue == nil) == (r2.objectiveValue == nil)
                    && (r1.objectiveValue.map { v in abs(v - (r2.objectiveValue ?? .nan)) <= 1e-7 * (1 + abs(v)) } ?? true)))
                if !same || back.m != model.m || back.integerColumns.count != model.integerColumns.count + 0 {
                    // integer count may differ only if invisible columns were integer (they are not invisible then)
                    lpFail += 1
                    if examples.count < 14 { examples.append("LP seed \(seed): \(s1) \(String(describing: r1.objectiveValue)) vs \(s2) \(String(describing: r2.objectiveValue)); m \(model.m)->\(back.m) n \(model.n)->\(back.n) int \(model.integerColumns.count)->\(back.integerColumns.count) names \(model.names.columns)/\(model.names.rows)") }
                }
            } catch {
                lpThrow += 1
                if examples.count < 14 { examples.append("LP seed \(seed) threw \(error) names \(model.names.columns)/\(model.names.rows)") }
            }
        }
    }
    print("round trip seeds \(seeds): MPS exact failures \(mpsFail), MPS tricky-name failures \(mpsTrickyFail), LP optimum/shape failures \(lpFail), LP throws \(lpThrow)")
    for e in examples { print("  " + e) }
}

// MARK: - Fuzzing

func baseCorpus(_ format: String) -> [String] {
    var docs: [String] = []
    for seed in UInt64(0)..<6 {
        let lp = randomModel(seed: seed * 7 + 3, tricky: false)
        if format == "mps" { docs.append(MPSFormat.write(lp)); docs.append(MPSFormat.write(lp, free: false)) }
        else if let t = try? LPFormat.write(lp) { docs.append(t) }
    }
    if format == "mps" {
        docs.append(mpsDoc("OBJSENSE\n    MAX", rows: " N COST\n E e1\n L l1\n G g1\n", columns: "    m1 'MARKER' 'INTORG'\n    x COST 1 e1 1\n    x l1 2 g1 -1\n    m2 'MARKER' 'INTEND'\n    y COST -1 e1 3\n", rhs: "    RHS e1 5 l1 4\n    RHS COST 2\n", ranges: "    RNG e1 -2 l1 3\n", bounds: " UP BND x 4\n MI BND y\n UP BND y 3\n"))
    } else {
        docs.append("Maximize\n obj: 3 x + 2 y - z + 4\nSubject To\n c1: x + y + z <= 10\n c2: 2 <= x - y\n c3: -2 <= y - z <= 3\nBounds\n x <= 8\n -inf <= y <= 3\n z free\nGenerals\n x\nBinaries\n b\nEnd\n")
    }
    return docs
}

func mutate(_ text: String, _ g: inout SeededGenerator) -> String {
    var lines = text.components(separatedBy: "\n")
    let tokensPool = ["nan", "inf", "-inf", "1e400", "-1e400", "1e-400", "0x1p3", "1D+02", "--1", "1e", "+", "-", "99999999999999999999999999999", "0", "-0", "1e30", "-1e30", "1e20", "RHS", "BOUNDS", "RANGES", "COLUMNS", "ROWS", "ENDATA", "N", "E", "L", "G", "UP", "LO", "MI", "PL", "BV", "FR", "FX", "LI", "UI", "SC", "'MARKER'", "'INTORG'", "'INTEND'", "COST", "x0", "r0", "obj:", ":", "<=", ">=", "=", "<", ">", "=<", "=>", "free", "-inf", "+inf", "Bounds", "Subject", "To", "End", "Generals", "Binaries", "st", "\t", " ", "", "x0[1]", "[", "]", "^", "*", "\\", "e5", "1.5e+3", "S1::", "Maximize", "Minimize", "OBJSENSE", "MAX", "OBJSECT", "MARKER"]
    let ops = g.integer(in: 1...3)
    for _ in 0..<ops {
        if lines.isEmpty { lines = [""] }
        let k = g.integer(in: 0...(lines.count - 1))
        switch g.integer(in: 0...11) {
        case 0: // truncate the document at a random character
            let all = lines.joined(separator: "\n")
            let cut = g.integer(in: 0...max(0, all.count))
            lines = String(all.prefix(cut)).components(separatedBy: "\n")
        case 1: lines.remove(at: k)
        case 2: lines.insert(lines[k], at: k)
        case 3: let k2 = g.integer(in: 0...(lines.count - 1)); lines.swapAt(k, k2)
        case 4, 5, 6: // replace a token
            var toks = lines[k].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if toks.isEmpty { toks = [""] }
            let t = g.integer(in: 0...(toks.count - 1))
            toks[t] = tokensPool[g.integer(in: 0...(tokensPool.count - 1))]
            lines[k] = toks.joined(separator: " ")
        case 7: // drop a token
            var toks = lines[k].split(separator: " ").map(String.init)
            if !toks.isEmpty { toks.remove(at: g.integer(in: 0...(toks.count - 1))) }
            lines[k] = (lines[k].hasPrefix(" ") ? " " : "") + toks.joined(separator: " ")
        case 8: // add a token
            lines[k] += " " + tokensPool[g.integer(in: 0...(tokensPool.count - 1))]
        case 9: // insert random bytes
            var chars = Array(lines[k])
            let junk: [Character] = ["\u{0}", "\r", "\t", "é", "€", "\u{FEFF}", "(", ")", ":", "+", "-", "e", "E", "0", "9", ".", ",", " ", "\"", "'"]
            chars.insert(junk[g.integer(in: 0...(junk.count - 1))], at: g.integer(in: 0...chars.count))
            lines[k] = String(chars)
        case 10: // indentation flip
            if lines[k].hasPrefix(" ") { lines[k] = String(lines[k].drop(while: { $0 == " " })) } else { lines[k] = " " + lines[k] }
        default: // duplicate a random block
            let k2 = g.integer(in: k...(lines.count - 1))
            lines.insert(contentsOf: lines[k...k2], at: k2 + 1)
        }
    }
    return lines.joined(separator: "\n")
}

func probeFuzz(format: String, seed: UInt64, count: Int, start: Int, solve: Bool = false) async {
    let corpus = baseCorpus(format)
    var g = SeededGenerator(seed: seed)
    var accepted = 0, rejectedInvalid = 0, rejectedOther = 0, acceptedInvalid = 0
    var otherErrors: [String: Int] = [:]
    var acceptedInvalidExamples: [String] = []
    let current = URL(fileURLWithPath: "fuzz-current-\(format).txt")
    for iteration in 0..<count {
        let base = corpus[g.integer(in: 0...(corpus.count - 1))]
        let input = mutate(base, &g)
        if iteration < start { continue }
        try? input.write(to: current, atomically: false, encoding: .utf8)
        let result = format == "mps" ? readMPS(input) : readLP(input)
        switch result {
        case .success(let lp):
            accepted += 1
            let bad = invalidities(lp)
            if solve && bad.isEmpty && lp.m <= 60 && lp.n <= 60 {
                let r1 = try? await Simplex().solve(lp, context: ctx(1))
                let r2 = try? await InteriorPoint().solve(lp, context: ctx(1))
                let r3 = lp.hasIntegerColumns ? try? await BranchAndBound().solve(lp, context: ctx(1)) : nil
                if let r1, case .optimal = r1.status, let x = r1.primal {
                    let v = lp.maxViolation(at: x)
                    if max(v.bounds, v.rows) > 1e-5 * (1 + (x.map { abs($0) }.max() ?? 0)) { print("fuzz iter \(iteration): Simplex optimal with violation \(v)") }
                }
                if let r1, let r2, case .optimal = r1.status, case .optimal = r2.status, let a = r1.objectiveValue, let b = r2.objectiveValue, abs(a - b) > 1e-6 * (1 + abs(a)) {
                    print("fuzz iter \(iteration): Simplex \(a) vs IPM \(b)")
                }
                _ = r3
            }
            if !bad.isEmpty {
                acceptedInvalid += 1
                if acceptedInvalidExamples.count < 5 { acceptedInvalidExamples.append("iter \(iteration): \(bad.prefix(3))") }
            }
        case .failure(let e):
            if case SolverError.invalidModel = e { rejectedInvalid += 1 }
            else { rejectedOther += 1; otherErrors[String(describing: e).prefix(50).description, default: 0] += 1 }
        }
    }
    print("fuzz \(format) seed \(seed) iterations \(start)..<\(count): accepted \(accepted) (invalid models among them \(acceptedInvalid)), invalidModel \(rejectedInvalid), other errors \(rejectedOther) \(otherErrors)")
    for e in acceptedInvalidExamples { print("  accepted invalid: \(e)") }
}

func probeFile(format: String, path: String) async {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
    let result = format == "mps" ? readMPS(text) : readLP(text)
    switch result {
    case .success(let lp):
        print("read: m=\(lp.m) n=\(lp.n) invalidities \(invalidities(lp))")
        print("xl=\(lp.xl) xu=\(lp.xu) rl=\(lp.rl) ru=\(lp.ru) c=\(lp.c) c0=\(lp.c0) sense=\(lp.sense)")
        if let r = try? await Simplex().solve(lp, context: ctx(3)) { print("Simplex: \(statusKey(r.status)) obj=\(String(describing: r.objectiveValue)) x=\(String(describing: r.primal))") }
        if let r = try? await InteriorPoint().solve(lp, context: ctx(3)) { print("IPM: \(statusKey(r.status)) obj=\(String(describing: r.objectiveValue)) x=\(String(describing: r.primal))") }
        if lp.hasIntegerColumns, let r = try? await BranchAndBound().solve(lp, context: ctx(3)) { print("B&B: \(statusKey(r.status)) obj=\(String(describing: r.objectiveValue)) x=\(String(describing: r.primal))") }
    case .failure(let e): print("rejected: \(e)")
    }
}
