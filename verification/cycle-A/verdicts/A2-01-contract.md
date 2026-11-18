# A2-01, sceptic (contract lens): crossed bounds reported `.optimal`

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** critical (`.optimal` returned at a point that violates its bounds by 0.5 to 2.0, far outside the 1e-7 tolerance)
- **Probe:** /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V032/main.swift (my own code, written independently of the finder's F2 slot)

## What the package promises for this input

I tried to refute the finding by arguing that the input is misuse, is by design, or falls inside a tolerance. None of these holds.

1. **The input is accepted, not misuse.**
   - README §1 ("What goes in") lists "a `CompiledLP` built by hand" as an input.
   - `CompiledLP.init` (Sources/ZTronLPCore/Model/CompiledLP.swift:123-146) checks only dimensions, with two `precondition`s.
   - README §4 ("Misuse of the building blocks traps") lists only inconsistent dimensions and mismatched lengths as misuse. Crossed bounds are not on that list, and they do not trap.
   - No doc comment on `xl`/`xu`/`rl`/`ru`, `withColumnBounds`, `withRowBounds`, `applying`, `BoundChange`, `WarmStart.incremental` or `SimplexEngine.applyBoundChanges` requires lower ≤ upper.
2. **The package classifies this data as infeasible.**
   - `Presolve.Outcome.infeasible` is documented as "The model has no feasible point" (Presolve.swift:25-26), and `normalizeBounds` returns that outcome for a crossing larger than the tolerance (Presolve.swift:150-160).
   - The package's own test `PresolveTests.boundsThatCrossByRoundingNoiseDescribeAFixedColumn` says "A real crossing is infeasible" and uses `xl = [1.5, 0]`, `xu = [1, inf]`. I ran `Simplex` on that exact instance (T1 below): it answers `.optimal`.
   - On the same hand-built data, InteriorPoint, BranchAndBound and CPSAT all answer `.infeasible`. The DSL compile and the MPS/LP readers reject it with `SolverError.invalidModel(.inconsistentVariableBounds)`.
   - Simplex is the only engine that answers with a success status.
3. **The Simplex path was meant to answer `.infeasible`.**
   - Simplex.swift:155-161: "Presolve has no certificate of its own. The unpresolved problem gives one, and settles the status."
   - SPECIFICATION-v0.2 §5.5 describes this as what `Simplex` "already does when presolve itself proves infeasibility": it returns the answer of the unpresolved solve "and its certificate".
   - The existing test `SimplexBasicsTests/infeasibilityFoundByPresolveStillCarriesARay` passes, with `.infeasible` and a Farkas ray. Its crossing comes from singleton rows, so the unpresolved engine sees it in basic slacks. A crossing stored in the column bounds themselves is never tested.
4. **The status semantics are violated.**
   - `SolveStatus.optimal`: "An optimal solution was found and proven".
   - README §4 (Results): "Optimal" means "feasible and dual feasible to 1e-7".
   - The violations observed are 0.5 to 2.0, with exact data and no numerical subtlety, so no tolerance or conditioning argument applies.
   - README risk 1 ("read the status before the values, and the warnings after") is a generic hedge about floating-point algorithms. It does not describe this deterministic logic gap.
   - In the paths with presolve off, through `SimplexEngine`, or with a crossed row, there is no warning at all. In the paths with presolve on, the warning ("presolve found the model infeasible … solving without presolve for the certificate") contradicts the `.optimal` status.
5. **The causal story holds, and is slightly sharper than the finder's.**
   - `primalInfeasibility()` (SimplexEngine.swift:664-677) measures basic variables only.
   - `placeNonbasic` (382-389) puts a nonbasic column on one of its two crossed bounds, so it violates the other one.
   - `conclude` (SimplexEngine+Driver.swift:777-801) sets `primalFeasible = true` for `.optimal` without calling `boundsRespected()`. That function does check nonbasic columns, but only for other statuses, and its comment states the invariant that crossed bounds break: "it does unless a run was interrupted in an unusual state".
   - A crossed row (rl > ru) fails the same way, through its logical column. Presolve does not check rows for crossing at all: V4 below gives outcome `reduced`.
6. **The finder's text has one small inaccuracy.** "InteriorPoint answers infeasibleOrUnbounded" is true only for the crossed row (V4). For crossed column bounds, InteriorPoint answers `.infeasible` from its presolve.
7. **Not re-run:** the finder's 40-configuration grid. My own runs cover 4 Simplex configurations on 6 instances, plus `Automatic`, `Conditioned`, the `.incremental` warm start and the engine directly.

## Commands and key output

Build, then run the LP cases:

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build --product V032 -c release   -> Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 lp      (exit 0)
V1 Simplex(dual): status=optimal x=[2.0] obj=2.0 viol(bounds 1 rows 0) dualRay=nil warnings=["presolve found the model infeasible (column x1 has lower bound 2.0 above upper bound 1.0); solving without presolve for the certificate"]
V1 Simplex(dual, presolve:false): status=optimal x=[2.0] viol(bounds 1 rows 0) warnings=[]
V1 InteriorPoint: status=infeasible
V1 Automatic: status=optimal x=[2.0] viol(bounds 1 rows 0)
V2 (x+y>=3, x in [2,1]) Simplex dual/primal, presolve on/off: status=optimal x=[1.0, 2.0] viol(bounds 1 rows 0); InteriorPoint: infeasible
V3 (max x, x in [2,1]) Simplex dual/primal, presolve on/off: status=optimal x=[1.0, 0.0] viol(bounds 1 rows 0); InteriorPoint: infeasible
V4 (row in [3,1]) Simplex dual/primal, presolve on/off: status=optimal x=[3.0, 0.0] viol(bounds 0 rows 2) warnings=[]; InteriorPoint: infeasibleOrUnbounded; Automatic: optimal; Presolve outcome = reduced
V5 (crossing 1e-9, inside tolerance): status=optimal viol 5e-10 / 1e-9, Presolve outcome = solved   (by design, correct)
```

The extra cases (T1 is the package's own test instance, then the warm-start and engine paths):

```
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 extra   (exit 0)
T1 Presolve outcome = infeasible("column x1 has lower bound 1.5 above upper bound 1.0")
T1 Simplex(dual): status=optimal x=[1.0, 2.0] obj=3.0 viol(bounds 0.5 rows 0) dualRay=nil
T1 Simplex(primal): status=optimal x=[1.0, 2.0] viol(bounds 0.5 rows 0)
T1 InteriorPoint: status=infeasible
T1 Conditioned(Simplex(.dual)): status=optimal viol(bounds 0.5)
T1 Portfolio[Simplex(.dual), InteriorPoint] x3: status=infeasible (the interior point wins the race)
T2 Simplex(dual) .incremental BoundChange(0, 2.5, 1.5): status=optimal x=[1.5, 1.25] obj=-2.75 viol(bounds 1 rows 0)
T3 SimplexEngine.applyBoundChanges crossed: status=optimal x=[1.5, 1.25] viol(bounds 1 rows 0) warnings=[]
```

The package's other paths for the same data:

```
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 other   (exit 0)
DSL compile: THROWS invalid model: variable x has lower bound 2.0 above upper bound 1.0
DSL Simplex solve(model): THROWS invalid model: ...
MPS read: THROWS invalid model: variable x has lower bound 2.0 above upper bound 1.0
I2 BranchAndBound: status=infeasible ("bound tightening found the model infeasible: column x1 ...")
I2 CPSAT: status=infeasible
I2 Automatic: status=infeasible
I2 Simplex(dual) relaxation: status=optimal x=[1.0, 2.0] viol(bounds 1)
I3 (integer x in [0.3,0.7]) BranchAndBound: infeasible; CPSAT: infeasible
```

The existing test, where the crossing comes from rows:

```
cd /Users/admin/Documents/ZTronLPOptimizer && swift test --filter 'ZTronLPSimplexTests.SimplexBasicsTests/infeasibilityFoundByPresolveStillCarriesARay'
✔ Test infeasibilityFoundByPresolveStillCarriesARay(_:) with 2 test cases passed   (exit 0)
```
