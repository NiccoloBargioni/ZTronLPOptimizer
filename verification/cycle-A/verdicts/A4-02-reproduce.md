# A4-02, sceptic, REPRODUCE lens (cycle A)

- Finding: B&B heuristic incumbents are accepted by a feasibility test relative to the row bound, 1e-7·(1+|bound|).
- Verdict: **confirmed**
- Documented: **no**
- Severity: **critical** (.optimal with a point that is infeasible in exact arithmetic, and an objective that no feasible point reaches)
- Probe: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V094/main.swift (product V094, release build). It is written from the description, not from the finder's code.

## How this check differs from the finder's

- **Model construction.** I built every model with the public DSL (`LPModel`, `VariableDomain.integer(.range(...))`, `model.compile()`). The finder built `CompiledLP` by hand, with manual sign flips.
- **Oracles.** None of them uses the solver's own judgement:
  1. Exact Int64 arithmetic on the returned integer point. Values are read through `Solution.value(of:)`.
  2. Closed-form weak-duality LP bounds. For example, a+b = (3a+3b)/3 ≤ 29,999,999/3 holds for any point, integral or not. The package's `Simplex(.dual)` on `relaxed()` returns the same LP values.
  3. Brute-force enumeration on scaled-down copies, k = 1..333. All four families match their closed forms: 0 mismatches.
  4. A second engine: `CPSAT(deterministic: true)` on the pure-integer cases.
  5. Metamorphic equivalents: the same integer set written with the Chvátal–Gomory rounded row (a+b ≤ k−1, a+b ≥ k+1).
  6. Configurations without the rounding heuristic (diving only; `.none`).
- **Extra cases.** A natural covering variant (min a+b, 3a+3b ≥ 1e9) and a threshold sweep that tests the mechanism, not only one instance.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V094 -c release
perl -e 'alarm shift; exec @ARGV' 120  .build/release/V094 enum
perl -e 'alarm shift; exec @ARGV' 600  .build/release/V094 core
perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V094 sweep
perl -e 'alarm shift; exec @ARGV' 600  .build/release/V094 repeat 25
perl -e 'alarm shift; exec @ARGV' 200  .build/release/V094 extra
```
All runs exited 0, with no alarm. Every solve has timeLimit 30 s. Metal is off, except for `Automatic`, which runs with its defaults.

**enum:** `enumeration vs closed forms: mismatches=0`. The exact Int64 checks give:
- knapsack: 3·1e7 = 30,000,000 against a rhs of 29,999,999, a violation of 1;
- mixed: 2·10,000,000 = 20,000,000 < 20,000,001;
- big: 3·333,333,333 = 999,999,999 against 1,000,000,001, a violation of 2.

**core:** 8 B&B and Automatic configurations per case.

Knapsack, max a+b s.t. 3a+3b ≤ 29,999,999, a,b ∈ [0,1e7] integer. Truth is 9,999,999; the LP bound is 9,999,999.667.
```
BB() / BB(det) / BB(dual,det) / BB(ipm,det) / BB(gap0,det) / Automatic:
  optimal obj=10000000 bound=10000000 rootLP=9999999.667 nodes=1 src=["rounding"]
  | exact: viol=1 maxViolation.rows=1 BEYOND-LP-BOUND(9999999.667) => WRONG
