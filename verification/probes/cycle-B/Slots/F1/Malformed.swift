// Targeted malformed inputs: is each rejected with invalidModel? If accepted, what does a solve do?
import Foundation
import ZTronLPOptimizer

func mpsDoc(rows: String = " N obj\n L c1", columns: String = " x obj 1 c1 1", rhs: String = "", ranges: String = "", bounds: String = "", end: Bool = true) -> String {
    var t = "NAME T\nROWS\n\(rows)\nCOLUMNS\n\(columns)\n"
    if !rhs.isEmpty { t += "RHS\n\(rhs)\n" }
    if !ranges.isEmpty { t += "RANGES\n\(ranges)\n" }
    if !bounds.isEmpty { t += "BOUNDS\n\(bounds)\n" }
    if end { t += "ENDATA\n" }
    return t
}

func runMalformed() async {
    let mpsCases: [(String, String)] = [
        ("RHS nan", mpsDoc(rhs: " RHS c1 nan")),
        ("RANGES nan", mpsDoc(rhs: " RHS c1 5", ranges: " RNG c1 nan")),
        ("RHS inf on E row", mpsDoc(rows: " N obj\n E c1", rhs: " RHS c1 inf")),
        ("RHS -inf on L row", mpsDoc(rhs: " RHS c1 -inf")),
        ("RHS -1e999 on L row", mpsDoc(rhs: " RHS c1 -1e999")),
        ("RHS inf on G row", mpsDoc(rows: " N obj\n G c1", rhs: " RHS c1 inf")),
        ("RHS nan on objective row", mpsDoc(rhs: " RHS obj nan")),
        ("RHS inf on objective row", mpsDoc(rhs: " RHS obj inf")),
        ("UP -inf", mpsDoc(bounds: " UP BND x -inf")),
        ("LO inf", mpsDoc(bounds: " LO BND x inf")),
        ("FX inf", mpsDoc(bounds: " FX BND x inf")),
        ("FX -inf", mpsDoc(bounds: " FX BND x -inf")),
        ("coefficients summing to inf", mpsDoc(columns: " x obj 1 c1 1e308\n x c1 1e308")),
        ("objective coefficients summing to inf", mpsDoc(columns: " x obj 1e308 c1 1\n x obj 1e308")),
        ("truncated: no ENDATA, no BOUNDS", mpsDoc(rhs: " RHS c1 5", bounds: "", end: false)),
        ("truncated mid COLUMNS", "NAME T\nROWS\n N obj\n L c1\n L c2\nCOLUMNS\n x obj 1 c1 1\n"),
        ("RANGES before RHS", "NAME T\nROWS\n N obj\n L c1\nCOLUMNS\n x obj -1 c1 1\nRANGES\n RNG c1 2\nRHS\n RHS c1 5\nENDATA\n"),
        ("BOUNDS with 6 fields", mpsDoc(bounds: " UP BND x 4 7 9")),
        ("COLUMNS line with 4 fields", mpsDoc(columns: " x obj 1 c1")),
        ("duplicate column names (non-contiguous)", mpsDoc(rows: " N obj\n L c1\n L c2", columns: " x obj 1 c1 1\n y c2 1\n x c2 3")),
        ("duplicate RHS entry", mpsDoc(rhs: " RHS c1 5\n RHS c1 7")),
        ("no ROWS section", "NAME T\nCOLUMNS\n x obj 1\nENDATA\n"),
        ("empty document", ""),
        ("only NAME", "NAME T\n"),
        ("negative range on L row", mpsDoc(rhs: " RHS c1 5", ranges: " RNG c1 -3")),
    ]
    let lpCases: [(String, String)] = [
        ("inf coefficient", "Minimize\n obj: x\nSubject To\n c1: inf x + y >= 1\nEnd\n"),
        ("1e999 coefficient", "Minimize\n obj: x\nSubject To\n c1: 1e999 x + y >= 1\nEnd\n"),
        ("inf objective coefficient", "Minimize\n obj: inf x + y\nSubject To\n c1: x + y >= 1\nEnd\n"),
        ("inf objective constant", "Minimize\n obj: x + inf\nSubject To\n c1: x >= 1\nEnd\n"),
        ("inf - inf rhs (NaN)", "Minimize\n obj: x\nSubject To\n c1: x + inf <= inf\nEnd\n"),
        ("crossed double-sided row", "Minimize\n obj: x\nSubject To\n c1: 5 <= x + y <= 3\nEnd\n"),
        ("bound x >= inf", "Minimize\n obj: x\nSubject To\n c1: x + y >= 1\nBounds\n x >= inf\nEnd\n"),
        ("bound x = -inf", "Minimize\n obj: x\nSubject To\n c1: x + y >= 1\nBounds\n x = -inf\nEnd\n"),
        ("row = inf", "Minimize\n obj: x\nSubject To\n c1: x + y = inf\nEnd\n"),
        ("row <= -inf", "Minimize\n obj: x\nSubject To\n c1: x + y <= -inf\nEnd\n"),
        ("SOS section", "Minimize\n obj: x + y\nSubject To\n c1: x + y >= 1\nSOS\n s1: S1:: x:1 y:2\nEnd\n"),
        ("semi-continuous section", "Minimize\n obj: x + y\nSubject To\n c1: x + y >= 1\nSemi-continuous\n x\nEnd\n"),
        ("no End", "Minimize\n obj: x\nSubject To\n c1: x >= 1\n"),
        ("truncated mid-constraint", "Minimize\n obj: x\nSubject To\n c1: x + y >= 1\n c2: x +"),
        ("two objectives", "Minimize\n obj: x\nMaximize\n obj2: y\nSubject To\n c1: x + y <= 1\nEnd\n"),
        ("duplicate row names", "Minimize\n obj: x\nSubject To\n c1: x >= 1\n c1: x <= 3\nEnd\n"),
        ("bound before Subject To", "Minimize\n obj: x\nBounds\n x <= 3\nSubject To\n c1: x + y >= 1\nEnd\n"),
        ("extra tokens in a bound", "Minimize\n obj: x\nSubject To\n c1: x + y >= 1\nBounds\n x <= 3 7 9\nEnd\n"),
    ]
    for (fmt, cases) in [("MPS", mpsCases), ("LP", lpCases)] {
        for (label, text) in cases {
            var line = "\(fmt) [\(label)]: "
            do {
                let lp = fmt == "MPS" ? try MPSFormat.read(text) : try LPFormat.read(text)
                line += "ACCEPTED m=\(lp.m) n=\(lp.n) rl=\(lp.rl) ru=\(lp.ru) xl=\(lp.xl) xu=\(lp.xu) c=\(lp.c) c0=\(lp.c0) a=\(lp.a.values)"
                if let bad = invalidData(lp) { line += "  INVALID: \(bad)" }
                for (name, run) in [("dual", { try await Simplex(.dual).solve(lp, context: ctx(3)) as any SolutionAnalysis }),
                                    ("primal", { try await Simplex(.primal).solve(lp, context: ctx(3)) as any SolutionAnalysis }),
                                    ("ipm", { try await InteriorPoint().solve(lp, context: ctx(3)) as any SolutionAnalysis }),
                                    ("auto", { try await Automatic().solve(lp, context: ctx(3)) as any SolutionAnalysis })] {
                    do {
                        let r = try await run()
                        line += "\n      \(name): \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(r.primal ?? [])"
                        if r.status.hasSolution, let x = r.primal { let v = lp.maxViolation(at: x); line += " maxViolation=\(v)" }
                    } catch { line += "\n      \(name): throws \(error)" }
                }
            } catch let e as SolverError {
                switch e {
                case .invalidModel(let d): line += "rejected invalidModel(\(d.message))"
                case .unsupported(let s): line += "rejected unsupported(\(s))"
                default: line += "rejected \(e)"
                }
            } catch { line += "NON-SolverError \(error)" }
            print(line)
        }
    }
}
