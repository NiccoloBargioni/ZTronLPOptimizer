# Cycle B (oracles first) - Finder F6 - Runtime

- Cycle: B (oracles first, independent of cycle A)
- Area: F6 Runtime: cancellation, limits, events, concurrency, memory budget, Metal tier, Automatic and Portfolio facades
- Slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B/Slots/F6/ (product F6)
- Package: /Users/admin/Documents/ZTronLPOptimizer git main @ d9afebe, Swift 6.4, Apple M3 8 cores, macOS 27
- Method: derive contract from first principles (LP optimality/feasibility oracle on returned points, exhaustive
  enumeration for small IPs, monotonicity under tighter limits, event-stream ordering, CPU-idle after cancel),
  attack public API with edge cases, randomized differential between engines/facades with recorded seeds.
  Only afterwards compare with README §4 / HANDBOOK Known gaps.

## Plan (claims / properties to check)
P1  Cancellation of the solve Task returns promptly for Simplex, InteriorPoint, BranchAndBound, CPSAT, Automatic,
    Portfolio, Conditioned with documented status (.cancelled?), no hang/crash, CPU returns idle afterwards.
P2  timeLimit honoured by every strategy within sane margin, reported as status not thrown error.
P3  memoryBudgetBytes / .memoryBudget status where README claims.
P4  makeEventStream: newest 256 kept, .finished always delivered, ordered; multiple consumers; no deadlock/leak
    when nobody consumes.
P5  SolveContext.threads honoured; parallel search ordering (incumbent/bound) - result oracle vs enumeration
    across thread counts; lint claims (one @unchecked Sendable, no nonisolated(unsafe), no global mutable state,
    no blocking waits) in source; TSAN baseline log review.
P6  Automatic routing as documented (IPM above 4,000 rows; Metal attached; MIP -> BnB/CPSAT); result optimal-
    checked by independent oracle.
P7  Portfolio race semantics: first acceptable answer wins, others cancelled, reported strategy matches, result
    never worse than members.
P8  Metal kernels equal CPU path at/above thresholds; MetalPolicy.off; .automatic thresholds (3,000,000 cols /
    6,000,000 nnz pricing; batch 64 points on 100,000 nnz feasibility screen); behaviour when shader lib fails.
P9  Randomized differential LP/MIP across facades (Automatic vs Portfolio vs Simplex vs IPM vs BnB) with
    independent KKT oracle; seeds recorded.