CPSAT(det): optimal 9999999 viol=0
tightened equivalent a+b<=9999999: BB(), BB(det) -> optimal 9999999 viol=0 (src lp)
BB(noRounding,det), BB(none,det): noSolution(timeLimit) after ~29,600 nodes (honest status, not a wrong answer)
```

Mixed, min x s.t. 2x−z ≥ 20,000,001, z ∈ [0,0.5]. Truth is 10,000,001; the LP bound is 10,000,000.5.
```
same 6 configs: optimal obj=10000000 bound=10000000 src=["rounding"] exact viol=1 => WRONG
BB(noRounding,det): optimal 10000001 (src diving) ok;  BB(none,det): optimal 10000001 (src lp) ok
```

Big, min x s.t. 3x+y ≥ 1e9+1, y fixed 0. Truth is 333,333,334.
```
same 6 configs: optimal obj=333333333 src=["rounding"] exact viol=2 => WRONG
noRounding / none: optimal 333333334 ok
```

Covering (my own case), min a+b s.t. 3a+3b ≥ 1,000,000,000. Truth is 333,333,334; the LP bound is 333,333,333.33.
```
same 6 configs: optimal obj=333333333 src=["rounding"] exact viol=1 => WRONG
CPSAT(det): optimal 333333334 ok; tightened a+b>=333333334: BB() optimal 333333334 ok
```

**extra:** the finder's one passing configuration, `Simplex(.dual)` with `.mostFractional`, `heuristics: .none`, run in parallel:
- knapsack: optimal 9,999,999, violation 0;
- covering: optimal 333,333,334, violation 0.

**sweep:** the code predicts a wrong answer exactly when 1e-7·(1+|rhs|) ≥ 1. The rounded root point always violates the row by exactly 1.
```
knapsack k=3,333,333 rhs 9,999,998  tol 0.9999999 -> det/par optimal 3333332 ok
knapsack k=3,333,334 rhs 10,000,001 tol 1.0000002 -> det/par optimal 3333334 viol=1 WRONG
covering k=3,333,332 rhs 9,999,997  tol 0.9999998 -> det/par optimal 3333333 ok
covering k=3,333,333 rhs 10,000,000 tol 1.0000001 -> det/par optimal 3333333 viol=1 WRONG
(every k below the threshold: ok; every k above it, up to 1e8: WRONG)
```
The boundary sits exactly where the relative formula puts it, to 7 digits, in both families. An absolute 1e-7 test would never accept a violation of 1.

**repeat 25:** load average 5 to 9.
```
knapsack: 25x par-default, 25x par-2, 25x par-8, 25x det(random seed) -> optimal 10000000
mixed:    25x each                                                     -> optimal 10000000
```
That is 200 out of 200 solves wrong. The effect happens at the root node, before any parallel work, so it does not depend on load, threads or the seed.

## Reasoning

1. **The behaviour happens.**
   - The returned point violates an integer-data row by 1 or 2 in exact Int64 arithmetic.
   - The package's own `CompiledLP.maxViolation(at:)` reports rows = 1 or 2. README risk 1 recommends exactly this check; the values are 1e7 times the documented `primalFeasibility` of 1e-7.
   - The status is `.optimal`. The reported objective lies strictly beyond the LP relaxation bound that the package itself computes (rootLP), and no feasible point, integral or not, can do that.
   - The reported `bound` equals that impossible value, so it is invalid too.
   - Every wrong incumbent has the source "rounding". The search stops after 1 node: the cutoff with objectiveStep 1 (TreeSearch.swift:85-86) prunes the root at expand line 214.
2. **The expected values are correct.** Five independent routes agree: closed form by weak duality and integrality, enumeration on scaled copies, CP-SAT, the CG-tightened equivalent models, and the configurations without rounding.
3. **Not load or randomness.** 200 of 200 repeats were wrong, deterministic and parallel alike. The sweep threshold matches the formula exactly.
4. **Code reading agrees.**
   - TreeSearch.swift:325-340 accepts s ≥ rl − 1e-7·(1+|rl|).
   - roundingHeuristic uses that test (consider, 363-366) and then offers the point (417-418). The dive uses the same test at 448.
   - BranchAndBound.swift:198 hard-codes `Tolerances.default`, and BranchAndBound has no tolerance parameter, so the user cannot tighten it.
5. **Refutation attempts that fail.**
   - **"Within a documented tolerance":** fails. None of the three documents states a relative test:
     - README §2.3 says only `primalFeasibility` 1e-7;
     - README §4 "Results" says "feasible … to 1e-7";
     - the `Tolerances` doc comment says "Bound/row violation allowed, after scaling", and B&B does not scale at all;
     - HANDBOOK item 16 says "no bound … is violated by more than 1e-7";
     - the package's own oracles are absolute: BranchAndBoundTests.swift:60-65 uses rows ≤ 1e-6 and CorpusTests.swift:139-140 uses rows ≤ 1e-5.
   - **"Within the gap":** fails. README risk 10 says to pass a tighter `Gap` when the exact optimum matters, and `Gap(relative: 0, absolute: 0)` still returns 10,000,000. The incumbent is not suboptimal within the gap; it is infeasible and super-optimal.
   - **API misuse:** fails. The models use only the public DSL and default strategies.
   - **Wrong oracle:** fails, because five independent routes agree.
   - **Load:** fails, because the effect is deterministic.
6. **Minor notes, which do not change the verdict.**
   - The finder's sub-claim "heuristics: .none -> 9,999,999" holds for the configuration it names (dual, mostFractional, parallel).
   - With primal plus pseudocost and deterministic, `.none` instead stops with noSolution(timeLimit) at 30 s for k ≥ 1e5. So turning the heuristics off is not a dependable workaround on this family.
