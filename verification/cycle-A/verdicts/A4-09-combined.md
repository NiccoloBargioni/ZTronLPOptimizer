# A4-09 — sceptic verdict (cycle A, lens: reproduce and contract)

Finding: `.boundImproved` events of a parallel branch-and-bound search can arrive out of order
(a later event reports a weaker bound).

- **verdict:** confirmed
- **documented:** false
- **severity:** low

## Reasoning

### Mechanism (code reading)
- `SearchTree.progressEvents(flip:)` (Sources/ZTronLPBranchAndBound/SearchTree.swift:531-547)
  emits `.boundImproved` only when `provenBound > lastBound + 1e-9·max(1,|bound|)` and then
  sets `lastBound`, so the tree actor *produces* a strictly increasing sequence. `lastBound`
  is written nowhere else (lines 168, 534, 535).
- Each worker then delivers that batch in a separate hop (TreeSearch.swift:119-120:
  `for event in await tree.progressEvents(flip: flip) { await sink.emit(event) }`). Nothing
  orders the hop to the `EventSink` actor across workers, so worker A can take bound b1, worker
  B take b2 > b1, and B reach the sink first. BranchAndBound.swift:319 makes the same call
  before the workers start, so it cannot race.
- By contrast the CP-SAT store queues events and drains them from one task "so they reach the
  sink in the order the store accepted them even though `offer` suspends"
  (Sources/ZTronLPCPSAT/Portfolio.swift:53-56, 115-123). The package orders this same event
  type on purpose elsewhere.

### Reproduction with an independent oracle (slot V115)
This oracle differs from the finder's adjacent-drop count:
1. contract view: count delivered bound events that fail to improve on the running maximum of
   all earlier delivered bounds, strictly and with the package's own 1e-9 threshold, plus the
   number of inverted pairs;
2. cause view: the sorted delivered values must be a sequence the tree could have produced
   (each one above the previous by more than the threshold); then a drop in delivery order can
   only be a reordering, not a bound that went down inside the tree;
3. witness: the stale event's `gap` field must be larger than that of the running-maximum event
   (a snapshot taken earlier);
4. validity: every bound must be at or below the published MIPLIB optimum;
5. controls: one worker (threads: 1), and `deterministic: true` at 8 threads (also one worker),
   should show zero stale events; CP-SAT with 8 workers serves as a contrast.

Results (release build, shared machine):

| configuration | runs | runs with a stale bound event | stale events / bound events | max displacement | worst drop |
|---|---|---|---|---|---|
| B&B threads 8 (P and D engines; lseu, mod008, p0201, misc03) | 80 | 12 | 18 / 87,416 | 5 | 0.103 (lseu) |
| B&B threads 4 (lseu, mod008) | 40 | 22 | 38 / 142,834 | 2 | 0.0973 |
| B&B threads 2 (lseu, mod008) | 40 | 12 | 19 / 162,463 | 1 | 0.0292 |
| controls: threads 1 (P, D) and deterministic at threads 8 | 60 | 0 | 0 / 103,925 | 0 | 0 |
| CP-SAT 8 workers (contrast) | 15 | 0 | 0 / 94 | 0 | 0 |

- In every parallel run the delivered multiset passes the permutation check (0 failures), and
  every stale event (75 of 75) has a larger gap than the event it follows. Both point to a
  reordering of a correctly produced sequence.
- Relative drops run from 1.5e-8 (mod008: 303.652007644 after 303.652012144) to 1e-4 (lseu:
  1064.818 after 1064.921), all well above the 1e-9 emission threshold. A stale event can be
  delivered up to 5 positions late.
- With one worker the stale count is 0 over about 104k events. At the parallel rate (about
  2e-4 per event) about 20 would be expected, so the chance of seeing none is about e^-20. The
  cause is therefore the multi-worker delivery.
- Nothing else is affected: 0 bounds above the optimum, 160 of 160 parallel runs `.optimal`
  at the reference optimum with the final bound equal to it, `.finished` last and unique in
  every run, 0 non-improving `.newIncumbent` events, 0 backward `.nodes` events.

