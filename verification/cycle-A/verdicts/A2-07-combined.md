# A2-07 combined verdict (cycle A, sceptic, lens: reproduce and contract)

Finding: "No simplex test checks returned duals or reduced costs beyond one textbook LP, and no test covers crossed bounds".

- verdict: **refuted**
- documented: false
- severity: info (finder: low)
- probe: verification/probes/cycle-A/Slots/V049/main.swift; full output in verdicts/A2-07-combined.V049-output.txt

## Reasoning

The main claim does not reproduce. The finder's own repro grep prints
`Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift:48-49` (`analysis.dual` and then
`lp.reducedCosts(forDuals: y)`). Lines 50-55 assert structural dual feasibility together with
complementary slackness: d_j <= tol when x_j is above its lower bound, d_j >= -tol when x_j is
below its upper bound, with tol = 1e-5 * (1 + |obj|). The assertion runs on all 13 netlib LPs
under 4 simplex configurations (primal and dual, each with and without presolve and scaling),
so 52 test cases. All 52 ran and passed in baseline/03-test-debug.log (lines 380-390), and they
passed again when I ran them. Two more simplex tests check duals, outside the two directories
the finder searched:
- `Tests/ZTronLPOptimizerTests/FacadeTests.swift:95-117` (WorkedExampleTests.transportLPWithNamedDuals). It runs `Simplex(.dual)` and checks strong duality by constraint name to 1e-7, and that every reduced cost is >= -1e-7.
- `Tests/ZTronLPOptimizerTests/ReadmeExampleTests.swift:78-95` (theRelaxationHasShadowPrices). It runs `Simplex(.dual)` and checks the shadow prices 19/6 and 8/3 to 1e-9.

Other tests touch duals as well:
- RefinementTests compares the duals of two runs. That checks consistency only.
- InteriorPointTests.textbookProblemWithDualsAndBounds covers crossover `.lite`.
- PresolveTests.postsolvedDualsAreOptimalOnConstructedProblems uses `ConstructedInstance.dual` (`base.dual`, line 485). That contradicts "used only by ScalingTests and FixtureTests". The test checks the postsolve dual mapping with a full KKT check, rows included, to 1e-7 over 120 seeds.

The finder also wrote that a wrong dual sign or dual-infeasible reduced costs would pass the
suite. Mutation testing refutes this (Method 1 below). Feeding the suite's own netlib assertion
deliberately broken duals:

| Mutation | Netlib assertion fails in |
|---|---|
| All duals negated | 52/52 |
| All duals zero | 52/52 |
| Largest dual negated | 52/52 |
| Duals x 1.1 | 52/52 |
| Each nonzero dual negated in turn | 3924/4137 (95%) |
| Each nonzero dual zeroed in turn | 3880/4137 (94%) |

The transport test catches every mutation I tried, including negating only the reduced costs.
The textbook test catches every mutation of the duals. So "half of the 'optimal' contract has no
test that could fail" is false.

Contract check: the duals are right. An oracle unlike the finder's per-component sign checks
(Method 2) certifies every answer:
- On netlib the worst duality gap is 2.4e-15 and the worst dual infeasibility 3.0e-12.
- In 50 of 52 cases y equals B^-T c_B, computed by my own Gaussian elimination, to 2.3e-14.
- The 2 exceptions are beaconfd with presolve on, where 25 rows differ. Both dual vectors are optimal there (gap -4.3e-16, dual infeasibility <= 2.4e-15), and the returned basis warm-starts the unpresolved LP in 0 iterations. That is dual degeneracy, not a defect.
- On constructed instances, 600 + 400 optimal solves with half of them maximizations, the worst gap is 2.4e-14. The logical reduced cost equals the dual exactly. The reported rc equals flip*d(flip*y) exactly.

So README §4 "dual feasible to 1e-7" and the HANDBOOK and Analysis.swift sign convention hold.
The docs claim no more test coverage than exists. HANDBOOK Testing lists the oracles. SPEC v0.2
§6 "expanded duals feasible and complementary" is a planned oracle, not a current one.

The two sub-claims:
- **IllConditionedTests: 2e-5 against README "about 1e-6".** This is literally true. But the README number is a measured value in §5, and I reproduced it exactly: at order 8 the distances are 3.96e-7 for dual, 8.72e-7 for primal and 7.64e-7 for the interior point. The test still catches the failure it is named for, defect 8 (a distance of 1 to 2.1), with a margin of five orders of magnitude.
- **"No test exercises crossed bounds".** This is false as stated. These tests cover it:
  - `CompileTests.swift:339` (crossedBoundsAreRejected)
  - `LPFormatTests.swift:448`
  - `MPSFormatTests.swift:474`
  - `PresolveTests.swift:311` (crossed column bounds give presolve `.infeasible`)
  - `SimplexTests.swift:96-104` (crossing singleton rows through Simplex give `.infeasible` with a certified ray)

  It is true only in a narrow sense: no test hands Simplex a CompiledLP with xl > xu or rl > ru. That is the subject of A2-01, which stands or falls on its own.

