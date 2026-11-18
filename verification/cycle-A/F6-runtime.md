# Cycle A, area F6 — Runtime: cancellation, limits, events, concurrency, memory budget, Metal tier, Automatic and Portfolio facades

- Cycle: A (claims first)
- Area: F6 Runtime
- Probe slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/F6/ (product F6)
- Method: claims from README §2.8/§2.9/§3 risks 4,7,14,15/§4 defects 2-4/§5 (Metal, cancellation latency, memory), HANDBOOK
  contracts and decisions, doc comments; each claim attacked with an executable probe or a targeted existing test.
- Repo: git main @ d9afebe, read-only.

## Plan (claims / properties to check, by cost of failure)

1. Cancellation of the solve's Task returns promptly (README §5: p99 <= 50 ms) with `.feasible/.noSolution(stoppedBy: .cancelled)`
   for Simplex(.primal/.dual), InteriorPoint, BranchAndBound, CPSAT(both), Automatic, Portfolio, Conditioned; no hang/crash;
   no work left running afterwards (CPU returns to idle).
2. timeLimit honoured by every strategy (status, not thrown error); timeLimit edge values (0, negative, NaN, inf, tiny).
3. memoryBudgetBytes: B&B and CP-SAT return `.memoryBudget`; Simplex/IPM never do (defect 3); Portfolio splits budget.
4. Events: makeEventStream keeps newest 256; `.finished` always delivered, last, unique, order kept; multiple consumers
   (multiple makeEventStream calls); no deadlock/leak with no consumer; nested facades (Portfolio, Conditioned) finish once.
5. Threads: SolveContext.threads honoured (B&B, CP-SAT workers, Portfolio split threads/k).
6. Lint claims in the source: exactly one @unchecked Sendable, no nonisolated(unsafe), no global mutable state, no blocking.
7. TSAN baseline log review (and which targets it covers vs README §5 claim).
8. Automatic routing: integer -> B&B; m <= 4000 -> dual simplex; m > 10000 with >30% dense column -> sparse QR; else IPM;
   Metal attached per policy.
9. Portfolio: first conclusive wins, others cancelled, reported winner matches, never worse than members'; ranking of
   inconclusive results; empty list throws `.unsupported`; per-strategy errors.
10. Metal: kernels agree with CPU at/above thresholds; MetalPolicy.off; .automatic thresholds (3,000,000 cols & 6,000,000 nnz
    for pricing; 64 points & 100,000 nnz for activity); behaviour when shader library unavailable; tests audit.
11. Test-suite audit of liveness/metal/optimizer tests: assertions that cannot fail, silent skips.

## Log (HELD / FAIL lines, then findings)