### Contract
- No published text promises that bound events are monotone. `EventSink`'s doc comment
  (Strategy.swift:222-224), README §2.3 ("serializes the events of one solve and enforces
  their order") and rule L10 (L3ToL10Tests.swift:274: "event delivery is monotone —
  `.finished` is the last event, delivered exactly once") define "order" only as `.finished`
  last and unique, and that holds. Serialization (rule C2) also holds.
- The implied contract is broken, though. The case is named `.boundImproved`, the internal doc
  calls it "an improved bound", and CP-SAT deliberately delivers in acceptance order. A
  delivered event whose bound is weaker than one already delivered is not an improvement
  from the consumer's side: a plot moves backwards and a delta computed by the consumer turns
  negative.
- Not by design and not documented. README §4 "Parallel search is not reproducible" and risk
  8 cover variation between runs. Risk 15 ("an interleaving the tests never produced") is
  generic and says nothing about events. The HANDBOOK is silent.

### Severity: low
This is a small inconsistency in the progress stream. Every stale value is still a valid lower
bound, only weaker, and the next event supersedes it. Results, statuses, the final bound and
`.finished` are unaffected. It is not "misleading API behaviour" at the medium level: a
consumer that acts on the latest event sees a slightly conservative bound and gap for one
event.

### Side observation (not verified)
`TreeSearch.offer` (TreeSearch.swift:317-321) uses the same two-hop pattern for
`.newIncumbent`. It never misordered in these runs because incumbents are rare. A fix like
CP-SAT's drain queue would cover both.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V115 -c release                       # Build complete
perl -e 'alarm shift; exec @ARGV' 580 .build/release/V115 repro 10 lseu,mod008,p0201,misc03
  SUMMARY repro D-threads8: runs 40 runsWithStaleBound 10 staleEvents 14 of 44979 boundEvents; permutationOfValidSequenceFailed 0; boundsAboveOptimum 0; ... wrongObjective 0
  SUMMARY repro P-threads8: runs 40 runsWithStaleBound 2 staleEvents 4 of 42437 boundEvents; permutationOfValidSequenceFailed 0; boundsAboveOptimum 0; ... wrongObjective 0
  lseu P-threads8 run 5: ... bound events 3051 stale 2 inversions 6 maxDisp 5 worstDrop 0.103 permOK yes invalid 0 staleGapUp 2
    stale event #1035: bound 1064.81818182 gap 0.0492695 after #1034 bound 1064.92142524 gap 0.0491773 (drop 0.103)
  mod008 D-threads8 run 1: stale event #1072: bound 303.652007644 after #1071 bound 303.652012144 (drop 4.5e-06)
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V115 repro 10 lseu,mod008 4
  SUMMARY repro D-threads4: runs 20 runsWithStaleBound 13 staleEvents 23 of 75140 ...; permutationOfValidSequenceFailed 0; boundsAboveOptimum 0
  SUMMARY repro P-threads4: runs 20 runsWithStaleBound 9 staleEvents 15 of 67694 ...; permutationOfValidSequenceFailed 0; boundsAboveOptimum 0
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V115 repro 10 lseu,mod008 2
  SUMMARY repro D-threads2: runs 20 runsWithStaleBound 7 staleEvents 13 of 85395 ...
  SUMMARY repro P-threads2: runs 20 runsWithStaleBound 5 staleEvents 6 of 77068 ...
perl -e 'alarm shift; exec @ARGV' 580 .build/release/V115 control 5 lseu,mod008,p0201,misc03
  SUMMARY control D-threads1: runs 20 runsWithStaleBound 0 staleEvents 0 of 56860 boundEvents ...
  SUMMARY control P-det-threads8: runs 20 runsWithStaleBound 0 staleEvents 0 of 265 boundEvents ...
  SUMMARY control P-threads1: runs 20 runsWithStaleBound 0 staleEvents 0 of 46800 boundEvents ...
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V115 cpsat 5 mod008,p0201,lseu
  SUMMARY cpsat CPSAT-workers8: runs 15 runsWithStaleBound 0 staleEvents 0 of 94 boundEvents ...
```
All exits were 0, with no alarm. The full output is in
/Users/admin/Documents/ZTronLPOptimizer/verification/cycle-A/verdicts/A4-09-combined-probe-output.txt.
