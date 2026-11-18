# Cycle B / F7 — Package integrity (gates, documentation claims, measured numbers, test-suite integrity, layering)

- Cycle: B (oracles first)
- Area: F7, package integrity
- Probe slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B/Slots/F7/
- Repo: /Users/admin/Documents/ZTronLPOptimizer @ d9afebe (read-only)
- Method: derive expectations from first principles (KKT / certificates / enumeration / write-read identity /
  invariances) with independent oracles in slot F7; then compare with README/HANDBOOK/SPEC claims,
  the baseline gate logs and the test suite. Documentation of defects (README §4, HANDBOOK Known gaps)
  read only after results.

## Plan (claims / properties to check)

1. Gates from baseline logs: build -warnings-as-errors, lint, debug suite, release integration+liveness, TSAN.
   Count executed / skipped / failed per target; compare with README "Building and testing" and HANDBOOK "Testing".
   Enumerate skipping tests (XCTSkip, early return, #if, env/corpus gates) and what each hides locally and in CI.
2. Lint (Scripts/lint.sh): rules C2, C3, C6 — patterns that cannot match, partial tree coverage.
3. Layering: actual import graph of Sources/* vs Package.swift vs README/HANDBOOK/SPEC layering claims.
4. README §1 example run verbatim in slot F7; printed numbers vs comments; does ReadmeExampleTests check them.
5. README §2 API tables: each listed declaration exists with stated shape/meaning; notable public API missing.
6. Measured numbers (README §5, HANDBOOK Benchmarks, SPEC v0.2 §1 table): deterministic node/iteration counts,
   objectives, instances closed; timings only gross (>3x) mismatches.
7. Test-suite integrity: loose tolerances, status-only assertions, generators with non-optimal "known optimum"
   (independent check), test names promising more than asserted, flaky timing assumptions.
8. Oracle probes (F7 slot): KKT check of LP optima from generators/fixtures; enumeration for small IPs;
   write-then-read identity (MPS/LP); permutation/scaling/min-max invariance on test-support generators.

## Log (HELD | claim | command | key output  /  FAIL | ...)

HELD | Baseline gates: build -warnings-as-errors rc=0, lint rc=0, debug suite rc=0, release integration+liveness rc=0, TSAN (4 targets) rc=0 | cat verification/baseline/progress.txt | all rc=0; TSAN 838 s
HELD | README §5 "Tests: 546 in 13 targets, debug build" | awk over 03-test-debug.log "Test run with N tests" | 3+47+13+83+28+24+13+17+163+35+3+91+26 = 546 in 13 binaries, 0 failures, 0 swift-testing skips recorded
HELD | README §5 "whole test suite, debug build 4 to 5 minutes" | progress.txt | 250 s
HELD | README §5 release run "passes with one recorded known issue" (for integration+liveness) | grep "known issue" 04-*.log | mod008 cpSatWithoutTheLPPropagator: feasible/timeLimit incumbent 333 vs 307 (withKnownIssue isIntermittent)
HELD | README §5 / HANDBOOK netlib table: pivot counts, IPM iterations, crossover pivots, max rel. error (deterministic) | .build/release/ZTronLPBenchmarks netlib transport (output: verification/cycle-B/F7-bench-netlib-transport.txt) | all 13x5 counts identical; errors identical (6.1e-12 ... 7.9e-16); totals 0.230/0.162/0.077 s under load (~2x, ok)
HELD | README §5 / HANDBOOK transport LP 2000x20000: iterations 1000/1942/1000/1942/12, refactors 11/21/21/40, objective 162355 | same run | identical; seconds 3.83/7.25/0.93/1.31/0.18 (<=2x of published, load)
HELD | README §2 "117 top-level declarations and 22 nested types" | swift-symbolgraph-extract (public) of the 9 modules + scratchpad/F7-scripts/symbols2.py | 117 distinct top-level names (operators merged by name), 22 nested types (18 + 4 NodeLPStrategy State/Worker typealiases); every top-level declaration is named in README §2
INFO | README §2 "about 700 public members and enum cases" | same | 885 (130 enum cases, 394 properties, 179 methods, 64 inits, 62 static methods, 39 static props ...) -- loose claim, ~26% low
HELD | README §5 B&B: "All twenty runs prove the published optimum" (10 MIPLIB3 x primal/dual node engine) | .build/release/ZTronLPBenchmarks mip cpsat (output verification/cycle-B/F7-bench-mip-cpsat.txt; load avg 35) | 20/20 optimal at the reference objective; stein45 40.4 s / 34.2 s (2x published under load; parallel node counts differ as README risk 8 says; lseu it-ratio 2.01 outside the published 0.60-1.65 range of a nondeterministic run)
HELD | README §5 CP-SAT: "7 of 7 optimal" by default, "5 of 7" without LP propagator (mod008, p0201 stop at 60 s) | same run | "proven optimal within the limit: 7 of 7 by default, 5 of 7 without the LP propagator"; mod008 stops at 326, p0201 at 7755
HELD | README §1 example run verbatim (Slots/F7/main.swift lines 1-51 = README lines 89-139, diff-verified) prints the commented numbers | cd verification/probes/cycle-B && .build/debug/F7 | 2600.0 / 56.0 / 1.0 / 2725.0 / 3.1666666666666665 / 2 (iterations; no value claimed)
HELD | ReadmeExampleTests checks the README numbers (2600 vs full enumeration, 56/6/0/1, engine name; relaxation 2725, overtime 0.5, wood 19/6, hours 8/3) | read Tests/ZTronLPOptimizerTests/ReadmeExampleTests.swift; hand KKT of relaxation (basis {c,o}: y_h=8/3, y_w=19/6, rc_t=-20.8, rc_d=-9.2) | consistent
HELD | README §2 defaults: Tolerances (1e-7,1e-7,1e-7,1e-9,1e-14,1e-6,1e-4,1e-6,1e-8), Gap (1e-4,1e-6), Heuristics (100,50,500,128), denseBasisLimit 1500, iterationCap max(50000,100(m+n)), Automatic 4000/10000/0.3, sparseDensity 0.10, sparseMultiplyThreshold 100000, BoundChange 24 B, CompileOptions (true,1e-14), metal .automatic, IPM regularization (1e-8,1e-10), Conditioning options (100,4096), KernelThresholds (3e6,6e6,64,64,1e5,1024,0.05) | .build/debug/F7 defaults | all equal
HELD | KKT oracle (own primal feasibility, dual sign/complementarity in min form from dual(model sense), c - A^T y vs reported reducedCosts, logical rc == dual (Analysis.swift:13-15), duality gap) on InstanceGenerator.constructedSuite(count:100, seed:11, maxSize:(50,100)) | .build/debug/F7 kkt 100 11 50 100 (Slots/F7/Probes.swift) | Simplex primal/dual/dual-nopresolve, IPM+lite, Automatic: 100/100 optimal, pinf<=2.7e-14, dsign<=1.7e-15, rc/logical mismatch 0, gap<=2.9e-14; IPM(.none) 1.3e-8 (tolerance-level)
HELD | Certificates in both senses: Farkas dual ray and improving primal ray (CertificateTests constructions, also on maximize, which the tests filter out) | .build/debug/F7 rays 60 404 | min: 120/120 infeasible with valid ray, 120/120 unbounded with valid ray; max: same 120/120 and 120/120
HELD | lint C2/C3/C6 hold on the current tree, and no lint-evading construct is present (no private(set) globals, spaced static vars, split @unchecked, locks, queue.sync, Darwin.sleep, waitUntilScheduled in Sources/Tests/demo) | grep (see log) + baseline 02-lint.log | 1 @unchecked Sendable (Sparse.swift:329, with INVARIANT)
FAIL | lint.sh enforces C2/C3/C6 as claimed (header lines 5-8; HANDBOOK Testing "no blocking primitives") | copy of Scripts/lint.sh run on synthetic tree verification/cycle-B/F7-lint (one violation per file): bash verification/cycle-B/F7-lint/Scripts/lint.sh | caught: plain global var, `static var a = 0`, @unchecked without INVARIANT. MISSED: `public private(set) var`, indented file-scope var in #if, `static var b : Int = 0`, multi-line static var, @unchecked Sendable with a neighbouring declaration's INVARIANT, `@unchecked`/`Sendable` split over lines (not even counted), DispatchQueue.sync, NSLock, NSCondition.wait, Darwin.sleep, MTLCommandBuffer.waitUntilScheduled (a blocking command-buffer wait); C3 and C6 never look at Tests/ (Tests/TT with @unchecked, Thread.sleep, DispatchSemaphore passes). Latent: Swift 6 mode catches the C2 cases at compile time; none present today.
HELD | README §5 Hilbert table: condition estimates, dense-solve error, per-engine distance, objective worst error, "every solve at every order ends optimal" | .build/debug/F7 hilbert (Slots/F7/Hilbert.swift) | all 120 solves optimal; numbers agree to the printed digit (e.g. order 8: 3.4e10, 1.0e-6, 4.0e-7, 8.7e-7, 7.6e-7, 3.4e-16; order 12: 3.9e16, 0.61, 1.68, 1.68, 3.12 -> "2,2,3")
FAIL | README §5 Hilbert table column "Answers with a warning": order 4 "0 of 12", order 5 "3 of 12" | .build/debug/F7 hilbert ; .build/debug/F7 hilbertwarn 4 5 6 | observed 4/12 at order 4 and 4/12 at order 5: InteriorPoint() attaches "N column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)" to every Hilbert answer from order 4 (stall warning only on 3 of 4 forms at order 5). Low (doc number).
HELD | Every fragile Hilbert answer (orders 9-12, 9 strategies of IllConditionedTests, 144 solves) carries a warning other than the dense-column note | .build/debug/F7 hilbertonly 9 10 11 12 | 0 answers with only the dense-column warning; but note IllConditionedTests.beyondDoublePrecisionNothingIsCalledInfeasible asserts only !warnings.isEmpty, which the IPM's unconditional dense-column warning satisfies by itself (latent weakness)
HELD | Import graph vs Package.swift: every `import` of Sources/* is a declared dependency; no engine imports ZTronLPMetal (Package.swift comment, HANDBOOK decision 2); facade @_exported-imports the 8 library targets, not TestSupport (README §2) | grep import over Sources/* (see log) | Core{Atomics,Foundation} Numerics{Core,CLAPACKShim,Atomics,Accelerate} Metal{Core,Numerics,Metal} Simplex{Core,Numerics} IPM{Core,Numerics,Simplex} Conditioning{Core,Numerics} B&B{Core,Numerics,Simplex,IPM,Atomics,HeapModule} CPSAT{Core,Numerics,Simplex,Atomics} Optimizer{all 8} TestSupport{Core}
FAIL | HANDBOOK Targets: "Each layer imports only the layers beneath it; branch and bound and CP-SAT are the two that import an LP engine (§3)"; SPEC v0.2 §2.1 "each layer imports only layers beneath it" | grep -n "^import" Sources/ZTronLPInteriorPoint/*.swift | ZTronLPInteriorPoint (an LP engine, Package.swift "MARK: Layer 3" with Simplex) imports ZTronLPSimplex; Package.swift's own comment documents the edge, HANDBOOK and SPEC deny it. Low.
FAIL | Package.swift: CPSAT target depends on heap, orderedCollections, bitCollections; comment "Heap / OrderedDictionary / BitSet" | grep -rn "import" Sources/ZTronLPCPSAT | no CPSAT file imports HeapModule, OrderedCollections or BitCollections; OrderedDictionary/BitSet used nowhere in Sources (only Heap, in B&B SearchTree.swift). Info/low: stale declared deps.
INFO | ci.yml:50 "Rule C10: Thread Sanitizer is clean on the integration suite with threads = 8" | grep threads Tests/ZTronLPIntegrationTests; SolveContext.resolvedThreads = activeProcessorCount | integration tests never set threads; on a GitHub macos-latest runner (3 vCPU) TSAN runs with 3 workers, not 8
FAIL(low) | Test name BranchAndBoundRandomTests.mixedModelsAgreeAcrossStrategiesAndWorkerCounts | read Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:187-205 | one strategy (BranchAndBound(engine: Simplex(.dual))) at threads 1/2/8; no second strategy, no reference optimum (self-agreement within 1e-4)
HELD | L7 sixteenMegabytesIsEnoughAndIsRespected scenario really ends optimal under 16 MB (the assertion also accepts a memoryBudget stop, so it is weaker than its name) | .build/debug/F7 budget (Slots/F7/Budget.swift) | 16 MB -> optimal 599, 7499 nodes; default -> optimal 599
HELD | README §2: Simplex() is .dual; Portfolio([]) throws .unsupported; Solution.value/reducedCost of an absent variable = 0, dual(ofConstraintNamed: unknown) = nil; event stream: .finished last and unique, simplexIteration at most every 100 pivots; fromTriplets sums duplicates and drops zeros; MemoryBudget.resolve = available/4 | .build/debug/F7 api2 (Slots/F7/Api2.swift) | dual=true; "unsupported: a portfolio needs at least one strategy"; 0/0/nil; degen2 1011 pivots -> 11 iteration events, 1 finished, last; nnz 1, a00 3; 25769803776/6442450944 = 4.0
HELD | README §5 "Thread Sanitizer: No reports on the simplex, interior-point, ... facade ... targets" (not covered by CI's or the baseline's TSAN filter) | env ZTRONLP_LATENCY_SCALE=20 swift test --sanitize=thread --scratch-path <scratchpad>/build-tsan --filter 'ZTronLPSimplexTests|ZTronLPInteriorPointTests|ZTronLPOptimizerTests' (log verification/cycle-B/F7-tsan-simplex-ipm-facade.log) | rc=0; 47 + 13 + 13 tests passed; 0 ThreadSanitizer reports
HELD | README §2 tables: every backticked member of a row exists on that type, and every labelled signature (inits such as Simplex(_:pricing:factorization:perturbation:maxIterations:presolve:scaling:tolerances:), BranchAndBound(engine:...:seed:), CPSAT(workers:...:deterministic:), WorkGate init(deadline:checkEvery:yieldEvery:), analyze(_:basis:primal:context:options:budget:), ...) matches the public symbol graph | scratchpad/F7-scripts/members.py and inits.py over swift-symbolgraph-extract output | 0 real mismatches (48 member-check hits are cross-type references such as status cases / LAPACK names; 1 signature hit is the shorthand read(contentsOf:) for read(contentsOf:options:))
HELD | README §5 / HANDBOOK Metal: "the 64 candidates agree with fp64 every time"; thresholds n >= 3e6, nnz >= 6e6; speed-ups within the published ranges | .build/release/ZTronLPBenchmarks metal latency (output verification/cycle-B/F7-bench-metal-latency.txt) | 64 of 64 at all three sizes; 0.73x / 1.14x / 1.49x (ranges 0.35-1.23, 1.08-1.89, 1.17-2.30); thresholds as stated
HELD | README §5 cancellation latency: p99 <= 50 ms acceptance over 240 solves | same run (load avg up to 28) | p99 11.25 ms, max 14.27 ms (published quiet-machine 3.64/4.43; README says p99 57 ms under 5-8x load) -- within load explanation
FAIL | MIPLIBCorpusTests slow cases in debug builds | cd /Users/admin/Documents/ZTronLPOptimizer && swift test --filter 'MIPLIBCorpusTests/cpSatWithoutTheLPPropagator' (log verification/cycle-B/F7-debug-cpsat-nolp.log) | "with 6 test cases passed after 4.107 seconds", no known issue, although the mod008 case has a 60 s limit it cannot prove (release: 75.9 s + known issue). Also baseline TSAN: same test 66.5 s, no known issue.

## Findings

### B7-01 (medium, test-integrity) Twelve MIPLIB corpus cases pass silently in every debug build, including CI's test job and its Thread Sanitizer job
- claim: HANDBOOK Testing: "tests that need a missing instance report a known issue instead of failing"; "A debug build runs a reduced corpus"; ci.yml:50 "Rule C10: Thread Sanitizer is clean on the integration suite"; README §5 "Thread Sanitizer: No reports on the ... branch-and-bound, CP-SAT, ... integration and liveness targets"; CorpusTests.swift:144-148 "CP-SAT as it runs by default ... proves every pure-integer instance of the set optimal".
- observed: CorpusTests.swift:125/151/171 `guard !Self.slow.contains(instance.name) || Slow.enabled else { return }` with Slow.enabled false in any DEBUG build without ZTRONLP_SLOW_TESTS=1 (CorpusTests.swift:9-17). 12 of the 23 MIPLIB parameter cases (BranchAndBound x2 engines on stein45/lseu/enigma/mod008; CPSAT() on stein45/lseu/mod008/p0201; CPSAT(lpPropagator:false) on stein45/lseu/enigma/mod008) return before solving and are reported "passed" -- no skip, no known issue. Debug: `cpSatWithoutTheLPPropagator ... 6 test cases passed after 4.107 seconds` (mod008 alone needs its 60 s limit); release: 75.9 s and the mod008 known issue; baseline TSAN (debug): 66.5 s, no known issue. CI's build-and-test (`swift test`) and thread-sanitizer jobs are debug builds, so TSAN never runs the largest parallel searches (stein45 B&B 55k nodes, CP-SAT portfolios on stein45/lseu/mod008/p0201).
- why wrong: a case that executes nothing is counted as a pass (546 "passed"); the package itself uses `.enabled(if:)` (SATTests) or withKnownIssue to make such gaps visible. The TSAN gate's coverage is materially smaller than README §5 and ci.yml state.
- location: Tests/ZTronLPIntegrationTests/CorpusTests.swift:9-17, 125, 151, 171; .github/workflows/ci.yml:62-65
- repro: `cd /Users/admin/Documents/ZTronLPOptimizer && swift test --filter 'MIPLIBCorpusTests/cpSatWithoutTheLPPropagator'` (passes in ~4 s, no known issue) vs `swift test -c release --filter 'MIPLIBCorpusTests/cpSatWithoutTheLPPropagator'` (~76 s, known issue); `grep -n "Test cpSatWithoutTheLPPropagator\|known issue" verification/baseline/0[345]*.log`
- documented: partly. HANDBOOK Testing says a debug build runs a reduced corpus and ZTRONLP_SLOW_TESTS=1 adds the slow instances; it does not say the omitted cases report as passed, nor that the TSAN job (debug, no ZTRONLP_SLOW_TESTS) excludes them. README §5 TSAN row omits it.
- confidence: reproduced

### B7-02 (low, test-integrity) Scripts/lint.sh enforces less than rules C3 and C6 (and C2) say; C3/C6 never look at Tests/
- claim: Scripts/lint.sh:5-8 ("C3 every @unchecked Sendable is listed and must carry an // INVARIANT: comment"; "C6 no DispatchSemaphore, Thread.sleep, blocking command-buffer wait or DispatchGroup wait"); HANDBOOK Testing ("every @unchecked Sendable listed with its invariant, no blocking primitives"); SPEC v0.2 §2.2 ("no new @unchecked Sendable (the count stays at one); Scripts/lint.sh must hold after every package").
- observed: on a synthetic tree with one violation per file, lint flags only `var plainGlobal = 0`, `static var a = 0` and an INVARIANT-less `@unchecked Sendable`. It passes: `@unchecked` and `Sendable` on separate lines (not even counted), an @unchecked Sendable whose only `// INVARIANT:` belongs to a neighbouring declaration within 8 lines, `MTLCommandBuffer.waitUntilScheduled()` (a blocking command-buffer wait), `DispatchQueue.global().sync {}`, `NSLock`, `NSCondition.wait()`, `Darwin.sleep(1)`, `public private(set) var`, an indented file-scope var in `#if`, `static var b : Int = 0`, a static var initialised on the next line; a Tests/ file with @unchecked Sendable, Thread.sleep and DispatchSemaphore.
- why wrong: line-based greps with fixed spellings; C3/C6 scan Sources only (lint.sh:21-23, 61, 66-67). Latent: no such construct is in the tree today, and Swift 6 mode rejects the C2 cases at compile time, but not the C3/C6 ones.
- location: Scripts/lint.sh:21-23, 35, 40, 57, 61, 66-67
- repro: `bash /Users/admin/Documents/ZTronLPOptimizer/verification/cycle-B/F7-lint/Scripts/lint.sh` (verbatim copy of Scripts/lint.sh; its ROOT is verification/cycle-B/F7-lint, whose Sources/T and Tests/TT hold the cases) -> rc=1 with only 3 hits
- documented: no
- confidence: reproduced

### B7-03 (low, doc-claim-false) README §5 Hilbert table: the "Answers with a warning" column is wrong at orders 4 and 5
- claim: README.md:615-616: order 4 "0 of 12", order 5 "3 of 12"; text: "The warnings at orders 5 and 6 are the interior point's, whose normal equations stall there"; "Measured with the engines as they are now."
- observed: 4 of 12 at order 4 and 4 of 12 at order 5. InteriorPoint() attaches "N column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)" (IPMWorker.swift:639) to every Hilbert answer from order 4; at order 5 the stall warning is on 3 of 4 forms. Every other cell of the table (condition estimate, dense solve, distances, objective error, all 120 optimal) matches.
- why wrong: deterministic count, differs from the table; the dense-column warning is the one README §4 Limits documents.
- location: README.md:615-616; Sources/ZTronLPInteriorPoint/IPMWorker.swift:639
- repro: `cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B && .build/debug/F7 hilbert` ; `.build/debug/F7 hilbertwarn 4 5 6`
- documented: no
- confidence: reproduced

### B7-04 (low, test-integrity) IllConditionedTests' "an answer this fragile must carry a warning" cannot fail for InteriorPoint()
- claim: Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:99 `#expect(!analysis.warnings.isEmpty, "... an answer this fragile must carry a warning")`; README §4 defect 9 "The answer carries a warning that the optimal basis is ill-conditioned".
- observed: InteriorPoint() (and Portfolio when the IPM answer wins) always carries the dense-column note on these dense matrices (orders >= 4), so the assertion holds whether or not an ill-conditioning/stall warning is produced. Today every fragile answer also carries a relevant warning (0 of 144 solves at orders 9-12 have only the dense-column note), so nothing is hidden yet.
- location: Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:99
- repro: `.build/debug/F7 hilbertwarn 4 5 6` (dense note on every IPM answer); `.build/debug/F7 hilbertonly 9 10 11 12`
- documented: no
- confidence: reproduced

### B7-05 (low, doc-claim-false) HANDBOOK and SPEC v0.2 say each layer imports only the layers beneath it; ZTronLPInteriorPoint imports ZTronLPSimplex
- claim: HANDBOOK.md:134 "Each layer imports only the layers beneath it; branch and bound and CP-SAT are the two that import an LP engine (§3)"; SPECIFICATION-v0.2.md:57 "The layering of v0.1 §3 stands: each layer imports only layers beneath it."
- observed: Sources/ZTronLPInteriorPoint/InteriorPoint.swift:12 `import ZTronLPSimplex` (and Package.swift lists it), an LP engine importing another engine of the same layer (Package.swift "MARK: Layer 3"). Package.swift:13-16 documents this edge itself; HANDBOOK and SPEC deny it. Every other import matches Package.swift.
- location: HANDBOOK.md:134; SPECIFICATION-v0.2.md:57; Sources/ZTronLPInteriorPoint/InteriorPoint.swift:12
- repro: `grep -rn "^import" /Users/admin/Documents/ZTronLPOptimizer/Sources/ZTronLPInteriorPoint/*.swift`
- documented: in Package.swift comments only
- confidence: reproduced

### B7-06 (low, test-integrity) mixedModelsAgreeAcrossStrategiesAndWorkerCounts runs one strategy
- claim: test name (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:187) promises agreement across strategies and worker counts.
- observed: the body runs only BranchAndBound(engine: Simplex(.dual)) at threads 1, 2, 8 and compares the runs with each other (1e-4 relative); no second strategy, no reference optimum.
- location: Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:187-205
- repro: `sed -n 187,205p /Users/admin/Documents/ZTronLPOptimizer/Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift`
- documented: no
- confidence: code-reading-only

### B7-07 (info, other) Package.swift declares Heap, OrderedCollections and BitCollections for ZTronLPCPSAT, which imports none of them
- claim: Package.swift:69-70 "Heap / OrderedDictionary / BitSet"; Package.swift:159 CPSAT dependencies `atomics, heap, orderedCollections, bitCollections`.
- observed: no file of Sources/ZTronLPCPSAT imports HeapModule, OrderedCollections or BitCollections; OrderedDictionary/OrderedSet/BitSet/BitArray appear nowhere in Sources; Heap is used only by ZTronLPBranchAndBound/SearchTree.swift.
- location: Package.swift:69-70, 159
- repro: `grep -rnE "import (HeapModule|OrderedCollections|BitCollections)|OrderedDictionary|BitSet" /Users/admin/Documents/ZTronLPOptimizer/Sources`
- documented: no
- confidence: reproduced

### B7-08 (info, doc-claim-false) ci.yml's TSAN rule says threads = 8; nothing sets it
- claim: .github/workflows/ci.yml:50 "Rule C10: Thread Sanitizer is clean on the integration suite with threads = 8."
- observed: ZTronLPIntegrationTests never sets SolveContext.threads; resolvedThreads defaults to ProcessInfo.activeProcessorCount (Strategy.swift:163-165), i.e. 3 on a GitHub macos-latest arm64 runner. 8 holds only on an 8-core machine (as in the baseline).
- location: .github/workflows/ci.yml:50, 62-65; Sources/ZTronLPCore/Solve/Strategy.swift:163-165
- repro: `grep -rn "threads" /Users/admin/Documents/ZTronLPOptimizer/Tests/ZTronLPIntegrationTests`
- documented: no
- confidence: code-reading-only

HELD | README.md:713 "The release run of eight targets (core, simplex, interior point, branch and bound, CP-SAT, facade, integration, liveness) passes with one recorded known issue (defect 1)" | swift test -c release --filter 'ZTronLPCoreTests|ZTronLPSimplexTests|ZTronLPInteriorPointTests|ZTronLPBranchAndBoundTests|ZTronLPCPSATTests|ZTronLPOptimizerTests' > verification/cycle-B/F7-release-six-targets.log, plus baseline 04-test-release-integration-liveness.log | six targets rc=0: 47+13+13+163+91+26 = 353 tests passed, 0 known issues, 0 failures; baseline integration 17 + liveness 24 passed with exactly 1 known issue (cpSatWithoutTheLPPropagator mod008, defect 1). Eight targets, 394 tests, one known issue.

FINAL | F7-integrity.json written; 8 findings (B7-01 medium, B7-02..B7-06 low, B7-07..B7-08 info), 6 overflow items
NOTE | B7-01 refined after re-reading ci.yml:19-65: the release 'corpora' job does run the 12 slow MIPLIB cases (correctness covered in CI); only the debug test job and the TSAN job omit them (TSAN still runs the smaller parallel B&B searches). B7-01 evidence and B7-03 table rows re-verified (F7-debug-cpsat-nolp.log:141, baseline 05-tsan.log:379, 04 log:246; F7 hilbert rerun rows 4 and 5 identical; lint copy rerun identical).
HELD | B7-04 evidence re-verified | .build/debug/F7 hilbertonly 9 10 11 12 | order 9: 36 solves, far 30, any warning 36, only dense 0; orders 10-12: 36/36/36/0