## Log (HELD / FAIL lines, findings appended below)
HELD | lint claims: exactly one @unchecked Sendable (Sparse.swift:329 SparseQRFactorization), no nonisolated(unsafe), no global/static stored vars, no DispatchSemaphore/Thread.sleep/waitUntilCompleted/DispatchGroup/usleep in Sources; all targets Swift 6 mode | grep over Sources + baseline/02-lint.log | "1 in total", "lint: all rules hold"
HELD | TSAN baseline: no ThreadSanitizer reports | grep -c ThreadSanitizer baseline/05-tsan.log -> 0; rc=0; suites Liveness, Integration, CPSAT, BranchAndBound ran (24+17+91+26 swift-testing tests) | NOTE README §5 also claims simplex, IPM, facade targets clean under TSAN; baseline did not run those
HELD | KernelThresholds constants match README §2.7/§2.9 (3,000,000 cols, 6,000,000 nnz, 64 cand, 64 points, 100,000 nnz, 1,024 batch, 0.05) | code read CandidateKernels.swift:24-37 | -
HELD | Portfolio S2: conclusive member wins, cooperative loser cancelled promptly, others lists it as noSolution(cancelled) | F6 portfolio scripted | wall=0.053 s winner=fastOptimal others=[slowCoop:noSolution(cancelled)]
HELD | Portfolio S3: deaf loser delays return (documented "plus the cancellation latency of the others") | F6 portfolio scripted | wall=1.000
HELD | Portfolio S4/S5: thrower recorded as numericalFailure in others; all-throw rethrows first error by index | F6 portfolio scripted | threw "unsupported: A"
HELD | Portfolio S6: inconclusive early result does not win while another member still works | F6 portfolio scripted | winner=slowOptimal
FAIL | Portfolio "if none concludes, the best of what came back is returned": first-arriving feasible is returned even when a later member returned a strictly better objective (min 10 vs 5; max 5 vs 10) | F6 portfolio scripted (Slots/F6/PortfolioProbe.swift S1,S1b,S7) | S1 obj=10 winner=fastWorse others=[slowBetter:feasible]; S7 obj=5 (max) -> candidate finding B6-xx
FAIL | (real engines) Portfolio returns worse feasible member: Portfolio([BranchAndBound(nodeLimit:3,deterministic:true), BranchAndBound(nodeLimit:3000,deterministic:true)]) on randomMILP(rows:25,columns:120,seed:99,upper:1) (max) | F6 portfolio real | members alone 1008 and 1090; portfolio (both orders) obj=1008; winner name ambiguous (both "BranchAndBound<Simplex(.primal)>")
HELD | Metal status on this Mac: ready(Apple M3, compiledFromSource); MetalAccelerator(device:nil) -> noDevice, scanner/evaluator nil under .forced | F6 metal thresholds | as stated
HELD | KernelThresholds.allowsReducedCostScan/allowsBatchedActivity boundary cases (3e6/6e6, 2,999,999, 5,999,999, 64/63 points, 100,000/99,999 nnz, .off, .forced, 0 points) | F6 metal thresholds | 11/11 HELD
HELD | Provider gating: scanner small LP auto=nil forced=kernel off=nil; evaluator nnz 5,979 auto=nil, nnz 124,873 auto=kernel; PolicyBoundActivityEvaluator auto 63 points -> nil, 64 -> ran | F6 metal thresholds | as expected
HELD | reducedCostScan kernel scores vs double oracle (m500/n5000, m3000/n60000): max abs err 1.1e-6, no attractiveness flips, top-64 identical to double top-64 | F6 metal scan | overlap 64/64 both
HELD | batchedActivity never rejects exactly-feasible points (integer data, equality rows at exact activity, coefficients up to 16,777,215, 40,000 columns), chunked 1,500-point evaluate == per-point evaluate, activities rel err 1.2e-5 | F6 metal activity | rejected=0, mismatches=0, dispatches=2
HELD | Metal forced vs off end to end: Automatic(MIP) forced/off and BranchAndBound forced equal enumeration on 12 random IPs; Simplex(.primal)+InteriorPoint forced on 13 netlib within 1.3e-11 of reference | F6 metal e2e | 0 mismatches
HELD | makeEventStream: content == exact suffix(256) of full EventRecorder record; two streams on one context identical; stream ends; .started first, .finished once and last - Simplex, IPM, BnB(3060 events), CPSAT, Automatic, Portfolio, Conditioned, and throwing paths (CPSAT on continuous, Conditioned(CPSAT), Portfolio([]), Portfolio all-throw) | F6 events stream | 12/12 HELD
HELD | No events after .finished and none after solve returns, incl. cancelled Portfolio/Conditioned/Automatic | F6 events callback | afterFinished=0 eventsAfterReturn=0 everywhere
HELD | BnB with 8 workers and CPSAT deliver progress callbacks one at a time | F6 events callback | maxConcurrentCallbacks=1
FAIL | Portfolio(bnb,cpsat,bnb-dual) invokes the progress callback concurrently from two members (EventSink "serializes the events of one solve (rule C2)") | F6 events callback (CallbackProbe with 20us spin) | maxConcurrentCallbacks=2 -> candidate finding (low/medium)
HELD | Automatic routing (README §2.5 Automatic row, Automatic.swift:46-51): m=4000 -> Simplex(.dual); 4001 -> InteriorPoint(crossover:.lite); 4002 with 40%-dense column -> IPM (<=10,000 rows); 10,000 dense -> IPM; 10,002 no dense -> IPM; 10,002 dense -> sparse-QR Simplex(.dual); pure and mixed integer -> BranchAndBound<Simplex(.primal)> | F6 automatic (cycle-cover LP, AutomaticProbe.swift) | all optimal, primal feasible <=2.3e-14; dense-column optima 4500/4500.5 confirmed by a hand dual certificate (y=0.25 on covered rows, 0.75/0.25/0.75 on runs) - my initial m/2 oracle was wrong
HELD | Automatic on empty model (0x0) -> optimal 0; on 0-row model min x0-x1 box -> optimal -4; Portfolio(dual,ipm) same | F6 automatic | as stated

