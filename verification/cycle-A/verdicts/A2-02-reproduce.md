# A2-02, sceptic with the REPRODUCE lens (slot V034)

- verdict: **confirmed**
- documented: **false**
- severity: **critical**: a false `.infeasible`, which is a conclusive status, on an LP that is provably feasible. It comes with no warning, and its ray is not a Farkas certificate.
- repository: main @ d9afebe, unchanged. Probe: `verification/probes/cycle-A/Slots/V034/`, with `Exact.swift`, `Instances.swift`, `Modes.swift` and `main.swift`.

## What I did and why it is independent

I did not use the finder's oracle. I copied only the finder's instance generator (seed 900+k, same evaluation order), so that I would get the same bits as k15. My `sum(c)` = 11.884433253052967 matches the finder's number. Every judgement comes from code I wrote for this probe:

- **Feasibility proof.** I wrote my own LU with partial pivoting and formed the explicit inverse R. I evaluated E = I − R·A entry by entry exactly, using Shewchuk expansions with TwoSum and an FMA TwoProd. ‖E‖∞ < 1 proves that A is nonsingular and gives ‖A⁻¹‖∞ ≤ ‖R‖∞/(1−‖E‖∞). I computed the residual δ = b − A·1 exactly. The unique solution then satisfies ‖x* − 1‖∞ ≤ ‖A⁻¹‖∞‖δ‖∞. When that bound is below 9, x* lies strictly inside [−10, 10]ⁿ, which proves the LP feasible. In that case the feasible set is the single point {x*} and the optimum is c·x*.
- **Certificate check.** I evaluated the Farkas value F(y) = Σᵢ(yᵢ>0 ? yᵢ·rlᵢ : yᵢ·ruᵢ) − Σⱼ(zⱼ>0 ? zⱼ·xuⱼ : zⱼ·xlⱼ), with z = Aᵀy, completely in exact expansion arithmetic, so its sign is exact. I took both signs of the returned ray, which removes any dependence on the sign convention. Only F > 0 certifies.
- **Second solution.** x* comes from my LU with iterative refinement using exact residuals. Its exact residual is 1.7e-17.

## (1) The observed behaviour happens

`V034 one 15` (release):
```
finder-k15: n 11, D spans 1e-7.0, sum(c) 11.884433253052967
  my inverse: kappa1 1.499e+09 kappaInf 1.043e+09 kappa2 5.004e+08; ‖I − R·A‖∞ (exact entries) 4.964e-08
  exact ‖b − A·1‖∞ 2.637e-16; rigorous bound ‖x* − 1‖∞ ≤ 6.343e-08 -> FEASIBLE (proven): true
  refined x*: exact residual 1.715e-17, max|x*−1| 1.919e-08, c·x* 11.884433256607089
  Simplex(.primal): infeasible, exact Farkas (better sign) -1.890038194921905e-07 sign -1 [rel. to terms -8.6e-08] -> certifies NOTHING, iters 79 (all phase 1), warnings []
  Simplex(.primal, presolve:false, scaling:.none): infeasible, Farkas -1.876e-07 -> certifies NOTHING, warnings []
  Simplex(.dual) / Simplex() / Automatic(): optimal obj 11.884433256540472 (|obj − c·x*| 6.7e-11), |x − x*| 1.8e-9, warning "ill-conditioned basis, estimate 2.12e9"
  InteriorPoint(): infeasible (crossover ray Farkas -1.890e-07 -> certifies NOTHING); warnings: dense columns, "the interior point stalled ... the simplex finished from its last iterate"
  Conditioned(Simplex(.primal)): infeasible, warnings []; report: "basis condition estimate 9.83e+07; no warnings"
```
The finder reported a Farkas margin of −1.8900381828682925e-07. My exact value agrees to 8 digits. The value is about 1e9 times larger than rounding noise, so the sign is not in doubt.

`V034 grid 15` uses my own grid of 40 configurations. Of 31 primal configurations, 29 return `.infeasible` with no warning and a non-certifying ray (F between −1.88e-7 and −1.89e-7). They cover every factorization (auto, dense, QR), presolve on and off, scaling none, equilibration and geometric, every pricing (Dantzig, devex, steepest edge, partial(3)), and every perturbation mode (off, always, onStall). Only two primal configurations answer `.optimal`, both correctly: feasibility and dual tolerances lowered to 1e-9, and both raised to 1e-6. All 9 dual configurations are optimal and correct. TALLY: primal infeasible 29, primal optimal 2, dual optimal 9.

Code: `Sources/ZTronLPSimplex/SimplexEngine+Primal.swift:697-706`. When phase 1 finds no entering candidate and no weak one, it sets `lastDualRay = farkasRay(from: y)` and returns `.infeasible`. `farkasRay` (lines 584-590) only chooses the better sign and never requires `farkasValue > 0`. Nothing downstream checks the ray: `Simplex.postsolved` only maps it.

## (2) The expected behaviour is correct

The LP is feasible by a rigorous argument: ‖x* − 1‖∞ ≤ 6.3e-8, and every bound is 9 away. By Farkas' lemma no certificate of infeasibility can exist, so no ray could justify the verdict. The correct answer is `.optimal` at x* with objective c·x* = 11.884433256607089. `Simplex(.dual)` and `Automatic()` return that answer to 6.7e-11.

