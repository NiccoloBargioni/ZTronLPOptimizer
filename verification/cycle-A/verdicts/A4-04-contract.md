# A4-04, contract lens: verdict

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** high (the finder also said high; I rated it on my own)
- **Sceptic:** cycle A, slot V101, contract lens

## What the package promises

- README §1, "What comes out": "the objective value, a proven bound, ...".
- `SolutionAnalysis.bound` (Sources/ZTronLPCore/Solve/Analysis.swift:22): "Proven bound; equals `objectiveValue` when optimal."
- `BranchAndBoundAnalysis.base` (BranchAndBound.swift:93-95): "MIP status, incumbent objective, proven bound." `gap`: "The relative gap between incumbent and bound".
- README §3 risk 3: "read `bound` and `BranchAndBoundAnalysis.gap` to know how far the incumbent may be from the optimum".
- README §3 risk 10: "`.optimal` means incumbent − bound ≤ max(1e-6, 1e-4·max(1, abs(incumbent))) ... so an incumbent of 1,000 with a bound of 999.95 is optimal." So for a MILP, an `.optimal` result is expected to carry a bound different from the incumbent.
- `SolveStatus.optimal`, README §2.5 and §4 "Limits by design", HANDBOOK decision 8: `.optimal` for a MILP means within the gap. This covers the **status and the incumbent**. It says nothing that lets the **bound** be wrong.
- The package's own test `aLooseGapStopsEarlyAndReportsIt` (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:252-261) asserts the contract outright on an `.optimal` result with `Gap(relative: 0.2)`. Its comment reads "The reported bound really bounds the true optimum (a maximization: bound ≥ optimum)". Its instance, `randomMILP(... integralData: true)`, has integral profits, so `objectiveStep` is 1 and the test cannot reach this path.
- SearchTree.swift:171-173 says of `prunedBound`: "the proven bound can never exceed it." The design meant to keep the bounds of pruned nodes.

**The "equals objectiveValue when optimal" defence fails.** For a MILP solved within a gap, the two halves of that doc comment cannot both hold. The engine itself does not follow the second half. On `.gapReached` it reports the real `provenBound`, which differs from the objective. On `.complete` it overwrites the bound with the incumbent. Three things outrank the generic protocol comment for MILPs: the README's MILP-specific text (risk 10, risk 3), `BranchAndBoundAnalysis`'s "proven bound", and the package's own test. None of README §4 (defects, limits by design, not verified) or HANDBOOK (decisions, known gaps, not verified) mentions that the bound or gap can collapse to the incumbent.

**Not misuse.** `Gap(relative:absolute:)` is a public, documented parameter. A continuous column with an objective cost is an ordinary MILP. A hand-built `CompiledLP` is a documented input.

**Not within tolerance.** No tolerance is documented for the bound. With `Gap(0.05)` the reported gap is 0 while the true gap is 2.9 %.

## Causal story: checked by reading the code

1. Pruning works like this when `objectiveStep == 0`:
   - The cutoff is incumbent − slack (SearchTree.swift:312-318; TreeSearch.swift:84-90).
   - Pruned nodes can therefore hold solutions in [incumbent − slack, incumbent).
   - When `objectiveStep > 0`, the cutoff is incumbent − step + ε instead, so pruning is exact.
2. Nodes pruned by workers return no children, and their bound is recorded nowhere:
   - `process()`: TreeSearch.swift:139 (node.bound ≥ cut), :154 (`.cutoff`), :177.
   - `expand()`: :214.
   - Only prunes in the tree's own `push`/`pop`/`removeBestBound` update `prunedBound` (SearchTree.swift:339-340, 357-359, 376-377).
3. When the pool empties, the tree closes `.complete` (SearchTree.swift:202-203, 299-300). BranchAndBound.swift:350-352 then sets `boundValue = incumbent.objective`, and the gap is computed from that bound, so it is 0. `.gapReached` (BranchAndBound.swift:353-354) keeps `provenBound`.
4. This line dates from v1.0 (`git blame`: d13d602) and has no comment that justifies it.

Removing line 352 alone would not fix it. In the 1-node cases below, the root is pruned in `expand()` at :214. Its LP bound is lost, so `provenBound` is already min(∞, incumbent), which is the incumbent.

## Commands run and key output