### FINDING (draft) Portfolio discards a better feasible member result
- severity: medium; category: wrong-result (selection), confidence: reproduced
- claim: README §2.5 Portfolio row "If none concludes, the best of what came back is returned (feasible before undecided before no solution before failure)"; Sources/ZTronLPOptimizer/Portfolio.swift:11-13 "if none concludes, the best of what came back is returned"; derived contract: a portfolio is never worse than its members.
- observed: two inconclusive feasible members -> the one that ARRIVED FIRST is returned regardless of objective. Scripted: members min-objective 10 (50 ms) and 5 (300 ms) -> portfolio obj=10 (either list order); max 5 vs 10 -> 5. Real engines: Portfolio([BranchAndBound(nodeLimit:3,deterministic:true), BranchAndBound(nodeLimit:3000,deterministic:true)]) on InstanceGenerator.randomMILP(rows:25,columns:120,seed:99,upper:1) (maximize): members alone 1008 and 1090; portfolio returns 1008 in both orders, while it holds the 1090 result in `others`.
- location: Sources/ZTronLPOptimizer/Portfolio.swift:105-113 (rank() compares status class only; ties keep arrival order; objectiveValue never compared).
- repro: cd verification/probes/cycle-B && swift build -c release --product F6 && .build/release/F6 portfolio scripted ; .build/release/F6 portfolio real
- documented: not in README §4 / HANDBOOK known gaps (checked below).
HELD | Cancellation (README §5 p99<=50 ms; statuses .optimal or stopReason .cancelled; CPU idle afterwards), 20 cancels per configuration at random delays, load avg 11-20: Simplex(.primal) p99 14.7 ms, Simplex(.dual) 34.8, IPM 17.3, Automatic(LP) 29.1, Portfolio(dual,ipm) 29.0, Conditioned(dual) 35.8 (transport 60x600); BnB 15.2, BnB(dual) 16.0, BnB(ipm) 16.7, CPSAT 8.7, CPSAT(lp:false) 15.0, Automatic(MIP) 15.2, Portfolio(bnb,cpsat) 8.0, Conditioned(bnb) 17.7, Conditioned(cpsat) 9.0 (randomMILP 25x120 seed 99); every configuration idle CPU over 0.6 s after return = 0.000 s; no bad status | F6 cancel 20 all (Slots/F6/Cancel.swift) | worst of all 35.8 ms
FAIL | Conditioned(Simplex(.dual)) cancellation/time limit on constructedOptimum(rows:3500,columns:7000,seed:31,density:0.0015): cancel latency p50 317 ms, worst 778 ms (inner Simplex(.dual) alone in the same run: p50 1.7 ms, worst 4.0 ms); timeLimit 0.3 -> returns after 0.588 s (Simplex alone 0.302 s) | F6 bigcancel conditioned 6 (Slots/F6/Threads.swift runBigCancel) | candidate finding (analyzer's dense LU after the inner solve has no cancellation/deadline check)
FAIL | InteriorPoint on dense normal equations (constructedOptimum(rows:3000,columns:6000,seed:32,density:0.08), nnz 1.44M): cancel latency p50 95 ms, worst 621 ms (6 cancels); timeLimit 0.3 -> 0.741 s | F6 bigcancel ipm 6 | candidate finding (gate checked once per IPM iteration, IPMWorker.swift:674; contradicts WorkGate doc "bounded regardless of problem size")
HELD | timeLimit in {0, -1, 0.05, 0.3} for Simplex(.primal), Simplex(.dual), IPM, Automatic(LP), Portfolio(primal,dual,ipm), Conditioned(dual) on transport 60x600 and BnB, BnB(ipm), CPSAT, Automatic(MIP), Portfolio(bnb,cpsat), Conditioned(bnb) on randomMILP 25x120: result is a status (noSolution/feasible(timeLimit) or conclusive), never a throw; overrun <= 24 ms (48 cases, 3 runs) | F6 limits time (Slots/F6/Limits.swift) | max over=0.024 s
HELD | threads honoured by BnB and CPSAT at 1/2/4 (CPU utilisation 0.84/1.56/2.04 and 0.74/1.53/2.08); Simplex primal/dual threads=1 on transport 100x1200 (parallel pricing size) 0.65/0.70; IPM dense m3000 threads=1 0.74 | F6 threads util; F6 util2 | utilisation <= threads
INFO | CPSAT(workers:4) with threads=1 uses ~2.2 cores - documented ("threads is the number of portfolio workers unless workers is given") | F6 threads util | utilisation 2.19
FAIL(low) | Portfolio with threads=1 and k=2/3 members runs k single-thread members (child.threads = max(1, threads/k), Portfolio.swift:44): utilisation 1.55 and 1.79 with threads=1 | F6 threads util | README says "threads ÷ k each"
FAIL(low,unconfirmed) | InteriorPoint threads=1 on transport 100x1200 (sparse normal equations): utilisation 1.54 (Accelerate internal threading?) | F6 threads util | single run
HELD | ConditioningAnalyzer.analyze(after:) on the stopped m=3500 basis takes 0.294 s and cancelling its task after 5 ms does not shorten it (0.366 s) -> attribution of the Conditioned overrun | F6 analyzer | outcome=analyzed
FAIL | Portfolio delivers member events to the progress callback concurrently - reproduced 3/3: Portfolio([BranchAndBound(), BranchAndBound(engine: Simplex(.dual))]) on mipHard timeLimit 1: maxConcurrentCallbacks=2 every run; BranchAndBound() alone (8 workers): 1 every run | F6 events concurrency | consequence: two listeners chained on one context see different interleavings: Portfolio([Conditioned(BranchAndBound()), Automatic()]) stream1/stream2 != EventRecorder suffix (F6 events nested: suffixMatch=false), every non-portfolio and Portfolio(bnb,cpsat) case matched
HELD | nested event semantics: BnB(engine: IPM), Conditioned(Portfolio), Portfolio(Portfolio), IPM with crossover: one .started first, one .finished last, .finished status == returned status | F6 events nested | finishedStatusMatchesReturn=true
INFO | timeLimit NaN or +inf -> no deadline (BranchAndBound ran until the probe cancelled it at 3 s); documented only at Deadline.after(seconds:) ("nil or a non-finite value means no deadline"), not at SolveContext.timeLimit | F6 limits nan | feasible(cancelled) at 3.15 s
HELD | Portfolio(primal,dual,ipm) on 13 netlib vs ReferenceValues: worst rel err 1.33e-11, all optimal and primal feasible <=1e-6; Portfolio(bnb,cpsat) on 30 random small IPs (seeds 1001-1030, 5x12, upper 1/2) equals exhaustive enumeration | F6 portfolio oracle | 0 mismatches
HELD | parallel search vs enumeration across thread counts: BranchAndBound(), CPSAT(), BranchAndBound(engine:Simplex(.dual), nodeSelection:.depthFirst) x threads {1,2,8} on 25 random IPs (seeds 7001-7025, 6x13) | F6 threads diff | 0 mismatching seeds
HELD | memoryBudgetBytes -> .memoryBudget for BranchAndBound and CPSAT (README §2 "Memory is budgeted, partly"): BnB budgets 0/1 KB/16 KB/256 KB/4 MB -> feasible(memoryBudget) with 1/12/71/395/2811 nodes; CPSAT <=16 KB -> noSolution(memoryBudget), 256 KB -> feasible(memoryBudget) with LP propagator dropped (lpSolves=0), 4 MB -> runs to timeLimit with propagator (lpSolves 92,308); negative budget treated as 0; Portfolio splits the budget | F6 memory | as stated
HELD | monotonicity under tighter node limits, deterministic BnB on mipHard nodeLimit 1..2000: incumbent never worse, bound never looser as the limit grows | F6 limits monotone | violations=0
FAIL | Metal kernel tests cannot fail on a broken shader: copy of the package in verification/cycle-B/F6-shadercheck with one invalid line appended to Sources/ZTronLPMetal/Shaders/Kernels.metal; `swift test --filter ZTronLPMetalTests` -> rc=0, "Test run with 28 tests in 3 suites passed", BatchedActivityTests and ReducedCostScanTests skipped: "the GPU tier is unavailable on this machine" (on an M3) | log verification/cycle-B/F6-shadercheck/metal-tests-broken-shader.log | candidate finding (test-integrity)
INFO | IPM threads=1 utilisation 1.54 on transport 100x1200 once; re-runs 1.04 and 0.77 -> not confirmed
INFO | engine names do not identify configuration: BranchAndBound(nodeLimit:3) and (nodeLimit:3000) are both "BranchAndBound<Simplex(.primal)>", Automatic's sparse-QR choice reports "Simplex(.dual)" -> PortfolioAnalysis.winner can be ambiguous

## Findings (final)

### B6-01 (high) Conditioned keeps working after cancellation or the time limit
- claim: SolverStrategy doc (Strategy.swift:193) "Limits and cancellation end in the analysis's status"; README §5 cancellation latency acceptance p99 <= 50 ms (rule L1); WorkGate doc (WorkGate.swift:84-87) "keeps cancellation latency bounded regardless of problem size"; README §2.5 Conditioned row.
- observed: Conditioned(Simplex(.dual)) on InstanceGenerator.constructedOptimum(rows:3500, columns:7000, seed:31, density 0.0015): 6 cancels at random delays -> latency p50 317 ms, worst 778 ms, while Simplex(.dual) alone in the same run: p50 1.7 ms, worst 4.0 ms. timeLimit 0.3 -> returns after 0.588 s (Simplex alone 0.302 s); timeLimit 1 -> 1.60 s. ConditioningAnalyzer.analyze(after:) on the stopped basis alone takes 0.294 s and a cancel after 5 ms does not shorten it (0.366 s).
- why wrong: the inner engine stopped promptly; the decorator then runs an O(m^3) dense LU of the m x m basis (m <= 4,000) with no Task.isCancelled / deadline check, so the run's cancellation and time limit are exceeded by the full analysis time (grows as m^3, roughly 0.3-1 s at 3,500-4,000 rows, more under load).
- location: Sources/ZTronLPOptimizer/Conditioned.swift:39 (analyze runs unconditionally after the inner solve, even when its status is .feasible/.noSolution(stoppedBy: .cancelled/.timeLimit)); Sources/ZTronLPConditioning/ConditioningAnalyzer.swift:209-213 and 471-490 (dense factorization, no gate).
- repro: cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bigcancel conditioned 6 ; .build/release/F6 analyzer ; .build/release/F6 util2
- documented: no. README §2.5 gives Conditioned's time as "inner's plus one analyze" but nothing in §3/§4 or HANDBOOK says the analysis ignores cancellation/time limits.

### B6-02 (medium) InteriorPoint cancellation/time-limit latency is one whole iteration
- claim: WorkGate doc (WorkGate.swift:84-87) "keeps cancellation latency bounded regardless of problem size"; README §5 p99 <= 50 ms (rule L1); IPMWorker.swift:672-673 comment says checking once per iteration satisfies rule L1.
- observed: InteriorPoint() on constructedOptimum(rows:3000, columns:6000, seed:32, density 0.08) (nnz 1,440,811; dense normal equations): 6 cancels -> p50 95 ms, worst 621 ms; timeLimit 0.3 -> 0.741 s; timeLimit 4 -> 4.03 s / 4.53 s.
- why wrong: the gate is checked once per iteration (IPMWorker.swift:674); forming A Theta A^T and the dense Cholesky (IPMWorker.swift:391-418) run without any check, so latency equals one iteration and grows with m^3 and sum z_j^2.
- location: Sources/ZTronLPInteriorPoint/IPMWorker.swift:672-674, 383-430.
- repro: perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bigcancel ipm 6 ; .build/release/F6 util2
- documented: partly: README §5 "What these numbers do not say" disclaims models larger than 2,000 x 20,000; not in §4; WorkGate's doc claim is unqualified.

### B6-03 (medium) Portfolio returns a worse feasible result than one of its members  [see draft above]

### B6-04 (medium) Portfolio calls the progress callback concurrently; listeners see different orders
- claim: EventSink doc (Strategy.swift:222) and README §2.3 "serializes the events of one solve"; Portfolio doc (Portfolio.swift:16-18) "forwarded as it comes, interleaved"; SolveContext.makeEventStream doc "A previously installed progress callback keeps receiving every event".
- observed: Portfolio([BranchAndBound(), BranchAndBound(engine: Simplex(.dual))]) on randomMILP(25x120, seed 99), timeLimit 1, callback with a 20 us critical section: maxConcurrentCallbacks=2 in 3 of 3 runs (BranchAndBound() alone with 8 workers: 1 in 3 of 3). With an EventRecorder plus two makeEventStream on one context, Portfolio([Conditioned(BranchAndBound()), Automatic()]) gives streams whose content differs from the recorder's suffix (suffixMatch=false); every single-strategy case matched exactly.
- location: Sources/ZTronLPOptimizer/Portfolio.swift:42 (members get context.nested(), each member's own EventSink calls the shared closure directly); Sources/ZTronLPCore/Solve/Strategy.swift:266-277 (nested() forwards without serialization), 172-183 (chained listeners).
- repro: .build/release/F6 events concurrency ; .build/release/F6 events nested
- documented: no.

### B6-05 (medium) Metal kernel tests pass with a shader that does not compile
- claim: test names (ReducedCostScanTests.scoresMatchTheDoubleReference, BatchedActivityTests.aPointOnItsBoundsIsNeverRejectedBySinglePrecision, ...); README §5 Building and testing.
- observed: in a copy of the package with an invalid line appended to Kernels.metal: swift test --filter ZTronLPMetalTests -> rc=0, "28 tests in 3 suites passed"; both kernel suites skipped with "the GPU tier is unavailable on this machine" on an Apple M3.
- location: Tests/ZTronLPMetalTests/MetalTestSupport.swift:15-19 (.requiresMetal skips whenever isAvailable is false, which includes .libraryUnavailable); Tests/ZTronLPMetalTests/MetalTierTests.swift:31-45 (status test accepts .libraryUnavailable); MetalTierTests.swift:105-116 only greps the source for the kernel names.
- repro: D=verification/cycle-B/F6-shadercheck; cp -R Package.swift Package.resolved Sources Tests $D/; echo 'this is not valid metal source;' >> $D/Sources/ZTronLPMetal/Shaders/Kernels.metal; cd $D && swift test --filter ZTronLPMetalTests
- documented: no (README §4 Not verified mentions only the precompiled-library path).

### B6-06 (low) Portfolio exceeds SolveContext.threads when threads < number of members
- observed: threads=1: Portfolio(bnb,cpsat) utilisation 1.55, Portfolio(bnb,cpsat,bnb-dual) 1.79 (BnB/CPSAT alone at threads=1: 0.84/0.74).
- location: Sources/ZTronLPOptimizer/Portfolio.swift:44 child.threads = max(1, resolvedThreads / count).
- repro: .build/release/F6 threads util
- documented: README §2.5 "threads ÷ k each" (silent about k > threads); risk 7 recommends SolveContext.threads to share the machine.

## Status: COMPLETE - final JSON written to cycle-B/F6-runtime.json (6 findings B6-01..B6-06, 19 claims held)
