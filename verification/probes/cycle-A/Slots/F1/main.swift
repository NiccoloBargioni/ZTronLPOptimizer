// Probe slot F1 of cycle A (finder F1: core). Subcommands:
//   presolve <from> <to> [infeasible] [verbose]   presolve/scaling on-off with KKT+basis+ray checks
//   intpresolve <from> <to>                       integer presolve by enumeration
//   dsl                                           DSL / compile / Solution API checks
//   mps                                           MPS semantics checks
//   lp                                            LP-format semantics checks
//   roundtrip <from> <to>                         MPS/LP write-read round trips on random models
//   fuzz <mps|lp> <seed> <count> [start]          mutation fuzzing (writes current input to fuzz-current.txt)
//   file <mps|lp> <path>                          read one file and solve it (for minimised repros)
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"
func arg(_ i: Int, _ d: UInt64) -> UInt64 { args.count > i ? UInt64(args[i]) ?? d : d }

switch command {
case "presolve":
    await probePresolve(seeds: arg(2, 0)..<arg(3, 50), infeasible: args.contains("infeasible"), verbose: args.contains("verbose"))
case "intpresolve":
    probeIntegerPresolve(seeds: arg(2, 0)..<arg(3, 200))
case "detail":
    await probeDetail(seed: arg(2, 14))
case "basisrepro":
    await probeBasisRepro()
case "misc":
    await probeMisc()
case "misc2":
    await probeMisc2()
case "emptycol":
    await probeEmptyColumn()
case "names":
    probeNames()
case "emptyname":
    await probeEmptyName()
case "netlib":
    await probeNetlib()
case "unbobj":
    await probeUnboundedObjective()
case "dsl":
    await probeDSL()
case "mps":
    await probeMPS()
case "lp":
    await probeLP()
case "roundtrip":
    await probeRoundTrip(seeds: arg(2, 0)..<arg(3, 100))
case "fuzz":
    await probeFuzz(format: args.count > 2 ? args[2] : "mps", seed: arg(3, 1), count: Int(arg(4, 1000)), start: Int(arg(5, 0)), solve: args.contains("solve"))
case "file":
    await probeFile(format: args[2], path: args[3])
default:
    print("usage: see main.swift header")
}
