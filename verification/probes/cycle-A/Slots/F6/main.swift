// Probe slot F6 of cycle A: runtime (cancellation, limits, events, concurrency, memory budget,
// Metal tier, Automatic and Portfolio facades).
// Build: swift build --product F6 [-c release]   Run: .build/release/F6 <command> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

switch command {
case "cancel": await cancelAll(args)
case "cancel-large": await cancelLarge(args)
case "timelimit": await timeLimits(args)
case "dense-detail": await denseDetail(args)
case "events": await eventsProbe(args)
case "events-model": await eventsModel(args)
case "portfolio": await portfolioProbe(args)
case "automatic": await automaticProbe(args)
case "threads": await threadsProbe(args)
case "memory": await memoryProbe(args)
case "metal": await metalProbe(args)
case "misc": await miscProbe(args)
case "bnbagree": await searchAgreement(args)
case "bound-detail": await boundDetail(args)
case "bound-miplib": await boundMiplib(args)
default:
    print("commands: cancel, cancel-large, timelimit, events, portfolio, automatic, threads, memory, metal, misc")
}
