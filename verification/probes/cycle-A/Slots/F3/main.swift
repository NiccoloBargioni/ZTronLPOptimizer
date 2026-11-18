// Probe slot F3 of cycle A: interior point, crossover-lite, conditioning analyzer, Conditioned.
// Build: swift build --product F3 [-c release]   Run: .build/<cfg>/F3 <mode> [args]
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())
let t0 = Date()
switch mode {
case "kkt": try await probeKKT(rest)
case "tinyinf": try await probeTinyInfeasible(rest)
case "infunb": try await probeInfeasibleUnbounded(rest)
case "hilbert": try await probeHilbert(rest)
case "stallcancel": try await probeStallCancel(rest)
case "dense": try await probeDense(rest)
case "cond": try await probeCondition(rest)
case "conditioned": try await probeConditioned(rest)
case "netlib": try await probeNetlib(rest)
case "limits": try await probeLimits(rest)
case "basis": try await probeBasis(rest)
case "hone": try await probeHilbertOne(rest)
case "objscale": try await probeObjectiveScale(rest)
case "illfree": try await probeIllFree(rest)
case "illone": try await probeIllOne(rest)
case "viol": try await probeViolation(rest)
case "tinyfacades": try await probeTinyFacades(rest)
case "basisrow": try await probeBasisRow(rest)
default:
    print("modes: kkt tinyinf infunb hilbert stallcancel dense cond conditioned netlib limits")
}
print(String(format: "elapsed %.2f s", Date().timeIntervalSince(t0)))
