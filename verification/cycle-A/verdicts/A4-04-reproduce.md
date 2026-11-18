# A4-04, REPRODUCE lens (cycle A, sceptic slot V100)

- **Verdict:** confirmed
- **Documented:** no
- **Severity:** high. The status is honoured: in every run the incumbent stayed inside the gap. What is false is the bound and the gap, the package's certificate of quality. At the default gap the error is under 1e-4 relative (the largest seen was 1.8e-5). It becomes large with a loose `Gap`, a documented knob, and with `nodeLimit`, where README risk 3 tells users to read `bound` and `gap`.

## What I did (independent of the finder's probe and oracle)

- **Own probe** in `verification/probes/cycle-A/Slots/V100/main.swift`. Models are built with the public DSL (`LPModel<Item>`, binary `Item.take(j)`), not with `CompiledLP` by hand.
- **Oracles:**
  1. a hand derivation;
  2. my own brute-force enumeration over all 2^n points, with integer weights so feasibility is exact;
  3. zero-gap branch and bound, `Gap(relative: 0, absolute: 0)`, deterministic;
  4. `CPSAT(deterministic: true)` on the unscaled hand instance;
  5. a direct check of the better point against the data.
- **Context:** `timeLimit` 30 s and `metal = .off`. Every binary ran under a perl alarm.

## 1. Hand-derived instance (decisive)

The instance is a 6-item knapsack with capacity 82:

| Item | Weight | Profit |
|---|---|---|
| A | 50 | 55.0 |
| B | 30 | 32.7 |
| C | 8 | 8.64 |
| D | 7 | 7.42 |
| E | 5 | 5.2 |
| F | 2 | 2.0 |

The profit/weight ratios fall strictly: 1.10, 1.09, 1.08, 1.06, 1.04, 1.00. Every profit is multiplied by φ = π/3. No power of 10 up to 1e6 then makes the profits integral, so `objectiveStep` is 0 and pruning is done against the gap.

**By hand:**
- LP bound: A, B and 2/8 of C, giving 89.86φ = 94.101171951.
- Root rounding: C goes to 0, leaving A+B = 87.70φ = 91.839225240.
- The dive fixes C = 0. The LP is then 89.82φ, which is above the 5 % cutoff, so the dive stops.
- The root LP, 94.10, is within 5 % of 91.84, so the root is pruned in `expand` (TreeSearch.swift:214). That pruning is not recorded in `prunedBound`.
- The pool is empty, so the tree closes `.complete`, and BranchAndBound.swift:351 sets bound = incumbent.

**True optimum:** A+B+F, weight 82, 89.70φ = 93.933620342. The hand derivation, the enumeration and zero-gap branch and bound all agree. CP-SAT on the unscaled instance gives 89.7, and a positive scale does not change the best point.

Command:

```
swift build --product V100 -c release
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V100 hand
```

Key output. Each configuration was run 5 times and the 5 results were identical every time ("distinct=1"):

```
== hand(scale 1.0471975511965976): enumeration optimum 93.933620342 at x=[1, 1, 0, 0, 0, 1] (direct check: feasible true, value 93.933620342)
   BB exact gap 0: optimal obj 93.933620342 bound 93.933620342 gap 0.000e+00 nodes 3
   [P rel0.05 t8]  optimal obj 91.839225240 bound 91.839225240 gap 0.000e+00 nodes 1 ; boundValid false; trueRelGap 2.281e-02 vs reported gap 0
   [P rel0.05 t1]  same
   [P rel0.05 default-ctx-threads] same
   [D-det rel0.05] same  (BranchAndBound(engine: Simplex(.dual), deterministic: true))
   [P rel0.05 bestBound mostFrac] same
   [P rel0.05 no-diving] same
   [P rel0.05 nodeLimit1] feasible(stoppedBy: nodeLimit) obj 91.839225240 bound 91.839225240 gap 0 ; boundValid false
   [P rel0.03] same as rel0.05 (bound invalid, gap 0)
   [P rel0.02] / [P default gap] optimal obj 93.933620342 (incumbent happens to be optimal; bound valid)
```

**Control: the same instance unscaled.** Here `objectiveStep` = 0.02, so pruning uses the step and not the gap. The reported bounds are honest:

```
   CPSAT(deterministic) unscaled: optimal obj 89.700000000 bound 89.700000000
   [P rel0.05 t8]        optimal obj 89.700000000 bound 89.820000000 gap 1.338e-03   boundValid true
   [P rel0.05 no-diving] optimal obj 87.700000000 bound 89.820000000 gap 2.417e-02   boundValid true (>= true gap 2.281e-02)
```

The two runs differ only by a positive scale. With the same 2.28 %-suboptimal incumbent, one reports gap 2.4e-2 with a valid bound; the other reports gap 0 with a bound below a feasible solution. The point [1,1,0,0,0,1] has weight 82 ≤ 82 and value 93.93, which is more than the reported bound of 91.84.

