# A2-03 — sceptic verdict (lens: reproduce and contract)

- **verdict:** confirmed
- **documented:** false
- **severity:** critical (the finder rated it medium; see "Severity" below)
- **probe:** verification/probes/cycle-A/Slots/V037/ (Gen.swift copies the finder's instance generator so that the seeds give the same LPs and nothing else; Oracle.swift, Vertex.swift, NoRefine.swift, Cross.swift are mine)

## Independent oracle

- **Optimum by weak duality** (V037/Oracle.swift `certify`). From the constructed (x, y) I recompute d = c − Aᵀy (compensated sums). I check that every nonzero multiplier sits on a finite bound of the right side, and compare D = c0 + Σ y_i·b_i + Σ d_j·bound_j with P = c0 + cᵀx. Seed 1273: P = D = −307388095.1768796, gap 0, x feasible to 3.5e−17 relative. On all 800 instances of both sweeps the certificate is valid (0 invalid). The generator's objective is not used, and neither is CompiledLP.maxViolation.
- **Violations recomputed** with Neumaier summation, absolute and relative to max(1, Σ|a_ij x_j|, |bound|).
- **Vertex of the returned basis computed independently** (V037/Vertex.swift). The basic system [A −I]_B is equilibrated, solved by GEPP and refined 3× with double-double residuals; duals come from Bᵀy = c_B. This separates "wrong basis" from "right basis, wrongly evaluated".
- **Other engines.** InteriorPoint(), InteriorPoint(scaling: .none), Simplex(), Simplex(.primal), Automatic(), and dense LU / automatic factorization with scaling .none all reach −307388095.1768796 on seed 1273.

## Reproduction

`V037 one 1273 7 10 0 0 4 ...` (|a| in [2.213e−08, 1.012e+06]):

- `primal/qr/pretrue/none` and `primal/qr/prefalse/none` give **.optimal**, objective 39435549.925776005 (relative error 1.128).
  - My row violation is 496.2 on **equality** row 6: activity −27.67 against rl = ru = −523.91, so 0.947 relative.
  - The only warning: "the solution is optimal within the tolerances, but a violation of 8186.179927012323 remains ... the problem is ill-conditioned".
- `primal/qr/*/geo`, `primal/dense/pretrue/none`, `primal/auto/pretrue/none` and `dual/qr/pretrue/none` all reach the certified optimum.

## Mechanism (sharper than the finder's account)

`V037 norefine 1273 7 10 0 0 4 qr primal` runs SimplexEngine.solve on the same LP with no presolve and no scaling.

- **With `cutoff: 1e300`.** This skips refine() (SimplexEngine+Driver.swift:462), and runPrimal ignores the cutoff.
  - 64 iterations, **.optimal at the certified optimum** −307388095.1768796, row violation 8.9e−16, dual violation 0.
  - The basis has 4 logicals; equilibrated κ₁ is 10.6.
  - A fresh `SparseQRBasis.refactor` of that correct basis throws `singular(positions: [], rows: [])`. `DenseLUBasis` also throws `singular(positions: [0, 3], ...)`.
- **Without the cutoff** (refine runs): 114 = 64 + 50 iterations (50 is the pass budget max(50, 2m)). The result is the bad answer above, on the **all-logical basis** (7/7 logicals, κ = 1).
  - My independent vertex of that basis: primal violation 496.2 at row 6, objective 39435549.93.
  - Its largest reduced-cost sign violation is **8186.179927012323**, exactly the engine's "remaining" value. So the warned number is the slack basis's dual violation.

What happens, step by step:

1. refine() refactorizes at entry (SimplexEngine+Driver.swift:584-588).
2. refactorize() (SimplexEngine.swift:460-481) judges the unscaled optimal basis singular. Sparse QR's probe test reports no positions, so refactorize falls back to `installSlackBasis()`; dense LU swaps in logicals instead. No warning is issued.
3. `start` is captured after this (line 611) and measured: primal 496, dual 8186.
4. The 50-pivot pass ends without an optimal basis.
5. The fallback branch (lines 648-671) "restores" `start`, which is the replaced basis, and the run returns `conclude(.optimal)` (line 465).

The same holds on every other failing instance I checked. In each case refine() turned a correct answer into a wrong one:

| seed, config | without refine | with refine |
|---|---|---|
| 1383, primal/qr | right, 11 logicals, κ_eq 120 | 16/16 logicals, row violation 6018 (1.40 relative), objective error 0.17 |
| 1182, primal/qr | right, 12 logicals, κ_eq 893 | 23/23 logicals, row violation 1002 (0.75 relative) |
| 1377, primal/dense | right, 1 logical | 2 logicals, violation 3.5e−4 |
| 1017, dual/dense | right, 1 logical | 2 logicals, violation 2.6e−3 |

## Sweeps (my oracle; same seeds and grid as the finder)

**`V037 sweep 400 1000 4`**: 20800 solves.

- .optimal answers whose own warning reports a remaining violation > 1e−6: **27**. This matches the finder.
  - 25 of them are wrong by my oracle (relative violation > 1e−6 or objective error > 1e−6). All 25 carry that warning, and all 25 are scaling .none.
  - The other 2 (seed 1287, dual/auto|dense/pretrue/none, "78 remains") are primal feasible, with objective error 1.8e−8.
- False .infeasible: **9** (seeds 1276, 1295×4, 1314×2, 1378×2). All are scaling .none, have **no warning**, and a feasible point is known (violation ≤ 1.1e−19 relative).
  - Farkas margins of the rays: −1.2e−4 (×4), −3.5e−4 (×2), −1.3e−13, −1.4e−17, and +2.3e−13. The last is rounding noise; none can certify, since the LP is feasible.
- Equilibration and geometric (default) scaling: 0 bad answers. Every other non-optimal status (numericalFailure, noSolution(iterationLimit), feasible(iterationLimit)) is honest.

**`V037 sweep 400 1000 3`**: 20800 solves, 0 wrong, 0 false verdicts, 8 numericalFailure, 2 noSolution(iterationLimit). This matches the finder's statement that spread ≤ 10^±3 is clean.

## Contract

- **README §4, Limits, Results:** "'Optimal' ... feasible and dual feasible to 1e-7". The violations here are 3.5e−4 to 7.5e3 absolute (up to 1.4 relative); the dual violations are up to 8186. **Violated.**
- **refine() doc comment and HANDBOOK 16:** "The pass can only replace an optimal answer by a better one ... returns to the basis it started from". **False.** The pass replaced a correct optimal answer by an infeasible one, because "the basis it started from" is taken after a refactorization that can swap the basis.
- **The warning misstates the situation.** "Optimal within the tolerances" is untrue (8186 ≫ 1e−7). "Ill-conditioned" is untrue for the returned basis (κ₁ = 1); the failure lies in the unscaled factorization's singularity test.
- **README §2.5, Simplex:** "a ray when the answer is .infeasible". The 9 rays do not certify.
- **README Risk 1** ("wrong answer on a model unlike the tested ones; read the warnings") is generic. Defect 9 speaks only of feasible answers at κ > 1e11, and is contradicted here, since the bases are well conditioned.
- **Nothing documents** that scaling: .none on badly scaled data can yield an infeasible .optimal or a false .infeasible.
- **The input is not misuse.** `ScalingMode.none` is a public, documented option, and the LP is valid and finite. **It is not within a tolerance and not by design:** the engine itself measures the violation (its number equals mine to all digits) and discards it.
- **Location.** The finder's location (fallback branch, lines 649-671) is where the measured violation is dropped. The root cause also includes lines 584-588 and 611: `start` is captured after a refactorization that can silently replace the optimal basis.

## Severity

**Critical** on the given scale: ".optimal ... with a wrong value or an infeasible point; a false .infeasible". Both occur, and the false .infeasible verdicts come with no warning.

What limits the likelihood, but not the class:

- It needs the non-default scaling: .none on data with |a| spread over about 13–14 decades (row and column scales 10^±4).
- The .optimal cases carry a (misleading) warning.
- The default and the other scaling modes are right on all 400 instances.

The finder's medium ("wrong status on edge cases") understates it. A whole Simplex solve returns a confidently wrong vertex that its own main loop had right.

## Side observation (not A2-03, not investigated further)

In a **release** build, an array `[(String, any SolverStrategy)]` built inside main.swift's top-level async code held zeroed strategy values: Simplex() reported engineName "Simplex(.primal)" and maxIterations Optional(0); InteriorPoint() reported "InteriorPoint(crossover: .none)". Solves then returned noSolution(iterationLimit) at iteration 0.

The same code in a **debug** build, or the same array built inside a function in release, is right (`V037 anomaly`, debug vs release). This is probably a toolchain optimisation issue in the probe, not the package. Flagged for the orchestrator only.

## Commands and key output

```
cd verification/probes/cycle-A && swift build --product V037 -c release
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V037 one 1273 7 10 0 0 4 primal/qr/pretrue/none primal/qr/prefalse/none primal/dense/pretrue/none primal/auto/pretrue/none dual/qr/pretrue/none primal/qr/pretrue/geo cross
  ORACLE weak duality: P = -307388095.1768796, D = -307388095.1768796, gap 0, constructed x viol rel 3.509e-17 -> valid
  SOLVE primal/qr/pretrue/none: optimal obj 39435549.925776005 (relerr 1.128e+00) | my viol rows abs 4.962e+02 rel 9.472e-01 [worst row 6: activity -27.6657 in [-523.9086, -523.9086]] | iters 114 | warnings ["the solution is optimal within the tolerances, but a violation of 8186.179927012323 remains ..."]
  SOLVE primal/qr/pretrue/geo: optimal obj -307388095.1768795 (relerr 1.9e-16), viol 0
  CROSS InteriorPoint() / InteriorPoint(scaling: .none) / Simplex() / Simplex(.primal) / Automatic(): optimal -307388095.1768796 (from Cross.swift)
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V037 vertex 1273 7 10 0 0 4 primal/qr/prefalse/none primal/qr/prefalse/geo
  primal/qr/prefalse/none: duals of this basis: largest reduced-cost sign violation 8186.179927012323 at column 8; basis 7 basic (7 logical), kappa 1; vertex violation 4.962e+02 at row 6; objective 39435549.925776005
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V037 norefine 1273 7 10 0 0 4 qr primal
  cutoff 1e300 (refine skipped): optimal obj -307388095.1768796, viol 8.9e-16, iters 64; fresh SparseQRBasis.refactor: threw singular(positions: [], rows: []); DenseLUBasis: threw singular(positions: [0, 3], rows: [5, 3]); basis 4 logical, kappa_eq 1.06e+01
  no cutoff (refine runs): optimal obj 39435549.925776005, viol 4.962e+02, iters 114; basis 7/7 logical
V037 norefine {1377 5 13 0 0 4 dense primal | 1017 7 26 0 0 4 dense dual | 1383 16 9 0 0 4 qr primal | 1182 23 24 0 1 4 qr primal}
  refine skipped: right (relerr <= 4.3e-14) in every case; with refine: wrong (viol 3.5e-4 / 2.6e-3 / 6.0e3 / 1.0e3), iterations +50
perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V037 sweep 400 1000 4
  solves 20800, invalid certificates 0; bad answers by scaling: ["none": 25, "false-verdict/none": 9]
  optimal answers whose own warning reports a remaining violation > 1e-6: 27; wrong by my oracle: 25, without any warning: 0; false infeasible/unbounded: 9 (all warnings [])
perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V037 sweep 400 1000 3
  solves 20800; 0 wrong, 0 false verdicts; numericalFailure 8, noSolution(iterationLimit) 2
```
