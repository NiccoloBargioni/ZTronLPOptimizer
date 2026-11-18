# A4-01, sceptic lens REPRODUCE (cycle A, slot V091)

- **Verdict:** confirmed
- **Documented:** no
- **Severity:** critical (`.optimal` with an infeasible point; the reported objective is not c·x of that point)
- **Repository:** main @ d9afebe. Only `verification/` is untracked.

## What was checked

I wrote a new probe from the finding's description alone (Slots/V091/main.swift). It builds the models with the public DSL, which is the user path; the finder built a `CompiledLP` directly. It also runs the README's flagship facade `Automatic()`. I did not use the finder's oracle or the package's `maxViolation` as an oracle. Every returned point is checked against hand-written coefficient lists in the probe.

Models:
- **FC**: min 100·open + flow, with flow ≥ 0.5, flow − M·open ≤ 0, open binary and flow in [0, 10]. The DSL lowers the demand row to a bound.
- **FC2**: the same with two flows a and b, so that demand stays a real two-column row: a + b ≥ 0.5 and a + b − M·open ≤ 0.
- **PI**: min p + q, with 1e7·p + 1e7·q ≥ 5 and p, q integer in [0, 10].

Independent expected values:
- **FC by hand.** open = 0 forces flow ≤ 0, which contradicts flow ≥ 0.5, so it is infeasible. open = 1 gives flow = 0.5 and objective 100.5. Enumerating open ∈ {0,1} with a flow grid of step 1e-3 also gives 100.5 at (1, 0.5).
- **FC with open fixed, solved as an LP by a second engine.** With open = 0, Simplex(.dual) and InteriorPoint both return `infeasible`. With open = 1, both return `optimal 100.5`.
- **PI.** Enumerating 0..10 × 0..10 gives 1.0 at (0, 1). CPSAT(deterministic: true), a second and exact engine, returns `optimal 1.0` at (0, 1) with no row violation.
- **The LP relaxation itself** gives open = 5e-7 and flow = 0.5, objective 0.50005. |open − round(open)| = 5e-7 is below `Tolerances.default.integrality` = 1e-6.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A
swift build --product V091 -c release            # Build complete
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V091 main      # exit 0
```
FC, M = 1e6. The oracle gives 100.5 at open=1, flow=0.5. Nine configurations all printed the same result:
```
status=optimal obj=0.50005 bound=0.50005 point{open=0.0 flow=0.5}
check: rowViol=0.5 [link act=0.5 in [-inf, 0.0]] intViol=0.0 c.x=0.5 |obj-c.x|=5e-05
incumbent sources: [lp@node0]  warnings: []
```
The nine configurations:
- Automatic()
- Conditioned(Automatic())
- BB<Simplex.primal> with defaults
- BB<Simplex.dual>, deterministic
- BB<InteriorPoint>
- BB<Simplex.primal>, heuristics .none, mostFractional branching
- BB<Simplex.dual>, Gap(0,0)
- BB<Simplex.primal, presolve false, scaling .none>, 8 threads
- BB<Simplex.dual>, strong(6) branching, bestBound selection, 4 threads

FC2 printed the same with point {open=0, a=0.5, b=0} and rowViol=0.5 on `link`.

PI, through every configuration above:
```
status=optimal obj=5e-07 bound=5e-07 point{p=0.0 q=0.0}
check: rowViol=5.0 [cover act=0.0 in [5.0, inf]] c.x=0.0
CPSAT(deterministic) [second engine]: status=optimal obj=1.0 point{p=0.0 q=1.0} rowViol=0.0
```

```
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V091 engines   # exit 0
  open fixed 0.0: Simplex.dual status=infeasible; InteriorPoint status=infeasible
  open fixed 1.0: Simplex.dual status=optimal obj=100.5; InteriorPoint status=optimal obj=100.5
  LP relaxation: optimal obj=0.50005 open=5e-07 flow=0.5; |open-round(open)| = 5e-07 vs integrality 1e-06
  PI LP relaxation: optimal obj=5e-07 p=5e-07 q=0.0
