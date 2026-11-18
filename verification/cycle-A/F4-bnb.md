# Cycle A — area F4: Branch and bound — finder log

- Cycle: A (claims first)
- Area: F4, Branch and bound (Sources/ZTronLPBranchAndBound/*, tests, MIPLIB 3 corpus, README §2.5/§3/§4/§5 MIP)
- Probe slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/F4/ (product F4)
- Package: /Users/admin/Documents/ZTronLPOptimizer @ d9afebe (git main), Swift 6.4, M3 8 cores
- Method: extract checkable claims from README/HANDBOOK/doc comments/tests; falsify each with an executable probe
  (independent oracle: exhaustive enumeration + independent LP method), ordered by user cost.

## Plan (claims / properties to check, most costly failure first)

P1  .optimal answers correct vs exhaustive enumeration (binary; general int with negative/asymmetric bounds;
    mixed int with continuous part solved by an independent method; equality rows). Status, objective within gap,
    incumbent feasible + integral, `bound` a valid bound. Both node engines (Simplex .primal/.dual, InteriorPoint),
    deterministic and parallel, presolve on/off, branching rules, heuristics on/off. Minimize and maximize.
P2  Infeasible MILPs (LP-feasible but integer-infeasible; LP-infeasible) -> .infeasible, never .optimal.
P3  Unbounded relaxation -> .unbounded / .infeasibleOrUnbounded or correct optimal when integer part bounded; never a false .optimal.
P4  Gap semantics (README §2.5, risk 10): .optimal => incumbent - bound <= max(abs, rel*max(1,|inc|)); custom Gap tightens it.
P5  nodeLimit -> .feasible(.nodeLimit) with feasible incumbent + valid bound, or .noSolution(.nodeLimit); never false .optimal/.infeasible.
P6  timeLimit / cancellation honoured (bounded wall clock), same status discipline.
P7  memoryBudgetBytes bounds open nodes; stops with .memoryBudget, status discipline.
P8  deterministic: true reproducible run to run (risk 8, C9); parallel agree on objective within gap.
P9  MIPLIB 3 reference optima in ReferenceValues.swift equal published values; solve each with both node engines.
P10 Search-tree invariants: bound monotone/valid; analysis.gap consistent; incumbent history monotone; nodes counts sane.
P11 API claims: deterministic searches depth-first whatever nodeSelection; WarmStart ignored; dual nil for MILP;
    events order (.finished last+unique); root iteration cap / node LP failing 3x -> .numericalFailure.
P12 Test integrity of Tests/ZTronLPBranchAndBoundTests, MIPLIB parts of integration tests, L4 liveness test.

## Log (HELD | claim | command | key output)  /  FAIL | ...
FAIL | LP-integral node point within integrality tol is rounded and offered without a feasibility re-check | probes/cycle-A Slots/F4 (Util.swift, Families.swift, main.swift): .build/release/F4 bigm | fixed-charge min 100y+x, x>=0.5, x<=1e6 y: every config (P/D/I, det/par, presolve off) -> optimal obj 0.50005, x=(y=0,x=0.5), row violation 0.5, c.x=0.5; true optimum 100.5. Second shape 1e7x1+1e7x2>=5 -> optimal 5e-7 at (0,0), violation 5, optimum 1.
HELD | P1/P2 .optimal/.infeasible correct vs exhaustive enumeration (binary, general int with negative/asymmetric/fractional bounds, mixed int with vertex-enumerated continuous part, equality rows; min and max) x 11 configs (P/D/I engines, det/parallel, threads 1/2/4/8, presolve off, mostFractional/strong/pseudocost, bestBound/depthFirst/plunging, heuristics none) | .build/release/F4 enum all 60 0 | runs=2640 fails=0 badBound=0 suboptWithinGap=0 infeasibleInstances=30 (all reported .infeasible)
HELD | P2/P3 hand-built edge cases: parity-infeasible, LP-infeasible, empty integer range -> .infeasible; free integer column, no rows, all fixed, maximize with c0, [-0.5,0.5] integer -> correct .optimal | .build/release/F4 special | all 11 configs agree with hand-derived optima
HELD(weak) | P3 unbounded relaxation never gives a false .optimal/.unbounded: MILP-unbounded, LP-unbounded-but-MILP-infeasible and mixed unbounded all -> .infeasibleOrUnbounded | .build/release/F4 special | (status doc of .infeasibleOrUnbounded names only the IPM as its source; B&B returns it for every unbounded relaxation)
FAIL | rounding heuristic's relative feasibility test feas*(1+|bound|) accepts integer points violating rows by whole units | .build/release/F4 special (case huge-integer-bounds) | min x s.t. 3x+y>=1e9+1 (y fixed 0), x int: 10 of 11 configs -> optimal 333333333 with row violation 2.0; only heuristics:.none returns the true 333333334
HELD | P4a default gap never accepts an incumbent outside max(1e-6,1e-4*max(1,|inc|)) | .build/release/F4 gap 30 | near-tie knapsack (14 binaries, non-integral profits -> objectiveStep 0): 60 default runs, defaultOutsideGap=0, defaultSuboptWithinGap=35 (accepted by design)
HELD | P4b a custom tight Gap (0/0, 1e-12, IPM 0/1e-9) finds the true optimum | .build/release/F4 gap 30 | 90 tight runs, tightWrong=0, badBoundTight=0
FAIL | P4c/P10 `bound` is a proven bound | .build/release/F4 gap 30 | in all 35 default runs that returned a suboptimal incumbent, bound == incumbent < true optimum (maximise), e.g. seed 15: obj=bound=3670.045785, enumerated optimum 3670.050618
FAIL | P4c bound/gap after a loose user Gap | .build/release/F4 gaploose | seed 15 Gap(rel 0.05): optimal obj 3560.059532 bound 3560.059532 gap 0 after 1 node, enumerated optimum 3670.050618 (true gap 3.0%); same with D-det. Integral-profit variant (objectiveStep>0): bounds valid (36757 >= 36706).

### Finding draft A4-x: bound := incumbent on a completed search that pruned by the gap
- claim: SolutionAnalysis.bound "Proven bound" (Sources/ZTronLPCore/Solve/Analysis.swift:22); BranchAndBoundAnalysis "proven bound" (BranchAndBound.swift:93-97); README §3 risk 3 "read `bound` and `BranchAndBoundAnalysis.gap` to know how far the incumbent may be from the optimum"; SearchTree.swift:171-173 comment "the proven bound can never exceed [prunedBound]".
- observed: near-tie knapsack (Families/Modes nearTieKnapsack, seed 15, maximise, 14 binaries, non-integral profits): BranchAndBound(gap: Gap(relative: 0.05)) -> .optimal, objective 3560.059532, bound 3560.059532, gap 0, 1 node; enumeration optimum 3670.050618. Default gap: 35/60 runs return bound == incumbent < optimum (e.g. 3670.045785 vs 3670.050618).
- why wrong: nodes with LP bound in [inc - slack, inc) are pruned by cutoff (SearchTree.swift:318, TreeSearch.swift:88/139/177/214); when the pool then empties the tree closes .complete and BranchAndBound.swift:350-352 overwrites the bound with the incumbent, discarding prunedBound (and worker-side prunes are never recorded at all), so bound and gap claim exact optimality.
- location: Sources/ZTronLPBranchAndBound/BranchAndBound.swift:352 (boundValue = incumbent.objective on .complete); SearchTree.swift:402-407; TreeSearch.swift:139,177,214 (prunes not reported to the tree).
- repro: cd verification/probes/cycle-A && swift build --product F4 -c release && .build/release/F4 gaploose   (also: .build/release/F4 gap 30)
HELD | P5 nodeLimit -> .feasible(.nodeLimit)/.noSolution(.nodeLimit) or correct .optimal; incumbent feasible; bound valid; nodes <= L + workers | .build/release/F4 limits | randomMILP(5x15) 12 seeds x L in {1,2,3,5,10,40} x 3 configs: bad=0
HELD | P6 timeLimit honoured (T=0..0.5 s: wall within ~5 ms of T, 3 engines) and cancellation (latency 0.2-0.5 ms) with status discipline | .build/release/F4 limits | see scratch f4-limits.txt
HELD | P7 memoryBudgetBytes stops with .memoryBudget (budgets 1..200000 B), keeps incumbent, never a false .optimal | .build/release/F4 limits | e.g. 2000 B test config -> noSolution(memoryBudget) after 18 nodes
FAIL(suspect) | bound valid after a time limit at the root | .build/release/F4 limits | T=0.001 on randomMILP(30x120,s77) (maximise): feasible(timeLimit) obj 947 bound 947 after 1 node, while later runs find 1097 -> bound below the optimum; to confirm with rootstop mode
FAIL | bound valid after a stop during root expansion (confirmed) | .build/release/F4 rootstop | randomMILP(30x120,seed 77) maximise, proven optimum 1097, root LP 1120.53: timeLimit 0.0005..0.003 s (8 and 1 threads) and cancel after 0.2..2 ms -> feasible(timeLimit|cancelled) obj 947 bound 947 gap 0 nodes 1 open 0. Root node is never re-queued when expand() throws StopSignal (BranchAndBound.swift:307-322), so provenBound collapses to the incumbent.
HELD | P8a deterministic: true identical run to run at a fixed thread count (objective, nodes, iterations, primal, bound, events, incumbent history) for P, D and I engines; threads 2, 4 and 8 agree | .build/release/F4 det | 3 instances x 3 engines x 8 runs
FAIL(low) | P8b deterministic: true independent of SolveContext.threads | .build/release/F4 det | threads 1 vs 4: lpIterations 6102 vs 6111 (P), 5597 vs 5595 (D), 9433 vs 9432 (I); mixed(8,30,s5) P: event sequence and incumbent history differ; objective and primal equal. Cause: strong-branching probes run inline on the worker engine when the ConcurrencyBudget has no free slot (TreeSearch.swift:582-598), on fresh engines otherwise.
HELD | P8c parallel runs agree on the objective | .build/release/F4 det | 5 runs each (threads 2,4,8,8,8): spread 0 on all 3 instances
FAIL | objectiveStep treats an integer column's cost |c|<=1e-9 as an integral 0 (SearchTree.swift:139-141 "smallest possible improvement") | .build/release/F4 misc | min x1 + 1e-9 x2, x1 + (1e-9/1.5) x2 >= 0.5, x1 in {0,1}, x2 int in [0,1e9]: 10/11 configs -> optimal 1 bound 1 at (1,0) after 1 node (rounding incumbent, step 1 prunes the children); feasible (0, 7.5e8) has objective 0.75 (verified by maxViolation=0); heuristics:.none finds 0.75
HELD | README 2.5 "A root LP that hits its iteration cap ... ends with .numericalFailure" | .build/release/F4 misc | Simplex(.primal, maxIterations: 1/3/10) -> numericalFailure("the root LP did not finish within its iteration limit")
HELD | README 2.5 "deterministic: true searches depth-first whatever nodeSelection says" | .build/release/F4 misc | bestBound/depthFirst/plunging(32)/plunging(2) with deterministic: identical objective/nodes/iterations/events/incumbent nodes
HELD | P9 MIPLIB 3 reference optima in ReferenceValues.swift equal the published MIPLIB 3 values (p0033 3089, stein27 18, stein45 30, enigma 0, lseu 1120, mod008 307, flugpl 1201500, egout 568.1007, misc03 3360, p0201 7615; rows/cols match; pureInteger flags right: flugpl, egout, misc03 mixed) | independent knowledge + .build/release/F4 miplib all P,D 300 | all 20 runs .optimal, relerr <= 3.6e-16, rows viol <= 1.8e-12, bound == objective; stein45 33.8 s (P) / 26.3 s (D) at load ~14 (README 19.6/15.9 s quiet: load explains it)
NOTE | mod008 P: the .boundImproved events of a parallel run are not monotone in the stream | .build/release/F4 miplib | to quantify (events mode)
HELD(low note) | event stream of a parallel run: .finished last+unique, newIncumbent improving and last == final objective, count == incumbentHistory | .build/release/F4 events | 20 parallel runs (mod008, p0201, misc03, lseu, randomMILP): all held; but .boundImproved decreased once in 2/20 runs (emission races between progressEvents() and sink.emit, TreeSearch.swift:119-120) - no explicit monotonicity claim
FAIL | rounding heuristic relative tolerance, moderate magnitudes | .build/release/F4 relviol | max x1+x2 s.t. 3x1+3x2 <= 29,999,999 (x int in [0,1e7]): 10/11 configs -> optimal 10,000,000 (row violation 1, source "rounding"); true optimum 9,999,999 (heuristics:.none finds it). 2x - z >= 20,000,001 (z in [0,0.5]): optimal 10,000,000 (violation 1) vs 10,000,001.

### Finding draft: heuristic incumbents accepted with a feasibility test relative to the row bound
- claim: README §4 Results "feasible ... to 1e-7"; README §2.3 Tolerances primalFeasibility 1e-7; the package's own oracle (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:60-65 isIntegralAndFeasible: rows <= 1e-6 absolute).
- observed: see relviol lines; status .optimal with a point that violates an integer-data row by 1-2 units and an objective no feasible integer point attains.
- location: Sources/ZTronLPBranchAndBound/TreeSearch.swift:325-340 (isFeasible: tolerance feasibility*(1+|bound|), i.e. 3.0 on a bound of 3e7, 100 on 1e9), used by roundingHeuristic (TreeSearch.swift:363-419) and dive (448).
- repro: cd verification/probes/cycle-A && swift build --product F4 -c release && .build/release/F4 relviol
HELD | robustness: odd parameters never trap or hang (nodeLimit 0/-1, Heuristics(divingInterval 0, depth -1, iterations 0, batch 5000), strong 0/1000, pseudocost -5/1000, plunging -1, Gap negative/NaN/1e9, threads 0/-3/64, seed UInt64.max, memory 0/-1, timeLimit -1/NaN/inf) | .build/release/F4 edge | all return sane statuses; nodeLimit<=0 -> feasible(nodeLimit) after the root
FAIL(low) | README §5 MIP table column "LP pivots" (= BranchAndBoundAnalysis.lpIterations) counts real pivots | .build/release/F4 iters | 2-column model (min -x-0.1y, 2x+y<=1, x binary): mostFractional -> lpIterations 3 (P) / 2 (D) for 3 nodes; strong(1) and default pseudocost(4) -> 28 / 27 for 2 nodes; root LP alone 1 pivot. TreeSearch.swift:597 and :637 add candidates*2*50/4 = 25 per probed candidate instead of the probes' pivots.
HELD | P1 (second batch) enumeration, seeds 1000-1149 per family | .build/release/F4 enum all 150 1000 | runs=6600 fails=0 badBound=0 suboptWithinGap=0 infeasibleInstances=70
NOTE | test integrity: BranchAndBoundTests.swift:246 memoryBudgetDegradesThenStops asserts `stopReason == .memoryBudget || status == .optimal` (passes if the budget were ignored); L3ToL10Tests.swift:207 (L7 aBudgetTooSmallForTheTreeStopsWithTheIncumbent) does assert .memoryBudget strictly, so the suite still covers "stops"; "degrades" (parent states dropped first) is asserted nowhere.

## Final findings (ranked) — written to F4-bnb.json
A4-01 critical  LP-integral node point rounded and offered without feasibility re-check (big-M: optimal 0.50005 vs 100.5, row viol 0.5)
A4-02 critical  heuristic incumbents accepted with tolerance 1e-7*(1+|bound|) (3x1+3x2<=29,999,999: optimal 10,000,000 vs 9,999,999)
A4-03 critical  objectiveStep treats |c|<=1e-9 as integral 0 -> whole-step pruning (optimal 1 vs 0.75)
A4-04 high      bound := incumbent on .complete after gap pruning (Gap 0.05: bound=obj 3560.06, gap 0, optimum 3670.05)
A4-05 high      stop during root expansion drops the root: feasible(timeLimit) bound=obj 947, gap 0, optimum 1097, root LP 1120.5
A4-06 low       deterministic results depend on SolveContext.threads (1 vs >=2)
A4-07 low       lpIterations ("LP pivots" in README §5) adds 25 estimated pivots per strong-branched candidate
A4-08 low       memoryBudgetDegradesThenStops cannot fail if the budget is ignored; "degrades" untested
A4-09 low       .boundImproved events can arrive out of order in parallel runs
A4-10 info      unbounded relaxation -> .infeasibleOrUnbounded even for an evidently unbounded MILP; status doc names only the IPM
DONE | final JSON written to /Users/admin/Documents/ZTronLPOptimizer/verification/cycle-A/F4-bnb.json (10 findings, 19 claims held)
