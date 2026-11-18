# A2-04, sceptic V040 (lens: reproduce and contract)

- verdict: **confirmed**
- documented: **false**
- severity: **medium**
- finding: "Beyond a condition number of about 1e11 only the objective can be trusted" holds only for the Hilbert family's objective (README.md:408 Risk 1; README.md:461-468 defect 9)

## Reasoning

1. **Independent oracle.** Every LP the probe solves is a square, nonsingular equality system
   A x = b with box bounds, so its only feasible point, and its optimum, is x_exact = A⁻¹b.
   The probe writes every double as its bit pattern. A Python script then rebuilds each LP
   exactly with `fractions.Fraction` and computes x_exact, opt = cᵀx_exact, κ₁ = ‖A‖₁‖A⁻¹‖₁
   and the duals y = A⁻ᵀc, all exactly. The finder's oracle, sum(c) at x = 1, ignores the
   rounding in b. My exact oracle shows that this is off by up to 2e-6 relative at κ₁ 3.6e12
   and up to 3.8e-3 above 1e14. That is small next to the errors measured.
2. **Decisive case: the README's own family, with only the objective changed.** I used
   `InstanceGenerator.hilbert(order: 6...12)` in the two equality forms. The matrix, b,
   bounds and forms are unchanged; the generator's c = H·1 is replaced by a random
   c ∈ [0.5, 1.5]ⁿ. Such an LP still fits the README's description of the family: LPs on the
   Hilbert matrix "whose only optimum is x = (1, …, 1)". Results with each objective:
   - **c = H·1 (the generator's):** orders 9 to 12 give a worst relative objective error of
     7.9e-13. This reproduces the README.
   - **c = Hᵀy, y ∈ [0.5, 1.5] (moderate duals):** worst 1.2e-12.
   - **Random c:** order 9 (κ₁ 1.1e12) gives `.optimal` with errors up to 6.5e-2; for
     example 9.0252 against an exact 9.6328, the same from all five strategies. Order 10
     reaches 3.0e-2, order 11 5.6e-2, and order 12 0.136.

   The identity cᵀx̂ − opt = yᵀ(Ax̂ − b) holds exactly (discrepancy 0) for every answer. With
   c = H·1 the duals are y = 1, so the objective's error is only the sum of the row residuals
   (about 1e-11). With a random c, ‖y‖∞ runs from 6e10 to 3e15, and the same residuals of
   1e-11 to 1e-12 shift the objective by percent. The README's good numbers come from its
   choice of objective, not from the engines.
3. **Generality.** In my own family (A = Q₁·diag(σ)·Q₂ᵀ, random x*, random c), the wrong
   objectives start at κ₁ 1e11-1e12, where 8 of 31 `.optimal` answers are wrong (worst
   5e-6):
   - κ₁ 1e12-1e13: 24 of 34 wrong, worst 2.42;
   - κ₁ 1e13-1e14: 37 of 37, worst 4.65;
   - κ₁ 1e14-1e16: 69 of 69, worst 12.8.

   With c = Aᵀy and moderate y, nothing is wrong at any κ (worst 3.6e-9).
4. **The finder's own 24 instances**, rebuilt bit for bit and run on its 40 configurations,
   checked with the exact oracle:
   - κ₁ ≤ 1e11: 0 wrong (worst 4.5e-8);
   - κ₁ 1e12-1e14: 159 of 167 `.optimal` answers off by more than 1e-6 (the finder said
     165; the 6 extra come from its sum(c) oracle), worst 1.85;
   - κ₁ ≥ 1e14: 244 of 244, worst 3.43.

   Every one of these carries a warning, as the finder said.
5. **Against the contract.** The engines stay within their own tolerance contract:
   - README §4 Results says "Optimal is a statement about tolerances … feasible and dual
     feasible to 1e-7". The wrong answers are feasible to between 1e-9 and 1e-12.
   - The objective's error follows from those residuals and the large duals.

   So the defect is in the documents, not the solver. The defect 9 title, and Risk 1's
   "beyond it only the objective is", tell a user that the objective of an ill-conditioned
   answer can still be trusted. In general it cannot; it holds only when the duals are
   moderate, as they are with c = H·1. Even the narrower body text ("From order 9 of the
   same family … right in its objective to 1e-11") fails for an equality-form member of the
   family as the README itself describes it.
6. **Documented?** No. Nothing documents that the objective can be wrong:
   - Defect 9 says the opposite.
   - README §4 Results speaks of the point, not of the objective.
   - The warning understates the error by orders of magnitude. On hilbert-9-equality-generic1
     it says "the values may be wrong by about 5.79e-07 relative", while the objective is
     6.3e-2 off and the point 1.15 away.
   - The mitigation that Risk 1 offers, cross-checking with another engine, does not catch
     it either: `Simplex()`, `Simplex(.primal)` and `InteriorPoint()` all answer about 9.02
     against 9.633.
7. **Severity: medium.** The false generalisation is in the outside-view README and touches
   a regime that users are told to trust. It is confined to κ beyond about 1e11, it sits in
   a section that already presents the regime as a defect, and almost all such answers carry
   a warning. The solver does not break its tolerance contract. So it is more than a minor
   number mismatch (low), but not a materially false claim about the package's normal
   operation (high).

## Commands and key output

Probe source: `verification/probes/cycle-A/Slots/V040/main.swift`. Oracle:
`verification/cycle-A/A2-04-V040-oracle.py`. The dumps are deterministic: a second Hilbert
run differed in 0 of 490 results, ignoring seconds.

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build --product V040 -c release   # Build complete
S=<scratch dir>; for f in hilbert randsvd finder; do perl -e 'alarm shift; exec @ARGV' 900 .build/release/V040 $f $S/$f.jsonl; done
  family hilbert: 98 instances, 5 strategies, 490 solves, 433 optimal
  family randsvd: 144 instances, 5 strategies, 720 solves, 616 optimal
  family finder: 24 instances, 45 strategies, 1080 solves, 786 optimal
python3 -I ../../cycle-A/A2-04-V040-oracle.py $S/<family>.jsonl
```

Each oracle line gives:
`instances solves optimal | relerr>1e-6 >1e-3 >1e-1 worst | >1e-6 warned (ill-cond) | max|y| max|r| maxboundviol | naive-oracle err | non-optimal`

```
hilbert own(c=H1)  all 1e12-1e13 | 2 10 10 | 0 0 0 7.86e-13 | 0 (0) | 1.0e+00 9.4e-12 0 | 2.3e-18
hilbert own(c=H1)  all >=1e16    | 2 10 10 | 0 0 0 5.61e-13 | 0 (0) | 1.1e+00 1.1e-11 0 | 4.1e-17
hilbert dualmod    all 1e12-1e13 | 6 30 30 | 0 0 0 1.19e-12 | 0 (0) | 1.5e+00 9.4e-12 0
hilbert dualmod    all >=1e16    | 6 30 30 | 0 0 0 1.20e-12 | 0 (0) | 2.3e+00 1.1e-11 0
hilbert generic    all 1e10-1e11 | 6 30 27 | 0 0 0 5.97e-08 | ...                      (order 8: fine)
hilbert generic    all 1e12-1e13 | 6 30 27 | 15 15 0 6.46e-02 | 15 (15) | 6.5e+10 1.1e-11 0 | 1.2e-06
hilbert generic    all 1e13-1e14 | 6 30 15 | 15 15 0 2.95e-02 | 15 (15) | 3.1e+12 3.0e-13 0 | 5.9e-05 | unbounded 12, infeasibleOrUnbounded 3
hilbert generic    all 1e14-1e16 | 6 30 15 | 15 15 0 5.59e-02 | 15 (15) | 5.5e+13 3.5e-12 0 | 4.6e-04 | unbounded 12, infeasibleOrUnbounded 3
hilbert generic    all >=1e16    | 6 30 15 | 15 15 10 1.36e-01 | 15 (15) | 2.9e+15 7.8e-12 0 | 6.5e-03 | unbounded 12, infeasibleOrUnbounded 3
  hilbert-9-equality-generic1 opt 9.632777282: Simplex() 9.0252157, Simplex(.primal) 9.02521565, InteriorPoint() 9.02044407 (rel err 6.3e-2), max|r| 1.1e-11
randsvd generic    all 1e11-1e12 | 9 45 31 | 8 0 0 4.97e-06 | 8 (8)
randsvd generic    all 1e12-1e13 | 9 45 34 | 24 10 10 2.42e+00 | 21 (21) | 4.3e+11 3.4e-09 0 | 4.0e-05
randsvd generic    all 1e13-1e14 | 9 45 37 | 37 37 29 4.65e+00 | 37 (37)
randsvd generic    all 1e14-1e16 | 18 90 69 | 69 69 69 1.28e+01 | 69 (69)
randsvd dualmod    worst over all buckets 3.61e-09, 0 answers off by > 1e-6
finder grid40      1e10-1e11 | 3 120 101 | 0 0 0 4.45e-08
finder grid40      1e12-1e13 | 1 40 24 | 16 12 12 9.07e-01 | 16 (16) | 1.4e+11 | naive 2.0e-06
finder grid40      1e13-1e14 | 5 200 143 | 143 143 137 1.85e+00 | 143 (143) | naive 1.2e-05
finder grid40      1e14-1e16 | 10 400 244 | 244 244 244 3.43e+00 | 244 (244) | naive 3.8e-03
identity check max |(cᵀx̂ − opt) − yᵀr| = 0.0; reported objective vs cᵀx̂ max rel 2.4e-15 (all three families)
```

## Side observations (not part of this verdict; not verified further)

- **Unwarned, with the wrong sign.** On randsvd-n9-p12-s0-generic (κ₁ about 1e12),
  `Simplex()`, `Automatic()` and `Conditioned(Automatic())` return `.optimal` with objective
  −9.109 against an exact 6.405, and **no warning at all**. The point has 3 columns at ±10
  and a row residual of 1.1e-9 relative (within 1e-7). This contradicts defect 9's "The
  answer carries a warning" and Risk 1's mitigation "an ill-conditioned optimal basis is
  reported". The basis then holds row logicals, so its own condition estimate stays low.
  `Simplex(.primal)` on the same LP is right to 6.7e-6, and warns.
- **Wrong statuses on the free form with a random objective.** This LP is feasible and
  bounded, with a unique feasible point. Every simplex strategy answers `.unbounded`,
  without a warning, at orders 10 to 12. `InteriorPoint()` answers
  `.infeasibleOrUnbounded` at every order from 6 (κ₁ 2.9e7) up, where the simplex reaches
  1e-11. README §5's "Every solve at every order ends optimal" holds only for c = H·1.
