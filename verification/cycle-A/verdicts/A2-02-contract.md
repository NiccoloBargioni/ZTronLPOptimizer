# A2-02 — contract-lens sceptic (cycle A, slot V035)

- **Verdict:** confirmed
- **Documented:** false
- **Severity:** critical
- **Finding:** Primal simplex declares a feasible LP with κ₁ 1.5e9 infeasible, with no warning and with a dual ray that does not certify.

## What the package promises

- `SolveStatus.infeasible` (Sources/ZTronLPCore/Solve/Status.swift:7): "The model has no feasible point."
- `SimplexAnalysis.dualRay` (Sources/ZTronLPSimplex/Simplex.swift:339): "When infeasible: a Farkas certificate over the rows." README §2.5 says the same in its Simplex row ("a ray when the answer is `.infeasible`"), and so does HANDBOOK line 114 ("An `.infeasible` LP result carries a dual ray (a Farkas certificate)").
- README §4, defect 8 says this is fixed in this version: the simplex "takes a small pivot before it concludes 'infeasible'". HANDBOOK decision 18 gives the reason: "no direction of descent" is "only true if it is true of the entries that were set aside as too small".
- The doc comment of `fragilePivotLimit` (SimplexEngine.swift:452-453) says: "How many such pivots one run may take before it gives up with a **numerical failure**."
- README §4, *Results*, says that only "Optimal" is "a statement about tolerances". No document makes `.infeasible` relative to the tolerances.
- README §3, risk 1 says the solution is recovered "up to a condition number of about 1e10". That sentence is about the Hilbert family. It is a softer oracle than the finder treats it as, and I do not rely on it.

## Checks against refutation

- **Oracle.** x = 1 is feasible:
  - `maxViolation` gives rows 0 and bounds 0.
  - Summed in reverse order or with Kahan summation, the residual is at most 3.3e-16, on row 1-norms of at most 4.3.
  - A is nonsingular. A dense solve is 2.2e-8 from 1, deep inside the [-10, 10] box, so the LP is feasible in exact arithmetic as well.
  - Since b = A·1, every r has Farkas value Σzⱼ − 10·Σ|zⱼ| ≤ 0 (with z = Aᵀr). No certificate can exist.
  - The ray's margin is −1.89e-7 by my own implementation. The rounding scale of the terms is 5.5e-15, so this is not noise.
- **Misuse.** No. A hand-built `CompiledLP` is a documented input, and `Simplex(.primal)` is a public, documented method. All other settings are defaults.
- **Within tolerance.** No. A point with zero violation exists, and the status is not documented as relative to the tolerances.
- **By design.** No. The code contradicts its own design:
  - The doc comment says that running out of the fragile-pivot budget is a numerical failure.
  - The dual method does exactly that (SimplexEngine+Dual.swift:280-283, "Calling the problem infeasible would be wrong").
  - Primal phase 1 (SimplexEngine+Primal.swift:700-706) runs `if fragilePivots < fragilePivotLimit, let weak = weakPhase1Entering() … else { lastDualRay = farkasRay(from: y); return .infeasible }`. When the budget is spent, it returns `.infeasible`.
  - `farkasRay(from:)` (lines 584-590) picks a sign but never checks that `farkasValue > 0`.
- **Reproducible.** Yes, and deterministic. I reproduced the finder's numbers exactly: the margin of −1.8900e-7, and the dual objective 11.884433256540472 at 2.08e-8 from x = 1.

## Mechanism (more precise than the finder's)

The finder says phase 1 found "no weak candidate". The trace (`V035 trace 15`) shows that the budget ran out instead:

1. Phase 1 progresses normally up to iteration 15: the row violation falls from 9.4 to 6e-5, with 1 refactorization.
2. From iteration 17 to 20 it stalls at about 3.5e-7, which is 3.5 times the 1e-7 tolerance.
3. It then alternates between two states, with row violations of 3.642e-7 and 3.414e-7. It takes exactly one refactorization per iteration, which is the signature of a fragile pivot: refactorizations are 4 at iteration 20, 34 at 50, 63 at 79 and 64 at the end.
4. That uses up the m + 50 = 61 fragile-pivot budget, and the run ends `.infeasible` at iteration 79.

The source lines are the ones the finder named, but the branch taken is budget exhaustion. With the feasibility tolerances at 1e-9, the same primal method returns optimal at 2.1e-8 from x = 1.

## Scope

- **Family sweep** (`V035 sweep 200`, `Simplex(.primal)` defaults): 54 of 200 feasible instances end `.infeasible`. None of those rays certifies, and none carries a warning.

  | κ₁ | False `.infeasible` |
  |---|---|
  | below 1e8 | 0 of 20 |
  | 1e8 to 1e9 | 9 of 25 |
  | 1e9 to 1e10 | 20 of 26 |
  | 1e10 to 1e11 | 6 of 26 |
  | 1e11 to 1e12 | 4 of 18 |
  | 1e12 and above | 15 of 85 |

  The lowest κ is 2.3e8 (k52, n = 7). `Simplex(.dual)` answers optimal on all 200.
