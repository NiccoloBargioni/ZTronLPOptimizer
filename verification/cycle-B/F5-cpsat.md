# Cycle B (oracles first) - area F5: CP-SAT

- Cycle: B (oracles first, independent of cycle A)
- Area: F5, CP-SAT (Sources/ZTronLPCPSAT/*, Tests/ZTronLPCPSATTests/**, SATLIB uf50/uuf50, MIPLIB 3 pure-integer)
- Slot: verification/probes/cycle-B/Slots/F5 (product F5)
- Package: git main @ d9afebe, Swift 6.4, Apple M3 8 cores, macOS 27
- Method: derive the contract first (clause satisfaction, exhaustive enumeration, rejection of the
  documented out-of-domain inputs, monotonicity / determinism), build independent oracles in the
  slot, attack the public API, then read the code path behind each disagreement. README §4 and
  HANDBOOK "Known gaps" are read only after results exist, to mark documented findings.

## Plan (claims / properties to check)

1. SAT: every uf50-218 instance -> SAT, model checked against every clause by an independent checker.
2. UNSAT: every uuf50-218 instance -> UNSAT; cross-check a sample with an independent DPLL in the probe.
3. Random 3-SAT near ratio 4.26 (n small): CP-SAT verdict vs brute force / independent DPLL, fixed seeds.
4. Optimization vs exhaustive enumeration: random small pure-integer models (binary + general integer,
   negative bounds, equality rows, ranged rows, infeasible), lpPropagator on/off, deterministic/parallel,
   minimize/maximize.
5. Input domain: decimal data scaled by 10^k (k<=6) accepted and solved exactly; 10^-7 data, continuous
   columns, infinite bounds rejected with documented error (no trap, no silent rounding).
6. Overflow: bounds / scaled coefficients near 2^53, row activities near +-2^61 handled or rejected.
7. Objective above 10^4 (README fixed gap): is a non-optimal answer labelled .optimal?
8. Limits: time limit honoured; deterministic: true reproducible; portfolio workers agree; reported
   result is the best one found; monotonicity under tighter limits.
9. MIPLIB 3 pure-integer instances: optima of README §5 with default configuration (release).
10. Invariance: row/column permutation, redundant rows, min/max reformulation give same optimum.
11. Test-suite integrity of Tests/ZTronLPCPSATTests (tests that cannot fail, wrong references, skips).

## Log

HELD | uf50-218: all 1000 instances SAT, model satisfies every raw clause (own DIMACS parser + own CNF->LP + own clause check), configs par4-lp, det-lp, det-nolp, par8-seed, det-never | F5 sat .corpora/satlib/uf50-218 0 1000 <ci> (ci=2,0,1,4,6), release | "1000 instances, 0 failures" x5
HELD | uuf50-218: all 1000 instances reported .infeasible, same 5 configs | F5 unsat .corpora/satlib/uuf50-218 0 1000 <ci> | "1000 instances, 0 failures" x5
HELD | oracle check: own DPLL says UNSAT on uuf50 001-100 (sorted) and SAT with verified model on uf50 001-100 | F5 dpll <dir> 0 100 | "sat 0 unsat 100", "sat 100 unsat 0"
HELD | random 3-SAT n=8..40, ratio 3.8..4.8, 400 formulas, 7 configs round-robin: no wrong SAT/UNSAT, every SAT model checked; DPLL oracle validated by brute force on 126 formulas (n<=18) | F5 rand3sat 11 400 8 40 | "sat 286, unsat 114, bruteChecked 126, failures 0"
HELD | exhaustive enumeration, 40 random pure-integer models (n<=6, general ints with negative bounds, eq/range/half-integral rhs rows, row data /10^0..6, empty rows, infeasible ones), 7 configs | F5 enum 1 40 | "280 solves, 13 infeasible models, 0 failures"
HELD | enumeration, 600 more models (seed 2) x 7 configs, integral costs | F5 enum 2 600 6 0 | "4200 solves, 220 infeasible models, 0 failures"
HELD | enumeration, binaries with big coefficients (x100..x1e5), 400 models x 7 configs | F5 enum 3 400 6 0 1 1 | "2800 solves, 158 infeasible, 0 failures"
HELD | random 3-SAT n=40..90 near threshold, 300 formulas | F5 rand3sat 12 300 40 90 | "sat 171, unsat 129, failures 0"
FAIL | decimal costs (10^-ec, ec<=6) give .optimal with non-optimal value | F5 enum 4 400 6 6 | "109 failures", all "NON-OPTIMAL .optimal", e.g. #4 box-only model: got -4.5e-05, true -8.8e-05, bound -8.8e-05
FAIL | gap: min sum j*1e-6 x_j s.t. sum x_j >= 1 returns the WORST solution as .optimal in every config incl. default CPSAT() | F5 gap | n=50: "optimal obj 5e-05 bound 0.0" (true 1e-06)
HELD | integral costs below 1e4 exact (c0=9000) | F5 gap (G5) | "optimal 9001 bound 9001"
INFO | integral costs above 1e4 inexact (documented regime): G1 hint 1e5+5 -> optimal 100004 vs 100000; G4 c0=1e6 -> optimal 1000020 vs 1000001 | F5 gap
HELD | rejection: coef 1e-7 and 1.0000001 -> unsupported; continuous column, [0,inf), (-inf,0], free -> unsupported | F5 domain (D2,D3) | "unsupported: ..."
FAIL | coef 1e-10 / 5e-10 silently zeroed: a x0 + a x1 >= a, min x0+x1 -> optimal 0 (true 1) | F5 domain (D2) | "optimal obj=0.0 x=[0,0]"
FAIL | out-of-domain coefficient 1.0000000009 (and 2^48+0.1875) -> SolverError.internalInconsistency instead of unsupported | F5 domain (D2b, D5a) | "internal inconsistency: CP-SAT returned a point that violates row c1"
FAIL | integer bounds/rhs >= 2^50 relaxed outward by 1..4 -> .optimal with infeasible point | F5 domain (D4d,D4e,D4f,D4g',D4h,D7c) | x in [2^52+1,2^52+10], min x -> "optimal 4503599627370493"
FAIL | large fractional coefficient snapped (4 ulp) -> false optimum | F5 domain (D5b) | (2^49+.375)(x+y)-(2^50+.75)z=0, max x+y+z -> "optimal 0" (true 3, (1,1,1) exactly feasible)
HELD | empty model, empty infeasible row, fractional fixed bound, fractional box, parity-infeasible equality, xl>xu, duplicate rows | F5 domain (D6a-g) | all as expected
HELD | time limit honoured on pigeonhole 12/11 (132 binaries): 1.0 s -> 1.002 s (default, det), 2.0 s -> 2.002 s (8 workers nolp), 0 and -5 s -> immediate noSolution(timeLimit); exactly one .finished | F5 limits (L1) | "noSolution(timeLimit) wall 1.002 s, finished events 1"
HELD | cancellation after 0.3 s returns noSolution(cancelled) 1 ms after cancel | F5 limits (L2) | "returned 0.001 s after cancel"
HELD | deterministic: true reproducible (3 runs x 3 configs x 2 knapsacks): identical status/obj/x/conflicts/decisions and identical event sequences; workers: 8 with deterministic -> 1 worker | F5 limits (L3) | "identical results true, identical events true"
HELD | portfolio (8 workers) reports the best announced incumbent; point re-checked (bound/row violation 0, integral) on 6 knapsacks x 2 limits | F5 limits (L4) | "-> OK | boundViol 0.0 rowViol 0.0"
HELD | deterministic run monotone in time limit (0.1..3 s) | F5 limits (L5) | obj 2215 at every limit
HELD | memory budget 1 B / 50 kB -> noSolution(memoryBudget) with LP-propagator warning; 2 MB -> runs to time limit | F5 limits (L6)
INFO | rejected model emits .finished(status: .numericalFailure("unsupported: ...")) before throwing (status label misleading, contract of one .finished holds) | F5 limits (L7)
HELD | MIPLIB 3 pure-integer, default CPSAT(), release, 120 s limit: p0033 3089, enigma 0, stein27 18, lseu 1120, mod008 307, p0201 7615, stein45 30, all .optimal, each point re-checked (bound/row violation 0, integral, objective recomputed) | F5 miplib .corpora/miplib3/<f>.mps default 120 | stein45 29.41 s (README 18.62 s; machine load ~20)
HELD | mixed MIPLIB flugpl, egout, misc03 rejected with unsupported (continuous column) | F5 miplib ... default | "unsupported: CP-SAT accepts pure integer models"
HELD (documented, README §4 defect 1) | CPSAT(lpPropagator: false) does not close mod008 / p0201 in 60 s | F5 miplib .corpora/miplib3/{mod008,p0201}.mps nolp 60 | mod008 feasible(timeLimit) 321, p0201 feasible(timeLimit) 7735 (HANDBOOK range 7675-7725; fewer conflicts under load)
FAIL | minimal repros, all with default CPSAT() unless noted | F5 min | M1 bounds viol 4.0; M2b rows viol 4.0; M3 optimal 0 vs 3; M4 optimal 0 vs 1; M5 5e-05 vs 1e-06; M6 (1 var, no rows) optimal 1e-06 vs 5e-05; M7/M7b internalInconsistency; M8 2^53-1 rejected; M8b x=2^53-1 > ub 2^53-5 (viol 4.0)

## Findings (complete)

### B5-01 (critical, wrong-result) Integer bounds and row bounds of magnitude >= 2^50 are widened by 1-4 units; .optimal with an infeasible point
- claim: README §2.5 CPSAT row and §4 "Limits by design": CP-SAT accepts bounds and scaled coefficients below 2^53 and works in exact integer arithmetic (CPModel.swift header: "exact Int64 arithmetic"; "Root domains, rounded inward to integers").
- observed: x in [2^52+1, 2^52+10], min x -> .optimal x = 4503599627370493 = 2^52-3 (CompiledLP.maxViolation bounds = 4.0). x in [2^50+3, 2^50+8] -> x = 2^50+2 (viol 1). x - y = 2^52+1 -> x = 2^52-3, y = 0 (rows viol 4.0). x in [0, 2^53-5], max x -> 2^53-1 (viol 4). max x s.t. x <= 2^50+5 (CPSAT(deterministic: true)) -> x = 2^50+6. Bounds +-2^52 in 127x-125y>=1 -> y = -(2^52+4).
- why wrong: the data are exact integers, exactly representable, inside the accepted range; the returned point violates them, and the safety net CPSAT.violation (relative 1e-6) cannot see it.
- location: Sources/ZTronLPCPSAT/CPModel.swift:117-119 (snapTolerance = max(1e-9, 4 ulp)) used as `(xl - tol).rounded(.up)` / `(xu + tol).rounded(.down)` at CPModel.swift:173-174, rhs at :335 and :347, LPRelaxation.swift:95,:99. For |v| >= 2^50, 4 ulp >= 1, so an integral bound moves outward by floor(4 ulp) (1, 2 or 4).
- repro: cd verification/probes/cycle-B && swift build --product F5 -c release && .build/release/F5 min   (lines M1, M1b, M2b, M8b); .build/release/F5 domain (D4d-D4h, D7c, D7d)
- documented: no (README says bounds below 2^53 are accepted; nothing says they may be widened)

### B5-02 (critical, wrong-result) Data that no power of 10 up to 1e6 makes integral (or whose scaling exceeds 2^53) is silently rounded instead of rejected: wrong .optimal, or internalInconsistency
- claim: README §2.5 CPSAT row: "Throws .unsupported for ... data that no power of 10 up to 1e6 makes integral, bounds or scaled coefficients of magnitude 2^53 or more"; §4 Limits: data must become integral when multiplied by a power of 10 up to 10^6.
- observed: (2^49+0.375)x + (2^49+0.375)y - (2^50+0.75)z = 0 over binaries, max x+y+z -> .optimal 0 at (0,0,0), but (1,1,1) satisfies the row exactly (maxViolation 0) with objective 3. 1e-10 x0 + 1e-10 x1 >= 1e-10, min x0+x1 -> .optimal 0 (coefficients zeroed). max (2^49+0.5)x -> objective 562949953421313 (cost rounded). x - 1.0000000009 y >= 0 (y = 1e6) and (2^48+0.1875)x - 2^48 y <= 0 -> SolverError.internalInconsistency ("never caused by user data") instead of .unsupported.
- location: CPModel.swift:122-139 integralScale with snapTolerance (absolute 1e-9 floor and 4-ulp term) accepts at scale 1 values whose fraction is <= 1e-9 or <= 4 ulp; :300-306 then rounds them. The 0.375 needs scale 1000 -> 5.6e17 >= 2^53 -> should be rejected per README.
- repro: .build/release/F5 min (M3, M4, M7, M7b); .build/release/F5 domain (D2, D2b, D5a-D5d)
- documented: no; CPModel.swift comment calls the 4-ulp snap a guard against "noise", README promises rejection.

### B5-03 (high, doc-claim-false / wrong-result) With decimal costs and |objective| < 1, CP-SAT stops at an incumbent up to 1e-4 away (absolute) and reports .optimal: answers 50x off
- claim: CPSAT doc comment (CPSAT.swift:101-104): "Objective values are multiples of a fixed step (1 for integral costs), so this is an exact proof whenever 1e-4·|objective| is smaller than that step"; same comment: "within the MIP gap of §6.5 (relative 1e-4, absolute 1e-6)". README risk 10: inexact only "on large objective values", mitigation "keep objective values below 10^4". README §2.5/§4 accept data scaled by up to 10^6.
- observed: max 1e-6*x, x in [0,50] (one column, no row) -> .optimal 1e-06, bound 5e-05 (true 5e-05), CPSAT() and CPSAT(deterministic: true). min sum_{j=1..50} j*1e-6 x_j s.t. sum x_j >= 1 -> .optimal 5e-05 (the worst feasible choice), bound 0 (true 1e-06) in every configuration incl. CPSAT(). 1e-6 knapsack -> .optimal 1.3e-05 (det nolp) / 2.3e-05 (workers 4) vs 2.4e-05. Enumeration with costs /10^ec (ec<=6): 109 of 2800 solves .optimal non-optimal.
- why wrong: step 1e-6, |objective| <= 5e-5, so 1e-4·|objective| <= 5e-9 < step: the doc comment promises an exact proof. The stop rule is diff <= max(1e-6, 1e-4·max(1,|incumbent|)) = 1e-4 absolute for |incumbent| <= 1, i.e. 100 steps of 1e-6; the effective absolute gap is 100x the "absolute 1e-6" the comment names. Shrinking the objective (the README's mitigation) makes it worse. SolutionAnalysis.bound doc "equals objectiveValue when optimal" is also violated (bound 5e-05 vs objective 1e-06).
- location: Sources/ZTronLPCPSAT/Portfolio.swift:107-113 (checkGap: allowed = max(absoluteGap, relativeGap * max(1, |reportedObjective(best)|))); claim at Sources/ZTronLPCPSAT/CPSAT.swift:99-104.
- repro: .build/release/F5 min (M5, M5b, M6, M6b, M6c); .build/release/F5 gap (G2); .build/release/F5 enum 4 400 6 6
- documented: partly. README risk 10 gives the formula max(1e-6, 1e-4·max(1,|incumbent|)) but describes the trigger as large objective values (>= 10^4) with integral costs and recommends keeping objectives below 10^4; the CPSAT API doc states exactness for exactly these models. Trigger misdescribed, impact worse than "low to medium".

### B5-04 (high, hang / limit-not-honoured) Root propagation of two parallel rows over a wide domain runs ~1.7·U bound changes inside one propagate() call: time limit, cancellation and memory budget ignored, RSS grows to 10+ GB
- claim: CPSAT doc (CPSAT.swift:76-79): "timeLimit and task cancellation end the search with the best incumbent ... or with .noSolution(stoppedBy:)"; memoryBudgetBytes bounds learned clauses (rule L7); CPSearch.swift:9-12: "the loop calls gate.tick() once per propagation round, and forces a full check ... at every restart and every 10,000 propagations"; README §5 cancellation latency worst 4.43 ms for CPSAT.
- observed: min x s.t. 652x - 552y = -1505, x,y integer in [0, 1e9] (infeasible: gcd 4 does not divide 1505), timeLimit 2 s: CPSAT(), CPSAT(deterministic: true), CPSAT(lpPropagator:false, deterministic:true) all still running at 40 s (alarm, exit 142), max RSS 12.7 GB / 10.7 GB / 7.2 GB. memoryBudgetBytes = 100 MB: still running at 15 s, RSS 10.2 GB. Cancel after 0.5 s (deterministic): no return within 3.5 s, RSS 7.3 GB. With 8 default workers the cooperative pool is saturated and even the cancelling task cannot run. Smaller U terminates with .infeasible after 1.69·U propagations and ~150 B per propagation (U=1e7: 16.9M propagations, 0.93 s, 1.49 GB).
- why wrong: valid accepted model (bounds < 2^53, activities tiny); the limits must be honoured whatever the model; memory must stay under the budget.
- location: Sources/ZTronLPCPSAT/CPWorker.swift:651-663 (propagate(): `while true` to a fixed point with no gate tick, no propagation-count or memory check); each step of propagateLinear (CPWorker.swift:785-807) tightens by slack/a ~ 1 unit and interns a new bound literal / trail entry. The only checks are in CPSearch.swift search loop (gate.tick() once per propagate() call, check every 10,000 propagations between calls).
- repro: cd verification/probes/cycle-B && swift build --product F5 -c release && /usr/bin/time -l perl -e 'alarm shift; exec @ARGV' 40 .build/release/F5 pingpong 652 552 -1505 1e9 default 2   (also cfg det, detnolp; 8th arg = memory budget bytes); scaling: pingpong 652 552 -1505 1e7 detnolp 2 -> "infeasible wall 0.93 s, propagations 16932512", 1.49 GB. Cancellation: .build/release/F5 pingcancel (deterministic worker).
- documented: no (README risk 3 says a hard model ends .feasible/.noSolution at the limit; §5 reports CP-SAT cancellation worst 4.43 ms).
- B5-04 simpler repro (no rounding): x - y >= 1 and x - y <= 0, x,y in [0,U], CPSAT(deterministic: true), timeLimit 1 s: U=1e7 -> infeasible after 2e7 propagations, 0.60 s, 1.61 GB RSS; U=1e9 -> still running at 8 s (exit 142), 6.7 GB RSS. Command: .build/release/F5 strip 1e9
HELD | Diophantine oracle (extended Euclid): min x s.t. a x - b y = c, x,y in [0,U], U in {1e3,1e6,1e9,1e12} (bisection path), configs default/det-lp/par4-nolp: 150 models, 103 exact optimal, rest correctly infeasible, 0 failures (15 infeasible models with U>=1e8 skipped: B5-04) | F5 dioph 150 3 | "0 failures"
HELD | invariance on 40 medium models (n 20-40, general ints, mixed rows, objective <1e4): column+row permutation, min<->max flip, per-row scaling by 1e-3..1e3, duplicated and doubled rows: same optimum with CPSAT() and det-lp | F5 invariance 40 7 | "40 models, 0 failures"
- correction B5-03 location: claim is at Sources/ZTronLPCPSAT/CPSAT.swift:85-88 (not 99-104); stop rule Portfolio.swift:105-113 (allowed at :109).

### B5-05 (low, doc-claim-false) Bounds of magnitude 2^53-4 .. 2^53-1 are rejected, though README rejects only "magnitude 2^53 or more"
- claim: README §2.5 CPSAT row ("bounds or scaled coefficients of magnitude 2^53 or more" throw) and §4 Limits ("bounds and scaled coefficients below 2^53").
- observed: x in [0, 2^53-1] -> SolverError.unsupported "the bounds of column x1 are too large for exact integer arithmetic"; x in [-(2^53-1), 2^53-1] likewise. (x in [0, 2^53-5] is accepted but widened to 2^53-1, see B5-01.)
- location: CPModel.swift:173-178: hi = (xu + 4 ulp).rounded(.down) reaches 2^53+3 before the |hi| < 2^53 guard.
- repro: .build/release/F5 min (M8); .build/release/F5 domain (D4a, D4b)
- documented: README states the opposite threshold.

### B5-06 (low, test-integrity, code reading) SATLIB tests are disabled, not reported as a known issue, when the corpus is missing
- claim: HANDBOOK "Testing": "tests that need a missing instance report a known issue instead of failing".
- observed: Tests/ZTronLPCPSATTests/SATTests.swift:16,35,52 use @Test(.enabled(if: !Corpora.satlib(...).isEmpty, ...)) -> skipped; only the MIPLIB corpus tests (Tests/ZTronLPIntegrationTests/CorpusTests.swift:115) use withKnownIssue.
- repro: grep -n "enabled(if" Tests/ZTronLPCPSATTests/SATTests.swift
- documented: no.

INFO | NaN row upper bound in a hand-built CompiledLP is silently ignored (row dropped): optimal -2 at (1,1) | F5 domain (D6h)
INFO | D7a/M2 default-config results with objective ~1e15-2e18 stop far from optimum (documented regime: objective > 1e4)
HELD | SPECIFICATION-v0.2 statement about the current LP-worker size estimate (8·m·m or 96·nonzeros) matches LPRelaxation.swift engineBytes | code reading
- line corrections: B5-02 rounding at CPModel.swift:302 (rows) and :366 (objective), noise comment CPModel.swift:113-116, internalInconsistency thrown at CPSAT.swift:286-290; B5-04 row sides added at CPModel.swift:326-352.

DONE | final structured result written to verification/cycle-B/F5-cpsat.json (6 findings: B5-01..B5-06)
