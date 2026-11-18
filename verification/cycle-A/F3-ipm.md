# Cycle A, area F3: Interior point, crossover-lite, conditioning analyzer, Conditioned facade

- Cycle: A (claims first)
- Area: F3. Sources/ZTronLPInteriorPoint/{InteriorPoint,IPMWorker}.swift, Sources/ZTronLPSimplex/SimplexEngine+Crossover.swift,
  Sources/ZTronLPConditioning/{ConditioningAnalyzer,ConditioningReport,ConditionedAnalysis}.swift, Sources/ZTronLPOptimizer/Conditioned.swift;
  tests Tests/ZTronLPInteriorPointTests/**, Tests/ZTronLPConditioningTests/**, IllConditioned + Corpus tests in Tests/ZTronLPIntegrationTests/;
  README 2.5 (InteriorPoint), 2.6, 4 defects 7, 9, 10, the Interior point limit, 5 tables.
- Probe slot: verification/probes/cycle-A/Slots/F3 (build `cd verification/probes/cycle-A && swift build --product F3 [-c release]`,
  run `perl -e 'alarm shift; exec @ARGV' <s> .build/<cfg>/F3 <mode> [args]`)
- Package: git main @ d9afebe, Swift 6.4, M3 8 cores, macOS 27
- Method: claims first. Turn README/HANDBOOK/doc-comment claims into checkable properties, falsify each with a probe; audit tests as claims.

## Plan: claims and properties to check (ordered by cost of a failure)

C1  IPM .optimal answers are right: objective = simplex objective / constructed optimum; KKT (primal feasibility abs, dual sign
    conditions, complementarity) of primal/dual/reducedCosts; crossover .lite and .none, presolve on/off, all generator options
    (degenerate, free, range, maximize, scaleSpread). With crossover on: the final basis is optimal (warm simplex 0 pivots).
    [README 2.5 InteriorPoint row, 4 Results limit "feasible and dual feasible to 1e-7", Risk 1]
C2  No infeasible model is ever called .optimal/.unbounded and no unbounded model .optimal/.infeasible. Relative residual test
    (IPMWorker.run: primalResidual = max|rp|/(1+max|b|) <= 1e-8) vs a tiny-but-real infeasibility on a large RHS;
    crossover-lite failure path returns the interior solution as .optimal. [README 2.5, defect 7]
C3  Infeasible / unbounded status distribution: how often .infeasibleOrUnbounded vs .noSolution(.iterationLimit) vs other.
    [README 2.5 "Answers .infeasibleOrUnbounded when it cannot tell", defect 7 "for some models"]
C4  Defect 10 / HANDBOOK 17: crossover .none -> .numericalFailure "stalled" from kappa ~1e6 (Hilbert order 5); default recovers;
    stall handed to simplex (warning "stalled", crossover != nil); thresholds stallCeiling 1e-4, mu<1e-10, worst>1e-6 or 3 stagnant.
    README 5 ill-conditioned table: every IPM solve optimal at orders 3..12, warnings 3/12 at order 5 and 4/12 at order 6.
    Scale-dependence of the absolute mu<1e-10 stall gate.
C5  "It never returns .feasible: a limit or a cancellation gives .noSolution" (README 2.5) - including a stop inside the crossover
    of the stalled path (crossover status returned as is).
C6  Dense columns: >30% nonzeros -> warning text, correct answer, m>300 sparse path. [README 4 Interior point limit]
C7  ConditioningAnalyzer: basisConditionEstimate vs exact 1-norm condition (independent dense inverse in probe), thresholds
    1e8/1e12, wide range 1e6/1e9, dense column 30%, degenerate 30%, memoryBudgetBytes cap 16 m^2, 4000-row cap. [README 2.6]
C8  Conditioned returns the same status/objective/primal/basis as the wrapped engine; numericalFailure -> summary warning event
    before .finished. [README 2.5 Conditioned row, Conditioned.swift doc]
C9  Netlib with IPM (.none and .lite): objectives vs published optima; iteration counts / crossover pivots vs README 5 (gross only).
C10 Limits: maxIterations -> .noSolution(.iterationLimit) with iterations == cap; timeLimit 0; cancellation.
C11 Test audit: weak tolerances, status-only asserts, skips, accepted alternatives that hide the documented property.

## Log (HELD | claim | command | key output, or FAIL | ...)

FAIL | C2 no infeasible model is called .optimal | F3 `tinyinf` (Slots/F3/StatusProbe.swift probeTinyInfeasible) | min x+y, x+y=1e8, x+y=1e8+1: Simplex(.dual) infeasible; all 4 IPM configs (lite/none x presolve on/off) .optimal at x=(5e7,5e7), row violation 0.5; lite warns "crossover-lite ended with infeasible; returning the interior solution". Also B=1e6/delta=1e-2 (viol 5e-3), ineq variant viol 0.77
HELD | C2 infeasibility of order >= ~1e-6 relative is not called optimal | F3 `tinyinf` | B=1e3 any delta and B=1e6 delta>=1: lite -> .infeasible (stalled path, simplex verdict) or .infeasibleOrUnbounded; none -> numericalFailure or .infeasibleOrUnbounded

### Finding A3-01 (provisional): InteriorPoint reports .optimal on an infeasible LP whose infeasibility is small relative to the RHS, and overrides its own crossover's .infeasible verdict
- claim: README 2.5 InteriorPoint row; README 4 Results limit ("Optimal ... feasible and dual feasible to 1e-7"); SolveStatus.optimal doc "An optimal solution was found and proven"
- observed: min x+y s.t. x+y=1e8, x+y=1e8+1, x,y>=0 (infeasible; Simplex(.dual) -> .infeasible). InteriorPoint() and InteriorPoint(crossover: .none), presolve on or off -> .optimal, objective 1e8, x=(5e7,5e7), each row violated by 0.5. With crossover .lite the crossover returns .infeasible and the strategy still returns .optimal with the warning "crossover-lite ended with infeasible; returning the interior solution".
- why wrong: the model has no feasible point; violation 0.5 >> 1e-7; the package's own simplex (inside the same solve) proved infeasibility and the verdict was discarded.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:696-706 (relative residual max|rp|/(1+max|b|) <= 1e-8 accepts an absolute residual of 0.5 at |b|=1e8); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:209-217 (non-optimal crossover -> interior solution returned as .optimal)
- repro: cd verification/probes/cycle-A && swift build --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F3 tinyinf
- documented: no (defect 7 covers only infeasible-vs-unbounded)
HELD | C1 IPM .optimal answers right on constructed LPs (60 inst x 4 configs: lite/none x presolve on/off; degenerate/free/range/max mixes) | F3 `kkt 60 7 60 120` (release; Slots/F3/KKTProbe.swift) | 240/240 optimal; obj err <= 2.9e-8 (none), 1.7e-14 (lite); abs primal viol <= 2.1e-8; dual sign viol <= 8e-10; Lagrangian gap <= 3.2e-8; reported reducedCosts == c - A'y exactly
FAIL | C1 with crossover on, the final basis is optimal | F3 `kkt 60 7 60 120`, `basis`, `basisrow 56 13`, `basisrow 20 18` (Slots/F3/BasisProbe.swift) | 4/60 instances, all with presolve on: warm primal/dual simplex from finalBasis needs 1-5 pivots; basis vertex == returned x (1e-14) but dual infeasible by 2.9..77. No-presolve bases: 0 pivots. Same defect in Simplex(.dual)/(.primal) finalBasis with presolve (shared cause)

### Finding A3-0x (provisional): presolved final bases (IPM crossover and simplex) are not optimal when a singleton row fixes a column at its own bound
- claim: InteriorPoint.Crossover.lite doc "return a vertex with its basis"; InteriorPointAnalysis.crossover "its basis is what branch and bound reuses"; SimplexAnalysis.basis "Reusable as WarmStart.basis"; README 2.2 Presolve postsolve expandBasis maps a basis back
- observed: kkt instance k=56 (28x22): row 13 is 2.737*x18 <= 0 with x18 >= 0 (so x18 fixed at 0 by presolve); reported d_18 = +7.94, dual(row 13) = 0. finalBasis has x18 basic and row 13's logical atUpper, which implies y_13 = +2.9 on an atUpper logical (wrong sign). Warm Simplex from it: 4 pivots (primal), 4 (dual). k=20: -1.2546*x30 >= 0, x30 >= 0, same pattern.
- why wrong: at a column resting on both its own bound and the singleton row's bound, expandBasis always declares the row's bound the active one, without looking at the reduced cost's sign; the basis is primal feasible but not dual feasible, so not the optimal basis of the returned vertex.
- location: Sources/ZTronLPCore/Model/Presolve.swift:432-448 (expandBasis, singletonRow case: `current == .fixed` treated as resting on the tightened bound)
- repro: cd verification/probes/cycle-A && swift build -c release --product F3 && .build/release/F3 kkt 60 7 60 120 ; .build/release/F3 basis ; .build/release/F3 basisrow 56 13
- documented: no
HELD | C2 no infeasible model called .optimal/.unbounded and no unbounded model .optimal/.infeasible (generic infeasibility) | F3 `infunb 60 404` (release; Slots/F3/StatusProbe.swift) | 0 WRONG lines over 60 infeasible + 60 unbounded constructed models x 4 IPM configs, + 3 textbook models
FAIL(doc) | C3 defect 7 "answers .infeasibleOrUnbounded for some models" | F3 `infunb 60 404` | IPM never returned .infeasible or .unbounded: unbounded 60/60 -> .infeasibleOrUnbounded; infeasible 59/60 -> .infeasibleOrUnbounded, 1/60 -> .noSolution(iterationLimit) after 200 iterations (seed 17760892575079156926, mu 4e-8, primal residual 8e-3); textbook infeasible/unbounded/primal+dual infeasible -> .infeasibleOrUnbounded in all 4 configs. Only presolve or the stall->simplex path ever decides.
HELD | C4 README 5 ill-conditioned table, InteriorPoint() column: every solve optimal at orders 3..12, distances (order 8 <= 7.6e-7, 9..12 about 1-3) | F3 `hilbert 3 12` (release; Slots/F3/HilbertProbe.swift) | 40/40 optimal; dist o3 9e-15, o4 5e-13, o5 6e-12, o6 4e-10, o7 4e-8, o8 7.6e-7, o9 1.0, o10 1.44, o11 1.19, o12 3.1
HELD | C4 defect 10 trigger: IPM(crossover:.none) -> numericalFailure "stalled" from kappa1 ~9.4e5 (order 5) | F3 `hilbert 3 12` | numericalFailure at orders 5..12 in 30 of 32 form/order cells; message names the residuals; stall residuals 1.3e-7..2.2e-5 (< stallCeiling 1e-4); default recovers; warning "stalled" present, crossover != nil
FAIL(doc) | C4 defect 10 "the result is .numericalFailure" for crossover .none | F3 `hilbert 3 12`, `hilbert 5 9 1e-6 1` | IPM(none) returns .optimal with no conditioning warning at a point far from the unique optimum: order 5 equalityFree dist 4.5e-3, order 12 covering dist 0.23; objective x1e-6: orders 5..9 covering/packing dist 0.2..0.4 (objective rel err ~2e-9)
FAIL(low) | C4 README 5 "Answers with a warning" column (order 3: 0 of 12, order 4: 0 of 12, order 5: 3 of 12) | F3 `hilbert 3 12` | every IPM() answer from order 4 carries the dense-column warning ("n column(s) have more than 30% nonzeros"), so IPM() alone gives 4 of 4 at orders 4 and 5; only the stall warnings match the table (3 at order 5, 4 at order 6)
FAIL | C4 "the interior point hands a stall to the simplex" / defect 8 fixed (no infeasibleOrUnbounded on ill-conditioned feasible LPs) | F3 `hilbert 3 10 1e6 1`, `illfree 8 1e7 1e6 10`, `illfree 12 1e6 1 30` (release) | Hilbert equalityFree with objective x1e6: InteriorPoint() .infeasibleOrUnbounded at orders 6,7,9,10 (x1e8: 6..10); random 8x8 kappa2=1e7 free columns, costs x1e6: 10/10 .infeasibleOrUnbounded; unscaled costs kappa2=1e6: 3/30, 1e8: 5-11/30. Simplex(.dual) optimal on all. Stall gate: mu<1e-10 absolute while primal residual 2e-4..2.8e1 > stallCeiling -> infeasibleOrUnbounded
FAIL | C2/C4 no false .infeasible from the default IPM | F3 `illone 8 1e10 1 8 0`, `illfree 12 1e9 1 30` (release) | random dense boxed [-10,10] equality LPs, unique interior optimum x=1, witness violation 0: InteriorPoint() .infeasible in 9-17/30 at kappa2=1e9 (m=6..12), 1/30 at 1e8, 2-10/30 at 1e10; also .noSolution(iterationLimit) 2-4/30. Crossover dual ray fails Farkas (-7.9e-8). Simplex(.dual), Automatic, Portfolio optimal. kappa1 exact 2.65e10 (seed 8)
FAIL | C5 README 2.5 "It never returns .feasible: a limit or a cancellation gives .noSolution" | F3 `stallcancel 8 30 30` (release; Slots/F3/StallProbe.swift: Hilbert-8 equality block + 30x30 tied assignment, 68x908) | free run: stalled at 1.1 ms, crossover 141 pivots, optimal 12.606. timeLimit 1.9..2.5 ms: 10 of 31 runs -> .feasible(stoppedBy: .timeLimit), objective 20.606, point feasible (viol 9e-10); limits in phase 1 -> noSolution(timeLimit); cancel-on-stall -> noSolution(cancelled) 5/5
HELD | C6 dense columns: answer right, warning present above 30% | F3 `dense 400 700` (release; Slots/F3/DenseProbe.swift) | 400x700 constructed LP + 1..3 columns at 31/35/90%: all 4 configs optimal, obj err <= 1.4e-9, KKT clean; warning "k column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)" present; 29% none; analyzer .denseColumn warning (m>300) at 31/35/90%, none at 30%
INFO | C6 IPM dense-column count is taken on the presolved problem and only for > 3 kept rows | F3 `dense 400 700` | exactly 30% (120/400) warns with presolve on (rows removed) but not with presolve off; 3-row model with a 100% column: no warning
HELD | C7 basisConditionEstimate vs exact 1-norm condition (independent Gauss-Jordan inverse in probe) | F3 `cond` (release; Slots/F3/CondProbe.swift) | 20 random square bases (m 3..120, kappa2 1e1..1e14), 2 mixed structural/logical bases, 8 netlib optimal bases: estimate/exact in [0.677, 1.001]
HELD | C7 thresholds illConditionedWarning 1e8 / severe 1e12 (strict >), singular -> severe inf; wideRange 1e6 / 1e9 (strict >) | F3 `cond` | diag 1e8 none, 1.0000001e8 warning, 1e12 warning, 1.0000001e12 severe, singular severe; ratio 1e6 none, 1.000001e6 warning, 1e9 warning, 1.000001e9 severe
HELD | C7 memoryBudgetBytes caps the dense factorization at 16 m^2 bytes | F3 `cond` | m=50: budget 39,999 -> overMemoryBudget, 40,000 -> analyzed; m=200: 639,999 / 640,000 likewise; 0 and -5 -> overMemoryBudget
HELD | C8 Conditioned(inner) returns inner's status/objective/primal/basis | F3 `conditioned` (release; Slots/F3/ConditionedProbe.swift) | 36 comparisons (5 netlib x {IPM(), IPM(none), Simplex(.dual), Automatic()}, 10 constructed IPM(), Hilbert 5/8/10 x IPM()/IPM(none)): 0 differences in status/objective/x/basis (only degen2 IPM(none) duals differ by 2.3e-5 run to run: degenerate duals); report's estimate == exact kappa1 within [0.85,1]
HELD | C8 numericalFailure -> report.summary as SolverEvent.warning before the single .finished | F3 `conditioned` | Conditioned(IPM(none)) on Hilbert 8: summary warning event index 13, finished index 14, finished count 1
INFO | C8 Conditioned around an engine without a basis cannot see ill-conditioning | F3 `conditioned` | Conditioned(IPM(none)) on Hilbert 8 (numericalFailure "stalled"): warning event / summary reads "matrix coefficients span 0.0667 to 1 (ratio 15); no warnings", basisAnalysis .noBasis
HELD | C9 netlib with IPM: published optima, iterations and crossover pivots of README 5 | F3 `netlib 3` (release; Slots/F3/NetlibProbe.swift) | 13/13 optimal both modes; lite rel err <= 1.3e-11; IPM iterations 10,9,8,10,12,12,13,16,12,14,12,17,13 and crossover pivots 1,0,0,6,0,6,4,14,10,0,4,3,127 identical to README 5; total 0.033 s (README 0.038 s); warm primal/dual from crossover basis 0/0 on all 13
FAIL | C1 README 4 Results "feasible ... to 1e-7" for InteriorPoint(crossover: .none) | F3 `viol beaconfd` (release) | beaconfd: .optimal, row 51 (equality, rhs 0) activity 2.62e-5; reported primalResidual 3.91e-12 (scaled working problem); scagr7 2.8e-7, adlittle 6.5e-8. Test NetlibInteriorPointTests.convergesWithinFortyIterations allows 1e-5*(1+|obj|) = 0.34 on beaconfd (23 on scagr7)
HELD | C10 limits: maxIterations 0/1/3/10 -> .noSolution(iterationLimit) with iterations == cap, no primal; timeLimit 0 and -1 -> .noSolution(timeLimit); presolve-solved model returns optimal regardless | F3 `limits` (release) | as stated
FAIL | C2 (A3-01 through every route) no infeasible model is called .optimal | F3 `tinyfacades 40` (release; Slots/F3/StatusProbe.swift probeTinyFacades) | x+y=1e8 & x+y=1e8+1: InteriorPoint() and Conditioned(InteriorPoint()) .optimal obj 100000000.49999917, row viol 0.5000008, also after an MPS write/read round trip; Simplex(.dual) and Automatic() .infeasible; Portfolio([Simplex(.dual), InteriorPoint()]) .infeasible 40/40 (simplex won)
FAIL | C2/C4 recheck of the false .infeasible rate | F3 `illfree 8 1e9 1 30` (release) | m=8, kappa2=1e9, unique optimum x=1: boxed InteriorPoint() infeasible 16/30, noSolution(iterationLimit) 3/30, optimal 11/30; free-column InteriorPoint() infeasibleOrUnbounded 10/30 (unscaled costs); Simplex(.dual) optimal on all 30
FAIL | C4 recheck defect 10 | F3 `hilbert 5 9 1e-6 1` (release) | IPM(none) .optimal at dist 0.21..0.40 (covering/packing, orders 5..7; objErr 0.8e-9..2.7e-9, viol 0) with nwarn=1 (dense-column only); IPM() dist 5.7e-12..4e-8 on the same models

## Final findings (supersede the provisional A3-01 / A3-0x blocks above; numbered by severity)

### A3-01 [critical, wrong-result, reproduced] InteriorPoint returns .optimal on an infeasible LP and overrides its own crossover's .infeasible verdict
- claim: README 2.5 InteriorPoint row ("Answers .infeasibleOrUnbounded when it cannot tell the two apart"); README 4 Limits "Results" ("'Optimal' ... feasible and dual feasible to 1e-7"); Sources/ZTronLPCore/Solve/Status.swift:5 ("An optimal solution was found and proven").
- observed: min x+y s.t. x+y = 1e8, x+y = 1e8+1, x,y >= 0 (infeasible by 1). InteriorPoint() -> .optimal, objective 100000000.49999917, x = (50000000.25, 50000000.25), each row violated by 0.5. The same with crossover .none, presolve on or off, after an MPS round trip, and through Conditioned(InteriorPoint()). With crossover .lite the crossover itself ends .infeasible and the strategy still returns .optimal with the warning "crossover-lite ended with infeasible; returning the interior solution". Simplex(.dual) and Automatic() -> .infeasible. Also B=1e6, delta=1e-2 (violation 5e-3) and an inequality variant (x+2y <= B, x+2y >= B+delta) with violation 0.77. Portfolio([Simplex(.dual), InteriorPoint()]) answered .infeasible 40/40 because the simplex won.
- why wrong: no feasible point exists. 0.5 is 5e6 times the stated 1e-7. The right-hand sides are exact in double precision (ulp(1e8) = 1.5e-8), so this is not rounding. The simplex run inside the same solve proved infeasibility, and its verdict was replaced by a success status.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:696 and 704 (primalResidual = max|rp| / (1+max|b|) <= ipmResidual 1e-8 accepts an absolute residual of 0.5 at |b| = 1e8); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:209-217 (any non-optimal crossover result, .infeasible included, falls back to the interior solution with status .optimal).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 tinyfacades 40 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 tinyinf
- evidence: "CompiledLP InteriorPoint(): optimal obj 100000000.49999917 x [50000000.24999958, 50000000.24999958] viol (bounds: 0.0, rows: 0.5000008344650269)"; "CompiledLP Simplex(.dual): infeasible"; "Conditioned(InteriorPoint()): optimal ... rows: 0.5000008344650269"
- documented: no. Defect 7 covers only infeasible-vs-unbounded indecision.

### A3-02 [critical, wrong-result, reproduced] Default InteriorPoint() answers .infeasible on feasible bounded LPs at condition 1e8..1e10, with a ray that is not a Farkas certificate
- claim: README 3 Risk 1 ("up to a condition number of about 1e10 the solution is recovered"); README 4 defect 8 (fixed: "takes a small pivot before it concludes 'infeasible' ... the interior point hands a stall to the simplex"); InteriorPoint.swift:149-152 ("That decides nothing about the problem ... a vertex, or a certificate"); test theInteriorPointDoesNotMistakeAStallForInfeasibility.
- observed: 6x6 dense equality LP A x = A*1, columns boxed [-10,10], unique optimum x = 1 (witness violation 0), exact kappa1(A) = 1.64e8. InteriorPoint() -> .infeasible. The IPM stalls (8 iterations, primal residual 1.58e-6, mu 1.56e-11), and the crossover's primal simplex declares phase-1 infeasibility after 57 pivots. Its dual ray's Farkas value is -9.94e-7 (wrong sign). InteriorPoint(crossover: .none) -> numericalFailure. Simplex(.dual), Automatic() and Portfolio -> optimal, distance 2.55e-9. Rates over 30 seeds (boxed, m=8, kappa2=1e9): infeasible 16, noSolution(iterationLimit) 3, optimal 11. Other cells: kappa2=1e9 9/30 (m=6), 17/30 (m=12); kappa2=1e8 1/30; kappa2=1e10 2..10/30. Hilbert order 9 with rhs x1e6 is also .infeasible. Simplex(.primal) alone gives the same false verdict on the illone model (shared cause in the F2 area).
- why wrong: x = 1 satisfies every row and bound exactly, and an optimum exists. .infeasible is therefore a false verdict with an invalid certificate, inside the condition range README says is recovered.
- location: Sources/ZTronLPInteriorPoint/InteriorPoint.swift:148-171 (the stall path returns the crossover's status unchecked); InteriorPoint.swift:67-69 (crossoverSimplex = Simplex(.primal, presolve: false, scaling: .none)); Sources/ZTronLPSimplex/SimplexEngine+Primal.swift:697-705 (phase 1 "no improving direction" -> lastDualRay = farkasRay(from: y); return .infeasible, with no check of the ray's Farkas value).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 illone 6 1e8 1 0 0 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 illfree 8 1e9 1 30
- evidence: "InteriorPoint(): infeasible dist 1.10e+01 ipm-it 8 pres 1.58e-06 mu 1.56e-11 xover infeasible it 57 xover dualRay farkas -9.94e-07"; "Simplex(.dual): optimal dist 2.55e-09"; "Automatic(): optimal dist 2.55e-09"; tally "boxed IPM() infeasible: 16, boxed IPM() noSolution(iterationLimit): 3, boxed IPM() optimal: 11"
- documented: no. Defect 8 and Risk 1 say the opposite.

### A3-03 [high, wrong-result, reproduced] .infeasibleOrUnbounded on feasible bounded ill-conditioned LPs (the defect-8 answer class, documented as fixed)
- claim: README 4 defect 8 ("Fixed in this version ... infeasibleOrUnbounded from the interior point ... the interior point hands a stall to the simplex"); README 5 note under the ill-conditioned table; IPMWorker.swift:721-726 comment ("calling the problem infeasible would be wrong").
- observed: Hilbert order 6, equalities with free columns, objective x1e8, unique optimum x = 1 (witness violation 0). InteriorPoint(), InteriorPoint(crossover: .none) and presolve off all return .infeasibleOrUnbounded after 13 iterations: primal residual 5.35e-2, dual 4.2e-12, mu 3.38e-11, no crossover. Simplex(.dual), Simplex(.primal) and Automatic() -> optimal, distance 5.8e-10. With objective x1e6: orders 6, 7, 9, 10. With x1e8: orders 6..10. Random 8x8 free-column systems at kappa2=1e7 with costs x1e6: 10/10. Unscaled costs: kappa2=1e6 3/30, kappa2=1e8 5..11/30, kappa2=1e9 (m=8) 10/30. A well-conditioned LP at objective x1e8 is solved (objscale: 60/60).
- why wrong: the models are feasible with a unique optimum, so "infeasible or unbounded" is false. This is exactly the stall the defect-8 fix says is now handed to the simplex. The mu < 1e-10 gate is absolute, so it fires early when costs are large or the residual is slow. Anything above stallCeiling 1e-4 is then classified without the simplex.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:720-731 (absolute `mu < 1e-10`, then `worst > stallCeiling` (1e-4, line 866) -> .infeasibleOrUnbounded); InteriorPoint.swift:146-147 (returned without a simplex).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 hone 6 equalityFree 1e8 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 10 1e6 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 illfree 8 1e7 1e6 10
- evidence: "InteriorPoint(): infeasibleOrUnbounded dist nan obj - 0.000 s ipm-it 13 pres 5.35e-02 dres 4.20e-12 mu 3.38e-11 xover nil"; "Simplex(.dual): optimal dist 5.79e-10"
- documented: described wrongly. Defect 8 says this answer class is fixed for the interior point.

### A3-04 [medium, contract-violation, reproduced] InteriorPoint returns .feasible(stoppedBy: .timeLimit) when a limit lands in the stalled path's crossover
- claim: README 2.5 InteriorPoint row: "It never returns .feasible: a limit or a cancellation gives .noSolution."
- observed: the model is 68x908 (a Hilbert-8 equality block plus a 30x30 assignment with tied costs). Unlimited, it stalls at 1.1 ms, and the crossover finishes (141 pivots, optimal 12.606). With timeLimit 1.9..2.5 ms, 10 of 31 runs return .feasible(stoppedBy: .timeLimit) at objective 20.606 with a feasible point (violation 9e-10). Limits that land in the IPM give .noSolution(timeLimit). Cancellation at the stall gives .noSolution(cancelled), 5/5.
- why wrong: the documented contract excludes .feasible for this strategy, so code written against it meets a status the docs say cannot occur. The point itself is feasible but not optimal.
- location: Sources/ZTronLPInteriorPoint/InteriorPoint.swift:163-171 (the stalled path returns the crossover's SimplexAnalysis base as is) with Sources/ZTronLPSimplex/SimplexEngine.swift:95-107 (a stopped simplex with a primal-feasible iterate reports .feasible(stoppedBy:)).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 stallcancel 8 30 30 (timing-dependent; repeated, 10 of 31 runs in the 1.9..2.5 ms window)
- evidence: "timeLimit 2.x ms: feasible(stoppedBy: timeLimit) obj 20.606, viol 9e-10" in 10/31 runs; free run "stalled 1.1 ms, crossover 141 pivots, optimal 12.606"
- documented: no

### A3-05 [medium, doc-claim-false, reproduced] InteriorPoint(crossover: .none) .optimal points violate rows by up to 2.6e-5 while reporting primalResidual 3.9e-12
- claim: README 4 Limits "Results": "feasible and dual feasible to 1e-7"; InteriorPointAnalysis.primalResidual is reported as the solve's residual.
- observed: on beaconfd the result is .optimal, but row 51 (an equality with rhs 0) has activity 2.62e-5 (maxViolation rows 2.62e-5, max |rhs| 1.89e3), and the reported primalResidual is 3.91e-12. scagr7 violates by 2.8e-7. adlittle's 6.5e-8 is within tolerance. Every objective matches its published optimum.
- why wrong: 2.6e-5 is 260 times the stated 1e-7. The reported residual is measured on the scaled, presolved working problem relative to 1+max|b|, so it hides the violation in the original rows. The test meant to catch this allows 1e-5*(1+|obj|), which is 0.34 on beaconfd and 23 on scagr7.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:696-706 (the scaled relative residual is the only acceptance test, with no unscaled check after postsolve); InteriorPoint.swift:198-202 (crossover .none returns the interior point as is); Tests/ZTronLPInteriorPointTests/InteriorPointTests.swift:42.
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 viol beaconfd && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 netlib 3
- evidence: "beaconfd IPM(none): optimal maxViolation bounds 0.00e+00 rows 2.62e-05; worst row 51 bounds [0.0, 0.0] activity 2.6164713080145674e-05; max |rhs| 1.89e+03; reported primalResidual 3.91e-12"
- documented: no

### A3-06 [medium, doc-claim-false, reproduced] Defect 10 described wrongly: InteriorPoint(crossover: .none) also returns .optimal far from the unique optimum at condition ~1e6, with no warning
- claim: README 4 defect 10 ("from a condition number of about 1e6 on a dense system its residuals stall above the tolerance and the result is .numericalFailure"); defect 9 ("The answer carries a warning that the optimal basis is ill-conditioned", for condition > 1e11 only).
- observed: Hilbert order 5 (kappa1 9.4e5), equalities with free columns, unscaled: IPM(none) -> .optimal at distance 4.52e-3 from x = 1 (objective error 4e-18, row violation 1.4e-8). IPM() gets 5.8e-12. With objective x1e-6, covering and packing at orders 5..7: .optimal at distance 0.21..0.40, relative objective error 0.8e-9..2.7e-9, violation 0. At order 12, covering, unscaled: distance 0.23. The only warning is the dense-column one. There is no conditioning warning and no basis to analyze (Conditioned then reports "no warnings", see the overflow).
- why wrong: at condition ~1e6 the docs promise the solution (README 5: 6e-12 at order 5 for every engine) or .numericalFailure. Here a success status comes with a point 4.5e-3..0.4 from the only optimum, and nothing in the result says so. The acceptance test scales the dual residual by 1+max|c| and the gap by 1+|pobj|, so with small costs it is absolute.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:697-698 and 704 (dual residual and gap relative to 1+max|c| and 1+|pobj|); InteriorPoint.swift:198-202 (crossover .none: the interior point is returned with no conditioning check).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 5 9 1e-6 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 12
- evidence: "order 5 kappa1 9.44e+05 covering IPM(none): optimal it=7 dist=3.98e-01 objErr=7.75e-10 ... nwarn=1 viol=0.00e+00/0.00e+00"; "order 5 kappa1 9.44e+05 equalityFree IPM(none): optimal it=5 dist=4.52e-03 objErr=4.18e-18 ... viol=0.00e+00/1.36e-08"; "equalityFree IPM(): optimal it=5 dist=5.77e-12"
- documented: described wrongly. Defect 10 says the result is .numericalFailure.

### A3-07 [medium, wrong-result, reproduced] Presolved final bases (IPM crossover and simplex) are not optimal when a singleton row pins a column at its own bound
- claim: the InteriorPoint.Crossover.lite doc ("return a vertex with its basis"); the InteriorPointAnalysis.crossover doc ("its basis is what branch and bound reuses"); SimplexAnalysis.basis ("Reusable as WarmStart.basis"); README 2.2 (postsolve maps the basis back).
- observed: in instance k=56 of `kkt 60 7 60 120` (28x22), row 13 is 2.737*x18 <= 0 with x18 >= 0. Presolve removes the row and fixes x18 = 0. The reported d18 is +7.94 and dual(row 13) is 0. InteriorPoint().finalBasis has x18 basic and row 13's logical atUpper. With x18 basic, y13 must be +2.9 on an at-upper <= row, which is the wrong sign. The basis vertex equals the returned x to 1e-14 but is dual infeasible by 2.9..77. Warm primal and dual simplex from it need 1..5 pivots on 4/60 instances, while every no-presolve basis needs 0. Simplex(.dual) and Simplex(.primal) with presolve return the same bases (shared cause).
- why wrong: a basis returned as the optimal basis of the returned vertex must be dual feasible. This one is not, so warm starts and branch-and-bound reuse start from a non-optimal basis.
- location: Sources/ZTronLPCore/Model/Presolve.swift:432-448 (expandBasis, singletonRow case: when the column is at the tightened bound or .fixed, it becomes basic and the row's logical nonbasic, without consulting the reduced cost's sign).
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 kkt 60 7 60 120 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 basis && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 basisrow 56 13
- evidence: "row 13: a[18] = 2.736836914997054; column bounds [0.0, inf] kept: false x* = 0.0"; "basis status col 18: basic; returned x 0.0; reported d 7.935870598638149"; "row 13 logical status atUpper, reported dual 0.0"; basisCheck "dviol" 2.9..77
- documented: no

### A3-08 [medium, test-integrity, code-reading-only] The interior-point tests cannot catch A3-01, A3-02, A3-03, A3-05 or A3-06
- claim: tests as claims: IllConditionedTests.theInteriorPointDoesNotMistakeAStallForInfeasibility ("without it the result is a numerical failure that says what happened"); InteriorPointTests.infeasibleAndUnboundedAreReportedWithoutLooping; NetlibInteriorPointTests.convergesWithinFortyIterations.
- observed:
  (1) IllConditionedTests.swift:145-146 accepts `.optimal` from InteriorPoint(crossover: .none) without checking the point, so the 0.2..0.4 distances of A3-06 pass.
  (2) Every IllConditioned test uses only the Hilbert family with rhs = H*1 and unit-scale costs, so A3-02 (random condition 1e8..1e10) and A3-03 (scaled costs) are never exercised.
  (3) InteriorPointTests.swift:168 accepts .noSolution(.iterationLimit) and .infeasible. At :169, `iterations <= 200` is vacuous because 200 is the default maxIterations, so a run to the cap passes. No test uses an infeasible model with a large rhs (A3-01).
  (4) InteriorPointTests.swift:42 allows a violation of 1e-5*(1+|obj|) against the README's 1e-7 (A3-05).
- why wrong: each test names a property it does not check; the documented failure mode can occur and the test still passes.
- location: Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:131-151; Tests/ZTronLPInteriorPointTests/InteriorPointTests.swift:42, 165-174.
- repro: read the cited lines. The behaviours they let through are reproduced by the A3-01/02/03/05/06 repros. The tests themselves were not run.
- evidence: IllConditionedTests.swift:145-146 "case .optimal: break"; InteriorPointTests.swift:169 "#expect(first.iterations <= 200)"; :42 "violation.rows <= 1e-5 * (1 + abs(objective))"
- documented: no

### A3-09 [low, doc-claim-false, reproduced] Defect 7 understates: the interior point itself never returns .infeasible or .unbounded
- claim: README 4 defect 7 ("it answers .infeasibleOrUnbounded for some models").
- observed: 60 infeasible and 60 unbounded constructed models x 4 configurations, plus 3 textbook models. Unbounded 60/60 and textbook -> .infeasibleOrUnbounded. Infeasible 59/60 -> .infeasibleOrUnbounded, and 1/60 -> .noSolution(.iterationLimit) after 200 iterations (mu 4e-8, primal residual 8e-3). Never .infeasible or .unbounded, never a certificate. Only presolve or the stall->simplex path ever decides.
- why wrong: "for some models" implies the method usually tells the two apart. It never does: the worker has no other outcome.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:712-731 (.infeasibleOrUnbounded is the only failure verdict); InteriorPoint.swift:146-147.
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 infunb 60 404
- evidence: "unbounded <cfg> infeasibleOrUnbounded: 60" for each config; "infeasible <cfg> noSolution(iterationLimit): 1 e.g. seed 17760892575079156926 ... iters 200 ... pres 8e-3"
- documented: described wrongly ("for some models")

### A3-10 [low, doc-claim-false, reproduced] README 5 "Answers with a warning" column omits the dense-column warning every InteriorPoint() answer carries from order 4
- claim: README 5 ill-conditioned table (order 4 "0 of 12", order 5 "3 of 12", order 6 "4 of 12"; "The warnings at orders 5 and 6 are the interior point's").
- observed: from order 4, every InteriorPoint() answer carries "n column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)". IPM() alone gives 4 of 4 at orders 4..7. Only the stall warnings match the table.
- why wrong: the column under-counts the warnings a user sees.
- location: README.md:611-622 against Sources/ZTronLPInteriorPoint/IPMWorker.swift:638-642.
- repro: cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 12
- evidence: "order 5: IPM() answers with a warning: 4 of 4"
- documented: the table itself is the claim

## Overflow
- IPM dense-column count is taken on the presolved scaled problem and skipped at <= 3 kept rows (IPMWorker.swift:124-128): exactly 30% warns with presolve on, not off; a 3-row model with a 100% column gets no warning.
- Conditioned around a basis-less result (IPM(none) numericalFailure on Hilbert 8) reports "matrix coefficients span 0.0667 to 1 (ratio 15); no warnings", so it cannot see the ill-conditioning that caused the failure.
- When the converged path returns the interior point after a failed crossover (A3-01), finalBasis is that failed crossover's basis (InteriorPoint.swift:305 with 209-221; code reading).
- Simplex(.primal) runs 50,000 pivots (noSolution(iterationLimit)) on 7x7 Hilbert with rhs x1e6 and on illone seed 8 at kappa2=1e10, and the IPM stall path inherits this (F2 area).
- degen2 InteriorPoint(crossover: .none) duals differ by 2.3e-5 between identical runs (degenerate duals, not bitwise reproducible).
- 1 of 60 infeasible constructed models (seed 17760892575079156926) ends noSolution(iterationLimit) at 200 iterations rather than being classified; the test accepts that outcome.
- Facades on the A3-01 model: Automatic() routes to the simplex (.infeasible); Portfolio([Simplex(.dual), InteriorPoint()]) gave .infeasible 40/40 (simplex won); Conditioned(InteriorPoint()) passes the false .optimal through.
JSON written: F3-ipm.json
