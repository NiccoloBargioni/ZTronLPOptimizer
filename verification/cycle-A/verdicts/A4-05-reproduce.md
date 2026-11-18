# A4-05: sceptic verdict, lens REPRODUCE (cycle A, slot V103)

- Verdict: **confirmed**
- Documented: **no**
- Severity: **high**
- Package: git main @ d9afebe (working tree clean apart from verification/)
- Probe: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V103/main.swift
  (written from the finding's description. The finder's oracle, a 120 s `Simplex(.dual)` branch and bound run, is not used.)

## What was checked

1. **Whether the behaviour happens.** Yes. It happens on every run whenever the stop lands inside the root expansion: from natural time limits, from deterministic cancellation, from a deterministic deadline, and on a second, larger model.
2. **Whether the finder's expected value is right.** Yes. I checked it with my own oracle, independently of the finder's.
   - **LP relaxation value is certified at 1120.525624.** I took the primal point from Simplex(.primal), Simplex(.dual) and InteriorPoint(.none) and checked it myself: max violation 1.7e-13, so LP opt >= 1120.525624. My own weak-duality bound from the returned duals gives LP opt <= 1120.525624. The weak-duality bound holds for *any* multiplier vector, so it does not trust the solver.
   - **An integer point with objective 1097 is verified exactly** in Int64 arithmetic: integrality, 0/1 bounds and all 30 rows. Two independent engines produced it: BranchAndBound with the **primal** engine (the finder used dual) and **CPSAT**. Both prove 1097 optimal.
   - **Conclusion on the oracle.** A valid upper bound for this maximisation must be >= 1097. The reported "bound 947" is false by 150, and the incumbent is (1097-947)/1097 = 13.7% below the optimum.
   - **The right gap is about 18%.** With the root kept in the tree the bound is 1118.81, which gives gap 0.181. Against the root LP it would be 0.183. The finder's "about 18%" holds.
3. **Whether it depends on load or uncontrolled randomness.** No.
   - **Cancellation pinned to an event.** The probe cancels from the `progress` callback at the root's own `newIncumbent(node: 0, source: "rounding")` event. That fixes the moment of the stop without any timing, and it failed in 10/10 runs at 1 thread and 10/10 at 8 threads.
   - **Deadline pinned to an event.** The callback blocks 1.2 s at the same event with a 1 s time limit. That failed in 3/3 runs at each thread count.
   - **Controls.** Cancelling at the first `boundImproved` event (after the root is in the tree) gives a valid bound 1118.81 in 10/10 runs at each thread count. `nodeLimit` 1 and 2 also give valid bounds. The defect is therefore exactly the root-expansion window.

## The code, as read

- **Root stop path.** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:304-322. When `search.expand` of node 0 throws a `StopSignal`, `rootChildren` stays `[]`. Then `tree.begin(root:children: [])` queues nothing, and `tree.close(.timeLimit|.cancelled)` runs. The root node itself is never pushed into the tree.
- **Bound collapse.** SearchTree.swift:402-407. `provenBound` is min(prunedBound = +inf, incumbent, open, in flight), so it collapses to the incumbent. The result then has bound = objective and gap = 0.
- **The worker loop does it right.** TreeSearch.swift:121-123 handles the same `StopSignal` on any other node with `tree.abandon(node, closing:)`, which returns the node to the pool and keeps the bound valid. Only the root path misses this. No test in Tests/ covers a stop during the root expansion.

## Claims contradicted

- **README §3 risk 3.** It says to "read `bound` and `BranchAndBoundAnalysis.gap` to know how far the incumbent may be from the optimum". Here they report 0 when the truth is 13.7% (and 5.4% or more on the larger model).
- **`SolutionAnalysis.bound`.** Its doc says "Proven bound", but the reported value is below a verified feasible objective.
- **Status versus numbers.** The status is `.feasible` ("optimality was not proven"), while bound = objective and gap 0 together say the incumbent is optimal.
- **Not documented.** Nothing on this appears in README §3/§4, HANDBOOK or SPECIFICATION-v0.2.

