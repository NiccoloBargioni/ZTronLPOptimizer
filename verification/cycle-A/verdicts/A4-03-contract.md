# A4-03, contract lens: verdict

- Finding: objectiveStep counts an integer column's cost with |c| <= 1e-9 as an integral 0.
  Pruning by a whole objective step then gives a false `.optimal` (reported 1, true optimum 0.75).
- Sceptic: cycle A, slot V098, CONTRACT lens. Repo at main @ d9afebe (read-only).
- **Verdict: confirmed**
- **Documented: false**
- **Severity: critical** (the package reports a wrong answer under the success status `.optimal`, with an invalid bound and gap 0)

## What the package promises

- `SolveStatus.optimal` doc comment (Sources/ZTronLPCore/Solve/Status.swift:5): "An optimal
  solution was found and proven (within the gap, for MILP)."
- README §2.5, `BranchAndBound`: "`.optimal` means within `gap`." README §3 risk 10:
  `.optimal` means incumbent − bound ≤ max(1e-6, 1e-4·max(1, |incumbent|)). Its mitigation is
  "Pass a tighter `Gap` to `BranchAndBound` when the exact optimum matters". Risk 3 says to read
  `bound` and `BranchAndBoundAnalysis.gap` to learn how far the incumbent may be from the optimum.
- HANDBOOK decision 8: MILP "optimal" means optimal within the gap.
- The doc comment of `objectiveStep` (BranchAndBound.swift:378-379) says it returns "the smallest
  amount by which the objective can improve when every column with a nonzero cost is integer
  and the costs share a common divisor; 0 otherwise". For costs {1, 1e-9} the smallest
  improvement is 1e-9. The scale loop stops at 1e6, so the documented answer is 0. The code
  returns 1.
- Documented tolerances (README §2.3 `Tolerances`, §2.1 `CompileOptions`): dropZero 1e-14 and
  dropTolerance 1e-14. A cost of 1e-9 is therefore a real coefficient for the package's own
  compile step: it is kept, with no diagnostic. No document treats costs of 1e-9 as zero or
  describes the objective-step pruning at all. README §4 has no limit on the range of integer
  columns for branch and bound. The range and integrality restrictions there belong to CP-SAT.
- The only general caveats are risk 1 (floating-point algorithms on untested models) and defect
  9 (conditioning above 1e11). Neither describes this: the matrix-well-scaled variant below fails
  too, and the LP engines solve every relaxation exactly.

## Causal story (code reading, checked)

- BranchAndBound.swift:395 has `|c·s − round(c·s)| <= 1e-9·max(1, c·s)`. At s = 1 the cost
  1e-9 passes with equality and rounds to 0. gcd(1, 0) = 1, so `objectiveStep` = 1. The input is
  the bounds-only presolved LP, whose costs are unchanged (lines 197-209 and 293).
- SearchTree.swift:312-319 and TreeSearch.swift:83-89 set the cutoff to
  incumbent − step + 1e-9·max(1, |incumbent|), with no gap term. After rounding gives the
  incumbent 1 at the root, the cutoff is 1e-9. The root bound of 0.5 is pruned, so the node
  holding 0.75 is never solved. The result is nodes 1, bound 1, gap 0.
- The unit test `objectiveStepDetection` (Tests/ZTronLPBranchAndBoundTests/SearchTreeTests.swift:113-123)
  covers only costs {2,4,6}, {1.5,3}, {0.25,0.5}, a continuous cost and all zeros. It has no
  tiny cost.

## Commands and key output

