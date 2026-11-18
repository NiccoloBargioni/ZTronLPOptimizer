// Seeded fuzzing of the MPS and LP readers.
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let semMPS = """
NAME          SEM
ROWS
 N  COST
 E  e1
 L  l1
 G  g1
COLUMNS
    x         COST      1.0        e1        1.0
    x         l1        1.0
    MARKER                 'MARKER'                 'INTORG'
    i         COST      1.0        e1        1.0
    i         g1        2.0
    MARKER                 'MARKER'                 'INTEND'
    y         COST      2.0        g1        1.0
RHS
    RHS       COST      5.0        e1        5.0
    RHS       l1        5.0        g1        1.0
RANGES
    RNG       e1        2.0        l1        3.0
BOUNDS
 UP BND       x         4.0
 MI BND       y
 LI BND       i         -2
 UI BND       i         7
ENDATA
"""

let semLP = """
\\ comment
Maximize
 obj: 3 x + 2 y - z + 4
Subject To
 c1: x + y + z <= 10
 c2: 2 x - y >= -3
 c3: x - z = 1
 c4: -2 <= x + 2 y <= 8
Bounds
 x <= 6
 -1 <= y <= 5
 z free
Generals
 g
Binaries
 b
End
"""

func fuzzBases() -> (mps: [String], lp: [String]) {
    var mps = [semMPS]
    var lp = [semLP]
    for s in 0..<6 {
        let m = randomNamedLP(seed: UInt64(1000 + s), freeRows: s % 2 == 0)
        mps.append(MPSFormat.write(m))
        mps.append(MPSFormat.write(m, free: false))
        if let t = try? LPFormat.write(m) { lp.append(t) }
    }
    if let afiro = try? NetlibFixtures.load("afiro") {
        mps.append(MPSFormat.write(afiro)); lp.append((try? LPFormat.write(afiro)) ?? semLP)
    }
    return (mps, lp)
}

let nastyTokens = ["nan", "NaN", "-nan", "inf", "-inf", "+inf", "infinity", "-Infinity", "1e999", "-1e999", "1e-999",
                   "0x1p1023", "1e308", "-1e308", "1e20", "-1e20", "1e30", "-0", "0", "1D+400", "1.5d2",
                   String(repeating: "9", count: 400), "", "x", "'MARKER'", "'INTORG'", "'INTEND'",
                   "RHS", "BOUNDS", "RANGES", "ENDATA", "ROWS", "COLUMNS", "N", "E", "L", "G", "UP", "LO", "FX",
                   "FR", "MI", "PL", "BV", "LI", "UI", "SC", ":", "<=", ">=", "=", "+", "-", "<", ">", "=<", "==",
                   "Subject To", "Bounds", "End", "free", "Generals", "Binaries", "Maximize", "st", "obj:", "[", "^",
                   "é", "\t", "\r", "\u{0}", "∞", "½", "٣", "1e", "1e+", ".", "..", "-.", "+-3", "3x", "x3", "1.2.3"]

struct FuzzCase { let text: String; let what: String }

