# A5-01 — contract sceptic (cycle A, slot V122)

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** critical
- **Finding:** CP-SAT's 4-ulp snap tolerance widens in-domain data of magnitude >= 2^49/2^50,
  giving `.optimal` with an infeasible point and a wrong objective.

## What the package promises (contract)

- README §2.5, `CPSAT` row: throws `.unsupported` for "data that no power of 10 up to 1e6 makes
  integral, bounds or scaled coefficients of magnitude 2⁵³ or more, or row activities beyond
  ±2⁶¹". README §4 Limits/CP-SAT says the accepted class is data that becomes integral at a
  power of 10 up to 10⁶, "with bounds and scaled coefficients below 2⁵³ and row activities within
  ±2⁶¹". No reduced precision between 2^49 and 2^53 is mentioned.
- README risk 10, and the public doc comment of `CPSAT` (Sources/ZTronLPCPSAT/CPSAT.swift:85-88),
  say the proof is exact for integral costs while 1e-4·|objective| < 1. For integral costs that
  means objectives below 10⁴. The `lpPropagator` doc (CPSAT.swift:113) says results are
  "re-derived in exact integer arithmetic".
- README §4 Results: "Optimal" means feasible to 1e-7. `CompiledLP.maxViolation` is absolute.
  `Tolerances.primalFeasibility` is "after scaling", and CP-SAT does not scale.
  `SolveStatus.optimal`: "found and proven (within the gap, for MILP)".
- Internal comments in CPModel.swift say "exact Int64 arithmetic" (:3), "integral within 1e-9"
  (:9, :121), "Root domains, rounded inward" (:45) and "fractional row bounds round inward"
  (:326). The doc of `snapTolerance` (:113-116) says: "How close to an integer a scaled value
  must be to count as *that* integer".
- Test intent: in AcceptanceTests.swift, the `activityOverflowIsRejected` test has the comment
  "Bounds beyond 2^53 cannot be read exactly from a Double". The suite has no test of data
  between 2^49 and 2^53.
- Nothing public documents the 4-ulp snap. README, HANDBOOK, SPECIFICATION-v0.2 and the docc
  catalog have no "ulp" or "noise" statement for CP-SAT. HANDBOOK's decisions, known gaps and
  "Not verified" sections say nothing about it.

## The causal story checked in the code

- `snapTolerance(v) = max(1e-9, 4·v.ulp)` (CPModel.swift:117-119). For |v| >= 2^50 this is >= 1.
- Column bounds (:173-174): `ceil(xl − tol)` and `floor(xu + tol)`. Row sides (:335, :347):
  `floor(ru·s + tol)` and `ceil(rl·s − tol)`. LPRelaxation.swift:95,99 does the same. When v is
  an integer, `floor(v + tol)` = v + floor(tol): the bound moves outward by 1 (at 2^50), 2 (at
  2^51) or 4 (at 2^52). The function's own doc promises that v counts as that integer, so this
  is not a rounding of noise. It is an implementation error.
- For fractional data from 2^49 up, 4 ulp >= 0.5. The coefficient 1e15+0.5 then passes the
  integrality test at scale 1 (:131) and is rounded to 1e15+1. Without the snap it would need
  scale 10, which gives 1e16+5 >= 2^53, and README says that is rejected.
- The end-of-solve self-check `CPSAT.violation` (CPSAT.swift:337-354) uses a tolerance of
  1e-6·max(1,|v|), which is about 4.5e9 at 4.5e15. A violation of 4 cannot trip it, although its
  doc says "A violation is a bug in the solver".

## Execution (my own probe, models built through the public DSL `LPModel` → `compile()`)

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V122 -c release          # Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V122    # exit=0
```

Full output: verdicts/A5-01-contract-V122.txt. Exact optima were computed independently in
Int64. Key lines:

```
A52 x fixed 4503599627370497, x+y<=4503599627370497, max y  det/par/det-noLP [CPSAT]:
    optimal obj=8 x=4503599627370493 y=8 maxViolation(bounds=4.0, rows=4.0) | exact: max y = 0
A50 x fixed 1125899906842625, same row, max y  det/par/det-noLP [CPSAT]:
    optimal obj=2 x=1125899906842624 y=2 maxViolation(bounds=1.0, rows=1.0) | exact: max y = 0
A48-control x fixed 281474976710657  det/par/det-noLP [CPSAT]:
    optimal obj=-0 x=281474976710657 y=0 maxViolation(0,0)          | exact: 0   (threshold confirmed)
B (1e15+0.5)x+y>=1e15+1, x binary, y in [0,3], min y  det/par/det-noLP [CPSAT]:
    optimal obj=0 x=1 y=0 maxViolation(bounds=0.0, rows=0.5)         | exact: min y = 1
C x<=2^52+1, max x  par [CPSAT]: optimal obj=4503599627370501 maxViolation(bounds=4.0) | exact 4503599627370497
    (det / det-noLP: feasible(timeLimit) after 5 s — the documented one-step-per-incumbent climb)
D row x<=2^49+0.5, max x  det/par [CPSAT]: optimal obj=562949953421313 rows=0.5 | exact 562949953421312
E x<=2^53-1, 2^53-4: THROW unsupported "too large" (README: accepted below 2^53)
E x<=2^53-5  par [CPSAT]: optimal obj=9007199254740991 maxViolation(bounds=4.0) | exact 9007199254740987
```

The finder's F5 probe, which builds `CompiledLP` directly, produced the same numbers. That makes
two independent reproductions through two construction paths. The results are not
timing-dependent, and the deterministic configuration reproduces them.

## Reasoning (contract lens)

- **Not a misuse.** The data are exact integers or exactly representable values. They lie
  below 2^53, and the activities lie far inside ±2^61, so they are inside the domain that the
  README §4 explicitly accepts.
- **Not within a documented tolerance.** CP-SAT is documented as exact. Its gap gives an exact
  proof for integral costs below 10⁴, and A52 and A50 have objectives of 8 and 2 against a true
  optimum of 0. The point violates a fixed column bound by 1 to 4 absolute, far beyond the
  absolute 1e-7 of README §4 Results.
- **Not by design.** The 4-ulp snap is a deliberate design only for treating near-integral
  noise as integral, and only an internal comment states it. Applied additively to an exact
  integer bound, it moves the bound to a different integer. That contradicts the function's own
  doc, the "rounded inward" comments, the 1e-9 statements and the test comment about exact
  reading below 2^53. Case B (a half-integer at 1e15 treated as noise) is closest to the design
  intent. It still contradicts README's rejection rule (the data needs scale 10, which gives a
  coefficient >= 2^53) and the exactness claims.
- **Not documented** anywhere public.
- **Severity.** On the given scale this is critical: `.optimal` comes with an infeasible point
  and a wrong objective. The trigger is narrow: fractional data of magnitude at least 2^49
  (about 5.6e14), integral data of at least 2^50 (about 1.1e15), and an explicit `CPSAT` or a
  `Portfolio` containing it, because `Automatic` sends integer models to `BranchAndBound`.
- **Minor corollary (low).** The effective rejection edge for bounds is 2^53−4, not 2^53. This
  is conservative, but it does not match README §2.5.

Context only, not evaluated: `BranchAndBound` on A52, A50 and A48 also returns obj=10, with x
off its fixed bound by 4.95e7, 1.24e7 and 3.1e6. Its contract is tolerance-based, "after
scaling", so this is a separate matter for the B&B area.
