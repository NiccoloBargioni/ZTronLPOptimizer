# A4-05: contract lens (cycle A sceptic, slot V104)

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** high (the finder also said high; I rated it on my own)

## What the package promises

- `SolutionAnalysis.bound` (Sources/ZTronLPCore/Solve/Analysis.swift:22): "Proven bound; equals `objectiveValue` when optimal."
- `SolveStatus.feasible` (Status.swift:14): "An incumbent exists; optimality was not proven."
- `BranchAndBoundAnalysis.gap` (BranchAndBound.swift:99): "The relative gap between incumbent and bound".
- README §3 risk 3 covers exactly this case, a hard model under a limit. It says: "Set `timeLimit` or `nodeLimit`, and read `bound` and `BranchAndBoundAnalysis.gap` to know how far the incumbent may be from the optimum."
- README §1 item 3 and HANDBOOK "Contracts": stopping "return[s] what exists so far". SPECIFICATION-v0.2 line 30, describing the current package: "The LP bound at the root is all the bound there is."
- The mathematical contract: a proven bound of a maximisation model must be ≥ z*, and for a minimisation model ≤ z*.
- Nothing in README §4 (defects, limits by design, not verified), the HANDBOOK decisions, known gaps or not verified, or the doc comments limits this for small time limits or for stops at the root. `SolveContext.timeLimit` says only "Seconds, wall clock." A short limit or an early cancel is valid input, not misuse.

## Does the causal story hold? Yes, from reading the code

- BranchAndBound.swift:304-322: `search.expand` of node 0 runs rounding, the dive and the strong-branching probes. A `StopSignal` thrown there sets only `stoppedAtRoot`. `rootChildren` stays `[]` and `tree.begin(root:children: [])` is called.
- `begin` → `absorb` (SearchTree.swift:212-247) counts the root as processed and queues nothing. The root's bound (the root LP value) never enters `open`, `inFlightBounds` or `prunedBound`.
- `provenBound` (SearchTree.swift:402-407) is min(prunedBound = ∞, incumbent, nothing open, nothing in flight), which is the incumbent. BranchAndBound.swift:347-372 then reports bound = incumbent and relativeGap = 0, with status `.feasible(stoppedBy:)`.
- An ordinary node that is stopped is handled differently. `workerLoop` (TreeSearch.swift:121-123) calls `tree.abandon(node, closing:)`, which pushes the node back so its bound still counts. The root has no such path, so this is an omission and not a design choice.
- `checkGapAndMemory` is guarded by `open.count + inFlight > 0`, so the status does not become `.optimal`. Only the bound and the gap are wrong.

## Execution (probe V104, release build, metal off)

Oracle: `randomMILP(30x120, seed 77, upper 1)`, maximise, all 120 columns integer.
- `BranchAndBound(engine: Simplex(.dual))`, 150 s: optimal 1097, 48,368 nodes.
- `CPSAT()`, 150 s: optimal 1097. This is an independent engine.
- Both 1097 points check out directly: bound violation 0, row violation 0, fractionality 0, `objective(at:)` 1097.
- Root LP: 1120.525624.

`stop 1097` (default primal and dual node engines, 1 and 8 threads, 2 repetitions each; Task.cancel after a delay):
- T 0.0005, 0.001 and 0.002 s, both engines, 1 and 8 threads, every repetition: `feasible(timeLimit)`, obj 947, **bound 947, gap 0**, nodes 1, open 0, rootLP 1120.525624, incumbents ["rounding@0"].
- cancel after 0.2, 0.5 and 1.0 ms: `feasible(cancelled)`, obj 947, **bound 947, gap 0**, nodes 1.
- From T 0.003 s, or a cancel after 2 ms, the stop lands after the root's children are queued, and the bound is valid: 1118.806 with gap 0.181 (1 node, 2 open). Later stops give bounds from 1117.6 to 1116.3.
- The 947 incumbent point is feasible (violations 0, integral). The objective is right and the bound is wrong.
- SUMMARY: 27 of 53 results report a bound below the verified feasible objective 1097.

`wide` (MIPLIB 3 corpus plus two larger random MILPs, 8 threads, T from 1 ms to 1 s): 12 results show the same signature, on 6 of 13 instances. Whenever the optimum was known, the reported bound was on the wrong side of it:
- stein27 (min, opt 18, root LP 13), T 0.001 to 0.005: bound = obj = 27 or 19, gap 0.
- stein45 (min, opt 30, root LP 22), T 0.005, 0.01 and 0.02: bound = obj = 45, gap 0. T 0.05: bound = obj = 32, gap 0. T 0.1 gives the valid bound 22.
- mod008 (opt 307), T 0.001: bound = obj = 510. egout (opt 568.1), T 0.001: bound = obj = 689.45.
- randomMILP(80x400) at T 0.01 and 0.02, and randomMILP(120x800, upper 3) at T 0.05: bound = incumbent, gap 0.

`big 300 3000 3 1` (randomMILP 300x3000, maximise, 8 threads):
- **T 1.0 s, three runs: `feasible(timeLimit)`, obj 27795, bound 27795, gap 0**, nodes 1, open 0, rootLP 28881.13.
- T 1.3 s: bound 28881.13 (valid), gap 0.039.
- T 4.0 s: a verified feasible point (violations 0, integral) with obj 27908 > 27795, so the bound from the 1 s run is provably false.
- T 0.7 s: `noSolution`, because the root LP had not finished.

The window is the time the root expansion takes, and it grows with the model: a few ms at 30x120, about 50 ms on stein45, about 1.0-1.3 s at 300x3000. So a plain `timeLimit = 1` on a mid-size model, which is the setting risk 3 recommends, gives "gap 0" for an incumbent that is not optimal.

## Refutation paths considered

- Wrong oracle: no. Two engines prove 1097, the point was checked directly, and the corpus optima come from ReferenceValues.
- Misuse: no. The time limits are valid, the 1 s case is ordinary, and cancellation is a documented result.
- By design: no. Stopped non-root nodes go back to the pool. Only the root skips this.
- Inside a tolerance: no. The gap tolerance is 1e-4, and the errors are 4 to 50 %.
- Not reproducible: no. Every repetition is identical.
- Documented: no. Nothing covers it.

## Severity

high. The status stays `.feasible` and the point and objective are right, so this is not critical. But the bound sits 4 to 50 % on the wrong side of the optimum and the gap reads 0. That makes the "Proven bound" contract and README risk 3's advice materially false. It happens on ordinary inputs, not only on an edge case: a 1 s limit on a 300x3000 model triggers it.

## Commands

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V104 -c release
perl -e 'alarm shift; exec @ARGV' 420 .build/release/V104 ref        # -> Slots/V104/ref.log
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V104 stop 1097  # -> Slots/V104/stop.log
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V104 wide       # -> Slots/V104/wide.log
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V104 big 300 3000 3 1 0.1 0.2 0.5 1 2 4
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V104 big 300 3000 3 1 0.7 1.0 1.0 1.3   # -> Slots/V104/big.log
```
All runs exited normally; the alarm never fired.