Remaining true but narrow (info; no underlying defect found):
1. SimplexConstructedOptimaTests and ConstructedOptimaCorpusTests never check the duals, although the generator supplies them.
2. NetlibSimplexTests checks structural columns only, not the row-dual signs. Its tolerance, 1e-5*(1+|obj|), is far looser than 1e-7: a 0.1% dual scaling error goes unnoticed in 28 of 52 cases.
3. For a maximization, the reported `reducedCosts` are checked for count only (SimplexTests.swift:79). A missing sign flip there would pass the suite. The values are derived from the duals in one line (Simplex.swift:262-263) and were exact in every probe solve.

## Commands and key output

```
grep -rn 'instance\.dual\|analysis.dual\|reducedCosts' Tests/ZTronLPSimplexTests Tests/ZTronLPIntegrationTests
  -> includes Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift:48 `let y = try #require(analysis.dual)`
     and :49 `let d = lp.reducedCosts(forDuals: y)`; the assertion is at :55
grep -rn 'optimalityViolation|.dual(|reducedCost(of|dual(ofConstraint' Tests  (filtered)
  -> FacadeTests.swift:110-116, ReadmeExampleTests.swift:87-88, RefinementTests.swift:67-84,
     InteriorPointTests.swift:82, PresolveTests.swift:485-563 (base.dual)
grep -n 'WithoutPresolveOrScaling(_:) with|ReachesThePublishedOptimum(_:) with' baseline/03-test-debug.log
  -> 4 x "with 13 test cases passed"

swift test --filter 'ZTronLPSimplexTests.NetlibSimplexTests|...ReadmeExampleTests/theRelaxationHasShadowPrices'
  -> 4 tests x 13 cases passed; theRelaxationHasShadowPrices passed   (rc=0)
swift test --filter 'ZTronLPOptimizerTests.WorkedExampleTests/transportLPWithNamedDuals'
  -> passed (rc=0)

cd verification/probes/cycle-A && swift build --product V049 -c release
perl -e 'alarm shift; exec @ARGV' 900 .build/release/V049 all            (rc=0, 0.5 s)
  netlib cases solved optimal: 52; control (real duals) passes the suite's assertion: 52/52
  independent oracle on real duals: worst |duality gap| 2.40e-15, worst dual infeasibility 3.01e-12
  mutation 'negate all duals': NetlibSimplexTests assertion fails in 52/52 cases; Lagrangian oracle rejects 52/52
  mutation 'all duals zero': ... 52/52; oracle 52/52
  mutation 'negate the largest dual': ... 52/52; oracle 52/52
  mutation 'duals x 1.001': ... 24/52; oracle 52/52
  mutation 'duals x 1.1': ... 52/52; oracle 52/52
  mutation 'negate one nonzero dual' (each in turn): assertion fails 3924/4137; oracle rejects 4137/4137
  mutation 'zero one nonzero dual' (each in turn): assertion fails 3880/4137; oracle rejects 4136/4137
  transport (dual and primal): control strong=true signs=true; every mutation FAIL (caught),
    incl. 'reduced costs alone negated' (signs=false)
  textbook (4 runs): control true, gap 0; every dual mutation FAIL (caught);
    'reduced costs alone negated' and 'reduced costs without the max flip' pass (missed)
  constructed: 400 optimal solves (100 of 200 instances are maximizations), 0 bad; worst |gap| 1.63e-14,
    worst |rc_logical - dual| 0, worst |reported rc - flip*d(flip*y)| 0
  order 8: Simplex(.dual) 3.96e-07 Simplex(.primal) 8.72e-07 InteriorPoint() 7.64e-07 [all optimal]
.build/release/V049 constructed 300 -> 600 optimal solves (150 max), 0 bad; worst |gap| 2.36e-14
.build/release/V049 aside beaconfd  (rc=0)
  primal/dual with presolve: 25 rows whose dual differs from B^-T c_B; reported y gap -4.33e-16 dualInf <=2.41e-15;
    basis y gap -4.33e-16 dualInf 1.78e-15; warm start of the unpresolved problem: optimal in 0 iterations
  without presolve: 0 rows differ
```
