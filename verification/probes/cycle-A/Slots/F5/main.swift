// Probe slot F5 of cycle A: CP-SAT.
// Build: swift build --product F5 [-c release]   Run: .build/<cfg>/F5 <mode> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"

func arg(_ i: Int, _ d: String) -> String { args.count > i ? args[i] : d }

switch mode {
case "sat":
    await runSAT(family: arg(2, "uf50-218"), cfg: arg(3, "default"), start: Int(arg(4, "0"))!, count: Int(arg(5, "1000"))!, dpll: arg(6, "0") == "1")
case "rand3sat":
    await runRandom3SAT(n: Int(arg(2, "30"))!, count: Int(arg(3, "200"))!, seed: UInt64(arg(4, "1"))!, cfg: arg(5, "default"))
case "enum":
    await runEnum(count: Int(arg(2, "300"))!, seed: UInt64(arg(3, "1"))!, cfg: arg(4, "default"), kind: arg(5, "mixed"))
case "domain":
    await runDomain()
case "gap":
    await runGap()
case "det":
    await runDeterminism(name: arg(2, "lseu"), runs: Int(arg(3, "3"))!, cfg: arg(4, "det"))
case "miplib":
    await runMIPLIB(names: arg(2, "p0033,stein27,enigma,lseu,mod008,p0201,stein45").split(separator: ",").map(String.init), cfg: arg(3, "default"), limit: Double(arg(4, "60"))!)
case "limit":
    await runLimit(name: arg(2, "stein45"), cfg: arg(3, "default"), limit: Double(arg(4, "0.5"))!)
case "wide2":
    await runWide2(count: Int(arg(2, "50"))!, seed: UInt64(arg(3, "1"))!, cfg: arg(4, "default"), width: Int(arg(5, "3000000"))!)
case "mid":
    await runMid(count: Int(arg(2, "50"))!, seed: UInt64(arg(3, "1"))!, cfg: arg(4, "default"), budget: Int(arg(5, "0")).flatMap { $0 > 0 ? $0 : nil }, hints: arg(6, "0") == "1")
case "winner":
    await runWinner(count: Int(arg(2, "60"))!)
case "cancel":
    await runCancel(name: arg(2, "stein45"), cfg: arg(3, "default"), after: Double(arg(4, "0.3"))!, reps: Int(arg(5, "5"))!)
case "xcheck":
    await runXCheck()
case "big":
    await runBig()
default:
    print("modes: sat rand3sat enum domain gap det miplib limit big")
}
