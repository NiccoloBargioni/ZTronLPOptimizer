# A5-05 — sceptic verdict (lens: reproduce and contract), slot V133

- verdict: **confirmed**
- documented: **false** (but see note: README risk 10 does describe the real behaviour)
- severity: **low**

## Claim under test
Two doc comments say `bound == objectiveValue` on optimal results:
- `Sources/ZTronLPCore/Solve/Analysis.swift:22` (`SolutionAnalysis.bound`): "Proven bound; equals `objectiveValue` when optimal."
- `Sources/ZTronLPCPSAT/CPSAT.swift:361-362` (`CPSATAnalysis`): "`bound` is the propagated bound of the objective row, and equals `objectiveValue` once optimality is proven."

## Reproduction (independent construction and oracle)
Probe: `verification/probes/cycle-A/Slots/V133/main.swift`. Models are built with the DSL (`LPModel` + `compile`), not
as a raw `CompiledLP` like the finder's. The oracle enumerates every point in exact integer micro-units, or is the obvious upper bound.
The gap test uses README risk 10's formula max(1e-6, 1e-4·max(1,|inc|)).

```
cd verification/probes/cycle-A && swift build --product V133 -c release
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V133 c1      # exit 0
C1 oracle: best micro-units 3500007 -> 3.5000070000000001
C1 bounds-only [det]     x0=1: status=optimal obj=3.5000010000000001 bound=3.5000070000000001 | BOUND!=OBJ diff=6e-06, bound valid, within gap(3.5e-4), obj!=trueOpt
C1 with-row    [det]     x0=7: status=optimal obj=3.500007 bound=3.500007 | bound==obj
C1 bounds-only [detnolp] x0=1: status=optimal obj=3.500001 bound=3.500007 | BOUND!=OBJ, bound valid, within gap
C1 with-row    [detnolp] x0=0: status=optimal obj=3.5      bound=3.500007 | BOUND!=OBJ diff=7e-06, bound valid, within gap
C1 bounds-only [par4]    x0=1: status=optimal obj=3.500001 bound=3.500007 | BOUND!=OBJ, bound valid, within gap
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V133 c6      # exit 0; integral cost, max x, x in [0, 1e12+1]
C6 rep0 [par4]: status=optimal obj=999933992592 bound=1000000000001 trueOpt=1000000000001 | BOUND!=OBJ diff=66007409, bound valid, within gap(99993399.26)
C6 rep1/rep2 [par4]: optimal obj=bound=1000000000001;  det/detnolp: feasible(timeLimit) (documented one-step climb)
```
I also ran the finder's own binary, unchanged: `F5_ONLY=D13 F5_LIMIT=3 .build/release/F5 domain`. It gives det and detnolp `optimal obj=3.500001 bound=3.500007 x=[1]`, and par x=7 exact.
Controls that closed exactly (bound==obj, obj==oracle): 6 knapsacks n=18 with values ~1e6 (own brute force over 2^18 subsets) on det, detnolp, par4 and BranchAndBound(det); C2 (max x0, x0+x1<=1e9); C4; C5.
So the mismatch occurs only when the gap closes before exhaustion. It is reproducible and deterministic for C1.

## Contract reading
- The code does this on purpose. In `CPSAT.swift:298-303`, when `best.gapReached` holds without exhaustion, the code reports `reportedObjective(best.lowerBound)`, and its own comment says "report the proven bound when it is the tighter statement". `BranchAndBound.swift:352-353` does the same for `.gapReached`: `boundValue` stays `provenBound`.
  So `.optimal` does not imply `bound == objectiveValue`, and the protocol doc comment (Analysis.swift:22) is false as written, for CP-SAT (shown by running it) and for B&B (shown by reading the code).
- Charitable reading of CPSATAnalysis: the CPSAT strategy doc (CPSAT.swift:85-88) says the gap stop is an exact proof only when 1e-4·|objective| < the objective step. Under that reading, "once optimality is proven" could exclude these within-gap stops. In every bound!=obj case I saw, the proof was not exact (step 1e-6 vs 3.5e-4; step 1 vs 1e8).
  But that reading does not save `SolutionAnalysis.bound`, whose "when optimal" naturally means `status == .optimal`, and a caller sees `.optimal`.
- The numbers are not wrong. Each `bound` was checked against the oracle and is a valid proven bound (≥ the true optimum for max). Each `objectiveValue` is attained by a feasible `primal` and lies within the documented MIP gap.
  So this is not a wrong answer. Someone who follows the doc comment and treats `bound` as the attained optimum is off by at most the gap.
- Documentation status: README risk 10 (outside view) does say it. ".optimal means incumbent − bound ≤ max(...) ... so an incumbent of 1,000 with a bound of 999.95 is optimal" describes exactly bound ≠ objective on `.optimal`. The finder's note says README does not say they differ, and I think that undersells it.
  However, nothing (README §4, HANDBOOK known gaps or not-verified) acknowledges that the two doc comments state the opposite. The package contradicts itself and the false statements are not flagged, so documented=false.
- Severity low: a doc-comment/README inconsistency with no wrong value, status or point.