- **The default facades reach it:**
  - `InteriorPoint()` ends infeasible on k15. It warns about the stall, but the status is still `.infeasible`.
  - `Automatic()` on the integer version of the model (all columns integer, so x = 1 is an integral feasible point) is routed to `BranchAndBound(engine: Simplex(.primal))`. The root LP comes back infeasible, 0 nodes are processed, and the answer is `.infeasible` with no warning. This happens on 6 of 6 tested instances (k15, k52, k117, k96, k34, k46). `BranchAndBound(engine: Simplex(.dual))` answers optimal on the same instances.
- **The documented mitigations work only for a user who applies them:**
  - Checking the ray (README risk 1) exposes the failure.
  - `Portfolio([Simplex(.primal), Simplex(.dual)])` returned the dual method's optimum in 3 of 3 runs.
  - `Conditioned(Simplex(.primal))` reports nothing: its basis estimate is 9.8e7, under the 1e8 warning threshold, and every finding is `info` (dense column).

## Why it is not documented

- Defect 8 says this answer class is fixed.
- Defect 9 is about κ above 1e11 and about answers that stay `optimal`.
- Risk 1 is a generic disclosure.
- Nothing says that the primal method, or what calls it, can return `.infeasible` on a feasible model, or that running out of the fragile budget gives `.infeasible`.

## Severity

Critical on the scale: this is a false conclusive `.infeasible` on a feasible model. It starts at κ 2.3e8, and the default `Automatic()` facade reaches it on integer models.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V035 -c release                      # Build complete
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 one 15
  instance k15: n 11, D spans 1e-7.0, kappa1(A) 1.499e+09; x = 1: maxViolation rows 0.000e+00 bounds 0.000e+00;
    reverse-order residual 3.331e-16, Kahan residual 2.776e-16; dense solve dist-from-1 2.211e-08, in bounds: true
  kappa1 of the geometrically scaled matrix: 2.123e+09
  Simplex(.primal) default [iters 79, phase1 79]: infeasible dist-from-1 9.000e+00 last-iterate violation rows 3.414e-07
    ray farkas margin -1.890e-07 (rounding scale 5.545e-15) warnings []
  Simplex(.primal, presolve: false, scaling: .none): infeasible, margin -1.876e-07, warnings []
  Simplex(.primal, .dantzig, .denseLU): infeasible, margin -1.876e-07, warnings []
  Simplex(.primal, tolerances 1e-9) [iters 19]: optimal obj 11.884433257169114 dist 2.090e-08 (ill-conditioned warning)
  Simplex(.dual) default: optimal obj 11.884433256540472 dist 2.084e-08 (ill-conditioned warning, estimate 2.1e9)
  InteriorPoint(): infeasible (warning: stalled ... the simplex finished from its last iterate)
  Automatic(): optimal obj 11.884433256540472
  Conditioned(Simplex(.primal)): infeasible; report basisConditionEstimate 9.831e+07, worst severity info (denseColumn only)
  Portfolio([primal, dual]) x3: optimal, winner Simplex(.dual)
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 trace 15
  k15 Simplex(.primal): infeasible iterations 79 phase1 79 refactorizations 64; fragile-pivot limit m+50 = 61
  maxIterations 15: row violation 6.032e-05, refactorizations 1
  maxIterations 20: 3.642e-07, refactorizations 4 | 25: 3.414e-07, 9 | 50: 3.642e-07, 34 | 75: 3.414e-07, 59 | 79: 3.414e-07, 63
  maxIterations 80: infeasible, iterations 79, refactorizations 64
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V035 sweep 200     # raw output: A2-02-contract-V035-sweep.txt
  BUCKET a <1e8: instances 20, Simplex(.primal) false .infeasible 0 (ray certifies in 0), Simplex(.dual) optimal 20
  BUCKET b 1e8-1e9: instances 25, false .infeasible 9 (ray certifies in 0), dual optimal 25
  BUCKET c 1e9-1e10: instances 26, false .infeasible 20 (ray certifies in 0), dual optimal 26
  BUCKET d 1e10-1e11: instances 26, false .infeasible 6, dual optimal 26
  BUCKET e 1e11-1e12: instances 18, false .infeasible 4, dual optimal 18
  BUCKET f >=1e12: instances 85, false .infeasible 15, dual optimal 85
  lowest: k52 n 7 kappa 2.340e+08 x=1 viol 0 primal infeasible, ray margin -5.820e-07, warnings 0; dual optimal
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 mip 15,52,117,96,34,46,0,1,2
  MIP k15 kappa 1.499e+09 x=1 integral, violation 0: Automatic() infeasible warnings []; B&B(Simplex(.dual)) optimal 11.884433256540472
  MIP k52 kappa 2.340e+08: Automatic() infeasible warnings []; B&B(Simplex(.dual)) optimal 8.191818034646953
  (k117, k96, k34, k46 likewise: Automatic() infeasible, B&B with dual engine optimal)
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 mip 15,52
  BranchAndBound(engine: Simplex(.primal)) k15: infeasible, root LP infeasible, root warnings [], nodes 0
  BranchAndBound(engine: Simplex(.primal)) k52: infeasible, root LP infeasible, root warnings [], nodes 0
```

Probe source: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V035/main.swift (the generator is copied from the finder's F2 slot so that instance k is the same LP; every check is computed independently).