## 2. Own random near-tie families

Each family has 15 binaries and 30 seeds, built with a SplitMix64 generator:

- **Maximize:** two rows, profit = e·w1 + U(0, 0.004).
- **Minimize:** covering, cost = √2·w + U(0, 0.004).

Commands:

```
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V100 family 30 1e-4   (run twice)
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V100 minfam 30 1e-4
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V100 family 30 1e-2
```

Results:

```
SUMMARY max rel=0.0001 [P-t8]  runs=30 suboptimalWithinGap=14 (run 2: 16) outsideGap=0 invalidBound=14 (16) worstBoundExcess 5.056e-06
SUMMARY max rel=0.0001 [P-det] runs=30 suboptimalWithinGap=29 outsideGap=0 invalidBound=29 worst 1.291e-05   (identical in both runs)
SUMMARY max rel=0.0001 [D-det] runs=30 suboptimalWithinGap=29 outsideGap=0 invalidBound=29 worst 1.291e-05   (identical in both runs)
SUMMARY min rel=0.0001 [P-t8]  invalidBound=16; [P-det] 28; [D-det] 28; worst 1.821e-05
SUMMARY max rel=0.01   [P-t8]  suboptimalWithinGap=24 invalidBound=8 worst 9.866e-03; [P-det]/[D-det] 29 / 3, worst 9.867e-03
SUMMARY zero-gap BB disagreements with enumeration: 0 of 30 (each family)
```

Sample lines:

```
max seed 0 [P-det]: optimal obj 1223.243453226 bound 1223.243453226 gap 0 nodes 12529 | enumerated opt 1223.248102869 zero-gap BB 1223.248102869 -> INVALID BOUND
min seed 2 [P-det]: optimal obj 579.846497529 bound 579.846497529 gap 0 nodes 13776 | enumerated opt 579.838851019 -> INVALID BOUND
max seed 3 [P-det] rel 1e-2: optimal obj 1130.826044055 bound 1130.826044055 gap 0 nodes 1 | enumerated opt 1136.260927109 (true gap 4.8e-3) -> INVALID BOUND
```

## Reasoning

1. **The behaviour happens.** In the hand instance and in both families, when `objectiveStep` is 0, the run returns `.optimal` (or `.feasible(nodeLimit)`) with bound = incumbent and gap = 0, while a feasible solution better than that bound exists. The failure was verified against the data directly. Both mechanisms the finder names are visible in the code:
   - TreeSearch.swift:139, 177 and 214 prune inside the worker without recording `prunedBound`.
   - BranchAndBound.swift:350-352 overwrites the bound with the incumbent on `.complete`.

   The hand trace follows exactly the path the code reading predicts.
2. **The expected behaviour is right.** A proven bound for a maximization must be at least the optimum, and the reported gap must be at least the true gap. The documents and the code all say so:
   - Analysis.swift:22 says "Proven bound".
   - BranchAndBoundAnalysis describes "proven bound" and the gap between incumbent and bound.
   - README line 38 says "a proven bound". README risk 3 says to read `bound` and `gap` to know how far the incumbent may be. README risk 10 gives ".optimal" with incumbent 1,000 and bound 999.95, so bound ≠ objective is allowed.
   - The package's own test (BranchAndBoundTests.swift:259-260) asserts "The reported bound really bounds the true optimum" for a loose gap. That test uses `randomMILP` with integral data, so `objectiveStep` > 0 and it cannot reach this path.
   - The `.gapReached` path itself returns `.optimal` with bound ≠ objective: in the unscaled control, and in 26 of the 29 suboptimal deterministic runs at gap 1e-2.

   So "equals `objectiveValue` when optimal" in the protocol comment does not make bound = incumbent the intended MIP behaviour. A bound below a feasible solution is invalid under any reading.
3. **Not load or randomness dependent.** The hand case runs only the root (1 node). It gave the same result 5 times out of 5 with 1 thread, 8 threads, default threads and `deterministic: true`. The deterministic family counts were identical across two separate runs (29/30, worst excess 1.291e-05). Only the parallel counts varied (14 and 16), as expected.
4. **Scope and magnitude.** The `.optimal` status itself is honoured: outsideGap = 0 everywhere. The error in the bound is limited to the slack, so it is at most 1e-4 relative at the default gap. With a loose user gap the error reaches almost the whole gap: 2.28 % hidden at 5 %, 0.99 % at 1 %. With `nodeLimit` the `.feasible` result reports gap 0 for a 2.28 %-suboptimal incumbent. That is the case README risk 3 covers, and it comes from the unrecorded prune inside the worker.
5. **Documentation.** README §4 and the HANDBOOK known gaps and not-verified sections say nothing about it. The finder's numbers (3 % at 5 %, 35 of 60 at the default gap) are for its own instances. I did not reproduce them; my own instances show the same effect with the figures above.
