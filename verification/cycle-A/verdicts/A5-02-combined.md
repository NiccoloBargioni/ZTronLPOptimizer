# A5-02 — sceptic verdict (lens: reproduce and contract)

- Finding: a coefficient that no power of 10 up to 1e6 makes integral (1e-10) is zeroed instead of rejected, and the solve ends in `SolverError.internalInconsistency`.
- Verdict: **confirmed**
- Documented: **false**
- Severity (my own rating): **critical**. The symptom the finder reported, `internalInconsistency` instead of `.unsupported`, would on its own be medium (misleading API behaviour). But the same zeroing, run here, also returns a false `.infeasible` and a wrong `.optimal` with a "proven" bound. The final self-check cannot catch those because the point returned is feasible, or no point is returned at all. Both are critical on the scale.
- Probe: `verification/probes/cycle-A/Slots/V124/main.swift` (slot V124). Repo at d9afebe, read-only.

## Independent oracle

- Oracle 1 (exact): the integer optimum comes from a binary search on each monotone row. The sign of Σ a·x − r is computed without rounding error (TwoProduct by fma plus TwoSum), so feasibility is decided exactly on the Double data. It does not depend on the finder's hand derivation or on `maxViolation`.
- Oracle 2: a different engine, `BranchAndBound(deterministic: true)` (LP-based, with no integer scaling).
- Check 3: the package's own `CompiledLP.maxViolation(at:)` at the true optimal point.

## Contract

