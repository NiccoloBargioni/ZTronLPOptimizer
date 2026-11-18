// Cycle A, F2 probes. Usage: F2 <mode> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"
func arg(_ k: Int, _ d: Int) -> Int { args.count > k ? Int(args[k]) ?? d : d }

switch mode {
case "kkt":
    await runKKT(count: arg(2, 40), seed0: UInt64(arg(3, 1)), spread: Double(arg(4, 0)), seriousOnly: arg(5, 0) == 1)
case "infeas":
    await runInfeasible(count: arg(2, 60), seed0: UInt64(arg(3, 1)))
case "unbdd":
    await runUnbounded(count: arg(2, 60), seed0: UInt64(arg(3, 1)))
case "netlib":
    await runNetlib()
case "hilbert":
    await runHilbert(maxOrder: arg(2, 12))
case "hilbertcfg":
    await runHilbertConfigs(order: arg(2, 8))
case "limits":
    await runLimits()
case "warm":
    await runWarm(count: arg(2, 20), seed0: UInt64(arg(3, 1)))
case "degen":
    await runDegenerate()
case "numerics":
    runNumerics()
case "hwarn":
    await runHilbertWarnings(order: arg(2, 4))
case "cap":
    await runCap()
case "engine":
    await runEngine()
case "illone":
    await runIllOne(arg(2, 15))
case "illrandom":
    await runIllRandom()
case "one":
    await runOne()
case "crossed":
    await runCrossed()
case "edge":
    await runEdge()
default:
    print("modes: kkt infeas unbdd netlib hilbert hilbertcfg limits warm degen numerics edge")
}