HELD | Cancellation of the solve's Task returns promptly with status optimal or stoppedBy .cancelled, no throw, no CPU after return (standard problems: degen2 LP, randomMILP 14x70) for Simplex primal/dual, IPM, BnB, CPSAT (both), Automatic (LP, MIP), Portfolio (BnB+CPSAT, primal+IPM), Conditioned (Simplex, BnB, Automatic) | probe F6 (Slots/F6/Cancel.swift) `.build/release/F6 cancel 12` (load avg 2.7) | worst max latency 13.24 ms (Portfolio primal+IPM), others <= 3.9 ms; idle CPU in 300 ms after return <= 0.21 ms (baseline 0.09); no unexpected status
HELD | timeLimit honoured as a status (never thrown) by Simplex primal/dual, IPM (lite/none), BnB (Simplex/IPM engine), CPSAT (both), Automatic, Portfolio, Conditioned on bigLP=transport(200,2000) and randomMILP 14x70 at limit 0.3 s | `.build/release/F6 timelimit 0.3` (load 3.6) | overshoot <= 15 ms except IPM(crossover:.none) 46 ms and Conditioned(Simplex(.dual)) 71 ms (analyzer runs after the limit)
FAIL | Cancellation/time limit promptness regardless of problem size (WorkGate doc "keeps cancellation latency bounded regardless of problem size"; L1 rule p99 <= 50 ms) | `.build/release/F6 cancel-large ipmdense 2.0 3 6500`; `F6 dense-detail 6500 1.0`; `F6 cancel-large presolve-ipm 0.02 2`; `F6 cancel-large presolve 0.02 2` (load avg 3.6-3.9) | Automatic->IPM on 6500-row LP with one dense column: cancel latency 141/316/663 ms; IPM iteration gap 667-714 ms; timeLimit 1.0 -> elapsed 1.514 s; m=4500: 75-134 ms. InteriorPoint on transport(400,5000) (2M cols): cancel at 20 ms -> 1021/1033 ms; Simplex(.dual) same LP: 181/238 ms
FAIL | Portfolio: "If none concludes, the best of what came back is returned" / never worse than its members | `.build/release/F6 portfolio worse2` (Slots/F6/Facades.swift) | members alone (deterministic): BnB(dual,nodeLimit 30) feasible 1762, BnB(dual,nodeLimit 4000) feasible 1852 (maximize); Portfolio of both, either order: feasible 1762, bound 1893.795 (the other's bound 1893.700) -> the first-arrived incumbent wins regardless of objective
HELD | Portfolio race: first conclusive wins, others cancelled (status stoppedBy .cancelled), winner name == base.engine, wall = winner's (threads/2) + latency, no CPU after return | `F6 portfolio race` | IPM alone 1.413 s; Portfolio(primal,IPM) optimal 78310 winner InteriorPoint(crossover: .lite) == base.engine, other Simplex(.primal): noSolution(cancelled), wall 1.709 s, idle CPU 0.09 ms
HELD | Portfolio([]) throws .unsupported; all members throw -> first error rethrown; one member throws -> recorded as numericalFailure in others | `F6 portfolio empty` | as stated
HELD | Cancelling a Portfolio stops every member promptly | `F6 portfolio cancelparent` | latency 0.4-0.95 ms, status noSolution/feasible(cancelled), idle CPU 0.06 ms
HELD | Automatic routing (README §2.5): integer -> BranchAndBound<Simplex(.primal)>; m <= 4000 -> Simplex(.dual); m > 10000 with a column > 30% dense -> Simplex(.dual) sparse QR (engine name "Simplex(.dual)"); else InteriorPoint(crossover: .lite); boundaries 4000/4001, 3000 vs 3001 entries at m = 10001, integer at m = 5000 | `F6 automatic` (Slots/F6/Facades.swift) | all choices as documented; objectives correct by hand (4000, 4001, 5001, 7001, 7002, 10001, 5000, 3)
FAIL(add. evidence for latency) | Automatic, m=10000 LP with a 50%-dense column (routed to IPM, dense normal equations) | `F6 automatic limit10000` (load 5.4) | timeLimit 0.5 -> elapsed 0.798 s; 1.0 -> 1.180 s; cancel latency 93 / 353 ms
HELD | makeEventStream keeps the newest 256 events, in order, .finished kept and last, events after .finished dropped | `F6 events synthetic` | 256 events = nodes 745..999 + .finished; ordered; ended
HELD | Two makeEventStream() on one context both receive every event and end | `F6 events two` (BnB on randomMILP 8x30) | 20 events each, identical, both ended
HELD | No consumer: solve returns, stream drains later and ends | `F6 events noconsumer` | solve 0.33 s; 100 events, ended
HELD | Slow consumer (2 ms/event): stream is a suffix of all events, ends with .finished | `F6 events slow` | 100/100 events (solve emits < 256)
HELD | L10 on facades: one .started first, one .finished last, for Automatic (LP, MIP), Portfolio (3 LP engines; one member throws; all throw), Conditioned(Portfolio), Conditioned(CPSAT) inner throws, nested Portfolio, timeLimit 0 | `F6 events facades` | all L10 true, started events 1
FAIL | `.finished` "delivered exactly once on every exit path" (HANDBOOK Strategies contracts; Status.swift:144) and makeEventStream "The stream ends after .finished" | `F6 events-model` (Slots/F6/Events.swift) | Automatic().solve(LPModel with NaN objective coefficient, context:) throws invalid model; the stream gets 0 events and its consumer is still waiting after 5 s (ends only when its task is cancelled); control with a valid model: 4 events, ended
FAIL | Conditioned cancellation/time limit: inner Simplex(.dual) alone cancels in 5-7 ms, Conditioned(Simplex(.dual)) in 337-338 ms on transport(400,3600) (m=4000); analyzer alone 0.380 s; timeLimit 0.5 -> 0.848-0.882 s, 1.0 -> 1.330-1.403 s (Conditioned(Simplex(.dual)) and Conditioned(Automatic)) | `F6 cancel-large conditioned 0.5 2`, `F6 cancel-large conditioned-inner 0.5 2`, `F6 cancel-large analyzer`, `F6 cancel-large conditioned-limit` (load 5.6-7.1) | see numbers

### Draft findings (final numbering by severity in F6-runtime.json)

#### D1 Cancellation and time limits wait for uninterruptible interior-point / presolve steps (latency grows with problem size)
- claim: WorkGate doc (Sources/ZTronLPNumerics/WorkGate.swift:84-87) "keeps cancellation latency bounded regardless of problem size"; rule L1 (Tests/ZTronLPLivenessTests/L1CancellationTests.swift:44 "every loop that can run more than ~1 ms calls gate.tick(); cancellation is seen within the latency bound", p99 <= 50 ms, max <= 200 ms in release); README §5 cancellation p99 <= 50 ms; README risk 2 "Always set timeLimit".
- observed: Automatic() on a 6,500 x 322,501 LP with one dense column (routed to InteriorPoint, dense normal equations): IPM iterations 667-714 ms apart, gate checked once per iteration; cancel latency 141 / 316 / 663 ms; timeLimit 1.0 s -> returns after 1.514 s. m = 4,500: 75-134 ms. m = 10,000 identity + 50%-dense column (Automatic -> IPM): timeLimit 0.5 -> 0.798 s, 1.0 -> 1.180 s, cancel 93/353 ms. InteriorPoint() on transport(400,5000) (5,400 x 2,000,000, 4M nnz) cancelled after 20 ms: 1,021 / 1,033 ms (setup: standard form, symbolic analysis, starting point not gated). Simplex(.dual) same LP: 181 / 238 ms (presolve + scaling passes not gated). Load average 3.6-5.4 on 8 cores.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:672-674 (one gate.check per iteration), :384-441 factorNormalEquations / startingPoint not gated; Sources/ZTronLPSimplex/Simplex.swift:146 (Presolve.run) and :198 (Scaler.scale) run before any WorkGate exists.
- repro: cd verification/probes/cycle-A && swift build --product F6 -c release && .build/release/F6 dense-detail 6500 1.0 ; .build/release/F6 cancel-large ipmdense 2.0 3 6500 ; .build/release/F6 cancel-large presolve-ipm 0.02 2 ; .build/release/F6 automatic limit10000
- documented: no. README §4 limits mention dense normal equations (slowness), defect 3 (memory); nothing about cancellation/time-limit latency.

#### D2 Conditioned runs the whole conditioning analysis after a cancelled or timed-out inner solve
- claim: HANDBOOK contracts (cancellation is a result, returns promptly per L1); README §5 p99 <= 50 ms; timeLimit "seconds, wall clock".
- observed: transport(400,3600) (m = 4,000): Simplex(.dual) alone cancels in 5-7 ms; Conditioned(Simplex(.dual)) in 337-338 ms; the analyzer alone takes 0.380 s (dense LU of the 4,000-row basis). timeLimit 0.5 -> 0.848-0.882 s; 1.0 -> 1.330-1.403 s (also Conditioned(Automatic)).
- location: Sources/ZTronLPOptimizer/Conditioned.swift:40 (analyze runs unconditionally, with no deadline/cancellation check); ConditioningAnalyzer has no WorkGate.
- repro: .build/release/F6 cancel-large conditioned 0.5 2 ; ... conditioned-inner 0.5 2 ; ... analyzer ; ... conditioned-limit
- documented: README §2.5 says Conditioned costs inner + one analyze; nothing about cancellation or limits.

#### D3 Portfolio returns the first inconclusive result to arrive, not the best: worse incumbent than a member's
- claim: README §2.5 Portfolio "If none concludes, the best of what came back is returned (feasible before undecided before no solution before failure)"; Portfolio.swift:12-13 "if none concludes, the best of what came back is returned".
- observed: members alone (deterministic): BnB(dual, nodeLimit 30) feasible 1762 in 0.04 s, BnB(dual, nodeLimit 4000) feasible 1852 in 0.60 s (maximize). Portfolio of both, either order: feasible 1762 (bound 1893.795, the other's 1893.700). With time limits (BnB + CPSAT, 0.3/0.6 s) the portfolio returned CPSAT's 1826/1827 while BnB alone reached 1865/1869.
- location: Sources/ZTronLPOptimizer/Portfolio.swift:105-113 (rank by status only, first in arrival order wins ties; objective and bound ignored).
- repro: .build/release/F6 portfolio worse2 ; .build/release/F6 portfolio timelimit
- documented: the parenthetical orders status classes only; not stated that among feasible results the first to arrive wins.

#### D4 LPModel convenience solve: a compile error exits without .started/.finished; a makeEventStream consumer never ends
- claim: HANDBOOK "`.finished` is the last progress event and is delivered exactly once on every exit path"; Status.swift:144-145 same; Strategy.swift:169-171 "The stream ends after .finished".
- observed: Automatic().solve(model with NaN objective coefficient, context:) throws SolverError.invalidModel; the stream created by context.makeEventStream() receives 0 events and its consumer is still waiting 5 s later (the stream ends only when the consumer task is cancelled); the same consumer ends with 4 events for a valid model.
- location: Sources/ZTronLPCore/Solve/Strategy.swift:209-215 (`try model.compile()` before any EventSink exists).
- repro: .build/release/F6 events-model
- documented: no (L10 test aThrowingSolveStillFinishesOnce covers CompiledLP paths only).
HELD | threads honoured by BnB and CPSAT (CPU/wall <= threads) | `F6 threads` (load 7) | threads 1: BnB 0.74, CPSAT 0.66; 2: 1.96, 1.89; 4: 3.37, 3.74
HELD | Simplex dense LU (m=1500) and sparse QR (m=2200) stay on ~1 core with threads=1 | `F6 threads lp` | 0.94-0.98
FAIL | SolveContext.threads bounds the CPU a solve uses (README risk 7 "give each its share with SolveContext.threads"; ConcurrencyBudget "never exceed threads"; Strategy.swift:162 "The number of worker threads this run may use") | `F6 threads lp`; `VECLIB_MAXIMUM_THREADS=1 F6 threads lp`; `F6 threads` | InteriorPoint() threads=1 on transport(200,2000): CPU/wall 2.62-3.22 (Accelerate's own threads); with VECLIB_MAXIMUM_THREADS=1: 1.00 (and faster, 1.20 s vs 1.62 s). Portfolio of 3 members with threads=1: CPU/wall 2.37 (each member gets max(1, 1/3) = 1)

#### D5 SolveContext.threads does not bound the interior point (Accelerate threads) nor a Portfolio with more members than threads
- claim: README §3 risk 7 mitigation "give each its share with SolveContext.threads"; README §2.8 ConcurrencyBudget "so that nested parallel regions never exceed threads"; Strategy.swift:162 resolvedThreads "The number of worker threads this run may use".
- observed: InteriorPoint() with threads = 1 on transport(200,2000) (2,200 x 400,000): process CPU/wall 2.62-3.22 (3 runs); with VECLIB_MAXIMUM_THREADS=1 it is 1.00-1.07 and the solve is faster (1.20 s vs 1.62 s). Portfolio([BnB, CPSAT, BnB(dual)]) with threads = 1: CPU/wall 2.37.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift (Accelerate sparse/dense factorization, no thread control); Sources/ZTronLPOptimizer/Portfolio.swift:44 `child.threads = max(1, context.resolvedThreads / count)`.
- repro: .build/release/F6 threads lp ; VECLIB_MAXIMUM_THREADS=1 .build/release/F6 threads lp ; .build/release/F6 threads
- documented: no.
HELD | Defect 3 as documented: Simplex, IPM, Automatic (LP), Conditioned never return .memoryBudget (budget 1 byte -> optimal); Conditioned skips the condition estimate above the budget | `F6 memory lp` | all optimal; report estimate nil
HELD | B&B open nodes stay under memoryBudgetBytes | `F6 memory bnb-free 15` vs `F6 memory bnb-budget 15` (separate processes) | peak RSS 843.9 MB (140,063 nodes) without budget vs 31.0 MB (7,423 nodes) with 16 MB
HELD | CPSAT and Portfolio report .memoryBudget under a tiny budget, never wait | `F6 memory cpsat-budget`, `F6 memory portfolio-budget` | budget 0 / 4096: noSolution(memoryBudget) at once; 1 MB: feasible(timeLimit); Portfolio 4096: noSolution(memoryBudget)
INFO | Under a binding 16 MB budget the B&B node rate collapses (~7,700 nodes/s before, 560 -> 170 nodes/s after, declining as the open list grows): checkGapAndMemory copies and sorts the whole open list on every over-budget check (SearchTree.swift:437-461) | `F6 memory bnb-trace 6` | 0.51 s 3,924 nodes; 6.02 s 5,979 nodes; status feasible(timeLimit), RSS 30 MB
HELD | Metal status ready (compiledFromSource), device nil -> noDevice; forced kernels work on afiro; forced solves give the CPU answers (afiro -464.753..., randomMILP 8x30 235 = CPU 235) | `F6 metal status` | as stated
HELD | KernelThresholds constants and gates (3,000,000 cols AND 6,000,000 nnz for scan; 64 points AND 100,000 nnz for activity; .off never; .forced any size, activity needs >= 1 point); provider honours them at 100,000 vs 99,900 nnz; PolicyBoundActivityEvaluator declines 63 points, accepts 64; attachMetal under .off attaches nothing; candidateKernels nil under .off even with a provider | `F6 metal thresholds` | all as documented
HELD | Scan kernel agrees with fp64 (top-64 identical; no attractive-sign flips; score rel. err <= 3.5e-4) at 20k and 200k columns (forced) and at/above the threshold 3,000,000 cols / 6,000,000 nnz and 3,200,000 / 6,400,000 (granted under .automatic) | `F6 metal scan`, `F6 metal scan big` | overlap 64/64 in all four
HELD | Activity screen has no false negatives on 256 points (128 exactly on row bounds, 100,000 nnz, values up to 1e3, tolerance 0) | `F6 metal activity` | false negatives 0, false positives 0
FAIL(low) | MetalBatchedActivity "Never rejects a point that is feasible in exact arithmetic" (README §2.9, Kernels.metal comment) | `F6 metal bigbound` | row x0+x1 <= 1e39 (finite), point (1.6e38, 1.6e38): fp64 maxViolation 0, GPU flag false (bound clamped to 3e38 = infinityStandIn); (1e38,1e38) and (0,0) accepted
HELD | Shader library unavailable only disables the tier: binary without its resource bundle -> libraryUnavailable("the ZTronLPMetal resource bundle was not found"); bundle with a broken Kernels.metal -> libraryUnavailable("shader compilation failed: ..."); forced Simplex/BnB/Automatic solves still optimal with CPU answers (7828, 235) | copy of .build/release/F6 in scratchpad dirs a/ (no bundle) and b/ (broken shader); `F6 metal status2` | as stated, exit 0
HELD | Lint claims in source: exactly one @unchecked Sendable (Sources/ZTronLPNumerics/Sparse.swift:329, with INVARIANT comment), no nonisolated(unsafe), no lock/blocking primitives (also NSLock/os_unfair_lock/pthread/.sync/.wait/Mutex, beyond the lint's patterns), only structured tasks besides MetalTierState's startup task | grep over Sources and Tests | as stated; one global singleton with actor-protected mutable state: MetalAccelerator.shared (info)
HELD | TSAN baseline: no ThreadSanitizer report in verification/baseline/05-tsan.log (Integration, Liveness, BranchAndBound, CPSAT targets) | grep ThreadSanitizer/data race | 0 hits; 4 Swift Testing runs passed
HELD | Parallel B&B (primal, dual, IPM engines), CPSAT, Automatic, Portfolio agree with deterministic B&B on 40 random (mixed) MILPs; every returned point feasible and integral; every stopped .feasible point feasible and not better than the optimum | `F6 bnbagree 40 1` (Slots/F6/Search.swift) | disagreements 0, bad points 0, bad status 0 (117 stopped runs)
FAIL | B&B bound of a stopped run (README risk 3 "read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum") | `F6 bnbagree 40 1`; `F6 bound-detail`; `F6 bound-miplib` | 18 stopped runs with bound beyond the optimum; randomMILP 14x70 (max, opt 599): timeLimit 0.0001-0.001 s or cancel after 0.5-1 ms -> feasible(timeLimit/cancelled) obj 520 bound 520 gap 0.0 nodes 1 open 0; stein27 (min, opt 18): limit 0.005 -> obj 19 bound 19 gap 0; mod008 (opt 307): obj 510 bound 510 gap 0; egout (opt 568.1): obj 689.45 bound 689.45 gap 0. CPSAT bounds always valid.

#### D6 A B&B run stopped during the root's expansion reports bound = incumbent and gap = 0 (false optimality certificate)
- claim: README §3 risk 3 "read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum"; README §2.4 `bound`; SolveStatus.feasible "optimality was not proven".
- observed: randomMILP(14,70,seed 4242) (maximize, optimum 599): timeLimit 0.0001-0.001 s, or Task cancelled after 0.5-1 ms -> .feasible(stoppedBy: .timeLimit/.cancelled), objective 520, bound 520, gap 0.0, nodesProcessed 1, nodesOpen 0. MIPLIB: stein27 (opt 18) limit 0.001-0.005 -> obj 27/19 with bound 27/19 gap 0; mod008 (opt 307) limit 0.001-0.002 -> obj 510 bound 510 gap 0; egout (opt 568.1007) limit 0.002 -> 689.45 / 689.45 / gap 0. CPSAT under the same limits always reports a valid bound.
- location: Sources/ZTronLPBranchAndBound/BranchAndBound.swift:306-320 (a StopSignal in the root's expand leaves rootChildren empty, tree.begin(root:children: []) then close(.timeLimit)): the root's LP bound is dropped; SearchTree.provenBound (SearchTree.swift:399-405) then falls back to the incumbent.
- repro: .build/release/F6 bound-detail ; .build/release/F6 bound-miplib stein27 mod008 egout ; .build/release/F6 bnbagree 40 1
- documented: no.
FAIL(add. evidence D6) | the false bound reaches the facades | `F6 misc bound-facades` | Automatic and Conditioned(Automatic), timeLimit 0.0003-0.001 on randomMILP 14x70: feasible(timeLimit) obj 520 bound 520; nodeLimit 1/2/3 bounds valid (618.3, 617.8, 617.3)
HELD | timeLimit edge values never throw: 0, -1, 1e-9 -> noSolution(timeLimit) at once; NaN, +inf, -inf, 1e300 -> no limit (Deadline.after doc: non-finite = no deadline) for Simplex x2, IPM, BnB, CPSAT, Automatic, Portfolio, Conditioned | `F6 misc limits` | as stated (-inf meaning "no limit" is documented only on Deadline.after; info)
HELD | threads 0/-5 -> resolvedThreads 1; CPSAT(workers: 0) -> 1 worker; memoryBudgetBytes -100 -> 0; default budget = physical/4 (6,442,450,944 of 25,769,803,776) | `F6 misc threadsedge` | as stated
FAIL(test-integrity) | L7 `sixteenMegabytesIsEnoughAndIsRespected` (Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:190-200) can catch an ignored budget | `F6 memory l7` (same problem and strategy as the test: LivenessProblems.mip() = randomMILP(14,70,4242), BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound)) | 16 MB budget: optimal 599, 6,133 nodes, at most 1,549 open; budget Int.max/2: optimal 599, 5,847 nodes, at most 1,596 open. By the tree's own accounting (SearchTree.swift:29-30, 61-62, about 1.5 KB per open node here) the open list peaks near 2-3 MB, so neither the strip path nor .memoryBudget is ever reached; the test asserts status only and passes with the budget ignored
FAIL(test-integrity) | L1 `timeLimitsAreHonouredPromptly` (Tests/ZTronLPLivenessTests/L1CancellationTests.swift:123-139) can catch an ignored time limit | `F6 misc l1` (load avg 36.7) | with no time limit at all, 9/9 release runs (BnB, BnB(IPM), CPSAT x 3) end optimal in 0.189-0.430 s, inside the test's release bound 0.25 + LatencyBounds.max (0.200) = 0.45 s; baseline release run of the test 0.500 s for all 3 solves (04-test-release-integration-liveness.log); in debug the limit does bind (03-test-debug.log 0.755 s for 3 runs, bound 1.05 s), whether an unlimited debug solve exceeds 1.05 s was not measured
INFO | README.md:714 "Thread Sanitizer: No reports on the simplex, interior-point, branch-and-bound, CP-SAT, facade, integration and liveness targets" vs the only TSAN command (ci.yml:65, HANDBOOK.md:177): --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests|ZTronLPBranchAndBoundTests|ZTronLPCPSATTests'; ZTronLPSimplexTests, ZTronLPInteriorPointTests and ZTronLPOptimizerTests never run under TSAN (those source modules are exercised only through the integration and liveness tests) | read-only grep | overflow item

#### D7 L7 test cannot fail for an ignored memory budget
- claim: test name and rule L7 comment "sixteen megabytes is enough and is respected".
- observed: see the FAIL(test-integrity) line above (`F6 memory l7`).
- location: Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:190-200 (asserts `.optimal || .memoryBudget` and `hasSolution` only; the open list never exceeds ~3 MB).
- repro: cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 memory l7
- documented: no. (The behaviour itself holds: `F6 memory bnb-budget 15` 31.0 MB RSS vs 843.9 MB without a budget.)

#### D8 L1 time-limit test cannot fail in release for an ignored time limit
- claim: test `timeLimitsAreHonouredPromptly`; rule L1.
- observed: see the FAIL(test-integrity) line above (`F6 misc l1`).
- location: Tests/ZTronLPLivenessTests/L1CancellationTests.swift:123-139 (0.25 s limit on a MIP that solves to optimal in 0.14-0.43 s; accepts .optimal; release bound 0.45 s).
- repro: .build/release/F6 misc l1
- documented: no.

#### D9 Metal activity screen rejects a feasible point when a finite row bound exceeds 3e38
- claim: README.md:398 MetalBatchedActivity "Never rejects a point that is feasible in exact arithmetic"; Sources/ZTronLPMetal/BatchedActivityKernel.swift:27.
- observed: row x0 + x1 <= 1e39 (finite), point (1.6e38, 1.6e38): fp64 maxViolation 0, GPU flag false; (1e38, 1e38) and (0, 0) accepted.
- location: Sources/ZTronLPMetal/KernelSupport.swift `infinityStandIn = 3.0e38` and the row-bound clamp in BatchedActivityKernel.swift init (finite bounds beyond 3e38 become 3e38).
- repro: .build/release/F6 metal bigbound
- documented: no.

### Final numbering (F6-runtime.json)
A6-01 = D6 (critical) | A6-02 = D1 (high) | A6-03 = D2 (high) | A6-04 = D5 (medium) | A6-05 = D3 (medium) | A6-06 = D4 (medium) | A6-07 = D7 (medium) | A6-08 = D8 (low) | A6-09 = D9 (low)
JSON-WRITTEN | final structured result written to verification/cycle-A/F6-runtime.json (9 findings A6-01..A6-09)
