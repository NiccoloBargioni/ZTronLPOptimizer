# A4-08 — sceptic verdict (cycle A, lens: reproduce and contract)

- **Finding:** Test `memoryBudgetDegradesThenStops` (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:241, assertion at :246) cannot fail if the memory budget is ignored. No test checks the "degrades" step.
- **Verdict:** confirmed
- **Documented:** false
- **Severity:** medium. The finder rated it low. On the cycle's scale, "a test that cannot catch the bug it is named for" is medium. The package's own behaviour is correct, so it goes no higher.
- **Probe:** /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V112/main.swift
- **Raw output:** /Users/admin/Documents/ZTronLPOptimizer/verification/cycle-A/verdicts/A4-08-combined.V112-output.txt

## Reasoning

1. **The test checks only the status, with a predicate that is always true here.** Line 246 is
   `#expect(analysis.status.stopReason == .memoryBudget || analysis.status == .optimal)`. The first half holds for any memory-budget stop. The second half holds for any solve that completes. The test reads nothing else from the first solve: no node count, iterations, open nodes or incumbent. Its second solve (default config, 16 MiB, expects `.optimal`) does not depend on the budget logic either.
2. **Counterfactual, run independently.** The finder's oracle used another configuration (dual, deterministic, 200 000 B). I ran the test's exact configuration, `BranchAndBound(nodeSelection: .bestBound, heuristics: .none)`, with no binding budget: `memoryBudgetBytes = nil` (25% of RAM) and `Int.max`. A solver that ignores the budget would return the same status. Both runs give `optimal obj 593`, and the line-246 predicate is **true**. The optimum is independently confirmed by `CPSAT()`, a different algorithm, at `optimal obj 593`. So the test passes for a solver with no memory budget.
3. **The predicate holds for every budget I tried.** I scanned the test configuration over 20 budgets, from 1 B through 1 MiB, plus nil:
   - Every finite budget stopped with `noSolution(memoryBudget)`. Even 1 MiB stopped after 2 274 nodes.
   - Only nil completed with `.optimal`.
   - The predicate was false for 0 of the 20.

   With the real implementation, the `.optimal` half can never be reached at 2 000 B. A budget more than 500 times larger still stops. That half admits only an implementation that ignores the budget, or under-counts it by more than 500 times.
4. **The "degrades" step is real, observable and untested.**
   - **What the code does.** In branch and bound, the budget is read only by `SearchTree`: it is passed in at BranchAndBound.swift:208 and checked at SearchTree.swift:436–461. Over budget, the tree first strips parent states from the lowest-priority open nodes (lines 437–458). It closes with `.memoryBudget` only if it is still over (line 461).
   - **What execution shows.** With `deterministic: true` and `threads: 1` (3 runs each, all reproducible):
     - 64 000 B: `optimal 593`, 2 353 nodes, 18 177 LP iterations. Unbudgeted: `optimal 593`, 2 353 nodes, 18 155 LP iterations. Same tree, 22 extra pivots: nodes that lost their parent state warm-started from the root.
     - 32 000 B: `optimal 593`, 2 394 nodes, 19 060 LP iterations.
     - 24 000 B: `feasible(memoryBudget)`, and the 593 incumbent is kept.
   - **What a regression would look like.** The search path can change only when the pool goes over budget, so an implementation that skipped the degrade step would stop with `.memoryBudget` at 32–64 KB. The test would not notice: any `.memoryBudget` stop satisfies line 246.
   - **No other test covers it.** I checked every memory-budget test in Tests/:
     - In the internal tests (SearchTreeTests, L4SearchTreeTests, EngineStubTests), every SearchTree is built with `memoryBudget: .max`, and no test looks at `parentState`.
     - All five end-to-end tests accept any `.memoryBudget` stop (BranchAndBoundTests :246, L7 at 16 MiB, L7 at 4 096 B, L7 at 0 B, and `everyExitPathOfEveryEngine` at 512 B).

     Removing the degrade step would therefore pass the whole suite. A discriminating test was feasible: for example, deterministic mode, threads 1, a 64 000 B budget, expect `.optimal 593`.