```

The mechanism scan sets the LP value of open to 0.5/M, so it crosses the 1e-6 tolerance between M = 4e5 and M = 6e5:
```
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V091 scan      # exit 0
  M=1e3..4e5 (LP open 5e-4..1.25e-6): optimal 100.5 at open=1, rowViol 0, source rounding@node0
  M=6e5 (LP open 8.3e-7): optimal 0.50008333 at open=0 flow=0.5, rowViol 0.5, source lp@node0
  M=1e6 (5e-7): optimal 0.50005, rowViol 0.5, lp@node0
  M=1e7 (5e-8): optimal 0.500005, rowViol 0.5, lp@node0
  M=1e9 (5e-10): optimal 0.50000005, rowViol 0.5, lp@node0
```
The result is wrong exactly when the LP value falls within the integrality tolerance, which is what the finding predicts. Above the threshold the rounding heuristic, which does call `isFeasible`, rejects open = 0 and finds open = 1.

The repeat mode tests load and randomness:
```
perl -e 'alarm shift; exec @ARGV' 500 .build/release/V091 repeat    # exit 0
  FC: 81 solves, 1 outcome. (The tool printed 2 groups, which differ only in the "@nodeN" suffix the probe strips for some runs.)
      The outcome: optimal 0.50005 at open=0 flow=0.5, rowViol 0.5, source lp.
      The runs: seeds 0, 1, 7 and 12345 × threads 1, 2 and 8 × 5 repetitions, plus 5 sequential and 16 concurrent Automatic solves at 8 threads.
  PI via Automatic: 10 solves at threads 1 and 8, all optimal 5e-07 at (0,0), rowViol 5.0
```

## Code reading

`Sources/ZTronLPBranchAndBound/TreeSearch.swift:200-204`, in `expand`: when no integer column is fractional beyond `integrality` (1e-6), the code rounds every integer column. It then calls `offer(objective: objective, ...)` with the node's LP objective, with no `isFeasible` check and no `lp.internalObjective(at:)`. The `dive` path at lines 446-449 does both, and so does `roundingHeuristic` (line 364). The root node takes the same path, through `search.expand` in BranchAndBound.swift. `SearchTree.offerIncumbent` compares objectives only. The result assembly in `BranchAndBound.search` returns `incumbent.x` and the stored objective unchanged, so nothing checks the point later.

## Why the defect stands

1. **The behaviour happens.** It shows on every configuration, every engine, every thread count and seed, and both facades. It shows in both shapes and in a third variant, FC2.
2. **The expected values are right.** The exact optimum (100.5, and 1 for PI) was derived by hand, by enumeration, by two LP engines with open fixed, and by CP-SAT. Take even the most charitable tolerance-based reading, in which a solver may accept the unrounded LP point (open=5e-7, flow=0.5) as integral within 1e-6, with value 0.50005. The package still does not return that point. It returns open = 0, which violates `link` by 0.5. The bound in force is 1e-7·(1+|0|) in `isFeasible`, and 5e-7 even after dividing by the row's 1e6 coefficient. PI is violated by 5. The reported objective also differs from c·x of the returned point, by 5e-5 for FC and 5e-7 for PI.
3. **Load and randomness play no part.** The path is deterministic, and 91 repeated solves across seeds, thread counts and in-process concurrent load were identical.

The package's own test oracle, `isIntegralAndFeasible` (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:61-65), would reject this point: it requires a row violation of at most 1e-6.

## Documentation

README §4 "Results" says `.optimal` means feasible and dual feasible to 1e-7. Neither README §2.5, §3 (risks 1 and 10), §4 nor the HANDBOOK mentions that an LP point integral within tolerance is rounded and returned unchecked, or that big-M rows can yield an infeasible incumbent. Risk 1's generic advice to check points with `maxViolation` does not document this behaviour. The result carries no warning: `warnings` is empty, `Conditioned` included.

## Caveat

The title's "objective off by a factor of 200" holds against the exact MIP optimum, which is 100.5. A tolerance-based reading could accept 0.50005 as a value, but only together with the unrounded point, which is not what is returned. The core defect does not depend on this distinction: a point infeasible by 0.5, or by 5, is reported with `.optimal`.