Probe: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V098/main.swift

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V098 -c release            # Build complete
perl -e 'alarm shift; exec @ARGV' 400 .build/release/V098 <mode>   # every run exit 0, timeLimit 30 s
```

E1 `repro`: the finder's model, min x1 + 1e-9·x2, x1 + (1e-9/1.5)·x2 >= 0.5, x1 ∈ {0,1},
x2 ∈ Z ∩ [0,1e9]
```
P-default: optimal obj 1 bound 1 gap 0 x ["1","0"] nodes 1 src ["rounding"]
D-default / P-det / I-default: the same (optimal 1, bound 1, 1 node, rounding)
D-mostfrac-noheur: optimal obj 0.75 bound 0.75 x ["0","750000000"] nodes 3
P-noheur:          optimal obj 0.75 bound 0.75 x ["0","750000000"] nodes 3
point (0, 7.5e8): maxViolation (bounds 0, rows 0) objective 0.75
LP x1=0: optimal obj 0.75 x ["0","750000000"]   (integral, so the x1=0 branch optimum is 0.75)
LP x1=1: optimal obj 1 ;  LP root: optimal obj 0.5 x ["0.5","0"]
```
Independent oracle: the MILP optimum is min(0.75, 1) = 0.75. The reported bound of 1 exceeds
the true optimum, so it is not a valid bound. The error, 0.25, is 2500 times the gap slack of 1e-4.

E2 `threshold`: the same model with cost eps and row coefficient eps/1.5, x2 ≤ 1e10. The
optimum is 0.75 for every eps.
```
eps 5e-10        P/D-default: optimal 1    (wrong)
eps 1e-09        P/D-default: optimal 1    (wrong)
eps 1.0000001e-9 P/D-default: optimal 0.75 (correct)
eps 1.1e-9, 2e-9, 1e-8      : optimal 0.75 (correct)
```
The result flips exactly at the 1e-9 tolerance of objectiveStep. This isolates that test as
the cause.

E3 `chain`: the same trade-off with every matrix coefficient in [1, 1500]. A chain of zero-cost
continuous columns stands in for the 6.7e-10 coefficient. This rules out conditioning.
```
eps 1e-9:   point maxViolation 0 objective 0.75; P-default optimal 1 bound 1 nodes 1; D-default optimal 1;
            D-mostfrac-noheur optimal 0.75
eps 1.1e-9: P-default / D-default / noheur all optimal 0.75
```

E4 `gap`: the documented mitigation (risk 10) on the finder's model
```
P Gap(1e-9,1e-9): optimal obj 1 bound 1 gap 0
P Gap(0,0):       optimal obj 1 bound 1 gap 0
D Gap(0,0):       optimal obj 1 bound 1 gap 0
```
The step cutoff ignores `gap`, so a tighter Gap cannot help.

E5 `dsl`: LPModel with default CompileOptions, through the facades
```
compiled c [1.0, 1e-09] diagnostics 0
Automatic: optimal obj 1 open 1.0 units 0.0 bound 1 engine BranchAndBound<Simplex(.primal)>
BranchAndBound(): optimal obj 1 ; Conditioned(BranchAndBound()): optimal obj 1 warnings []
```

## Reasoning (why it is not refuted)

- The oracle is sound: an integral, exactly feasible point with objective 0.75, plus LP bounds
  on both x1 branches.
- It is not misuse. The model goes through the public CompiledLP initializer and through the
  DSL with default options. Its bounds are finite and small, and no documented restriction
  applies.
- It is not by design. The code contradicts the doc comment of `objectiveStep`, and no decision
  in HANDBOOK or README describes it.
- It is not within any tolerance. The 0.25 error exceeds every documented tolerance by orders of
  magnitude.
- It is not documented: there is no defect, limit, risk or not-verified entry for it.
- It is reproducible and deterministic: 1 node across all default configurations and both facades.
- The trigger is narrow. It needs a cost of magnitude ≤ 1e-9 at the scale where the other costs
  become integral, on an integer column whose range is large enough for that cost to exceed the
  gap (≥ ~1e5). Tie-breaking terms are an example. A narrow trigger does not lower the severity
  class: the package returns `.optimal` with a wrong objective, a bound above the true optimum
  and gap 0, and nothing warns.
