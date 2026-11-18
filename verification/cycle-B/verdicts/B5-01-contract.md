# B5-01, sceptic verdict, CONTRACT lens (cycle B, slot V122)

- Finding: Integer bounds and row bounds of magnitude >= 2^50 are widened by 1 to 4 units, and CP-SAT returns `.optimal` at a point that violates them.
- Package: git main @ d9afebe (source tree clean), Swift 6.4, M3, macOS 27.
- **Verdict: confirmed**
- **Documented: false**
- **Severity: critical.** This is a wrong answer reported as `.optimal`: the point is infeasible and the objective is wrong. It happens with objectives of 0 to 10, a range the README calls exact.

## What the package promises (contract)

- **README §2.5, CPSAT row.** CPSAT throws `.unsupported` only for "bounds or scaled coefficients of magnitude 2⁵³ or more" (and for continuous columns, unbounded integers, data no power of 10 up to 1e6 makes integral, and activities beyond ±2⁶¹). All the models below are therefore inside the accepted domain, so this is not misuse.
- **README §4, Limits by design, CP-SAT.** It accepts "bounds and scaled coefficients below 2⁵³". No limit or defect says that bounds or row sides may be relaxed.
- **README §4, Results.** "Optimal ... feasible ... to 1e-7". `Tolerances.primalFeasibility` is documented as "Bound/row violation allowed, after scaling" (an absolute violation), and CP-SAT does not scale columns. The violations seen here are 1 to 4 absolute.
- **`SolveStatus.optimal` doc.** "An optimal solution was found and proven (within the gap, for MILP)." An infeasible point is not a solution.
- **README risk 10 (the gap).** It applies only to objectives of 10⁴ or more. The proof is "exact for integral costs ... while the objective stays below 10⁴". My cases have objectives of at most 10, so the gap cannot explain them.
- **Doc comments of the declarations involved.**
  - CPModel.swift:3 says "CP-SAT works on pure integer programs in exact Int64 arithmetic".
  - CPModel.swift:45 (`lower`/`upper`) says "Root domains, rounded inward to integers". The observed rounding goes outward.
  - `snapTolerance` (CPModel.swift:113-119) is documented as the test for "how close to an integer a scaled value must be to count as that integer ... so that noise in large data is not mistaken for a fraction". The design intent is integrality detection. It is not a licence to map an exact integer to a different integer, yet 2^52+1 becomes 2^52-3.
  - `CPSAT.violation` (internal) says "A violation is a bug in the solver, never a property of the model". Its relative 1e-6 net (4.5e9 at 4.5e15) is a bug detector, not a published tolerance.
- **Test comment.** Tests/ZTronLPCPSATTests/AcceptanceTests.swift:83 says "Bounds beyond 2^53 cannot be read exactly from a Double". This implies the intent that bounds below 2^53 are read exactly. `largeButRepresentableDataIsAccepted` stops at 1e15, which is below 2^50, so no test covers [2^50, 2^53).
- **HANDBOOK and SPECIFICATION-v0.2.** Neither has a decision, known gap or statement about widening large bounds.

## Causal story (code reading, holds)

- `snapTolerance(v) = max(1e-9, 4*ulp(v))` is at CPModel.swift:117-119.
- It is applied outward before rounding at four places:
  - column bounds at CPModel.swift:173-174, `(xl - tol).rounded(.up)` and `(xu + tol).rounded(.down)`;
  - row upper side at :335;
  - row lower side at :347;
  - the LP relaxation's row sides at LPRelaxation.swift:95 and :99.
- When `tol < 1` this equals ceil/floor with noise snapping. When |v| >= 2^50, 4 ulp is 1, 2 or 4, so an exact integral bound moves outward by that many whole units:
  - [2^50, 2^51): 1 unit;
  - [2^51, 2^52): 2 units;
  - [2^52, 2^53): 4 units.
- The `|lo|,|hi| < 2^53` guard is applied after the widening. The `CPSAT.violation` re-check is relative 1e-6, so it cannot see the violation.
- `LPModel.compile` passes the bounds through exactly. The compiled `xl`, `xu`, `rl` and `ru` printed below equal the declared values, so the widening happens only in CP-SAT's loading.

## Independent probe (own models, public DSL, small objectives)