- README §2.5, `CPSAT` row, and the `CPSAT.solve` doc comment (CPSAT.swift:147-149) say it "Throws `.unsupported` for … data that no power of 10 up to 1e6 makes integral". 1e-10·10^k for k = 0…6 is 1e-10 … 1e-4, and none of these is an integer. README §4 "Limits by design / CP-SAT" says the same, and neither states a tolerance.
- `SolverError.internalInconsistency` (Status.swift:54): "A bug in the solver; never caused by user data." README §1 promise 3: `solve` throws "only for a model that is invalid or outside what the engine accepts".
- The 1e-9 snap appears only in the header comment of CPModel.swift and in the doc comments of the internal `snapTolerance` and `integralScale` (CPModel.swift:114-122). The test that covers it is named `scalingToleratesFloatingPointNoiseOnly`, which states the intent: noise only. 1e-10 is not rounding noise around 0. The package's documented drop tolerance is `CompileOptions.dropTolerance` = 1e-14, and that drop is reported through `ModelDiagnostic.Kind.droppedSmallCoefficient`. CP-SAT's drop of anything up to 1e-9/scale is silent: no warning and no diagnostic.
- Mechanism (code read, matches the finder's locations):
  1. `integralScale` (CPModel.swift:122-138) accepts |v·s − round(v·s)| ≤ max(1e-9, 4 ulp) at line 131, so [1e-10, 1] gets scale 1.
  2. `Int64((1e-10).rounded())` is 0, and the term is dropped at `if a == 0 { continue }` (line 305). The same happens in LPRelaxation.swift:80-81 and in the objective loop (`if c == 0 { continue }`).
  3. A row left with no terms is then judged by its bounds alone (lines 309-312), and a row with fewer terms by the remaining activity range ("cannot be satisfied within the column bounds"). Both give `infeasibleReason`, which leads to `.infeasible` with no search.

## Commands and key output

Build: `cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build --product V124 -c release` gives "Build complete!".
Run (made twice, with the same results): `V124_LIMIT=3 perl -e 'alarm shift; exec @ARGV' 240 .build/release/V124` exits with status 0. CP-SAT ran in four configurations: det = `CPSAT(deterministic: true)`, par = `CPSAT()`, detnolp and nolp = `lpPropagator: false`, each with `timeLimit` 3 s.

**Reproduction of the finder's cases:**
```
C1  max x + y s.t. 1e-10 x + y <= 1, x in [0,1e9] int, y binary   (typed DSL path: CPSAT.solve(LPModel))
  oracle1 exact: optimum x=1e9 y=0 obj=1e9; (1e9,1) has residual +0.1 (infeasible)
  oracle2 B&B:   optimal obj=1000000011 (within its tolerance; see aside)
  det/par/detnolp/nolp: THROW internal inconsistency: CP-SAT returned a point that violates row c1
C2  max x s.t. 1e-10 x <= 0.05, x in [0,1e9]                       (CompiledLP)
  oracle1 exact: 5e8; oracle2 B&B: optimal 5e8
  par, nolp: THROW internal inconsistency ... row c1 (t=0.00s)
  det, detnolp: feasible(timeLimit) obj≈2.5e6..2.7e6, point feasible, t=3.00s (limit honoured; climbing one incumbent at a time)
```

**The same mechanism: false `.infeasible`:**
```
C3b min z s.t. 1e-10 z >= 1, z in [0,2e10] int                     (CompiledLP, as the MPS/LP readers produce)
  oracle1 exact: optimum z=1e10 (residual +3.6e-17; at 1e10-1: -1e-10); lp.maxViolation(at:[1e10]) = (0,0)
  oracle2 B&B:   optimal obj=1e10
  det/par/detnolp/nolp: status=infeasible
C3c min z + w s.t. 1e-10 z - w >= 1, z in [0,2e10] int, w binary  (typed DSL path, two-term row)
  oracle1 exact: z=1e10, w=0; oracle2 B&B: optimal 1e10
  det/par/detnolp/nolp typed: status=infeasible
```
(C3, the one-variable version through the DSL, is not affected: `lowerSingletonConstraints` turns the row into the bound z ≥ 1e10, and CP-SAT returns the exact optimum 1e10. The defect needs the coefficient to reach the CP-SAT loader.)

**The same mechanism: wrong `.optimal`, which the self-check cannot see:**
```
C4  max y s.t. 1e-10 x - y >= 0, x in [0,2e10] int, y binary      (CompiledLP)
  oracle1 exact: optimum 1 (y=1 at x>=1e10); lp.maxViolation(at:[1e10,1]) = (0,0); oracle2 B&B: optimal 1 at (1e10, 1)
  det/par/detnolp/nolp: status=optimal obj=-0 bound=-0 x=[0,0]
C4d same model through the DSL:      det/par/detnolp/nolp typed: status=optimal obj=-0 (B&B: optimal 1)
C4f same model via LPFormat.read:    det/par/detnolp/nolp: status=optimal obj=-0 bound=-0 (B&B: optimal 1)
C7  min y - 1e-10 x s.t. x - 3e10 y <= 0, x in [0,3e10] int, y binary   (objective path)
  oracle: objective at (3e10,1) = -2, feasible; B&B: optimal -2
  det/par/detnolp/nolp: status=optimal obj=0 bound=0 x=[0,0]
```
The gap of 1 (C4) or 2 (C7) is far outside the documented gap of max(1e-6, 1e-4·max(1,|z|)) (README risk 10) and outside any feasibility tolerance.

**Controls (where the finding does not hold, or the behaviour is within tolerance):**
```
C5  1e-10 x + y <= 1, x in [0,10], y binary, max x+y: optimal obj=11 at (10,1), rows violation 1.0e-9.
    The exact optimum is 10, but 1e-9 is within the documented 1e-7 feasibility tolerance: harmless here.
C6  a x + y <= 1, x in [0,10], y binary (det):
    a = 1e-12, 1e-10, 5e-10, 1e-9  -> ACCEPTED (a zeroed; rows violation = 10a)
    a = 1.0000001e-9, 1.5e-9, 2e-9, 1e-8, 1e-7 -> THROW unsupported: row c1 has coefficients that no power of 10 up to 1e6 makes integral
    a = 1e-6 -> ACCEPTED, exact (integral at 1e6)
```
So the line between "rejected" and "silently dropped" sits at |a·scale| = 1e-9. A smaller non-integral coefficient is silently dropped, while a larger one is rejected. Whether the result is harmless depends on |a|·(column range) compared with the 1e-6 self-check and the 1e-7 tolerance, a quantity the loader never looks at.

Existing tests: `AcceptanceTests/dataThatNoPowerOfTenMakesIntegralIsRejected` and `AcceptanceTests/scalingToleratesFloatingPointNoiseOnly` both pass in the baseline (`baseline/03-test-debug.log`, lines 1615 and 1624). Neither has a coefficient of magnitude ≤ 1e-9, so the suite cannot see this.

## Attempts to refute, and why each fails

- Wrong oracle: no. Two independent oracles (the exact residual sign, and B&B) agree with the package's own `maxViolation` on the true optimum in every case.
- Misuse: no. Every model is pure integer, finitely bounded, below 2^53, with activities far below 2^61, and built through public API: the DSL, `LPFormat.read` and `CompiledLP.init`.
- By design: the snap is intended in code comments only. The public contract promises `.unsupported`, and `internalInconsistency` is documented as never caused by user data. A false `.infeasible` or a wrong `.optimal` cannot be a design outcome.
- Within a documented tolerance: only when |a|·range ≤ ~1e-7 (C5, C6). C1 violates by 0.1, C3b and C3c are false infeasible, and C4 and C7 are off by 1 and 2.
- Not reproducible: no. Two full runs gave the same statuses in all four configurations.

## Documentation status

Not documented. The README (§2.5, §4) states rejection without a tolerance. The HANDBOOK says nothing about the snap. The 1e-9 snap is only in internal comments in CPModel.swift. Nothing mentions the internalInconsistency, false infeasible or wrong optimal outcomes, and SolverError's doc comment says the opposite.

## Aside (another area, not verified further)

On C1, oracle 2 `BranchAndBound(deterministic: true)` returned `optimal obj=1000000011 x=[1000000011, 0]` while x ≤ 1e9. That is a column bound violated by 11 (1.1e-8 relative), likely a tolerance applied after scaling. The verdict here rests on oracle 1. This may be worth a look by the F4 area.
