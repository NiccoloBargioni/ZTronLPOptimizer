# A4-03, sceptic verdict (lens: REPRODUCE)

- Finding: objectiveStep counts an integer column's cost of magnitude <= 1e-9 as an integral 0, so pruning by a whole objective step discards better solutions (reported optimal 1, true optimum 0.75).
- Verdict: **confirmed**
- Documented: **no**
- Severity: **critical** (`.optimal` returned with a wrong objective and a bound above the true optimum)
- Probe: `verification/probes/cycle-A/Slots/V097/main.swift`. I wrote it from scratch. The model is built with the public DSL (`LPModel` -> `compile()`), not `CompiledLP` by hand, and the oracle is my own; the finder's code was not reused.

## Reasoning

1. **The observed behaviour happens.** Model: min x1 + 1e-9 x2, x1 + (1e-9/1.5) x2 >= 0.5, x1 binary, x2 integer in [0, 1e9]. These all return `optimal obj 1 bound 1 x [1, 0] nodes 1`, 6 runs out of 6 in each of 3 separate process runs:
   - `BranchAndBound()` with 8 threads and with 1 thread;
   - `Simplex(.dual)` and `InteriorPoint()` node engines;
   - `deterministic: true` with seed 0 and with seed 987654321;
   - `Gap(relative: 0, absolute: 0)`;
   - `.strong` branching with `.bestBound`;
   - `.depthFirst` with no heuristics. Here the incumbent comes from the LP, not from rounding, so the rounding heuristic is not the cause.

   `Automatic()` on the DSL model picks `BranchAndBound<Simplex(.primal)>` and also returns `.optimal`, objective 1 (3 of 3 runs). Only configurations whose best-bound search visits the x1 = 0 child before any incumbent exists (no heuristics with `.pseudocost` or `.mostFractional`) return 0.75. That they get it right is a matter of search order.

2. **The expected optimum, 0.75, is correct.** I checked it four ways, none of which uses `maxViolation` or `objective(at:)`:
   - **By hand.** With x1 = 1, the best choice is x2 = 0, objective 1. With x1 = 0, the row needs a·x2 >= 0.5, where a = fl(1e-9/1.5) = 6.6666666666666674e-10.
   - **Exact arithmetic.** An FMA test of the product's sign shows that a·7.5e8 >= 0.5 holds (the activity is 0.50000000000000011) and that a·(7.5e8 - 1) >= 0.5 fails. So x2min = 7.5e8, the objective is 0.75, and the optimum is min(1, 0.75) = 0.75.
   - **Second engines.** On the subproblem with x1 fixed at 0 and x2 relaxed, dual simplex, primal simplex and the interior point all return 0.75 at x2 = 750000000. That value is integral, so it is also the integer optimum of that branch. With x1 fixed at 1, all three return 1. The root LP is 0.5 at (0.5, 0).
   - **What that means for the reported result.** The reported bound of 1 is above the true optimum, so it is invalid. The true gap is 0.25, 2500 times the README's `.optimal` slack of max(1e-6, 1e-4·max(1, |inc|)) = 1e-4.

3. **The mechanism is isolated, and neither load nor randomness explains it.**
   - **One-ulp contrast.** A sweep of c2 keeps the true optimum at about 0.75 by using row coefficient c2/1.5 and an ample upper bound. Every c2 <= 1e-9 gives the wrong answer: 1e-9, 9.99999e-10, 9e-10, 5e-10 and 1e-10. Every c2 > 1e-9 gives 0.75: nextUp(1e-9) = 1.0000000000000003e-9, 1.000001e-9, 1.1e-9, 1.5e-9, 2e-9 and 4e-9. The models at c2 = 1e-9 and at nextUp(1e-9) have the same LPs, root bound and rounding incumbent, and they flip from wrong to right. The only code that depends on c2 crossing 1e-9 in this way is the integrality test in `BranchAndBound.objectiveStep` (BranchAndBound.swift:395): `|scaled - rounded| <= 1e-9 * max(1, scaled)`. At scale 1 it rounds 1e-9 to 0 and returns step = gcd(1, 0) = 1. The cutoff `incumbent - step + 1e-9·max(1, |inc|)` (SearchTree.swift:314-316, TreeSearch.swift:85-86) is then 1e-9, so the x1 = 0 child, with bound 0.75, is pruned.
   - **The step-based cutoff ignores `gap`.** That is why `Gap(0, 0)` does not help.
   - **Contrasts that come out right.** With x2 continuous, the step is 0 and the result is correct at 0.75. With costs doubled to (2, 2e-9), it is correct at 1.5.
   - **A scaled variant that fails.** With the objective scaled to (1e-3, 1e-12), the step is found at scale 1000 and the result is still wrong: `.optimal` 0.001 against a true 0.00075. The error is 2.5e-4, more than the 1e-4 slack. So the trigger is "a cost <= 1e-9 at the first power-of-ten scale that makes the other costs integral", not just an absolute value of 1e-9.
   - **Neither load nor randomness explains it.** Every solve took 0.02 to 1.9 ms against a 30 s limit and ended `.optimal`, not stopped by a limit. The result is identical across thread counts, seeds, deterministic mode and 3 process runs.

