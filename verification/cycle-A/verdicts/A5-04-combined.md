# A5-04, sceptic verdict (lens: reproduce and contract)

- verdict: **confirmed**
- documented: **false**
- severity: **low**
- probe: verification/probes/cycle-A/Slots/V130/main.swift (own slot, own code; the finder's F5 probe was read, not run)

## Claim under test
CPSATAnalysis.winningWorker doc (Sources/ZTronLPCPSAT/CPSAT.swift:373-375): "The worker that ended the search — the one that completed the proof (or, for a feasibility problem, found the solution); otherwise the one that found the reported incumbent". The finding says a parallel feasibility solve can name a worker whose solution was not the one returned.

## Code reading (root cause)
- CPSearch.swift:198-199 (and :151-152 for LP solutions): `_ = await store.offer(...)` discards the "became the incumbent" result, then `guard model.hasObjective else { return .satisfied }`. Every worker that completes an assignment before it sees the stop flag reports `.satisfied`, accepted or not.
- Portfolio.swift:69: `if let best = bestObjective, objective >= best { return false }`. For a feasibility problem every objective is 0 (CPModel.swift:457-458), so only the first offer is kept (bestWorker) and later ones are rejected.
- CPSAT.swift:253 sorts the reports by index; :259 `prover = reports.first { .exhausted || .satisfied }`; :331 `winningWorker: prover?.index ?? best.worker`. So the field is the lowest-index `.satisfied` worker, not `best.worker`, the worker whose values are returned.
- The stop flag is raised only after a worker's search returns (CPSearch.swift:67-69), which is after `offer` has drained its event to the sink. Workers that are within one gate stride of a solution can finish during that window.

## Independent oracle (not the .newIncumbent source the finder used)
uf50: `CPSAT(deterministic: true)` is exactly worker 0 of a parallel run: same index 0, seed 0, lower-bound-first phase, natural order, and no relaxation for a clause model. The only differences (clause sharing and memory allowance) act at restarts. Clauses are exchanged only in restart(). So when the deterministic run finds its point S0 with 0 restarts, worker 0 of any parallel run either is stopped or reports `.satisfied` with exactly S0. On a satisfiable CNF, `winningWorker == 0` with `.optimal` means worker 0 reported `.satisfied`. If the returned point differs from S0, the named worker's solution is provably not the one returned.
Oracle validated empirically: in every parallel run where the event source was cpsat[0], the returned point equalled S0 (74/74, 95/95, 93/93), and CPSAT(workers: 1) returned S0 in 200/200.
Synthetic cross-check (n binaries, no rows, zero costs): workers with index % 4 != 1 can only return all zeros. The random-phase workers' points were replicated from WorkerRandom, and the replica matched the returned point whenever cpsat[1] won (oracleFail=0 over 400 runs). On this model worker 0 almost never overlaps with another winner, so no mismatch shows (0/400). This means the race needs workers that finish close together, as on easy SAT instances.

## Commands and key output
```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A && swift build --product V130 -c release
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V130 uf50 100 2 8
  uf50-0103.cnf: winningWorker=0 but returned point differs from worker 0's point S0 in 13 of 50 variables (det run: 21 conflicts, 0 restarts); .newIncumbent sources=["cpsat[2]"]; returned point satisfies CNF: true, S0 satisfies CNF: true
  uf50-0116.cnf: winningWorker=0 but returned point differs ... in 20 of 50 variables ...; sources=["cpsat[1]"]
  uf50 workers=8: files=100 runs=200 notOptimal=0 invalidPoint=0 multipleIncumbentEvents=0 eventMismatch=49
    files whose deterministic run needs no restart: 100
    oracle validation: runs with source cpsat[0] on such files=74, returned point == S0 in 74
    winningWorker==0 on such files: 114; returned point == S0 (consistent) 80; != S0 (proven mismatch) 34
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V130 uf50 300 1 8
  runs=300 eventMismatch=60; source cpsat[0]: 95, == S0 in 95; winningWorker==0: 132; proven mismatch 31
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V130 uf50 100 2 4     (the package's own test config, CPSAT(workers: 4))
  runs=200 eventMismatch=42; source cpsat[0]: 93, == S0 in 93; winningWorker==0: 130; proven mismatch 31
perl -e 'alarm shift; exec @ARGV' 600 .build/release/V130 uf50 100 2 1     (control)
  runs=200 eventMismatch=0; proven mismatch 0
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V130 synthetic 200 64 8   (and 100 runs each at n=2000, 20000)
  oracleFail=0 contentMismatch=0; winner/source histograms almost all 0; source 1 runs matched the replicated worker-1 point
```
Every one of the 900 parallel uf50 runs was `.optimal` with exactly one `.newIncumbent` event, and every returned point satisfied every clause under my own clause check. Only the label is wrong.

## Reasoning
- Reproduced: the event-based mismatch rate is 20-25% (finder: 23/100). My stricter, content-based oracle proves 10-17% of 8-worker runs and 15.5% of 4-worker runs. In these runs winningWorker=0, but worker 0's own assignment differs from the returned one in 1 to 20 of 50 variables.
- The finder's oracle slightly overstates the mismatch rate. In 6 of 40 event mismatches with winner 0, another worker had found the very same assignment S0. The defect stands without those cases.
- The finding holds against the contract. The doc ties the field to the reported result: "found the solution", with a fallback to "the one that found the reported incumbent". In the mismatched runs, worker 0 found a different solution, after another worker's solution had already been accepted. The field is biased toward low indices: worker 0 is named in 114/200 runs, but its point was returned in only 74.
- It is not by design. No decision in HANDBOOK, README §3 or §4, or the code comments says the lowest index is reported. README risk 8 covers run-to-run variation of the returned solution, not a field that disagrees with that solution. The existing tests only check `winningWorker != nil` or a valid range (SATTests.swift:60, OptimizationTests.swift:305), so none can catch this.
- Severity is low. The field is diagnostic, and nothing in the package reads it. Status, objective, primal and bound are unaffected. It is a doc/field inconsistency, not a wrong answer.
- Fix suggestion: take the proof from `.exhausted` reports only, and otherwise use `best.worker`. Or have a worker report `.satisfied` only when its offer was accepted.
