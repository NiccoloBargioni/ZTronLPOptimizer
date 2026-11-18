// Probe V136, cycle B, sceptic for B5-06 (SATLIB tests skipped, not a known issue, without
// the corpus). Predicts what each corpus test of the package does for the corpus root in force
// ($ZTRONLP_CORPORA or <package>/.corpora), counting the instances independently of
// `Corpora.satlib` (POSIX readdir instead of FileManager), and evaluates the three
// `.enabled(if:)` traits of Tests/ZTronLPCPSATTests/SATTests.swift:16, :35, :52 verbatim.
//
// Usage: [ZTRONLP_CORPORA=<dir>] .build/debug/V136
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let override = ProcessInfo.processInfo.environment["ZTRONLP_CORPORA"] ?? ""
let independentRoot = override.isEmpty ? "/Users/admin/Documents/ZTronLPOptimizer/.corpora" : override
print("ZTRONLP_CORPORA      = \(override.isEmpty ? "<unset>" : override)")
print("Corpora.root         = \(Corpora.root.path)")
print("independent root     = \(independentRoot)")

/// Files ending in .cnf in `path`, by readdir; nil when the directory does not exist.
func countCNF(_ path: String) -> Int? {
    guard let dir = opendir(path) else { return nil }
    defer { closedir(dir) }
    var n = 0
    while let entry = readdir(dir) {
        var raw = entry.pointee.d_name
        let length = Int(entry.pointee.d_namlen)
        let name = withUnsafeBytes(of: &raw) { bytes in
            String(decoding: bytes.prefix(length), as: UTF8.self)
        }
        if name.hasSuffix(".cnf") { n += 1 }
    }
    return n
}

let families = ["uf50-218", "uuf50-218"]
var independent: [String: Int] = [:]
for family in families {
    let viaAPI = Corpora.satlib(family).count
    let viaReaddir = countCNF(independentRoot + "/satlib/" + family)
    independent[family] = viaReaddir ?? 0
    print("\(family): Corpora.satlib = \(viaAPI), readdir = \(viaReaddir.map(String.init) ?? "no directory")"
          + (viaAPI == (viaReaddir ?? 0) ? "  [agree]" : "  [DISAGREE]"))
}

// The traits, verbatim from SATTests.swift.
let trait16 = !Corpora.satlib("uf50-218").isEmpty
let trait35 = !Corpora.satlib("uuf50-218").isEmpty
let trait52 = !Corpora.satlib("uf50-218").isEmpty && !Corpora.satlib("uuf50-218").isEmpty
// The same, from the independent counts.
let uf = independent["uf50-218"]!, uuf = independent["uuf50-218"]!
let ind16 = uf > 0, ind35 = uuf > 0, ind52 = uf > 0 && uuf > 0
print("traits (verbatim)    : :16 \(trait16)  :35 \(trait35)  :52 \(trait52)")
print("traits (independent) : :16 \(ind16)  :35 \(ind35)  :52 \(ind52)"
      + ((trait16, trait35, trait52) == (ind16, ind35, ind52) ? "  [agree]" : "  [DISAGREE]"))

func predict(_ test: String, enabled: Bool, needs: Int, have: Int, countExpectation: Bool) {
    let outcome: String
    if !enabled {
        outcome = "SKIPPED by .enabled(if:) -> not run; no issue and no known issue is recorded"
    } else if countExpectation && have < needs {
        outcome = "RUNS and FAILS: #expect(files.count == \(needs)) sees \(min(have, needs))"
    } else if !countExpectation && have < needs {
        outcome = "RUNS on \(max(0, have - 100)) of 20 instances per family (no count check)"
    } else {
        outcome = "RUNS on the full set"
    }
    print("  \(test): \(outcome)")
}
print("predicted SATTests outcomes:")
predict("satlibUF50AllSatisfiable (:16)", enabled: trait16, needs: 100, have: uf, countExpectation: true)
predict("satlibUUF50AllUnsatisfiable (:35)", enabled: trait35, needs: 100, have: uuf, countExpectation: true)
predict("satlibPortfolioAgrees (:52)", enabled: trait52, needs: 120, have: min(uf, uuf), countExpectation: false)

// Contrast: MIPLIBCorpusTests.load (CorpusTests.swift:113-119) records a known issue per
// missing instance.
let miplib = ReferenceValues.miplib3.map(\.name)
let missing = miplib.filter { access(independentRoot + "/miplib3/\($0).mps", F_OK) != 0 }
print("MIPLIB 3: \(miplib.count) reference instances, \(missing.count) missing on disk"
      + (missing.isEmpty ? "" : " -> withKnownIssue for each: \(missing.joined(separator: " "))"))
