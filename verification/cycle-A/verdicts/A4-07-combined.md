# A4-07 — sceptic verdict (lens: reproduce and contract)

- **Verdict:** confirmed
- **Documented:** false. Only the internal comment at `Sources/ZTronLPBranchAndBound/TreeSearch.swift:596` mentions it, and that comment says "count the cap's worth at most" while the formula counts a quarter of the cap's worth. README §2 (BranchAndBoundAnalysis row), §4, §5, the HANDBOOK and the public doc comments never say that `lpIterations` contains an estimate. README §5 heads the column "LP pivots", and HANDBOOK:203 calls the same numbers "LP iterations".
- **Severity (independent):** medium. The finder rated it low.

## What the code does

`TreeSearch.runProbes` returns `candidates.count * 2 * limit / 4` as its iteration count on both
paths (inline at :597, task group at :637). With `probeIterationLimit` = 50 this is 25 per
strong-branched candidate, whatever the probes did. `chooseBranch` adds that to the node's
iterations (:511), and `SearchTree` sums them into `lpIterations`. `NodeLPStrategy.probe` returns only
`Double?`, so the tree has no access to the real count. `Sources/ZTronLPBenchmarks/main.swift:150-154`
prints `lpIterations` and the P/D ratio. Those numbers are the README §5 "LP pivots" column and the
"0.60 to 1.65 times" claim.

## Independent oracle

Probe: `/Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V109/main.swift`.
`CountingSimplex` is a public `NodeLPStrategy` wrapper. It passes every call to `Simplex` unchanged
and records the real pivots of every root, node, dive and probe run. A probe's pivots come from the
engine's analysis of its last run (`Simplex.rootAnalysis(_:worker:)` describes `worker.lastOutcome`,
which `SimplexEngine.run` resets and sets on every run: Driver.swift:432, :800). This method differs
from the finder's, which compared branching rules and a separate root solve. For the tiny model it
is also checked by hand. Root LP x = 0.5. Down probe: x leaves, ratios y 0.8 and slack 1.0, so y
enters (1 pivot). Up probe: nothing can enter, so it is infeasible after 0 pivots.

Sanity check that the wrapper does not change the search: plain `Simplex` with deterministic
search gives the same nodes and lpIterations as the wrapped runs.

    .build/release/V109 plain p0033 egout misc03
    p0033 plain det: P nodes 1605 lpIterations 11840 | D nodes 1993 lpIterations 8777   (wrapped: same)
    egout plain det: P nodes 7817 lpIterations 82952 | D nodes 7684 lpIterations 56573  (wrapped: same)
    misc03 plain det: P nodes 1293 lpIterations 47495 | D nodes 1169 lpIterations 34254 (wrapped: same)

## Commands and key output

    cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
    swift build --product V109 -c release
    perl -e 'alarm shift; exec @ARGV' 120 .build/release/V109 tiny

    mostFractional P: nodes 3 | reported 3  | real root 1 + nodes 2 + probes 0 = 3
    mostFractional D: nodes 3 | reported 2  | real 2
    strong(1) P:      nodes 2 | reported 28 | real root 1 + nodes 2 + probes 1 (runs: 0 and 1 pivots) = 4 | real nodes + 25x1 = 28
    strong(1) D:      nodes 2 | reported 27 | real 3 | formula 27
    pseudocost(4) P:  nodes 2 | reported 28 | real 4 | formula 28
    pseudocost(4) D:  nodes 2 | reported 27 | real 3 | formula 27

    perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V109 miplib det p0033 flugpl enigma mod008 stein27 misc03 p0201 egout lseu
    reported - (real root+node pivots + 25 x candidates) = 0 on all 18 runs
    estimate share of reported 9.7 % .. 82.8 %; reported/real 0.806 (misc03 D) .. 4.217 (egout D)
    P/D ratio reported vs real: egout 1.47 vs 3.01, lseu 2.72 vs 3.13, misc03 1.39 vs 1.23, p0033 1.35 vs 1.27

    perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V109 miplib par p0033 stein27 enigma lseu mod008 flugpl egout misc03 p0201
    (benchmark configuration: default BranchAndBound, parallel, both engines)
    p0033 D  rep 6690   real 1841   cand 224 x25 = 5600   probes really 751    est share 83.7 %  rep/real 3.634
    egout P  rep 67219  real 31639  cand 1532 x25 = 38300 probes really 2720   est share 57.0 %  rep/real 2.125
    egout D  rep 40661  real 10097  cand 1320 x25 = 33000 probes really 2436   est share 81.2 %  rep/real 4.027
    misc03 D rep 27630  real 32381  cand 786 x25 = 19650  probes really 24401 (92 runs at the 50 cap)  rep/real 0.853
    lseu P   rep 122782 real 115467 est share 8.0 %  rep/real 1.063
    reported - formula: 0 on 17 of 18 runs, -49 on enigma P (work abandoned when the parallel search closed)
    egout ratio P/D: reported 1.65, real 3.13;  p0033: 1.23 vs 1.69;  RATIO RANGE reported 0.74-1.83, real 0.77-3.13
    SUM P reported 417858 vs real 358653; SUM D reported 337602 vs real 278466

My parallel egout run (P 6221 nodes / 67219, D 5645 / 40661) is close to the published row
(5784 / 60903 and 5602 / 41026). By the same mechanism, about 80 % of the published dual
figure would be the constant, and the real egout ratio is about 3.0 to 3.1 in both of my runs,
against the published 1.48.

## Reasoning against the contract

- The defect is real and exact. In deterministic mode the reported value equals the real
  root/node/dive pivots plus 25 per probed candidate on every run. On a typical instance the
  real probe pivots per candidate are 1.8 to 32. Probes also reach the 50 cap (enigma, misc03,
  p0201). So 25 per candidate is neither a count nor an upper bound, and the number it gives is
  too high on egout and p0033 and too low on misc03.
- No refutation holds. The oracle is direct instrumentation, it does not change the search, and
  it agrees with a hand derivation. The configuration is the benchmark's own, not a misuse. No
  tolerance for pivot counts is documented. The estimate is deliberate in the code, but the
  public documents present the numbers as pivots or iterations, so the claim is still false.
- README §5 "LP pivots" column: false as a description. In the benchmark configuration the
  constant makes up 8 % to 84 % of each number.
- "0.60 to 1.65 times the LP pivots" (README §5, HANDBOOK:203, BranchAndBound doc comment):
  measured on real pivots, egout's ratio is about 3.1, not about 1.5. Adding the same constant
  to both engines pulls every ratio towards 1.
- "LP pivots summed over the set within 1 %" (How current): not shown false. Both runs being
  compared contain the constant, so it only dilutes the relative difference.
- Severity is medium, not low. The public statistic `lpIterations` behaves misleadingly. For
  example, comparing branching rules by it gives 3 vs 28 on the tiny model where the real counts
  are 3 vs 4. The published pivot numbers are off by up to 4× and one engine ratio by about 2×,
  which is not a minor mismatch. It is not high: no answer, status, limit or acceptance criterion
  is affected (the branch-and-bound acceptance is about time), and the seconds columns are right.
