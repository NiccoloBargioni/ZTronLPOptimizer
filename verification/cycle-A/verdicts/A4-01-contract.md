# A4-01: contract-lens sceptic verdict (cycle A)

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** critical. Under `.optimal` the returned primal violates a row by 0.5 (or 5), far outside every tolerance the package states.
- **Package state:** git main @ d9afebe. My probe is slot V092 (`verification/probes/cycle-A/Slots/V092/main.swift`). It builds every model through the public DSL and uses none of the finder's helpers.

## What the package promises

- README §4, Limits, Results: "'Optimal' is a statement about tolerances, not about the point: feasible and dual feasible to 1e-7 … `.optimal` for a MILP means within the gap". So the gap clause qualifies the objective, but the point must still be feasible.
- `SolveStatus.optimal` (Status.swift) says "An optimal solution was found and proven (within the gap, for MILP)". `hasSolution` says "True when a primal solution accompanies the status".
- `SearchTree.offerIncumbent` (SearchTree.swift:466) has the doc comment "Offers a feasible integral solution". The search's own `isFeasible` (TreeSearch.swift:325) allows a row violation of `1e-7·(1+|bound|)`. The rounding heuristic (line 364) and the dive (line 448) both apply it before they offer a point.
- The `SolutionAnalysis` conventions (Analysis.swift) say that values are unscaled and refer to the problem as given.
- `Tolerances.primalFeasibility` is 1e-7, "after scaling". `Tolerances.integrality` is 1e-6, "distance from an integer that counts as integral".
- The package's own test oracle, `isIntegralAndFeasible` (BranchAndBoundTests.swift:60-65), requires a row violation of at most 1e-6.
- Nothing in README §3 or §4, the HANDBOOK (decision 8, known gaps, not verified) or the parts of SPECIFICATION-v0.2 that describe the current package says that an LP point integral within tolerance is rounded and returned unchecked. Nor does any of them say that big-M or large coefficients can yield an infeasible incumbent.

## Causal story, checked in the code

1. `TreeSearch.expand`, lines 196-205: when every integer column lies within 1e-6 of an integer, the integer columns are rounded and the point is offered.
   - It is offered with the node's LP `objective`.
   - It never goes through `isFeasible`.
   - The objective is never recomputed.
   - The dive does both (`isFeasible`, then `lp.internalObjective(at:)`).
2. `BranchAndBound.search` assembles the result (lines 357-399) with no final check of the incumbent.
3. Branch and bound takes its integrality tolerance from `Tolerances.default` (BranchAndBound.swift:198). No user setting changes it.

## Attempts to refute

- **By design?** No. The design intent stated in the doc comments is "a feasible integral solution". The other two incumbent paths check feasibility, and this one omits the check.
- **Within a documented tolerance?** Not for the point.
  - The unscaled row violation is 0.5. Even with the row equilibrated by its 1e6 coefficient it is 5e-7, five times `primalFeasibility`.
  - The package's own `isFeasible` would reject the point (0.5 > 1e-7).
  - So would its test oracle (0.5 > 1e-6).
- **The objective value is partly defensible.** Under the documented integrality tolerance, the unrounded LP point (open = 5e-7, flow = 0.5) counts as integral and is row-feasible. Its objective, 0.50005, is the optimum of the problem relaxed to that tolerance. This is the well-known big-M "trickle flow" effect, and solvers with a tolerance report the same value.
  - So "objective off by a factor of 200 vs 100.5" uses an exact-integrality oracle, and that part of the headline overstates.
  - It does not rescue the result. The package returns the rounded point (open = 0), which is infeasible, and `objectiveValue` (0.50005) is not equal to c·x at that point (0.5). No reading of the contract makes this pair a valid `.optimal` answer.
- **Misuse?** A big-M of 1e6 on a flow bounded by 10 is a poor formulation, but it is valid input, and the README restricts no coefficient magnitudes for correctness.
  - The trigger is simply rhs/coefficient ≤ 1e-6. For example, M = 1e7 with a demand of 5 gives `.optimal` 5.00005 at an infeasible point, against a true optimum of 105.
  - Shape 2 has no big-M ratio at all (both coefficients are 1e7).
  - No configuration avoids it: a tight `Gap`, `.none` heuristics, every engine, deterministic or parallel all give the same result.
  - `Conditioned(Automatic())` lists a big-M warning in its conditioning report, but it still returns `.optimal` at the infeasible point, and `analysis.warnings` is empty.
- **Already documented?** No (see above).

Other effects observed:

- `Portfolio([BranchAndBound(), CPSAT()])` returns branch and bound's wrong `.optimal` 5e-7 at (0, 0), although `CPSAT()` alone returns the correct 1.
- README risk 1's advice (`maxViolation(at:)`) would catch the bad point. That is a mitigation the user has to apply, not documentation of the defect.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V092 -c release          -> Build complete!
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V092 all   -> exit=0
```

```
shape1 LP Simplex(.primal): optimal obj=0.50005 open=5e-07 (|open-round| <= 1e-6: true) flow=0.5 LP-point rowViol=0 | rounded point rowViol=0.5 c.x(rounded)=0.5
shape1 LP Simplex(.dual):   same
== shape 1, d=0.5, M=1e6 (true optimum 100.5) ==
BranchAndBound():                      optimal obj=0.50005 bound=0.50005 [open=0 flow=0.5] c.x=0.5 viol(rows 0.5) sources=["lp"]
  identical for: deterministic, Simplex(.dual), InteriorPoint(), threads 4 + heuristics .none,
  tight gap 1e-9/1e-12, Automatic(), Conditioned(Automatic()) (report: "row link has a coefficient on the
  binary column open that is 1e+06 times the row median (big-M)", status still optimal, analysis.warnings empty)
== M=1e7, d=5 (true optimum 105) ==
BranchAndBound(), Automatic(): optimal obj=5.00005 [open=0 flow=5] c.x=5 viol(rows 5) sources=["lp"]
== threshold sweep, M=1e6 (LP puts open=d*1e-6) ==
d=0.5 / 0.9 / 1.0 : optimal obj=0.50005 / 0.90009 / 1.0001, open=0, row viol 0.5 / 0.9 / 1, source "lp"
d=1.01 / 1.5 / 2.0: optimal obj=101.01 / 101.5 / 102, open=1, viol 0, source "rounding"   (correct)
  -> the switch is exactly the 1e-6 integrality test in expand() (TreeSearch.swift:198)
== shape 2: min a+b, 1e7 a + 1e7 b >= 5, a,b integer in [0,10] (true optimum 1) ==
BranchAndBound(), BranchAndBound(Simplex(.dual), deterministic), Automatic(): optimal obj=5e-07 [a=0 b=0] c.x=0 viol(rows 5) sources=["lp"]
CPSAT():                                  optimal obj=1 [a=1 b=0] viol 0
Portfolio([BranchAndBound(), CPSAT()]):  optimal obj=5e-07 [a=0 b=0] viol(rows 5)
```

## Code read

- TreeSearch.swift:196-205 (`expand`), 317-339 (`offer`, `isFeasible`), 348-419 (the rounding heuristic, which checks), 425-450 (the dive, which checks and recomputes the objective).
- BranchAndBound.swift:198 and 290-293 (the tolerances), 357-399 (the result, with no final check).
- SearchTree.swift:466-479.
- Status.swift and Strategy.swift (the `Tolerances` doc comments), Analysis.swift.
- README §2.3, §2.5, §3 risks 1 and 10, §4; HANDBOOK decisions and gaps; SPECIFICATION-v0.2.
- BranchAndBoundTests.swift:60-65.
