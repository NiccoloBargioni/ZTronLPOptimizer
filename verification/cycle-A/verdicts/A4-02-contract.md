# A4-02, contract-lens sceptic (cycle A)

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** critical (my own rating; it matches the finder's)

## What the package promises
- `Tolerances.primalFeasibility` (Sources/ZTronLPCore/Solve/Strategy.swift:9-10): "Bound/row violation allowed, after scaling." Value 1e-7. It does not say the tolerance is relative to the size of the bound.
- README §2.3: `primalFeasibility` 1e-7. README §4 Limits, Results: "feasible and dual feasible to 1e-7 (and, after the simplex's refinement pass, to about 1e-10 ...)". This is the simplex's measure: absolute, in the scaled problem. The same section says `.optimal` for a MILP means within the gap.
- `SolveStatus.optimal` doc (Status.swift:5): "An optimal solution was found and proven (within the gap, for MILP)."
- HANDBOOK decision 16: "Optimal" means "no bound ... is violated by more than 1e-7". The wording is absolute.
- README risk 1 names `CompiledLP.maxViolation(at:)` as the way to check a point. It measures absolute violation in the model's own units. The package's tests use the same measure: BranchAndBoundTests.swift:60-65 accepts rows <= 1e-6, CorpusTests.swift:139-140 accepts rows <= 1e-5.
- The gap (README risk 10, `Gap`) limits how far a *feasible* incumbent may be from the optimum. It can never make an objective better than the optimum acceptable.
- No README defect, HANDBOOK known gap or doc comment mentions a feasibility test relative to the row bound. SPEC-v0.2 P1 ("tolerance scaled by the row's magnitude") is planned presolve work and is not implemented.
- `BranchAndBound` always uses `Tolerances.default` (BranchAndBound.swift:198, 294). The user cannot tighten the tolerance.

## Code reading
TreeSearch.isFeasible (TreeSearch.swift:325-340) accepts row activity s when s <= ru + 1e-7·(1+|ru|). It works in original units, not "after scaling". For ru = 29,999,999 the allowance is 3.0. roundingHeuristic (348-419) offers the nearest, floor and ceiling roundings through this test.

Here the accepted incumbent's objective is better than the root LP relaxation bound itself (1e7 against 9,999,999.667). The cutoff (TreeSearch.swift:83-89, SearchTree.swift:311-318) therefore prunes everything at the root, even with Gap(0,0). `provenBound` is clamped to "never above the incumbent" (SearchTree.swift:400-406), so the reported bound equals the infeasible incumbent. The finder's mechanism ("objectiveStep pruning") is consistent, but objectiveStep is not needed.

The dive path (line 448) rounds only columns that are already within 1e-6 of an integer, so it is far less exposed. Diving-only runs below were exact. The rounding heuristic is the operative path.

## Commands and key output
Own probe, slot V095. The models are built with the public DSL, not the finder's CompiledLP helper. Raw output is in A4-02-contract-V095-{main,threshold,scaled}.txt next to this file.

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build --product V095 -c release
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V095 main        # exit 0
```
- knapsack: max x1+x2 s.t. 3x1+3x2 <= 29,999,999, x integer in [0,1e7]; exact optimum 9,999,999.
  - BnB(), BnB(det), BnB(dual), BnB(gap 0), BnB(rounding only), Automatic(), Conditioned(Automatic()), Portfolio([BnB(),CPSAT()]): all `optimal obj=10000000 bound=10000000`, absRowViol=1 (relative 3.33e-08), x=[1e7,0], rootLP=9999999.667, nodes=1, hist=[rounding@10000000], warnings=[].
  - BnB(heur none) and BnB(diving only): optimal 9,999,999, violation 0. CPSAT(): optimal 9,999,999.
  - Same result without the column upper bounds. CPSAT then throws unsupported, and Portfolio returns B&B's 10,000,000.
- production: max 7x+5y s.t. 3x+2y <= 20,000,001, x,y integer >= 0; optimum 50,000,002 by full enumeration over x.
  - All configurations with the rounding heuristic, the facades included: `optimal obj=50000005`, x=[0,10000001], absRowViol=1, rootLP=50000002.5.
  - heur none and diving only: 50,000,002 at x=[1,9999999].
- mixed: min x s.t. 2x - z >= 20,000,001, z continuous in [0,0.5], x integer >= 0; optimum 10,000,001.
  - Automatic(), Conditioned(Automatic()) and every B&B with rounding: `optimal obj=10000000`, absRowViol=1, rootLP=10000000.5.
  - heur none and diving only: 10,000,001.

```
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V095 threshold   # knapsack 3x1+3x2 <= 3N-1, BnB(deterministic: true)
```
The wrong answer starts exactly where 1e-7·(1+|ru|) reaches the unit violation (3N >= 1e7, so N >= 3.33e6):

| N | Result |
|---|---|
| 10, 1e3, 1e5, 1e6, 3e6, 3.3e6 | EXACT; at 3.3e6 the allowance is 0.99 |
| 3.4e6 | 3,400,000, SUPEROPTIMAL by 1; allowance 1.02 |
| 4e6, 1e7, 1e8 | SUPEROPTIMAL by 1 |

Side note (info, not part of A4-02): `BranchAndBound(heuristics: .none, deterministic: true)` returns noSolution(timeLimit) after about 40k nodes in 60 s for N >= 1e5. Depth-first search without heuristics is therefore not a practical workaround.

```
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V095 scaled      # Scaler.factors(for:mode:) on the same lp
```
The package's own scaling gives the integer columns factor 1 and the row factor 0.25 (knapsack, production) or 0.5 (mixed). The scaled row violation of the returned point is therefore 0.25 to 0.5, which is 2.5e6 to 5e6 times the documented 1e-7 "after scaling".

## Reasoning
**Not a misuse.** These are valid, small models with integer data, all values exactly representable in double. The default facade `Automatic` routes them to BranchAndBound, and `Conditioned` gives no warning.

**Not inside a documented tolerance.** The point fails every measure the package documents or uses:
- after scaling: 0.25 to 0.5 against 1e-7;
- `maxViolation`, the checker the README names: 1.0;
- the package's own test oracle: more than 1e-6.

Only the undocumented bound-relative measure inside isFeasible accepts it.

**Not covered by the gap.** The gap limits the suboptimality of a feasible incumbent. Here the incumbent is infeasible, and its objective is better than the optimum and better than the root LP relaxation bound. Gap(0,0) gives the same answer.

**Not documented.** No defect, known gap, limit or doc comment mentions it.

**Severity.** The result is `.optimal` with an infeasible point and an objective no feasible point attains, through the default facade and with no warning. That is critical on the given scale.

**Mitigations.**
- The violation is at most 1e-7 of the row bound, and the objective error is about 1e-7 relative.
- `maxViolation` (README risk 1 advice) exposes it.
- CPSAT solves bounded pure integer cases correctly.
- `heuristics: .none` avoids it.

**Minor corrections to the finding.**
- The pruning does not depend on objectiveStep: the incumbent beats the root LP bound.
- The dive (line 448) is barely exposed. The rounding heuristic is the cause.
