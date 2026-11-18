// Cycle B, slot F4 (branch and bound). Subcommands:
//   rand <kind> <seedStart> <count> [configFilter]   random MILPs vs exhaustive enumeration
//   show <kind> <seed>                               print one instance, its oracle and every config
import Foundation
import ZTronLPOptimizer
import ZTronLPTestSupport

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "rand"

func describe(_ inst: Inst) -> String {
    var s = "\(inst.label) \(inst.maximize ? "max" : "min") nI=\(inst.nI) nC=\(inst.nC) m=\(inst.m)\n"
    s += "  cost=\(inst.cost) c0=\(inst.c0)\n  xl=\(inst.xl)\n  xu=\(inst.xu)\n"
    for i in 0..<inst.m { s += "  \(inst.rl[i]) <= \(inst.rows[i]) <= \(inst.ru[i])\n" }
    return s
}

switch cmd {
case "rand":
    let kind = args.count > 2 ? args[2] : "bin"
    let start = args.count > 3 ? UInt64(args[3])! : 1
    let count = args.count > 4 ? Int(args[4])! : 50
    let filter = args.count > 5 ? args[5] : ""
    var fails = 0
    var statusTally: [String: Int] = [:]
    var nodeTotal = 0
    var runs = 0
    for s in start..<(start + UInt64(count)) {
        let inst = kind == "nearint2" ? nearInt2Instance(seed: s) : kind == "nearint" ? nearIntInstance(seed: s) : (["knap","hardint","hardmix","bigobj","bigobj2"].contains(kind) ? hardInstance(seed: s, kind: kind) : randomInstance(seed: s, kind: kind))
        let lp = inst.compiled()
        let truth = oracle(inst)
        switch truth {
        case .optimal: statusTally["opt", default: 0] += 1
        case .infeasible: statusTally["inf", default: 0] += 1
        case .unbounded: statusTally["unb", default: 0] += 1
        }
        for cfg in allConfigs where filter.isEmpty || cfg.name.contains(filter) {
            let out = await cfg.run(lp)
            nodeTotal += out.nodes
            runs += 1
            let issues = check(inst, lp, truth, out, gapUsed: cfg.name.contains("tightgap") ? tight : Gap())
            if !issues.isEmpty {
                fails += 1
                print("FAIL \(inst.label) [\(cfg.name)] oracle=\(truth) status=\(out.status) obj=\(String(describing: out.objective)) bound=\(String(describing: out.bound)) :: \(issues.joined(separator: " | "))")
            }
        }
    }
    print("DONE kind=\(kind) seeds=\(start)..<\(start + UInt64(count)) configs=\(allConfigs.filter { filter.isEmpty || $0.name.contains(filter) }.count) fails=\(fails) tally=\(statusTally) meanNodes=\(Double(nodeTotal) / Double(max(1, runs)))")

case "show":
    let kind = args[2]
    let seed = UInt64(args[3])!
    let inst = kind == "nearint2" ? nearInt2Instance(seed: seed) : kind == "nearint" ? nearIntInstance(seed: seed) : (["knap","hardint","hardmix","bigobj","bigobj2"].contains(kind) ? hardInstance(seed: seed, kind: kind) : randomInstance(seed: seed, kind: kind))
    print(describe(inst))
    let lp = inst.compiled()
    let truth = oracle(inst)
    print("oracle: \(truth)")
    for cfg in allConfigs {
        let out = await cfg.run(lp)
        let issues = check(inst, lp, truth, out, gapUsed: cfg.name.contains("tightgap") ? tight : Gap())
        print("[\(cfg.name)] status=\(out.status) obj=\(String(describing: out.objective)) bound=\(String(describing: out.bound)) x=\(String(describing: out.primal)) nodes=\(out.nodes) \(issues.isEmpty ? "OK" : "ISSUES: " + issues.joined(separator: " | ")) warn=\(out.warnings)")
    }

case "bigm":
    await probeBigM(args.count > 2 ? Double(args[2])! : 1e6)

case "gapdemo":
    // For each seed: oracle optimum, default-gap BnB, tight-gap BnB; print where default != optimum or bound invalid.
    let kind = args[2]
    let start = UInt64(args[3])!, count = Int(args[4])!
    var subopt = 0, badBound = 0, tightWrong = 0
    for s in start..<(start + UInt64(count)) {
        let inst = hardInstance(seed: s, kind: kind)
        let lp = inst.compiled()
        guard case .optimal(let zs, _) = oracle(inst) else { continue }
        for (name, cfg) in [("default-par", BranchAndBound()), ("default-det", BranchAndBound(deterministic: true)), ("dual-det", BranchAndBound(engine: Simplex(.dual), deterministic: true))] {
            let d = await runBnB(cfg, lp)
            let z = d.objective ?? .nan, b = d.bound ?? .nan
            let sub = abs(z - zs) > 1e-6 * (1 + abs(zs))
            let bad = inst.maximize ? b < zs - 1e-6 * (1 + abs(zs)) : b > zs + 1e-6 * (1 + abs(zs))
            if sub { subopt += 1 }
            if bad { badBound += 1 }
            if sub || bad { print("\(inst.label) [\(name)] oracle=\(zs) status=\(d.status) obj=\(z) bound=\(b) slack=\(slack(z)) suboptimal=\(sub) boundInvalid=\(bad) nodes=\(d.nodes)") }
        }
        let t = await runBnB(BranchAndBound(gap: tight), lp)
        let tz = t.objective ?? .nan
        if abs(tz - zs) > 1e-6 * (1 + abs(zs)) || t.status != .optimal { tightWrong += 1; print("\(inst.label) [tight] oracle=\(zs) status=\(t.status) obj=\(tz) bound=\(String(describing: t.bound))") }
        let tb = t.bound ?? .nan
        if inst.maximize ? tb < zs - 1e-6 * (1 + abs(zs)) : tb > zs + 1e-6 * (1 + abs(zs)) { print("\(inst.label) [tight] bound invalid \(tb) vs \(zs)") }
    }
    print("GAPDEMO kind=\(kind) seeds=\(start)..<\(start + UInt64(count)) suboptimalDefault=\(subopt) invalidBoundDefault=\(badBound) tightWrong=\(tightWrong)")

case "gap":
    await probeGap(p: args.count > 2 ? Double(args[2])! : 3.3)

case "step":
    await probeStep(seed: UInt64(args[2])!)

case "edges":
    await probeEdges()

case "tol":
    await probeTolerance()

case "miplib":
    // miplib <names,comma or all> <engines,comma> <timeLimit>
    let names = args[2] == "all" ? [] : args[2].split(separator: ",").map(String.init)
    let engines = args[3].split(separator: ",").map(String.init)
    await probeMiplib(names: names, engines: engines, timeLimit: Double(args[4])!)

case "limits":
    await probeLimits(args[2].split(separator: ",").map(String.init))

case "det":
    await probeDeterminism(args[2].split(separator: ",").map(String.init), runs: args.count > 3 ? Int(args[3])! : 5)

case "detthreads":
    await probeDetThreads(args[2].split(separator: ",").map(String.init))

case "inv":
    await probeInvariants(seeds: UInt64(args[2])!..<UInt64(args[3])!, cols: Int(args[4])!)

case "boundseed":
    await probeBoundSeed(UInt64(args[2])!, cols: Int(args[3])!)

case "time":
    await probeTime(args[2].split(separator: ",").map(String.init), limits: args[3].split(separator: ",").map { Double($0)! })

case "testint":
    await probeTestIntegrity()

case "exactlimit":
    await probeExactNodeLimit(args[2])

case "unbd":
    await probeUnbounded(kind: args[2], seeds: UInt64(args[3])!..<UInt64(args[4])!)

case "minimize":
    await probeMinimize(seed: UInt64(args[2])!)

case "detsel":
    await probeDetSelection(args[2].split(separator: ",").map(String.init))

case "round":
    await probeRounding(scale: args.count > 2 ? Double(args[2])! : 1)

default:
    print("unknown command \(cmd)")
}