## Why not refuted

- **Oracle.** It is independent and certified: an exact integer check, a primal plus weak-duality LP certificate, and two engines different from the finder's.
- **Misuse.** `timeLimit` and `Task.cancel` are documented uses. The natural sweep and the larger-model runs use no callback tricks.
- **Tolerance.** The error is 13.7% against a 1e-4 gap tolerance.
- **Reproducibility.** It reproduced on every run, including the deterministically triggered runs.

## Severity

**High.** A published claim (README risk 3, `bound` = "Proven bound") is materially false whenever a stop lands during the root expansion. The window is not only sub-millisecond: it grows with the model, measured 69-150 ms on a 120x1200 model under load. Ordinary limits of 93, 118 and 142 ms hit it in 6/6 runs.

It is not critical: the objective and the point are correct (verified feasible), only the bound and gap are false.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V103 -c release                               # Build complete
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 oracle     # exit 0
  LP Simplex(.primal): optimal reported 1120.53 | my pᵀx 1120.525624089 maxViol 8.5e-14 | my weak-duality UB(y) 1120.525624089
  LP Simplex(.dual):   optimal reported 1120.53 | my pᵀx 1120.525624089 maxViol 1.7e-13 | my weak-duality UB(y) 1120.525624089
  LP InteriorPoint(.none): optimal 1120.53 | my pᵀx 1120.525623955 maxViol 0 | UB(y) 1120.525624116
  BranchAndBound(primal) 120s: optimal obj 1097 bound 1097 nodes 44976 2.1s | exact check: true objective 1097
  CPSAT 120s: optimal obj 1097 bound 1097 conflicts 794163 7.6s | exact check: true objective 1097
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 natural 1097   # 5 reps each, exit 0, load ~9-10
  T 0.0005/0.001/0.002, t1 and t8: feasible-ROOTLOST=5 (each)
    e.g. feasible(stoppedBy: timeLimit) obj 947 bound 947 gap 0 nodes 1 open 0 rootLP 1120.53 inc ["rounding@0"]
  T 0.003 t1/t8: feasible-validBound=5: obj 947 bound 1118.81 gap 0.181421 nodes 1 open 2
  T 0.005 .. 0.05: feasible-validBound=5 (each)
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 cancel 1097    # exit 0
  cancel at root incumbent, t1: ROOTLOST=10; t8: ROOTLOST=10
    e.g. feasible(stoppedBy: cancelled) obj 947 bound 947 gap 0 nodes 1 open 0 | cancelled at 0.586ms newIncumbent(947, node 0, "rounding")
  CONTROL cancel at first boundImproved, t1: validBound=10; t8: validBound=10 (bound 1118.81 gap 0.181421 open 2)
  nodeLimit 1: feasible(nodeLimit) bound 1118.81 gap 0.181; nodeLimit 2: bound 1117.75 gap 0.180
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 deadline 1097  # exit 0
  timeLimit 1 s, callback blocks 1.2 s at root incumbent, t1: ROOTLOST=3; t8: ROOTLOST=3
    events: 0.564ms newIncumbent(947, node 0, rounding); 1203.5ms boundImproved(bound: 947.0, gap: 0.0); nodes(1, open 0);
            finished(feasible(stoppedBy: timeLimit), 1.2035 s)
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V103 big 120 1200 5   # exit 0, load ~16
  root window: first incumbent at 68.9 ms, root children queued at 150.4 ms
  T 0.0933 s (x2), 0.1178 s (x2), 0.1423 s (x2): feasible(timeLimit) obj 11097 bound 11097 gap 0 nodes 1 open 0 rootLP 11814.4
  20 s reference: feasible(timeLimit) obj 11735 (exact check true) bound 11811.2 -> reported bound 11097 is invalid
```

Raw logs: /private/tmp/claude-501/-Users-admin--claude-spares-spare-zzrljs/7aab57cc-e0cf-4457-93b0-57da6847eb38/scratchpad/v103-{oracle,natural,cancel,deadline,big}.txt
