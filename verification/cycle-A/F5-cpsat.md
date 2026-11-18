# Cycle A, area F5: CP-SAT

- Cycle: A (claims first), finder for F5
- Area: CP-SAT (Sources/ZTronLPCPSAT/*, Tests/ZTronLPCPSATTests/**, SATLIB uf50/uuf50, pure-integer MIPLIB 3)
- Slot: verification/probes/cycle-A/Slots/F5 (build: `swift build --product F5 [-c release]`)
- Method: list the package's own claims (README §2.5, §3 risks 3/8/10, §4 defect 1 and CP-SAT limits, §5 CP-SAT table, HANDBOOK, doc comments in CPSAT.swift/CPModel.swift/Portfolio.swift/CPSearch.swift/LPRelaxation.swift), then try to falsify each with an executable probe or targeted test run.
- Repo: git main @ d9afebe, read-only.

## Plan (claims / properties to check, by cost of failure)

1. SAT/UNSAT: every uf50-218 instance SAT with a model checked against every clause; every uuf50-218 UNSAT (sample cross-checked by an independent DPLL in the probe); random 3-SAT near threshold vs independent DPLL; lpPropagator on/off, deterministic/parallel.
2. Optimization vs exhaustive enumeration on small pure-integer models (binary + general integer, negative bounds, equality/range rows, maximize, infeasible), lpPropagator on/off, deterministic/parallel.
3. Input domain (CPSAT.swift doc, README §2.5, §4 CP-SAT limits): scaling by 10^k up to 1e6 accepted and exact; 1e7 rejected with `.unsupported`; continuous columns / infinite bounds rejected; bounds and scaled coefficients near 2^53 and activities near +-2^61 handled or rejected, no trap, no silent rounding, no overflow.
4. Gap claim (README risk 10, CPSAT.swift doc): proof exact for integral costs below 1e4; check behaviour above (and with objective constant, scaled costs, maximize).
5. Limits and determinism (README risk 8, CPSAT doc): timeLimit honoured; deterministic:true reproducible (result + events); portfolio returns the best incumbent; winningWorker meaning; bound semantics (`bound` == objective when optimal).
6. MIPLIB 3 pure-integer optima (README §5 CP-SAT table, release build, default config) and lpPropagator:false defect 1 description.
7. Test-suite integrity of Tests/ZTronLPCPSATTests (status-only assertions, loose tolerances, silent skips).

## Log
HELD | 1e-6 scaled data accepted and solved exactly (1e-6x+2e-6y>=5e-6, min x+y -> 3) | F5 domain (D1) | optimal obj=3 in det/par/detnolp
HELD | 1e-7 coefficient rejected with .unsupported | F5 domain (D2) | THROW unsupported "no power of 10 up to 1e6 makes integral"
HELD | continuous column / infinite integer bound rejected with .unsupported | F5 domain (D4a, D4b) | THROW unsupported (continuous / unbounded)
FAIL | coefficient 1e-10 (no power of 10 <=1e6 makes it integral) should be .unsupported | F5 domain (D3) | THROW internal inconsistency: CP-SAT returned a point that violates row c1 (all configs)
FAIL | column bounds >= 2^50 (README: bounds below 2^53 are in the domain) | F5 domain (D5 2^50+1) | par: optimal obj=1125899906842626 x=2^50+2 > xu=2^50+1; min side -(2^50+2) < xl
OBS  | deterministic:true (lpPropagator default true) climbs one step per incumbent when the model has no linear row (bounds only) | F5 domain (D5 2^49+1 det) | feasible(timeLimit) obj=2598083 after 20 s, par solves at once
FAIL | column bounds 2^51+1, 2^52+1 handled exactly (README §2.5: only >= 2^53 rejected) | F5_ONLY=D5 F5_LIMIT=3 .build/release/F5 domain | par: optimal x=2^51+3 (xu=2^51+1), x=2^52+5 (xu=2^52+1); min side symmetric
FAIL | row rhs 2^50+1..2^52+1 handled exactly | F5_ONLY=D6 ... domain | det: optimal x=2^50+2 for row x<=2^50+1; par: x=2^52+5 for row x<=2^52+1
FAIL | in-domain row a=2^40+1, x<=1e6, a*x<=R=989560464999299968 (exact max 899999) | F5_ONLY=D8 ... domain | det/par: optimal x=900000 (violates by 32; invisible in Double)
HELD | activity near 2^60 accepted and solved; activity > 2^61 rejected .unsupported | F5_ONLY=D7 ... domain | optimal obj=1000; THROW unsupported "activity bounds ... do not fit in Int64"
HELD | fractional rhs with scaled coefficients rounds inward (0.5x+0.25y<=1.3) | F5_ONLY=D9 ... domain | optimal 5, x=[0,5]
OBS  | coefficient 1e15+0.5 accepted at scale 1 (snap 4ulp=0.5), not rejected although scale 10 would exceed 2^53 | F5_ONLY=D10 ... domain | optimal obj=1 (correct by luck here)
OBS  | NaN row upper bound silently treated as no bound | F5_ONLY=D11 ... domain | optimal x=5
HELD(within 1e-7 tol) | xu=2.9999999995 snapped to 3 (5e-10 below integrality) | F5_ONLY=D12,D12b ... domain | optimal x=3
OBS(documented gap) | max 1e-6 x + 3.5, x in [0,7]: optimal label at x=1 (obj 3.500001, true 3.500007) - constant inflates relative gap; README risk 10 advice "keep objective below 1e4" does not cover non-integral costs | F5_ONLY=D13 ... domain | optimal obj=3.500001 bound=3.500007
OBS(documented gap) | max x, x in [0,2^49+1] par: optimal obj=562946402850150 vs true 562949953421313 (rel 6.3e-6 < 1e-4) | F5_ONLY=D5 ... domain | within documented gap
HELD | every uf50-218 instance SAT, model satisfies every clause (independent DIMACS parser; package parser agrees on all 1000) | .build/release/F5 sat uf50-218 {default,det,detnolp,nolp} 0 1000 | ok=1000 bad=0 timeouts=0 in each config, worst 0.010 s
HELD | every uuf50-218 instance UNSAT; all 1000 cross-checked by independent DPLL (default config) | .build/release/F5 sat uuf50-218 default 0 1000 1 (+ det,detnolp,nolp without DPLL) | ok=1000 bad=0 in each config
HELD | random 3-SAT at ratios 3.8..5.0 agrees with independent DPLL (SAT models checked) | F5 rand3sat 40 300 3 {default,det}; rand3sat 12 500 4 w8; rand3sat 75 100 5 default | 0 bad over 1,200 formulas
HELD | optimum vs exhaustive enumeration, 400 random small pure-integer models each (mixed/binary/decimal-scaled/equality/wide, negative bounds, range rows, max/min, c0, infeasible) | F5 enum 400 11 det all; enum 400 12 {detnolp,default,nolp} all | bad=0 (status, objective, point feasibility 1e-9, bound==objective) in 4 configs
HELD | deterministic:true identical result, counters and event sequence across runs and context.threads 1/4/8 (lp on and off) | F5 det {p0033,lseu,enigma} 3 det; F5 det lseu 3 detnolp | identical=true in all four
HELD | README §5 CP-SAT table: 7/7 pure-integer MIPLIB 3 optimal with CPSAT(), each <= 60 s | F5 miplib p0033,enigma,stein27,lseu,mod008,p0201,stein45 default 60 (release) | all optimal = reference, viol=0; stein45 44.2 s at load avg 107 (README 18.6 s on quiet machine)
HELD | knapsack optima with values up to ~1e9 exact (no non-optimal 'optimal' observed) | F5 gap (G1, 60 knapsacks x {default,det}) | exact=120 beyondGap=0
HELD | defect 1 as described: CPSAT(lpPropagator:false) stops at 60 s on mod008 and p0201 with feasible incumbents | F5 miplib mod008,p0201 nolp 60 | mod008 feasible(timeLimit) 324 (README 329, HANDBOOK 316-330); p0201 feasible(timeLimit) 7815 (HANDBOOK 7675-7725; fewer conflicts under load avg ~100)
HELD | wide domains (> 1e6 values, bisection) on 2-variable programs vs exact scan oracle: no point violation, no invalid bound, every non-optimal 'optimal' within the documented 1e-4 relative gap (objectives 1e5..5e7) | F5 wide2 40 {1,2} {default,det,detnolp,nolp} 3000000 | bad=0; det 2, detnolp 18 within-gap only; detnolp 2 stopped at 20 s (documented climbing)
HELD | exact optimum when |objective| < 1e4 (integral costs) on 2-variable programs, domains up to 4000 values | F5 wide2 150 9 {det,detnolp,default} 2000 | bad=0 withinGapNotOptimal=0 (102 feasible, 48 infeasible)
HELD | time limits honoured: stein45 limit 0.5 s default, 2 s nolp; p0201 1 s detnolp | F5 limit stein45 default 0.5; limit stein45 nolp 2; limit p0201 detnolp 1 | overshoot <= 32 ms at load avg 260-600; feasible(timeLimit) each
HELD | mid-size (12-16 vars) vs enumeration, also under tight memory budgets (30 KB..400 KB) and random primal-point hints | F5 mid 60 3 {default,det} 0 0; mid 40 4 default {30000,100000,400000} 1; mid 40 5 det 60000 1 | bad=0 everywhere
HELD | no trap/overflow with coefficients ~2^37, bounds 2^20, activities ~2^58 (rejected .unsupported beyond 2^61) | F5 big | 89/90 runs feasible points (viol 0), 1 noSolution(timeLimit), rest .unsupported
FAIL | wrong optimum, small objective, in documented domain | F5_ONLY=D14,D14c F5_LIMIT=2 .build/release/F5 domain | D14c: optimal obj=8 (true 0), x=[2^52-3, 8], maxViolation bounds=4 rows=4; D14: optimal obj=0 (true 1), maxViolation rows=0.5

### A5-01 (critical) Snap tolerance 4*ulp silently rounds in-domain data >= 2^49: infeasible points and wrong optima labelled .optimal
- claim: README §2.5 CPSAT row and §4 "Limits by design / CP-SAT": data that becomes integral at a power of 10 up to 1e6, "with bounds and scaled coefficients below 2^53 and row activities within +-2^61", is accepted; everything else throws .unsupported. CPModel.swift header: "CP-SAT works on pure integer programs in exact Int64 arithmetic"; "Root domains, rounded inward to integers"; fractional row bounds "round inward". README §4 Results: optimal = feasible to 1e-7.
- observed: (a) x fixed by bounds to 2^52+1, y in [0,10], row x + y <= 2^52+1, maximize y (true optimum 0): every config returns .optimal obj=8, x=[4503599627370493 (=2^52-3), 8]; CompiledLP.maxViolation = bounds 4, rows 4. (b) (1e15+0.5)x + y >= 1e15+1, x binary, y in [0,3], min y (true 1): .optimal obj=0, x=[1,0], maxViolation rows 0.5. (c) max x, x in [0, 2^52+1]: .optimal x=2^52+5 (bound violated by 4); 2^51+1 -> +2; 2^50+1 -> +1 (det). (d) rows x <= 2^50+1 .. 2^52+1 widened likewise; a=2^40+1, a*x <= 989560464999299968 returns x=900000 (exact max 899999).
- why wrong: CPModel.snapTolerance = max(1e-9, 4*ulp(v)) is applied to column bounds (rounded outward by it), row sides (rounded outward), and to integrality of coefficients (a coefficient with fraction 0.5 at 2^49..2^50 counts as integral and is rounded). For |v| >= 2^49 this is 0.5..4 units, so the integer model solved differs from the model given; the final self-check CPSAT.violation uses 1e-6 relative tolerance and cannot see it. All data here is exactly representable, below 2^53, activities far below 2^61, so README says it is handled; it is neither solved exactly nor rejected.
- location: Sources/ZTronLPCPSAT/CPModel.swift:117-119 (snapTolerance), used at :131 (integrality), :173-174 (column bounds), :335 and :347 (row sides); same in LPRelaxation.swift:95,99; check that misses it CPSAT.swift:340-354.
- repro: cd verification/probes/cycle-A && swift build --product F5 -c release && F5_ONLY="D14,D14c,D5,D6,D8" F5_LIMIT=2 .build/release/F5 domain
- documented: not documented (README promises < 2^53; the 4*ulp snap is only in a code comment "so that noise in large data is not mistaken for a fraction").
- confidence: reproduced (det, par, detnolp), expected values derived by hand and confirmed by the package's own maxViolation.

### A5-02 (medium) A coefficient that no power of 10 up to 1e6 makes integral (1e-10) is zeroed instead of rejected; the solve ends in SolverError.internalInconsistency
- claim: README §2.5 CPSAT: "Throws .unsupported for ... data that no power of 10 up to 1e6 makes integral"; CPSAT.solve doc: same. CPSAT.swift run(): a violation found by the final check is "A bug, never a property of the model".
- observed: max x + y s.t. 1e-10 x + y <= 1, x in [0,1e9], y in [0,1] -> THROW "internal inconsistency: CP-SAT returned a point that violates row c1" in det, par and detnolp; 1e-10 x <= 0.05, x in [0,1e9] -> internalInconsistency (par). 1e-7 is correctly rejected with .unsupported; 4e-10 next to 1e-6 is correctly rejected.
- why wrong: integralScale accepts |v*scale - round| <= max(1e-9, 4ulp), so 1e-10 counts as the integer 0 at scale 1 and the term is dropped (`if a == 0 { continue }`); the model solved is a different model and the self-check then blames the solver. The documented outcome is .unsupported.
- location: Sources/ZTronLPCPSAT/CPModel.swift:122-138 (integralScale with snapTolerance) and :302-305 (zero coefficient dropped); LPRelaxation.swift:80 same.
- repro: cd verification/probes/cycle-A && F5_ONLY="D3,D3b" F5_LIMIT=3 .build/release/F5 domain
- documented: the 1e-9 tolerance is in the CPModel.swift header comment only; README states rejection; the internalInconsistency outcome is nowhere documented.
- confidence: reproduced
HELD | cancellation honoured: Task.cancel after 0.3 s returns feasible(cancelled) with incumbent | F5 cancel stein45 default 0.3 5; cancel p0201 nolp 0.3 5 | max latency 1.19 ms, median 0.70 ms (README CPSAT() p99 1.71 ms)
HELD | portfolio returns the best incumbent: last .newIncumbent objective == objectiveValue, incumbents strictly improve, .finished last | F5 winner 100 (part 2: p0033,stein27,lseu,enigma x3, 8 workers) | incumbent-consistency bad=0
FAIL | winningWorker for a feasibility problem names the worker that found the reported solution (CPSATAnalysis doc) | F5 winner 100 | 23/100 uf50 instances with 8 workers: winningWorker=cpsat[0] while the only .newIncumbent (the returned model) came from cpsat[2], [6], [1], ...
HELD | worker configurations agree with enumeration: no clause sharing, 2 workers, RestartPolicy.never, geometric, 8 workers without LP | F5 enum 250 21 {noshare,w2,never,geo,w8nolp} all; mid 30 7 w8nolp 0 1 | bad=0 everywhere
FAIL(doc) | CPSATAnalysis doc "bound ... equals objectiveValue once optimality is proven" / SolutionAnalysis "equals objectiveValue when optimal" | F5_ONLY=D13 domain; F5 big (k=3 det) | .optimal with obj=3.500001 bound=3.500007; .optimal obj=-2.3795703474867405e+17 bound=-2.3796833534450074e+17
TEST-AUDIT | tests named for large data stop below 2^50: dataNearTheLimitsOfInt64IsHandled (activities 1e15), scalingToleratesFloatingPointNoiseOnly (1.2e11), columnBoundsRoundInward (|v|<4), largeButRepresentableDataIsAccepted (1e15) | read Tests/ZTronLPCPSATTests/{AcceptanceTests,LPPropagatorTests}.swift | none can catch A5-01 (2^49..2^53)
FAIL | README: bounds rejected only at magnitude 2^53 or more | F5_ONLY=D15 F5_LIMIT=2 .build/release/F5 domain | xu=2^53-1 and 2^53-4 THROW unsupported "too large"; xu=2^53-5 -> par optimal x=2^53-1 (maxViolation bounds=4 rows=4). Part of A5-01.

### A5-03 (medium, test-integrity) The tests named for large data cannot catch A5-01
- claim: LPPropagatorTests.dataNearTheLimitsOfInt64IsHandled ("push the integer combination towards the limits of Int64 ... the answer does not change and nothing overflows"), AcceptanceTests.scalingToleratesFloatingPointNoiseOnly ("A large value that is not an integer is not mistaken for one"), columnBoundsRoundInward, largeButRepresentableDataIsAccepted.
- observed: the largest data they use: activities 1e15 (< 2^50), a fractional value 1.2e11, bounds below 4. A value 1e15+0.5 IS mistaken for an integer (D14), bounds >= 2^50 round outward (D5), so the properties the names promise fail in the documented domain while the tests pass (baseline 03/04 green).
- location: Tests/ZTronLPCPSATTests/LPPropagatorTests.swift:398-436; AcceptanceTests.swift:88-96, 204-212, 252-262
- repro: read the tests; run `swift test --filter 'ZTronLPCPSATTests.AcceptanceTests'` (passes) against F5 domain D14/D14c/D5 (fail)
- confidence: code-reading of the tests + reproduced counterexamples

### A5-04 (low) winningWorker of a feasibility solve can name a worker whose solution was not returned
- claim: CPSATAnalysis.winningWorker doc (CPSAT.swift ~370): "the one that completed the proof (or, for a feasibility problem, found the solution)".
- observed: CPSAT(workers: 8) on uf50-218 first 100 files: 23 runs where winningWorker = cpsat[0] (or [1]) while the single .newIncumbent event, i.e. the stored and returned model, came from another worker (e.g. uf50-0104: winner 0, source cpsat[6]).
- why: run() takes `prover = reports.first { .exhausted || .satisfied }` in index order; the store kept the first offered model (equal objective 0 rejects later offers), so the two disagree whenever a lower-index worker also finished satisfied.
- location: Sources/ZTronLPCPSAT/CPSAT.swift:259 and :328 (winningWorker: prover?.index ?? best.worker); Portfolio.swift:68-69.
- repro: .build/release/F5 winner 100
- confidence: reproduced

### A5-05 (low) `bound` differs from `objectiveValue` on .optimal results, against the doc comments
- claim: CPSATAnalysis doc: "`bound` is the propagated bound of the objective row, and equals `objectiveValue` once optimality is proven"; SolutionAnalysis.bound: "Proven bound; equals `objectiveValue` when optimal".
- observed: .optimal obj=3.500001 bound=3.500007 (D13); .optimal obj=562946402850150 bound=562949953421313 (D5 2^49+1 par, first run); .optimal obj=-2.3795703474867405e+17 bound=-2.3796833534450074e+17 (big k=3 det).
- why: when the gap closes without exhaustion, run() reports the proven bound (CPSAT.swift:298-303), which is deliberate in code but contradicts both doc comments; the integration test asserts bound == objective only on instances that close exactly.
- location: Sources/ZTronLPCPSAT/CPSAT.swift:298-303 vs :356-358 doc; Sources/ZTronLPCore/Solve/Analysis.swift:22
- repro: F5_ONLY=D13 F5_LIMIT=3 .build/release/F5 domain
- confidence: reproduced
OBS(cross-area) | BranchAndBound(deterministic:true) on D14c returns optimal obj=10 x=[4503599577830908, 10] (fixed bound violated by 4.95e7); on D14 the same infeasible point as CP-SAT | .build/release/F5 xcheck | for the B&B / simplex area to verify
HELD | baseline gates for the area: CP-SAT suites pass in debug (03), release integration incl. cpSatClosesEveryPureIntegerInstance 7/7 (04), TSAN 91 tests in 7 CP-SAT suites (05) | verification/baseline/*.log | all rc=0

## Final
Structured result written to verification/cycle-A/F5-cpsat.json (findings A5-01 critical, A5-02 medium, A5-03 medium test-integrity, A5-04 low, A5-05 low; 14 claims held; overflow 6). Probe sources: verification/probes/cycle-A/Slots/F5/{main,Oracle,SAT,Enum,Claims,Wide,Winner,Cancel,XCheck}.swift.