4. **Not by design, and not documented.**
   - The README says `.optimal` for a MILP "means within the gap" (§2.5 and the §4 Results bullet).
   - `CompileOptions.dropTolerance` and `Tolerances.dropZero` are both 1e-14, so a 1e-9 cost is documented as kept. The compiled LP has `c = [1.0, 1e-09]` and no diagnostics.
   - Nothing in README §3, README §4 or HANDBOOK (Known gaps, Not verified) mentions objective-step pruning or tiny costs.
   - The existing unit test `SearchTreeTests.objectiveStepDetection` covers only costs that are clearly integral or clearly fractional.
   - The trigger is narrow: a tiny tie-breaking cost on an integer column with a wide range. That does not change the class of failure, which is a wrong value with a success status.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V097 -c release                      # Build complete
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V097 all   # exit 0, full log in scratchpad v097-run1.txt
```

```
PART0 exact oracle c2=1e-09 a=6.6666666666666674e-10: x1=0 needs x2 >= 750000000 (0.5/a = 749999999.99999988), branch0 obj 0.75; branch1 obj 1; optimum 0.75
PART0 exact: a*7.5e8 >= 0.5 ? true;  a*(7.5e8-1) >= 0.5 ? false; my activity at (0,7.5e8) = 0.50000000000000011, objective = 0.75
PART0 compiled: m 1 n 2 c [1.0, 1e-09] xl [0.0, 0.0] xu [1.0, 1000000000.0] rl [0.5] ru [inf] A.values [1.0, 6.666666666666667e-10] integer [0, 1] diagnostics []
PART1 x1=0 LP: dual optimal 0.75 x ["0", "750000000"] | primal optimal 0.75 | ipm optimal 0.75 x ["0", "750000000"]
PART1 x1=1 LP: dual optimal 1 x ["1", "0"] | primal optimal 1 | ipm optimal 1 x ["1", "0"]
PART1 root LP relaxation: optimal 0.5 x ["0.5", "0"]
PART2 default(8 threads) [6/6]: optimal obj 1 bound 1 x ["1", "0"] nodes 1 open 0 src ["rounding"] gap 0  <-- WRONG ... by 0.25 [bound > true optimum]
PART2 default threads=1: wrong 6/6;  dual-engine: wrong 6/6;  ipm-engine: wrong 6/6
PART2 deterministic seed0: wrong 6/6;  deterministic seed987654321: wrong 6/6;  exact gap 0/0: wrong 6/6
PART2 no heuristics, depthFirst: optimal obj 1 bound 1 ... src ["lp"]  wrong 6/6;  strong, bestBound: wrong 6/6
PART2 no heuristics: wrong 0/6 (obj 0.75);  no heuristics, mostFractional, primal / dual: wrong 0/6 (obj 0.75)
PART2 Automatic() on LPModel run 0..2: engine BranchAndBound<Simplex(.primal)> optimal obj 1 bound 1 x1 1 x2 0  <-- WRONG
PART3 c2=1.0000000000000003e-09 (nextUp 1e-9) default: optimal obj 0.75 x ["0", "750000000"] nodes 2
PART3 c2=1.0000000000000001e-09 (1e-9)        default: optimal obj 1 bound 1 x ["1", "0"] nodes 1  <-- WRONG
PART3 c2 in {4e-9, 2e-9, 1.5e-9, 1.1e-9, 1.000001e-9}: optimal ~0.75 (correct, within 1e-7 feasibility)
PART3 c2 in {9.99999e-10, 9e-10, 5e-10, 1e-10}: optimal obj 1 bound 1  <-- WRONG (default and deterministic)
PART4 x2 continuous, c2=1e-9: optimal obj 0.75 (correct)
PART4 costs doubled (2, 2e-9), same rows: optimal obj 1.5 (correct)
PART4 objective scaled 1e-3 (1e-3, 1e-12): optimal obj 0.001 bound 0.001  <-- WRONG (truth 0.00075, error 2.5e-4 > slack 1e-4)
```

I repeated the run twice more with `V097 bb` and once more with `V097 sweep`, and got identical outcomes: every wrong count stayed 6/6, the counts of 0/6 stayed 0/6, and the maximum solve time was 1.9 ms.
