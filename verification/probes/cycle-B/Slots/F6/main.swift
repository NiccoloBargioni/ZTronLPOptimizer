// Cycle B, finder F6 (runtime): cancellation, limits, events, concurrency, memory budget,
// Metal tier, Automatic and Portfolio facades. Usage: F6 <mode> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())
let started = nowNs()
switch mode {
case "cancel": await runCancel(rest)
case "limits": await runLimits(rest)
case "memory": await runMemory(rest)
case "events": await runEvents(rest)
case "portfolio": await runPortfolio(rest)
case "automatic": await runAutomatic(rest)
case "metal": await runMetal(rest)
case "threads": await runThreads(rest)
case "bigcancel": await runBigCancel(rest)
case "analyzer": await runAnalyzerTiming(rest)
case "util2": await runUtil2(rest)
default:
    print("modes: cancel limits memory events portfolio automatic metal threads bigcancel")
}
print("DONE \(mode) in \(String(format: "%.2f", secs(started))) s")