5. **What lowers the impact.** As the finder says, the "stops" half is caught elsewhere, strictly:
   - L3ToL10Tests.swift:207 (L7 `aBudgetTooSmallForTheTreeStopsWithTheIncumbent`, 4 096 B) requires `stopReason == .memoryBudget`.
   - L3ToL10Tests.swift:336 (`everyExitPathOfEveryEngine`, 512 B) does the same.
   - Both passed in the baseline.

   So the suite would still catch an ignored budget. Only the degrade half is unguarded.
6. **Contract.** No promise about the package's behaviour is broken:
   - README §2 (complexity notes and the BranchAndBound row) says the open nodes stay under the memory budget and the search ends at it. My runs agree.
   - The degrade rule appears only in source and test comments: the L7 suite comment says "degrades (drops bases)". The implementation does it.

   The defect is in the tests. A test named for "degrades then stops" can catch neither failure. HANDBOOK §Testing says "The liveness rules of §12.2 each have a test", which overstates coverage for L7's degrade clause. Neither README §3–§4, its "Not verified" list, nor HANDBOOK's Known gaps or Not verified sections mentions this weakness, so documented = false.
7. **Minor accuracy notes on the finding.**
   - Node counts at 2 000 B vary from run to run in non-deterministic mode: I saw 19–22 nodes, the finder saw 18. Same outcome.
   - The test's doc comment also says "keeping whatever incumbent exists". With `heuristics: .none` and an early stop, no incumbent ever exists, so that clause is not exercised either.
   - The finder's line references are accurate.

## Commands and key output

```
sed -n 238,250p Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift
  241: @Test func memoryBudgetDegradesThenStops() async throws {
  246: #expect(analysis.status.stopReason == .memoryBudget || analysis.status == .optimal)

grep -rn "memoryBudget:" Tests/          -> only `.max` (L4SearchTreeTests:10, EngineStubTests:121, SearchTreeTests helper default)
grep -rn "\.parentState" Tests/          -> no matches
grep memoryBudget in Sources/ZTronLPBranchAndBound, ZTronLPSimplex, ZTronLPCore
  -> only BranchAndBound.swift:208 (resolve -> SearchTree) and SearchTree.swift:436/443/461
baseline/03-test-debug.log, 05-tsan.log: memoryBudgetDegradesThenStops passed;
  aBudgetTooSmallForTheTreeStopsWithTheIncumbent passed

cd verification/probes/cycle-A && swift build --product V112 -c release
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V112 test      (exit 0)
  T1 run 1..3 budget 2000: noSolution(stoppedBy: memoryBudget) nodes 21/20/19  predicate(line246)=true
  T2 default config budget 16777216: optimal obj 593                           second expect = true
  T1-unbudgeted budget nil(=25% RAM): optimal obj 593 nodes 3221               predicate(line246)=true
  T1-unbudgeted budget Int.max:       optimal obj 593 nodes 3369               predicate(line246)=true
.build/release/V112 oracle    (exit 0)
  CPSAT(): optimal obj 593
.build/release/V112 scan      (exit 0)
  budgets 1 .. 1048576: noSolution(stoppedBy: memoryBudget)  (1 MiB: nodes 2274 open 2273)
  budget nil: optimal obj 593 nodes 3425
  predicate false for 0 of 20 budgets
.build/release/V112 degrade   and   .build/release/V112 repeat   (exit 0; deterministic, threads 1)
  ref nil:      optimal 593 nodes 2353 lpIter 18155 (x3 identical; also 128000/256000/1 MiB identical)
  64000 B:      optimal 593 nodes 2353 lpIter 18177 (x3)   <- degraded (stripped parent states), still optimal
  32000 B:      optimal 593 nodes 2394 lpIter 19060 (x3)   <- degraded, still optimal
  24000 B:      feasible(stoppedBy: memoryBudget) obj 593 nodes 1028 open 31 (x3)
  <= 8000 B:    noSolution(stoppedBy: memoryBudget)
```