Small oracle nit, which does not affect the finding: the finder's "optimum 11.884433253052967" is c·1, not c·x*. The two differ by 3.6e-9. "Dense solve distance from 1: 2.2e-8" is consistent with my max|x* − 1| = 1.9e-8.

The condition number is genuinely moderate. From the explicit inverse: κ₁ = 1.50e9 (agrees with the finder's DenseLU estimate), κ∞ = 1.04e9, κ₂ = 5.0e8. All are below the README's "about 1e10". They are also well below the Hilbert order 8 that defect 8 calls recovered (κ₂ ≈ 1.5e10, κ₁ ≈ 3.4e10).

## (3) Load and randomness play no part

The engine's RNG has a fixed seed (`SimplexEngine.swift:209`). `V034 det 15 10`, run three times in release and once in debug, gave the same result every time: `infeasible|iters 79|ray 8a2fc91f224fec6d|warn 0`. That held for 10 sequential runs, 16 concurrent runs (self-made load), threads 1, 2 and 8, and time limits of 2 s and 300 s. The debug build is bit-identical, including the same ray hash. Each solve takes about 0.5 ms.

## Breadth: not a single instance

`V034 family` runs the finder's 24 instances against my oracle. All 24 are proven feasible. `Simplex(.primal)` default returns false `.infeasible` with no warning and a non-certifying ray on k15 (κ₁ 1.5e9), k3 (κ₁ 1.3e10), k22 (3.5e13), k5 (1.8e14) and k20 (9.1e14). `Simplex(.dual)` is optimal on all 24.

`V034 fresh 400 7001` uses my own family: xorshift64*, n 6-12, D spanning 1e-5 to 1e-9, c random. All 400 are proven feasible:

| κ₁ (my inverse) | instances | primal false-infeasible | ray certifies | warned | dual false-infeasible | IPM false-infeasible |
|---|---|---|---|---|---|---|
| < 1e8 | 143 | 0 | 0 | 0 | 0 | 0 |
| 1e8 – 1e9 | 78 | 23 | 0 | 0 | 0 | 22 |
| 1e9 – 1e10 | 83 | 57 | 0 | 0 | 0 | 49 |
| 1e10 – 1e11 | 73 | 30 | 0 | 0 | 0 | 34 |
| ≥ 1e11 | 23 | 6 | 0 | 0 | 0 | 7 |

The smallest κ₁ with a false `.infeasible` is 4.4e8 (fresh-s7042). The defect is wider than the finder reported: it starts about an order of magnitude lower, and it reaches the default `InteriorPoint()` as well.

## Documentation

These statements are contradicted:

- README §3 Risk 1: "up to a condition number of about 1e10 the solution is recovered".
- README §4 defect 8, marked fixed: the simplex "takes a small pivot before it concludes 'infeasible'".
- HANDBOOK decision 18, which describes that fix.
- HANDBOOK Contracts: "An `.infeasible` LP result carries a dual ray (a Farkas certificate)". The ray here certifies nothing.
- README §4 defect 9 speaks only of κ above about 1e11, and says the answer then stays `optimal`.

Risk 1's generic heading, "a wrong or failed answer on a model unlike the tested ones", is a general disclaimer, not documentation of this defect. Its mitigation, checking the ray, would catch the bad ray, but the README's κ statement promises the case is safe. The HANDBOOK Testing line ("every infeasible result's dual ray ... checked numerically") is about the test suite's oracle, not a runtime check. I do not count it as violated by itself.

## Side observations (info, not verified further)

1. Outside this finding's κ range, `Simplex(.primal)` default also ends with `noSolution(iterationLimit)` after 50,000 iterations on 11-12-variable instances (k9, k10, k19, k21, k23, κ₁ 4e13 to 6e14). It ends with `numericalFailure("primal feasibility could not be maintained")` on k4 and k8. The dual method is optimal on all of them.
2. **Heads-up on the probe toolchain, not a package defect.** My first `one` mode built `[(String, any SolverStrategy)]` in a `switch` case of top-level code in main.swift (Swift 5 mode, top-level await) and awaited inside the loop. In that version the first `Simplex` elements read **uninitialized existential boxes**. Under `MallocScribble=1` they showed maxIterations −6148914691236517206 (0xAA fill) and an invalid enum raw value of −86. Without scribble, maxIterations was 0, giving `noSolution(iterationLimit)` after 0 iterations. The same code inside a function is correct. The boxes are allocated and initialized in client code, so this looks like a Swift 6.4 miscompile of top-level async code. Guard Malloc did not flag any package write. All results above come from function-scoped code. A copy of the affected main.swift is in `verdicts/A2-02-reproduce-toplevel-main.swift.txt` (build it with the slot's other files). Other probes that build existential arrays and await in a loop at top level could be affected.

## Commands

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V034 -c release            # and: swift build --product V034 (debug)
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V034 one 15
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V034 grid 15
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V034 det 15 10      # x3; and .build/debug/V034 det 15 3
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V034 family
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V034 fresh 400 7001
MallocScribble=1 perl -e 'alarm shift; exec @ARGV' 200 .build/release/V034 one 15   # function-scoped: clean
```
Every run completed with full output, and none hit the alarm (no exit 142). Where the exit status was captured, it was 0.