The slot is /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B/Slots/V122/main.swift. Every variable is an integer, and `timeLimit` is 10 s. Each case was solved with:
- `CPSAT()`;
- `CPSAT(deterministic: true)`;
- `CPSAT(lpPropagator: false, deterministic: true)`.

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B
swift build --product V122 -c release                       # Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V122   # exit=0
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V122 A3          # 2^51 case
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V122 "A K=2^52"  # repeat, identical
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V122 U           # row upper side
```

Key output (maxViolation is the public, absolute `CompiledLP.maxViolation`):

**A: x in [0,K], y in [0,10], x + y >= K+3, min y (true optimum 3)**
- K=1000 (control): `optimal obj=3`. ok in all 3 configurations.
- K=2^50-8 (control): `optimal obj=3`. ok in all 3, so the threshold is 2^50.
- K=2^50: `optimal obj=1 bound=1 x=1125899906842625 (bounds 1.0, rows 1.0)` in all 3. WRONG.
- K=2^51: `optimal obj=0 bound=0`, x=2^51+2 (bounds 2, rows 1) or 2^51+1 (bounds 1, rows 2). WRONG in all 3.
- K=2^52:
  - CPSAT(): `optimal obj=0 x=4503599627370500 (bounds 4.0)`;
  - deterministic: `x=4503599627370499 (bounds 3.0)`;
  - nolp-deterministic: `x=4503599627370495 (rows 4.0)`.
  - All WRONG (objective 0 vs 3). Repeated with identical results.

**C: x in [K,K+20], y in [0,10], x - y == K+1, min y (optimum 0 at x = K+1)**
- K=1000: ok.
- K=2^52:
  - CPSAT() and nolp-deterministic: `optimal obj=0 x=4503599627370493 (bounds 3.0, rows 4.0)`. WRONG, infeasible point.
  - deterministic with LP: `x=4503599627370497`, ok, because the search happened to pick the right value.

**B: x in [K+1,K+10], y in [0,10], min y (x must stay in its bounds)**
- K=1000: ok.
- K=2^50+2: `optimal x=1125899906842626 (bounds 1.0)` in all 3.
- K=2^52: `optimal x=4503599627370493 = 2^52-3 (bounds 4.0)` in all 3. This is the finder's M1 value.

**U: x in [K,K+20], y in [0,10], x + y <= K+1, max y (true optimum 1), exercising row upper side CPModel.swift:335**
- K=1000: ok.
- K=2^50: `optimal obj=3 bound=3 x=1125899906842623 (bounds 1.0, rows 1.0)` in all 3.
- K=2^52: `optimal obj=9 bound=9 x=4503599627370492 (bounds 4.0, rows 4.0)` in all 3.

Total: 23 of the 24 solves on models with a value >= 2^50 are `.optimal` with an infeasible point. The one exception is C with the deterministic LP configuration. 15 of the 23, all the A and U cases, also have a wrong objective. In the B and C cases the objective is right but the point is infeasible. None of the 15 control solves (values below 2^50) is wrong.

## Reasoning for the verdict

- **Input is inside the documented domain.** The README accepts the input (every value is below 2^53, an exact integer and exactly representable).
- **The output breaks every applicable promise.** It violates the documented feasibility meaning of `.optimal`: an absolute violation of 1 to 4 against a 1e-7 tolerance, on integer data the solver claims to handle in exact Int64 arithmetic. It also violates the code's own doc ("rounded inward").
- **Not explained by the gap.** The objectives are small, where README risk 10 says CP-SAT is exact, and the controls just below 2^50 are exact.
- **Not by design.** The 4-ulp snap is documented only as integrality noise handling. Nothing tells the user that bounds may move.
- **Not documented.** Nothing in README §3/§4 or the HANDBOOK mentions it.
- **No relative-tolerance escape.** A relative-tolerance reading is not available: no CP-SAT tolerance is published, `maxViolation` is absolute, and objectives off by 2 to 8 units at magnitude 1 to 9 cannot be excused by relative feasibility.
- **The finder's statements and line numbers check out.** CPModel.swift:117-119, 173-174, 335, 347 and LPRelaxation.swift:95, 99 are correct.
- **Exposure is narrow, but this does not change the severity class.** The trigger needs |bound| or |scaled row side| >= 2^50 (about 1.13e15), and CPSAT has to be chosen explicitly or put in a Portfolio (Automatic sends integer models to BranchAndBound). By the scale this is still critical: `.optimal` with an infeasible point or a wrong value.
