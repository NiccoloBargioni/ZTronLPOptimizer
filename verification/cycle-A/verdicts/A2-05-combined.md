# A2-05 — combined sceptic (lens: reproduce and contract), cycle A

- Finding: README §5 ill-conditioned table, column "Answers with a warning", under-counts the
  warned answers at orders 4 and 5 (README.md:615-616, text README.md:627-628).
- Verdict: **confirmed**
- documented: **false**
- severity: **low**
- Probe: slot V043, /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/V043/main.swift
  (own code; finder's code read only).

## Reasoning

Claim: order 4 "0 of 12", order 5 "3 of 12"; "The warnings at orders 5 and 6 are the interior
point's, whose normal equations stall there before the simplex finishes the solve."

Measured on HEAD d9afebe (Sources unmodified), the same 12 answers per order (4 Hilbert forms ×
`Simplex(.dual)`, `Simplex(.primal)`, `InteriorPoint()`), three independent counts:

1. `analysis.warnings` non-empty (what the column header names);
2. a `SolverEvent.warning` received through `SolveContext.progress` (a separate channel);
3. a structural prediction from the `CompiledLP` alone, using the README §4 rule ("a column
   with more than 30 % nonzeros makes the normal equations dense (a warning says so)"):
   Hilbert columns are 100 % dense, so every `InteriorPoint()` answer should warn.

All three give **4 of 12 at order 4 and 4 of 12 at order 5** (README: 0 and 3). The four are
the `InteriorPoint()` answers, each carrying
"4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"
(IPMWorker.swift:128 counts, :638-640 emits; InteriorPoint.swift:139 carries it into the
answer). At order 5 three IPM answers also carry the stall warning; the `equalityFree` one
carries only the dense-column warning. The count of answers that keep a warning after the
dense-column one is removed reproduces the README column exactly at every order 3-12
(0, 0, 3, 4, 12, …): the table counted only conditioning-related warnings (stall,
ill-conditioned basis), not "answers with a warning". Same result with `metal: .off` and
`.automatic`; deterministic.

Refutation attempts that fail:
- Wrong oracle: no. Three independent counts agree; the header says "answers with a warning".
- Misuse: no. Default `InteriorPoint()`, default and Metal-off contexts, the generator the
  README describes; all 120 solves `.optimal`, other columns reproduce (order 4 dist
  5.3e-13/6.1e-13/5.3e-13, obj err 3.5e-16; order 5 5.8e-12/8.2e-12/5.8e-12, 1.4e-16).
- Stale table: no. The table first appears in 9fd4f24; `git diff --stat 9fd4f24 d9afebe --
  Sources/` is empty, and at 9fd4f24 the dense-column warning and its propagation already
  exist (IPMWorker.swift:128/639, InteriorPoint.swift:139). The README also says "Measured with
  the engines as they are now".
- By design: the warning is by design (README §4), but that makes the table's count wrong, not
  right; nothing says the column excludes it, and the text attributes the warnings to stalls.

Not documented: README §4 documents that the dense-column warning exists, but nowhere says the
table excludes it; the accompanying text states the opposite reading. Severity low: a number
mismatch in a measured table; the uncounted warning is a benign notice; no answer is wrong.
Minor precision on the finder's wording: the table counts stall *and* ill-conditioned-basis
warnings (orders 7+), i.e. everything but the dense-column one.

Aside (info, not part of this verdict): README §4's rule would also predict the warning at
order 3 (3 columns of 3 rows, 100 %), but IPMWorker.swift:128 applies it only when
`keptRows > 3`, so order 3 has none (and the table's "0 of 12" there holds).

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V043 -c release            # Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V043 table 12 off   # exit 0
order | observed | events | oracle(readme-rule) | nonDense | readme | maxDist dual/primal/ipm | objErr | non-optimal
3 | 0 of 12 | 0 of 12 | 4 of 12 | 0 of 12 | 0 of 12 | 6.7e-15/9.0e-15/9.0e-15 | 1.2e-16 | []
4 | 4 of 12 | 4 of 12 | 4 of 12 | 0 of 12 | 0 of 12 | 5.3e-13/6.1e-13/5.3e-13 | 3.5e-16 | []
5 | 4 of 12 | 4 of 12 | 4 of 12 | 3 of 12 | 3 of 12 | 5.8e-12/8.2e-12/5.8e-12 | 1.4e-16 | []
6 | 4 of 12 | 4 of 12 | 4 of 12 | 4 of 12 | 4 of 12 | 5.8e-10/5.8e-10/4.2e-10 | 2.3e-16 | []
7..12 | 12 of 12 in every count, README 12 of 12; dist at 9-12 between 1.0 and 3.1, obj err <= 7.9e-12
  order 4: <form>/ipm warnings ["DENSE"] for all 4 forms; dual/primal []
  order 5: equality/ipm, covering/ipm, packing/ipm ["DENSE","STALL"]; equalityFree/ipm ["DENSE"]
perl -e 'alarm shift; exec @ARGV' 200 .build/release/V043 table 6 auto   # same 0/4/4/4 vs README 0/0/3/4
perl -e 'alarm shift; exec @ARGV' 120 .build/release/V043 detail 4 off | grep text: | sort | uniq -c
   4  text: ["4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"]
   8  text: []
V043 detail 6: every ipm ["DENSE","STALL"]; V043 detail 7: dual/primal ["ILLCOND",...], ipm ["DENSE","STALL","ILLCOND",...]
git diff --stat 9fd4f24 d9afebe -- Sources/      # empty
git show 9fd4f24:Sources/ZTronLPInteriorPoint/IPMWorker.swift | grep -n 'keptRows > 3\|normal equations will be dense'   # lines 128, 639
git show 9fd4f24:Sources/ZTronLPInteriorPoint/InteriorPoint.swift | grep -n 'contentsOf: outcome.warnings'                 # line 139
```