Probe: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V101/main.swift. It has its own instances and its own brute-force oracle, and every solve sets timeLimit 30 s.

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V101 -c release                      # Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V101 tiny      # exit 0
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V101 neartie   # exit 0
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V101 count     # exit 0
```

### Hand-made instance

The instance is a knapsack with weights A 10, B 10, C 11 and capacity 21:

- The root LP takes A, B and 1/11 of C.
- Rounding gives A+B.
- The optimum is A+C.

**(1) Non-decimal profits 10.5/10.4/11.0 + 1e-7·√k, so `objectiveStep` = 0.** Enumerated optimum 21.5000004.

```
Gap(0.05) P default: optimal obj 20.9000003 bound 20.9000003 gap 0 | trueRelGap 2.871e-02 boundValid false nodes 1 hist [rounding@0]
           P 1 thread / D det / IPM / mostFractional+bestBound+rounding-only: identical (bound 20.9000003, gap 0, boundValid false)
Gap(0.03)  same on 5 of 6 configs (true gap 2.87 % < 3 %: status fine, bound and gap wrong)
Gap(0.01)  every config finds 21.5000004: bound valid
```

**(2) Integral profits 105/104/110 plus one continuous column y ∈ [0,1] with profit 0.5 and no row entries.** This is an ordinary MILP. Enumerated optimum 215.5.

```
Gap(0.05) P default: optimal obj 209.5 bound 209.5 gap 0 | trueRelGap 2.864e-02 boundValid false nodes 1
           P 1 thread / D det / IPM / rounding-only: identical
```

**(3) Control: the same integral profits without the continuous column, so `objectiveStep` = 1.** Optimum 215.

```
Gap(0.05) P default: optimal obj 209 bound 215 gap 0.028708134 | boundValid true nodes 1 open 1   (.gapReached path)
           mostFractional/bestBound: optimal obj 209 bound 219 gap 0.0478 | boundValid true
```

Adding one constant continuous objective term (+0.5) turns a correct "bound 215, gap 2.9 %" into a wrong "bound 209.5, gap 0". The incumbent's quality is unchanged. The `.optimal` status is right both times.

### Finder's near-tie family

I re-implemented the generator and used my own oracle. Seed 15 has optimum 3670.05062.

```
Gap(0.05) P/P1/D-det/IPM/rounding-only: optimal obj 3560.05953 bound 3560.05953 gap 0 nodes 1 boundValid false   (finder's numbers reproduced exactly)
Gap(0.05) heuristics .none: optimal obj 3560.05953 bound 3675.05862 gap 0.0323 nodes 40 open 25 boundValid true (.gapReached: same incumbent, honest bound)
Gap(1e-4) P default: optimal obj 3670.04579 bound 3670.04579 gap 0 boundValid false (finder's default case reproduced exactly)
          D det: obj = bound = 3670.02891 boundValid false
```

### Default gap over 30 seeds

Configurations: `BranchAndBound()` with automatic threads and with 1 thread.

```
COUNT default gap: runs 60 boundBelowOptimum 25 (with gap==0: 25) incumbentOutsideGap 0
```

The finder reported 35/60 with a different pair of configurations (P and D-det). The count depends on the configuration. The effect itself reproduced: every bad bound comes with gap 0, and no incumbent falls outside the gap.

Baseline: `aLooseGapStopsEarlyAndReportsIt` passed in verification/baseline/03-test-debug.log. It cannot reach this path because its costs are integral.

## Reasoning for the severity

The status and the incumbent stay within the documented contract (`.optimal` = within the gap), so this is not critical.

The `bound` and `gap` fields of a success status are another matter. The package publishes them as "a proven bound" and as the measure of "how far the incumbent may be from the optimum". On this path they are materially false: the bound is below the optimum of a maximisation, and the gap is reported as 0 when the true gap is 2.9 %.

It is not an exotic edge case:

- It needs only `objectiveStep == 0`. Any MILP with a continuous column in the objective, or with costs that are not short decimals, has that.
- It needs a search that ends `.complete` after pruning inside the gap's slack.
- It is deterministic and engine-independent (primal, dual and IPM, 1 and 8 workers), and it shows up on a model with 3 binaries and 1 continuous column.

With the default gap the error is at most 1e-4 relative. With a user's loose gap it is as large as the whole gap. That loose-gap case is exactly where risk 3 tells users to rely on `bound` and `gap`.

On the scale, "a published claim that is materially false" is high.
