# Cycle A / F7 — Package integrity (gates, documentation claims, measured numbers, test-suite integrity, layering)

- Cycle: A (claims first)
- Area: F7 Package integrity
- Probe slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/F7/
- Package: /Users/admin/Documents/ZTronLPOptimizer @ d9afebe (Swift 6.4, Apple M3, 8 cores, macOS 27)
- Method: list concrete claims from README / HANDBOOK / SPEC v0.2 (§1-§2) / doc comments / test names, then try to
  falsify each with an executable check (probe in slot F7 or targeted `swift test --filter`). Order by user cost.
- Log format: "HELD | claim | command | key output" or "FAIL | ...", findings appended in full.

## Plan (claims / properties to check)

1. Gates (baseline logs): build -warnings-as-errors, lint, debug suite, release integration+liveness, TSAN — exit codes,
   executed / skipped / failed counts per target vs README "Building and testing" and HANDBOOK "Testing".
2. Skipping tests: XCTSkip, early returns, #if, env / corpus gates — what each hides locally and in CI.
3. Lint (Scripts/lint.sh): do C2, C3, C6 patterns match what they claim; tree coverage; patterns that can never match.
4. Layering: actual `import` graph of Sources/* vs Package.swift vs README / HANDBOOK / SPEC layering claims.
5. README §1 example run verbatim in slot F7: printed numbers vs comments; ReadmeExampleTests checks them?
6. README §2 API tables: declarations exist with stated shape; notable public declarations missing.
7. Measured numbers: README §5, HANDBOOK Benchmarks, SPEC v0.2 §1 table — deterministic node counts, iteration
   counts, objectives, instances closed (ZTronLPBenchmarks workloads). Timing only gross (>3x) mismatches.
8. Test-suite integrity: loose tolerances, status-only assertions, generator "known optimum" not optimal (check a few
   independently), test names promising more than asserted, flaky timing assumptions.
9. TestSupport: Fixtures reference values (re-derive a few), DIMACS parser, LivenessHarness.
10. Scripts fetch-miplib / fetch-satlib and CI workflow: what CI actually runs vs claims.

## Log
HELD | Gates: build -warnings-as-errors rc=0, lint rc=0, debug suite rc=0, release integration+liveness rc=0, TSAN rc=0 (4 targets) | baseline/progress.txt + logs | 01 rc=0 31s; 02 "lint: all rules hold" (1 @unchecked); 03 13 runs, 546 tests (3+47+13+83+28+24+13+17+163+35+3+91+26) all passed, 0 skipped, 0 known issues; 04 integration 24 + liveness 17 passed, 1 known issue (cpSatWithoutTheLPPropagator mod008); 05 TSAN 24+17+91+26 passed, 0 "ThreadSanitizer" lines
HELD | README "Tests: 546 in 13 targets, debug build" | sum of "Test run with N tests" in baseline/03-test-debug.log | 546
HELD | README §1 example prints the commented numbers | probe F7 (main.swift, README lines 89-139 extracted by sed verbatim) `.build/release/F7 readme` | 2600.0 / 56.0 / 1.0 / 2725.0 / 3.1666666666666665 / 2 (iterations)
HELD | ReadmeExampleTests checks those numbers (2600 by enumeration, 56/6/0/1, engine name, 2725, 19/6, 8/3) | read Tests/ZTronLPOptimizerTests/ReadmeExampleTests.swift + independent LP-dual hand derivation (basis {c,o}: y_h=8/3, y_w=19/6; MIP o=1 vertex c=56,t=6 unique) | consistent
HELD | README §2 defaults (Tolerances, denseBasisLimit 1500, iterationCap max(50000,100(m+n)), sparseMultiplyThreshold 100000, sparseDensity 0.10, refactorInterval 100/50, KernelThresholds 3e6/6e6/64/64/1e5/1024/0.05, Automatic 4000/10000/0.3, Heuristics 100/50/500/128, Gap 1e-4/1e-6, B&B pseudocost(4)+plunging(32)+primal engine, CPSAT luby(100) lp:true, IPM lite/200/1e-8/1e-10, Options 100/4096, CompileOptions true/1e-14, budget = 1/4 of 24 GB) | `.build/release/F7 defaults` | all equal to README values
HELD | Automatic.choice rules (<=4000 dual; >4000 IPM; >10000 rows with a column >30% dense sparseSimplex; boundary strict) | `.build/release/F7 defaults` | 4000->dual, 4001->ipm, 10000+dense->ipm, 10001 w/ 3000 (=30%)->ipm, 3001->sparseSimplex
HELD | Layering: imports of Sources/* vs Package.swift: no engine imports Metal; IPM->Simplex the only engine-engine edge besides B&B/CPSAT; all BLAS/LAPACK via ztlp_* shim | grep of import lines per target; grep for cblas_/dgetrf etc. | as documented (decision 1/2)
HELD | README §5 netlib table: dims, nonzeros (A without objective), primal/dual pivots, IPM its, crossover pivots, rel. errors (HANDBOOK output) | `.build/release/F7 netlib` (Slots/F7/Probes.swift) | all 13 rows identical: afiro 27x32 83 16/14/10/1 6.1e-12 ... degen2 444x534 3978 1011/539/13/127 7.9e-16; all optimal
HELD | Oracle 1 (InstanceGenerator.constructedOptimum / constructedSuite) gives a truly optimal x*,y*: independent KKT certificate incl. row-dual signs, complementarity and duality gap, on every suite the tests use (debug 3x100, release 3x1000, fixture 40, certificate 2x40) and Hilbert 3/8/12 x 4 forms | `.build/release/F7 gen` | 0 failing instances; worst primal viol 0, sign viol 0, duality gap <= 2.4e-13, objective mismatch 0
FAIL | README §5 Hilbert table, column "Answers with a warning": order 4 "0 of 12", order 5 "3 of 12" | `.build/release/F7 hilbert 3 12` and `.build/release/F7 hilbertwarn 3 6` (Slots/F7/Probes.swift, Extra.swift) | order 4: 4 of 12 (every InteriorPoint() answer: "4 column(s) have more than 30% nonzeros; the normal equations will be dense"), order 5: 4 of 12 (3 stalled + 1 dense-only). The column counts only stall warnings. All other cells match: cond 7.5e2..3.9e16, dense 1.2e-15..6.1e-1, dual/primal/IPM distances (order 8: 4.0e-7/8.7e-7/7.6e-7; order 9+: 1.0..3.1), objective errors 1.2e-16..7.9e-12, orders 6-12 warning counts 4/12/12/12/12/12/12, every answer optimal
FAIL | Scripts/lint.sh enforces C2/C3/C6 ("CI runs this; it exits non-zero on the first rule that is broken") | mutation test: copy of lint.sh run on injected one-line violations, verification/cycle-A/F7-lint-mutation/ (commands in the log of this session; rerun recipe in finding A7-0x) | caught: nonisolated(unsafe) in Sources+Tests, `var x`/`public var x` at col 0, any `static var x =`, @unchecked w/o INVARIANT (Sources), DispatchSemaphore/Thread.sleep/waitUntilCompleted/DispatchGroup/usleep(/indented sleep(. NOT caught: `@MainActor var x = 0`, `public private(set) var x = 0`, an indented global inside `#if`, `sleep(1)` at column 0, nanosleep/NSLock/DispatchQueue.sync/waitUntilScheduled, and every C2-global/C3/C6 violation placed under Tests/ (only nonisolated(unsafe) is checked in Tests/). No current violation exists anywhere in Sources/ or Tests/ (grep), so the gap is latent.
HELD | README §5 / HANDBOOK benchmark netlib + transport rows (pivots, refactorizations, IPM its, objective 162355; timings within load) | `cd /Users/admin/Documents/ZTronLPOptimizer && swift build -c release --product ZTronLPBenchmarks && .build/release/ZTronLPBenchmarks netlib transport` (output saved in cycle-A/F7-bench-netlib-transport.txt) | every count identical to HANDBOOK output; totals 0.145/0.111/0.054 s vs 0.112/0.087/0.038 (load avg ~10); transport 1000/11, 1942/21, 1000/21, 1942/40, IPM 12, all 162355.0000
HELD | README §2 API tables: every listed member name exists (Python scan over Sources) and ~300 listed declarations compile with the README's labels/shapes (Slots/F7/APIShapes.swift, never executed) | `swift build -c release --product F7` | Build complete after fixing only my own guesses (argument order of add/setObjective, map types of CompiledModel, payloads of enum cases the README names without them). No README entry absent. Note: LPFormat.write is `throws` (README row does not say writing throws)
HELD | MIPLIB benchmark: all 10 instances x 2 node engines optimal at the published objective | `.build/release/ZTronLPBenchmarks mip` (cycle-A/F7-bench-mip.txt) | 20/20 optimal, objectives 3089/18/30/0/1120/307/1201500/568.1007/3360/7615; stein45 35.9 s / 32.6 s under load (README 19.6/15.9: <2x); node counts differ (parallel search, risk 8): e.g. enigma primal/dual LP-it ratio 5.11 in this run vs README range 0.60-1.65
HELD | README §5 "Thread Sanitizer: no reports on the simplex, interior-point, branch-and-bound, CP-SAT, facade, integration and liveness targets" (baseline gate covered only integration, liveness, B&B, CP-SAT) | `ZTRONLP_LATENCY_SCALE=20 perl -e 'alarm shift; exec @ARGV' 2400 swift test --sanitize=thread --scratch-path <scratchpad>/build-tsan --filter 'ZTronLPSimplexTests|ZTronLPInteriorPointTests|ZTronLPOptimizerTests'` (log cycle-A/F7-tsan-simplex-ipm-facade.log) | 47 + 13 + 13 tests passed, 0 "ThreadSanitizer" lines, 0 failures. Note: neither CI nor HANDBOOK's TSAN gate runs these three targets, so the claim is not regression-protected
HELD | README §5 "in deterministic mode the nine MIPLIB 3 instances other than stein45 reach the same optima" + README §1 item 6 "BranchAndBound(deterministic: true) gives the same result every run" | `cd verification/probes/cycle-A && F7_LIMIT=60 perl -e 'alarm shift; exec @ARGV' 1500 .build/release/F7 bnbdet` (cycle-A/F7-bnbdet.txt) | 9 instances x {primal, dual} node engine x 2 runs: all optimal at the published objective (rel. err <= 2.0e-16), node counts and LP iterations identical between the two runs (e.g. enigma dual 24460 nodes / 594890 LP its both runs; lseu primal 27187 / 118719); slowest 2.33 s
HELD-ish (info) | Benchmark latency rows count a solve that returned before Task.cancel() as latency 0 (LivenessHarness.swift:45-48) | `.build/release/F7 latency` (cycle-A/F7-latency.txt; same instances, windows and seed as ZTronLPBenchmarks latency) | Simplex(.primal) 30 interrupted / 8 zero / 2 finished after the cancel; InteriorPoint 9 / 8 / 23; BranchAndBound 35 / 5 / 0. With 40 samples p99 = max, so p99/max are unaffected; p50 moves 0.16->0.21 ms (primal). Worst 8.05 ms (IPM) < 50 ms. Not a finding beyond info
FAIL | BranchAndBoundTests.memoryBudgetDegradesThenStops / L7 sixteenMegabytesIsEnoughAndIsRespected can catch a budget that is not honoured | `.build/release/F7 membudget` (Slots/F7/Extra.swift: the test's own instance randomMILP(12, 60, seed 4242), BranchAndBound(nodeSelection: .bestBound, heuristics: .none)) | 2,000 B: noSolution(stoppedBy: memoryBudget) after 19 nodes; 4,096 B: same after 29; 16 MiB: optimal 593, 3191 nodes; no budget: optimal 593, 3269 nodes. The test asserts `stopReason == .memoryBudget || status == .optimal`, which the no-budget result satisfies -> a solver that ignored the budget passes. See A7-01

## Findings

### A7-01 (medium, test-integrity, reproduced) The memory-budget tests accept the result of a solve that ignores the budget
- Claim: L7 suite doc (Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:186-188) "the node pool respects the budget; exceeding it degrades (drops bases) and, if still exceeded, stops with .feasible(stoppedBy: .memoryBudget)"; test names `sixteenMegabytesIsEnoughAndIsRespected` (L3ToL10Tests.swift:190) and `memoryBudgetDegradesThenStops` (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:241); README §2 BranchAndBound Space "open nodes, held under the memory budget"; HANDBOOK "The liveness rules of §12.2 each have a test".
- Observed: both tests assert `status == .optimal || stopReason == .memoryBudget` (L3ToL10Tests.swift:198, BranchAndBoundTests.swift:246). Neither reads a byte count, a dropped-basis count or a warning, so neither checks "respected" or "degrades". On the BranchAndBoundTests instance and solver the probe gives: 2,000 B -> noSolution(stoppedBy: memoryBudget) after 19 nodes; 4,096 B -> same after 29; 16 MiB -> optimal 593 (3191 nodes); no budget -> optimal 593 (3269 nodes). The unbudgeted result satisfies both assertions.
- Why wrong: a regression that stops enforcing the budget (or the degrade step in SearchTree.checkGapAndMemory, SearchTree.swift:428-462), or that undercounts openBytes, turns the 2,000-byte case into `.optimal`, which the test accepts; the 16 MiB test cannot fail on a pool that grows past 16 MiB. Mitigation: `aBudgetTooSmallForTheTreeStopsWithTheIncumbent` (4,096 B, L3ToL10Tests.swift:202-215) and the L10 exit-path test require `.memoryBudget`, so a budget ignored entirely is still caught; a loosely honoured budget or a dead degrade step is not.
- Location: Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:246; Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:198
- Repro: `cd verification/probes/cycle-A && swift build -c release --product F7 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F7 membudget` (Slots/F7/Extra.swift memBudget: randomMILP(rows 12, columns 60, seed 4242, upper 1), BranchAndBound(nodeSelection: .bestBound, heuristics: .none), budgets 2000/4096/16 MiB/nil)
- Evidence: "budget 2000: noSolution(stoppedBy: ZTronLPCore.StopReason.memoryBudget) nodes 19" ... "budget nil (default): optimal nodes 3269 objective 593.0"
- Documented: no (README risk 4 says the budget counts open nodes and clauses only; nothing says these tests do not check the budget)

### A7-02 (low, doc-claim-false, reproduced) README §5 Hilbert table: "Answers with a warning" is wrong for orders 4 and 5
- Claim: README.md:615-616: order 4 "0 of 12", order 5 "3 of 12".
- Observed: order 4: 4 of 12 (all four InteriorPoint() answers carry "4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"); order 5: 4 of 12 (3 stall warnings + 1 dense-column warning). Every other cell of the table (condition estimates 7e2..4e16, dense-solve and per-engine distances, objective errors, warning counts for orders 3 and 6-12) reproduces.
- Why wrong: the column apparently counted stall/ill-conditioning warnings only, but `SolutionAnalysis.warnings` also carries the IPM dense-column warning (Sources/ZTronLPInteriorPoint/IPMWorker.swift:638-639), which every Hilbert matrix of order >= 4 triggers.
- Location: README.md:615-616 (warning source Sources/ZTronLPInteriorPoint/IPMWorker.swift:638)
- Repro: `cd verification/probes/cycle-A && .build/release/F7 hilbert 3 12; .build/release/F7 hilbertwarn 3 6`
- Evidence: "order 4 ... warned 4 of 12"; hilbertwarn order 4: InteriorPoint on each of the 4 forms: "4 column(s) have more than 30% nonzeros; the normal equations will be dense"
- Documented: no

### A7-03 (low, test-integrity, reproduced) Scripts/lint.sh misses violations inside its own stated scope
- Claim: Scripts/lint.sh:2-8 "CI runs this; it exits non-zero on the first rule that is broken ... C2 no global mutable variables in library code ... C3 every @unchecked Sendable is listed ... C6 no DispatchSemaphore, Thread.sleep, blocking command-buffer wait or DispatchGroup wait"; HANDBOOK "no global mutable state ... no blocking primitives"; SPEC v0.2 §2.2 "no new @unchecked Sendable (the count stays at one)".
- Observed (mutation test on a copy of the script, one injected line per run): rc=0 (not caught) for `@MainActor var counter = 0` in Sources; `    try? await commandBuffer.waitUntilScheduled()` (a blocking command-buffer wait; only waitUntilCompleted is listed); `sleep(1)` starting in column 0 (the pattern '[^A-Za-z_.]sleep\(' needs a preceding character); `nanosleep(&ts, nil)`; any `@unchecked Sendable` without INVARIANT under Tests/ (`code()` greps Sources only, so the "count stays at one" is a count over Sources). Caught: nonisolated(unsafe) in Sources and Tests, `var`/`public var` globals at column 0, every `static var x =`, @unchecked without INVARIANT in Sources, DispatchSemaphore/Thread.sleep/waitUntilCompleted/DispatchGroup/usleep(/indented sleep(.
- Why wrong: the gate is what CI relies on for C2/C3/C6; these forms pass it. Mitigation: Swift 6 language mode (Package.swift:23) rejects nonisolated global vars (so `public private(set) var` and an indented global inside `#if`, which lint also misses, are caught by the compiler), but not `@MainActor var` globals or blocking calls. No current violation exists (grep of Sources/ and Tests/), so the gap is latent.
- Location: Scripts/lint.sh:21-23 (code() scope), :35 (global-var regex), :66 (C6 pattern list)
- Repro: `mkdir -p T/Scripts T/Sources/X && cp Scripts/lint.sh T/Scripts/ && printf 'func f() {\nsleep(1)\n}\n' > T/Sources/X/V.swift && bash T/Scripts/lint.sh; echo rc=$?` (likewise with the other one-liners; the copies live in verification/cycle-A/F7-lint-mutation/t/)
- Evidence: "lint: all rules hold" rc=0 for each uncaught mutation; rc=1 for each caught one
- Documented: no

### A7-04 (low, test-integrity, reproduced from baseline logs) Debug and Thread-Sanitizer runs report skipped MIPLIB cases as passed
- Claim: README "Building and testing" / §5: 546 tests pass in a debug build; README §5 "Thread Sanitizer: no reports on ... branch-and-bound, CP-SAT, ... integration ..." with the CI thread-sanitizer job (.github/workflows/ci.yml:65) as the gate.
- Observed: Tests/ZTronLPIntegrationTests/CorpusTests.swift:125, :151, :171 `guard !Self.slow.contains(instance.name) || Slow.enabled else { return }`, where `Slow.enabled` is false in any DEBUG build without ZTRONLP_SLOW_TESTS=1 (CorpusTests.swift:9-17). In debug: branchAndBoundWithBothStrategies runs 6 of 10 instances, cpSatClosesEveryPureIntegerInstance 3 of 7, cpSatWithoutTheLPPropagator 2 of 6; the other 12 cases return at their first line and are reported as passed (baseline 03: "cpSatWithoutTheLPPropagator(_:) with 6 test cases passed after 7.784 seconds", no known issue; release 04 records the mod008 known issue after 60 s). The CI TSAN job and HANDBOOK's TSAN command are debug builds, so under Thread Sanitizer B&B never runs stein45, lseu, enigma or mod008, CPSAT() never runs stein45, lseu, mod008 or p0201, and CPSAT(lpPropagator: false) never runs stein45, lseu, enigma or mod008.
- Why wrong: a skipped case shows as a pass in the 546-test count and in CI; the TSAN claim on the integration target covers only the reduced corpus, i.e. not the longest parallel searches. Swift Testing's `.enabled(if:)` (used by the SATLIB tests) would show them as skipped.
- Location: Tests/ZTronLPIntegrationTests/CorpusTests.swift:125,151,171; .github/workflows/ci.yml:65
- Repro: `grep -n "Slow.enabled else { return }" Tests/ZTronLPIntegrationTests/CorpusTests.swift; grep "cpSatWithoutTheLPPropagator\|cpSatClosesEvery\|branchAndBoundWithBoth" verification/baseline/03-test-debug.log verification/baseline/05-tsan.log`
- Evidence: 03-test-debug.log "cpSatClosesEveryPureIntegerInstance(_:) with 7 test cases passed after 8.283 seconds"; 04 release "recorded a known issue ... mod008"
- Documented: partly. HANDBOOK Testing says "A debug build runs a reduced corpus ... ZTRONLP_SLOW_TESTS=1 runs the slow MIPLIB instances in a debug build as well". It does not say the skipped cases count as passes, nor that the TSAN gate therefore never covers them.

### A7-05 (low, doc-claim-false, code-reading-only) fetch-miplib.sh ignores ZTRONLP_CORPORA although the tests read it
- Claim: Sources/ZTronLPTestSupport/Fixtures.swift:39 "The directory the fetch scripts write to: `$ZTRONLP_CORPORA` when set, otherwise ...".
- Observed: Scripts/fetch-miplib.sh:15 `DEST="${1:-${ROOT}/.corpora/miplib3}"`, no reference to ZTRONLP_CORPORA (fetch-satlib.sh:31 does honour it).
- Why wrong: with ZTRONLP_CORPORA set, fetch-miplib.sh writes into .corpora/miplib3 while Corpora.root looks under $ZTRONLP_CORPORA; every MIPLIB test then records "has not been fetched" as a known issue (CorpusTests.swift:113-121) and the run is green with the corpus untested.
- Location: Scripts/fetch-miplib.sh:15
- Repro: `grep -n ZTRONLP_CORPORA Scripts/fetch-miplib.sh Scripts/fetch-satlib.sh Sources/ZTronLPTestSupport/Fixtures.swift`
- Evidence: fetch-miplib.sh: no match; fetch-satlib.sh:31 `CORPORA="${ZTRONLP_CORPORA:-$ROOT/.corpora}"`; Fixtures.swift:42 reads the variable
- Documented: no

### A7-06 (low, test-integrity, code-reading-only) FixtureTests.constructedInstancesAreFeasibleAndComplementary checks only the column half of the certificate
- Claim: test name (Tests/ZTronLPTestSupportTests/FixtureTests.swift:39) and its comment "Dual feasibility of the constructed pair"; Oracle 1 (constructed optimum) is the reference for every engine's duals.
- Observed: the loop runs over `0..<lp.n` only (FixtureTests.swift:46-50): the m row entries of `reducedCosts(forDuals:)` (row-dual signs against row activity) and the duality gap are never checked.
- Why wrong: a generator change that gave an inactive inequality row a nonzero dual, or a dual of the wrong sign, would pass this test. Today the oracle is correct: an independent KKT certificate (row and column signs, complementarity, duality gap <= 2.4e-13) holds on every suite (`.build/release/F7 gen`).
- Location: Tests/ZTronLPTestSupportTests/FixtureTests.swift:46-50
- Repro: `sed -n 39,53p Tests/ZTronLPTestSupportTests/FixtureTests.swift`
- Evidence: `for j in 0..<lp.n { ... }` is the only dual check
- Documented: no

### A7-07 (low, doc-claim-false, reproduced) Manifest and HANDBOOK misstate the dependency and import graph
- Claim: Package.swift:69-70 "the only two dependencies (§2): ... Heap / OrderedDictionary / BitSet"; Package.swift:159 gives ZTronLPCPSAT `heap, orderedCollections, bitCollections`; Package.swift:182 gives ZTronLPTestSupport ZTronLPNumerics; HANDBOOK.md:134-135 "branch and bound and CP-SAT are the two that import an LP engine".
- Observed: no file anywhere imports OrderedCollections or BitCollections; HeapModule is imported only by Sources/ZTronLPBranchAndBound/SearchTree.swift; ZTronLPCPSAT imports Atomics, Foundation, Core, Numerics, Simplex only; ZTronLPTestSupport imports Core, Dispatch, Foundation (no Numerics); ZTronLPInteriorPoint imports ZTronLPSimplex (crossover-lite), a third LP-engine consumer.
- Why wrong: three declared products are dead weight for every client of ZTronLPCPSAT, and the manifest comment and HANDBOOK sentence describe a graph that is not the real one.
- Location: Package.swift:69-70, 159, 182; HANDBOOK.md:134-135
- Repro: `grep -rln "import HeapModule\|import OrderedCollections\|import BitCollections" Sources Tests; grep -h "^import" Sources/ZTronLPCPSAT/*.swift Sources/ZTronLPTestSupport/*.swift Sources/ZTronLPInteriorPoint/*.swift | sort | uniq -c`
- Evidence: only Sources/ZTronLPBranchAndBound/SearchTree.swift matches; CPSAT imports listed above
- Documented: IPM -> Simplex is recorded as a design decision elsewhere in HANDBOOK, which contradicts the Targets sentence

### A7-08 (info, doc-claim-false, reproduced) README "no single full debug run of it was green" is stale
- Claim: README.md:715 "Every other test passed in those runs, so every test of the final tree has passed, but no single full debug run of it was green".
- Observed: the baseline full debug run (verification/baseline/03-test-debug.log, rc=0) passed all 546 tests in 13 runs.
- Why wrong: the statement understates the current state; a green full debug run exists on this tree (on an 8-core M3 under the baseline load).
- Location: README.md:715
- Repro: `grep -c "Test run with" verification/baseline/03-test-debug.log; grep "Test run with" verification/baseline/03-test-debug.log`
- Evidence: 13 "Test run with N tests ... passed" lines summing to 546; progress.txt debug suite rc=0
- Documented: n/a

### A7-09 (info, performance-claim, reproduced) Cancellation-latency figures count solves that finished before the cancel as 0 ms
- Claim: README §5 / HANDBOOK "Cancellation latency, 240 solves: p99 3.64 ms, max 4.43 ms"; L1 test p99 bounds.
- Observed: LivenessHarness.cancellationLatency records latency 0 when the solve returned before Task.cancel() (Sources/ZTronLPTestSupport/LivenessHarness.swift:45-48), and the benchmark and L1 test put those zeros into the quantiles. Probe on the benchmark's own instances/windows/seed: Simplex(.primal) 30 interrupted / 8 finished first / 2 finished after the cancel; InteriorPoint 9 / 8 / 23; BranchAndBound 35 / 5 / 0. With 40 samples per row p99 = max, so the published p99/max per row are unaffected; p50 shifts (primal 0.16 -> 0.21 ms) and the all-engines p99 over 240 is taken at a slightly lower rank of the real latencies. Worst observed 8.05 ms (IPM), within the 50 ms acceptance.
- Why wrong: a quantile of "latency" that includes non-cancellations is optimistic; effect measured as negligible for the published numbers.
- Location: Sources/ZTronLPTestSupport/LivenessHarness.swift:45-48; Sources/ZTronLPBenchmarks/main.swift:262-270
- Repro: `cd verification/probes/cycle-A && perl -e 'alarm shift; exec @ARGV' 400 .build/release/F7 latency`
- Evidence: cycle-A/F7-latency.txt
- Documented: the field doc says "True when the solve had already finished before the cancellation reached it", but the benchmark row does not say zeros are included

## Late checks (after the findings above)
HELD | README §1 item 6 "CPSAT(deterministic: true) gives the same result ... every run"; README §5 CP-SAT closes the pure-integer set | `cd verification/probes/cycle-A && F7_LIMIT=40 perl -e 'alarm shift; exec @ARGV' 1200 .build/release/F7 cpdet` (cycle-A/F7-cpdet.txt) | CPSAT(deterministic: true): p0033, stein27, enigma, lseu, mod008, p0201 optimal at the published objective, conflicts and lpSolves identical between two runs (e.g. lseu 6593 / 14712). CPSAT(lpPropagator: false, deterministic: true): p0033, stein27, enigma, lseu optimal and identical (lseu 390501 conflicts both runs); mod008 and p0201 stop at the 40 s limit (obj 372 / 9345), with conflicts differing between runs (669025 vs 676188), as expected when a time limit ends the run (overflow note)

CORRECTION | A7-04 count: 4 + 4 + 4 = 12 skipped cases in debug (not 10); per-engine TSAN coverage spelled out. Final JSON written to cycle-A/F7-integrity.json