func mutate(_ base: String, _ g: inout RNG) -> FuzzCase {
    var lines = base.components(separatedBy: "\n")
    var what: [String] = []
    let k = g.int(1, 3)
    for _ in 0..<k {
        let op = g.int(0, 9)
        switch op {
        case 0: // truncate at a character
            let chars = Array(lines.joined(separator: "\n"))
            let cut = g.int(0, max(0, chars.count - 1))
            lines = String(chars[0..<cut]).components(separatedBy: "\n"); what.append("truncate@\(cut)")
        case 1 where !lines.isEmpty:
            let i = g.int(0, lines.count - 1); lines.remove(at: i); what.append("deleteLine\(i)")
        case 2 where !lines.isEmpty:
            let i = g.int(0, lines.count - 1); lines.insert(lines[i], at: i); what.append("dupLine\(i)")
        case 3 where lines.count > 1:
            let i = g.int(0, lines.count - 1), j = g.int(0, lines.count - 1); lines.swapAt(i, j); what.append("swap\(i),\(j)")
        case 4 where !lines.isEmpty, 5 where !lines.isEmpty, 6 where !lines.isEmpty:
            let i = g.int(0, lines.count - 1)
            var toks = lines[i].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if !toks.isEmpty {
                let t = g.int(0, toks.count - 1)
                let rep = g.chance(0.8) ? nastyTokens[g.int(0, nastyTokens.count - 1)] : String(g.int(-99, 99))
                toks[t] = rep
                lines[i] = toks.joined(separator: " "); what.append("tok\(i).\(t)=\(rep.debugDescription)")
            }
        case 7 where !lines.isEmpty:
            let i = g.int(0, lines.count - 1)
            var toks = lines[i].split(separator: " ").map(String.init)
            if !toks.isEmpty { toks.remove(at: g.int(0, toks.count - 1)) }
            lines[i] = " " + toks.joined(separator: " "); what.append("dropTok\(i)")
        case 8 where !lines.isEmpty:
            let i = g.int(0, lines.count - 1)
            lines[i] += " " + nastyTokens[g.int(0, nastyTokens.count - 1)] + " " + nastyTokens[g.int(0, nastyTokens.count - 1)]; what.append("appendToks\(i)")
        default:
            let i = g.int(0, lines.count)
            lines.insert(g.pick(["RHS", "BOUNDS", "ROWS", "COLUMNS", "RANGES", "Subject To", "Bounds", "End", "OBJSENSE", "OBJSENSE MAX", "NAME", "Generals"]), at: i); what.append("insertHeader\(i)")
        }
    }
    return FuzzCase(text: lines.joined(separator: "\n"), what: what.joined(separator: ","))
}

func runFuzz(format: String, from: Int, count: Int, solve: Bool) async {
    let bases = fuzzBases()
    let pool = format == "lp" ? bases.lp : bases.mps
    var accepted = 0, rejected = 0, unsupported = 0, otherErr = 0, invalidAccepted = 0
    var flagged: [String: Int] = [:]
    for k in from..<(from + count) {
        FileHandle.standardError.write("case \(format) \(k)\n".data(using: .utf8)!)
        var g = RNG(UInt64(k) &* 2654435761)
        let base = pool[g.int(0, pool.count - 1)]
        let c = mutate(base, &g)
        do {
            let lp = format == "mps" ? try MPSFormat.read(c.text) : (format == "mpsfixed" ? try MPSFormat.read(c.text, options: { var o = MPSFormat.ReadOptions(); o.fixedColumns = true; return o }()) : try LPFormat.read(c.text))
            accepted += 1
            if let bad = invalidData(lp) {
                invalidAccepted += 1
                let key = bad.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
                flagged[key, default: 0] += 1
                if flagged[key]! <= 2 { print("case \(k) ACCEPTED INVALID (\(bad)) via \(c.what)") }
                if solve {
                    let r = try? await Simplex(.dual).solve(lp, context: ctx(3))
                    if let r, r.status.hasSolution { print("   -> Simplex says \(statusName(r.status)) obj=\(r.objectiveValue ?? .nan) x=\(r.primal ?? [])") }
                }
            }
        } catch let e as SolverError {
            if case .unsupported = e { unsupported += 1 } else if case .invalidModel = e { rejected += 1 } else { otherErr += 1; print("case \(k) other SolverError \(e)") }
        } catch {
            otherErr += 1; print("case \(k) non-SolverError \(error)")
        }
    }
    print("fuzz \(format) \(from)..<\(from + count): accepted=\(accepted) rejected=\(rejected) unsupported=\(unsupported) other=\(otherErr) acceptedInvalid=\(invalidAccepted) kinds=\(flagged)")
}

func dumpFuzzCase(format: String, k: Int) {
    let bases = fuzzBases()
    let pool = format == "mps" ? bases.mps : bases.lp
    var g = RNG(UInt64(k) &* 2654435761)
    let base = pool[g.int(0, pool.count - 1)]
    let c = mutate(base, &g)
    print("--- case \(k): \(c.what)\n\(c.text)\n---")
}
