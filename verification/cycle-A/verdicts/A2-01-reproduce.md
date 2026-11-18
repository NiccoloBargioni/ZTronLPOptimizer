# A2-01: independent sceptic, lens REPRODUCE

Finding: Simplex reports crossed bounds (xl > xu or rl > ru) as `.optimal` at an infeasible point, even after presolve has found the model infeasible.

- **Verdict: confirmed**
- **Documented: no**
- **Severity: critical.** The scale defines critical as `.optimal` returned with an infeasible point, and that is what happens here.
- Package: git main @ d9afebe. Probe slot: `verification/probes/cycle-A/Slots/V031/main.swift`. I wrote it from the description and did not reuse the finder's oracle.

## Three questions

1. **Does the behaviour happen? Yes.** I tested 5 cases of my own, each in 24 Simplex configurations: method (`.dual`, `.primal`), pricing (`.dantzig`, `.devex`, `.steepestEdge`), presolve on or off, and scaling (geometric or none). Every one of the 120 solves returned `optimal`. My own violation measure (not `CompiledLP.maxViolation`) gives 1.0, 1.0, 1.0, 2.0 and 4.0 for the five cases.
   - `Automatic()` routes these LPs to `Simplex(.dual)` and answers `optimal` too.
   - For crossed column bounds, the result carries the presolve warning "presolve found the model infeasible (...); solving without presolve for the certificate" next to status `optimal`.
   - Three other entry points also answer `optimal` at a point that violates a bound by 1.0: `WarmStart.incremental` with `BoundChange(column: 1, lower: 3.5, upper: 2.5)` on a feasible base LP, a cold solve of `base.applying([change])`, and `SimplexEngine.applyBoundChanges` followed by a dual solve.
2. **Is the expected answer (infeasible) correct? Yes.** Five independent oracles agree:
   - **By hand:** the interval [2, 1] (or [3, 1] for the row) is empty, so no point can be feasible.
   - **By enumeration:** a grid over [-10, 10]^n in steps of 0.25 has 0 feasible points in every case.
   - **By a second formulation:** I wrote each problem again without any crossed interval but with the same empty feasible set. For example, x in [2, +inf) plus a row x ≤ 1; for the row case, two rows x + y ≥ 3 and x + y ≤ 1. On these, all 24 configurations answer `infeasible`. I checked every dual ray with my own interval Farkas test, which does not depend on the package's sign convention: 24/24 valid in each case.
   - **By other engines:** `InteriorPoint` (crossover lite and none) answers `infeasible` for crossed columns and `infeasibleOrUnbounded` for crossed rows. The package's own B&B (via `Automatic` on a MIP) and `CPSAT` answer `infeasible` on an integer column with crossed bounds.
   - **By the DSL:** compiling x in [2, 1] throws "invalid model: variable x has lower bound 2.0 above upper bound 1.0".
   - **Control:** an uncrossed but infeasible bound change (x in [4.5, 5] against x + y ≤ 4) answers `infeasible` with a dual ray on every path. So the engine does prove infeasibility; only crossed intervals slip through.
3. **Does it depend on load or randomness? No.**
   - Each case and method was run 5 times with 1 thread and 5 times with 8 threads, and always gave exactly 1 distinct answer.
   - Debug and release builds give identical results.
   - The solves take microseconds, with no timing involved.

### Tolerance

The default primal feasibility tolerance is 1e-7. I swept how far the bounds cross (the gap) in a model with xl0 = 1 + gap and xu0 = 1:

- **Gap of 1e-12 or 1e-8, presolve on:** presolve's rule for bounds crossed by rounding noise fixes the column at the midpoint, as documented. The violation is gap/2.
- **Gap from 1e-6 to 1.0:** status `optimal`, and the violation equals the gap, up to 1e7 times the tolerance.
- **Gap of 1000:** status `infeasible`, but only because the row x0 + x1 ≤ 10 proves infeasibility on its own.

So this is not a tolerance effect.

## Mechanism (read in the code)

- **`SimplexEngine.swift:664`:** `primalInfeasibility()` loops only over basic variables (`head[k]`).
- **`SimplexEngine.swift:382`:** `placeNonbasic` puts an `.atLower` column at `lower[j]` even when `lower[j] > upper[j]`. That column is never measured.
- **`SimplexEngine+Driver.swift:785`:** `conclude` sets `primalFeasible = true` for `.optimal` without calling `boundsRespected()` (line 806). That check would catch the point. Its comment assumes nonbasic columns always sit within bounds, which crossed bounds break.
- **Crossed row:** a basic logical violates one of its bounds whatever its value, so it is pivoted out of the basis. It then stays nonbasic at one bound and violates the other, unmeasured.
- **`Simplex.swift:155-161`:** when presolve returns `.infeasible`, the code re-solves the problem without presolve, and that run's status replaces presolve's verdict.
- **Why the tests miss it:** the existing test `infeasibilityFoundByPresolveStillCarriesARay` crosses bounds through singleton *rows*. Those stay uncrossed rows in the problem solved without presolve, so the engine still proves infeasibility. Crossed column bounds and crossed multi-entry rows are not tested.

## Is it misuse, or by design?

Neither.

- README §1 lists "a `CompiledLP` built by hand" as a supported input.
- The `CompiledLP` initializer, `withColumnBounds`, `applying`, `WarmStart.incremental` and `SimplexEngine.applyBoundChanges` are all public, and none states xl ≤ xu as a precondition.
- README §4 "Misuse of the building blocks traps" covers inconsistent dimensions only.
- I found no mention of crossed bounds in README, HANDBOOK or SPECIFICATION.
- The package itself treats crossed bounds as infeasible or invalid: in presolve, the interior point, branch and bound, CP-SAT, the DSL and the readers.

## Reach

- **Affected:** the LP simplex path: `Simplex`, `SimplexEngine`, and `Automatic`'s LP route.
- **Not affected:** MIP models through `Automatic` (branch and bound) and `CPSAT`. I checked one model only.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V031            # and: swift build --product V031 -c release
perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 dsl
  DSL compile with x in [2,1]: threw invalid model: variable x has lower bound 2.0 above upper bound 1.0
perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 grid      (same in .build/release)
  K1 column [2,1], no rows, min x: crossed over 24 Simplex configs: optimal 24; worst own violation 1.0
     split over 24 configs: infeasible 24; Farkas rays verified by own check 24/24
     first config: status optimal x [2.0] obj 2.0 ownViolation(bounds 1.0, rows 0.0) warnings ["presolve found the model infeasible (column x1 has lower bound 2.0 above upper bound 1.0); solving without presolve for the certificate"]
     InteriorPoint(lite/none): infeasible; Automatic: optimal x [2.0] (violation 1.0)
  K2 column [2,1], max x: optimal 24, x [1.0], violation 1.0; split infeasible 24 (24/24 rays valid); IPM infeasible
  K3 column [4,3] inside a row: optimal 24, x [4,0,0], violation 1.0; split infeasible 24 (24/24); IPM infeasible
  K4 row [3,1] over x,y in [0,5]: optimal 24, x [3,0], row violation 2.0; split infeasible 24 (24/24); IPM infeasibleOrUnbounded
  K5 row [6,2] + a normal row, max: optimal 24, x [1.333,0.333], row violation 4.0; split infeasible 24 (24/24); IPM infeasibleOrUnbounded
perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 warm      (same in .build/release)
  base cold (hand: x=[1,3], obj -7): status optimal x [1.0, 3.0] obj -7.0
  crossed y in [3.5,2.5] (grid feasible points 0):
    dual/primal incremental: status optimal x [1.5, 2.5] obj -6.5 ownViolation(bounds 1.0) + presolve-infeasible warning
    dual/primal cold on applying(): same
    engine applyBoundChanges + dual: status optimal x [1.5, 2.5] obj -6.5 ownViolation(bounds 1.0)
  control x in [4.5,5] (uncrossed, infeasible): every path status infeasible, dualRay [-1.0]
perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 sweep
  gap 1e-12/1e-8 presolve=true: optimal, violation gap/2 (noise rule); gap 1e-6..1.0: optimal, violation = gap;
  gap 1000: infeasible (row x0 + x1 <= 10 proves it independently)
perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 repeat
  every case x method: 1 distinct answer over 10 runs (5 x threads 1, 5 x threads 8)
perl -e 'alarm shift; exec @ARGV' 120 .build/debug/V031 mip
  MIP x0 in [3,2] integer: Automatic (B&B): infeasible ("bound tightening found the model infeasible ..."); CPSAT: infeasible
```

All runs exited 0. None hit the alarm.
