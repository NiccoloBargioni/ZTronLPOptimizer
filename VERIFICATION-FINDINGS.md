# ZTronLPOptimizer: verification findings (interim)

Snapshot of 2026-11-18, 14:12 CET against `main` @ `d9afebe`. Verification only: nothing in the package was changed to produce these results.

> **Status: interim.** All 14 finders have finished. 31 of the 136 planned skeptic checks are done (30 confirmed, 1 refuted), and the cross-cycle reconciliation has not run yet. A finding marked *pending* is its finder's claim, backed by the finder's own reproduction, but no skeptic has checked it yet.

## Contents

- [Summary](#summary)
- [How the findings were produced](#how-the-findings-were-produced)
- [All issues, most severe first](#all-issues-most-severe-first)
- [Findings by area](#findings-by-area)
  - [F1 Core: DSL, compile, presolve, scaling, MPS/LP I/O, result types](#f1-core)
  - [F2 Simplex engine and numerics](#f2-simplex)
  - [F3 Interior point, crossover, conditioning, Conditioned](#f3-ipm)
  - [F4 Branch and bound](#f4-bnb)
  - [F5 CP-SAT](#f5-cpsat)
  - [F6 Runtime: cancellation, limits, events, concurrency, memory budget, Metal, Automatic, Portfolio](#f6-runtime)
  - [F7 Package integrity: gates, docs, published numbers, tests, layering](#f7-integrity)
- [Reproducing a finding](#reproducing-a-finding)

## Summary

The two cycles reported 110 findings: 60 in cycle A and 50 in cycle B. Counting findings that describe the same defect once leaves 75 distinct issues, and 28 of them were found independently by both cycles. By the highest rating a finder gave them, 15 are critical, 8 high, 23 medium, 25 low and 4 info.

Where the defects are:

- **Wrong answers under a success status.** These are the critical findings: `.optimal` at an infeasible or non-optimal point, or a false `.infeasible`.
  - Branch and bound. An LP-integral node solution is rounded and accepted without re-checking its rows ([A4-01](#a4-01), [B4-01](#b4-01)). Heuristic incumbents pass a feasibility test that is relative to the row bound ([A4-02](#a4-02), [B4-04](#b4-04)). The objective-step cutoff prunes the optimum ([A4-03](#a4-03), [B4-02](#b4-02)).
  - CP-SAT. Data of magnitude 2^49 and above is rounded by a 4-ulp snap ([A5-01](#a5-01), [B5-01](#b5-01)). Coefficients that should be rejected are rounded instead ([A5-02](#a5-02), [B5-02](#b5-02)).
  - Simplex. Crossed bounds are solved to `.optimal` ([A2-01](#a2-01), [B1-03](#b1-03)). Phase 1 declares feasible LPs infeasible, with a ray that proves nothing ([A2-02](#a2-02), [B2-02](#b2-02)). The refinement pass can return the all-slack starting basis as optimal ([B2-01](#b2-01)).
  - Interior point. It reports `.optimal` on an infeasible LP, overriding the crossover's own verdict ([A3-01](#a3-01), [B3-01](#b3-01)). It answers `.infeasible` on feasible LPs at condition numbers of 1e8 to 1e10 ([A3-02](#a3-02)). With `crossover: .none` it can report answers far from the optimum ([B3-02](#b3-02)).
  - Core. Presolve rounds integer bounds outward once they reach about 1e9 ([B1-01](#b1-01)). The default geometric scaling can lead to `.optimal` at a non-optimal vertex, with no warning ([B1-02](#b1-02)).
- **Bounds and gaps that are not proofs.** A search that completes after pruning by the gap, or that stops while the root is being expanded, reports bound = incumbent and gap 0 ([A4-04](#a4-04), [B4-03](#b4-03), [A4-05](#a4-05), [A6-01](#a6-01)).
- **Limits not honoured.** CP-SAT root propagation ignores the time limit, cancellation and the memory budget ([B5-04](#b5-04)). `Conditioned` runs its analysis after a cancelled solve ([A6-03](#a6-03), [B6-01](#b6-01)). Interior-point cancellation latency grows with problem size ([A6-02](#a6-02), [B6-02](#b6-02)).
- **Tests that cannot fail** for the bug they are named for, and test runs that count skipped cases as passed. Examples: [A7-01](#a7-01), [A3-08](#a3-08), [A5-03](#a5-03), [B4-05](#b4-05), [B6-05](#b6-05), [B7-01](#b7-01).
- **Documentation and published numbers** that disagree with what was measured: the README §5 tables, the defect descriptions in README §4, and several doc comments.

Most failures need edge inputs: badly scaled or very large data, values at a tolerance boundary, crossed bounds, or a limit that lands at a particular moment. On well-posed inputs, the large oracle sweeps found nothing:

- Simplex: about 75,000 solves on KKT-constructed LPs in cycle A, and 129,600 solves over 432 configurations on planted LPs in cycle B.
- Netlib: every optimum within a relative 1.33e-11, in every configuration.
- Branch and bound: 9,240 runs checked against exhaustive enumeration, and all 10 MIPLIB 3 instances solved to their published optima.
- CP-SAT: every SATLIB uf50-218 and uuf50-218 instance answered correctly, and thousands of models checked against enumeration.

Findings by the finder's severity and by verification status:

| Severity | Findings | Confirmed | Refuted | Pending | Not verified (info) |
|---|---:|---:|---:|---:|---:|
| critical | 20 | 7 | 0 | 13 | 0 |
| high | 11 | 2 | 0 | 9 | 0 |
| medium | 32 | 4 | 0 | 28 | 0 |
| low | 42 | 10 | 1 | 31 | 0 |
| info | 5 | 0 | 0 | 0 | 5 |

A finding counts as confirmed here once at least one skeptic has confirmed it; the "Verification" line of each finding says how many have.

## How the findings were produced

- **Two independent cycles** covered the same seven areas, and neither saw the other's work.
  - Cycle A worked claims first. It listed what the README, HANDBOOK, doc comments and tests claim, and tried to falsify each claim by running a check.
  - Cycle B worked oracles first. It derived the contract from first principles (KKT conditions, Farkas certificates, enumeration, round trips), built its own oracles, and attacked the public API with adversarial inputs.
- **One finder per area and cycle** wrote probe programs against the public API. For each discrepancy it recorded the reproduction command, the observed output, why it is wrong, the likely culprit as file:line, and whether the behaviour is documented. Findings come from three sources: the mathematical contract, a claim the package makes about itself, or an internal invariant. A test that cannot fail for the bug it targets also counts.
- **Skeptics try to refute each finding.**
  - Critical and high findings get two skeptics, one with a *reproduce* lens and one with a *contract* lens, and a tiebreak if they disagree.
  - Medium and low findings get one skeptic, with a *combined* lens. The finding is escalated if that skeptic rates it high or critical.
  - Info items are recorded, not verified. At most 10 findings per finder are verified.
- **The finders and skeptics are AI agents (Claude Code).** Each result rests on executed probes unless its confidence says "code-reading-only".
- **"Same defect" and "Related" links** were made by hand from titles and locations. The workflow's own cross-cycle reconciliation has not run yet.

### Severity scale

- **critical:** a wrong answer reported with a success status (`.optimal` or `.feasible` with a wrong value or an infeasible point, a false `.infeasible` or `.unbounded`), memory unsafety, or a data race.
- **high:** a crash, trap or hang on valid input; a limit or cancellation not honoured; a published claim that is materially false.
- **medium:** a wrong status or an invalid certificate on edge cases; misleading API behaviour; a test that cannot catch the bug it is named for; a malformed file that traps instead of throwing.
- **low:** a minor documentation or number mismatch; a small inconsistency.
- **info:** an observation worth recording, not verified further.

### Verification labels

- **confirmed 2/2:** both skeptics (reproduce and contract lenses) confirmed the finding.
- **confirmed 1/2:** one of the two skeptics confirmed it; the other check is pending.
- **confirmed 1/1:** the single skeptic (combined lens) confirmed it.
- **confirmed 1/1, escalated:** the skeptic confirmed it and rated it high or critical, so by the policy a second skeptic and a tiebreak are due.
- **refuted:** the skeptic found that the finding does not hold as stated.
- **pending:** no skeptic has checked it yet. The finding rests on its finder's own reproduction.
- **n/a:** an info item, not verified by design.

### Baseline: the package's own gates

All of these passed on a quiet machine before any agent ran. The machine was an Apple M3 (8 cores, 24 GiB) running macOS 27.0 with Apple Swift 6.4 (swiftlang-6.4.0.34.1).

- `swift build --build-tests -Xswiftc -warnings-as-errors`: passed (31 s).
- `Scripts/lint.sh`: passed.
- `swift test` (debug): passed (250 s).
- `swift test -c release --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests'`: passed (246 s). Its summary line reads "17 tests in 5 suites passed … with 1 known issue".
- Thread Sanitizer, `ZTRONLP_LATENCY_SCALE=20 swift test --sanitize=thread --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests|ZTronLPBranchAndBoundTests|ZTronLPCPSATTests'`: passed (838 s), with no ThreadSanitizer warnings.

Two integrity findings qualify these passes: debug and Thread Sanitizer runs count skipped MIPLIB cases as passed ([A7-04](#a7-04), [B7-01](#b7-01)).

## All issues, most severe first

One row per distinct issue. Severity is the highest rating any finder gave; the findings column gives each finding's verification status.

| Severity | Issue | Findings |
|---|---|---|
| critical | Crossed bounds (xl > xu or rl > ru) are reported .optimal at an infeasible point, even after presolve has diagnosed infeasibility | [A2-01](#a2-01) confirmed 2/2<br>[B1-03](#b1-03) pending |
| critical | Primal simplex declares a feasible LP with condition number 1.5e9 infeasible, without a warning and with a dual ray that does not certify | [A2-02](#a2-02) confirmed 2/2<br>[B2-02](#b2-02) pending |
| critical | An LP-integral node solution is rounded and accepted as incumbent without re-checking feasibility or recomputing the objective: big-M model reported optimal at an infeasible point, objective off by a factor of 200 | [A4-01](#a4-01) confirmed 2/2<br>[B4-01](#b4-01) pending |
| critical | Heuristic incumbents are accepted by a feasibility test relative to the row bound (1e-7\*(1+\|bound\|)): integer-data knapsack reported optimal at 10,000,000 when the optimum is 9,999,999 | [A4-02](#a4-02) confirmed 2/2<br>[B4-04](#b4-04) pending |
| critical | objectiveStep counts an integer column's cost of magnitude &lt;= 1e-9 as an integral 0, so pruning by a whole objective step discards better solutions: reported optimal 1, true optimum 0.75 | [A4-03](#a4-03) confirmed 2/2 |
| critical | BranchAndBound stopped during the root's expansion reports bound = incumbent and gap 0 (false optimality certificate) | [A4-05](#a4-05) confirmed 2/2<br>[A6-01](#a6-01) pending |
| critical | Coefficients that no power of 10 up to 1e6 makes integral (or whose scaling passes 2^53) are silently rounded instead of rejected: false optimum, or SolverError.internalInconsistency | [A5-02](#a5-02) confirmed 1/1, escalated<br>[B5-02](#b5-02) pending |
| critical | In-domain data of magnitude >= 2^49 is silently rounded by a 4-ulp snap tolerance: infeasible points and wrong optima labelled .optimal | [A5-01](#a5-01) confirmed 1/2<br>[B5-01](#b5-01) confirmed 1/2 |
| critical | InteriorPoint returns .optimal on an infeasible LP (violation 0.5) and overrides its own crossover's .infeasible verdict | [A3-01](#a3-01) pending<br>[B3-01](#b3-01) pending |
| critical | Default InteriorPoint() answers .infeasible on feasible bounded LPs at condition 1e8..1e10, with a dual ray that is not a Farkas certificate | [A3-02](#a3-02) pending |
| critical | Presolve integer-bound rounding moves integral bounds outward by about 1e-9\*\|b\| per pass once \|b\| >= \~1e9; BranchAndBound and Automatic return .optimal points outside the bounds | [B1-01](#b1-01) pending |
| critical | Geometric scaling, the default, makes Simplex(), Simplex(.primal) and Automatic() return .optimal at a non-optimal vertex with no warning when one row mixes coefficients >= 1e16 apart | [B1-02](#b1-02) pending |
| critical | Refinement pass swaps the optimal basis for the all-slack basis (sparse QR) and reports that starting point as .optimal, infeasible by 3.4e7 | [B2-01](#b2-01) pending |
| critical | InteriorPoint(crossover: .none) reports .optimal with a grossly wrong objective (up to \~290x) when finite variable bounds are large | [B3-02](#b3-02) pending |
| critical | Incumbent keeps the inflated LP objective, so the objective-step cutoff prunes the true optimum: .optimal a full unit below it, even with Gap(0,0) | [B4-02](#b4-02) pending |
| high | A search that completes after pruning by the gap reports bound = incumbent and gap = 0: with Gap(relative: 0.05) a 3% suboptimal incumbent is reported with gap 0; with the default gap, 35 of 60 runs report a bound past the true optimum | [A4-04](#a4-04) confirmed 2/2<br>[B4-03](#b4-03) pending |
| high | MPS and LP readers accept non-finite and out-of-range numbers; the engines then return success statuses with wrong answers | [A1-01](#a1-01) pending<br>[B1-04](#b1-04) pending |
| high | .infeasibleOrUnbounded on feasible bounded ill-conditioned LPs (the defect-8 answer class, documented as fixed) when the absolute mu gate fires | [A3-03](#a3-03) pending |
| high | Cancellation and time limits wait for uninterruptible interior-point factorizations and presolve/scaling: latency grows with problem size | [A6-02](#a6-02) pending<br>[B6-02](#b6-02) pending |
| high | Conditioned runs the full conditioning analysis after a cancelled or timed-out inner solve | [A6-03](#a6-03) pending<br>[B6-01](#b6-01) pending |
| high | Feasible bounded LPs with large solution, dual or bound magnitudes get .infeasibleOrUnbounded at iteration 0 in every IPM configuration, including the default | [B3-03](#b3-03) pending |
| high | With decimal costs and \|objective\| &lt; 1, CP-SAT stops up to 1e-4 (absolute) from the bound and reports .optimal: answers 2% to 50x off, where its API doc promises an exact proof | [B5-03](#b5-03) pending |
| high | Root propagation of two parallel rows over a wide domain runs about 1.7\*U bound changes inside one propagate() call: time limit, cancellation and memory budget are ignored and RSS grows past 10 GB | [B5-04](#b5-04) pending |
| medium | After a failed refinement pass, .optimal stands although the refactorized vertex violates feasibility by up to 8e3; the same badly scaled inputs also get false .infeasible verdicts | [A2-03](#a2-03) confirmed 1/1, escalated |
| medium | 'Beyond a condition number of about 1e11 only the objective can be trusted' holds only for the Hilbert family's objective | [A2-04](#a2-04) confirmed 1/1 |
| medium | Test sixteenMegabytesIsEnoughAndIsRespected never reaches its budget, so it cannot fail if memoryBudgetBytes is ignored | [A4-08](#a4-08) confirmed 1/1<br>[A6-07](#a6-07) pending<br>[A7-01](#a7-01) pending |
| medium | Tests named for large-data handling and inward rounding never reach the magnitudes where A5-01 fails | [A5-03](#a5-03) confirmed 1/1 |
| medium | Presolve.expandBasis returns an optimal-status basis that is dual infeasible and disagrees with the returned duals | [A1-02](#a1-02) pending<br>[A3-07](#a3-07) pending<br>[B3-05](#b3-05) pending |
| medium | CompiledLP.maxViolation(at:) reports zero violation for a point that contains NaN | [A1-03](#a1-03) pending<br>[B1-10](#b1-10) pending |
| medium | An infeasible or tolerance-level conflicting one-variable constraint makes compile and solve throw invalidModel instead of returning .infeasible | [A1-04](#a1-04) pending<br>[B1-08](#b1-08) pending |
| medium | Solution.dual(ofConstraintNamed:) gives each lowered singleton constraint the whole reduced cost when several imply the same active bound, so the reported duals are not a dual solution | [A1-05](#a1-05) pending<br>[B1-07](#b1-07) pending |
| medium | LP writer name-collision handling produces duplicate row and range-column names, so the file read back is a different LP (optimum 4 becomes 6) | [A1-10](#a1-10) pending<br>[B1-05](#b1-05) pending |
| medium | InteriorPoint returns .feasible(stoppedBy: .timeLimit) when a limit lands in the stalled path's crossover | [A3-04](#a3-04) pending<br>[B3-06](#b3-06) pending |
| medium | InteriorPoint(crossover: .none) .optimal points violate rows by up to 2.6e-5 while reporting primalResidual 3.9e-12 | [A3-05](#a3-05) pending |
| medium | Defect 10 described wrongly: InteriorPoint(crossover: .none) also returns .optimal far from the unique optimum at condition \~1e6, with no warning | [A3-06](#a3-06) pending |
| medium | The interior-point tests cannot catch A3-01, A3-02, A3-03, A3-05 or A3-06 | [A3-08](#a3-08) pending |
| medium | SolveContext.threads does not bound InteriorPoint (Accelerate threads) or a Portfolio with more members than threads | [A6-04](#a6-04) pending<br>[B6-06](#b6-06) pending |
| medium | Portfolio returns the first inconclusive result to arrive, not the best: a worse incumbent than one of its members | [A6-05](#a6-05) pending<br>[B6-03](#b6-03) pending |
| medium | LPModel convenience solve: a compile error exits with no .started/.finished, so a makeEventStream consumer never ends | [A6-06](#a6-06) pending |
| medium | Twelve MIPLIB corpus cases pass silently in every debug build, including CI's test job and its Thread Sanitizer job | [A7-04](#a7-04) pending<br>[B7-01](#b7-01) pending |
| medium | Readers silently accept structurally malformed files: RANGES before RHS drops the ranges, MPS without ENDATA or truncated mid-COLUMNS loads as a smaller model, and a second LP objective is summed into the first | [B1-06](#b1-06) pending |
| medium | Dual simplex stalls until the 50,000-pivot cap on a feasible 36x78 LP; .onStall never fires because its trigger measures primal degeneracy | [B2-03](#b2-03) pending |
| medium | The 1e-4 stall ceiling makes the default InteriorPoint() answer .infeasibleOrUnbounded for feasible bounded badly scaled LPs instead of letting the simplex finish | [B3-04](#b3-04) pending |
| medium | aLooseGapStopsEarlyAndReportsIt cannot detect invalid bounds: its instance has integral costs, so the slack-cutoff path never runs | [B4-05](#b4-05) pending |
| medium | Portfolio invokes the progress callback concurrently from its members; chained listeners see different event orders | [B6-04](#b6-04) pending |
| medium | The Metal kernel tests pass, by skipping, when the shader library does not compile | [B6-05](#b6-05) pending |
| low | README 5 ill-conditioned table under-counts the warned answers at orders 4 and 5 | [A2-05](#a2-05) confirmed 1/1<br>[A3-10](#a3-10) pending<br>[A7-02](#a7-02) pending<br>[B7-03](#b7-03) pending |
| low | SparseQRBasis doc comment says it is chosen when the basis density is below 2%; no code does that | [A2-06](#a2-06) confirmed 1/1<br>[B2-04](#b2-04) pending |
| low | deterministic: true results depend on SolveContext.threads: threads 1 and threads >= 2 give different LP-iteration counts and, on one instance, a different event sequence and incumbent history | [A4-06](#a4-06) confirmed 1/1<br>[B4-06](#b4-06) pending |
| low | BranchAndBoundAnalysis.lpIterations, published as 'LP pivots' in README §5, adds a fixed estimate of 25 pivots per strong-branched candidate instead of the probes' real pivots | [A4-07](#a4-07) confirmed 1/1<br>[B4-09](#b4-09) pending |
| low | .boundImproved events of a parallel search can arrive out of order (a later event reports a weaker bound) | [A4-09](#a4-09) confirmed 1/1 |
| low | winningWorker of a parallel feasibility solve can name a worker whose solution was not the one returned | [A5-04](#a5-04) confirmed 1/1 |
| low | bound differs from objectiveValue on .optimal results, contrary to two doc comments | [A5-05](#a5-05) confirmed 1/1 |
| low | Bounds of magnitude 2^53-4 to 2^53-1 are rejected although README rejects only magnitudes of 2^53 or more | [B5-05](#b5-05) confirmed 1/1 |
| low | SATLIB corpus tests are disabled, not reported as a known issue, when the corpus is missing | [B5-06](#b5-06) confirmed 1/1 |
| low | The free-format MPS round trip is not bit-exact for range rows | [A1-06](#a1-06) pending<br>[B1-09](#b1-09) pending |
| low | The MPS writer produces a file its own reader rejects when a constraint is named "" | [A1-07](#a1-07) pending |
| low | LP export drops columns that have no cost, no row and default bounds, and renumbers columns; README describes only the Rg column | [A1-08](#a1-08) pending |
| low | .unbounded Simplex results carry an objectiveValue although hasSolution is false | [A1-09](#a1-09) pending |
| low | Defect 7 understates: the interior point itself never returns .infeasible or .unbounded | [A3-09](#a3-09) pending<br>[B3-07](#b3-07) pending |
| low | Test timeLimitsAreHonouredPromptly cannot fail in release for an ignored time limit | [A6-08](#a6-08) pending |
| low | Metal activity screen rejects a feasible point when a finite row bound exceeds 3e38 | [A6-09](#a6-09) pending |
| low | Scripts/lint.sh misses violations inside its own stated C2/C3/C6 scope | [A7-03](#a7-03) pending<br>[B7-02](#b7-02) pending |
| low | fetch-miplib.sh ignores ZTRONLP\_CORPORA although the tests and its doc comment say the fetch scripts use it | [A7-05](#a7-05) pending |
| low | FixtureTests.constructedInstancesAreFeasibleAndComplementary checks only the column half of the certificate | [A7-06](#a7-06) pending |
| low | Manifest and HANDBOOK misstate the dependency and import graph | [A7-07](#a7-07) pending<br>[B7-05](#b7-05) pending<br>[B7-07](#b7-07) n/a |
| low | The SolutionAnalysis.bound doc says it 'equals objectiveValue when optimal', which is false for a MILP that is optimal by gap | [B4-07](#b4-07) pending |
| low | A nodeLimit equal to the node count of the complete search reports .feasible(nodeLimit) although the search proved optimality | [B4-08](#b4-08) pending |
| low | IllConditionedTests' 'an answer this fragile must carry a warning' cannot fail for InteriorPoint() | [B7-04](#b7-04) pending |
| low | Test mixedModelsAgreeAcrossStrategiesAndWorkerCounts runs one strategy | [B7-06](#b7-06) pending |
| low | No simplex test checks returned duals or reduced costs beyond one textbook LP, and no test covers crossed bounds | [A2-07](#a2-07) refuted 1/1 |
| info | Every unbounded relaxation is answered .infeasibleOrUnbounded, even for an evidently unbounded integer model; the status's doc comment attributes it to the interior point only | [A4-10](#a4-10) n/a |
| info | README 'no single full debug run of it was green' is stale | [A7-08](#a7-08) n/a |
| info | Cancellation-latency figures count solves that finished before the cancel as 0 ms | [A7-09](#a7-09) n/a |
| info | ci.yml's TSAN rule says threads = 8, but nothing sets it | [B7-08](#b7-08) n/a |

## Findings by area

### <a id="f1-core"></a>F1 Core: DSL, compile, presolve, scaling, MPS/LP I/O, result types

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** Cycle A, finder F1 (core). The most important claims held under independent oracles: DSL semantics, compile, the Solution API, presolve/postsolve with scaling across 18 engine configurations on 600 random LPs and 13 netlib instances (KKT checked on the original problem), integer presolve by enumeration, MPS/LP section and bound semantics, round trips, and 56,000 fuzzed files with no trap or hang. Ten findings. The most severe (A1-01, high, critical-class consequence): both readers accept non-finite or overflowing numbers (1e400, inf, nan) on the wrong side, and the engines then answer .optimal with x=-inf, .optimal with objective NaN, a false .unbounded or a false .infeasible, against README's promise of invalidModel. Medium: Presolve.expandBasis can return a dual-infeasible basis that disagrees with the returned duals (about 4% of random LPs; tests check only structure); maxViolation(at:) passes NaN points; an infeasible one-variable constraint throws invalidModel instead of returning .infeasible. Low: double-counted duals of duplicate lowered constraints, range rows not bit-exact in the MPS round trip, an empty name breaking the MPS export, undocumented LP column dropping and renumbering, objectiveValue on .unbounded, duplicate LP row labels.

Claims and properties that held: 16.

Not checked:

- Time/Space bounds of the README API tables (complexity claims)
- Fixed-format MPS beyond the fuzz corpus (names with spaces, column positions); MPSFormat.read(contentsOf:) Latin-1 fallback and file-error passthrough
- SolverEvent ordering and frequency, EventSink, makeEventStream's 256-event buffer (Strategy.swift)
- Tolerances.consistent (simplex scope) and the effect of non-default tolerances on presolve
- Presolve on models larger than netlib degen2 (444 x 534); presolve's 10-pass limit only through existing tests
- README example numbers (ReadmeExampleTests passed in the baseline; not re-run) and golden files facility-location.{lp,mps} (not re-derived)
- No targeted existing tests re-run: the baseline debug suite passed and all checks here were independent probes

Further notes (not verified):

- info: MPS reader accepts a file with no ENDATA that is cut after its first COLUMNS line, silently returning a smaller model (F1 mps)
- info: an MPS RANGES section placed before RHS is wiped when the RHS header resets the range array (row read as \[-inf,5] instead of \[3,5]) (F1 mps)
- info: 'UI BND x -3' with no lower bound throws inconsistent bounds; the negative-upper-means-lower-minus-infinity convention is applied to UP only (F1 mps)
- info: LP reader stores '2 &lt;= x - y' as -x + y &lt;= -2, so the row dual sign is relative to the flipped orientation (F1 lp)
- info: the presolve '.solved' path returns a basis that is optimal but not the basis of the returned degenerate duals in \~5% of random seeds (part of A1-02)

**Cycle B (oracles first).** Built independent oracles: KKT on the original model, Farkas and ray validity, brute-force IP enumeration, finite-difference duals, structural compile checks, name-based round trips and seeded fuzzing of both readers. Ran them over thousands of seeds and 11 LP plus 7 IP engine configurations. The core contract held on ordinary data: KKT-valid optima, valid infeasibility and unboundedness certificates, presolve and scaling on vs off agreeing on the random families, correct DSL folding, MPS and LP semantics, basis consistency, and no reader traps across 60000 fuzz cases. Three critical wrong answers with a success status were reproduced. (1) Presolve's integer-bound rounding moves integral bounds outward once |b| >= \~1e9, so B&B and Automatic return .optimal points up to 11 units outside the bounds at 1.7e9 (timestamp-sized data). (2) The default geometric scaling hides a cost below the 1e-7 dual tolerance, so Simplex(), Simplex(.primal) and Automatic return .optimal -10 with no warning on min -x0 - x1, 1e-16 x0 + x1 &lt;= 1, whose optimum is -11; the reported reduced cost is -1 at a lower bound. (3) Crossed bounds (rl > ru from the LP reader, xl > xu in a CompiledLP) are solved to .optimal at infeasible points, even after presolve proves infeasibility. Medium issues: the readers accept NaN/inf values and structurally malformed files, contradicting the README's invalidModel claim; the LP writer's rename creates duplicate names that change the optimum on read-back; lowered-singleton duals double count; contradictory singletons throw instead of returning .infeasible. Low issues: the free-MPS 'bit-for-bit' range claim is false, and maxViolation ignores NaN. None of these is documented in README §4 or HANDBOOK Known gaps.

Claims and properties that held: 13.

Not checked:

- No existing swift test --filter runs; the test-integrity remark in B1-09 rests on reading the test code
- Fixed-format MPS data identity in a round trip (only fuzzed for traps); names with spaces in fixed format
- MPSFormat.ReadOptions.keepFreeRows round trip
- LPName sanitisation and qualifier stripping beyond the Rg collision in B1-05
- Presolve .full on MIPs and presolve on vs off for MIPs (B&B always uses .boundsOnly)
- The simplex refinement pass (SimplexEngine+Driver.swift:579-602) was not traced; B1-02 shows only that it does not repair the scaled-tolerance answer
- Models larger than about 10x10 in the random oracles; netlib/MIPLIB corpus not re-run
- Metal paths, timing and performance claims, and thread-sanitizer runs (outside this area)

Further notes (not verified):

- LPFormat.read doc comment (LPFormat.swift:209-210) says SOS sets and semi-continuous variables throw SolverError.unsupported; an LP file with an SOS or Semi-continuous section throws invalidModel('line 5: a constraint has no relational operator') (F1 malformed)
- InteriorPoint (default scaling) returns .infeasibleOrUnbounded for the feasible, bounded one-row LP of B1-02 once the spread is >= 1e24, and InteriorPoint with every scaling mode does the same on scalext seed 6 (IPM area; not minimized)
- Simplex(scaling: .none) returned .optimal with x\[2] = -1.57e19 below xl = 0 on scalext seed 8 (coefficient spread \~1e240; pathological data, engine numerics)
- scalext seed 3: default Simplex .optimal -5.6 (with an ill-conditioning warning, estimate 1e241) while scaling .none and .equilibration reach a feasible -6.4 before a limit
- DSL: setting .continuous after .binary gives bounds \[0, inf], not the LP relaxation \[0, 1] (max x gives 12 instead of 1); may be intended, not checked against the docs (F1 dsl2)
- Presolve's crossed-bound noise tolerance is applied in column space: with coefficients about 2e11 (lpdiff seed 513) a row violation of 1.71 was accepted and engines disagreed (unbounded vs infeasible)
- MPS reader accepts non-contiguous duplicate column names by merging them (lenient, F1 malformed)

</details>

#### <a id="b1-01"></a>B1-01 · Presolve integer-bound rounding moves integral bounds outward by about 1e-9\*|b| per pass once |b| >= \~1e9; BranchAndBound and Automatic return .optimal points outside the bounds

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/Model/Presolve.swift:139-150 (normalizeBounds, :142 rounded(.up) and :146 rounded(.down)), :166 (pass loop re-applies it); Sources/ZTronLPBranchAndBound/BranchAndBound.swift:199-202 (pre.reduced adopted as the problem)
- **Claim tested:** README §2.2 Presolve row and §4 Presolve: presolve 'rounds integer bounds'; the Presolve.swift rule comment says it rounds fractional bounds inward; Status.swift:5 says .optimal means an optimal solution was found and proven.
- **Observed:** Integer x in \[1.7e9, 1.7e9+100], minimize x: BranchAndBound() and Automatic() return .optimal with x = 1699999989, and CompiledLP.maxViolation at that point gives bounds = 11.0. A DSL model (start integer >= 1\_700\_000\_000, finish >= start + 3600, minimize finish) returns optimal start = 1699999989, finish = 1700003589. The drift is 22 at 2e9, 110 at 1e10 and 10999.5 at 1e12+0.5, and the maximize side drifts upward the same way. Presolve.run(mode: .boundsOnly) on its own maps xl = 1e9+0.5 to 999999990. CP-SAT returns the correct point.
- **Why it is wrong:** normalizeBounds computes ceil(xl - 1e-9\*max(1,|xl|)). When |xl| >= 1e9 the slack is at least one unit, so an integral bound drops by one or more units and sets `changed`. The pass loop then applies the rule again for up to 10 passes plus a final normalize, giving 11 outward steps. Rounding integer bounds may only tighten them. B&B solves pre.reduced and never checks the incumbent against the original bounds, so the status is .optimal at an infeasible point. Unix timestamps hit this.
- **Documented:** Not documented. README §3 risk 10 covers only the MIP gap on the objective, README §4 Presolve lists integer bound rounding with no magnitude limit, and HANDBOOK Known gaps lists only CP-SAT items.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F1 bigint2 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F1 bigint
```

<details><summary>Probe output</summary>

```text
'integral bounds min x, x>=X X=1700000000.0: bnb=optimal x=1699999989.0 (violation 11.0) auto=optimal x=1699999989.0'; 'status=optimal start=1699999989.0 finish=1700003589.0 (expected start=1700000000, finish=1700003600)', 'maxViolation ... bounds=11.0'; 'Presolve.run boundsOnly M=1000000000.0: xl 1000000000.5 -> 999999990.0'
```

</details>

#### <a id="b1-02"></a>B1-02 · Geometric scaling, the default, makes Simplex(), Simplex(.primal) and Automatic() return .optimal at a non-optimal vertex with no warning when one row mixes coefficients >= 1e16 apart

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/Model/Scaling.swift:42-113 (geometric and equilibration factors from |a\_ij| only, no limit on the column-factor spread); Sources/ZTronLPSimplex/SimplexEngine+Driver.swift:511 (dual infeasibility against tol.dualFeasibility on scaled data) and :579-602 (refinement pass, not traced); Sources/ZTronLPSimplex/SimplexEngine.swift:760-772 (values unscaled with no unscaled optimality check); Sources/ZTronLPSimplex/Simplex.swift:197
- **Claim tested:** README §4 Results: 'Optimal' means 'feasible and dual feasible to 1e-7 (and, after the simplex's refinement pass, to about 1e-10 ...)'. The README SolutionAnalysis row (line 264) says values are unscaled. The Simplex row (line 308) says it 'warns when the optimal basis is ill-conditioned or was optimal only within the tolerances'. Status.swift:5 says .optimal is found and proven. The contract requires scaling on and off to agree.
- **Observed:** LP: min -x0 - x1 subject to 1e-16\*x0 + x1 &lt;= 1, 0 &lt;= x &lt;= 10. Simplex() (dual, geometric scaling, presolve on), Simplex(.primal) and Automatic() return .optimal with obj = -10.0, x = \[10.0, 0.0], y = \[0.0], reducedCosts = \[-1.0, -1.0, 0.0] and warnings = \[]. The point (10, 0.5) has maxViolation (0, 0) and objective -10.5. The optimum is -11, which Simplex(scaling: .none) and .equilibration return. The same happens for every spread from 1e-16 to 1e-60, while 1e-4 to 1e-14 are correct. At 1e-20 the column factors are \[8.6e9, 1.16e-10], so x1's scaled cost is -1.16e-10, below the 1e-7 dual tolerance. On a random 4x4 LP (scalext seed 6, coefficients 1e-93..1e138) the default returns -95.4 and primal returns -65.4, both .optimal with no warnings, while x = \[10, 10, 3, 10] is feasible (maxViolation (0, 0)) at -96.0 and equilibration finds -96.6. A single row of it is enough to reproduce.
- **Why it is wrong:** In the model's own units the returned vertex has reduced cost -1 for x1 at its lower bound in a minimization. That is dual infeasible by 1.0, not 1e-7. The package's own unscaled reduced costs show this, yet the status is .optimal and nothing is warned. The scale factors come from |a\_ij| alone, with costs ignored, and the optimality test runs on scaled reduced costs with an absolute tolerance. Nothing re-checks dual feasibility after unscaling.
- **Documented:** Not documented. README §3 risk 1 says wrong answers are possible on untested models but that an ill-conditioned optimal basis is reported; here warnings = \[]. README §4 Results claims dual feasibility to 1e-7 and does not say it is measured in the scaled problem.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 200 .build/debug/F1 scalmin && perl -e 'alarm shift; exec @ARGV' 60 .build/debug/F1 scalmin1 20 && perl -e 'alarm shift; exec @ARGV' 280 .build/debug/F1 scalcase 6 10,10,3,10
```

<details><summary>Probe output</summary>

```text
'k=16 truth=-10.999999999999998: dual=optimal -10.0 WRONG x=[10.0, 0.0] w=0 dual-noscale=optimal -10.999999999999998 dual-equil=optimal -10.999999999999998 primal=optimal -10.0 WRONG x=[10.0, 0.0] w=0 ipm=optimal -10.999999999999998 auto=optimal -10.0 WRONG x=[10.0, 0.0] w=0'; 'k=20 factors rows=[8589934592.0] columns=[8589934592.0, 1.1641532182693481e-10]; scaled c=[-8589934592.0, -1.1641532182693481e-10]'; '  dual: optimal obj=-10.0 x=[10.0, 0.0] y=[0.0] d=[-1.0, -1.0, 0.0] warnings=[]'; '  point [10.0, 0.5]: objective -10.5 maxViolation (bounds: 0.0, rows: 0.0)'; seed 6: '  dual: optimal obj=-95.4 x=[10.0, 10.0, 2.7, 10.0] ... warnings=0', '  primal: optimal obj=-65.4 x=[10.0, 0.0, 2.7, 10.0] ... warnings=0', '  probe x=[10.0, 10.0, 3.0, 10.0]: objective=-96.0 maxViolation=(bounds: 0.0, rows: 0.0)', '  rows [1]: default(geom)=-65.4 equil=-96.6 none=-96.6'
```

</details>

#### <a id="b1-03"></a>B1-03 · Crossed bounds (rl > ru from the LP reader, xl > xu in a CompiledLP) are solved to .optimal at infeasible points, even after presolve has proven infeasibility

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-01](#a2-01) (cycle A)
- **Location:** Sources/ZTronLPCore/IO/LPFormat.swift:462-463 (rowLower/rowUpper appended with no lo &lt;= hi check, unlike columns at :658); Sources/ZTronLPCore/Model/CompiledLP.swift:130-131 (init validates only array sizes); Sources/ZTronLPSimplex/Simplex.swift:155-161 (presolve-infeasible fallback trusts the engine)
- **Claim tested:** Status.swift:5 says .optimal means an optimal solution was found and proven. Presolve outcome .infeasible means the model has no feasible point (Presolve.swift:25). README §2.2 says a malformed LP file throws SolverError.invalidModel. compile() rejects the same data as inconsistentRowBounds or inconsistentVariableBounds.
- **Observed:** LPFormat.read of 'Minimize / obj: x / Subject To / c1: 5 &lt;= x + y &lt;= 3 / End' is accepted with rl = \[5], ru = \[3]. Automatic returns optimal x = \[0, 5] with maxViolation rows = 2.0. Simplex(.dual) with and without presolve or scaling returns optimal x = \[0, 5]. Simplex(.primal) returns optimal x = \[0, 3]. BranchAndBound with integer x, y in \[0, 10] returns optimal x = \[5, 0]. 3.001 &lt;= x+y &lt;= 3 returns optimal with violation 1e-3. A hand-built CompiledLP with xl = 5 > xu = 3 on a column of the row x+y >= 1: Presolve.run finds it infeasible, Simplex warns and re-solves without presolve, and returns optimal x = \[5, 0], obj = 5, bound violation 2.0. InteriorPoint answers infeasibleOrUnbounded or infeasible, and CPSAT answers infeasible.
- **Why it is wrong:** No real point satisfies rl > ru or xl > xu, so the right result is .infeasible, or a reader error as compile() gives. Simplex.solve leaves the unpresolved engine to settle the status, and that engine treats crossed bounds as satisfiable.
- **Documented:** Not documented. README §4 Misuse says only inconsistent dimensions trap and says nothing about crossed bounds in a CompiledLP or an LP file; HANDBOOK Known gaps lists only CP-SAT items.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F1 crossed
```

<details><summary>Probe output</summary>

```text
'LP [crossed double-sided row]: ACCEPTED m=1 n=2 rl=[5.0] ru=[3.0]'; 'dual: optimal obj=0.0 x=[0.0, 5.0] maxViolation=(bounds: 0.0, rows: 2.0)'; hand-built xl>xu: 'dual: optimal obj=5.0 x=[5.0, 0.0] maxViolation=(bounds: 2.0, rows: 0.0)'
```

</details>

#### <a id="a1-01"></a>A1-01 · MPS and LP readers accept non-finite and out-of-range numbers; the engines then return success statuses with wrong answers

- **Severity:** high (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-04](#b1-04) (cycle B)
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:286 (RHS/RANGES values stored unchecked), :327-328 (bound values: only NaN rejected, ±inf accepted on either side), :403-415 (only xl > xu checked, no row sanity); Sources/ZTronLPCore/IO/LPFormat.swift:335 (Double(...) overflow to inf accepted), :462-465, :655-660
- **Claim tested:** README §2.2 (MPSFormat, LPFormat): a malformed file throws SolverError.invalidModel. README risk 12: malformed inputs yield SolverError.invalidModel. MPSFormat.swift:9-13: values of magnitude 1e20 or more are mapped to ±inf only on the side where an infinite bound makes sense, because read as finite numbers they would poison ratio tests. ModelDiagnostic.nonFiniteValue: NaN, or infinite on the wrong side (compile() enforces this; the readers do not).
- **Observed:** MPS: 'UP BND x -1e400' (or '-inf') with row e: x = 0 is read with xl = xu = -inf. Simplex and InteriorPoint both return .optimal with objective -inf at x = \[-inf]. 'LO BND x 1e400' gives .optimal with objective +inf at x = \[inf]. 'RHS r 1e400' on a G row (min x s.t. x >= 1e400) gives .unbounded. 'RHS COST nan' gives .optimal with objective NaN. 'RHS r nan' gives .optimal. LP: 'x >= 1e400' in Bounds gives .optimal with objective inf. 'r: x >= 1e400' gives .unbounded. 'obj: x + 1e400 y' is read as cost +inf and Simplex returns .optimal with objective NaN. 'r: 1e400 x + y >= 1' makes Simplex return .infeasible, although y = 1 is feasible. Across 28,000 mutated inputs per format, the fuzzer had both readers accept models with row or column bounds of \[inf,inf] or \[-inf,-inf], c0 = NaN or inf, or non-finite coefficients.
- **Why it is wrong:** These files should be rejected with invalidModel, as compile() rejects the same values. Instead the solvers return .optimal at a point that violates a row (x = -inf against x = 0), .unbounded for a model bounded below by 1e400, and .infeasible for a feasible model. By consequence this is the critical class (wrong answer with a success status). It is rated high because it takes non-finite or overflowing literals, which only corrupt or untrusted files contain.
- **Documented:** Not documented. Risk 12 admits there was no fuzzing and predicts traps, not silent acceptance. The MPSFormat doc comment claims that wrong-side huge values stay finite. No test in MPSFormatTests or LPFormatTests feeds NaN, inf or overflowing literals.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && for f in up-minus-1e400 lo-1e400 rhs-1e400-G objrhs-nan rhs-nan; do perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 file mps Slots/F1/inputs/$f.mps; done; for f in lp-lo-1e400 lp-rhs-1e400 lp-coef-1e400 lp-rowcoef-1e400; do perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 file lp Slots/F1/inputs/$f.lp; done; perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 mps
```

<details><summary>Probe output</summary>

```text
up-minus-1e400.mps: read xl=[-inf] xu=[-inf] rl=[0] ru=[0]; Simplex: optimal obj=-inf x=[-inf]; IPM: optimal obj=-inf. rhs-1e400-G.mps: rl=[inf]; Simplex: unbounded; IPM: unbounded. objrhs-nan.mps: c0=nan; Simplex: optimal obj=-nan. lp-rowcoef-1e400.lp: Simplex: infeasible. lp-coef-1e400.lp: c=[1, inf]; Simplex optimal obj=nan.
```

</details>

#### <a id="a1-02"></a>A1-02 · Presolve.expandBasis returns an optimal-status basis that is dual infeasible and disagrees with the returned duals

- **Severity:** medium (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A3-07](#a3-07) (cycle A), [B3-05](#b3-05) (cycle B)
- **Location:** Sources/ZTronLPCore/Model/Presolve.swift:438-445 (current == .fixed claims the row whichever side the reduced cost points to), compare :401
- **Claim tested:** README §2.2: postsolve maps 'a solution, a ray or a basis between the reduced and the original problem' (expandBasis). SimplexAnalysis.basis is 'Reusable as WarmStart.basis'. The basis that comes with an .optimal result should be an optimal basis of the original LP and should match the returned duals.
- **Observed:** Minimal case: min x s.t. -4x >= 4, x in \[-1,1]. With Simplex(.dual) and presolve on, the basis is {x basic, row logical atLower}. The basis's own duals are y = -0.25, so the logical at its lower bound has d = -0.25 and the basis is dual infeasible. The reported duals are y = \[0] with d\_x = 1 while x is basic. A warm start from this basis takes 1 pivot; the presolve-off basis takes 0. On random LPs: 24 of 540 seeds gave a dual-infeasible basis and 45 of 540 a basis that disagrees with the reported duals. All of them had presolve on, under every engine and scaling. x, y and d themselves always passed KKT.
- **Why it is wrong:** Take a column fixed by presolve whose reduced cost points at its own original bound. expandDual (sign test, :401) correctly gives the singleton row a zero dual. expandBasis instead treats any .fixed column as resting on the bound the row created, makes it basic and puts the row's logical at a bound. The resulting basis is not optimal and does not match the reported (x, y). Warm starts and the conditioning analysis of the 'optimal basis' (InteriorPoint.finalBasis and Conditioned use the same postsolve) work from the wrong basis.
- **Documented:** Not documented. PresolveTests.aBasisIsMappedBothWays and postsolveInvariantsHoldOnRandomProblems check only structure (m basics, the round trip through reduceBasis), never optimality or agreement with the duals, so they cannot catch this.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 basisrepro ; perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 presolve 60 600 | grep -B1 'dual-infeasible: \["'
```

<details><summary>Probe output</summary>

```text
presolve=true: optimal obj=-1.0 x=[-1.0] y=[0.0] d=[1.0, 0.0]; basis status=[basic, atLower]; basis's own duals [-0.25] dual-infeasible [k=1 atLower d=-0.25]; warm start from it: optimal iterations 1. presolve=false: basis [atLower, basic], dual feasible, warm start 0 iterations.
```

</details>

#### <a id="a1-03"></a>A1-03 · CompiledLP.maxViolation(at:) reports zero violation for a point that contains NaN

- **Severity:** medium (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-10](#b1-10) (cycle B)
- **Location:** Sources/ZTronLPCore/Model/CompiledLP.swift:187 and :192
- **Claim tested:** README risk 1 offers CompiledLP.maxViolation(at:) as the independent check of a point. Its doc comment: 'The largest violation of a column bound and of a row bound at x, both >= 0.'
- **Observed:** Bounds \[0,1]^2, row 1 &lt;= x0 + x1 &lt;= 2, x = \[NaN, 0.5]: maxViolation returns (bounds: 0.0, rows: 0.0).
- **Why it is wrong:** Every comparison with NaN is false, so Swift.max keeps its earlier argument and the NaN coordinate and NaN row activity vanish. The check that the README recommends for validating a point accepts a meaningless one.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 dsl   (line 'maxViolation flags a NaN point')
```

<details><summary>Probe output</summary>

```text
FAIL | maxViolation flags a NaN point | (bounds: 0.0, rows: 0.0)
```

</details>

#### <a id="a1-04"></a>A1-04 · An infeasible or tolerance-level conflicting one-variable constraint makes compile and solve throw invalidModel instead of returning .infeasible

- **Severity:** medium (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-08](#b1-08) (cycle B)
- **Location:** Sources/ZTronLPCore/Model/Compile.swift:209-227 (singletons tighten bounds, then guard xl\[j] &lt;= xu\[j] throws with no tolerance)
- **Claim tested:** README §2.1 presents CompileOptions.lowerSingletonConstraints ('a one-variable constraint becomes a bound; on by default') as a choice of representation. SolveStatus.infeasible: 'The model has no feasible point.'
- **Observed:** minimize x + y s.t. x &lt;= -1 (x >= 0 from its domain), x + y >= 0: Simplex().solve(model) throws 'invalid model: variable x has lower bound 0.0 above upper bound -1.0'. With lowerSingletonConstraints = false the same model returns .infeasible. 'x >= 1 + 1e-12' together with 'x &lt;= 1' also throws, although presolve would treat a 1e-12 crossing as a fixed column.
- **Why it is wrong:** An infeasible LP is not an invalid model, and the outcome flips with an option documented as representational. The diagnostic blames bounds the user never wrote. Bounds that cross by rounding noise are a hard error, with no tolerance applied.
- **Documented:** Partly. The compile() doc lists 'lower > upper on a variable' among the errors it throws. Neither README nor HANDBOOK says that an infeasible one-variable constraint becomes an error rather than an .infeasible status.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 dsl   (INFO lines 'infeasible singleton')
```

<details><summary>Probe output</summary>

```text
INFO | infeasible singleton x <= -1 (x>=0): solve threw invalid model: variable x has lower bound 0.0 above upper bound -1.0 / same model with lowerSingletonConstraints=false: status infeasible / singleton x>=1+1e-12 and x<=1: solve threw invalid model
```

</details>

#### <a id="b1-04"></a>B1-04 · MPS and LP readers accept NaN and infinities where no LP can have them; every engine then reports .optimal with a NaN or infinite objective, x = +-inf, or a row silently ignored

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-01](#a1-01) (cycle A)
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:275-290 (RHS/RANGES: no NaN/inf checks), :263-268 (summed duplicates not re-checked), :327-328 (bounds: NaN checked, +inf lower / -inf upper not); Sources/ZTronLPCore/IO/LPFormat.swift:335 and :348 (numbers and the 'inf' token used as coefficients), :404 (addConstraint), :469 (addBound), :574 (finishObjective): no finiteness checks
- **Claim tested:** README §2.2 MPSFormat and LPFormat rows: 'A malformed file throws SolverError.invalidModel'. README §3 risk 12 says malformed inputs yield SolverError.invalidModel. compile() rejects the same values as nonFiniteCoefficient or nonFiniteValue.
- **Observed:** MPS cases accepted and then solved: 'RHS c1 nan' gives ru = \[nan], and all engines return optimal with the row ignored; 'RANGES c1 nan' gives rl = \[nan]; 'RHS obj nan' gives c0 = nan and optimal obj = nan; 'RHS obj inf' gives c0 = -inf and optimal obj = -inf; 'LO/FX x inf' gives xl = +inf and optimal x = \[inf]; 'UP/FX x -inf' gives optimal x = \[-inf]; duplicate COLUMNS entries 1e308+1e308 give an inf coefficient or cost and optimal obj = nan; 'RHS inf' on an E or G row gives rl = +inf and .unbounded. LP cases: 'inf x' and '1e999 x' give an inf coefficient; 'obj: inf x' gives optimal obj = nan; 'x + inf &lt;= inf' gives ru = nan and optimal with the row ignored; 'x >= inf' gives optimal x = inf; 'x + y = inf' gives numericalFailure from dual and 'unbounded obj=inf' from primal. Fuzzing accepted 191 LP and 8 MPS models with invalid data. None trapped.
- **Why it is wrong:** These files are malformed, since no finite LP has these values. The MPS reader checks NaN only in BOUNDS and finiteness only per COLUMNS entry, not on the summed value. Nothing checks RHS, RANGES or the objective RHS, and the LP reader checks no value at all. Downstream, .optimal comes back with NaN or inf values, and maxViolation reports 0 (see B1-10).
- **Documented:** Not documented. README §2.2 and §3 risk 12 state the opposite. Risk 12 admits the readers were not fuzzed but still says malformed inputs yield invalidModel.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F1 malformed ; fuzz: perl -e 'alarm shift; exec @ARGV' 600 .build/debug/F1 fuzz lp 8000 12000 1
```

<details><summary>Probe output</summary>

```text
'MPS [RHS nan]: ACCEPTED m=1 n=1 rl=[-inf] ru=[nan] ... INVALID: NaN bound on row 0'; 'MPS [RHS nan on objective row]: ACCEPTED ... c0=nan' then 'dual: optimal obj=nan x=[0.0] maxViolation=(bounds: 0.0, rows: 0.0)'; 'MPS [UP -inf]: ACCEPTED ... xl=[-inf] xu=[-inf]' then 'dual: optimal obj=-inf x=[-inf]'; 'MPS [LO inf]: ACCEPTED ... xl=[inf] xu=[inf]' then 'dual: optimal obj=inf x=[inf] maxViolation=(bounds: 0.0, rows: inf)'; 'MPS [RHS inf on E row]: ACCEPTED ... rl=[inf] ru=[inf]' then 'dual: unbounded obj=nan'
```

</details>

#### <a id="b1-05"></a>B1-05 · LP writer name-collision handling produces duplicate row and range-column names, so the file read back is a different LP (optimum 4 becomes 6)

- **Severity:** medium (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-10](#a1-10) (cycle A)
- **Location:** Sources/ZTronLPCore/IO/LPFormat.swift:24 (rowNames\[i] += "\_" without re-uniquing), :55 (range column named from the renamed row)
- **Claim tested:** LPFormat.swift:22-24 says the writer keeps row names apart from the generated range columns. README §4 File formats: 'A range row is written to LP format as an equality against an extra Rg… column', which implies writing a range row preserves the model.
- **Observed:** A CompiledLP with columns x, y, Rga, range row 'a' (1 &lt;= x &lt;= 2), range row 'a\_' (3 &lt;= y &lt;= 4), and objective x + y + Rga. The writer emits both rows as 'a\_' and both range columns as 'Rga\_', with two bound lines '1.0 &lt;= Rga\_ &lt;= 2.0' and '3.0 &lt;= Rga\_ &lt;= 4.0'. Reading back gives columns \['x', 'y', 'Rga', 'Rga\_'] and rows \['a\_', 'a\_']: one shared range column, so x = y. The original optimum is 4.0 and the read-back optimum is 6.0.
- **Why it is wrong:** The collision fix appends '\_' to a row name whose 'Rg' + name is a column, without checking that the new name is free among rows or that 'Rg' + new name is free among columns. The file silently describes another model.
- **Documented:** Not documented. README §4 File formats describes the Rg column but not this collision.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 60 .build/debug/F1 lpnames
```

<details><summary>Probe output</summary>

```text
' a_: x - Rga_ = 0', ' a_: y - Rga_ = 0', ' 1.0 <= Rga_ <= 2.0', ' 3.0 <= Rga_ <= 4.0'; 'read back: n=4 columns=[x, y, Rga, Rga_] rows=[a_, a_]'; 'optimum original optimal 4.0 vs read back optimal 6.0'
```

</details>

#### <a id="b1-06"></a>B1-06 · Readers silently accept structurally malformed files: RANGES before RHS drops the ranges, MPS without ENDATA or truncated mid-COLUMNS loads as a smaller model, and a second LP objective is summed into the first

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:160-163 (the RHS header re-creates the rhs and range arrays, discarding earlier RANGES), :170 (ENDATA optional, end of input accepted in any section); Sources/ZTronLPCore/IO/LPFormat.swift:276 (the 'end' keyword optional; no check for duplicate row names or a second objective section)
- **Claim tested:** README §2.2 MPSFormat row: 'A malformed file throws SolverError.invalidModel (.syntax, ...)'. The LPFormat row and README §3 risk 12 make the same claim.
- **Observed:** MPS: with RANGES before RHS the file is accepted with row \[-inf, 5] instead of \[3, 5], so the range is silently lost. A file with no ENDATA and no BOUNDS, and a file truncated in the middle of COLUMNS, are both accepted as smaller models. A BOUNDS line with 6 fields is accepted. A duplicate RHS entry is accepted with the last value winning. LP: a file with no End is accepted. Two objective sections are accepted, with both cost vectors summed under the last sense (c = \[-1, -1]). Duplicate row names, a bound before Subject To, and extra tokens in a bound line are all accepted.
- **Why it is wrong:** These are malformed, or at best ambiguous, files. Accepting them changes the model without notice. In the RANGES-before-RHS case a well-formed range is discarded, so the solved LP differs from the file author's.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/F1 malformed
```

<details><summary>Probe output</summary>

```text
'MPS [RANGES before RHS]: ACCEPTED m=1 n=1 rl=[-inf] ru=[5.0] ... c=[-1.0]'; 'MPS [truncated mid COLUMNS]: ACCEPTED m=2 n=1'; 'MPS [truncated: no ENDATA, no BOUNDS]: ACCEPTED'; 'MPS [duplicate RHS entry]: ACCEPTED ... ru=[7.0]'; 'LP [two objectives]: ACCEPTED m=1 n=2 ... c=[-1.0, -1.0]'; 'LP [no End]: ACCEPTED'; 'LP [duplicate row names]: ACCEPTED m=2'
```

</details>

#### <a id="b1-07"></a>B1-07 · Solution.dual(ofConstraintNamed:) gives each lowered singleton constraint the whole reduced cost when several imply the same active bound, so the reported duals are not a dual solution

- **Severity:** medium (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-05](#a1-05) (cycle A)
- **Location:** Sources/ZTronLPCore/Solve/Analysis.swift:178-183
- **Claim tested:** Analysis.swift:158-160 says a lowered constraint 'receives the reduced cost when the bound it implies is the active one'. The contract requires duals and reduced costs to be those of the original model, satisfying stationarity c - A^T y = d.
- **Observed:** Model: x >= 2 (named a), 2x >= 4 (named b), minimize x. The reported duals are dual(a) = 1.0 and dual(b) = 0.5. x = 2 lies strictly inside its own domain \[0, inf), so stationarity requires 1\*y\_a + 2\*y\_b = 1, but the reported values give 2.0. Moving both implied bounds by t changes the optimum by t, while the duals predict 2t.
- **Why it is wrong:** When k lowered constraints imply the same active bound, each gets the full d/a, so the bound's multiplier is counted k times. At CompiledLP level, Presolve.expandDual handles duplicate singleton rows correctly (held in the lpdiff and dualfd checks), but the DSL path does not.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F1 dsl2
```

<details><summary>Probe output</summary>

```text
'x>=2 (a) and 2x>=4 (b), min x: dual a=1.0 b=0.5; d/dt of optimum when both move the bound by t is 1, duals predict 2.0'
```

</details>

#### <a id="b1-08"></a>B1-08 · Contradictory one-variable constraints make compile() throw invalidModel instead of the model solving to .infeasible; the outcome depends on lowerSingletonConstraints

- **Severity:** medium (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-04](#a1-04) (cycle A)
- **Location:** Sources/ZTronLPCore/Model/Compile.swift:140-147 (singletons lowered) and :210-229 (implied bounds intersected, then inconsistentVariableBounds or nonIntegralFixedBound thrown)
- **Claim tested:** README line 216 describes CompileOptions.lowerSingletonConstraints as a lowering ('a one-variable constraint becomes a bound; on by default'), which should not change the answer. An infeasible model should report .infeasible (Status.swift).
- **Observed:** x >= 3 and x &lt;= 2 as two one-variable constraints: compile throws 'invalid model: variable v\[1] has lower bound 3.0 above upper bound 2.0'. The same model with lowerSingletonConstraints = false gives .infeasible, and x+y >= 3, x+y &lt;= 2 gives .infeasible. An integer constraint 2i == 3 throws 'integer variable i\[0] is fixed at the non-integral value 1.5' instead of .infeasible.
- **Why it is wrong:** Lowering merges constraint-implied bounds into the column bounds and then applies the declared-bounds validity check to them. A modelling infeasibility becomes a thrown model error, so a caller handling .infeasible never sees it.
- **Documented:** Partly. The compile() doc comment (Compile.swift:31-34) lists 'lower > upper on a variable' and 'a non-integral fixed bound' as throws, without saying that lowered constraints count. Nothing in README §4 or HANDBOOK.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F1 dsl2
```

<details><summary>Probe output</summary>

```text
'x>=3, x<=2 (two one-variable constraints) -> throws invalid model: variable v[1] has lower bound 3.0 above upper bound 2.0'; 'x+y>=3, x+y<=2 -> infeasible'; 'x>=3, x<=2 with lowerSingletonConstraints=false -> infeasible'; 'integer 2i == 3 (a constraint) -> throws invalid model: integer variable i[0] is fixed at the non-integral value 1.5'
```

</details>

#### <a id="a1-05"></a>A1-05 · Solution.dual(ofConstraintNamed:) double counts when two named one-variable constraints imply the same bound

- **Severity:** low (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-07](#b1-07) (cycle B)
- **Location:** Sources/ZTronLPCore/Solve/Analysis.swift:173-185
- **Claim tested:** Analysis.swift:155-160: a lowered constraint 'receives the reduced cost when the bound it implies is the active one'. The presolve's own postsolve handles the same situation ('the last and tightest claims the reduced cost and the others see none left').
- **Observed:** min x + y s.t. a: x >= 2, b: 2x >= 4, c: x + y >= 1 gives ya = 1, yb = 0.5, yc = 0, so ya + 2\*yb = 2 != c\_x = 1. Kept as rows, the same model gives duals \[1, 0, 0].
- **Why it is wrong:** Each lowered constraint independently claims the whole reduced cost, so the reported duals are not a valid dual solution (the stationarity residual is -1).
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 misc
```

<details><summary>Probe output</summary>

```text
FAIL | ... | ya=1.0 yb=0.5 yc=0.0: c_x - (ya + 2yb + yc) = -1.0; INFO | same model as rows: duals [1.0, 0.0, 0.0]
```

</details>

#### <a id="a1-06"></a>A1-06 · The free-format MPS round trip is not bit-exact for range rows

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-09](#b1-09) (cycle B)
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:526 (fallback '?? (hi - lo)')
- **Claim tested:** MPSFormat.swift:3-5: the writer emits shortest round-trip numbers 'so read(write(lp)) == lp'. Test name: rangeRowsReadBackBitForBit.
- **Observed:** 15 of 400 random models read back different, only in range-row bounds, by at most 2.2e-16 relative to the larger end. Examples: rl -388213.4614957075 -> -388213.4614957074; -5.323138532990446e-11 -> -5.3231197227887606e-11; -2.0 -> -1.9999999999999996. Every other field, including adversarial names, survives exactly.
- **Why it is wrong:** When the 8-ulp search for an exact R fails, the writer falls back to R = hi - lo, and lo is then not reproduced. The equality claim is false, although the numerical effect is about one ulp of the larger bound.
- **Documented:** Not documented. The writer doc claims an exact round trip.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 roundtrip 0 400 | grep MPSDIFF
```

<details><summary>Probe output</summary>

```text
round trip seeds 0..<400: MPS exact failures 15 ... MPSDIFF seed 4 onlyRangeRows=true maxErrRelToLargerEnd=1.52e-16
```

</details>

#### <a id="a1-07"></a>A1-07 · The MPS writer produces a file its own reader rejects when a constraint is named ""

- **Severity:** low (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:447-452
- **Claim tested:** MPSFormat.write doc: free format 'keeps every name ... so the output round-trips'. The DSL accepts .named("").
- **Observed:** LPModel.minimizing(x + y).subjectTo { (x + y >= 1).named("") }.mpsString() writes ' G ' in ROWS and '    x  1.0' in COLUMNS. MPSFormat.read then fails with 'line 4: a ROWS line needs a type and a name'. The LP export of the same model reads back.
- **Why it is wrong:** The writer's 'usable' check rejects the empty name, but the replacement it substitutes is still empty.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 emptyname
```

<details><summary>Probe output</summary>

```text
FAIL | MPS export of a constraint named "" reads back | invalid model: line 4: a ROWS line needs a type and a name
```

</details>

#### <a id="a1-08"></a>A1-08 · LP export drops columns that have no cost, no row and default bounds, and renumbers columns; README describes only the Rg column

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/IO/LPFormat.swift:32 (only nonzero costs written), :66-76 (default bounds not written)
- **Claim tested:** README §4 'Not verified': LP and MPS exports round-trip through this package's own readers. README §4 'File formats' names only the Rg column as a change made by LP export.
- **Observed:** Columns \[a, b, c], where a has no cost or row, read back as \[b, c]. Columns \[a, b, c], where c has no cost or row, read back as \[b, a]. Column indices, and so positional solution vectors, do not survive.
- **Why it is wrong:** The README presents the LP round trip as structure-preserving apart from the Rg column. Only the test helper's comments acknowledge the dropped column and the renumbering.
- **Documented:** Only in the comments of Tests/ZTronLPCoreTests/LPFormatTests.swift:12-13 and :38, not in README or HANDBOOK.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 lp   (INFO lines 'LP round trip')
```

<details><summary>Probe output</summary>

```text
INFO | LP round trip (a has no cost/row): columns [a, b, c] -> [b, c]; (c has no cost/row): [a, b, c] -> [b, a]
```

</details>

#### <a id="a1-09"></a>A1-09 · .unbounded Simplex results carry an objectiveValue although hasSolution is false

- **Severity:** low (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPSimplex/Simplex.swift:259 vs Sources/ZTronLPCore/Solve/Analysis.swift:20
- **Claim tested:** SolutionAnalysis.objectiveValue: 'nil without a primal solution'. SolveStatus.hasSolution: 'True when a primal solution accompanies the status', which is false for .unbounded.
- **Observed:** min -x - y s.t. x - y &lt;= 1, x, y >= 0 gives .unbounded with hasSolution = false and objectiveValue = -1.0, with presolve on and off.
- **Why it is wrong:** The two doc comments together promise nil here. A caller that reads objectiveValue without checking the status gets the objective of an arbitrary last iterate.
- **Documented:** README risk 9 documents the last iterate in primal for unbounded results, but says nothing about objectiveValue.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 unbobj
```

<details><summary>Probe output</summary>

```text
presolve=true: unbounded hasSolution=false objectiveValue=Optional(-1.0) primal=Optional([1.0, 0.0])
```

</details>

#### <a id="a1-10"></a>A1-10 · The LP writer can emit duplicate row labels, and the LP reader accepts duplicate row names

- **Severity:** low (finder) · **Category:** other · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B1-05](#b1-05) (cycle B)
- **Location:** Sources/ZTronLPCore/IO/LPFormat.swift:24
- **Claim tested:** LPFormat.write keeps row names apart from the generated Rg columns, and names are uniqued. compile() and the MPS reader both reject duplicate row names.
- **Observed:** Rows \[a (range), a\_] with a column named Rga: row a is renamed a\_ and collides with the existing row a\_, so both are written as 'a\_:'. LPFormat.read returns rows \[a\_, a\_] without error; the optimum is preserved.
- **Why it is wrong:** The writer appends '\_' without re-checking uniqueness, and the reader does not reject duplicate labels, so a name lookup on the result is ambiguous.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F1 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 misc2
```

<details><summary>Probe output</summary>

```text
LP text: ' a_: x + Rga - Rga_ = 0' and ' a_: x + z <= 3.0'; read back: rows [a_, a_]
```

</details>

#### <a id="b1-09"></a>B1-09 · Free MPS write-then-read is not exact for range rows (49 of 3000 random models), contrary to the 'read(write(lp)) == lp' and 'bit-for-bit' claims; the round-trip tests use only representable pairs

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-06](#a1-06) (cycle A)
- **Location:** Sources/ZTronLPCore/IO/MPSFormat.swift:5 and :614-630 (exactRange and its fallback)
- **Claim tested:** MPSFormat.swift:5: 'so read(write(lp)) == lp'. MPSFormat.swift:616: 'so a range row reads back bit-for-bit'.
- **Observed:** In 49 of 3000 random models a range row such as \[-8.0, 10.050132380851457] reads back as \[-8.000000000000002, 10.050132380851457]. Searching 1e5 ulps around R with either anchor finds no value that reproduces the pair, so exactness is impossible for such pairs in the RHS+RANGES encoding. The tests rangeRowsReadBackBitForBit and randomProblemsOfEveryShapeRoundTrip use only bound pairs that are exactly representable (read in the test code), so they cannot catch this.
- **Why it is wrong:** The claim is unconditional. exactRange returns nil when no R works, as its own comment says, and the writer then writes an inexact R.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 600 .build/debug/F1 roundtrip 0 3000 && perl -e 'alarm shift; exec @ARGV' 60 .build/debug/F1 showmps 167
```

<details><summary>Probe output</summary>

```text
49/3000 MPS round-trip failures, all on range rows; e.g. '[-8.0, 10.050132380851457] -> [-8.000000000000002, 10.050132380851457]'; no R within 1e5 ulps reproduces the pair
```

</details>

#### <a id="b1-10"></a>B1-10 · CompiledLP.maxViolation(at:) ignores NaN: an all-NaN point, or NaN row bounds, report (0, 0)

- **Severity:** low (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-03](#a1-03) (cycle A)
- **Location:** Sources/ZTronLPCore/Model/CompiledLP.swift:184-194
- **Claim tested:** README §3 risk 1 says 'CompiledLP.maxViolation(at:) checks a point'. The CompiledLP.swift:183 doc says it returns the largest violation of a column bound and of a row bound at x.
- **Observed:** maxViolation(at: \[NaN, ...]) returns (bounds: 0.0, rows: 0.0). For the NaN-bound models of B1-04 it also reports rows 0.0 for the row that is ignored.
- **Why it is wrong:** A NaN coordinate or activity satisfies no bound. Swift.max with NaN keeps the accumulated value, so the checker the README recommends for validating answers reports no violation.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F1 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F1 dsl
```

<details><summary>Probe output</summary>

```text
'maxViolation at an all-NaN point = (bounds: 0.0, rows: 0.0)'
```

</details>

### <a id="f2-simplex"></a>F2 Simplex engine and numerics

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** Cycle A, F2 (Simplex engine and numerics), claims first. On well-posed inputs the claims held: about 75,000 probe solves found no error in the 52-configuration grid on KKT-constructed LPs (objective, primal feasibility, dual signs, complementary slackness, sign conventions, maximize), on Farkas and recession certificates, on netlib (worst 1.33e-11), on the README Hilbert table, warm starts, limits, degeneracy or the LAPACK/BLAS blocks. There are two critical findings. A2-01: an LP with crossed bounds (xl > xu or rl > ru, reachable through the public CompiledLP initializer and derivations, WarmStart.incremental and SimplexEngine.applyBoundChanges) is answered .optimal at a point that violates its bounds by 1.0, even after presolve has said it is infeasible. A2-02: the primal simplex calls a feasible 11x11 LP with κ₁ = 1.5e9 infeasible, with no warning and a ray that fails the Farkas check. There are two medium ones. A2-03: refine() keeps .optimal when its own re-measurement shows a violation 8e10 times the tolerance; this needs scaling .none on 10^±4 data, which also gives false .infeasible verdicts. A2-04: 'beyond κ ≈ 1e11 only the objective can be trusted' fails for non-Hilbert objectives. Three are low: a README 5 warning count, the SparseQRBasis density doc comment, and no test checking duals or crossed bounds. Probe sources are in verification/probes/cycle-A/Slots/F2, and the log is in verification/cycle-A/F2-simplex.md.

Claims and properties that held: 16.

Not checked:

- Larger LPs (above \~540 rows) in the KKT sweep; the sparse QR path above 1,500 rows was checked only for time limits.
- Event-stream claims (simplex iterations reported at most every 100) and EventSink ordering.
- Metal/kernel-seam behaviour inside the simplex (KernelSeamTests, MetalPolicy.forced).
- The perturbation clean-up limit of 500 iterations (EngineFailure path) and the fragile-pivot limit m + 50; not provoked deliberately.
- Cancellation latency inside the refinement pass (covered by RefinementTests; not re-measured).
- SimplexAnalysis.degeneracy, phase1Iterations and refactorizations counts against an independent count.
- Whether BranchAndBound or CPSAT can generate crossed BoundChanges that reach A2-01 (other areas).
- InteriorPoint's own handling of the A2-02 instance beyond its status (area of another finder).

Further notes (not verified):

- info: Simplex(.dual) on Klee-Minty starts primal feasible and hands over to the primal method, so the Pricing setting decides its iteration count (n = 20 Dantzig hits the cap); consistent with 'Pricing applies to the primal method'.
- info: from κ ≥ 1e12 the random L·D·U family also gives 87 noSolution(iterationLimit) after 50,000 pivots on n ≤ 12 (stalling, honest status).
- info: DenseLUBasis.ftran/btran silently leave the right-hand side unchanged before the first refactor or after a refactor that threw (guard let lu else return), BasisFactorization.swift:171-181.

**Cycle B (oracles first).** Over more than 650,000 probe solves the simplex was correct: planted LPs in all 432 configurations, all 13 netlib instances, the Hilbert table, the Farkas and ray certificates, limits, warm starts, degenerate assignment LPs, invariance and the numerical building blocks. The README netlib and Hilbert tables reproduce exactly. The failures all come from wide magnitude ranges combined with non-default options: two critical, one medium and one low. B2-01 (critical): with a sparse QR basis, the refinement pass's refactorization hits the QR singularity probe, the engine silently installs the all-slack basis, and returns the starting point as .optimal, infeasible by 3.4e7 and with no warning. The public SimplexEngine localizes it: the run is correct with refinement skipped. B2-02 (critical): primal phase 1 declares .infeasible without checking its own Farkas value, giving false infeasibility on feasible LPs, among them Klee-Minty order 14 where x = 0 is feasible, with rays that certify nothing (margin -inf or &lt;= 0). B2-03 (medium): the dual simplex stalls until the 50,000-pivot cap because the .onStall trigger measures primal degeneracy. B2-04 (low): the SparseQRBasis doc comment describes a density rule that does not exist. Every critical and medium case used scaling .none or .equilibration. None was seen with the defaults (dual, automatic factorization, presolve, geometric scaling).

Claims and properties that held: 16.

Not checked:

- The Metal pricing path inside the simplex (MetalPolicy.forced), and parallel pricing with the pivot row at >= 20,000 columns and 200,000 nonzeros.
- SimplexEngine+Crossover (pushDuals, face bounds) was not probed directly; it is reached only through InteriorPoint, which is outside F2.
- The README timings for the larger transport LP (2,000 x 20,000), refactorization cost and the dense-basis memory figures (8 m^2 bytes) were not re-measured.
- DenseQR, DenseCholesky and SparseSymmetricSolver. The CLAPACKShim entry points were exercised only through DenseLU and the triangular solves. The accuracy of conditionEstimate against the exact condition number was not measured; it was only seen to agree with the observed errors in the warnings.
- Whether B2-01 or B2-02 can be triggered with the default geometric scaling: not seen in 2,700 sampled seeds. No LP above 1,500 rows (where .automatic picks sparse QR) with an intrinsically ill-conditioned optimal basis was built.
- The existing package tests were not re-run.
- Cancellation in the middle of a solve, and the progress-event cadence beyond what the traces showed.

Further notes (not verified):

- info: numericalFailure('primal feasibility could not be maintained') on badly scaled LPs with scaling .none (HARD seeds 5093 P/QR and 5169 D/auto/pre=0) and on unscaled Klee-Minty orders 13-14 is an honest failure status, not verified further.
- info (code reading plus the numerics probe): when dgetrf reports info > 0, DenseLU.init lists only exactly-zero pivots (deficientPivots(relativeTolerance: 0)). A nearly singular basis can therefore be reported with fewer deficient positions than it has. The repair loop retries up to 4 times before falling back to the slack basis; this was not followed further.
- test-coverage info: RefinementTests 'aPassThatCannotFinishLeavesTheAnswerAsItWas' injects only an iteration limit. No test exercises a failed refactorization inside the pass, which is the path of B2-01.

</details>

#### <a id="a2-01"></a>A2-01 · Crossed bounds (xl > xu or rl > ru) are reported .optimal at an infeasible point, even after presolve has diagnosed infeasibility

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [B1-03](#b1-03) (cycle B)
- **Location:** Sources/ZTronLPSimplex/SimplexEngine.swift:664-677 (primalInfeasibility measures basic variables only; a nonbasic column placed at a crossed bound by placeNonbasic, SimplexEngine.swift:382-389, is never measured); Sources/ZTronLPSimplex/Simplex.swift:155-161 (presolve's .infeasible verdict is replaced by the unpresolved engine run)
- **Claim tested:** README 2.2: CompiledLP is 'min or max of cᵀx + c0 with rl ≤ Ax ≤ ru and xl ≤ x ≤ xu'; README 2.5: Simplex returns a ray when the answer is .infeasible; Simplex.swift:156-157 comment: 'The unpresolved problem gives one \[certificate], and settles the status'; README 3 Risk 1: read the status before the values.
- **Observed:** CompiledLP(a: 0x1, c: \[1], xl: \[2], xu: \[1]) -> Simplex(.dual) and Simplex(.primal), with and without presolve: status optimal, x = \[2], objective 2, maxViolation bounds 1.0, warning 'presolve found the model infeasible (column x1 has lower bound 2.0 above upper bound 1.0); solving without presolve for the certificate'. One row with rl = 3 > ru = 1 over x, y in \[0, 5]: optimal x = \[3, 0], row violation 2.0. Same through WarmStart.incremental with BoundChange(column 0, lower 2.5, upper 1.5), CompiledLP.withColumnBounds, SimplexEngine.applyBoundChanges and Automatic(). All 40 configurations of the probe grid answer optimal on four such cases. InteriorPoint answers infeasibleOrUnbounded.
- **Why it is wrong:** The problem has no feasible point; .optimal with a point that violates its bounds by 1.0 is a wrong answer with a success status. Presolve detected the infeasibility and the final status overrides it.
- **Documented:** Not documented. README 4 'Misuse of the building blocks traps' covers inconsistent dimensions only. The DSL compile and the MPS/LP readers reject crossed bounds, but CompiledLP's public initializer, withColumnBounds/withRowBounds/applying, WarmStart.incremental and SimplexEngine.applyBoundChanges accept them.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F2 crossed   (grid version: perl -e 'alarm shift; exec @ARGV' 300 .build/release/F2 edge)
```

<details><summary>Probe output</summary>

```text
1 crossed column dual: status optimal x [2.0] obj 2.0 maxViolation (bounds 1.0, rows 0.0) warnings ["presolve found the model infeasible (column x1 has lower bound 2.0 above upper bound 1.0); solving without presolve for the certificate"]
2 crossed row dual: status optimal x [3.0, 0.0] obj 3.0 maxViolation (bounds 0.0, rows 2.0)
3 incremental crossed change: status optimal x [1.5, 1.25] obj -2.75 maxViolation (bounds 1.0, rows 0.0)
4 engine applyBoundChanges crossed: status optimal x [1.5, 1.25] obj -2.75 maxViolation (bounds 1.0, rows 0.0)
edge: CASE xl>xu no rows expected infeasible: ["optimal": 40]; CASE rl>ru row expected infeasible: ["optimal": 40]
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated critical, documented: no</summary>

I reproduced the finding from scratch in slot V031, with my own cases and my own oracles.

(1) The behaviour happens. I tested 5 crossed-bound cases: K1 and K2 have x in \[2,1] with no rows, minimized and maximized. K3 has x0 in \[4,3] inside a row. K4 has a row with 3 &lt;= x+y &lt;= 1. K5 has a row \[6,2] next to a normal row. Each ran in 24 Simplex configurations: method dual or primal, pricing dantzig, devex or steepestEdge, presolve on or off, scaling geometric or none. All 120 solves return .optimal. My own violation measure (not CompiledLP.maxViolation) gives 1.0, 1.0, 1.0, 2.0 and 4.0. Automatic() returns the same .optimal points. On crossed columns, the result's warnings say presolve found the model infeasible. Three more paths return .optimal with a bound violation of 1.0 on my own base LP (cold optimum x=\[1,3], obj -7, which matches the hand value): WarmStart.incremental with a crossed BoundChange, a cold solve of applying(), and SimplexEngine.applyBoundChanges.

(2) The expected answer, infeasible, is correct. Five independent oracles agree:
- By hand, the intervals are empty.
- A grid enumeration over \[-10,10]^n finds 0 feasible points.
- I rewrote each problem with the same empty feasible set but no crossed interval. All 24 configurations answer .infeasible, and every dual ray passes my own Farkas interval check, which works in either sign orientation (24/24 per case).
- InteriorPoint answers infeasible for crossed columns and infeasibleOrUnbounded for crossed rows; branch and bound and CPSAT answer infeasible on a MIP with crossed bounds.
- The DSL compile throws invalidModel.

A control case also behaves correctly: an uncrossed bound change that makes the problem infeasible gets .infeasible with a ray on every path.

(3) The result does not depend on load or randomness. Each case and method gave one distinct answer over 10 runs (threads 1 and 8). Debug and release builds give identical results.

A sweep over the size of the gap rules out tolerance (default 1e-7). For gaps of 1e-6 to 1.0 the result is .optimal and the violation equals the gap. Only the documented noise rule for tiny crosses (gap/2 for 1e-12 and 1e-8, with presolve on) is benign. A gap of 1000 gives infeasible only because a row proves infeasibility on its own.

The code confirms the mechanism:
- primalInfeasibility (SimplexEngine.swift:664) checks only basic variables.
- placeNonbasic (line 382) puts a nonbasic column at lower\[j] even when lower\[j] > upper\[j].
- conclude (SimplexEngine+Driver.swift:785) marks .optimal primal-feasible without calling boundsRespected() (line 806), which would catch the point.
- Simplex.swift:155-161 replaces presolve's .infeasible verdict with the result of the unpresolved run.

The existing test infeasibilityFoundByPresolveStillCarriesARay creates the crossing only through singleton rows, so it cannot catch this case.

This is not misuse and not by design. README §1 lists a CompiledLP built by hand as a supported input. The initializer and the derivation and bound-change APIs are public and state no xl &lt;= xu precondition. README §4 covers only inconsistent dimensions. README, HANDBOOK and SPEC never mention crossed bounds. Every other part of the package treats crossed bounds as infeasible or invalid.

Severity is critical under the scale: a success status with an infeasible point. The affected scope is the LP simplex path (Simplex, SimplexEngine, the LP route of Automatic); B&B and CPSAT are not affected.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V031 && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 grid && perl -e 'alarm shift; exec @ARGV' 300 .build/debug/V031 warm
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-01-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

Contract lens: I tried to refute the finding as misuse, as by design, or as inside a tolerance. None of these holds.

(1) The input is accepted, not misuse.
- README §1 lists "a CompiledLP built by hand" as an input.
- CompiledLP.init (CompiledLP.swift:123-146) checks only dimensions.
- README §4 "Misuse of the building blocks traps" lists only inconsistent dimensions. Crossed bounds are not on that list, and they do not trap.
- No doc comment on xl/xu/rl/ru, withColumnBounds, withRowBounds, applying, BoundChange, WarmStart.incremental or SimplexEngine.applyBoundChanges requires lower ≤ upper.

(2) The package itself classifies this data as infeasible.
- Presolve.Outcome.infeasible is documented as "The model has no feasible point".
- The package's own test PresolveTests.boundsThatCrossByRoundingNoiseDescribeAFixedColumn says "A real crossing is infeasible". I ran Simplex on that exact instance (xl=\[1.5,0], xu=\[1,inf]): dual and primal both answer .optimal with a bound violation of 0.5.
- On the same hand-built data, InteriorPoint, BranchAndBound and CPSAT answer .infeasible. The DSL compile and the MPS reader throw invalidModel(.inconsistentVariableBounds).
- Simplex is the only engine that returns a success status.

(3) The Simplex path was meant to answer .infeasible.
- The comment at Simplex.swift:155-161 says the unpresolved problem "gives one \[certificate], and settles the status".
- SPECIFICATION-v0.2 §5.5 describes this as current Simplex behaviour: it returns the unpresolved answer and its certificate.
- The existing test SimplexBasicsTests/infeasibilityFoundByPresolveStillCarriesARay passes, giving .infeasible with a Farkas ray. Its crossing comes from singleton rows; a crossing stored in the column bounds is never tested.

(4) The status semantics are violated.
- SolveStatus.optimal says "An optimal solution was found and proven". README §4 Results says optimal means "feasible and dual feasible to 1e-7".
- The violations observed are 0.5 to 2.0, on exact data, so no tolerance or conditioning argument applies. A 1e-9 crossing is correctly treated as a fixed column, by design.
- Risk 1 is a generic hedge about floating-point algorithms, not documentation of this deterministic gap.
- With presolve off, through SimplexEngine, or with a crossed row, there is no warning at all. With presolve on, the warning ("presolve found the model infeasible") contradicts the .optimal status.

(5) The causal story is confirmed and slightly sharper than the finder's.
- primalInfeasibility() (SimplexEngine.swift:664) measures basic variables only. placeNonbasic (382-389) puts a nonbasic column on one of its two crossed bounds, so it violates the other.
- conclude() (SimplexEngine+Driver.swift:777-801) sets primalFeasible=true for .optimal without calling boundsRespected(). That function does check nonbasic columns, but only for other statuses, and its comment assumes they always sit within bounds.
- A crossed row fails the same way through its logical column. Presolve does not check rows for crossing at all (outcome .reduced).

(6) Small corrections to the finder:
- InteriorPoint answers infeasibleOrUnbounded only for the crossed row. For crossed column bounds it answers .infeasible.
- I did not re-run the 40-configuration grid.

Severity: critical under the given scale. This is .optimal with an infeasible point on an input the package accepts and itself calls infeasible. The routes are CompiledLP.init, withColumnBounds/withRowBounds/applying, WarmStart.incremental, SimplexEngine.applyBoundChanges, Automatic and Conditioned.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V032 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 lp && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 extra && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V032 other
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-01-contract.md`.

</details>

#### <a id="a2-02"></a>A2-02 · Primal simplex declares a feasible LP with condition number 1.5e9 infeasible, without a warning and with a dual ray that does not certify

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [B2-02](#b2-02) (cycle B)
- **Location:** Sources/ZTronLPSimplex/SimplexEngine+Primal.swift:697-706 (phase 1 finds no entering column above the tolerance and no weak candidate, and returns .infeasible); farkasRay(from:) at SimplexEngine+Primal.swift:584-590 picks the better sign but never checks that farkasValue > 0
- **Claim tested:** README 3 Risk 1: 'up to a condition number of about 1e10 the solution is recovered'; README 4 defect 8 (fixed): the simplex 'takes a small pivot before it concludes "infeasible"'; HANDBOOK decision 18; README 2.5: a ray when the answer is .infeasible; HANDBOOK Testing: every infeasible result's dual ray is checked numerically.
- **Observed:** Instance k15 of a random L·D·U equality family (n = 11, D spans 1e-7, κ₁ = 1.50e9, rows rl = ru = A·1, columns in \[-10, 10]). x = 1 satisfies every row exactly in floating point (maxViolation 0); a dense solve recovers x to 2.2e-8. Simplex(.primal) default: infeasible, warnings \[], Farkas margin of its dualRay -1.89e-7, which is negative, so the ray certifies nothing. The same holds in all 22 primal configurations of the grid (dense and QR, presolve on and off, scaling none and geometric, Dantzig, steepest-edge and partial pricing, perturbation off and always). InteriorPoint(), whose crossover runs the simplex, also answers infeasible. Simplex(.dual) and Automatic() answer optimal, 2.1e-8 from x = 1. Across the family: 19 more false .infeasible at κ 1e10-1e12 and 22 at κ 1e12-1e14.
- **Why it is wrong:** The LP is feasible, so .infeasible is a false conclusive verdict. It comes with no warning, at a condition number the README calls safe, and its certificate fails the independent check.
- **Documented:** Not documented. Defect 8 says the false 'infeasible' found on the Hilbert family is fixed. Defect 9 speaks of condition numbers above about 1e11 and says the answer then stays optimal.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 illone 15   (family sweep: perl -e 'alarm shift; exec @ARGV' 300 .build/release/F2 illrandom)
```

<details><summary>Probe output</summary>

```text
instance k15: n 11, D spans 1e-7.0, kappa1 1.50e+09; x = 1 violates rows by 0.00e+00, bounds by 0.00e+00; dense solve distance from 1: 2.21e-08; optimum 11.884433253052967
  Simplex(.primal): infeasible obj nil dist 9.00e+00 farkas margin -1.8900381828682925e-07 warnings []
  Simplex(.dual): optimal obj 11.884433256540472 dist 2.08e-08 warnings [ill-conditioned basis, estimate 2.1e9]
  InteriorPoint(): infeasible obj nil (stalled; the simplex finished from its last iterate)
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated critical, documented: no</summary>

I reproduced the finding from scratch in slot V034 and judged it with my own oracle, not the finder's. Only the instance generator was copied, so that I would get the same bits for k15; sum(c) = 11.884433253052967 matches the finder.

(2) The finder's expected behaviour is correct.
- I built an explicit inverse R from my own LU and evaluated E = I − R·A exactly (Shewchuk expansions with TwoSum and an FMA TwoProd). ‖E‖∞ = 4.96e-8 &lt; 1, which proves A nonsingular.
- The exact residual ‖b − A·1‖∞ is 2.64e-16. This gives the rigorous bound ‖x\* − 1‖∞ ≤ 6.34e-8, so x\* lies strictly inside \[−10, 10]^11 and the LP is provably feasible.
- The feasible set is the single point x\*. The optimum is c·x\* = 11.884433256607089, from a refined solve with exact residual 1.7e-17.
- By Farkas' lemma no infeasibility certificate can exist.
- κ from the explicit inverse: κ₁ = 1.50e9, κ∞ = 1.04e9, κ₂ = 5.0e8. All are below the README's "about 1e10" and below Hilbert order 8, which defect 8 says is fixed.

(1) The observed behaviour happens.
- Simplex(.primal) default answers .infeasible after 79 phase-1 iterations, with warnings \[].
- Its dual ray's exact Farkas value is −1.890038e-7 for the better of the two signs, so the ray certifies nothing. This matches the finder to 8 digits and is far above rounding noise. Taking both signs makes the check independent of the sign convention.
- In my own grid of 31 primal configurations, 29 answer the same way. They cover every factorization, presolve on and off, scaling none, equilibration and geometric, every pricing and every perturbation mode. Only lowering the tolerances to 1e-9, or raising them to 1e-6, gives a correct optimum.
- InteriorPoint() also answers .infeasible, and its crossover ray does not certify either. It warns only of a stall.
- Conditioned(Simplex(.primal)) answers .infeasible, and its report says "no warnings".
- Simplex(.dual), Simplex() and Automatic() are optimal and within 6.7e-11 of c·x\*.

The code matches the description. SimplexEngine+Primal.swift:697-706 returns .infeasible with farkasRay(from: y). farkasRay (lines 584-590) only chooses the better sign and never requires farkasValue > 0. Nothing downstream checks the ray.

(3) Load and randomness play no part.
- The engine RNG has a fixed seed (SimplexEngine.swift:209).
- Results were bit-identical (status, 79 iterations, ray hash 8a2fc91f224fec6d) across 10 sequential runs, 16 concurrent runs, threads 1, 2 and 8, time limits of 2 s and 300 s, and both the release and debug builds.

Breadth.
- My own fresh family has 400 instances (xorshift64\*, random c), all proven feasible.
- Simplex(.primal) gives false .infeasible on 23 of 78 at κ₁ 1e8-1e9, 57 of 83 at 1e9-1e10 and 30 of 73 at 1e10-1e11. The lowest κ₁ affected is 4.4e8.
- None of these rays certify and none of these answers are warned.
- InteriorPoint() is similar. Simplex(.dual) gave 0 false .infeasible.
- On the finder's 24 instances, the false .infeasible appear on k15 (κ₁ 1.5e9), k3 (1.3e10), k22, k5 and k20.

Documentation.
- The finding contradicts README Risk 1 ("up to about 1e10 the solution is recovered"), the defect 8 fix and HANDBOOK decision 18, and the HANDBOOK contract that an .infeasible result carries a Farkas certificate.
- Defect 9 covers only κ above about 1e11 and says answers stay optimal.
- Risk 1's generic heading ("wrong answer on a model unlike the tested ones") is a disclaimer, not documentation of this defect.
- Small oracle nit that does not affect the finding: the finder's "optimum" is c·1, not c·x\*. They differ by 3.6e-9.

Severity is critical under the rubric: a false .infeasible on a feasible LP, with no warning.

Two side notes, recorded as info and not verified further.
- At κ ≥ 4e13, primal also hits the 50,000-iteration limit on n ≤ 12 (k9, k10, k19, k21, k23), and returns numericalFailure on k4 and k8.
- A probe-toolchain hazard, not a package defect. Top-level code in main.swift (Swift 5 mode) that built an existential array of strategies and awaited inside the loop read uninitialized existential boxes. MallocScribble showed the 0xAA fill: maxIterations −6148914691236517206 and an invalid enum raw value of −86. Without scribble this showed up as maxIterations 0, so the solve ended with iterationLimit after 0 iterations. The same code inside a function is correct, and all my results use function-scoped code. A copy of the affected file is saved for the orchestrator.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V034 -c release && perl -e 'alarm shift; exec @ARGV' 200 .build/release/V034 one 15 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V034 fresh 400 7001
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-02-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

CONTRACT. SolveStatus.infeasible is documented as "The model has no feasible point". SimplexAnalysis.dualRay is documented as "When infeasible: a Farkas certificate over the rows", and README §2.5 and HANDBOOK line 114 say the same. README defect 8 says the false-'infeasible' class on ill-conditioned LPs is fixed: the simplex "takes a small pivot before it concludes 'infeasible'". The doc comment of fragilePivotLimit (SimplexEngine.swift:452-453) says the engine gives up "with a numerical failure" once those pivots run out. README §4 Results calls only "Optimal" a statement about tolerances. The README risk-1 sentence about "about 1e10" is about the Hilbert family, so I do not use it as the oracle; the status and certificate contract is enough.

REFUTATION ATTEMPTS.
(1) Oracle: correct. x = 1 is exactly feasible: maxViolation is 0, and the residual is at most 3.3e-16 when summed in reverse order or with Kahan summation. A is nonsingular and a dense solve lands 2.2e-8 from 1, deep inside the ±10 box, so the LP is feasible in exact arithmetic too. Since b = A·1, every r has Farkas value Σz\_j − 10Σ|z\_j| ≤ 0, so no certificate can exist. The ray's margin is −1.89e-7 against a rounding scale of 5.5e-15, so the negative sign is not noise.
(2) Misuse: no. A hand-built CompiledLP is a documented input, and Simplex(.primal) is a public method.
(3) Within tolerance: no. A point with zero violation exists, and `.infeasible` is not documented as tolerance-relative.
(4) By design: no. The code contradicts its own design. The dual method throws a numerical failure when the fragile budget runs out (Dual.swift:280-283, "Calling the problem infeasible would be wrong"). Primal phase 1 at SimplexEngine+Primal.swift:700-706 instead returns .infeasible once fragilePivots ≥ fragilePivotLimit. farkasRay(from:) (584-590) never checks that farkasValue > 0.

MECHANISM (more precise than the finder's). A trace with growing maxIterations shows phase 1 stalling near 3.5e-7, 3.5 times the 1e-7 tolerance, by iteration 17-20. It then alternates between two states (3.642e-7 and 3.414e-7) with one refactorization per iteration, which is the signature of a fragile pivot. That exhausts the m+50 = 61 budget, and the run ends .infeasible at iteration 79. So the branch taken is budget exhaustion, not "no weak candidate"; the source lines are the same. With the feasibility tolerances at 1e-9 the primal method returns the right answer.

SCOPE. In my own 200-instance sweep of the same family, Simplex(.primal) with defaults ends falsely .infeasible on 54. Every one has a non-certifying ray and no warning, and the lowest κ is 2.3e8. By κ bucket: 9/25 at 1e8-1e9 and 20/26 at 1e9-1e10. Simplex(.dual) is optimal on all 200. Default facades reach the defect too. InteriorPoint() ends infeasible, with a stall warning. On the integer version of the model (x = 1 is integral and feasible), Automatic() routes to BranchAndBound(engine: Simplex(.primal)): the root LP comes back infeasible, 0 nodes are processed, and the answer is .infeasible with no warning, on 6 of 6 instances tested. Conditioned(Simplex(.primal)) flags nothing: basis estimate 9.8e7, under the 1e8 threshold. The documented mitigations (check the ray, cross-check with another engine) catch it only if the user applies them.

NOT DOCUMENTED. Defect 8 claims the class is fixed. Defect 9 is about κ > 1e11 with answers that stay optimal. Risk 1 is a generic disclosure.

SEVERITY. Critical on the scale: a false conclusive .infeasible on a feasible model.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V035 -c release && perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 one 15 && perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 trace 15 && perl -e 'alarm shift; exec @ARGV' 400 .build/release/V035 sweep 200 && perl -e 'alarm shift; exec @ARGV' 200 .build/release/V035 mip 15,52
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-02-contract.md`.

</details>

#### <a id="b2-01"></a>B2-01 · Refinement pass swaps the optimal basis for the all-slack basis (sparse QR) and reports that starting point as .optimal, infeasible by 3.4e7

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A2-03](#a2-03): both in the simplex refinement pass, on badly scaled data with scaling: .none
- **Location:** Sources/ZTronLPSimplex/SimplexEngine.swift:471-475. In refactorize(), a .singular error that carries no positions makes the engine call installSlackBasis() silently. SparseQRBasis always throws such an error (BasisFactorization.swift:207-209, Sparse.swift:361-364); its probe tolerance of 1e-4 corresponds to a condition number near 1e12. Sources/ZTronLPSimplex/SimplexEngine+Driver.swift:584-587: refine() refactorizes the optimal basis, and that call performs the swap. From then on the pass measures the slack basis. Code reading says it most likely leaves through the early return at :594-597, which runs warnIfIllConditioned() on the identity basis and so gives no warning. If instead it takes the re-solve path, the state it would restore (:613) was captured after the swap. Either way the pass adds no pivots: 702 with and without it. Driver.swift:785: conclude(.optimal) sets primalFeasible = true without checking.
- **Claim tested:** README 2.5: Simplex 'Returns a vertex with its basis' and warns when the optimal basis is ill-conditioned; SolveStatus.optimal 'An optimal solution was found and proven'; README 4 Limits/Results: optimal means 'feasible and dual feasible to 1e-7'; HANDBOOK decision 16: 'The pass can only replace an optimal answer by a better one: anything but an optimal ending returns the engine to the basis it started from.'
- **Observed:** Simplex(.primal, factorization: .sparseQR, presolve: false or true, scaling: .none) on a feasible, bounded planted LP (HARD family seed 5067: m=56, n=67, known optimum -90497620.27) returns .optimal with objective 28004750.59 and no warning. CompiledLP.maxViolation(at:) of the returned x is 3.36e7 on the rows. The returned basis has 0 structural columns, and x is exactly the slack-basis starting point: the it=0 progress event has objective 28004750.594775513. The same progress log shows the engine had already reached the right optimum at it=700 (-90497620.2749953, phase 2, infeasibility 0). With denseLU the same LP ends optimal after 88 pivots and carries an ill-conditioned-basis warning (condition estimate 1.5e14). Seed 5069 (m=52, n=17, maximize) behaves the same way: .optimal at -2729088 against a true 106374769, rows violated by 1.35e7. On the public SimplexEngine (same LP, no presolve or scaling), solve(cutoff: nil) runs the refinement pass and gives 19 refactorizations, the all-slack basis and the wrong answer. With cutoff: 1e300, which cannot bind and skips refine (Driver.swift:462), it gives 18 refactorizations, 32 structural basics, the correct optimum and a row violation of 2.2e-8.
- **Why it is wrong:** A point that violates rows by 3e7, with an objective 130% off, is reported .optimal and carries no warning. The pass that is documented never to make an answer worse threw away the optimal basis.
- **Documented:** Not documented. README 4 and the HANDBOOK known gaps do not mention it, and HANDBOOK decision 16 states the opposite. No test covers a refactorization failure inside the pass: RefinementTests inject only an iteration limit.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F2 -c release && HARD=1 perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 one 5067 60 80 'P/QR/pre=0/sc=none/devex/pert=off' ; HARD=1 .build/release/F2 engine 5067 60 80 primal qr ; HARD=1 .build/release/F2 trace 5067 60 80 'P/QR/pre=0/sc=none/devex/pert=off' 100 ; HARD=1 .build/release/F2 one 5069 60 80 'P/QR/pre=0/sc=none/devex/pert=off' ; sweep: HARD=1 .build/release/F2 grid 5000 300 60 80 mid hard
```

<details><summary>Probe output</summary>

```text
P/QR/pre=0/sc=none/devex/pert=off status=optimal obj=28004750.594775513 it=702 pv=2.6e+00 dv=1.0e+00 objErr=1.3e+00 | package maxViolation(at:) bounds=0.0 rows=33642684.54654266 | warnings=[] | basis: 0 structural of 56 basic; max |x - slack-basis point| = 0.0. Engine: cutoff=nil -> status=optimal obj=28004750.594775513 refac=19 structural basics=0 rows=3.36e7; cutoff=1e+300 -> status=optimal obj=-90497620.27499528 refac=18 structural basics=32 rows=2.2e-08. Trace: it=0 obj=28004750.594775513 ... it=700 obj=-90497620.2749953 inf=0.0 phase=2; finished optimal
```

</details>

#### <a id="b2-02"></a>B2-02 · False .infeasible on feasible LPs, with a dualRay that certifies nothing (on Klee-Minty order 14, x = 0 is feasible)

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-02](#a2-02) (cycle A)
- **Location:** Sources/ZTronLPSimplex/SimplexEngine+Primal.swift:697-706. When phase 1 finds nothing to price, including after weakPhase1Entering(), it sets lastDualRay = farkasRay(from: y) and returns .infeasible without requiring farkasValue(lastDualRay) > 0. farkasRay (:584-590) only picks the better of the two signs, and farkasValue (:562-581) would return -inf for the Klee-Minty ray. Simplex.postsolved (Simplex.swift:237-291) does not check again.
- **Claim tested:** SolveStatus.infeasible: 'The model has no feasible point'. README risk 1: 'An .infeasible or .unbounded result of Simplex carries a ray that can be checked independently'. HANDBOOK Results: 'An .infeasible LP result carries a dual ray (a Farkas certificate)'. README defect 8 (marked fixed) and HANDBOOK decision 18: before phase 1 reads 'no direction of descent' as infeasibility, the small entries now get a second look.
- **Observed:** (1) Klee-Minty (Chvatal form) of order 14, where x = 0 is feasible (package maxViolation(at: 0) = (0, 0)). Simplex(.primal, scaling: .none) returns .infeasible after 7 pivots and Simplex(.dual, scaling: .none) after 6, both without a warning. The dualRay puts +0.05 on a row whose lower bound is -inf, so its Farkas margin is -inf. With scaling .none, 18 of the 36 configurations per method and presolve setting answer .infeasible at orders 13 and 14. (2) HARD planted seed 5028 (m=25, n=16), whose planted x\* is exactly feasible. Simplex(.primal, presolve: true, scaling: .none) returns .infeasible after 29 pivots with a dualRay margin of -2.0e-16. The returned x is the optimum itself (objective 16187313.706328832) and violates one bound by 1.35e-7 absolute. (3) Planted seed 30 with a warm start .basis that has all 7 structurals basic, which is a legitimate basis since n &lt; m. Simplex(.primal, factorization: .sparseQR, scaling: .none) returns .infeasible with margin 1.4e-12, while x is feasible to 1.2e-10 and sits at the optimum. (4) A planted LP with rows scaled by 10^+-3 (invariance seed 114): the primal method with sparse QR and scaling none returns .infeasible in 4 configurations.
- **Why it is wrong:** Each of these models is feasible: a point that satisfies every row and bound exactly is known. The status is false, and the certificate fails an independent Farkas check (margin &lt;= 0, or it relies on a bound that does not exist).
- **Documented:** Not in this form. README defect 8 and HANDBOOK decision 18 call the false-infeasible class fixed, on the Hilbert family. This is a different trigger: a wide range of magnitudes with scaling .none, or a warm start. The claim in README risk 1 that the ray can be checked independently fails here. In the samples, every case had scaling .none.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 kmone 14 'P/auto/pre=1/sc=none/devex/pert=onStall' ; .build/release/F2 kmone 14 'D/auto/pre=1/sc=none/devex/pert=onStall' ; HARD=1 .build/release/F2 cert 5028 60 80 'P/auto/pre=1/sc=none/devex/pert=off' ; .build/release/F2 allbasic 30 20 25 'P/QR/pre=1/sc=none/devex/pert=onStall' ; .build/release/F2 km 8 14 ; .build/release/F2 invariance 1 150 15 20
```

<details><summary>Probe output</summary>

```text
klee-minty 14: optimum 1e+26; x = 0 feasible: package maxViolation(at: 0) = (bounds: 0.0, rows: 0.0) | P/auto/pre=1/sc=none/devex/pert=onStall status=infeasible it=7 obj=nil farkas=margin -inf dualRay=[0.0, 0.0, 0.0, 0.0, -0.0, -0.0, -0.0, 0.0, -0.0, -0.0, -1.0, 0.05000000000000001, 0.0, 0.0] warnings=[] | D/auto/pre=1/sc=none/devex/pert=onStall status=infeasible it=6 (same ray). Seed 5028: planted x* absViol=0.0; P/auto/pre=1/sc=none status=infeasible it=29 x absViol=1.347e-07 obj(x)=16187313.706328832 (= planted optimum) farkas=margin -2.0e-16 warnings=[]; with presolve false or with the dual method the status is optimal.
```

</details>

#### <a id="a2-03"></a>A2-03 · After a failed refinement pass, .optimal stands although the refactorized vertex violates feasibility by up to 8e3; the same badly scaled inputs also get false .infeasible verdicts

- **Severity:** medium (finder); skeptic: critical · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it and rated it critical; by the policy a second skeptic and a tiebreak are pending.
- **Related:** [B2-01](#b2-01): both in the simplex refinement pass, on badly scaled data with scaling: .none
- **Location:** Sources/ZTronLPSimplex/SimplexEngine+Driver.swift:649-671 (fallback branch of refine(): restores `start` and only warns; a `remaining` above tol.primalFeasibility is neither turned into a non-optimal status nor sent back to the main loop)
- **Claim tested:** README 4 Results limit: 'Optimal' means 'feasible and dual feasible to 1e-7'; doc comment of SimplexEngine.refine and HANDBOOK 16: 'The pass can only replace an optimal answer by a better one'; the engine's own warning: 'the solution is optimal within the tolerances'.
- **Observed:** KKT-constructed LP (seed 1273, 7x10, |a| in \[2.2e-8, 1.0e6]) with Simplex(.primal, factorization: .sparseQR, scaling: .none): optimal, objective 3.94e7 against the constructed -3.07e8 (relative error 1.13), row violation 496, warning 'the solution is optimal within the tolerances, but a violation of 8186.179927012323 remains that pivoting at tighter tolerances could not remove: the problem is ill-conditioned'. The sweep at row and column scales of 10^±4 gave 27 .optimal answers whose own warning reports a violation above 1e-6, and 9 false .infeasible verdicts whose rays have negative Farkas margins and carry no warning. All of these use scaling: .none; the default geometric scaling is right on every instance, and spreads up to 10^±3 are clean in every configuration.
- **Why it is wrong:** On a fresh factorization the engine measured a violation 8e10 times its tolerance and still returned the status that promises feasibility to 1e-7. refine() restores the basis from before the pass and treats it as optimal, although that re-measurement showed it is not, and the warning text misstates it.
- **Documented:** Partly. README 3 Risk 1 warns of wrong answers on models unlike the tested ones. Nothing says .optimal can stand when the vertex's own re-measured violation exceeds the tolerance, and the warning calls it 'optimal within the tolerances'.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 one 1273 7 10 0 0 4 primal/qr/pretrue/none primal/qr/pretrue/geo   (sweep: perl -e 'alarm shift; exec @ARGV' 500 .build/release/F2 kkt 400 1000 4 1)
```

<details><summary>Probe output</summary>

```text
primal/qr/pretrue/none: optimal obj 39435549.925776005 viol 0.00e+00/4.96e+02 iters 114 warnings ["the solution is optimal within the tolerances, but a violation of 8186.179927012323 remains that pivoting at tighter tolerances could not remove: the problem is ill-conditioned"]
primal/qr/pretrue/geo: optimal obj -307388095.1768795 viol 0/0
sweep: optimal answers whose own warning reports a remaining violation > 1e-6: 27; FALSE-VERDICT ... primal/auto/pretrue/none: infeasible farkas margin -0.000122 warnings []
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated critical, documented: no</summary>

Reproduced exactly with an oracle independent of the finder's.

Oracle:
- The optimum is certified by weak duality from the constructed (x, y). I recompute d = c - A^T y, check every multiplier sits on a finite bound, and find P = D = -307388095.1768796, with x feasible to 3.5e-17. I use neither the generator's objective nor maxViolation.
- Violations are recomputed with compensated sums.
- The vertex of the returned basis is computed independently: equilibrated GEPP with double-double refinement, duals from B^T y = c\_B.
- InteriorPoint, Simplex(), Simplex(.primal) and Automatic all reach the certified optimum.

Seed 1273 reproduction:
- Simplex(.primal, factorization: .sparseQR, presolve: true or false, scaling: .none) returns .optimal with objective 39435549.93 (relative error 1.128).
- The point violates equality row 6 by 496.2 (0.947 relative).
- The warning says a violation of 8186.18 remains.

Mechanism (sharper than the finder's account): refine() destroys a correct answer.
- With SimplexEngine.solve(cutoff: 1e300), refine is skipped and runPrimal ignores the cutoff. The main loop ends after 64 iterations at the correct optimal basis: certified objective, violation 8.9e-16, dual violation 0, 4 logicals, equilibrated kappa 10.6.
- A fresh SparseQRBasis.refactor of that basis throws singular(positions: \[], rows: \[]), and DenseLU also calls it singular.
- With refine, 50 more pivots (64 + 50 = 114) end on the all-logical basis (kappa 1). Its exact vertex violates row 6 by 496.2, and its largest reduced-cost sign violation is 8186.179927012323, exactly the engine's 'remaining'.
- So refactorize() at refine entry (SimplexEngine+Driver.swift:584-588) silently installs the slack basis via SimplexEngine.swift:460-481. `start` is captured after that (line 611), the pass fails, and the fallback (648-671) 'restores' the slack basis while .optimal stands (line 465).
- The same holds on seeds 1383, 1182, 1377 and 1017: right without refine, wrong with it, and always 50 extra iterations.

Sweep over the finder's seeds and grid with my oracle:
- 27 .optimal answers whose warning reports a remaining violation above 1e-6, matching the finder. 25 of them are wrong by my oracle (all carry that warning, all scaling .none). The other 2 are primal feasible with objective error 1.8e-8.
- 9 false .infeasible verdicts, matching the finder. All are scaling .none, none has a warning, and each problem has a known feasible point. Their rays' Farkas margins are negative or at rounding level (one is +2.3e-13); none can certify, since the problems are feasible.
- Equilibration and default geometric scaling: 0 bad answers. Spread 10^±3: clean (0 wrong out of 20800).

Contract:
- README §4 says 'Optimal' means feasible and dual feasible to 1e-7. That is violated.
- HANDBOOK 16 and the refine() doc comment say 'the pass can only replace an optimal answer by a better one'. That is false here: the pass replaced a correct answer by an infeasible one.
- The warning misstates the situation twice: 'optimal within the tolerances' is untrue, and so is 'ill-conditioned' (the returned basis has kappa 1).
- Not misuse (.none is a public, documented option), not within a tolerance, not by design: the engine measures the violation itself and discards it.
- documented=false: Risk 1 is generic, and defect 9 covers only feasible answers on ill-conditioned bases.

Severity: critical on the given scale (.optimal at an infeasible point with a wrong objective; false .infeasible without warning). Likelihood is limited because it needs scaling: .none on data spread over about 13-14 decades.

Side note, not part of A2-03: in a release build only, an array of `any SolverStrategy` built in main.swift's top-level async code held zeroed strategy values. The debug build, or a function scope in release, is right. This is probably a toolchain issue in the probe.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V037 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V037 norefine 1273 7 10 0 0 4 qr primal && perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V037 sweep 400 1000 4
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-03-combined.md`.

</details>

#### <a id="a2-04"></a>A2-04 · 'Beyond a condition number of about 1e11 only the objective can be trusted' holds only for the Hilbert family's objective

- **Severity:** medium (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Location:** README.md:408 (Risk 1), README.md:461-468 (defect 9)
- **Claim tested:** README 3 Risk 1: 'up to a condition number of about 1e10 the solution is recovered, beyond it only the objective is (defect 9)'; README 4 defect 9 title: 'Beyond a condition number of about 1e11 only the objective can be trusted'.
- **Observed:** Random L·D·U equality LPs (x = 1 unique, generic objective c = Aᵀ1 + 1, 24 instances x 40 configurations). At κ₁ 1e10-1e12 the objective is right (worst 8.1e-8). At κ₁ 1e12-1e14, 165 of 167 .optimal answers have the objective off by more than 1e-6 (worst 1.85 relative); above 1e14, 244 of 244 (worst 3.43). All carry the ill-conditioning warning. In the Hilbert family c = H·1, so cᵀx = 1ᵀHx is pinned by the rows and the objective is right whatever point is returned; that is why the README's measurements look good.
- **Why it is wrong:** The general statement tells users to trust the objective of an ill-conditioned answer. With a generic objective it is as wrong as the point.
- **Documented:** Misstated: defect 9 generalises from the Hilbert family, whose objective is constant on the near-feasible set.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F2 illrandom | grep BUCKET
```

<details><summary>Probe output</summary>

```text
BUCKET 1e10-1e12: optimal 101, objective off by > 1e-6: 0, worst 8.08e-08
BUCKET 1e12-1e14: optimal 167, objective off by > 1e-6: 165, worst 1.85e+00
BUCKET >1e14: optimal 244, objective off by > 1e-6: 244, worst 3.43e+00
(unwarned far-off optimal answers: 0)
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated medium, documented: no</summary>

Reproduced with an independent exact oracle. Every probe LP is a square nonsingular equality system with box bounds, so its only feasible point, and its optimum, is x\_exact = A^-1 b. V040 writes every double as its bit pattern. A Python script then rebuilds each LP with fractions.Fraction and computes exactly: x\_exact, opt = c^T x\_exact, kappa1 = ||A||1 ||A^-1||1, and the duals y = A^-T c.

1. Decisive case: the README's own family with only the objective changed. I used InstanceGenerator.hilbert(order: 6...12) in the equality and equalityFree forms, keeping the matrix, b and bounds. The README describes this family as "LPs on the Hilbert matrix whose only optimum is x = 1", which these LPs still are.
- With the generator's c = H\*1, orders 9-12 are right to 7.9e-13, which reproduces the README.
- With c = H^T y and y in \[0.5, 1.5] (moderate duals), they are right to 1.2e-12.
- With a random c in \[0.5, 1.5]^n, order 9 (kappa1 1.1e12) returns .optimal with relative objective errors up to 6.5e-2. Example: hilbert-9-equality-generic1 gives 9.0252 against an exact 9.6328 from Simplex(), Simplex(.primal) and InteriorPoint() alike. Order 10 is off by up to 3.0e-2, order 11 by 5.6e-2, order 12 by 0.136.

2. Mechanism. The identity c^T xhat - opt = y^T(A xhat - b) holds with zero discrepancy for every answer.
- With c = H\*1 the duals are y = 1, so the objective error is only the sum of the row residuals (about 1e-11). That is why the README's measurements look good.
- With a random c, |y| runs from 6e10 to 3e15, and the same 1e-11 residuals move the objective by percent.

3. My own family (A = Q1 diag(sigma) Q2^T, random x\*, random c):

| kappa1 | .optimal answers off by > 1e-6 | worst relative error |
|---|---|---|
| 1e11-1e12 | 8 of 31 | 5e-6 |
| 1e12-1e13 | 24 of 34 | 2.42 |
| 1e13-1e14 | 37 of 37 | 4.65 |
| 1e14-1e16 | 69 of 69 | 12.8 |

With c = A^T y and moderate y, nothing is off at any condition number (worst 3.6e-9).

4. The finder's 24 instances, rebuilt bit for bit, on its 40 configurations, checked exactly:
- kappa1 up to 1e11: worst 4.5e-8.
- kappa1 1e12-1e14: 159 of 167 off by > 1e-6 (the finder said 165), worst 1.85. The 6-answer gap comes from the finder's oracle, sum(c): it ignores the rounding of b and is itself 2e-6 off at kappa1 3.6e12.
- kappa1 above 1e14: 244 of 244, worst 3.43.
- Every one of these carries a warning.

5. Contract. The solver stays inside its own tolerance contract: README §4 Results says "Optimal is a statement about tolerances", feasible to 1e-7, and the wrong answers are feasible to 1e-9 to 1e-12. The fault is in the documents.
- The defect 9 title and Risk 1's "beyond it only the objective is" tell users the objective of an ill-conditioned answer can be trusted. That holds only when the duals are moderate.
- The body's "right in its objective to 1e-11" fails even for an equality-form member of the family as the README describes it.

6. Not documented.
- Nothing says the objective can be wrong.
- The warning understates the error: on hilbert-9-equality-generic1 it says "the values may be wrong by about 5.79e-07 relative" while the objective is off by 6.3e-2.
- Risk 1's suggested cross-check with another engine does not help, because all engines agree on the wrong value (about 9.02).

7. Severity: medium. The false generalisation is in the outside-view README and in a regime users are told to trust. It is confined to kappa above about 1e11, in a section that already presents the regime as a defect, with warnings on nearly all such answers. The solver's own contract is not broken.

Side observations, outside this verdict and not verified further:
- randsvd-n9-p12-s0-generic: Simplex(), Automatic() and Conditioned(Automatic()) return .optimal with objective -9.109 against an exact 6.405, with no warning at all.
- On the Hilbert free form with a random objective, which is feasible and bounded: every simplex strategy answers .unbounded at orders 10-12, and InteriorPoint() answers .infeasibleOrUnbounded from order 6 up.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V040 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V040 hilbert "$TMPDIR/h.jsonl" && python3 -I verification/cycle-A/A2-04-V040-oracle.py "$TMPDIR/h.jsonl" | grep ' all '
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-04-combined.md`.

</details>

#### <a id="b2-03"></a>B2-03 · Dual simplex stalls until the 50,000-pivot cap on a feasible 36x78 LP; .onStall never fires because its trigger measures primal degeneracy

- **Severity:** medium (finder) · **Category:** hang · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPSimplex/SimplexEngine+Dual.swift:412-421 (the trigger requires degeneracyFraction() > 0.3 and !costsPerturbed); Sources/ZTronLPSimplex/SimplexEngine.swift:703-715 (degeneracyFraction measures primal degeneracy); SimplexEngine+Dual.swift:165, 423, 448 (cost shifts set costsPerturbed)
- **Claim tested:** Simplex.Perturbation.onStall (Simplex.swift:37-38, README 2.5): 'After 1,000 iterations without progress with more than 30% of basics at a bound'. The anti-cycling comment at SimplexEngine.swift:724-725 says a basis seen among the last 64 triggers Bland's rule for 50 iterations. The task contract requires that degenerate problems do not stall.
- **Observed:** Planted LP seed 1356: m=36, n=78, real data, a 2.9-decade row and column spread, known optimum 7255833.9693. Simplex(.dual) returns noSolution(iterationLimit) after 50,000 pivots, 1,317 refactorizations and degeneracy 0.0. This happens with denseLU or automatic factorization (presolve false, scaling .equilibration) and with sparseQR (presolve true or false, scaling .none), under perturbation .off and .onStall alike. In the progress log the objective sits at the optimum (7255833.97) from pivot 2,000 on, while the primal infeasibility swings between 4e6 and 1.2e8 for 48,000 dual-degenerate pivots. Perturbation .always solves every one of these configurations, and so does the primal method. HARD seeds 5093, 5142, 5147, 5169 and 5173 stall the same way with dual/QR/scaling none. Unscaled Klee-Minty of orders 8-12 stops at 50,000 pivots in 27 of 36 configurations per method, although Dantzig's worst case there is 2^n-1 &lt;= 4,095 pivots.
- **Why it is wrong:** A feasible, bounded LP with 36 rows goes unsolved. The documented anti-stall mechanism cannot engage for the kind of stall the dual method has, which is dual degeneracy. degeneracyFraction() counts basic variables at a bound, which is primal degeneracy and is 0.0 here. The trigger is also blocked whenever a cost shift has set costsPerturbed.
- **Documented:** Not documented. README 2.5 describes the .onStall trigger accurately but says nothing of this consequence for the dual method. No stall appeared with the default geometric scaling in 2,700 sampled seeds.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F2 trace 1356 60 80 'D/LU/pre=0/sc=eq/devex/pert=onStall' 2000 ; sweep: .build/release/F2 grid 1000 400 60 80 full (32 failures, all on seed 1356) ; HARD=1 .build/release/F2 grid 5000 300 60 80 mid hard ; .build/release/F2 kmone 10 'P/auto/pre=1/sc=none/devex/pert=onStall'
```

<details><summary>Probe output</summary>

```text
it=2000 obj=7255833.970796935 inf=4398358.43 ... it=24000 obj=7255833.965338953 inf=121441636.69 ... it=48000 obj=7255833.969265446 inf=12306679.97 | finished noSolution(iterationLimit) 0.459s | D/LU/pre=0/sc=eq/devex/pert=onStall status=noSolution(iterationLimit) it=50000 ph1=0 refac=1317 degen=0.0
```

</details>

#### <a id="a2-05"></a>A2-05 · README 5 ill-conditioned table under-counts the warned answers at orders 4 and 5

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Same defect:** [A3-10](#a3-10) (cycle A), [A7-02](#a7-02) (cycle A), [B7-03](#b7-03) (cycle B)
- **Location:** README.md:615-616
- **Claim tested:** README 5 table, column 'Answers with a warning': order 4 '0 of 12', order 5 '3 of 12'; text: 'The warnings at orders 5 and 6 are the interior point's, whose normal equations stall there'.
- **Observed:** Order 4: 4 of 12, order 5: 4 of 12. From order 4 on, every InteriorPoint() answer carries the warning '4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)'. At order 5 the stall warning appears on 3 forms. Every other column of the table reproduces (distances, objective errors, all statuses optimal, 12 of 12 warned from order 7).
- **Why it is wrong:** The table counts only the stall warnings, while an answer with any warning is what its column header names.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 hilbert 12 ; perl -e 'alarm shift; exec @ARGV' 100 .build/release/F2 hwarn 4
```

<details><summary>Probe output</summary>

```text
4 | 5.30e-13 | 5.30e-13 | 6.12e-13 | 5.30e-13 | 3.50e-16 | 4 of 12 | []
5 | 5.77e-12 | 5.84e-12 | 8.21e-12 | 5.77e-12 | 1.38e-16 | 4 of 12 | []
order 4 equality ipm: optimal warnings ["4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"]
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

I reproduced the finding in my own slot (V043, my own code). For each order I counted the same 12 answers: 4 Hilbert forms times Simplex(.dual), Simplex(.primal) and InteriorPoint(). I counted them three independent ways:
(1) answers whose analysis.warnings is non-empty, which is what the column header names;
(2) answers that sent a SolverEvent.warning through the SolveContext.progress callback, a separate channel;
(3) a prediction from the CompiledLP structure alone, using the README section 4 rule that a column with more than 30% nonzeros makes the normal equations dense and triggers a warning. Hilbert columns are 100% dense.

All three counts give 4 of 12 at order 4 and 4 of 12 at order 5. The README says 0 of 12 and 3 of 12. The four warned answers are the InteriorPoint() ones, each carrying "4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)". The count is made at IPMWorker.swift:128, the warning is emitted at :638-640, and InteriorPoint.swift:139 copies it into the answer. At order 5, three IPM answers also carry the stall warning; the equalityFree one carries only the dense-column warning.

If the dense-column warning is removed and the answers that still carry a warning are counted, the result matches the README column exactly at every order from 3 to 12 (0, 0, 3, 4, 12, ...). So the table counted only the conditioning warnings (stall and ill-conditioned basis), not answers with any warning. The finder said "only stall warnings"; that is slightly imprecise, because from order 7 on the ill-conditioned-basis warnings are counted too. This does not change the verdict.

Refutation attempts that fail:
- Wrong oracle: no. Three independent counts agree.
- Misuse: no. I used default InteriorPoint() with Metal off and with the default Metal setting, and got the same result. All 120 solves end optimal, and the distance and objective-error columns reproduce (order 4: 5.3e-13/6.1e-13/5.3e-13 and 3.5e-16).
- Stale table: no. The table first appears in commit 9fd4f24, and Sources/ is unchanged from 9fd4f24 to HEAD d9afebe (git diff --stat is empty). At 9fd4f24 the warning and the code that passes it into the answer already existed. The README also says the table was measured with the engines as they are now.
- By design: the warning itself is by design and is documented in README section 4. That makes the table's count wrong, not right. Nothing says the column leaves it out, and the text under the table attributes the warnings at orders 5 and 6 to stalls, implying there are none at order 4.

Not documented: no document says the table leaves out the dense-column warning. Severity is low: it is a number mismatch in a measured table, the uncounted warning is a harmless notice, and no answer is wrong.

Side observation (info, outside this verdict): the README section 4 rule would also predict the warning at order 3, but IPMWorker.swift:128 counts dense columns only when keptRows > 3, so order 3 gets none.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V043 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V043 table 12 off
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-05-combined.md`.

</details>

#### <a id="a2-06"></a>A2-06 · SparseQRBasis doc comment says it is chosen when the basis density is below 2%; no code does that

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Same defect:** [B2-04](#b2-04) (cycle B)
- **Location:** Sources/ZTronLPNumerics/BasisFactorization.swift:204-205; Sources/ZTronLPSimplex/Simplex.swift:78-90
- **Claim tested:** Sources/ZTronLPNumerics/BasisFactorization.swift:204-205: 'Chosen when m > 1,500 or the basis density is below 2%.'
- **Observed:** Simplex.makeFactorization(rows:) picks by m only: rows 100 and 1500 give DenseLUBasis, 1501 gives SparseQRBasis. basisDensity(basic:lp:) is called by no engine, as README 2.7 says.
- **Why it is wrong:** The doc comment describes a selection rule that does not exist.
- **Documented:** README 2.7 states it correctly ('What Simplex uses above 1,500 rows'); the doc comment does not.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F2 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F2 engine | tail -1
```

<details><summary>Probe output</summary>

```text
makeFactorization(rows: 100) is DenseLUBasis: true; rows 1500: true; rows 1501: true
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

The finding holds. The doc comment on SparseQRBasis (Sources/ZTronLPNumerics/BasisFactorization.swift:204-205) says it is "Chosen when m > 1,500 or the basis density is below 2%", but no code applies a density rule.

Code reading:
- Simplex.makeFactorization(rows:) (Simplex.swift:78-90) takes only m. The `.automatic` case tests only m &lt;= denseBasisLimit (1,500).
- It is called with `rows:` only, at Simplex.swift:103 and 198 and InteriorPoint.swift:267.
- SimplexEngine.factor is assigned once, in its init (SimplexEngine.swift:245), so the factorization never switches mid-solve.
- basisDensity(basic:lp:) is called only by tests (BasisFactorizationTests:528-533).
- Automatic routes to the sparse-QR simplex only for m > 10,000 with a column more than 30% dense, which is the opposite of a low-density rule.
- The sibling DenseLUBasis doc comment says "Chosen when m &lt;= 1,500". For m &lt;= 1,500 with density below 2%, the two comments contradict each other.
- git history: the selector is m-only in every commit, and the density sentence dates from v1.0. SPECIFICATION-v0.2 plans no density rule either.

Execution (V046), using oracles independent of the finder's type check:
1. A behavioural fingerprint of a real solve. DenseLUBasis refactors every 100 updates and SparseQRBasis every 50, so pivots, refactorization count and the objective and primal bits identify the factorization used.
2. Peak resident memory in fresh processes. DenseLUBasis allocates a dense m x m matrix.
3. Basis density computed by probing every entry of the basis, which matched basisDensity exactly.

Results:
- On transport LPs with basis density between 0.07% and 0.98%, `.automatic` behaved exactly like forced `.denseLU` at m = 200, 1,000 and 1,500, with bit-identical solutions and peak memory growth of 45.7 MB against 7.9 MB for sparseQR.
- At m = 1,501 it behaved like `.sparseQR`.
- Four repeated runs gave identical fingerprints.

Refutation attempts failed:
- Not misuse: the default automatic selection was used, and `makeFactorization` has no density input.
- Every reading of "density" puts these LPs below 2%.
- Not by design: the DenseLUBasis comment uses "Chosen when" for the automatic rule.
- No tolerance applies, since this is a discrete choice.

documented=false: the true m-only rule is stated correctly in README 2.5, 2.7, §3 risk 2, §4 Limits and §5, in HANDBOOK, in SPECIFICATION-v0.2 line 100, and in the Simplex.Factorization.automatic and DenseLUBasis doc comments. No document records that the SparseQRBasis comment is wrong.

Severity is low: a false sentence in a public doc comment, with no effect on any answer.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V046 -c release && perl -e 'alarm shift; exec @ARGV' 580 .build/release/V046 && for cfg in "auto 20 1480" "dense 20 1480" "sparse 20 1480" "auto 20 1481"; do perl -e 'alarm shift; exec @ARGV' 200 .build/release/V046 rss ${=cfg}; done
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-06-combined.md`.

</details>

#### <a id="a2-07"></a>A2-07 · No simplex test checks returned duals or reduced costs beyond one textbook LP, and no test covers crossed bounds

- **Severity:** low (finder); skeptic: info · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle A (claims first)
- **Verification:** The skeptic refuted it.
- **Location:** Tests/ZTronLPSimplexTests/SimplexTests.swift:237-290; Tests/ZTronLPIntegrationTests/CorpusTests.swift:211-252; Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:55
- **Claim tested:** README 4 Results limit: 'feasible and dual feasible to 1e-7'; the sign convention in Analysis.swift (dual = sensitivity of the reported objective, logical reduced cost = dual); HANDBOOK Testing: oracle 1, constructed optima.
- **Observed:** ConstructedInstance.dual is used only by ZTronLPCoreTests/ScalingTests and ZTronLPTestSupportTests/FixtureTests. SimplexConstructedOptimaTests, ConstructedOptimaCorpusTests, NetlibCorpusTests and IllConditionedTests assert status, objective and primal feasibility only. The one dual check is SimplexBasicsTests.textbookProblem, a single 2x3 maximisation. A wrong dual sign or dual-infeasible reduced costs would pass the suite. My probes found the duals right: 20800 KKT solves, dual-sign violation at most 8.8e-14. IllConditionedTests asserts a distance of at most 2e-5 for a README claim of 'about 1e-6', and no test exercises crossed bounds (A2-01).
- **Why it is wrong:** Half of the 'optimal' contract, dual feasibility and complementary slackness, has no test that could fail.
- **Documented:** not stated

**Reproduction**

```sh
cd . && grep -rn 'instance\.dual\|analysis.dual\|reducedCosts' Tests/ZTronLPSimplexTests Tests/ZTronLPIntegrationTests
```

<details><summary>Probe output</summary>

```text
grep: instance.dual only in Tests/ZTronLPCoreTests/ScalingTests.swift:164-173 and Tests/ZTronLPTestSupportTests/FixtureTests.swift:45; analysis.dual! only in SimplexBasicsTests.textbookProblem
```

</details>

<details><summary>Skeptic, combined lens: refuted, rated info, documented: no</summary>

The main claim does not reproduce. The finder's own repro grep prints Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift:48-49 (analysis.dual, then lp.reducedCosts(forDuals:)). Lines 50-55 assert structural dual feasibility together with complementary slackness, with tol = 1e-5\*(1+|obj|). The assertion runs on all 13 netlib LPs under 4 simplex configurations (primal and dual, each with and without presolve and scaling): 52 test cases. All 52 passed in the baseline log and again when I ran them.

Two more simplex tests check duals, outside the two directories the finder searched:
- WorkedExampleTests.transportLPWithNamedDuals (FacadeTests.swift:95-117) runs Simplex(.dual) and checks strong duality by constraint name to 1e-7 and that every reduced cost is >= -1e-7.
- ReadmeExampleTests.theRelaxationHasShadowPrices runs Simplex(.dual) and checks the shadow prices 19/6 and 8/3 to 1e-9.

PresolveTests also uses ConstructedInstance.dual (base.dual, line 485), contrary to the finding's evidence.

The finder also wrote that a wrong dual sign or dual-infeasible reduced costs would pass the suite. I fed the suite's own netlib assertion broken duals in my V049 probe:
- all duals negated: caught in 52/52 cases
- all duals zero: 52/52
- largest dual negated: 52/52
- duals x 1.1: 52/52
- each nonzero dual negated in turn: 3924/4137 (95%)
- each nonzero dual zeroed in turn: 3880/4137 (94%)

The transport test catches every mutation I tried, including negating only the reduced costs. The textbook test catches every mutation of the duals.

Contract check: the duals are right. My oracle is different from the finder's per-component sign checks. It uses the Lagrangian dual bound (weak-duality gap) and recomputes y = B^-T c\_B by my own Gaussian elimination.
- Netlib: worst gap 2.4e-15, worst dual infeasibility 3e-12.
- 1000 constructed solves, half of them maximizations: worst gap 2.4e-14. The logical reduced cost equals the dual, and the reported rc equals flip\*d(flip\*y), both exactly.
- beaconfd with presolve: the returned basis's own duals differ from the reported ones in 25 rows. Both vectors are optimal and the basis warm-starts in 0 iterations, so this is dual degeneracy, not a defect.

So README §4 "dual feasible to 1e-7" and the HANDBOOK and Analysis.swift sign convention hold, and the docs claim no coverage that does not exist.

The two sub-claims:
- IllConditionedTests asserts 2e-5 against README's "about 1e-6". This is literally true, but the README number is a measured value (I reproduced it: 3.96e-7, 8.72e-7 and 7.64e-7 at order 8). The test still catches the failure it is named for, defect 8 (a distance of 1 to 2.1).
- "No test covers crossed bounds" is false as stated. CompileTests:339, LPFormatTests:448, MPSFormatTests:474, PresolveTests:311 and SimplexTests:96-104 all cover crossed bounds or crossing singleton rows. It is true only in the narrow sense that no test hands Simplex a CompiledLP with xl > xu or rl > ru, which is A2-01's subject.

Remaining true but narrow (info):
- The constructed-optima suites never check duals.
- The netlib check covers structural columns only, at a loose 1e-5\*(1+|obj|): a 0.1% dual scaling error is missed in 28 of 52 cases.
- For a maximization, the reported reducedCosts are checked for count only.

None of these hides a defect.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V049 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/V049 all ; cd . && sed -n '44,57p' Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A2-07-combined.md`.

</details>

#### <a id="b2-04"></a>B2-04 · SparseQRBasis doc comment describes a density rule for choosing it that no code applies

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-06](#a2-06) (cycle A)
- **Location:** Sources/ZTronLPNumerics/BasisFactorization.swift:204-205
- **Claim tested:** Sources/ZTronLPNumerics/BasisFactorization.swift:204-205: 'Chosen when m > 1,500 or the basis density is below 2%.'
- **Observed:** Simplex.makeFactorization(rows:) (Simplex.swift:78-90) takes only the row count, and .automatic returns DenseLUBasis for every m &lt;= 1,500 whatever the density. No engine calls basisDensity(basic:lp:): grep finds only its definition, and README 2.7 itself says it serves 'the tests and the analyzer and no engine'.
- **Why it is wrong:** The doc comment states a selection rule that does not exist.
- **Documented:** README 2.7 and Simplex.Factorization.automatic state the actual rule (dense LU up to 1,500 rows); only this doc comment is wrong.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F2 -c release && .build/release/F2 crash 1 1 (the last line prints makeFactorization(rows: 1500) -> DenseLUBasis, rows: 1501 -> SparseQRBasis) ; grep -rn 'basisDensity' Sources
```

<details><summary>Probe output</summary>

```text
Simplex().makeFactorization(rows: 1500) -> DenseLUBasis, rows: 1501 -> SparseQRBasis; grep basisDensity: only BasisFactorization.swift:283 (the definition)
```

</details>

### <a id="f3-ipm"></a>F3 Interior point, crossover, conditioning, Conditioned

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** F3 holds on its main path. Constructed LPs (240/240 KKT-correct), netlib (13/13, iteration and pivot counts as in README 5), dense columns, analyzer estimates, thresholds and memory cap, and Conditioned's pass-through are all as documented. The status logic fails in both directions, though. A3-01 (critical): an infeasible LP with a large rhs (x+y=1e8, x+y=1e8+1) comes back .optimal with violation 0.5 from every IPM configuration and through Conditioned, even after the crossover itself proved infeasibility, because the relative residual test accepts it and a non-optimal crossover falls back to the interior point. A3-02 (critical): on feasible bounded LPs at condition 1e8..1e10, inside README's recovered range, the default InteriorPoint() answers .infeasible (16/30 at kappa2=1e9, m=8) with a ray that fails the Farkas check, via the stall path's primal phase 1. A3-03 (high): the defect-8 class (.infeasibleOrUnbounded on feasible ill-conditioned LPs) is not fixed when costs are scaled or columns are free, because the mu &lt; 1e-10 gate is absolute. Medium findings: .feasible returned despite the 'never .feasible' contract; IPM(none) row violations of 2.6e-5 behind a reported residual of 3.9e-12; defect 10 misdescribed (silent .optimal far from the optimum); non-optimal presolved bases from expandBasis; tests too weak to catch any of these. Low: two doc mismatches (defect 7 wording, the README 5 warning column).

Claims and properties that held: 15.

Not checked:

- Analyzer tooManyRows cap above 4000 rows (existing test theEstimateIsSkippedAboveFourThousandRows, not run)
- LDL^T and regularization fallback of the normal-equation factorization
- Sparse (Accelerate, m > 300) normal-equation path under ill-conditioning; condition probes were dense only
- Effects of Conditioned's context.attachingMetal() and the Metal tier
- InteriorPoint as a branch-and-bound node engine (NodeLPStrategy)
- Portfolio exposure to A3-01 on models where the IPM finishes before the simplex
- A time limit landing in the crossover of the converged path (code reading suggests the interior point is returned as .optimal; not probed)
- No targeted package tests were run; all evidence comes from the F3 probe slot
- Concurrency/TSAN behaviour of the IPM; the baseline TSAN results were not read in detail
- Netlib beyond the 13 bundled instances; MIPLIB not used with the IPM

Further notes (not verified):

- IPM dense-column count is taken on the presolved scaled problem and skipped at &lt;= 3 kept rows (IPMWorker.swift:124-128): exactly 30% warns with presolve on, not off; a 3-row model with a 100% column gets no warning
- Conditioned around a basis-less result (IPM(none) numericalFailure on Hilbert 8) reports 'matrix coefficients span 0.0667 to 1 (ratio 15); no warnings', so it cannot see the ill-conditioning that caused the failure
- When the converged path returns the interior point after a failed crossover (A3-01), finalBasis is that failed crossover's basis (InteriorPoint.swift:305 with 209-221; code reading)
- Simplex(.primal) runs 50,000 pivots (noSolution(iterationLimit)) on 7x7 Hilbert with rhs x1e6 and on illone seed 8 at kappa2=1e10; the IPM stall path inherits this (F2 area)
- degen2 InteriorPoint(crossover: .none) duals differ by 2.3e-5 between identical runs (degenerate duals, not bitwise reproducible)
- 1 of 60 infeasible constructed models (seed 17760892575079156926) ends noSolution(iterationLimit) at 200 iterations instead of being classified; the test accepts that outcome
- Facades on the A3-01 model: Automatic() routes to the simplex (.infeasible); Portfolio(\[Simplex(.dual), InteriorPoint()]) gave .infeasible 40/40 (simplex won); Conditioned(InteriorPoint()) passes the false .optimal through

**Cycle B (oracles first).** Seven reproduced findings. B3-01 (critical): the default InteriorPoint() returns .optimal on a provably infeasible LP whose row right-hand sides differ in magnitude (row violation up to 0.23), because the primal residual is divided by 1+max|b| and crossover's own .infeasible verdict is discarded. B3-02 (critical): InteriorPoint(crossover: .none) returns .optimal with objectives off by up to \~290x when finite bounds are 1e8-1e11, because residuals and gap are measured in the shifted standard form. B3-03 (high): feasible bounded LPs with |x\*|, |y\*| or finite bounds of about 1e12 or more get .infeasibleOrUnbounded at iteration 0 in every configuration (absolute 1e12 cap). B3-04 (medium): stalls whose residual lands just above 1e-4 make the default answer .infeasibleOrUnbounded on 1-3% of badly scaled feasible LPs, contradicting README defect 10 and §2.5. B3-05 (medium): presolve basis expansion returns non-optimal bases, for the simplex too. B3-06 (low): .feasible(timeLimit) despite README §2.5. B3-07 (low): defect 7 says 'some models', but the IPM never decides infeasible versus unbounded by itself. Held: KKT optimality on more than 1,200 planted LPs including degenerate and maximization ones, edge models, defect 10 on Hilbert, the README §5 Hilbert and netlib tables (iterations and pivots exact, relative error &lt;= 1.33e-11), condition estimates within a factor of 2 of an explicit-inverse reference, the 16\*m^2 memory cap, analyzer thresholds, the dense-column warning, Conditioned bit-identical to its engine, invariances, limits and cancellation.

Claims and properties that held: 16.

Not checked:

- The package's own tests were not run with swift test --filter in this window; IllConditionedTests and CorpusTests were only read (their early returns follow an #expect that already records the failure).
- The dual ray carried by the IPM's stall-path .infeasible result was validated on only one instance (mixedscale big=1e3, delta=1e-3).
- README §5 transport-LP timing.
- Interaction with Automatic, Portfolio, Metal and BranchAndBound(engine: InteriorPoint()) on the B3-01 to B3-04 inputs.
- Concurrency (TSAN) of the IPM workers.
- The B3-01 and B3-02 inputs through the MPS or LP readers or the DSL (only CompiledLP through the public API).
- The sparse Cholesky path (m > 300) on the B3-01 to B3-03 inputs; the minimal repros are small and use the dense path.
- Dense-column performance (a documented limit).

Further notes (not verified):

- InteriorPoint(crossover: .none) .optimal points violate rows by 1.5e-6 and 3.0e-6 relative (S3 seeds 3075, 3080), above the README 1e-7 claim; on beaconfd the reported primalResidual 3.9e-12 (scaled standard form) understates an original-space violation of 2.6e-5 absolute, 1.05e-6 relative to the row's terms (F3 kkt 3000 100 30 50 S3; F3 viol beaconfd pre).
- Test laxity: InteriorPointTests.convergesWithinFortyIterations bounds the violation by 1e-5\*(1+|objective|), which allows 23 absolute on scagr7; no test covers an infeasible model with mixed rhs magnitudes (B3-01), large finite bounds (B3-02, B3-03) or a basis check after presolve expansion (B3-05).
- NodeLPStrategy's InteriorPoint node worker (about NodeLPStrategy.swift:255) returns the IPM root analysis when it is .optimal even if the root dual simplex decides otherwise; with B3-01 this could let BranchAndBound treat an infeasible root as optimal (code reading only).
- Conditioned(InteriorPoint(crossover: .none)) reports no findings on Hilbert-6 because there is no basis to analyze (basis=noBasis), so the report cannot explain the numerical failure it accompanies (info).
- The dense-column warning fires on tiny problems (a 6x6 model; 20-24 columns of 30x50 models) where the normal equations are trivially small (info, noise).
- B3-05's culprit lives in ZTronLPCore presolve and also gives non-optimal Simplex(.dual) and Simplex(.primal) bases, so it touches the simplex area too.

</details>

#### <a id="a3-01"></a>A3-01 · InteriorPoint returns .optimal on an infeasible LP (violation 0.5) and overrides its own crossover's .infeasible verdict

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B3-01](#b3-01) (cycle B)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:696,704 (primalResidual = max|rp|/(1+max|b|) &lt;= ipmResidual 1e-8 accepts an absolute residual of 0.5 at |b| = 1e8); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:209-217 (any non-optimal crossover result, .infeasible included, falls back to the interior solution with status .optimal)
- **Claim tested:** README 2.5 InteriorPoint row ('Answers .infeasibleOrUnbounded when it cannot tell the two apart'); README 4 Limits 'Results' ('Optimal ... feasible and dual feasible to 1e-7'); Sources/ZTronLPCore/Solve/Status.swift:5 (.optimal: 'An optimal solution was found and proven').
- **Observed:** min x+y s.t. x+y = 1e8, x+y = 1e8+1, x,y >= 0 (infeasible by 1). InteriorPoint() -> .optimal, objective 100000000.49999917, x = (50000000.25, 50000000.25), each row violated by 0.5. The same with crossover .none, presolve on or off, after an MPS write/read round trip, and through Conditioned(InteriorPoint()). With crossover .lite the crossover itself ends .infeasible and the strategy still returns .optimal, adding the warning 'crossover-lite ended with infeasible; returning the interior solution'. Simplex(.dual) and Automatic() -> .infeasible. Also B=1e6, delta=1e-2 (violation 5e-3) and an inequality variant (x+2y &lt;= B, x+2y >= B+delta) with violation 0.77. Portfolio(\[Simplex(.dual), InteriorPoint()]) answered .infeasible 40/40 because the simplex won.
- **Why it is wrong:** No feasible point exists. 0.5 is 5e6 times the stated 1e-7 feasibility. The right-hand sides are exact in double precision (ulp(1e8) = 1.5e-8), so this is not rounding. The package's own simplex, run inside the same solve, proved infeasibility, and that verdict was replaced by a success status.
- **Documented:** No. Defect 7 covers only infeasible-vs-unbounded indecision; nothing says an infeasible model can come back .optimal.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 tinyfacades 40 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 tinyinf
```

<details><summary>Probe output</summary>

```text
CompiledLP InteriorPoint(): optimal obj 100000000.49999917 x [50000000.24999958, 50000000.24999958] viol (bounds: 0.0, rows: 0.5000008344650269) | CompiledLP Simplex(.dual): infeasible | CompiledLP Conditioned(InteriorPoint()): optimal ... rows: 0.5000008344650269 | tinyinf lite configs: warnings ['crossover-lite ended with infeasible; returning the interior solution']
```

</details>

#### <a id="a3-02"></a>A3-02 · Default InteriorPoint() answers .infeasible on feasible bounded LPs at condition 1e8..1e10, with a dual ray that is not a Farkas certificate

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPInteriorPoint/InteriorPoint.swift:148-171 (the stall path returns the crossover's status unchecked); InteriorPoint.swift:67-69 (crossoverSimplex = Simplex(.primal, presolve: false, scaling: .none)); Sources/ZTronLPSimplex/SimplexEngine+Primal.swift:697-705 (phase 1 with no improving direction -> lastDualRay = farkasRay(from: y); return .infeasible, with no check of the ray's Farkas value)
- **Claim tested:** README 3 Risk 1 ('up to a condition number of about 1e10 the solution is recovered'); README 4 defect 8, marked fixed ('takes a small pivot before it concludes infeasible ... the interior point hands a stall to the simplex'); InteriorPoint.swift:149-152 comment ('That decides nothing about the problem ... a vertex, or a certificate'); test theInteriorPointDoesNotMistakeAStallForInfeasibility.
- **Observed:** 6x6 dense equality LP A x = A\*1, columns boxed \[-10,10], unique optimum x = 1 (witness violation 0), exact kappa1(A) = 1.64e8. InteriorPoint() -> .infeasible. The IPM stalls (8 iterations, primal residual 1.58e-6, mu 1.56e-11), and the crossover's primal simplex declares phase-1 infeasibility after 57 pivots. Its dual ray has Farkas value -9.94e-7 (wrong sign, no proof). InteriorPoint(crossover: .none) -> numericalFailure. Simplex(.dual), Automatic() and Portfolio -> optimal, distance 2.55e-9. Over 30 seeds (boxed, m=8, kappa2=1e9): .infeasible 16, .noSolution(iterationLimit) 3, optimal 11. Other cells: kappa2=1e9 9/30 (m=6), 17/30 (m=12); kappa2=1e8 1/30; kappa2=1e10 2..10/30. Hilbert order 9 with rhs x1e6 is also .infeasible. Simplex(.primal) alone gives the same false verdict on the illone model (shared cause, F2 area).
- **Why it is wrong:** x = 1 satisfies every row and bound exactly and is the optimum. .infeasible is therefore a false verdict with an invalid certificate, inside the condition range README says is recovered and in the answer class defect 8 says is fixed.
- **Documented:** No. Defect 8 and Risk 1 state the opposite.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 illone 6 1e8 1 0 0 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 illfree 8 1e9 1 30
```

<details><summary>Probe output</summary>

```text
InteriorPoint(): infeasible dist 1.10e+01 ipm-it 8 pres 1.58e-06 mu 1.56e-11 xover infeasible it 57 xover dualRay farkas -9.94e-07 | Simplex(.dual): optimal dist 2.55e-09 | Automatic(): optimal dist 2.55e-09 | illfree tally: boxed IPM() infeasible 16, boxed IPM() noSolution(iterationLimit) 3, boxed IPM() optimal 11
```

</details>

#### <a id="b3-01"></a>B3-01 · InteriorPoint() reports .optimal on an infeasible LP and discards crossover's own .infeasible verdict

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A3-01](#a3-01) (cycle A)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:657,696 (primal residual divided by 1+max|b| over all rows, so a 1e-3 violation on a row with rhs 1 counts as \~1e-9 next to a row with rhs 1e6); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:208-217 (a non-optimal crossover status becomes a warning and the interior point is returned as .optimal)
- **Claim tested:** README §2.5 InteriorPoint: 'Answers `.infeasibleOrUnbounded` when it cannot tell the two apart'; README §4 Limits/Results: 'Optimal' means 'feasible and dual feasible to 1e-7'; Tolerances.primalFeasibility = 1e-7.
- **Observed:** Infeasible 3x4 LP: min x0+x1+x2+x3; r0: x0+x1 >= big; r1: x2+x3 >= 1; r2: x2+2x3 &lt;= 1-delta; x >= 0 (Farkas y1=+1, y2=-1 gives A^T y = (0,0,0,-1) &lt;= 0 and y^T b = delta > 0). big=1e6, delta=1e-3: all four IPM configurations, including the default InteriorPoint(), return .optimal obj=1000001.0030269028 after 8 iterations with reported primal residual 1.945e-9; an independent KKT check finds a row violation of 1.905e-3; crossover-lite itself ended .infeasible and only a warning remains. big=1e6, delta=1e-5: violation 1.24e-3; big=1e9: violation 0.23; big=1e3, delta=1e-5: violation 6.6e-6. Simplex(.dual) and Simplex(.primal) answer .infeasible in 2 iterations in every case.
- **Why it is wrong:** A provably infeasible model gets a success status and a point violating a row by up to 0.23, four to six orders of magnitude above the 1e-7 feasibility claim; the crossover proved infeasibility and its verdict was discarded.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 mixedscale
```

<details><summary>Probe output</summary>

```text
verification/cycle-B/F3-raw/mixedscale.txt: 'BAD infeas big=1000000.0 delta=0.001 ipm-lite optimal obj=1000001.0030269028 expect=infeasible it=8 mu=4.497e-04 pr=1.945e-09 xo=infeasible/0 | pviol=1.905e-03'; warning 'crossover-lite ended with infeasible; returning the interior solution'; dual and primal simplex: infeasible, it=2
```

</details>

#### <a id="b3-02"></a>B3-02 · InteriorPoint(crossover: .none) reports .optimal with a grossly wrong objective (up to \~290x) when finite variable bounds are large

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A3-05](#a3-05), [A3-06](#a3-06): same convergence test of InteriorPoint(crossover: .none), IPMWorker.swift:687-706
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:687-698 (gap divided by 1+|c'^T x'| of the shifted form, \~B when x = l + x' with l = -B); Sources/ZTronLPInteriorPoint/IPMWorker.swift:116-122,657,696 (b' = b - A\*l; primal residual divided by 1+max|b'|, \~B)
- **Claim tested:** README §2.5 offers crossover .none as a supported mode whose failure on hard problems is documented as .numericalFailure (README §4 defect 10); README §4 Results: 'Optimal' means feasible and dual feasible to 1e-7; Tolerances.ipmResidual 1e-8, 'Relative primal, dual and gap residuals'.
- **Observed:** min x+y s.t. x+2y >= 1, 2x+y >= 1, -B &lt;= x,y &lt;= B (optimum 2/3): .optimal with objective 0.6666857 (B=1e4), 0.66857 (1e6), 0.8575 (1e8), 2.5745 (1e9), 19.745 (1e10), 191.45 (1e11), each in 7 iterations with reported primal residual 2.3e-9 and finalMu up to 48.6. Planted family (20 seeds, m=20, n=30, nonbinding bounds +-B): B=1e8 1/20 wrong (-3.898 vs -6.237, row violation 0.37), B=1e9 16/20 wrong (16.37 vs 2.53), B=1e10 20/20 wrong (47.95 vs 2.53), B=1e11 20/20 wrong (209.7 vs 2.28, row violation up to 43.5). The default .lite and Simplex(.dual) are correct for every B &lt;= 1e11.
- **Why it is wrong:** A success status, no warning, and an objective off by up to a factor of \~290 (in the planted family also a primal-infeasible point): the convergence test is relative to the shifted standard form, whose magnitudes are \~B, so a duality gap of 190 passes as 1e-8.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 bigbox && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 hugebounds 1 20 1e6 1e7 1e8 1e9 1e10 1e11 1e12 1e15
```

<details><summary>Probe output</summary>

```text
F3-raw/bigbox.txt: 'BAD bigbox B=100000000000.0 ipm-none optimal obj=191.45196533203125 expect=optimal/0.6666666666666666 it=7 mu=4.861e+01 pr=2.277e-09'; F3-raw/hugebounds.txt: 'bound B=100000000000.0: dual:optimal 20, ipm-lite:optimal 20, ipm-none:optimal-WRONGOBJ 20; seed=5 ipm-none obj=209.72723729368192 known=2.2829866110632313 pviol=1.021e+01'
```

</details>

#### <a id="a3-03"></a>A3-03 · .infeasibleOrUnbounded on feasible bounded ill-conditioned LPs (the defect-8 answer class, documented as fixed) when the absolute mu gate fires

- **Severity:** high (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [B3-04](#b3-04): same stall and mu gates, IPMWorker.swift:720-741
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:720-731 (absolute 'mu &lt; 1e-10', then 'worst > stallCeiling' (1e-4, line 866) -> .infeasibleOrUnbounded); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:146-147 (returned without a simplex)
- **Claim tested:** README 4 defect 8 ('Fixed in this version ... infeasibleOrUnbounded from the interior point ... the interior point hands a stall to the simplex'); README 5 note under the ill-conditioned table; IPMWorker.swift:721-726 comment ('calling the problem infeasible would be wrong').
- **Observed:** Hilbert order 6, equalities with free columns, objective x1e8, unique optimum x = 1 (witness violation 0). InteriorPoint(), InteriorPoint(crossover: .none) and presolve off all return .infeasibleOrUnbounded after 13 iterations: primal residual 5.35e-2, dual 4.2e-12, mu 3.38e-11, no crossover. Simplex(.dual), Simplex(.primal) and Automatic() -> optimal, distance 5.8e-10. With objective x1e6: orders 6, 7, 9, 10. With x1e8: orders 6..10. Random 8x8 free-column systems at kappa2=1e7 with costs x1e6: 10/10. Unscaled costs: kappa2=1e6 3/30, kappa2=1e8 5..11/30, kappa2=1e9 (m=8) 10/30. A well-conditioned LP at objective x1e8 is solved (objscale: 60/60).
- **Why it is wrong:** The models are feasible with a unique optimum, so 'infeasible or unbounded' is false. This is exactly the stall the defect-8 fix says is now handed to the simplex. The mu &lt; 1e-10 gate is absolute, so it fires before the primal residual has come down when costs are large or convergence is slow. Anything above stallCeiling 1e-4 is then classified without consulting the simplex.
- **Documented:** Described wrongly: defect 8 says this answer class is fixed for the interior point.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 hone 6 equalityFree 1e8 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 10 1e6 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 illfree 8 1e7 1e6 10
```

<details><summary>Probe output</summary>

```text
InteriorPoint(): infeasibleOrUnbounded dist nan obj - 0.000 s ipm-it 13 pres 5.35e-02 dres 4.20e-12 mu 3.38e-11 xover nil | Simplex(.dual): optimal dist 5.79e-10 | illfree 8 1e9 1 30: free IPM() infeasibleOrUnbounded 10, free IPM() optimal 20
```

</details>

#### <a id="b3-03"></a>B3-03 · Feasible bounded LPs with large solution, dual or bound magnitudes get .infeasibleOrUnbounded at iteration 0 in every IPM configuration, including the default

- **Severity:** high (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:714-718 (if xNorm > 1e12 || yNorm > 1e12 || !mu.isFinite then .infeasibleOrUnbounded; absolute, evaluated before the first step); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:146-147
- **Claim tested:** README §2.5 InteriorPoint: 'Answers `.infeasibleOrUnbounded` when it cannot tell the two apart', i.e. only for models that are infeasible or unbounded.
- **Observed:** min -x-y, x+2y &lt;= B, 2x+y &lt;= B, x,y >= 0 (x\* = B/3): B=1e13 and 1e14 give .infeasibleOrUnbounded at it=0 (mu 1.97e12) in all four IPM configurations; B &lt;= 3e12 optimal. min Cx+Cy, x+2y >= 1, 2x+y >= 1 (y\* = C/3): C >= 3e12 gives .infeasibleOrUnbounded at it=0; C = 1e10 optimal. The 2-variable model with optimum 2/3 and bounds +-1e12: lite and none .infeasibleOrUnbounded at it=0. Planted family with nonbinding bounds +-1e12 and +-1e15: 20/20 .infeasibleOrUnbounded at it=0 for lite and none. Simplex(.dual) correct in every case.
- **Why it is wrong:** The models are feasible and bounded with closed-form optima that the simplex reaches in 2 iterations; the starting point alone trips an absolute 1e12 norm cap, because scaling normalizes neither b, c nor the bounds.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 edge && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 bigbox
```

<details><summary>Probe output</summary>

```text
F3-raw/edge.txt: 'BAD large-x B=10000000000000.0 ipm-lite infOrUnb obj=nil expect=optimal/-6666666666666.667 it=0 mu=1.965e+12'; 'BAD large-c C=3000000000000.0 ipm-lite infOrUnb obj=nil expect=optimal/2000000000000.0 it=0 mu=5.896e+11'; F3-raw/bigbox.txt: 'BAD bigbox B=1000000000000.0 ipm-lite infOrUnb it=0 mu=3.805e+11'; F3-raw/hugebounds.txt: 'bound B=1000000000000.0: dual:optimal 20, ipm-lite:infOrUnb 20, ipm-none:infOrUnb 20'
```

</details>

#### <a id="a3-04"></a>A3-04 · InteriorPoint returns .feasible(stoppedBy: .timeLimit) when a limit lands in the stalled path's crossover

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B3-06](#b3-06) (cycle B)
- **Location:** Sources/ZTronLPInteriorPoint/InteriorPoint.swift:163-171 (the stalled path returns the crossover's SimplexAnalysis base as is) with Sources/ZTronLPSimplex/SimplexEngine.swift:95-107 (a stopped simplex with a primal-feasible iterate reports .feasible(stoppedBy:))
- **Claim tested:** README 2.5 InteriorPoint row: 'It never returns .feasible: a limit or a cancellation gives .noSolution.'
- **Observed:** The model is 68x908 (a Hilbert-8 equality block plus a 30x30 assignment with tied costs). Unlimited, it stalls at 1.1 ms and the crossover finishes (141 pivots, optimal 12.606). With SolveContext.timeLimit 1.9..2.5 ms, 10 of 31 runs return .feasible(stoppedBy: .timeLimit) at objective 20.606 with a feasible point (violation 9e-10). Limits that land in the IPM give .noSolution(timeLimit). Cancellation at the stall gives .noSolution(cancelled), 5/5.
- **Why it is wrong:** The documented contract excludes .feasible for this strategy, so code written against it meets a status the docs say cannot occur. The point is feasible but not optimal.
- **Documented:** No.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 stallcancel 8 30 30 (timing-dependent; repeated: 10 of 31 runs in the 1.9..2.5 ms window)
```

<details><summary>Probe output</summary>

```text
timeLimit 1.9..2.5 ms: feasible(stoppedBy: timeLimit), objective 20.606, violation 9e-10 in 10/31 runs; free run: stalled at 1.1 ms, crossover 141 pivots, optimal 12.606; cancel-on-stall: noSolution(cancelled) 5/5
```

</details>

#### <a id="a3-05"></a>A3-05 · InteriorPoint(crossover: .none) .optimal points violate rows by up to 2.6e-5 while reporting primalResidual 3.9e-12

- **Severity:** medium (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A3-06](#a3-06), [B3-02](#b3-02): same convergence test of InteriorPoint(crossover: .none), IPMWorker.swift:687-706
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:696-706 (the scaled relative residual is the only acceptance test; there is no unscaled check after postsolve); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:198-202 (crossover .none returns the interior point as is); Tests/ZTronLPInteriorPointTests/InteriorPointTests.swift:42
- **Claim tested:** README 4 Limits 'Results': 'feasible and dual feasible to 1e-7'; InteriorPointAnalysis.primalResidual is reported as the solve's residual (NetlibInteriorPointTests checks it &lt;= 1e-8).
- **Observed:** beaconfd: .optimal, but row 51 (an equality with rhs 0) has activity 2.62e-5 (maxViolation rows 2.62e-5, max |rhs| 1.89e3), and the reported primalResidual is 3.91e-12. scagr7 violates by 2.8e-7. adlittle's 6.5e-8 is within tolerance. Every objective matches its published optimum.
- **Why it is wrong:** 2.6e-5 is 260 times the stated 1e-7. The reported residual is measured on the scaled, presolved working problem relative to 1+max|b|, so it hides the violation in the original rows. The netlib test meant to catch this allows 1e-5\*(1+|obj|), which is 0.34 on beaconfd and 23 on scagr7.
- **Documented:** No.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 viol beaconfd && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 netlib 3
```

<details><summary>Probe output</summary>

```text
beaconfd IPM(none): optimal maxViolation bounds 0.00e+00 rows 2.62e-05; worst row 51 bounds [0.0, 0.0] activity 2.6164713080145674e-05; max |rhs| 1.89e+03; reported primalResidual 3.91e-12
```

</details>

#### <a id="a3-06"></a>A3-06 · Defect 10 described wrongly: InteriorPoint(crossover: .none) also returns .optimal far from the unique optimum at condition \~1e6, with no warning

- **Severity:** medium (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A3-05](#a3-05), [B3-02](#b3-02): same convergence test of InteriorPoint(crossover: .none), IPMWorker.swift:687-706
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:697-698,704 (dual residual and gap relative to 1+max|c| and 1+|pobj|); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:198-202 (crossover .none: the interior point is returned with no conditioning check)
- **Claim tested:** README 4 defect 10 ('from a condition number of about 1e6 on a dense system its residuals stall above the tolerance and the result is .numericalFailure'); defect 9 ('The answer carries a warning that the optimal basis is ill-conditioned', for condition > 1e11 only).
- **Observed:** Hilbert order 5 (kappa1 9.4e5), equalities with free columns, unscaled: IPM(none) -> .optimal at distance 4.52e-3 from x = 1 (objective error 4e-18, row violation 1.4e-8); IPM() gets 5.8e-12. With objective x1e-6, covering and packing at orders 5..7: .optimal at distance 0.21..0.40, relative objective error 0.8e-9..2.7e-9, violation 0. At order 12, covering, unscaled: distance 0.23. The only warning is the dense-column one. There is no conditioning warning and no basis for Conditioned to analyze.
- **Why it is wrong:** At condition \~1e6 the docs promise the solution (README 5: 6e-12 at order 5 for every engine) or .numericalFailure. Here a success status comes with a point 4.5e-3..0.4 from the only optimum, and nothing in the result says so. The acceptance test scales the dual residual by 1+max|c| and the gap by 1+|pobj|, so with small costs it is effectively absolute.
- **Documented:** Described wrongly: defect 10 says the result is .numericalFailure.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 5 9 1e-6 1 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 12
```

<details><summary>Probe output</summary>

```text
order 5 kappa1 9.44e+05 covering IPM(none): optimal it=7 dist=3.98e-01 objErr=7.75e-10 ... nwarn=1 viol=0.00e+00/0.00e+00 | order 5 kappa1 9.44e+05 equalityFree IPM(none): optimal it=5 dist=4.52e-03 objErr=4.18e-18 ... viol=0.00e+00/1.36e-08 | equalityFree IPM(): optimal it=5 dist=5.77e-12
```

</details>

#### <a id="a3-07"></a>A3-07 · Presolved final bases (IPM crossover and simplex) are not optimal when a singleton row pins a column at its own bound

- **Severity:** medium (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-02](#a1-02) (cycle A), [B3-05](#b3-05) (cycle B)
- **Location:** Sources/ZTronLPCore/Model/Presolve.swift:432-448 (expandBasis, singletonRow case: when the column is at the tightened bound or .fixed it is made basic and the row's logical nonbasic, without consulting the reduced cost's sign)
- **Claim tested:** InteriorPoint.Crossover.lite doc ('return a vertex with its basis'); InteriorPointAnalysis.crossover doc ('its basis is what branch and bound reuses'); SimplexAnalysis.basis ('Reusable as WarmStart.basis'); README 2.2 (postsolve maps a basis back).
- **Observed:** In instance k=56 of 'kkt 60 7 60 120' (28x22), row 13 is 2.737\*x18 &lt;= 0 with x18 >= 0. Presolve removes the row and fixes x18 = 0. The reported d18 is +7.94 and dual(row 13) is 0. InteriorPoint().finalBasis has x18 basic and row 13's logical atUpper. With x18 basic, y13 must be +2.9 on an at-upper &lt;= row, which is the wrong sign. The basis vertex equals the returned x to 1e-14 but is dual infeasible by 2.9..77. Warm primal and dual simplex from it need 1..5 pivots on 4/60 instances, while every no-presolve basis needs 0. Simplex(.dual) and Simplex(.primal) with presolve return the same bases (shared cause).
- **Why it is wrong:** A basis returned as the optimal basis of the returned vertex must be dual feasible. This one is not, so warm starts and branch-and-bound reuse start from a non-optimal basis, and anything that reads it as an optimality certificate is misled.
- **Documented:** No.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 kkt 60 7 60 120 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 basis && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 basisrow 56 13
```

<details><summary>Probe output</summary>

```text
row 13: a[18] = 2.736836914997054; column bounds [0.0, inf] kept: false x* = 0.0 | basis status col 18: basic; returned x 0.0; reported d 7.935870598638149 | row 13 logical status atUpper, reported dual 0.0 | basisCheck dviol 2.9..77, warm start 1..5 pivots on 4/60
```

</details>

#### <a id="a3-08"></a>A3-08 · The interior-point tests cannot catch A3-01, A3-02, A3-03, A3-05 or A3-06

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [B7-04](#b7-04): interior-point tests that cannot fail
- **Location:** Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:131-151; Tests/ZTronLPInteriorPointTests/InteriorPointTests.swift:42,165-174
- **Claim tested:** Tests as claims: IllConditionedTests.theInteriorPointDoesNotMistakeAStallForInfeasibility ('without it the result is a numerical failure that says what happened'); InteriorPointTests.infeasibleAndUnboundedAreReportedWithoutLooping; NetlibInteriorPointTests.convergesWithinFortyIterations.
- **Observed:** (1) IllConditionedTests.swift:145-146 accepts .optimal from InteriorPoint(crossover: .none) without checking the point, so A3-06's 0.2..0.4 distances pass. (2) Every IllConditioned test uses only the Hilbert family with rhs = H\*1 and unit-scale costs, so A3-02 (random condition 1e8..1e10) and A3-03 (scaled costs, free columns) are never exercised. (3) InteriorPointTests.swift:168 accepts .noSolution(.iterationLimit) and .infeasible. At :169, 'iterations &lt;= 200' is vacuous because 200 is the default maxIterations, so a run to the cap passes. No test uses an infeasible model with a large rhs (A3-01). (4) InteriorPointTests.swift:42 allows a violation of 1e-5\*(1+|obj|) against the README's 1e-7 (A3-05).
- **Why it is wrong:** Each test names a property it does not check: the documented failure mode can occur and the test still passes.
- **Documented:** No.

**Reproduction**

```sh
Read the cited lines. The behaviours they let through are reproduced by the A3-01, A3-02, A3-03, A3-05 and A3-06 repros. The tests themselves were not run.
```

<details><summary>Probe output</summary>

```text
IllConditionedTests.swift:145-146 'case .optimal: break'; InteriorPointTests.swift:169 '#expect(first.iterations <= 200)'; InteriorPointTests.swift:42 'violation.rows <= 1e-5 * (1 + abs(objective))'
```

</details>

#### <a id="b3-04"></a>B3-04 · The 1e-4 stall ceiling makes the default InteriorPoint() answer .infeasibleOrUnbounded for feasible bounded badly scaled LPs instead of letting the simplex finish

- **Severity:** medium (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A3-03](#a3-03): same stall and mu gates, IPMWorker.swift:720-741
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:720-741 and :866 (stallCeiling 1e-4: worst > stallCeiling gives .infeasibleOrUnbounded); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:146-147 (returned without trying the simplex)
- **Claim tested:** README §2.5: 'When its residuals stall close to a solution, an ill-conditioned problem, the simplex finishes from the last iterate (`crossover: .lite`)'; README §4 defect 10: 'The default, with crossover, is not affected.'
- **Observed:** Planted feasible bounded LPs with row/column scales 10^+-3 (m=30, n=50, seeds 3000-3099): InteriorPoint() .infeasibleOrUnbounded 1/100 (seed 3050) and InteriorPoint(presolve: false) 3/100 (seeds 3023, 3043, 3069), each with mu &lt; 1e-10, dual residual &lt;= 6e-14 and primal residual 1.17e-4 to 2.28e-4; simplex 200/200 optimal. Seed 3050: presolve on gives .infeasibleOrUnbounded at it=46 with primal residual 1.319e-4; presolve off stalls at 7.19e-5 and the simplex finishes at the known optimum 785976.99035; scaling .none stalls, then optimal.
- **Why it is wrong:** The iterate is at the optimum up to the primal residual (mu 5e-11, dual residual 6e-15); a residual of 1.3e-4 instead of &lt; 1e-4 turns the documented simplex finish into a claim that the model is infeasible or unbounded.
- **Documented:** HANDBOOK decision 17 states the 1e-4 boundary, but README §4 defect 10 says the default with crossover is not affected and README §2.5 promises the simplex finish for stalls near a solution.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 kkt 3000 100 30 50 S3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 one 3050 30 50 S3
```

<details><summary>Probe output</summary>

```text
F3-raw/kkt_S3.txt: 'TALLY ipm-lite: infOrUnb 1, optimal 99'; 'TALLY ipm-lite-nopre: infOrUnb 3, optimal 97'; 'seed=3050 ipm-lite infOrUnb obj=nil known=785976.9903495781 it=46 mu=5.061e-11 pr=1.319e-04 dr=6.198e-15'; F3-raw/one_3050.txt: 'presolve=false ... -> optimal obj=785976.9903495782 it=47 pr=7.190e-05' with the warning 'the interior point stalled ... the simplex finished from its last iterate'
```

</details>

#### <a id="b3-05"></a>B3-05 · Presolve basis expansion returns a non-optimal basis (a basic column with nonzero reduced cost) after a singleton row

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A1-02](#a1-02) (cycle A), [A3-07](#a3-07) (cycle A)
- **Location:** Sources/ZTronLPCore/Model/Presolve.swift:432-446 (expandBasis, singleton-row case: when the tightened bound meets the column's own opposite bound (current == .fixed) the column is made basic and the logical nonbasic regardless of the reduced-cost sign)
- **Claim tested:** The basis of an .optimal result (InteriorPointAnalysis.finalBasis, SimplexAnalysis.basis) is an optimal basis for the returned point: README §2.5 crossover 'to a vertex'; it is what warm starts and the conditioning analyzer and Conditioned (README §2.6) use.
- **Observed:** min -x0+x1+2x2; r0: -x0 &lt;= 1 (singleton); r1: x0+x1+x2 >= 1; r2: x1-x2 &lt;= 0.5; x0 &lt;= -1; x1,x2 >= 0. InteriorPoint(), Simplex(.dual) and Simplex(.primal) with presolve on: optimal, obj 3.75, x = (-1, 1.25, 0.75), but status \[basic, basic, basic, atUpper, atLower, atUpper] with reduced costs \[-2.5, 0, 0, 0, 1.5, -0.5]: x0 basic with reduced cost -2.5; independent basis check dual infeasibility 0.833; a warm start of Simplex(presolve: false) from it needs 1 pivot (0 from the presolve-off basis); the analyzer's condition estimate is 4 instead of 2. Sparse planted LPs m=350 n=500: non-optimal basis for ipm-lite 14/15 and 10/15, dual 13/15 and 11/15, primal 13/15 and 10/15; 0/30 with presolve off; points, duals and objectives correct throughout.
- **Why it is wrong:** A basis whose basic column has a nonzero reduced cost is not optimal; warm starts, condition analysis and the Conditioned report then work on a basis that does not carry the optimum.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F3 presolvebasis && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 kkt 8000 15 350 500 q
```

<details><summary>Probe output</summary>

```text
F3-raw/presolvebasis.txt: 'ipm-lite optimal obj=3.75 x=[-1.0, 1.25, 0.75] status=[basic, basic, basic, atUpper, atLower, atUpper] ... basis dualInf=8.333e-01 <-- basis not optimal; analyzer on this basis: est=4.000e+00' against presolve off 'dualInf=0.000e+00 ... est=2.000e+00'; F3-raw/presolvebasis2.txt: warm-start iterations 1 vs 0; F3-raw/kkt_sparse.txt: BASIS-FAIL ipm-lite 14/15
```

</details>

#### <a id="a3-09"></a>A3-09 · Defect 7 understates: the interior point itself never returns .infeasible or .unbounded

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B3-07](#b3-07) (cycle B)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:712-731 (.infeasibleOrUnbounded is the only failure verdict); Sources/ZTronLPInteriorPoint/InteriorPoint.swift:146-147
- **Claim tested:** README 4 defect 7: 'it answers .infeasibleOrUnbounded for some models'.
- **Observed:** 60 infeasible and 60 unbounded constructed models x 4 configurations (lite/none x presolve on/off), plus 3 textbook models. Unbounded 60/60 and textbook -> .infeasibleOrUnbounded. Infeasible 59/60 -> .infeasibleOrUnbounded and 1/60 -> .noSolution(.iterationLimit) after 200 iterations (mu 4e-8, primal residual 8e-3). Never .infeasible or .unbounded and never a certificate; only presolve or the stall->simplex path ever decides.
- **Why it is wrong:** 'For some models' implies the method usually tells the two apart. It never does: the worker has no other failure outcome.
- **Documented:** Described wrongly ('for some models').

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F3 infunb 60 404
```

<details><summary>Probe output</summary>

```text
per config: 'unbounded <cfg> infeasibleOrUnbounded: 60'; 'infeasible <cfg> infeasibleOrUnbounded: 59'; 'infeasible <cfg> noSolution(iterationLimit): 1 e.g. seed 17760892575079156926 ... iters 200 ... pres 8e-3'
```

</details>

#### <a id="a3-10"></a>A3-10 · README 5 'Answers with a warning' column omits the dense-column warning every InteriorPoint() answer carries from order 4

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-05](#a2-05) (cycle A), [A7-02](#a7-02) (cycle A), [B7-03](#b7-03) (cycle B)
- **Location:** README.md:611-622 against Sources/ZTronLPInteriorPoint/IPMWorker.swift:638-642
- **Claim tested:** README 5 ill-conditioned table: order 4 '0 of 12', order 5 '3 of 12', order 6 '4 of 12'; 'The warnings at orders 5 and 6 are the interior point's'.
- **Observed:** From order 4, every InteriorPoint() answer carries 'n column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)'. IPM() alone gives 4 of 4 at orders 4..7. Only the stall warnings match the table (3 at order 5, 4 at order 6).
- **Why it is wrong:** The column under-counts the warnings a user sees. Minor.
- **Documented:** The table itself is the claim.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 hilbert 3 12
```

<details><summary>Probe output</summary>

```text
order 5: IPM() answers with a warning: 4 of 4 (likewise orders 4, 6, 7)
```

</details>

#### <a id="b3-06"></a>B3-06 · InteriorPoint() returns .feasible(stoppedBy: .timeLimit) when the time limit fires in the simplex that finishes a stall

- **Severity:** low (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A3-04](#a3-04) (cycle A)
- **Location:** Sources/ZTronLPInteriorPoint/InteriorPoint.swift:163-171 (the stall path returns finished.base whatever its status)
- **Claim tested:** README §2.5 InteriorPoint: 'It never returns `.feasible`: a limit or a cancellation gives `.noSolution`.'
- **Observed:** Spread-3 planted LP 300x500 that stalls (seeds 3 and 4): time limits of 0.026-0.047 s give status .feasible(timeLimit) with crossover .feasible(timeLimit) after 115-451 pivots; for example a limit of 0.028 s gives objective 82474.26 against the optimum 82472.74, a feasible point (violation 3.8e-13) and bound nil. Reproduced in two runs; the window depends on timing.
- **Why it is wrong:** A status the documented contract excludes; code written to the documented status set of InteriorPoint does not expect it.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 stalllimit 1 300 500 3 5 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 stalllimit 3 300 500 3 1
```

<details><summary>Probe output</summary>

```text
F3-raw/stalllimit.txt: 'limit=0.026 -> feasible(timeLimit) it=38 xo=feasible(timeLimit)/115 <-- .feasible from InteriorPoint' (also at 0.029, 0.031, 0.034, 0.036)
```

</details>

#### <a id="b3-07"></a>B3-07 · README defect 7 understates how often the interior point leaves infeasible versus unbounded undecided: on its own it never decides

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A3-09](#a3-09) (cycle A)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:712-719 (divergence to .infeasibleOrUnbounded is the only terminal verdict); README.md:449-451
- **Claim tested:** README §4 defect 7: 'it answers `.infeasibleOrUnbounded` for some models; a simplex solve of the same model decides it'; README §2.5: 'when it cannot tell the two apart'.
- **Observed:** 100/100 infeasible models (Farkas margin 0.5) and 100/100 unbounded models (planted ray), m=20 n=30: all four IPM configurations answer .infeasibleOrUnbounded every time; also 60/60 at Farkas margins 1e-3, 1e-6 and 1e-9. It returns .infeasible or .unbounded only when presolve decides or a stall below 1e-4 hands the model to the simplex. Simplex(.dual) and Simplex(.primal): exact status 100% with valid Farkas rays (own checker).
- **Why it is wrong:** 'Some models' describes the normal case: the IPM outcome has no infeasible or unbounded verdict at all, so every infeasible or unbounded model that presolve does not decide comes back undecided.
- **Documented:** README §4 defect 7 documents the behaviour but says 'for some models'; in these families it is every model that presolve does not decide.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F3 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 status 1 100 20 30 infeasible && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F3 status 1 100 20 30 unbounded
```

<details><summary>Probe output</summary>

```text
F3-raw/st_infeasible.txt: 'TALLY ipm-lite: infOrUnb 100', 'TALLY ipm-none-nopre: infOrUnb 100', 'TALLY dual: infeasible 100', 'TALLY dual-farkas: valid 100'; F3-raw/st_unbounded.txt: 'TALLY ipm-lite: infOrUnb 100', 'TALLY dual: unbounded 100'
```

</details>

### <a id="f4-bnb"></a>F4 Branch and bound

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** 9,240 runs on 840 random small MILPs, checked against exhaustive enumeration with an independent LP for the continuous part, found nothing wrong: every status, objective, point and bound was correct, across 11 configurations. Limits, determinism at a fixed thread count and all 10 MIPLIB 3 instances (exact optima, both node engines) also held. Targeted constructions broke three correctness paths, each giving a false .optimal. (1) An LP point whose integer columns sit within the 1e-6 integrality tolerance is rounded and returned without re-checking the rows: a big-M model reports 0.50005 at an infeasible point, against a true optimum of 100.5. (2) Heuristic incumbents pass a feasibility test relative to the row bound: a knapsack with rhs 29,999,999 reports 10,000,000, violating its row by 1. (3) objectiveStep reads a cost of 1e-9 as an integral 0: optimal 1 against 0.75. Two paths misreport the bound and gap. A search that completes after pruning by the gap sets bound = incumbent and gap = 0 (3% off with Gap 0.05). A stop during root expansion drops the root node (feasible, bound = incumbent, gap 0, 14% off). Four low items: determinism depends on the thread count, the published 'LP pivots' include estimates, one memory test is weak, and bound events can arrive out of order. One info item on the .infeasibleOrUnbounded status. Log: verification/cycle-A/F4-bnb.md; probes: verification/probes/cycle-A/Slots/F4/.

Claims and properties that held: 19.

Not checked:

- Metal batchedActivity screening of rounding batches: every probe ran with SolveContext.metal = .off.
- BranchAndBound's own bound-only presolve cannot be switched off through the public API; 'presolve off' toggled only the engine flag (Simplex/InteriorPoint presolve: false), which affects the IPM root and the root analysis, not the node SimplexEngine.
- The node-LP path 'fails three times -> .numericalFailure' (rule L5): Simplex(maxIterations:) stops the root first, so it could not be triggered from outside; L5LimitRetryTests in the package cover it.
- Exact accounting of open-node bytes against memoryBudgetBytes: openBytes is internal; only status behaviour was checked.
- A debug build (assertions enabled) of the enumeration batches; all probe runs used the release build.
- Custom NodeLPStrategy conformers, and InteriorPoint as node engine on the full MIPLIB set (only P and D were run on it).
- TSAN was not re-run by this agent; the baseline result was used.
- Devices other than this M3 Mac; models larger than the MIPLIB 3 set.

Further notes (not verified):

- low doc: SolutionAnalysis.bound 'Proven bound; equals objectiveValue when optimal' (Sources/ZTronLPCore/Solve/Analysis.swift:22) is false for a B&B .optimal ended by gapReached, e.g. Gap(rel 0.01) seed 15: obj 3650.05, bound 3675.06 (F4 gaploose).
- low test-tolerance: the MIPLIB B&B test accepts 1e-4 relative error (CorpusTests.swift:135-136), i.e. +-120 on flugpl, though both engines reach the reference to 3.6e-16; a wrong answer within one objective step on flugpl/egout would pass.
- info: the 'lp' incumbent path reports the LP objective rather than c.x of the rounded point (0.50005 vs 0.5 in A4-01); harmless when rounding moves nothing, wrong otherwise.
- info: debug builds skip stein45/lseu/enigma/mod008 (CorpusTests.swift:125) by returning, with no known issue recorded; HANDBOOK documents the reduced debug corpus, so this is not a finding.

**Cycle B (oracles first).** Branch and bound was checked against independent oracles: - exhaustive enumeration, with vertex enumeration for continuous parts, on 2,400 random small MILPs x 13 configurations plus 240 harder ones; - 897 models with an unbounded relaxation, and hand-built edge cases; - the published MIPLIB 3 optima (20/20 solved with both simplex node engines); - node, time and memory limits, determinism, and tree and event invariants.  The random corpus passed. Targeted adversarial models found two critical defects with one root cause. When the integer columns of an LP solution are within 1e-6 of integral, expand() rounds them and offers the point as the incumbent with the LP objective, without a feasibility check or an objective recompute (TreeSearch.swift:200-203). - With a big-M row this returns .optimal at an infeasible point (row violation 0.4). - With integral costs, the inflated incumbent objective makes the objective-step cutoff prune the true optimum. .optimal then comes back a full unit below the optimum, even with Gap(0,0) and from Automatic.  When the objective step is 0, a third problem appears. Nodes discarded against the gap-slack cutoff never reach SearchTree.prunedBound, and the .complete path overwrites the bound with the incumbent. The reported 'proven' bound then lies below the true optimum with gap 0. This shows on the package's own InstanceGenerator.randomMILP with non-integral data, and the bound is 10.8% below the optimum under Gap(relative: 0.2).  Rounding and diving accept points with an unscaled 1e-7\*(1+|rhs|) test, which gives .optimal above the solver's own LP relaxation on badly scaled rows. The package's bound-validity test cannot see the bound defect, because its instance has integral costs.  Lesser issues: - deterministic results differ between threads=1 and threads>=2; - the bound doc comment contradicts the gap semantics; - a nodeLimit equal to the needed node count reports .feasible; - lpIterations counts strong-branching probes synthetically.  These held: MIPLIB reference values, limits, determinism for a fixed thread count, detection of infeasible and unbounded models, and event ordering. The Thread Sanitizer baseline reported no data races.

Claims and properties that held: 13.

Not checked:

- Cancellation latency and Task cancellation paths, beyond the package's own liveness tests.
- Resident memory against the memoryBudgetBytes accounting; only the status behaviour was checked.
- Whether the .gapReached close path, as opposed to .complete, can also report an invalid bound.
- Node LPs that become unbounded after a bounded root, and the 'LP failed three times leads to numericalFailure' path (risk 15).
- The InteriorPoint node strategy, beyond the random-model configurations and the time-limit runs.
- The Metal rounding-batch path (MetalPolicy, risk 14).
- The README §5 timings: the machine was loaded 10 to 70 times over during the runs.
- The full test suite, which was not permitted; only probes and the baseline logs were used.

Further notes (not verified):

- info: In a debug build, the MIPLIB branch-and-bound corpus test returns early for slow instances unless ZTRONLP\_SLOW\_TESTS=1. This is documented in Tests/ZTronLPIntegrationTests/CorpusTests.swift:7-12, and the release run covers those instances.
- info: In near-integral families, objectiveValue often differs from objective(at: primal) by about 1e-5 (385 cases in nearint 1..1500). The root cause is the same as B4-01 and B4-02: the LP objective is kept for a rounded point.
- info: stein45 took 58.6 s (primal) and 49.6 s (dual), against 16 to 20 s in README §5, under load averages of 89 to 541 on 8 cores. The difference cannot be attributed to the package, so it is not reported as a false claim.

</details>

#### <a id="a4-01"></a>A4-01 · An LP-integral node solution is rounded and accepted as incumbent without re-checking feasibility or recomputing the objective: big-M model reported optimal at an infeasible point, objective off by a factor of 200

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [B4-01](#b4-01) (cycle B)
- **Related:** [B4-02](#b4-02): B4-02's inflated incumbent comes from the same unchecked LP-integral path
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:200-204
- **Claim tested:** README §4 Limits/Results: 'Optimal' means 'feasible and dual feasible to 1e-7'; README §2.5: .optimal means within gap; SolutionAnalysis.primal/objectiveValue describe the incumbent. The package's own oracle isIntegralAndFeasible (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:60-65) requires row violation &lt;= 1e-6.
- **Observed:** Fixed-charge model min 100y + x, x + 0\*z >= 0.5, x - 1e6\*y &lt;= 0, y binary, x in \[0,10]: all 11 configurations (Simplex primal/dual, InteriorPoint, deterministic and parallel, threads 1-8, engine presolve off, every branching rule, heuristics off) return .optimal, objective 0.50005, bound 0.50005, primal y=0, x=0.5 (row violation 0.5; c.x = 0.5, not the reported 0.50005), incumbent source 'lp'. The true optimum is y=1, x=0.5, objective 100.5. Second shape: min x1+x2, 1e7\*x1 + 1e7\*x2 >= 5, x integer -> .optimal 5e-7 at (0,0), row violation 5; true optimum 1.
- **Why it is wrong:** The root LP puts y = 5e-7, within the 1e-6 integrality tolerance, so expand() rounds every integer column to the nearest integer and offers the point with the LP objective, never checking the rounded point against the rows. With a big-M coefficient the rounding moves the row activity by 0.5 (or 5), so a point infeasible by 0.5 becomes the 'optimal' incumbent and the reported objective matches neither the true optimum nor c.x of the returned point. The rounding heuristic and the dive do call isFeasible; this path does not.
- **Documented:** Not documented. README §4 says optimal means feasible to 1e-7 and Tolerances.integrality is 1e-6, but nothing says an integral-within-tolerance LP point is rounded and returned unchecked.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 bigm
```

<details><summary>Probe output</summary>

```text
oracle optimum 100.5 at [1.0, 0.5, 0.0]
P-default: status optimal obj 0.50005 bound 0.50005 x [0.0, 0.5, 0.0] viol (bounds: 0.0, rows: 0.5) c.x 0.5 src ["lp"]
(identical for D-default, I-default, P-det, D-det, I-det-nopre, P-nopre-t8, D-mostfrac-noheur, P-strong-bestbound, D-depthfirst-t2, P-t1)
oracle2 optimum 1.0 at [1.0, 0.0]; P-default: status optimal obj 5e-07 x [0.0, 0.0] viol (rows: 5.0)
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated critical, documented: no</summary>

I reproduced the defect from scratch in slot V091, using the public DSL and the README facade Automatic() rather than the finder's CompiledLP path or oracle. Every returned point was checked against hand-written coefficient lists in the probe.

(1) The behaviour happens. I used three models:
- FC: min 100\*open + flow, flow >= 0.5, flow - 1e6\*open &lt;= 0, open binary, flow in \[0,10].
- FC2: the same with two flows, so that demand stays a real two-column row.
- PI: min p+q, 1e7p + 1e7q >= 5, p and q integer in \[0,10].

Nine configurations all returned status=optimal. They were Automatic, Conditioned(Automatic), and B&B with primal simplex, dual simplex and interior point, deterministic and parallel, 1 to 8 threads, presolve and scaling off, heuristics none with mostFractional, Gap(0,0), and strong branching with bestBound.
- FC and FC2 returned objective 0.50005 at open=0 with the link row violated by 0.5. The reported objective is not c·x of the returned point (0.5). The incumbent source is lp@node0 and there are no warnings.
- PI returned objective 5e-7 at (0,0) with the row violated by 5.

(2) The expected values are right, by four independent routes:
- By hand, open=0 is infeasible (flow &lt;= 0 contradicts flow >= 0.5) and open=1 gives 100.5.
- Enumeration gives 100.5 for FC and 1.0 for PI.
- With open fixed as an LP, Simplex(.dual) and InteriorPoint both return infeasible for open=0 and optimal 100.5 for open=1.
- CPSAT, an exact second engine, returns optimal 1.0 at (0,1) for PI.

Even under the most charitable tolerance-based reading, which accepts the unrounded LP point (open=5e-7, flow=0.5, value 0.50005), the package does not return that point. It returns open=0, which is infeasible by 0.5. That is far above primalFeasibility 1e-7, and still 5e-7 after dividing by the row's 1e6 coefficient. The package's own test oracle isIntegralAndFeasible (BranchAndBoundTests.swift:61-65) would reject the point, since it requires a row violation of at most 1e-6.

(3) Load and randomness play no part. A scan over M shows the switch exactly where the LP value 0.5/M crosses Tolerances.integrality = 1e-6: M &lt;= 4e5 is correct (the rounding heuristic finds open=1), and M >= 6e5 is wrong. 91 repeated solves were all identical: seeds 0, 1, 7 and 12345, threads 1, 2 and 8, five repetitions, and 16 concurrent Automatic solves.

The code reading agrees. TreeSearch.swift:200-204 rounds the integer columns and calls offer() with the node LP objective, without isFeasible and without internalObjective. dive (lines 446-449) and roundingHeuristic (line 364) do both. offerIncumbent compares objectives only, and the result assembly returns incumbent.x unchanged.

None of README §2.5, §3, §4 or the HANDBOOK documents this behaviour. README §4 says optimal means feasible to 1e-7.

Caveat: the title's 'factor of 200' holds against the exact MIP optimum of 100.5. A tolerance reading could accept 0.50005, but only together with the unrounded point, which is not what the package returns. The core defect does not depend on this distinction.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V091 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V091 main
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-01-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

The contract, read from the docs and doc comments:
- README §4 (Results): "Optimal" means feasible and dual feasible to 1e-7. For a MILP, "within the gap" qualifies the objective only.
- SolveStatus.hasSolution: "a primal solution accompanies the status".
- SearchTree.offerIncumbent doc: "Offers a feasible integral solution".
- The search's own isFeasible allows a row violation of 1e-7·(1+|bound|). The rounding heuristic and the dive both call it before offering a point.
- The test oracle isIntegralAndFeasible allows rows ≤ 1e-6.
- Nothing in README §3/§4, HANDBOOK (decisions, known gaps, not verified) or the current-state statements of SPECIFICATION-v0.2 says that an LP point integral within tolerance is rounded and returned unchecked.

The causal story holds in the code:
- TreeSearch.expand (lines 196-205) rounds the integer columns when all are within 1e-6 of an integer. It offers the point with the node's LP objective, with no isFeasible check and no recomputed objective. The dive does both.
- BranchAndBound.search (lines 357-399) applies no final check.
- The integrality tolerance is fixed at Tolerances.default (BranchAndBound.swift:198), so no user setting avoids it.

Refutation attempts:
1. By design: no. The stated intent is "feasible integral", and the other two incumbent paths check feasibility.
2. Tolerance: partly, for the objective only. Under the documented integrality tolerance (1e-6 counts as integral), the unrounded LP point (open=5e-7, flow=0.5) is row-feasible. Its objective 0.50005 is the optimum of the problem relaxed to that tolerance; this is the classic big-M trickle-flow effect. So the finder's "factor of 200 against 100.5" relies on exact integrality and overstates. But the package returns the rounded point (open=0). Its row violation is 0.5 unscaled, and still 5e-7 if the row is equilibrated by its 1e6 coefficient, which is 5x primalFeasibility. objectiveValue 0.50005 is not c·x = 0.5 at that point. No reading of the contract makes the pair (0.50005, (0, 0.5)) a valid .optimal answer.
3. Misuse: M=1e6 on a flow ≤ 10 is a poor formulation, but it is valid input, and no coefficient limit for correctness is documented. The trigger is just rhs/coefficient ≤ 1e-6: M=1e7 with demand 5 gives .optimal 5.00005 at an infeasible point, against a true optimum of 105. Shape 2 has no big-M ratio at all.
4. Documented: no. Conditioned(Automatic()) lists a big-M warning in its conditioning report, but it still returns .optimal at the infeasible point with empty analysis.warnings. README risk 1's maxViolation advice is a mitigation the user must apply, not documentation of the defect.

Additional impact: Portfolio(\[BranchAndBound(), CPSAT()]) returns the wrong .optimal 5e-7 on shape 2, although CPSAT alone gets 1.

Severity is critical on the given scale: .optimal with an infeasible point.

Verdict file: verification/cycle-A/verdicts/A4-01-contract.md
Probe: verification/probes/cycle-A/Slots/V092/main.swift

Command:

```sh
cd verification/probes/cycle-A && swift build --product V092 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V092 all
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-01-contract.md`.

</details>

#### <a id="a4-02"></a>A4-02 · Heuristic incumbents are accepted by a feasibility test relative to the row bound (1e-7\*(1+|bound|)): integer-data knapsack reported optimal at 10,000,000 when the optimum is 9,999,999

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [B4-04](#b4-04) (cycle B)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:325-340 (isFeasible), used by roundingHeuristic at 363-366/417-418 and by dive at 448
- **Claim tested:** README §2.3 Tolerances primalFeasibility 1e-7 and README §4 Results 'feasible ... to 1e-7'; .optimal = within gap (README §2.5, risk 10). The package's own test oracle treats feasibility as an absolute violation of at most 1e-6 (BranchAndBoundTests.swift:60-65), and so does the MIPLIB test (rows &lt;= 1e-5, CorpusTests.swift:139-140).
- **Observed:** max x1 + x2 s.t. 3x1 + 3x2 &lt;= 29,999,999, x integer in \[0,1e7]: 10 of 11 configurations -> .optimal 10,000,000 (row violation 1, source 'rounding'); heuristics: .none -> 9,999,999 (violation 0). min x s.t. 2x - z >= 20,000,001, z in \[0,0.5] -> .optimal 10,000,000 (violation 1) vs true 10,000,001. min x s.t. 3x + y >= 1e9+1 (y fixed 0) -> .optimal 333,333,333 (violation 2) vs 333,333,334.
- **Why it is wrong:** TreeSearch.isFeasible accepts a row activity s when s >= rl - 1e-7\*(1+|rl|), i.e. an absolute slack of 3.0 on a bound of 3e7 and 100 on 1e9. A rounded integer point that violates an integer-data row by whole units is accepted as incumbent, and because the objective is integral (objectiveStep 1) the true optimum's node is pruned as 'no better'. The returned objective is better than any feasible integer point and the returned point is infeasible in exact arithmetic.
- **Documented:** Not documented. README never says the feasibility tolerance is relative to the bound; the measure it implies (and that the tests use) is absolute.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 relviol   (also: .build/release/F4 special, case huge-integer-bounds)
```

<details><summary>Probe output</summary>

```text
knapsack cents: max sum x s.t. 3x1+3x2 <= 3e7-1 [true optimum 9999999.0]: P-default=optimal/10000000/rowviol 1/["rounding"] ... D-mostfrac-noheur=optimal/9999999/rowviol 0/["lp"]
2x-z>=2e7+1, z in [0,0.5] [true optimum 10000001.0]: P-default=optimal/10000000/rowviol 1/["rounding"] ...
3x+y>=1e9+1 (y fixed 0) [true optimum 333333334.0]: P-default=optimal/333333333/rowviol 2/["rounding"]
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated critical, documented: no</summary>

I reproduced A4-02 from scratch in slot V094.

\*\*How the probe differs from the finder's:\*\*
- Models are built with the public DSL (LPModel, VariableDomain.integer(.range)), not with a hand-built CompiledLP.
- No oracle depends on the solver's own judgement:
- exact Int64 arithmetic on the returned integer point;
- closed-form weak-duality LP bounds, which match the package's Simplex(.dual) on relaxed();
- brute-force enumeration on scaled copies: 0 mismatches;
- CP-SAT as a second engine;
- metamorphic equivalents with the Chvatal-Gomory rounded row (same integer feasible set);
- configurations without the rounding heuristic.

\*\*(1) The behaviour happens.\*\*
- Six of the eight B&B/Automatic configurations return .optimal with a point that violates an integer-data row by 1 or 2 in exact arithmetic. These are default, deterministic, dual engine, interior-point engine, Gap(0,0), and the Automatic facade.
- Knapsack: 10,000,000 against a truth of 9,999,999.
- 2x-z case: 10,000,000 against 10,000,001.
- 3x+y case: 333,333,333 against 333,333,334.
- My own covering variant (min a+b, 3a+3b >= 1e9): 333,333,333 against 333,333,334.
- The package's own maxViolation (the check README risk 1 recommends) reports rows = 1 or 2.
- Each wrong objective lies strictly beyond the LP relaxation bound, which no feasible point can do. The reported bound equals that impossible value.
- Every wrong incumbent comes from the "rounding" heuristic, and the search stops after 1 node.

\*\*(2) The expected values are correct.\*\* All five routes agree: CP-SAT, the tightened equivalents, the no-rounding configurations, the finder's no-heuristics configuration, and the closed form confirmed by enumeration.

\*\*(3) Load and randomness play no part.\*\* 200 of 200 repeated solves were wrong, across 2, 8 and default threads and deterministic runs with random seeds. A sweep of k puts the boundary exactly where 1e-7\*(1+|rhs|) >= 1, to 7 digits, in both families:
- knapsack: k=3,333,333 is right, k=3,333,334 is wrong;
- covering: k=3,333,332 is right, k=3,333,333 is wrong.

That pins the cause to the relative test in TreeSearch.isFeasible (lines 325-340, used at 363-366/417-418 and at 448). BranchAndBound.swift:198 hard-codes Tolerances.default, so the user cannot tighten it.

\*\*Refutation attempts that fail.\*\*
- Documented tolerance: README §2.3 and §4 say only "1e-7". The Tolerances doc says "violation allowed, after scaling", and B&B does not scale. HANDBOOK item 16 says "violated by more than 1e-7". The package's own test oracles are absolute (1e-6 and 1e-5). No document mentions a relative test.
- Within the gap: risk 10's mitigation, a tighter Gap, fails; Gap(0,0) still returns the wrong answer. The incumbent is infeasible and super-optimal, not merely suboptimal within the gap.
- API misuse: I used only the public API with default strategies.

\*\*Minor note.\*\* With primal pseudocost branching in deterministic mode, heuristics .none stops with noSolution(timeLimit) at 30 s for k >= 1e5. That status is honest, but it means turning heuristics off is not a dependable workaround. The finder's dual + mostFractional + none configuration does return the truth.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V094 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V094 core && perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V094 sweep
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-02-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

Contract: the package documents one meaning of feasibility, and the returned point fails it.
- Tolerances.primalFeasibility (Strategy.swift:9-10) is "Bound/row violation allowed, after scaling", 1e-7.
- README §4 Results says "feasible and dual feasible to 1e-7". The same sentence goes on to the simplex refinement to 1e-10, so it uses the simplex's measure: absolute, in the scaled problem.
- SolveStatus.optimal is documented as "An optimal solution was found and proven (within the gap, for MILP)".
- HANDBOOK decision 16 says no bound may be violated by more than 1e-7.
- README risk 1 names CompiledLP.maxViolation(at:) as the way to check a point. It is absolute, and the package's own tests use it with 1e-6 (B&B) and 1e-5 (MIPLIB).
- Nothing documents a test relative to the row bound. BranchAndBound always uses Tolerances.default (BranchAndBound.swift:198), so the user cannot tighten it.

Code: TreeSearch.isFeasible (325-340) accepts s &lt;= ru + 1e-7\*(1+|ru|) in original units. That allows 3.0 on ru = 29,999,999. roundingHeuristic offers the nearest rounding through this test. The accepted incumbent beats the root LP relaxation bound itself (1e7 against 9,999,999.667), so the cutoff prunes everything at node 1, even with Gap(0,0). provenBound is clamped to the incumbent, so the reported bound equals the infeasible incumbent.

My probe (public DSL models, slot V095) reproduces the finding. It shows up through Automatic(), Conditioned(Automatic()) and Portfolio(\[BnB, CPSAT]) too, with no warnings:
- knapsack: optimal 10,000,000 against 9,999,999;
- a production model (7x+5y, 3x+2y &lt;= 20,000,001): optimal 50,000,005 against 50,000,002, which I checked by full enumeration;
- a MILP with a continuous column: optimal 10,000,000 against 10,000,001.

The threshold sweep pins the cause to the relative formula. With the knapsack row 3x1+3x2 &lt;= 3N-1, the answer is exact up to N = 3.3e6, where the allowance is 0.99. It is wrong from N = 3.4e6, where the allowance is 1.02. The switch is exactly where 1e-7\*(1+|ru|) reaches the unit violation.

Using the package's own Scaler, the scaled row violation is 0.25 to 0.5, which is 2.5e6 to 5e6 times the documented 1e-7 "after scaling".

Why it is not refuted:
- Not a misuse: the models are valid, small and integer, with exactly representable data.
- Not inside the gap: the gap limits how far a feasible incumbent can be from the optimum. It cannot excuse an infeasible incumbent whose objective beats the optimum.
- Not documented anywhere in README, HANDBOOK or the doc comments.

Severity is critical on the given scale: .optimal is returned with an infeasible point and an objective no feasible point attains.

Mitigations: the violation is at most about 1e-7 of the row bound. maxViolation exposes it, and CPSAT, or heuristics: .none, avoids it. Heuristics .none is not robust, though: with deterministic: true it gives noSolution(timeLimit) for N >= 1e5.

Two minor corrections to the finding:
- objectiveStep is not needed for the pruning, because the incumbent beats the root LP bound.
- The dive path (line 448) is barely exposed. It rounds only columns already within 1e-6 of an integer, and diving-only runs were exact.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V095 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V095 main && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V095 threshold && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V095 scaled
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-02-contract.md`.

</details>

#### <a id="a4-03"></a>A4-03 · objectiveStep counts an integer column's cost of magnitude &lt;= 1e-9 as an integral 0, so pruning by a whole objective step discards better solutions: reported optimal 1, true optimum 0.75

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Related:** [B4-02](#b4-02): both prune the optimum through the objective-step cutoff
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:380-408 (tolerance at 395); cutoff use at SearchTree.swift:312-319 and TreeSearch.swift:83-89
- **Claim tested:** BranchAndBound.swift:378-379 and SearchTree.swift:139-141: objectiveStep is 'the smallest amount by which the objective can improve' when every costed column is integer and the costs share a common divisor; README §2.5 .optimal = within gap.
- **Observed:** min x1 + 1e-9\*x2, x1 + (1e-9/1.5)\*x2 >= 0.5, x1 in {0,1}, x2 integer in \[0,1e9]: 10 of 11 configurations -> .optimal, objective 1, bound 1, x=(1,0), 1 node, incumbent from rounding. The point (0, 7.5e8) is feasible (maxViolation 0) with objective 0.75, and it is the optimum (x1=0 forces x2 >= 7.5e8). Only BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, heuristics: .none) returns 0.75.
- **Why it is wrong:** objectiveStep's integrality test |c\*scale - round| &lt;= 1e-9\*max(1, c\*scale) accepts c = 1e-9 as the integer 0, the gcd ignores it and the step becomes 1. The cutoff incumbent - 1 + 1e-9 then prunes every node whose bound is within 1 of the incumbent, including the one holding a solution better by 0.25, far outside the 1e-4 gap. The result is a false .optimal.
- **Documented:** Not documented. The trigger is narrow: a cost of at most 1e-9 (after the scale at which the other costs become integral) on an integer column with a range large enough for it to matter, as with tiny tie-breaking terms.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 misc   (lines starting 'tinycost')
```

<details><summary>Probe output</summary>

```text
tinycost P-default: optimal obj 1 bound 1 x [1.0, 0.0] nodes 1 src ["rounding"]
... (same for D-default, I-default, P-det, D-det, I-det-nopre, P-nopre-t8, P-strong-bestbound, D-depthfirst-t2, P-t1)
tinycost D-mostfrac-noheur: optimal obj 0.75 bound 0.75 x [0.0, 750000000.0] nodes 3 src ["lp"]
check point (0, 7.5e8): viol (bounds: 0.0, rows: 0.0) obj 0.75
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated critical, documented: no</summary>

I reproduced the finding from scratch in slot V097. The model is built with the public DSL and checked against an oracle of my own.

1. The observed behaviour happens. For min x1 + 1e-9 x2, x1 + (1e-9/1.5) x2 >= 0.5, x1 binary, x2 integer in \[0, 1e9], these configurations all return `.optimal`, objective 1, bound 1, x = (1, 0), 6/6 runs each, in 3 separate process runs:
- `BranchAndBound()` with 8 threads and with 1 thread;
- dual-simplex and interior-point node engines;
- `deterministic: true` with two seeds;
- `Gap(0, 0)`;
- strong branching with best-bound;
- depth-first with no heuristics, where the incumbent comes from the LP rather than rounding.

`Automatic()` on the DSL model also returns `.optimal` 1. Only best-bound runs with no heuristics return 0.75, because of their search order.

2. The expected optimum, 0.75, is correct. By hand, x1 = 1 gives 1 and x1 = 0 needs a·x2 >= 0.5. An exact FMA test with a = fl(1e-9/1.5) shows that x2 = 7.5e8 satisfies the row (activity 0.50000000000000011) and 7.5e8 − 1 does not, so the objective is 0.75. Dual simplex, primal simplex and the interior point on the subproblem with x1 fixed at 0 all return 0.75 at an integral x2 = 750000000; with x1 fixed at 1 they return 1. The reported bound of 1 is therefore invalid, and the error of 0.25 is 2500 times the README's `.optimal` slack of 1e-4.

3. The mechanism is isolated, and neither load nor randomness explains it. In a sweep of c2 whose true optimum stays at about 0.75, every c2 &lt;= 1e-9 gives the wrong answer and every c2 > 1e-9 gives the right one, including nextUp(1e-9). Between c2 = 1e-9 and nextUp(1e-9) the LPs, root bound and rounding incumbent are the same, yet the result flips from wrong to right. That pins the cause on the integrality test in `objectiveStep`, `|scaled-rounded| <= 1e-9*max(1,scaled)`. The test rounds 1e-9 to 0, so the step becomes gcd(1, 0) = 1. The cutoff, incumbent − step + 1e-9 = 1e-9, then prunes the x1 = 0 child, whose bound is 0.75. Because the step-based cutoff ignores the gap setting, `Gap(0, 0)` does not help. Contrasts:
- x2 continuous: correct;
- costs doubled to (2, 2e-9): correct;
- objective scaled to (1e-3, 1e-12): wrong, `.optimal` 0.001 against a true 0.00075. The trigger is relative to the power-of-ten scale that makes the other costs integral.

Every solve took under 2 ms against a 30 s limit.

4. Not documented. The README says `.optimal` for a MILP means within the gap. The drop tolerances are 1e-14, so the 1e-9 cost is kept, and the compiled c = \[1, 1e-9] with no diagnostics. README §3/§4 and the HANDBOOK's gaps and not-verified sections do not mention it. The unit test `objectiveStepDetection` does not cover tiny costs. The trigger is narrow, but the failure is a wrong value reported with a success status, which is critical on the scale.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V097 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V097 all
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-03-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

The finding holds up. The package promises that a MILP `.optimal` is optimal and proven within the gap:
- `SolveStatus.optimal` doc comment: "found and proven (within the gap, for MILP)".
- README §2.5: "`.optimal` means within `gap`".
- README risk 10: incumbent − bound ≤ max(1e-6, 1e-4·max(1, |incumbent|)).
- HANDBOOK decision 8 says the same.

The model is valid input:
- It goes through the public CompiledLP initializer, and also through the DSL with default CompileOptions. Those keep the 1e-9 cost (dropTolerance 1e-14) and issue no diagnostic.
- Bounds are finite and modest, and no documented B&B limit applies. The range and integrality restrictions belong to CP-SAT only.

The causal story is correct (code read and execution checked):
- BranchAndBound.swift:395 tests |c·s − round(c·s)| &lt;= 1e-9·max(1, c·s). The cost 1e-9 passes this with equality, rounds to 0, and gcd(1, 0) gives objectiveStep = 1.
- This contradicts the function's own doc comment (lines 378-379, "the smallest amount by which the objective can improve"). For costs {1, 1e-9} that amount is 1e-9, or 0 since the scale loop stops at 1e6.
- The cutoff at SearchTree.swift:312-319 and TreeSearch.swift:83-89 is incumbent − step + 1e-9·max(1, |inc|), with no gap term. Once rounding finds the incumbent 1, the cutoff is 1e-9, so the root (bound 0.5) and the x1=0 branch (0.75) are pruned.

My own runs (V098) settle it:
- Independent oracle: (0, 7.5e8) is integral, exactly feasible and has objective 0.75. The LP with x1=0 gives 0.75 at an integral point, and the LP with x1=1 gives 1, so the true optimum is 0.75.
- Defaults (P, D, P-det, I) report optimal 1, bound 1, gap 0, after 1 node. The bound is invalid and the error (0.25) is 2500 times the gap slack.
- Threshold scan: eps ≤ 1e-9 is wrong, while eps = 1.0000001e-9 and above gives the correct 0.75. This isolates the objectiveStep tolerance as the cause.
- A variant with every matrix coefficient in \[1, 1500] fails the same way, so this is not the ill-conditioning of defect 9 or risk 1.
- The documented mitigation (a tighter Gap, even Gap(0,0)) does not help, because the step cutoff ignores the gap.
- The facades Automatic and Conditioned(BranchAndBound()) return .optimal 1 with no warnings.

Nothing in README §3/§4, HANDBOOK (decisions, known gaps, not verified) or SPEC v0.2 describes objective-step pruning or treats tiny costs as zero. The unit test objectiveStepDetection has no tiny-cost case. Hence documented = false.

The trigger is narrow: a cost ≤ 1e-9 at the scale where the other costs become integral, on an integer column with a large range, such as a tie-breaking term. But the outcome is a wrong value under the success status `.optimal`, with a false bound and gap 0. That is critical on the given scale.

Verdict file: verification/cycle-A/verdicts/A4-03-contract.md. Probe: verification/probes/cycle-A/Slots/V098/main.swift.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V098 -c release && perl -e 'alarm shift; exec @ARGV' 400 .build/release/V098 all
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-03-contract.md`.

</details>

#### <a id="b4-01"></a>B4-01 · Rounded near-integral LP solution becomes the incumbent without a feasibility check: .optimal at an infeasible point

- **Severity:** critical (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-01](#a4-01) (cycle A)
- **Related:** [B4-02](#b4-02): B4-02's inflated incumbent comes from the same unchecked LP-integral path
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:200-203. In expand(), when fractional.isEmpty, the integer columns are rounded and offer(objective: objective, x: solution) is called with the LP objective, with no isFeasible and no objective recompute.
- **Claim tested:** Status.swift:5: '.optimal: An optimal solution was found and proven (within the gap, for MILP)'. README §4 Limits 'Results': 'Optimal' means 'feasible and dual feasible to 1e-7'. README §3 risk 1 names CompiledLP.maxViolation(at:) as the way to check a point. README §2.4: primal holds the n values of the solution.
- **Observed:** Model: max y - 1000z s.t. y - 1e6 z &lt;= 0, y in \[0, 0.4], z binary. BranchAndBound() parallel, Simplex(.dual) deterministic, Gap(relative: 0, absolute: 0) and Automatic all return status=optimal objective=0.3996 bound=0.3996 x=(z=0, y=0.4) nodes=1. maxViolation gives rows 0.4, and objective(at: x)=0.4, not 0.3996. The exact optimum is 0 at (0, 0). M=1e7 gives 0.39996. M=1e5 is correct, because z=4e-6 is branched on.  Second model: max x1+x2 s.t. 1e6 x1 - 1e6 x2 &lt;= -0.5, binaries. Every engine and Automatic return optimal 1.9999995 at (1, 1), with objective(at: x)=2.0 and the row violated by 0.5. The exact optimum is 1 at (0, 1).
- **Why it is wrong:** The root LP vertex has z=4e-7, which is inside the 1e-6 integrality tolerance, so expand() treats the LP solution as integral. It rounds the integer columns and offers the rounded point with the LP objective. It never calls isFeasible on that point and never recomputes the objective, although the rounding and diving heuristics do both.  Rounding a column with coefficient 1e6 moves the row activity by 0.4. The returned point therefore violates its row by 0.4, which is 4e6 times primalFeasibility and fails under any absolute or relative reading. The reported objective is attained by no feasible point.  Any LP vertex is exposed when an integer column is near-integral but not exact and has large row coefficients. Big-M rows y &lt;= M z with M above 1e6 times the range of y are the common case.
- **Documented:** Not documented. Neither README §4 (Defects, Limits) nor the HANDBOOK 'Known gaps' mentions it. It contradicts README §4 Limits 'Results' ('feasible ... to 1e-7') and Status.swift:5.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F4 bigm 1e6 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F4 round 1e6
```

<details><summary>Probe output</summary>

```text
bigm 1e6: [primal] status=optimal objective=Optional(0.3996) bound=Optional(0.3996) nodes=1 x=[0.0, 0.4] objective(at:x)=0.4 maxViolation(bounds: 0.0, rows: 0.4). [dual-det], [tightgap] and [Automatic] print the same.

round 1e6: [primal] status=optimal objective=Optional(1.9999995) bound=Optional(1.9999995) x=[1.0, 1.0] objective(at:x)=2.0 maxViolation(bounds: 0.0, rows: 0.5). [primal-det], [noheur], [dual], [ipm] and [Automatic] print the same.
```

</details>

#### <a id="b4-02"></a>B4-02 · Incumbent keeps the inflated LP objective, so the objective-step cutoff prunes the true optimum: .optimal a full unit below it, even with Gap(0,0)

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A4-03](#a4-03): both prune the optimum through the objective-step cutoff
- **Related:** [A4-01](#a4-01), [B4-01](#b4-01): B4-02's inflated incumbent comes from the same unchecked LP-integral path
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:200-203 offers the LP objective for the rounded point. The step cutoffs at TreeSearch.swift:83-87 (cutoff(for:)) and SearchTree.swift:312-317 (cutoff) allow only 1e-9 relative. BranchAndBound.swift:350-352 sets bound = incumbent on .complete.
- **Claim tested:** Status.swift:5: '.optimal ... proven (within the gap, for MILP)'. README §3 risk 10: '.optimal means incumbent - bound &lt;= max(1e-6, 1e-4\*max(1, abs(incumbent)))', with the mitigation 'Pass a tighter Gap to BranchAndBound when the exact optimum matters'. README §1 promises 'a proven bound'.
- **Observed:** Minimized model, from F4 minimize 766: max 2x0+21x1+x2+24x3+3x4+22x5+7x6+11x7+9x8, x binary, subject to: - 2x0+7x1+5x2+4x3+9x4+2x5+4x6+8x7 &lt;= 21 - 1e6x1-1e6x2 &lt;= 0.7381787698023262 - 1e6x1-1e6x6 &lt;= 0.8789166025652512 - -1e6x4+1e6x8 &lt;= 0.6272604256811957  BranchAndBound() (parallel and deterministic), Gap(relative: 0, absolute: 0) and the Simplex(.dual) engine all return status=optimal objective=66.00000564534383 bound=66.00000564534383 at x=(1,0,0,1,0,1,1,1,0), whose value is 66. The exact optimum is 67 at (1,0,0,1,1,1,1,0,1): row 1 gives 21 &lt;= 21 and the other rows give 0, -1e6 and 0. This was checked by enumeration and by hand.  The unminimized 11-variable instance nearint2#766 (F4 step 766) returns 72.00000564534383 against the true 73 from default-par, default-det, Gap(0,0)-det and Automatic. In a random family (8 to 11 binaries, knapsack rows, linking rows 1e6 d - 1e6 e &lt;= delta), 3,000 seeds x 13 configs produced 91 results beyond the gap.
- **Why it is wrong:** The LP-path incumbent is stored with the LP objective V+E, while the point's own value is V. Here E is 5.6e-6, gained by near-integral columns exploiting the fractional rhs of the 1e6-scaled rows.  All costs are integral, so objectiveStep=1 and the cutoff is incumbent - 1 + 1e-9\*max(1, |incumbent|). That formula assumes the incumbent lies on the objective lattice. Since E > 1e-9\*|inc|, a node whose LP bound is exactly V+1 lies above the cutoff and is pruned, although it contains the solution of value V+1. The search then completes, and BranchAndBound reports bound = incumbent.  The result misses the optimum by 1.0, against a slack of 0.0066, or 0 under Gap(0,0). Both the status and the bound are false.  Two mechanism checks support this. Adding a fixed continuous column with a cost (objectiveStep 0) makes the search find 73. Dividing the row shifts by 1000, which puts E below 1e-9 relative, also finds 73.
- **Documented:** Not documented. Neither README §4 nor the HANDBOOK 'Known gaps' mentions it. It falsifies README §3 risk 10: both its definition of .optimal and its 'tighter Gap' mitigation.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F4 step 766 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F4 minimize 766 && perl -e 'alarm shift; exec @ARGV' 3600 .build/release/F4 rand nearint2 1 3000
```

<details><summary>Probe output</summary>

```text
step 766: 'oracle optimal 73.0'.
- [as generated default-par] status=optimal objective=Optional(72.00000564534383) bound=Optional(72.00000564534383) objective(at:x)=72.0 nodes=7, last incumbent '72.00000564534383@6/lp'.
- [as generated default-det] and [as generated Gap(0,0)-det] print the same, and [as generated Automatic] gives 72.00000564534383.
- [+fixed continuous col with cost (step 0)] gives 73.0 in every config.
- [row shifts /1000] gives 73.00000000049212.

The minimized model gives 66.00000564534383 against 67. rand nearint2 1 3000 had 91 beyond-gap failures: seed 766 in every config except mf-dfs-noheur, and seeds 2754 and 351 also in primal-par. In the nearint family 1..1500, mf-dfs-noheur failed on seeds 810, 942, 1070 and 1156 (for example #1070: 0.99999819 against an exact 0).
```

</details>

#### <a id="a4-04"></a>A4-04 · A search that completes after pruning by the gap reports bound = incumbent and gap = 0: with Gap(relative: 0.05) a 3% suboptimal incumbent is reported with gap 0; with the default gap, 35 of 60 runs report a bound past the true optimum

- **Severity:** high (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [B4-03](#b4-03) (cycle B)
- **Related:** [B4-05](#b4-05): B4-05 is the test that cannot catch this bound defect
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:350-352 (boundValue = incumbent.objective on .complete); TreeSearch.swift:139,177,214 (prunes not recorded in prunedBound); SearchTree.swift:402-407
- **Claim tested:** SolutionAnalysis.bound 'Proven bound' (Sources/ZTronLPCore/Solve/Analysis.swift:22); BranchAndBoundAnalysis 'proven bound' and gap (BranchAndBound.swift:93-101); README §3 risk 3: 'read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum'; SearchTree.swift:171-173: 'the proven bound can never exceed \[prunedBound]'.
- **Observed:** Near-tie knapsack (maximise, 14 binaries, non-integral profits so objectiveStep = 0), seed 15, enumerated optimum 3670.050618. BranchAndBound(gap: Gap(relative: 0.05)) -> .optimal, objective 3560.059532, bound 3560.059532, gap 0, 1 node (also D-det). Default gap: 35 of 60 runs over 30 seeds return an incumbent below the optimum (all within the slack, as designed), and in every one of them bound == incumbent &lt; optimum, e.g. obj = bound = 3670.045785 with optimum 3670.050618. With integral profits (objectiveStep > 0) the bounds are valid.
- **Why it is wrong:** Nodes whose bound lies in \[incumbent - slack, incumbent) are pruned by the cutoff. When the pool then empties, the tree closes .complete and BranchAndBound overwrites the bound with the incumbent, discarding prunedBound (nodes pruned inside a worker by process()/expand() are never reported to the tree at all). The returned bound is then not a bound: it claims no better solution exists while one does, and gap = 0 says the incumbent is exact when it is up to the whole gap away. The existing check of the reported bound (aLooseGapStopsEarlyAndReportsIt, BranchAndBoundTests.swift:265-275) uses an integral-cost instance and so cannot hit this path.
- **Documented:** Not documented. README §3 risk 10 and HANDBOOK decision 8 say .optimal is 'within the gap' (which holds), but both present bound/gap as the measure of the remaining distance, which is what is misreported.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 gaploose   (and: .build/release/F4 gap 30)
```

<details><summary>Probe output</summary>

```text
seed 15 rel 0.05 P: optimal obj 3560.059532 bound 3560.059532 gap 0 opt 3670.050618 trueRelGap 2.997e-02 boundValid false nodes 1
seed 15 rel 0.05 D-det: optimal obj 3560.059532 bound 3560.059532 gap 0 ... boundValid false
seed 15 default: suboptimal within gap obj 3670.045785 opt 3670.050618 ... BAD BOUND 3670.045785 < opt 3670.050618
SUMMARY gap instances=30 defaultSuboptWithinGap=35 defaultOutsideGap=0 tightWrong=0 badBoundDefault=35 badBoundTight=0
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated high, documented: no</summary>

I reproduced the finding from scratch with my own probe (slot V100). Models are built with the public DSL. The oracles are mine: a hand derivation, brute-force enumeration over all 2^n points (integer weights, so feasibility is exact), zero-gap BranchAndBound, CPSAT on the unscaled instance, and a direct check of the better point against the data.

(1) The behaviour happens, and it follows the path the code reading predicts. Hand instance: a 6-item knapsack (A..F, capacity 82, profit/weight ratios strictly decreasing), all profits scaled by pi/3, which makes objectiveStep 0. The root LP gives 94.10 and the rounding heuristic gives 91.84 (A+B). The root LP is within 5% of that incumbent, so the root is pruned inside expand (TreeSearch.swift:214), and that prune is never recorded in prunedBound. The tree then closes .complete, and BranchAndBound.swift:351 overwrites the bound with the incumbent. Every Gap(relative: 0.05) or 0.03 configuration returned .optimal with obj = bound = 91.839225240, gap 0, 1 node: primal with 8, 1 and default threads, dual with deterministic: true, bestBound with mostFractional, and diving off. The true optimum is A+B+F (weight 82), 93.933620342, so the true gap of 2.28% is reported as 0. With nodeLimit: 1 the result is .feasible(nodeLimit) with bound = incumbent and gap 0, which is exactly the case README risk 3 covers.

Control: the same instance unscaled (objectiveStep 0.02) reports honest bounds. With 5% gap and no diving it gives obj 87.7, bound 89.82, gap 2.4e-2, against a true gap of 2.28e-2.

Own near-tie families (15 binaries, 30 seeds, my own SplitMix64 generator), default gap: deterministic primal and dual runs gave invalid bounds in 29/30 (maximize) and 28/30 (minimize) instances; 8-thread runs gave 14-16/30. Every suboptimal-within-gap run that reported bound = incumbent had gap 0. At gap 1e-2 the hidden error reaches 0.99%.

(2) The expected behaviour is right. Analysis.swift:22 says 'Proven bound'. README line 38 promises 'a proven bound'; risk 3 says to read bound and gap; risk 10 gives an example with bound ≠ objective under .optimal. The package's own test (BranchAndBoundTests.swift:259-260) asserts that the reported bound bounds the true optimum under a loose gap, but it uses randomMILP with integral data (objectiveStep > 0), so it cannot reach this path. The .gapReached path itself returns .optimal with bound ≠ objective (the control, and 26 of 29 suboptimal deterministic runs at gap 1e-2). So bound = incumbent on .complete is not the intended convention, and a bound below a feasible solution's value is invalid under any reading.

(3) Not load or randomness dependent. The hand case runs only the root and gave the same result 5 times out of 5 in every configuration. The deterministic family counts and the worst excess (1.291e-05) were identical across two separate runs.

Severity: the .optimal status is honoured (no incumbent left the gap), so this is not critical. But the published 'proven bound' and gap are materially false under a loose user gap or a node limit; at the default gap the error stays below 1e-4 relative. Not documented: README §4 and the HANDBOOK known gaps and not-verified sections are silent. I did not reproduce the finder's exact counts (35/60), only the effect, on my own instances.

Verdict file: verification/cycle-A/verdicts/A4-04-reproduce.md. Probe: verification/probes/cycle-A/Slots/V100/main.swift.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V100 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V100 hand && perl -e 'alarm shift; exec @ARGV' 900 .build/release/V100 family 30 1e-4
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-04-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated high, documented: no</summary>

Confirmed as a contract defect.

\*\*What the package promises.\*\*
- README §1 promises "a proven bound".
- The `SolutionAnalysis.bound` and `BranchAndBoundAnalysis` doc comments call it a proven bound.
- README risk 3 says to read `bound` and `gap` to know how far the incumbent may be from the optimum.
- README risk 10 gives an `.optimal` MILP example whose bound differs from the incumbent (incumbent 1,000, bound 999.95).
- The package's own test `aLooseGapStopsEarlyAndReportsIt` asserts that on an `.optimal` result with `Gap(relative: 0.2)` "the reported bound really bounds the true optimum". Its instance has integral costs (`objectiveStep` = 1), so it cannot reach this path.
- The "within the gap" meaning of `.optimal` (`SolveStatus` doc, README §2.5 and §4, HANDBOOK decision 8) covers the status and the incumbent, not the bound.

\*\*The "equals objectiveValue when optimal" defence fails.\*\* That half of the `SolutionAnalysis` comment cannot hold together with "proven" for a MILP solved within a gap. The same engine does not follow it either: the `.gapReached` path reports the real `provenBound`. No README §4 or HANDBOOK entry mentions that the bound or gap can collapse to the incumbent.

\*\*Not misuse, not within a tolerance.\*\* `Gap` is public and documented, a continuous objective column is an ordinary MILP, and no tolerance is documented for the bound.

\*\*The causal story holds, read from the code.\*\*
- When `objectiveStep` is 0, the cutoff is incumbent − slack, so nodes pruned in the slack band can contain better solutions.
- Worker-side prunes (TreeSearch.swift:139, :154, :177, :214) record no bound. Only the tree's own push/pop prunes update `prunedBound`.
- On `.complete`, BranchAndBound.swift:352 sets `boundValue = incumbent.objective`, so the gap comes out as 0.
- Removing line 352 alone would not fix it: when the root is pruned in `expand()`, `provenBound` is already the incumbent.

\*\*Reproduced with my own instances and brute-force oracle.\*\*
- A 3-item knapsack with non-decimal profits and `Gap(0.05)` returns `.optimal` with objective 20.9000003, bound 20.9000003, gap 0, after 1 node. The optimum is 21.5000004, a true gap of 2.87 %. This happens on all of primal, 1 thread, dual-deterministic, IPM and rounding-only.
- The same knapsack with integral profits plus one continuous column with profit 0.5 returns objective = bound = 209.5 with gap 0. The optimum is 215.5.
- The control without that continuous column (`objectiveStep` = 1) returns objective 209, bound 215, gap 0.0287, which is a valid bound.
- So one constant continuous objective term turns a correct bound and gap into a false "gap 0".
- The finder's seed 15 numbers reproduced exactly. With `Gap(0.05)` and no heuristics, the search ends `.gapReached` with the same incumbent and an honest bound of 3675.06.
- With the default gap, 25 of 60 runs (automatic and 1 thread) reported a bound below the optimum, every one with gap 0, and no incumbent fell outside the gap. The finder counted 35 of 60 with a different pair of configurations.

\*\*Severity: high.\*\* The status and incumbent are within the contract, so this is not critical. But a published claim ("proven bound", risk 3) is materially false on a common path: any MILP with a continuous or non-decimal objective cost that ends `.complete` after pruning in the slack band. The error is up to the whole user gap; with the default gap it is at most 1e-4 relative.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V101 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V101 tiny
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-04-contract.md`.

</details>

#### <a id="a4-05"></a>A4-05 · A time limit or cancellation that lands while the root is being expanded loses the root node: .feasible(timeLimit) reported with bound = incumbent and gap 0 when the incumbent is 14% below the optimum

- **Severity:** high (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Both skeptics confirmed it.
- **Same defect:** [A6-01](#a6-01) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:307-322 (root not re-queued on StopSignal); SearchTree.swift:402-407
- **Claim tested:** README §3 risk 3: 'Set timeLimit or nodeLimit, and read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum'; SolutionAnalysis.bound 'Proven bound'; SolveStatus.feasible 'optimality was not proven'.
- **Observed:** randomMILP(rows 30, columns 120, seed 77, upper 1), maximise; a 120 s dual run proves 1097, root LP 1120.53. timeLimit 0.0005, 0.001, 0.002, 0.003 s (8 and 1 threads), 0.005 s (1 thread), and Task.cancel after 0.2, 0.5, 1 and 2 ms all give .feasible(timeLimit|cancelled), objective 947, bound 947, gap 0, nodesProcessed 1, nodesOpen 0. When the stop lands after the root's children are queued (0.005 s, 8 threads) the bound is a valid 1118.8 with gap 0.18.
- **Why it is wrong:** When search.expand() of the root throws a StopSignal (it runs rounding, a dive and strong-branching probes at node 0), rootChildren stays empty and tree.begin() is called with no children, so the tree holds no open node. provenBound then collapses to the incumbent and the analysis says the incumbent is proven optimal (bound = objective, gap 0) under a status that says it is not. The 'how far from the optimum' reading that risk 3 recommends for exactly this situation reports 0 instead of about 18%.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 rootstop
```

<details><summary>Probe output</summary>

```text
reference (120 s, dual): optimal obj 1097 bound 1097 nodes 45888
T 0.001 P: feasible(stoppedBy: timeLimit) obj 947 bound 947 gap 0 nodes 1 open 0 rootLP 1120.525624 boundValid false incumbents ["rounding@0"]
T 0.005 P-t1: feasible(stoppedBy: timeLimit) obj 947 bound 947 gap 0 nodes 1 open 0
cancel after 1.0 ms: feasible(stoppedBy: cancelled) obj 947 bound 947 gap 0 nodes 1 rootLP 1120.525624
```

</details>

<details><summary>Skeptic, reproduce lens: confirmed, rated high, documented: no</summary>

I reproduced the defect from scratch in slot V103 and checked the expected value with an oracle independent of the finder's (the finder used a 120 s Simplex(.dual) branch-and-bound run).

(1) The behaviour happens.
- Natural time limits of 0.0005, 0.001 and 0.002 s: 5 of 5 runs at both 1 and 8 threads return feasible(timeLimit) with obj 947, bound 947, gap 0, nodes 1, open 0.
- From 0.003 s on, the bound is a valid 1118.81 with gap 0.18.

(2) The expected behaviour is correct.
- The LP relaxation value of 1120.525624 is certified two ways by my own code: a primal feasibility check (max violation 1.7e-13), and a weak-duality bound computed from the duals. That bound is valid for any multiplier vector, so it does not trust the solver.
- An integer point with objective 1097 is verified exactly in Int64 arithmetic. Two engines other than the finder's produced it, BranchAndBound with the primal engine and CPSAT, and both prove 1097 optimal.
- So any valid bound must be at least 1097. The reported bound of 947 is false by 150, and the incumbent is 13.7% below the optimum. The correct gap is about 0.18: 0.181 with the root kept in the tree (bound 1118.81), 0.183 against the root LP.

(3) The effect does not depend on load or randomness.
- Cancelling from the progress callback at the root's own newIncumbent(node 0, "rounding") event fails in 10 of 10 runs at both 1 and 8 threads. The callback fixes the moment of the stop, so timing plays no part.
- A 1 s time limit with the callback blocking 1.2 s at that event fails in 3 of 3 runs at each thread count.
- Controls behave: cancelling at the first boundImproved event (after the root is in the tree) gives a valid bound of 1118.81 in 10 of 10 runs, and nodeLimit 1 and 2 also give valid bounds.
- On a larger randomMILP (120 rows by 1200 columns, seed 5), the root-expansion window runs from 69 to 150 ms. Ordinary limits of 93, 118 and 142 ms give bound = obj = 11097 with gap 0 in 6 of 6 runs, while a 20 s run finds a verified feasible 11735. So the window is not only sub-millisecond.

The code confirms the cause:
- BranchAndBound.swift:304-322: when expand() of node 0 throws a StopSignal, rootChildren stays empty, tree.begin queues nothing, and the root is never pushed into the tree.
- SearchTree.swift:402-407: provenBound then collapses to the incumbent.
- TreeSearch.swift:121-123: the worker loop handles the same signal on every other node by returning the node to the pool, so only the root path is wrong.

This contradicts three published claims:
- README section 3 risk 3 says to read bound and gap to know how far the incumbent may be from the optimum.
- SolutionAnalysis.bound is documented as a 'Proven bound'.
- The .feasible status itself means optimality was not proven.

Nothing in README, HANDBOOK or the specification documents this, and no test covers a stop during root expansion.

I rate it high, not critical: the objective and the point are correct, and only the bound and gap certificate are materially false.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V103 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 oracle && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 cancel 1097 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 natural 1097 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V103 deadline 1097 && perl -e 'alarm shift; exec @ARGV' 400 .build/release/V103 big 120 1200 5
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-05-reproduce.md`.

</details>

<details><summary>Skeptic, contract lens: confirmed, rated high, documented: no</summary>

What the package promises:
- SolutionAnalysis.bound (Analysis.swift:22): "Proven bound; equals objectiveValue when optimal."
- SolveStatus.feasible: "optimality was not proven".
- README §3 risk 3 covers exactly this case: set timeLimit or nodeLimit, then read bound and BranchAndBoundAnalysis.gap "to know how far the incumbent may be from the optimum".
- README §1 item 3 and the HANDBOOK contracts: a stop returns "what exists so far".
- SPECIFICATION-v0.2 line 30, about the current package: "The LP bound at the root is all the bound there is."
- Nothing in README §4 (defects, limits by design, not verified), the HANDBOOK decisions, known gaps or not verified, or the doc comments limits this for short time limits or for stops at the root. SolveContext.timeLimit says only "Seconds, wall clock", so this is valid input, not misuse.

The causal story holds in the code:
- BranchAndBound.swift:304-322: search.expand of node 0 runs rounding, the dive and the strong-branching probes. A StopSignal thrown there sets only stoppedAtRoot, rootChildren stays \[], and tree.begin(root:children: \[]) is called.
- begin calls absorb, which counts the root as processed and queues nothing. The root LP bound never enters open, inFlightBounds or prunedBound.
- provenBound (SearchTree.swift:402-407) therefore equals the incumbent, so bound = incumbent and relativeGap = 0 under .feasible(stoppedBy:).
- An ordinary node that is stopped goes back to the pool: workerLoop (TreeSearch.swift:121-123) calls tree.abandon(node, closing:), which pushes it. The root has no such path, so this is an omission, not a design choice.
- checkGapAndMemory needs open+inFlight > 0, which is why the status stays .feasible rather than .optimal.

What I ran:
- Oracle: two independent engines (B&B with the dual node engine, and CPSAT) both prove 1097. The 1097 point checks feasible directly: violations 0, integral.
- Short limits: 27 of 53 runs report bound 947 with gap 0, while the root LP is 1120.53. The 947 incumbent point is itself feasible, so only the bound and gap are wrong.
- Corpus: the same lost-root result appears on stein27, stein45, mod008 and egout. On stein45 (min, optimum 30, root LP 22), time limits of 5 to 50 ms give bound 45 or 32 with gap 0. Every time the bound is on the wrong side of the optimum.
- Larger model: on a 300x3000 random MILP, timeLimit 1 s gives bound = incumbent 27795 with gap 0 in three runs out of three. A run with 4 s finds a verified feasible point of 27908, which disproves that bound.

The window is the time the root expansion takes, and it grows with model size. So this is not only an edge case: the exact usage risk 3 recommends produces a "gap 0" certificate for a non-optimal incumbent.

Refutation paths do not hold:
- Wrong oracle: no.
- Misuse: no.
- By design: no.
- Within a tolerance: no. The errors are 4 to 50 % against a gap tolerance of 1e-4.
- Not reproducible: no. Every repetition is identical.

Severity is high, not critical: the status, the objective value and the point are all correct. But the "Proven bound" contract and risk 3's advice become materially false, and ordinary inputs trigger it.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V104 -c release && perl -e 'alarm shift; exec @ARGV' 400 .build/release/V104 stop 1097 && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V104 big 300 3000 3 1 1.0 1.3 4
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-05-contract.md`.

</details>

#### <a id="b4-03"></a>B4-03 · With objective step 0, the reported 'proven' bound lies below the true optimum and gap reads 0 (slack-pruned nodes never reach prunedBound; .complete overwrites the bound)

- **Severity:** high (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-04](#a4-04) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:350-352 (case .complete: if hasIncumbent { boundValue = incumbent.objective }). TreeSearch.swift:139, 154, 177 and 214 discard nodes against the slack cutoff without telling the tree. SearchTree.swift:340, 359 and 377 feed prunedBound only from push, pop and removeBestBound. provenBound is at SearchTree.swift:402-404.
- **Claim tested:** README §1: results carry 'a proven bound'. Analysis.swift:22: 'Proven bound'. The README §3 risk 3 mitigation: 'read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum'. SearchTree.swift:171-172: prunedBound is 'The bound of nodes that were pruned or dropped without being fully explored; the proven bound can never exceed it'.
- **Observed:** (1) max 10000x0 + 3.31234567xa + 2xb + 2xc s.t. 3xa+2xb+2xc &lt;= 4, binaries. BranchAndBound(), parallel and deterministic, returns status=optimal objective=10003.31234567 bound=10003.31234567 gap=0.0 nodes=1. Yet x=(1,0,1,1) is feasible with value 10004, and the root LP bound is 10004.31234567. With p=3.3 (objective step 0.1) the same search reports the valid bound 10004.3.  (2) The package's own generator, InstanceGenerator.randomMILP(rows: 6, columns: 30, seed: 13, integerFraction: 0.8, upper: 2, integralData: false), with BranchAndBound() and with deterministic: optimal 696.8528577299143, bound equal, gap 0.0. A feasible integral point has 696.8684768970606 (row violation 2.8e-14). Seeds 18 and 21 behave the same.  (3) randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1, integralData: false) with Gap(relative: 0.2): optimal 523.2299614429742, bound equal, gap 0.0, while the optimum is 586.8790317749188. The bound is 10.8% below the optimum.  .boundImproved events carry the same invalid values.
- **Why it is wrong:** For a maximization, a proven bound must be at least every feasible objective, and the gap must bound the distance to the optimum. With objectiveStep == 0 the cutoff is incumbent - gap slack.  TreeSearch discards nodes whose bound lies in \[incumbent - slack, incumbent) in four places: - process(): node.bound >= cut; - the engine's .cutoff outcome; - objective >= currentCutoff(), checked twice. None of these tells SearchTree, so prunedBound never sees the nodes. On CloseReason.complete, BranchAndBound then replaces the bound with the incumbent.  The status is still within the gap, but the bound and gap fields assert an exactness that is false. A user following the risk 3 mitigation reads gap 0 for an incumbent 10.8% from the optimum. Any model with a continuous column that has a cost, or with non-integral costs, is exposed.
- **Documented:** Not documented. Neither README §4 nor the HANDBOOK 'Known gaps' mentions it. It contradicts README §1 ('a proven bound'), Analysis.swift:22 and the README §3 risk 3 mitigation.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F4 gap 3.31234567 && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F4 boundseed 13 30 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F4 testint && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F4 inv 1 41 30
```

<details><summary>Probe output</summary>

```text
gap 3.31234567:
- [default-par] status=optimal objective=10003.31234567 bound=Optional(10003.31234567) gap=Optional(0.0) nodes=1 history=['10003.31234567@0/rounding'] boundValid=false.
- [default-det] prints the same.
- [tight-par] gives 10004.0 with bound 10004.0.

boundseed 13 30: 'BranchAndBound(): optimal objective=696.8528577299143 bound=696.8528577299143 gap=0.0 nodes=4 -> bound below a feasible objective by 0.015619167146383006'.

testint: 'integralData=false: exact(Gap 0) optimal 586.8790317749188 | loose(0.2) optimal objective=523.2299614429742 bound=523.2299614429742 gap=0.0 nodes=1 -> bound >= optimum? false'.

inv 1 41 30: 8 bad runs, all 'bound below optimum' (seeds 13, 18, 21).
```

</details>

#### <a id="b4-04"></a>B4-04 · Rounding and diving incumbents pass an unscaled 1e-7\*(1+|rhs|) feasibility test: .optimal above the solver's own LP relaxation on badly scaled rows

- **Severity:** medium (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-02](#a4-02) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:325-340 (isFeasible: the column test at line 328 and the row test at line 335), used by the rounding heuristic and by dive().
- **Claim tested:** README §2.3: Tolerances.primalFeasibility is 1e-7. README §4 Limits 'Results': 'feasible ... to 1e-7'. An integer solution can never beat its own LP relaxation.
- **Observed:** (1) max x+y s.t. 1e-7x + 1e-7y &lt;= 1.5e-7, x and y binary. Every engine returns status=optimal objective=2.0 bound=2.0 at x=(1,1), from the incumbent '2.0@0/rounding'. The root LP is 1.5, and the exact optimum is 1.  (2) max x s.t. 3x + y &lt;= 1e9+1, x integer in \[0, 1e9], y fixed 0. The result is optimal 333333334 with bound 333333334. The row activity is 1000000002 > 1000000001, and the absolute maxViolation is 1.0. The root LP is 333333333.667, and the exact optimum is 333333333.  BranchAndBound(heuristics: .none) returns the exact optima, 1 and 333333333.
- **Why it is wrong:** TreeSearch.isFeasible works on the unscaled problem with the allowance feasibility\*(1+|bound|). - On a row whose coefficients are 1e-7, that allowance is an absolute 1e-7, a 33% violation in the row's own units. The LP engine works on the scaled problem and rejects the point. - On a row with rhs 1e9, it is 100 units, which admits a whole unit of integer data.  The search then closes with an incumbent above the root relaxation bound that the same solver computed, and reports bound = incumbent.  Under a relative-tolerance reading, as SCIP uses, both points are within tolerance, and the README does not say whether the tolerance is absolute or relative. That is why this is graded medium, not critical. The incumbent beating the LP bound is still an internal inconsistency.
- **Documented:** Partly. README §4 Limits 'Results' states feasibility 'to 1e-7' without saying whether it is absolute or relative, and a relative reading admits both points. README §4 and the HANDBOOK 'Known gaps' do not say that an incumbent can exceed the LP relaxation, nor that heuristics use a looser test than the node LPs.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F4 tol
```

<details><summary>Probe output</summary>

```text
[huge rhs: max x s.t. 3x + y <= 1e9+1] status=optimal objective=Optional(333333334.0) bound=Optional(333333334.0) root LP=Optional(333333333.6666666) x=[333333334.0, 0.0] activity=[1000000002.0] ru=[1000000001.0] history=['333333334.0@0/rounding']. With heuristics off: 333333333.0.

[tiny coefficients: max x+y s.t. 1e-7x+1e-7y <= 1.5e-7] status=optimal objective=Optional(2.0) bound=Optional(2.0) root LP=Optional(1.5) x=[1.0, 1.0] activity=[2e-07] ru=[1.5e-07] history=['2.0@0/rounding']. With heuristics off: 1.0.
```

</details>

#### <a id="b4-05"></a>B4-05 · aLooseGapStopsEarlyAndReportsIt cannot detect invalid bounds: its instance has integral costs, so the slack-cutoff path never runs

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A4-04](#a4-04): B4-05 is the test that cannot catch this bound defect
- **Location:** Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:209-211 (an instance with integral data) and 252-261 (the assertion; exact is solved with the default Gap).
- **Claim tested:** Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:259-260: 'The reported bound really bounds the true optimum (a maximization: bound >= optimum)', followed by #expect(loose.bound! >= exact.objectiveValue! - 1e-6).
- **Observed:** hardInstance() is InstanceGenerator.randomMILP(rows: 12, columns: 60, seed: 4242, upper: 1) (lines 209-211). Its data is integral, so objectiveStep > 0 and the cutoff is step based. The gap-slack pruning behind B4-03 therefore never runs, and the test passes: the loose bound is 617.28 >= the optimum 593, with gap 0.104.  Changing only integralData to false makes the identical assertion fail: the loose bound is 523.23 &lt; the optimum 586.88, with gap 0.0.  The reference `exact` is also solved with the default gap rather than Gap(0,0), so the reference is not guaranteed optimal either.
- **Why it is wrong:** The only test of bound validity under a loose gap exercises the one cutoff path that keeps the bound honest. It passes with B4-03 present, and it does pass today.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F4 testint
```

<details><summary>Probe output</summary>

```text
'hardInstance objective step: costs integral = true'.

'integralData=true: exact(Gap 0) optimal 593.0 | loose(0.2) optimal objective=559.0 bound=617.2804334721933 gap=0.10425837830446028 nodes=1 -> bound >= optimum? true'.

'integralData=false: exact(Gap 0) optimal 586.8790317749188 | loose(0.2) optimal objective=523.2299614429742 bound=523.2299614429742 gap=0.0 nodes=1 -> bound >= optimum? false'.
```

</details>

#### <a id="a4-06"></a>A4-06 · deterministic: true results depend on SolveContext.threads: threads 1 and threads >= 2 give different LP-iteration counts and, on one instance, a different event sequence and incumbent history

- **Severity:** low (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Same defect:** [B4-06](#b4-06) (cycle B)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:582-598; BranchAndBound.swift:296 (budget built from threads, not workerCount)
- **Claim tested:** BranchAndBound.swift:144-146: 'Single worker ... identical results and identical event sequences across runs (rule C9)'; README §3 risk 8 and §4: deterministic: true 'runs a single worker with a fixed seed'.
- **Observed:** 8 runs per engine at threads 4,4,4,4,1,8,2,8: runs at 2, 4 and 8 threads are identical in every field. threads 1 differs: randomMILP(10,40,s9) lpIterations 6102 vs 6111 (P), 5597 vs 5595 (D), 5587 vs 5585 (I); randomMILP(14,50,s21) 18912 vs 18914 (P); mixed(8,30,s5) with P: event sequence and incumbent history differ. Objective, bound and primal were equal in all of them.
- **Why it is wrong:** Deterministic mode runs one worker but still sizes the ConcurrencyBudget from context.threads. With a free slot, strong-branching probes run on fresh engines in child tasks; with threads 1 they run inline on the worker's own engine, which changes the engine state the next node LP starts from. The same model and seed therefore give different runs on machines or contexts with a different thread count, the default being the active processor count.
- **Documented:** Not documented. The package test twentyRunsAreIdentical fixes threads = 4, so it cannot see this.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 det
```

<details><summary>Probe output</summary>

```text
randomMILP(10,40,s9) P det: run 4 threads 1: iterations 6102 vs 6111
mixed(8,30,s5) P det: run 4 threads 1: events differ (13 vs 13), incumbent history differs
mixed(8,30,s5) D det: IDENTICAL over 8 runs (threads 4,4,4,4,1,8,2,8)
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

My own runs reproduce the defect, and a precise reading of the code shows its cause.

\*\*Cause in the code.\*\*
- BranchAndBound.swift:204-205 and 296 set `workerCount = deterministic ? 1 : threads`, but build `ConcurrencyBudget(threads: threads, occupied: workerCount)`. A deterministic search therefore still has `threads - 1` free slots.
- TreeSearch.swift:582-598: when the budget grants slots, strong-branching probes run in child tasks on fresh private engines. When it grants none (threads == 1), they run inline on the worker's own engine. That changes the basis and factorization the next node LP warm-starts from.

\*\*Causal test.\*\* The dependence switches on exactly at the borrow threshold `candidates.count >= 4`:
- `.mostFractional` and `.strong(candidates: 3)` give identical runs at every thread count.
- `.strong(candidates: 4)`, `.strong(candidates: 8)` and the default `.pseudocost(4)` split into two groups: threads 1, and threads >= 2.

\*\*Reproducibility at a fixed context holds.\*\* Three runs at threads 1 were identical, as were repeated runs at threads 4. Threads 2, 3, 4, 8 and nil (the default, 8 here) always form one identical group. So the defect is a dependence on thread count (1 against >= 2), not run-to-run noise.

\*\*Contract.\*\* Thread-count independence is not promised in so many words. But every description of the mode implies it:
- the doc comment: "Single worker ... identical results and identical event sequences across runs";
- README principle 6: "same result and the same event sequence every run";
- risk 8: "runs a single worker with a fixed seed";
- §4: "which uses one worker".

Risk 8 also offers deterministic mode as the cure for "the solution returned" varying. Across threads 1 and >= 2 the returned solution still varies. Risk 7 advises lowering SolveContext.threads to share CPUs, which pushes users into exactly this case. CPSAT's deterministic LP worker pins `threads = 1` (LPRelaxation.swift:225), while branch and bound has no such guard, so this is an oversight rather than a design choice. It is not a wrong oracle, not misuse, and not within a documented tolerance.

\*\*Documented: no.\*\* Neither README, HANDBOOK nor SPECIFICATION says that deterministic results depend on threads. The only description of the two probe paths is an internal doc comment, which says nothing about reproducibility. `twentyRunsAreIdentical` pins threads = 4, so it cannot see this.

\*\*Severity: low.\*\*
- Status and objective agree in every run, apart from 1 ulp on one random instance.
- Only threads == 1 differs, and the default on any multi-core Apple machine falls in the consistent group.

The impact is larger than the finder reported. The finder said objective, bound and primal were always equal. In fact:
- on MIPLIB enigma and lseu (primal engine), threads 1 returns a different optimal integer solution;
- node counts differ by up to about 415× (enigma, dual engine: 59 vs 24,460 nodes, 0.03 s vs 2.8 s);
- on scan seed 119, objective and bound differ by 1 ulp.

Medium ("misleading API behaviour") is therefore arguable.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V106 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/V106 repro PDI r10 m8 r14 && perl -e 'alarm shift; exec @ARGV' 900 .build/release/V106 mech P r10 m8 r14 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V106 mdetail P enigma lseu
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-06-combined.md`.

</details>

#### <a id="a4-07"></a>A4-07 · BranchAndBoundAnalysis.lpIterations, published as 'LP pivots' in README §5, adds a fixed estimate of 25 pivots per strong-branched candidate instead of the probes' real pivots

- **Severity:** low (finder); skeptic: medium · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Same defect:** [B4-09](#b4-09) (cycle B)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:597 and :637
- **Claim tested:** README §5 MIP table, column 'LP pivots', and the derived ratio claim 'The primal node engine ... takes between 0.60 and 1.65 times the LP pivots of the dual one'; README §5 'How current': 'LP pivots summed over the set within 1 %'.
- **Observed:** Two-column model min -x - 0.1y, 2x + y &lt;= 1, x binary, y in \[0,1] (root LP takes 1 pivot): mostFractional reports lpIterations 3 (P) / 2 (D) over 3 nodes; strong(1) and the default pseudocost(4) report 28 (P) / 27 (D) over 2 nodes. The 25 extra come from the probe estimate.
- **Why it is wrong:** runProbes returns candidates.count \* 2 \* 50 / 4 as its iteration count whatever the probes did ('count the cap's worth at most'). The published pivot counts and the primal/dual ratios therefore mix real pivots with a constant per probed candidate, and the probe term is identical for both engines.
- **Documented:** The code comment admits the estimate (TreeSearch.swift:596); README §5 presents the numbers as pivots.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 iters
```

<details><summary>Probe output</summary>

```text
mostFractional P: optimal obj -0.1 nodes 3 lpIterations 3 (root LP alone: 1 pivots)
strong(1) P: optimal obj -0.1 nodes 2 lpIterations 28
pseudocost(4) D: optimal obj -0.1 nodes 2 lpIterations 27
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated medium, documented: no</summary>

The code confirms the finding. TreeSearch.runProbes returns candidates.count\*2\*limit/4 on both paths (inline :597, task group :637). That is 25 per strong-branched candidate, whatever the probes did. chooseBranch adds it to the node's iterations (:511) and SearchTree sums it into lpIterations. The NodeLPStrategy.probe protocol returns only Double?, so the tree has no access to the real count.

The benchmark (Sources/ZTronLPBenchmarks/main.swift:150-154) prints lpIterations and the P/D ratio. Those are the README §5 'LP pivots' column and the '0.60 to 1.65 times' claim.

Oracle: a public NodeLPStrategy wrapper that passes every call to Simplex unchanged and records the real pivots of each root, node, dive and probe run. A probe's pivots are read from Simplex.rootAnalysis(\_:worker:), which describes worker.lastOutcome; SimplexEngine.run resets and sets this on every run. Plain Simplex in deterministic mode gives the same nodes and lpIterations as the wrapped runs (p0033, egout, misc03), so the wrapper does not change the search.

Tiny model: the hand derivation (down probe 1 pivot, up probe 0 pivots) matches the measurement. Reported 28/27, real 4/3.

MIPLIB in deterministic mode: on all 18 runs, reported equals real root+node pivots plus 25 per candidate exactly. In the benchmark's parallel configuration the constant is 8 % to 84 % of each reported number, and reported/real ranges from 0.85 (misc03 D, an undercount) to 4.03 (egout D). Real probe pivots per candidate are 1.8 to 32, and some probes reach the 50 cap, so 25 is neither a count nor a bound. egout's P/D ratio is 1.65 reported against 3.13 real, against 1.48 published; my run's raw numbers are close to the published row.

The 'within 1 %' sub-claim is not shown false: both sides of that comparison contain the constant, which only dilutes the difference.

Not documented: only an internal comment mentions it, and that comment misdescribes the formula ('the cap's worth at most', while the formula counts a quarter of it). README, HANDBOOK and the public docs present the numbers as pivots or iterations.

Severity is medium, not low. The public lpIterations statistic is misleading: comparing branching rules by it gives 3 vs 28 where the real counts are 3 vs 4. The published figures are off by up to 4×, and one engine ratio by about 2×. It is not high because no solve result, status, limit or acceptance criterion is affected, and the timings are correct.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V109 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V109 tiny && perl -e 'alarm shift; exec @ARGV' 1500 .build/release/V109 miplib par p0033 egout misc03
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-07-combined.md`.

</details>

#### <a id="a4-08"></a>A4-08 · Test memoryBudgetDegradesThenStops cannot fail if the memory budget is ignored, and no test checks the 'degrades' step

- **Severity:** low (finder); skeptic: medium · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Same defect:** [A6-07](#a6-07) (cycle A), [A7-01](#a7-01) (cycle A)
- **Location:** Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:246
- **Claim tested:** Test name (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:241) and its comment: 'with a tiny budget the pool first drops parent states, then stops with .memoryBudget'.
- **Observed:** The assertion is `analysis.status.stopReason == .memoryBudget || analysis.status == .optimal` (line 246). The second disjunct is exactly what a solve that ignores the budget returns: the same instance without a binding budget is .optimal (limits mode: 'memory budget 200000 det: optimal obj 593'). Today the first disjunct holds (2,000 B with that configuration -> noSolution(memoryBudget) after 18 nodes). Nothing asserts that parent states are dropped before the stop. The liveness test L7 aBudgetTooSmallForTheTreeStopsWithTheIncumbent (Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:207) does assert .memoryBudget strictly, so the suite as a whole would still catch an ignored budget.
- **Why it is wrong:** The test named for the degrade-then-stop behaviour passes for a solver with no memory budget at all and never observes the degrade step.
- **Documented:** not stated

**Reproduction**

```sh
cd . && sed -n 241,250p Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift; then cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 limits   (memory lines)
```

<details><summary>Probe output</summary>

```text
#expect(analysis.status.stopReason == .memoryBudget || analysis.status == .optimal)
memory budget 2000 test-config: noSolution(stoppedBy: memoryBudget) obj nil nodes 18 open 19
memory budget 200000 det: optimal obj 593 nodes 2119 open 0
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated medium, documented: no</summary>

The finding holds. I reproduced it with my own oracle, not the finder's: the test's exact configuration with no binding budget, plus CP-SAT for the optimum.

1. \*\*What the test checks.\*\* Line 246 of `memoryBudgetDegradesThenStops` is `stopReason == .memoryBudget || status == .optimal`. The first solve is checked only through its status. The second solve (default config, 16 MiB, expects `.optimal`) does not depend on the budget.

2. \*\*Counterfactual.\*\* I ran the test's exact configuration, `BranchAndBound(nodeSelection: .bestBound, heuristics: .none)`, with `memoryBudgetBytes` set to nil (25% of RAM) and to `Int.max`. That is the status a solver that ignores the budget would return. Both gave `optimal obj 593`, and the line-246 predicate is TRUE. `CPSAT()`, a different algorithm, independently gives `optimal 593`.

3. \*\*Budget scan.\*\* I scanned 20 budgets from 1 B through 1 MiB, plus nil:
- Every finite budget stops with `noSolution(memoryBudget)`; even 1 MiB stops after 2 274 nodes.
- Only nil completes.
- The predicate is false for 0 of the 20.

So with the real implementation the `.optimal` half is unreachable at 2 000 B. It admits only a solver that ignores the budget, or under-counts it by more than 500 times.

4. \*\*The "degrades" step exists, is observable, and no test covers it.\*\*
- \*\*Code.\*\* In branch and bound with Simplex, only `SearchTree` reads the budget (BranchAndBound.swift:208 passes it in; SearchTree.swift:436-461 checks it). Over budget, the tree first strips parent states (lines 437-458). It closes with `.memoryBudget` only if it is still over (line 461).
- \*\*Execution\*\* (`deterministic: true`, threads 1, 3 identical runs each):
- 64 000 B: `optimal 593`, 2 353 nodes, 18 177 LP iterations, against 18 155 unbudgeted on the same 2 353 nodes. Those are warm starts from the root after stripping.
- 32 000 B: `optimal 593`, 2 394 nodes.
- 24 000 B: `feasible(memoryBudget)`, with the incumbent kept.
- \*\*Regression.\*\* A version without the degrade step would stop at 32-64 KB.
- \*\*No test catches that.\*\* In the internal SearchTree tests every tree uses `memoryBudget: .max`, and no test inspects `parentState`. All five end-to-end budget tests (BranchAndBoundTests:246; L7 at 16 MiB, 4 096 B and 0 B; `everyExitPathOfEveryEngine` at 512 B) accept any `.memoryBudget` stop.

A test that could tell the two apart was easy to write: deterministic mode, 64 000 B, expect `optimal 593`.

5. \*\*What limits the impact.\*\* As the finder notes, the "stops" half is asserted strictly elsewhere: L3ToL10Tests.swift:207 (4 096 B) and :336 (512 B). The package's behaviour matches README §2: the open nodes stay under the budget, and the search ends at it.

6. \*\*Documentation.\*\* Neither README nor HANDBOOK mentions this weakness. HANDBOOK §Testing says "The liveness rules of §12.2 each have a test", which overstates coverage of L7's degrade clause. Documented = false.

7. \*\*Severity.\*\* Medium, independently of the finder's low. This is literally "a test that cannot catch the bug it is named for": it can catch neither an ignored budget nor a missing degrade step, and the degrade half has no coverage anywhere in the suite. It is not higher because the package itself behaves correctly and the stop is covered by other tests.

8. \*\*Minor notes.\*\* Node counts at 2 000 B vary between 19 and 22 in non-deterministic mode; the finder saw 18. The doc-comment clause "keeping whatever incumbent exists" is never exercised either, because `heuristics: .none` means no incumbent exists.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V112 -c release && for m in test oracle scan degrade repeat; do perl -e 'alarm shift; exec @ARGV' 900 .build/release/V112 $m; done
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-08-combined.md`.

</details>

#### <a id="a4-09"></a>A4-09 · .boundImproved events of a parallel search can arrive out of order (a later event reports a weaker bound)

- **Severity:** low (finder) · **Category:** concurrency · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:119-120
- **Claim tested:** SolverEvent.boundImproved names an improvement; EventSink 'serializes the events of one solve ... and enforces their order' (Sources/ZTronLPCore/Solve/Strategy.swift:222-224), which only promises .finished last.
- **Observed:** 20 parallel runs (8 threads) on mod008, p0201, misc03, lseu and randomMILP(14,50,s21): in 2 runs one .boundImproved event reports a lower bound than the one before it (mod008 run 0: 941 bound events, 1 drop; lseu run 2: 3382 events, 1 drop). newIncumbent events, the final event and the event counts were consistent.
- **Why it is wrong:** Each worker reads progressEvents() from the tree actor and emits them to the sink in a separate hop, so two workers can deliver their events in the opposite order to the one in which the tree produced them. A consumer plotting the bound sees it move backwards.
- **Documented:** Not documented; no explicit monotonicity claim exists, hence low.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 events
```

<details><summary>Probe output</summary>

```text
mod008 run 0: bound events 941 drops 1; incumbent events 4 non-improving 0; last event 307 final 307
lseu run 2: bound events 3382 drops 1
SUMMARY events runs=20 boundNonMonotone=2 incumbentNonImproving=0 lastIncumbentEventNotFinal=0
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

The defect is real. I confirmed it by reading the code and by running it with an oracle independent of the finder's.

Mechanism:
- SearchTree.progressEvents (SearchTree.swift:531-547) emits .boundImproved only when provenBound > lastBound + 1e-9·max(1,|b|), then sets lastBound. lastBound is written nowhere else, so the tree produces a strictly increasing sequence.
- Each worker delivers its batch to the EventSink in a separate actor hop (TreeSearch.swift:119-120). Nothing orders those hops across workers, so a worker holding an older, lower bound can reach the sink after one holding a newer bound.
- BranchAndBound.swift:319 makes the same call before the workers start, so it cannot race.
- CP-SAT does order its events on purpose: its store queues them and drains them in acceptance order (Portfolio.swift:53-56, 115-123).

Independent oracle (slot V115):
- Contract view: count delivered bound events that do not improve on the running maximum of all earlier delivered bounds, strictly and at the package's own 1e-9 threshold, plus inverted pairs.
- Cause view: the sorted delivered multiset must be a sequence the tree could have produced (strictly increasing by more than the threshold). If it is, a drop can only be a reordering.
- Witness: each stale event's gap field must exceed that of the event it follows, as an earlier snapshot would.
- Validity: every bound must be at or below the published MIPLIB optimum.
- Controls: one worker (threads 1), deterministic:true (also one worker), and CP-SAT as a contrast.

Results (release build):
- Parallel B&B: 160 runs (2, 4 and 8 threads; P and D engines; lseu, mod008, p0201, misc03). 46 runs had at least one stale event; 75 stale events out of about 393k bound events.
- Every stale event passes both cause checks (75 of 75 permutation-consistent, 75 of 75 with a larger gap).
- Drops range from 4.5e-6 to 0.103 (relative 1.5e-8 to 1e-4), all well above the 1e-9 threshold. Displacement reaches 5 positions.
- Single-worker controls: 0 stale events in about 104k. About 20 would be expected at the parallel rate, so the chance of none is about e^-20.
- CP-SAT with 8 workers: 0 stale.

Nothing else is affected:
- 0 bounds above the optimum.
- 160 of 160 parallel runs .optimal at the reference optimum, with the final bound equal to it.
- .finished last and unique in every run.
- 0 non-improving .newIncumbent events and 0 backward .nodes events.

Contract: nothing published promises monotone bound events.
- EventSink's doc, README §2.3 "enforces their order" and rule L10 ("event delivery is monotone — .finished is the last event, delivered exactly once") define order only as .finished last and unique, which holds. Serialization (rule C2) also holds.
- The implied contract is still broken: the case name .boundImproved, the internal doc "an improved bound" and CP-SAT's deliberate ordering all imply each event improves on the last.
- No document mentions it. README §4 "Parallel search is not reproducible" and risk 8 cover variation between runs, and risk 15 is a generic interleaving risk with nothing about events. So documented=false.

Severity, rated independently: low. It is a small inconsistency in the progress stream. Each stale value is still a valid lower bound, only weaker, and the next event supersedes it. Results, statuses, the final bound and .finished are unaffected.

Side observation (not verified): TreeSearch.offer (lines 317-321) uses the same two-hop pattern for .newIncumbent. It never misordered here because incumbents are rare.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V115 -c release && perl -e 'alarm shift; exec @ARGV' 580 .build/release/V115 repro 10 lseu,mod008 4 && perl -e 'alarm shift; exec @ARGV' 580 .build/release/V115 control 5 lseu,mod008
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A4-09-combined.md`.

</details>

#### <a id="b4-06"></a>B4-06 · deterministic: true gives a different search with threads = 1 than with threads >= 2

- **Severity:** low (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-06](#a4-06) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:581-597. runProbes calls budget.borrow; when extra == 0 the probes run inline on the worker engine. The test pin is at Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:301 (context.threads = 4).
- **Claim tested:** README §3 risk 8: 'deterministic: true on BranchAndBound and CPSAT runs a single worker with a fixed seed'. README §4 Limits: 'Parallel search is not reproducible unless deterministic: true, which uses one worker'. Read together, these say the result does not depend on SolveContext.threads.
- **Observed:** On misc03, deterministic with threads=1 takes 559 nodes and returns 3359.9999999999995. With threads 2, 3, 4, 8 and 16 it takes 1293 nodes and returns 3360.0, identically across those thread counts. On p0033 the counts are 1575 and 1605 nodes. Each thread count is reproducible run to run.
- **Why it is wrong:** runProbes runs the strong-branching and pseudocost probes inline on the worker's engine when the ConcurrencyBudget grants no slot, as with threads=1. Otherwise it runs them on fresh engines in child tasks. That changes the probe results and therefore the tree.  resolvedThreads defaults to activeProcessorCount, so a 'deterministic' run on a 1-core container differs from one on a laptop. The package's determinism test pins threads = 4, so it cannot see this.  Objectives agree to within 1 ulp, so this affects reproducibility, not correctness.
- **Documented:** Not documented. README §3 risk 8 and §4 Limits describe deterministic mode as one worker and do not say that the thread count matters.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F4 detthreads misc03,p0033
```

<details><summary>Probe output</summary>

```text
misc03: threads=1 gives 559 nodes and objective 3359.9999999999995; threads 2/3/4/8/16 give 1293 nodes and 3360.0, with identical fingerprints. p0033: 1575 nodes against 1605.
```

</details>

#### <a id="b4-07"></a>B4-07 · The SolutionAnalysis.bound doc says it 'equals objectiveValue when optimal', which is false for a MILP that is optimal by gap

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A5-05](#a5-05): same doc comment, SolutionAnalysis.bound (Analysis.swift:22)
- **Location:** Sources/ZTronLPCore/Solve/Analysis.swift:22
- **Claim tested:** Sources/ZTronLPCore/Solve/Analysis.swift:22: 'Proven bound; equals `objectiveValue` when optimal.'
- **Observed:** max 10000x0 + 3.3xa + 2xb + 2xc s.t. 3xa+2xb+2xc &lt;= 4, binaries. BranchAndBound() returns status=optimal objective=10003.3 bound=10004.3 gap=9.997e-5. bound != objectiveValue under .optimal.
- **Why it is wrong:** For a MILP, .optimal means 'within the gap' (Status.swift:5). README §3 risk 10 gives the example that 'an incumbent of 1,000 with a bound of 999.95 is optimal'. The doc comment on the shared protocol tells users the bound equals the objective whenever the status is optimal, which is false for BranchAndBound.
- **Documented:** README §3 risk 10 describes the behaviour correctly; the doc comment contradicts it.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 && perl -e 'alarm shift; exec @ARGV' 120 .build/debug/F4 gap 3.3
```

<details><summary>Probe output</summary>

```text
Default gap: optimal 10003.3, bound 10004.3, gap 9.997e-5 (the true optimum is 10004). Tight gap: optimal 10004, bound 10004.
```

</details>

#### <a id="b4-08"></a>B4-08 · A nodeLimit equal to the node count of the complete search reports .feasible(nodeLimit) although the search proved optimality

- **Severity:** low (finder) · **Category:** other · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPBranchAndBound/SearchTree.swift:249 (in absorb: if let limit = nodeLimit, nodesProcessed >= limit, !closed { close(.nodeLimit) })
- **Claim tested:** Status.swift: '.feasible(stoppedBy:): An incumbent exists; optimality was not proven'.
- **Observed:** p0033, deterministic: the complete search takes 1605 nodes. nodeLimit 1605 returns feasible(nodeLimit) with objective 3089 and bound 3089 (gap 0), and nodeLimit 1606 returns optimal. misc03 behaves the same at 1293.
- **Why it is wrong:** SearchTree.absorb closes with .nodeLimit as soon as nodesProcessed reaches the limit, before next() can observe that no open node is left. A search that finished and proved optimality (bound == incumbent) is reported as stopped by a limit. This is conservative, with no false .optimal or .infeasible, but the status understates the result.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F4 exactlimit p0033
```

<details><summary>Probe output</summary>

```text
p0033, deterministic, needs 1605 nodes. nodeLimit 1605 gives feasible(nodeLimit), objective 3089, bound 3089. nodeLimit 1606 gives optimal. misc03 behaves the same at 1293.
```

</details>

#### <a id="b4-09"></a>B4-09 · lpIterations counts each strong-branching probe as a fixed share of the probe cap rather than the pivots it took; the README §5 'LP pivots' columns inherit the synthetic count

- **Severity:** low (finder) · **Category:** performance-claim · **Confidence:** code-reading-only · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-07](#a4-07) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/TreeSearch.swift:597 and 637 (the probe cap is set at TreeSearch.swift:76)
- **Claim tested:** README §5 MIP table: the 'LP pivots' columns, and 'The primal node engine, the default, takes between 0.60 and 1.65 times the LP pivots of the dual one'. BranchAndBoundAnalysis.lpIterations.
- **Observed:** runProbes returns candidates.count \* 2 \* limit / 4 as the iteration count of its probes, whether they run inline or in parallel and whatever they actually took. With probeIterationLimit 50, that is 25 pivots per candidate (12.5 per probe).
- **Why it is wrong:** A pivot count that is partly synthetic cannot support a comparison of pivot counts between node engines. The README's ratio and its 'LP pivots' columns mix real node pivots with a fixed allowance per probe. In my runs the primal/dual ratio ranged from 0.40 (enigma) to 1.76 (stein45). Parallel runs vary, so the range itself is not the finding.
- **Documented:** Not documented. README §5 presents the counts as LP pivots.

**Reproduction**

```sh
sed -n '596,597p;637p' Sources/ZTronLPBranchAndBound/TreeSearch.swift; cd verification/probes/cycle-B && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 miplib all primal,dual 400
```

<details><summary>Probe output</summary>

```text
Line 596 reads '// Probe iterations are bounded by the cap; count the cap's worth at most.', and lines 597 and 637 return (results, candidates.count * 2 * limit / 4). In the miplib run, stein45 took 568972 primal pivots against 322860 dual (1.76x), and enigma 80549 against 199349 (0.40x).
```

</details>

#### <a id="a4-10"></a>A4-10 · Every unbounded relaxation is answered .infeasibleOrUnbounded, even for an evidently unbounded integer model; the status's doc comment attributes it to the interior point only

- **Severity:** info (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not verified: info items are recorded only.
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:255-261
- **Claim tested:** SolveStatus.infeasibleOrUnbounded: 'The solve could not tell infeasible from unbounded (interior point without a homogeneous self-dual embedding)' (Sources/ZTronLPCore/Solve/Status.swift:11-13).
- **Observed:** min -x - y, x - y &lt;= 1, x,y >= 0 integer (unbounded along x = y = k), a mixed model with an unbounded continuous column, and an LP-unbounded but integer-infeasible model (2x - 2y = 1): all 11 configurations -> .infeasibleOrUnbounded. No false .optimal or .unbounded.
- **Why it is wrong:** The answer is never wrong, but B&B is a second source of this status that its doc comment does not mention, and it does not try to find an integer point when one exists trivially.
- **Documented:** Tested as intended behaviour (BranchAndBoundTests.swift:110-111).

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F4 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/F4 special
```

<details><summary>Probe output</summary>

```text
milp-unbounded [expect unbounded|infeasibleOrUnbounded]: P-default=infeasibleOrUnbounded/nil ... P-t1=infeasibleOrUnbounded/nil
```

</details>

### <a id="f5-cpsat"></a>F5 CP-SAT

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** The CDCL core holds up on everything checked: all 2,000 SATLIB uf50/uuf50 instances (uuf cross-checked by an independent DPLL), 1,200 random 3-SAT formulas, about 3,000 small and mid-size integer programs against exhaustive enumeration across 10 configurations (LP propagator on and off, deterministic, 2 and 8 workers, no sharing, every restart policy, tight memory budgets, hints), wide domains against an exact oracle, the 7 pure-integer MIPLIB 3 optima, determinism, time limits and cancellation. The serious defect is in loading the model: a 4-ulp snap tolerance silently rounds in-domain data at magnitudes of 2^49 or more (about 5.6e14). The result is wrong answers labelled .optimal, for example objective 8 where only 0 is feasible, with bounds and rows violated by 4 (A5-01). The bound limit is also really 2^53-5, not the documented 2^53. A coefficient of 1e-10 is zeroed instead of rejected and ends in internalInconsistency (A5-02). The tests named for large data stop below 2^50 and cannot catch A5-01 (A5-03). There are two low-severity mismatches between the doc comments and the analysis fields (A5-04 winningWorker, A5-05 bound). The trigger for A5-01 is narrow, but the README places it inside the accepted domain.

Claims and properties that held: 14.

Not checked:

- README §5 timing and latency figures on a quiet machine (load average 100-600 during this run; only orders of magnitude compared)
- Rule L7 memory behaviour on large models (memoryBudget stop with an incumbent was only exercised by the existing tests)
- Clause-sharing soundness under adversarial interleavings beyond random parallel runs (TSAN gate green in the baseline)
- LP-propagator reduced-cost fixing and lazy explanations checked in isolation (only end-to-end against oracles)
- CP-SAT through the Portfolio, Conditioned and Automatic facades, and makeEventStream buffering with CP-SAT
- Debug-build behaviour of the probes (all probes ran in release)

Further notes (not verified):

- A NaN row upper bound is silently treated as no bound (max x, x&lt;=5, row x &lt;= NaN -> optimal 5) instead of an error (F5\_ONLY=D11 domain).
- deterministic: true with the default lpPropagator: true also climbs one step per incumbent when the model has no linear row for the relaxation (bounds only or clause rows only); the CPSAT doc names only lpPropagator: false (D5 det: feasible(timeLimit) at 2.6e6 of 5.6e14 after 20 s, parallel solves it at once).
- README risk 10 advice 'keep objective values below 10^4' is not enough with non-integral costs or a large objective constant: max 1e-6x + 3.5 returns x=1 instead of 7 labelled optimal (within the documented gap; the CPSAT doc comment states the step rule correctly).
- Cross-area, for the branch-and-bound/simplex finder: BranchAndBound(deterministic: true) on the A5-01 model (x fixed at 2^52+1, x + y &lt;= 2^52+1, max y) returns optimal obj=10 with x=4503599577830908, a fixed bound violated by 4.95e7 (F5 xcheck).
- SATTests run only the first 100 of 1000 files of each SATLIB family; a missing corpus disables them through .enabled(if:) rather than recording the known issue the HANDBOOK describes (my probe ran all 2000 files: all pass).
- A deterministic run that stops at its time limit is not reproducible (p0201 detnolp 1 s: 9595, 9535, 9595), although the CPSAT doc says 'identical results'; this is inherent to wall-clock limits.

**Cycle B (oracles first).** Cycle B, area F5 (CP-SAT), oracles first. The CDCL core held on every check: all 1000 uf50 instances SAT with verified models, all 1000 uuf50 UNSAT, 700 random 3-SAT formulas cross-checked with an independent DPLL, 7280 exhaustive-enumeration solves with integral costs, a Diophantine oracle on wide domains, invariance checks, determinism, portfolio, time limit and cancellation on ordinary hard models, and the seven MIPLIB 3 pure-integer optima with the default configuration. Six findings. Two are critical wrong answers, both from CPModel's snap tolerance max(1e-9, 4 ulp). B5-01: exact integer bounds and right-hand sides of magnitude >= 2^50, inside the documented range, are widened by 1-4, so .optimal comes back at an infeasible point (x = 2^52-3 for x >= 2^52+1). B5-02: data the README says is rejected is silently rounded instead, giving a false optimum (0 vs 3 on an exactly feasible point) or SolverError.internalInconsistency. Both need magnitudes >= 2^48..2^50, or coefficients &lt;= 1e-9 off an integer. B5-03 (high): with decimal costs and |objective| &lt; 1, the fixed gap becomes an absolute 1e-4, so .optimal answers are up to 50x off (a one-column model returns 1e-06 with bound 5e-05), exactly where the CPSAT API doc promises an exact proof. README risk 10 has the formula but misstates the trigger and the mitigation. B5-04 (high): two parallel rows over a wide domain (x-y>=1, x-y&lt;=0 on \[0,1e9]) make one propagate() call run \~1.7e9 steps without a gate tick, ignoring the time limit, cancellation and the memory budget while RSS passes 10 GB. B5-05 and B5-06 are low: the 2^53 threshold is off by 4, and the SAT tests skip instead of reporting a known issue. Probe sources: verification/probes/cycle-B/Slots/F5/{main,Oracles,Probes}.swift; log: verification/cycle-B/F5-cpsat.md.

Claims and properties that held: 21.

Not checked:

- Thread Sanitizer / data races in CP-SAT (left to the baseline TSAN step; not re-run)
- Soundness of clause sharing and of learned or LP-derived clauses, beyond black-box answers (internal API not reachable from probes)
- Effect of warmStart .primalPoint hints (used only in gap probes; G3 hint did not produce the intended first incumbent, not investigated)
- README §5 CP-SAT timing and conflict numbers: load-dependent (machine load about 20), not judged
- Whether BranchAndBound shares the B5-03 gap behaviour (outside F5)
- Memory-budget accounting in normal long runs (only tiny budgets and the B5-04 case)
- How often B5-04-style propagation storms occur during search (not only at the root) on large-domain models
- Tests of ZTronLPCPSATTests were not re-run individually; integrity only skimmed (agrees helpers are strict, SAT tests skip without corpus)

Further notes (not verified):

- info: a NaN row bound in a hand-built CompiledLP is silently ignored (row dropped), CPSAT returns optimal -2 at (1,1): F5 domain D6h. Invalid input, the DSL rejects NaN
- info: a rejected model's .finished event carries status .numericalFailure('unsupported: ...'), a misleading label: F5 limits L7
- info: with objectives about 1e15 (documented >= 1e4 regime) default CPSAT stops far from the optimum, e.g. max x s.t. x &lt;= 2^50+5 -> 1125886577027174: F5 min M2
- info: CPSAT(lpPropagator:false, deterministic:true) climbs one step per incumbent on wide ranges (documented in the CPSAT doc): D4g/D7a feasible(timeLimit) after 10 s

</details>

#### <a id="a5-01"></a>A5-01 · In-domain data of magnitude >= 2^49 is silently rounded by a 4-ulp snap tolerance: infeasible points and wrong optima labelled .optimal

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** One skeptic confirmed it; the second check is pending.
- **Same defect:** [B5-01](#b5-01) (cycle B)
- **Related:** [B5-05](#b5-05): same 4-ulp snap, at the 2^53 edge
- **Location:** Sources/ZTronLPCPSAT/CPModel.swift:117-119 (snapTolerance), applied at :131 (integralScale), :173-174 (column bounds), :335 and :347 (row sides); Sources/ZTronLPCPSAT/LPRelaxation.swift:95,99; self-check Sources/ZTronLPCPSAT/CPSAT.swift:340-354
- **Claim tested:** README §2.5 CPSAT row: throws .unsupported only for ... 'bounds or scaled coefficients of magnitude 2^53 or more, or row activities beyond +-2^61'; README §4 Limits/CP-SAT: data accepted 'with bounds and scaled coefficients below 2^53 and row activities within +-2^61'; CPModel.swift header: 'CP-SAT works on pure integer programs in exact Int64 arithmetic', root domains 'rounded inward', fractional row bounds 'round inward'; README §4 Results: optimal means feasible to 1e-7; README risk 10: exact for integral costs below 1e4.
- **Observed:** (a) x fixed by xl=xu=2^52+1, y in \[0,10], row x + y &lt;= 2^52+1, maximize y (only feasible y is 0): .optimal obj=8, x=\[4503599627370493 (=2^52-3), 8]; CompiledLP.maxViolation = bounds 4, rows 4 (det, par, detnolp). (b) (1e15+0.5)x + y >= 1e15+1, x binary, y in \[0,3], min y (true optimum 1): .optimal obj=0, x=\[1,0], maxViolation rows 0.5. (c) max x with x in \[0, 2^52+1]: .optimal x=2^52+5 (bound +4); 2^51+1 -> 2^51+3; 2^50+1 -> 2^50+2; mirrored for lower bounds. (d) rows x &lt;= 2^50+1 / 2^52+1 return 2^50+2 / 2^52+5; a=2^40+1, x&lt;=1e6, a\*x &lt;= 989560464999299968 returns x=900000 (exact max 899999). (e) the effective rejection limit is not 2^53: xu=2^53-1 and 2^53-4 throw .unsupported 'too large', xu=2^53-5 returns x=2^53-1 (bound and row +4).
- **Why it is wrong:** All data is exactly representable, below 2^53, with activities far inside +-2^61, i.e. inside the documented domain, so it must be solved exactly or rejected. CPModel.snapTolerance = max(1e-9, 4\*ulp(v)) counts any value within 4 ulp of an integer as that integer and is added outward to column bounds and row sides; at |v| >= 2^49 that is 0.5 to 4 units, so the integer model searched is a widened one. The returned points violate the model as given (visible in Double, reported by the package's own maxViolation), and in (a) and (b) the objective is wrong by 8 and by 1 at objective values far below 1e4. The end-of-solve self-check CPSAT.violation uses a 1e-6 relative tolerance and cannot see violations of a few units at 1e15. Trigger is narrow (data >= \~5.6e14), but the answer is a wrong .optimal.
- **Documented:** Not documented. README promises exact handling below 2^53; the 4-ulp snap appears only in a code comment (CPModel.swift:113-116, 'so that noise in large data is not mistaken for a fraction'). README risk 10 claims exactness for integral costs below 1e4, which (a) contradicts.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F5 -c release && F5_ONLY="D14,D14c,D5,D6,D8,D15" F5_LIMIT=2 perl -e 'alarm shift; exec @ARGV' 300 .build/release/F5 domain   (probe sources: Slots/F5/Claims.swift runDomain; cross-engine: .build/release/F5 xcheck)
```

<details><summary>Probe output</summary>

```text
D14c x in [2^52+1, 2^52+1], row x + y <= 2^52+1, max y (true opt 0) [det]: optimal obj=8 bound=8 x=[4503599627370493,8] maxViolation(bounds=4.0, rows=4.0)
D14 coef 1e15+0.5, rhs 1e15+1, min y (true opt 1) [par]: optimal obj=0 bound=0 x=[1,0] maxViolation(bounds=0.0, rows=0.5)
D5 bound 2^52+1 max x [par]: optimal obj=4503599627370501 x=[4503599627370501] maxViolation(bounds=4.0, rows=0.0)
D15 xu=2^53-1 [det]: THROW unsupported: the bounds of column x1 are too large for exact integer arithmetic
D15 xu=2^53-5 [par]: optimal obj=9007199254740991 maxViolation(bounds=4.0, rows=4.0)
```

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

Contract lens. The package promises that CP-SAT is exact inside a stated domain, and these inputs are inside it.
- README §2.5 and §4 Limits accept CP-SAT data with bounds and scaled coefficients below 2^53 and row activities within ±2^61.
- README risk 10 and the public `CPSAT` doc comment (CPSAT.swift:85-88) say the proof is exact for integral costs while the objective is below 1e4.
- README §4 Results says optimal means feasible to 1e-7. `maxViolation` is absolute, and CP-SAT does not scale.
- Internal comments say "exact Int64 arithmetic", "integral within 1e-9", "Root domains, rounded inward" and "fractional row bounds round inward".
- A test comment (AcceptanceTests.swift) says only bounds beyond 2^53 cannot be read exactly.

Nothing public documents the 4-ulp snap. README, HANDBOOK, SPECIFICATION-v0.2 and the docc catalog have no ulp or noise statement for CP-SAT, and no test covers data between 2^49 and 2^53.

The causal story holds in the code:
- `snapTolerance` = max(1e-9, 4·ulp) (CPModel.swift:117-119).
- It is added outward: column bounds at :173-174, row sides at :335 and :347, and LPRelaxation.swift:95,99.
- For an exact integer v with |v| >= 2^50, floor(v + tol) = v + floor(tol). The bound moves outward by 1, 2 or 4. That contradicts the function's own doc, which says a value "count\[s] as that integer". It is an implementation error, not noise snapping.
- From 2^49 up, the integrality test at :131 treats a fraction of 0.5 as noise. So 1e15+0.5 becomes 1e15+1, where README's rule would reject it: it needs scale 10, which gives 1e16+5 >= 2^53.
- The self-check `CPSAT.violation` uses a 1e-6 relative tolerance (about 4.5e9 at 4.5e15), so it cannot see these violations.

My own probe built the models through the public DSL. It reproduces the finder's numbers in all three CP-SAT configurations (deterministic, parallel, no LP propagator):
- A52: x fixed at 2^52+1, x + y &lt;= 2^52+1, maximize y. Returns .optimal obj=8 with x = 2^52-3, outside its fixed bound by 4. The exact optimum is 0.
- A50: the same at 2^50+1. Returns obj=2, violation 1. Exact optimum 0.
- A48 control: correct, which confirms the threshold.
- B: returns obj=0 with a row violated by 0.5. Exact optimum 1.
- C: x &lt;= 2^52+1 returns 2^52+5.
- D: a row at 2^49+0.5 returns 2^49+1, where inward rounding gives 2^49.
- E: xu = 2^53-1 and 2^53-4 throw .unsupported; xu = 2^53-5 returns 2^53-1.

The deterministic configuration is not timing-dependent, and the finder reproduced the same numbers independently through `CompiledLP`.

Why none of the refutations hold:
- Not a misuse: the data are exactly representable and inside the documented domain.
- Not within a documented tolerance: the objective is wrong by 8 at an objective of 8, far below 1e4, and an absolute bound is violated by 4.
- Not by design: the snap is meant to absorb noise, yet it moves exact integers.
- Not documented.

Severity is critical on the given scale: .optimal with an infeasible point and a wrong objective. The trigger is narrow: fractional data of at least 2^49 (about 5.6e14) or integral data of at least 2^50 (about 1.1e15), plus an explicit CPSAT or a Portfolio containing it. `Automatic` sends integer models to `BranchAndBound`. One minor corollary (low): the effective rejection edge for bounds is 2^53-4, not 2^53, which does not match README §2.5.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V122 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V122
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A5-01-contract.md`.

</details>

#### <a id="b5-01"></a>B5-01 · Integer bounds and row bounds of magnitude >= 2^50 are widened by 1 to 4 units; CP-SAT returns .optimal at a point that violates them

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** One skeptic confirmed it; the second check is pending.
- **Same defect:** [A5-01](#a5-01) (cycle A)
- **Location:** Sources/ZTronLPCPSAT/CPModel.swift:117-119 (snapTolerance = max(1e-9, 4\*ulp)) applied as (xl - tol).rounded(.up) / (xu + tol).rounded(.down) at CPModel.swift:173-174 and to row bounds at CPModel.swift:335 and :347; same at LPRelaxation.swift:95 and :99. For |v| >= 2^50, 4 ulp >= 1, so an integral bound moves outward by floor(4 ulp) = 1, 2 or 4.
- **Claim tested:** README §2.5 (CPSAT row) and §4 'Limits by design': CP-SAT accepts bounds and scaled coefficients below 2^53 and rejects only magnitudes of 2^53 or more; CPModel.swift header: 'CP-SAT works on pure integer programs in exact Int64 arithmetic', 'Root domains, rounded inward to integers'.
- **Observed:** With default CPSAT(): x integer in \[2^52+1, 2^52+10], min x -> .optimal x = 4503599627370493 (= 2^52-3), CompiledLP.maxViolation bounds = 4.0. x in \[2^50+3, 2^50+8] -> .optimal x = 2^50+2 (violation 1.0). x - y = 2^52+1, x in \[0,2^52+3], y in \[0,10], min x -> .optimal (2^52-3, 0), row violation 4.0. x in \[0, 2^53-5], max x -> .optimal 2^53-1 (violation 4.0). With CPSAT(deterministic: true): max x s.t. row x &lt;= 2^50+5 -> .optimal x = 2^50+6. 127x - 125y >= 1 over \[-2^52, 2^52] -> y = -(2^52+4).
- **Why it is wrong:** The bounds are exact integers, exactly representable in Double and inside the accepted range; the returned point is infeasible in exact arithmetic (and by the package's own maxViolation), yet labelled .optimal. CPSAT.violation's relative 1e-6 safety net cannot see a violation of 4 at 4.5e15.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F5 -c release && .build/release/F5 min   (lines M1, M1b, M2b, M8b); .build/release/F5 domain   (lines D4d, D4e, D4f, D4g', D4h, D7c, D7d)
```

<details><summary>Probe output</summary>

```text
[M1 x in [2^52+1, 2^52+10], min x, CPSAT()] optimal obj=4503599627370493.0 bound=4503599627370493.0 x=(4503599627370493) maxViolation(bounds 4.0, rows 0.0); [M2b x - y = 2^52+1 ...] optimal x=(4503599627370493,0) maxViolation(bounds 0.0, rows 4.0); [M8b x in [0, 2^53-5], max x] optimal x=(9007199254740991) maxViolation(bounds 4.0, rows 0.0); [D4g' max x s.t. x <= 2^50+5, det LP] optimal x=1125899906842630
```

</details>

<details><summary>Skeptic, contract lens: confirmed, rated critical, documented: no</summary>

Contract lens: what the package promises, against what it does.

\*\*What is promised.\*\*
- README §2.5 (CPSAT row) and §4 (Limits by design) accept bounds and scaled coefficients below 2^53. They reject only magnitudes of 2^53 or more, so every model tested is inside the accepted domain and this is not misuse. The values are exact integers, exactly representable in Double.
- README §4 (Results) says "Optimal ... feasible ... to 1e-7". The `Tolerances.primalFeasibility` doc says "Bound/row violation allowed, after scaling", which is an absolute measure, and CP-SAT does not scale columns.
- The `SolveStatus.optimal` doc says "An optimal solution was found and proven".
- CPModel.swift:3 says "exact Int64 arithmetic". CPModel.swift:45 (`lower`/`upper`) says "Root domains, rounded inward to integers".
- The `snapTolerance` doc (CPModel.swift:113-119) describes integrality-noise detection ("how close to an integer a scaled value must be to count as that integer"). It does not describe turning an exact integer into a different one.
- Tests/ZTronLPCPSATTests/AcceptanceTests.swift:83 has the comment "Bounds beyond 2^53 cannot be read exactly from a Double". That implies values below 2^53 are meant to be read exactly. No test covers \[2^50, 2^53).
- Nothing in README §3 or §4, the HANDBOOK known gaps or SPECIFICATION-v0.2 documents any widening.

\*\*Why the gap does not explain it.\*\* README risk 10 (the MIP gap) covers only objectives of 10^4 or more. My cases use objectives of 0 to 10, where the README says CP-SAT's proof is exact.

\*\*Why a relative-tolerance reading does not save it.\*\* No CP-SAT tolerance is published. `CompiledLP.maxViolation` is absolute. The internal `CPSAT.violation` check (relative 1e-6) is documented as a bug detector ("A violation is a bug in the solver"), not as a contract. And objectives off by 2 to 8 at magnitudes 1 to 9 cannot be excused by relative feasibility.

\*\*Cause, confirmed by reading the code.\*\*
- `snapTolerance` is `max(1e-9, 4*ulp)`. It is applied outward before rounding at four places: the column bounds (CPModel.swift:173-174), the row upper side (:335), the row lower side (:347) and the LP relaxation's row sides (LPRelaxation.swift:95 and :99).
- For |v| >= 2^50, 4 ulp is a whole number of units (1, 2 or 4), so an exact integral bound moves outward by that many units.
- The 2^53 guard and the relative 1e-6 re-check both run after the widening and cannot see it.
- The DSL compile passes the declared bounds through exactly; the widening happens only in CP-SAT's loading.

\*\*Execution.\*\* My own probe in slot V122 built the models with the public DSL and solved each with CPSAT(), CPSAT(deterministic: true) and CPSAT(lpPropagator: false, deterministic: true).
- 23 of the 24 solves with a value of 2^50 or more returned .optimal at an infeasible point.
- 15 of those 23 (all the A and U cases) also have a wrong objective. For example, x+y >= 2^52+3 with x &lt;= 2^52, min y, returns 0 instead of 3. In the 2^51 case and the 2^52 case it returns 0; at 2^50 it returns 1.
- All 15 control solves below 2^50 (K=1000 and K=2^50-8) were exact, so the threshold is exactly 2^50.

\*\*Severity.\*\* Narrow exposure: the trigger needs magnitudes of about 1.13e15 or more, and CPSAT is used only when chosen explicitly or put in a Portfolio. That does not change the class: .optimal with an infeasible point or a wrong value is critical on the given scale. The finder's statements and line numbers are accurate.

Command:

```sh
cd verification/probes/cycle-B && swift build --product V122 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/V122
```

The skeptic's full notes, commands and output: `verification/cycle-B/verdicts/B5-01-contract.md`.

</details>

#### <a id="b5-02"></a>B5-02 · Coefficients that no power of 10 up to 1e6 makes integral (or whose scaling passes 2^53) are silently rounded instead of rejected: false optimum, or SolverError.internalInconsistency

- **Severity:** critical (finder) · **Category:** wrong-result · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A5-02](#a5-02) (cycle A)
- **Location:** Sources/ZTronLPCPSAT/CPModel.swift:122-139 integralScale: a value counts as integral when within snapTolerance = max(1e-9, 4 ulp) (CPModel.swift:117-119), so fractions &lt;= 1e-9, or &lt;= 4 ulp (0.25 at 2^48, 0.5 at 2^49), pass at scale 1; CPModel.swift:302 (rows) and :366 (objective) then round them. CPSAT.swift:286-290 turns the resulting violation into internalInconsistency.
- **Claim tested:** README §2.5 CPSAT row: 'Throws .unsupported for ... data that no power of 10 up to 1e6 makes integral, bounds or scaled coefficients of magnitude 2^53 or more'; §4 Limits: data must become integral when multiplied by a power of 10 up to 10^6. SolverError.internalInconsistency doc (Status.swift): 'A bug in the solver; never caused by user data.'
- **Observed:** (2^49+0.375)x + (2^49+0.375)y - (2^50+0.75)z = 0 over binaries, max x+y+z -> CPSAT() .optimal 0 at (0,0,0), although (1,1,1) satisfies the row exactly (CompiledLP.maxViolation 0) with objective 3. 1e-10 x0 + 1e-10 x1 >= 1e-10, min x0+x1 -> .optimal 0 (coefficients zeroed; true 1). max (2^49+0.5)x -> objective 562949953421313 (cost rounded). x - 1.0000000009 y >= 0 with y = 1e6, and (2^48+0.1875)x - 2^48 y &lt;= 0 -> SolverError.internalInconsistency('CP-SAT returned a point that violates row c1') instead of .unsupported. By contrast 1e-7 and 1.0000001 are rejected correctly.
- **Why it is wrong:** The README promises rejection for this data. 0.375 at 2^49 needs scale 1000 (5.6e17 >= 2^53), 1e-10 and 1.0000000009 need 10^10; instead they are accepted at scale 1 and rounded, which changes the feasible set (false optimum 0 vs 3, labelled .optimal) or trips the final violation check, so valid input gets an error documented as never caused by user data.
- **Documented:** Not in README/HANDBOOK. A code comment (CPModel.swift:113-116) calls the 4-ulp snap a guard against 'noise in large data'; README promises rejection instead.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F5 -c release && .build/release/F5 min   (lines M3, M4, M7, M7b); .build/release/F5 domain   (lines D2, D2b, D5a, D5b, D5b', D5d)
```

<details><summary>Probe output</summary>

```text
[M3 (2^49+.375)x + (2^49+.375)y - (2^50+.75)z = 0, binaries, max x+y+z, CPSAT()] optimal obj=-0.0 x=(0,0,0); truth: optimal 3 at (1,1,1); maxViolation at (1,1,1) = (bounds 0.0, rows 0.0). [M4 1e-10 ...] optimal obj=0.0 x=(0,0) maxViolation(rows 1e-10). [M7] THROW internal inconsistency: CP-SAT returned a point that violates row c1
```

</details>

#### <a id="b5-03"></a>B5-03 · With decimal costs and |objective| &lt; 1, CP-SAT stops up to 1e-4 (absolute) from the bound and reports .optimal: answers 2% to 50x off, where its API doc promises an exact proof

- **Severity:** high (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCPSAT/Portfolio.swift:105-113 (checkGap; allowed = max(absoluteGap, relativeGap \* max(1, |reportedObjective(best)|)) at :109); claim at Sources/ZTronLPCPSAT/CPSAT.swift:85-88.
- **Claim tested:** CPSAT doc comment (CPSAT.swift:85-88): 'The search stops as soon as the incumbent is within the MIP gap of §6.5 (relative 1e-4, absolute 1e-6) ... this is an exact proof whenever 1e-4·|objective| is smaller than that step'. README risk 10: inexactness is 'Medium on large objective values', 'for CP-SAT, keep objective values below 10^4'. SolutionAnalysis.bound (Analysis.swift:22): 'equals objectiveValue when optimal'.
- **Observed:** max 1e-6\*x, x integer in \[0,50] (one column, no row) -> .optimal objective 1e-06, bound 5e-05 (true 5e-05), with CPSAT() and CPSAT(deterministic: true). min sum\_{j=1..50} j\*1e-6 x\_j s.t. sum x\_j >= 1 -> .optimal 5e-05 (the worst feasible choice), bound 0, true 1e-06, in every configuration including CPSAT(). 1e-6-scaled knapsack -> .optimal 1.3e-05 (deterministic, no LP) and 2.3e-05 (4 workers) vs 2.4e-05. Exhaustive enumeration with costs scaled by 10^-ec (ec &lt;= 6): 109 of 2800 solves .optimal with a non-optimal value (0 of 7000 with integral costs).
- **Why it is wrong:** Step 1e-6 and |objective| &lt;= 5e-5, so 1e-4·|objective| &lt;= 5e-9 &lt; step: the doc promises an exact proof. The stop rule is diff &lt;= max(1e-6, 1e-4·max(1,|incumbent|)), which is an absolute 1e-4 (100 steps, 100x the 'absolute 1e-6' named) whenever |incumbent| &lt;= 1. Shrinking the objective, the README's mitigation, makes it worse. .optimal with bound != objectiveValue also contradicts the SolutionAnalysis.bound contract.
- **Documented:** Partly misstated. README risk 10 gives the formula max(1e-6, 1e-4·max(1,|incumbent|)), but it describes the trigger as large objective values (>= 10^4, integral costs), rates the impact 'low to medium' and advises keeping objectives below 10^4. The CPSAT API doc says these models get an exact proof. Wrong trigger, worse impact.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F5 -c release && .build/release/F5 min   (lines M5, M5b, M6, M6b, M6c); .build/release/F5 gap   (G2 lines); .build/release/F5 enum 4 400 6 6
```

<details><summary>Probe output</summary>

```text
[M6 max 1e-6*x, x in [0,50], CPSAT(deterministic: true)] optimal obj=1e-06 bound=5e-05 x=(1); [M5 min sum j*1e-6 x_j s.t. sum x_j >= 1, CPSAT()] optimal obj=5e-05 bound=0.0 (x_50 = 1); enum seed 4 ... costExp 6: 2800 solves, 109 failures, all 'NON-OPTIMAL .optimal', e.g. box-only model got -4.5e-05, true -8.8e-05, bound -8.8e-05
```

</details>

#### <a id="b5-04"></a>B5-04 · Root propagation of two parallel rows over a wide domain runs about 1.7\*U bound changes inside one propagate() call: time limit, cancellation and memory budget are ignored and RSS grows past 10 GB

- **Severity:** high (finder) · **Category:** hang · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCPSAT/CPWorker.swift:651-663: propagate() loops while true to a fixed point with no gate tick, propagation count or memory check. Each pass of propagateLinear (CPWorker.swift:785-807) tightens a bound by slack/a, about 1 unit, interning a new bound literal and trail entry. The only checks are in the search loop: gate.tick() once per propagate() call at CPSearch.swift:106, and the full check every 10,000 propagations between calls. A row whose rounded sides cross (CPModel.swift:326-352 adds each side separately) is not detected at load.
- **Claim tested:** CPSAT doc (CPSAT.swift:72-74): timeLimit and task cancellation end the search with .feasible(stoppedBy:) or .noSolution(stoppedBy:); memoryBudgetBytes bounds the learned clauses (rule L7). CPSearch.swift:10-12: 'the loop calls gate.tick() once per propagation round, and forces a full check ... at every restart and every 10,000 propagations'. README §5: CPSAT cancellation latency worst 4.43 ms.
- **Observed:** x - y >= 1 and x - y &lt;= 0, x,y integer in \[0, U], CPSAT(deterministic: true), timeLimit 1 s: U=1e7 -> .infeasible after 2e7 propagations, 0.60 s, 1.61 GB RSS; U=1e9 -> still running at 8 s (alarm, exit 142), 6.7 GB RSS. 652x - 552y = -1505 over \[0,1e9]^2 (infeasible by parity), timeLimit 2 s: CPSAT(), CPSAT(deterministic: true) and CPSAT(lpPropagator: false, deterministic: true) are all still running at 40 s (exit 142), max RSS 12.7 / 10.7 / 7.2 GB. memoryBudgetBytes = 100 MB: still running at 15 s, 10.2 GB. Cancel after 0.5 s (deterministic): no return within 3.5 s (7.3 GB). With the default 8 workers the cooperative pool is saturated, so even the cancelling task does not run.
- **Why it is wrong:** The model is valid and accepted (bounds &lt; 2^53, tiny activities). A time limit, a cancellation and the memory budget must end any solve; here none is checked until the fixed point, which takes \~1.7\*U steps at \~150 bytes each (U=1e9: about 1.7e9 steps).
- **Documented:** No. README risk 3 says a hard model ends .feasible or .noSolution at the limit; §5 reports CP-SAT cancellation worst 4.43 ms.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F5 -c release && /usr/bin/time -l perl -e 'alarm shift; exec @ARGV' 8 .build/release/F5 strip 1e9 ; /usr/bin/time -l perl -e 'alarm shift; exec @ARGV' 40 .build/release/F5 pingpong 652 552 -1505 1e9 default 2   (cfg det | detnolp; optional 8th argument memoryBudgetBytes, e.g. 100000000); .build/release/F5 strip 1e7 for the terminating scale; perl -e 'alarm shift; exec @ARGV' 4 .build/release/F5 pingcancel
```

<details><summary>Probe output</summary>

```text
[strip U=10000000.0] infeasible wall 0.60 s propagations 20000000, 1613627392 maximum resident set size; strip 1e9: 8.57 real, 6726828032 maximum resident set size, rc=142; pingpong ... 1e9 default 2: 41.54 real, 12699090944 maximum resident set size, rc=142; pingpong ... budget 100000000: 15.48 real, 10193813504 maximum resident set size, rc=142; pingcancel: 'cancelled at 0.5 s; waiting...' then rc=142 at 4.13 s, 7311441920 max RSS
```

</details>

#### <a id="a5-02"></a>A5-02 · A coefficient that no power of 10 up to 1e6 makes integral (1e-10) is zeroed instead of rejected, and the solve ends in SolverError.internalInconsistency

- **Severity:** medium (finder); skeptic: critical · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it and rated it critical; by the policy a second skeptic and a tiebreak are pending.
- **Same defect:** [B5-02](#b5-02) (cycle B)
- **Location:** Sources/ZTronLPCPSAT/CPModel.swift:122-138 (integralScale with snapTolerance) and :302-305 (zero coefficient dropped); Sources/ZTronLPCPSAT/LPRelaxation.swift:80-81
- **Claim tested:** README §2.5 CPSAT and CPSAT.solve doc: throws .unsupported for 'data that no power of 10 up to 1e6 makes integral'. CPSAT.run: a point that fails the final check is 'A bug, never a property of the model'.
- **Observed:** max x + y s.t. 1e-10 x + y &lt;= 1, x in \[0,1e9], y in \[0,1]: THROW 'internal inconsistency: CP-SAT returned a point that violates row c1' in det, par and detnolp. 1e-10 x &lt;= 0.05, x in \[0,1e9]: internalInconsistency (par), det climbs to the time limit. Control cases behave: 1e-7 and (4e-10, 1e-6) are rejected with .unsupported.
- **Why it is wrong:** integralScale accepts |v\*scale - round(v\*scale)| &lt;= max(1e-9, 4 ulp), so 1e-10 is the integer 0 at scale 1 and the term is dropped; CP-SAT then solves a different model and its self-check reports a solver bug. The documented outcome for such data is .unsupported; an internalInconsistency error tells the user the solver is broken.
- **Documented:** The 1e-9 snap is stated only in the CPModel.swift header comment ('integral within 1e-9'); README states rejection; the internalInconsistency outcome is not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F5 -c release && F5_ONLY="D3,D3b,D2,D3c" F5_LIMIT=3 perl -e 'alarm shift; exec @ARGV' 120 .build/release/F5 domain
```

<details><summary>Probe output</summary>

```text
D3 coef 1e-10 (README: expect unsupported) [det]: THROW internal inconsistency: CP-SAT returned a point that violates row c1
D3 ... [par]: THROW internal inconsistency ...
D2 coef 1e-7 [det]: THROW unsupported: row c1 has coefficients that no power of 10 up to 1e6 makes integral
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated critical, documented: no</summary>

I reproduced the finding in my own slot (V124), checked against two oracles of my own: an exact integer optimum (binary search with an error-free residual sign, using fma TwoProduct plus TwoSum) and a second engine, BranchAndBound.

C1 is the finder's D3: max x + y s.t. 1e-10 x + y &lt;= 1, x in \[0,1e9], built with the public DSL. All four CP-SAT configurations (det, par, detnolp, nolp) throw `internalInconsistency` ("violates row c1"). The exact optimum is 1e9 at x=1e9, y=0. C2 is the finder's D3b: par and nolp throw the same error, while det and detnolp honour the 3 s limit with a feasible incumbent.

Cause, read in the code: `integralScale` (CPModel.swift:122-138, line 131) treats |v·s - round(v·s)| &lt;= max(1e-9, 4 ulp) as integral. \[1e-10, 1] therefore gets scale 1, the coefficient rounds to 0, and the term is dropped at line 305 (and in LPRelaxation.swift:80-81 and in the objective loop).

Contract: README §2.5 and the `CPSAT.solve` doc comment say `.unsupported` is thrown for "data that no power of 10 up to 1e6 makes integral". 1e-10·10^k for k = 0..6 is never an integer, and no tolerance is stated. `SolverError.internalInconsistency` is documented as "never caused by user data". So the defect is real, and the snap is not a defence: it is intended only in internal comments, and the test that covers it is named `scalingToleratesFloatingPointNoiseOnly`.

Severity, my own rating: the reported symptom alone would be medium. But the same zeroing also gives:
- \*\*False `.infeasible`:\*\* C3b (CompiledLP: min z s.t. 1e-10 z >= 1, z in \[0,2e10]) and C3c (typed DSL with a two-term row) return `.infeasible` in all four configurations. The true optimum is 1e10, B&B agrees, and the package's own `maxViolation` at that point is 0.
- \*\*Wrong `.optimal` with a proven bound:\*\* C4 (CompiledLP), C4d (DSL) and C4f (`LPFormat.read`) solve max y s.t. 1e-10 x - y >= 0. All return optimal obj=0, bound=0; the true optimum is 1, and B&B agrees. C7 (objective path) returns optimal 0; the true optimum is -2.

These gaps are far outside the documented gap and tolerances, and the self-check cannot see them because the returned point is feasible or there is none. That makes the defect critical.

Controls where it holds up:
- C5 (x in \[0,10]): the drop changes the activity by only 1e-9, within the 1e-7 tolerance.
- C6: a &lt;= 1e-9 is silently zeroed, while 1.0000001e-9 through 1e-7 is correctly rejected. The cut-off therefore ignores the column range, which is the quantity that decides whether the drop is harmless.
- C3 through the DSL as a one-variable row is unaffected, because the singleton row becomes a bound before CP-SAT sees it.

Not documented: the README and HANDBOOK state rejection without a tolerance, and nothing documents the `internalInconsistency`, false infeasible or wrong optimal outcomes. The documented drop tolerance is `CompileOptions.dropTolerance` = 1e-14, reported with a `.droppedSmallCoefficient` diagnostic; CP-SAT's drop is silent.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V124 -c release && V124_ONLY="C1,C2,C3b,C3c,C4,C4d,C4f,C7,C6" V124_LIMIT=3 perl -e 'alarm shift; exec @ARGV' 240 .build/release/V124
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A5-02-combined.md`.

</details>

#### <a id="a5-03"></a>A5-03 · Tests named for large-data handling and inward rounding never reach the magnitudes where A5-01 fails

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Location:** Tests/ZTronLPCPSATTests/LPPropagatorTests.swift:398-436; Tests/ZTronLPCPSATTests/AcceptanceTests.swift:88-96, 204-212, 252-262
- **Claim tested:** LPPropagatorTests.dataNearTheLimitsOfInt64IsHandled ('push the integer combination towards the limits of Int64 ... the answer does not change'); AcceptanceTests.scalingToleratesFloatingPointNoiseOnly ('A large value that is not an integer is not mistaken for one'); AcceptanceTests.columnBoundsRoundInward; AcceptanceTests.largeButRepresentableDataIsAccepted.
- **Observed:** The largest data these tests use: activities of 1e15 (below 2^50), a fractional value 1.2e11, column bounds below 4. In the documented domain the named properties fail: 1e15+0.5 is taken as an integer (A5-01 b), bounds >= 2^50 round outward (A5-01 c). The suites pass in the baseline (debug, release, TSAN).
- **Why it is wrong:** Each test can only pass for data below 2^49, so none can catch the defect it is named for; the documented limits (2^53, 2^61) are only tested on the rejection side.
- **Documented:** not stated

**Reproduction**

```sh
cd . && swift test --filter 'ZTronLPCPSATTests.AcceptanceTests' (passes; baseline 03-test-debug.log line 1663) while cd verification/probes/cycle-A && swift build --product F5 -c release && F5_ONLY="D14,D14c,D5" .build/release/F5 domain fails
```

<details><summary>Probe output</summary>

```text
baseline 03-test-debug.log: 'Suite AcceptanceTests passed', 'Suite LPPropagatorTests passed'; probe: D14 optimal obj=0 (true 1), D5 2^52+1 -> x=2^52+5
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated medium, documented: no</summary>

The finding holds: none of the four named tests can catch the CP-SAT rounding defects, and the documented limits (2^53, 2^61) are tested only on the rejection side.

\*\*Test data (read from source).\*\* These are the largest values each test uses:
- dataNearTheLimitsOfInt64IsHandled: coefficients 1e9, bounds 1e6, activities 1e15.
- largeButRepresentableDataIsAccepted: 1e9, 2e9, 1e6.
- columnBoundsRoundInward: bounds below 4 in magnitude.
- scalingToleratesFloatingPointNoiseOnly: 123456789012.5 (about 2^36.8).

A grep of Tests/ZTronLPCPSATTests finds no accepted-model test with bounds or coefficients of 2^48 or more, or with activities near 2^61. The rejection tests use bounds of 1e17 and activities of 1.2e19 and about 4e18. All four tests pass now (targeted swift test run) and in the baseline debug and TSAN logs.

\*\*Independent reproduction (probe V127, public API only).\*\* The oracle needs no package code. All data are exact dyadic rationals, and feasibility and optimum are decided in exact Int64 by enumerating the domains. It allows for the documented CP-SAT gap (README risk 10). Every case ran deterministic, parallel, and deterministic without the LP propagator, each with timeLimit 10 s.
- \*\*Large non-integer coefficient.\*\* Row a\*x + y >= a + 0.5, x binary, y in \[0,3], minimise y; the true optimum is 1. a = 2^49+0.5 and a = 7e14+0.5 are inside the README's domain, because 10a &lt; 2^53. Both return .optimal obj=0 at a point that violates the row by 0.5. Values up to 2^48+0.5 are correct.
- \*\*Column bounds.\*\* I used gap-free models with a small objective. Exact integer bounds are moved outward by 1, 2 and 4 units at 2^50+5, 2^51+5 and 2^52+5, and .optimal comes back with y = 4, 5, 7 against a true 3. Fractional bounds round outward from 2^48.
- \*\*Integral row sides.\*\* Sides of 2^50 or more are widened by one unit: .optimal obj=0 against a true 1.
- \*\*Acceptance side of the 2^61 limit.\*\* Row (2^40+1)x &lt;= R gives x = M with the row violated by 192 to 232.
- \*\*Related path at the tests' own magnitude.\*\* A single-term row a\*x &lt;= 5a-1 with a from 1e9 to 2^40+1 returns .optimal x = 5 (true 4). At a = 1e8 the answer is right.

\*\*Mechanism (code).\*\* CPModel.snapTolerance = max(1e-9, 4 ulp) is added before rounding down and subtracted before rounding up, for column bounds (CPModel.swift:173-174) and row sides (:335, :347, and LPRelaxation.swift:95, 99). It also decides integrality (:131). From 2^50 on, 4 ulp is at least 1, so an exact integer moves outward to a different integer. The 1e-9 floor is applied after the row is divided by its common divisor (:316-335), so a unit offset over a divisor of 1e9 or more falls under it.

\*\*Contract.\*\* These results contradict what the package says it does:
- README §2.5 and §4: the accepted domain is bounds and scaled coefficients below 2^53 and activities within ±2^61; everything else throws .unsupported.
- The CPModel header: "exact Int64 arithmetic", "integral within 1e-9", "Root domains, rounded inward to integers"; the integralScale doc also says "within 1e-9".
- The package's own exact brute-force comparisons in its tests.

The 1e-7 feasibility tolerance is absolute after scaling (Tolerances doc), and the gap concerns only the objective, so these are defects, not cases inside a documented tolerance. No README or HANDBOOK section mentions the snap or the test gap, so documented is false.

\*\*Severity.\*\* Medium: per the rubric, a test that cannot catch the bug it is named for. The wrong answers themselves are A5-01 (critical).

\*\*Corrections to the finding.\*\*
1. The CP-SAT unit suites ran only in the baseline debug and TSAN steps. Step 04 (release) ran only the Integration and Liveness tests.
2. 1e15+0.5 is itself outside the accepted domain (10a >= 2^53), so the README's documented outcome for it is .unsupported. 2^49+0.5 and 7e14+0.5 are strictly in-domain cases with the same wrong answer.
3. "Below 2^49" is not a single threshold. Fractional bounds fail from 2^48, halves from 2^49 and exact integers from 2^50. The single-term-row case shows a failure at the tests' own magnitude of 1e9, with a structure the tests never use. This widens the finding rather than refuting it.
4. The link to the test names is direct for columnBoundsRoundInward and scalingToleratesFloatingPointNoiseOnly. It is weaker for dataNearTheLimitsOfInt64IsHandled, whose doc is about the LP propagator's integer combinations overflowing Int64, and for largeButRepresentableDataIsAccepted, which tests acceptance and still passes on that point.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V127 -c release && perl -e 'alarm shift; exec @ARGV' 900 .build/release/V127 T0,T2,T1u,T1l,T3,T4,T5   (contrast: cd . && swift test --filter 'AcceptanceTests/(columnBoundsRoundInward|scalingToleratesFloatingPointNoiseOnly|largeButRepresentableDataIsAccepted)|LPPropagatorTests/dataNearTheLimitsOfInt64IsHandled' passes)
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A5-03-combined.md`.

</details>

#### <a id="a5-04"></a>A5-04 · winningWorker of a parallel feasibility solve can name a worker whose solution was not the one returned

- **Severity:** low (finder) · **Category:** api · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Location:** Sources/ZTronLPCPSAT/CPSAT.swift:259 and :331; Sources/ZTronLPCPSAT/Portfolio.swift:68-69
- **Claim tested:** CPSATAnalysis.winningWorker doc (CPSAT.swift:372-375): 'the one that completed the proof (or, for a feasibility problem, found the solution)'.
- **Observed:** CPSAT(workers: 8) on the first 100 uf50-218 files: in 23 runs winningWorker is cpsat\[0] or cpsat\[1] while the only .newIncumbent event, whose model the store kept and returned, came from another worker (uf50-0104: winner 0, source cpsat\[6]; uf50-0103: winner 0, source cpsat\[2]).
- **Why it is wrong:** run() picks the lowest-index report with outcome .satisfied (CPSAT.swift:259, :331) while the IncumbentStore keeps the first model offered and rejects later ones of equal objective (Portfolio.swift:68-69), so the field does not identify the worker that found the reported solution.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F5 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F5 winner 100   (Slots/F5/Winner.swift)
```

<details><summary>Probe output</summary>

```text
uf50-0103.cnf: winningWorker=cpsat[0] incumbent sources=["cpsat[2]"]
winner: total=100 mismatch=23 multipleIncumbents=0
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

Code reading confirms the mechanism, and an independent oracle reproduces the defect.

Mechanism:
- A worker that completes an assignment always returns .satisfied. It discards the result of store.offer (CPSearch.swift:198-199 and :151-152).
- The store keeps only the first offer, because every objective of a feasibility problem is 0 and Portfolio.swift:69 rejects objective >= best.
- run() sorts the reports by index (CPSAT.swift:253) and sets winningWorker to the lowest-index .satisfied report (:259, :331), not to best.worker, whose values are returned.
- The stop flag is raised only after the worker's search returns (CPSearch.swift:67-69). Workers that are close to a solution can finish in that window.

Independent oracle, not the .newIncumbent source the finder used:
- CPSAT(deterministic: true) runs exactly worker 0 of a parallel run: same index, seed, phase and order, and no relaxation for a clause model. Clauses are exchanged only at restarts.
- All uf50 files need 0 restarts in the deterministic run, so worker 0 of a parallel run either is stopped or reports exactly that point, S0.
- Validated empirically: whenever the event source was cpsat\[0], the returned point equalled S0 (74/74, 95/95, 93/93), and CPSAT(workers: 1) returned S0 in 200/200.

Results:
- 8 workers: in 34/200 and 31/300 runs, winningWorker=0 but the returned assignment differs from worker 0's S0 in 1 to 20 of 50 variables.
- 4 workers (the package's own test config): 31/200 such runs.
- 1 worker (control): 0.
- The event-based mismatch rate is 20-25%, matching the finder's 23/100.
- The finder's oracle slightly overstates the rate: in 6 of 40 cases another worker had found the identical point. The defect stands without them.

Contract: the doc ties the field to the reported result ("found the solution", with a fallback to "the reported incumbent"). The field is biased toward low indices: worker 0 is named in 114/200 runs, but its point was returned in only 74.

Not documented: README §3 risk 8 covers run-to-run variation of the returned solution, not a field that disagrees with it. Nothing in README §4 or HANDBOOK mentions it. The existing tests only check != nil or the range, so none can catch it.

Severity low: every returned point satisfied all clauses, and status, objective and bound are unaffected. Only a diagnostic label is wrong, and nothing in the package reads it.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V130 -c release && perl -e 'alarm shift; exec @ARGV' 600 .build/release/V130 uf50 100 2 8
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A5-04-combined.md`.

</details>

#### <a id="a5-05"></a>A5-05 · bound differs from objectiveValue on .optimal results, contrary to two doc comments

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** The skeptic confirmed it.
- **Related:** [B4-07](#b4-07): same doc comment, SolutionAnalysis.bound (Analysis.swift:22)
- **Location:** Sources/ZTronLPCPSAT/CPSAT.swift:298-303 versus :361-362; Sources/ZTronLPCore/Solve/Analysis.swift:22
- **Claim tested:** CPSATAnalysis doc (CPSAT.swift:361-362): 'bound is the propagated bound of the objective row, and equals objectiveValue once optimality is proven'; SolutionAnalysis.bound (Analysis.swift:22): 'Proven bound; equals objectiveValue when optimal'.
- **Observed:** .optimal obj=3.500001 bound=3.500007 (max 1e-6 x + 3.5, x in \[0,7]); .optimal obj=562946402850150 bound=562949953421313 (max x, x &lt;= 2^49+1, parallel); .optimal obj=-2.3795703474867405e+17 bound=-2.3796833534450074e+17 (large-coefficient model, det).
- **Why it is wrong:** When the gap closes without exhaustion, run() deliberately reports the proven bound (CPSAT.swift:298-303), so .optimal does not imply bound == objectiveValue; a caller following the doc comments can read the wrong number.
- **Documented:** README risk 10 documents that .optimal means within the gap, but not that bound and objectiveValue then differ; the two doc comments state the opposite.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F5 -c release && F5_ONLY=D13 F5_LIMIT=3 .build/release/F5 domain
```

<details><summary>Probe output</summary>

```text
D13 obj 0.000001 x + 3.5, x in [0,7] max (expect 3.500007) [det]: optimal obj=3.5000010000000001 bound=3.5000070000000001 x=[1]
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

I reproduced the finding independently. In slot V133 I built the models through the DSL, not a raw CompiledLP. My oracles were my own exact enumeration in integer micro-units, an analytic upper bound, and my own brute force over 2^18 knapsack subsets.

C1 is max 1e-6·x + 3.5 with x an integer in \[0,7]; the true optimum is 3.500007. It returns status .optimal with obj=3.500001 and bound=3.500007 under det, detnolp and par4, deterministically. A variant with a genuine row does the same under detnolp: obj=3.5, bound=3.500007.

C6 has integral costs: max x with x in \[0, 1e12+1]. One par4 run returned .optimal with obj=999933992592 and bound=1000000000001.

The finder's own unchanged F5 binary also reproduces: det and detnolp give .optimal obj=3.500001 bound=3.500007. Controls that closed exactly gave bound==obj: knapsacks on all three CP-SAT setups and on BranchAndBound, plus C2, C4 and C5. So the mismatch only happens when the gap closes before the search is exhausted.

The code does this on purpose:
- CPSAT.swift:298-303 reports reportedObjective(best.lowerBound) when gapReached holds without exhaustion. Its own comment says "report the proven bound when it is the tighter statement".
- BranchAndBound.swift:352-353 does the same for .gapReached.

So status .optimal does not imply bound == objectiveValue. The protocol doc at Analysis.swift:22 ("Proven bound; equals `objectiveValue` when optimal") is therefore false as written. Execution shows this for CP-SAT; reading the code shows the same for branch and bound.

The CPSATAnalysis sentence ("equals objectiveValue once optimality is proven") could be read charitably. CPSAT.swift:85-88 says a gap stop is an exact proof only when 1e-4·|objective| is below the objective step, and every bound≠obj case I saw was a non-exact proof. That reading does not save the protocol comment, though. A caller sees status .optimal and reads "when optimal" as that status.

No number is wrong. Every bound was checked against the oracle and is a valid proven bound (at or above the true optimum for max). Every objectiveValue is attained by a feasible primal and lies within the documented MIP gap. So this is not a wrong answer: a caller who takes the doc comment at its word and reads bound as the attained optimum is off by at most the gap. That makes severity low.

Documented: the finder says README does not state that bound and objectiveValue differ. That undersells README risk 10. Its line ".optimal means incumbent − bound ≤ max(...) ... so an incumbent of 1,000 with a bound of 999.95 is optimal" describes exactly this behaviour. However, neither README §4 nor HANDBOOK's known gaps or not-verified sections say that the two doc comments state the opposite. The package contradicts itself without flagging it, so documented=false.

Command:

```sh
cd verification/probes/cycle-A && swift build --product V133 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V133 c1
```

The skeptic's full notes, commands and output: `verification/cycle-A/verdicts/A5-05-combined.md`.

</details>

#### <a id="b5-05"></a>B5-05 · Bounds of magnitude 2^53-4 to 2^53-1 are rejected although README rejects only magnitudes of 2^53 or more

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** The skeptic confirmed it.
- **Related:** [A5-01](#a5-01): same 4-ulp snap, at the 2^53 edge
- **Location:** Sources/ZTronLPCPSAT/CPModel.swift:173-178: hi = (xu + 4 ulp).rounded(.down) passes 2^53 before the |hi| &lt; 2^53 guard.
- **Claim tested:** README §2.5 CPSAT row: throws .unsupported for 'bounds or scaled coefficients of magnitude 2^53 or more'; §4 Limits: 'bounds and scaled coefficients below 2^53'.
- **Observed:** x in \[0, 2^53-1], max x -> SolverError.unsupported('the bounds of column x1 are too large for exact integer arithmetic'); x in \[-(2^53-1), 2^53-1] the same. x in \[0, 2^53-5] is accepted but widened to 2^53-1 (B5-01).
- **Why it is wrong:** 2^53-1 is below 2^53 and exactly representable, so per the README it should be accepted.
- **Documented:** README states the threshold as 2^53.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F5 -c release && .build/release/F5 min   (line M8); .build/release/F5 domain   (lines D4a, D4b)
```

<details><summary>Probe output</summary>

```text
[M8 x in [0, 2^53-1], max x, CPSAT()] THROW unsupported: the bounds of column x1 are too large for exact integer arithmetic
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

I reproduced the finding with my own oracle. The oracle is exact Int64 arithmetic plus the README's own threshold. Take one integer column with integral bounds L &lt;= U, no rows, and |L|, |U| &lt; 2^53. Then max x must return exactly U, min x must return exactly L, and only bounds of magnitude 2^53 or more may throw.

I built the model three independent ways:
- a hand-made CompiledLP (no DSL, no presolve);
- the DSL, with .integer(.range(0...9\_007\_199\_254\_740\_991));
- free MPS text read by MPSFormat.read.

Results:
- U = 2^53-1, 2^53-2, 2^53-3 and 2^53-4 all throw SolverError.unsupported('the bounds of column x1 are too large for exact integer arithmetic'). This happens with both CPSAT() and CPSAT(deterministic: true), and on all three construction paths.
- U = 2^53-5 and below are accepted.
- U = 2^53 and 2^53+2 throw, as the README says.
- The lower side is symmetric: L = -(2^53-1) and -(2^53-4) throw, -(2^53-5) is accepted. x in \[-(2^53-1), 2^53-1] throws.
- A second run gave the same results. The throw happens when the model is loaded, so it is not timing-dependent.

The cause is at CPModel.swift:173-178. The snap tolerance max(1e-9, 4 ulp) is added before the |hi| &lt; 2^53 guard, and at this magnitude it equals 4. In Double, (2^53-1)+4 = 2^53+3, which rounds to 2^53+4, and that fails the guard. So for bounds the real threshold is a magnitude of 2^53-4.

For coefficients the README threshold is exact. An objective coefficient of 2^53-1 is accepted and 2^53 is rejected, because the guard at CPModel.swift:130 has no shift.

Why the finding is not refuted:
- Wrong oracle? No. 2^53-1 &lt; 2^53 is unambiguous. The objective row activity (at most 2^53) is far inside ±2^61, and the error message names the column bounds.
- Misuse? No. The models are valid and fail the same way on every construction path.
- By design? No. The intended threshold is 2^53: the guard literal says so, and so does the comment in the package test AcceptanceTests.swift:83 ('Bounds beyond 2^53 cannot be read exactly from a Double'). That test only checks 1e17, so it cannot catch this. The shift of 4 is a side effect of the noise snap.
- Within a documented tolerance? No. README §2.5 says 'magnitude 2⁵³ or more' (README:324) and §4 says 'bounds ... below 2⁵³' (README:486-488). The HANDBOOK and the public doc comment of CPSAT.solve (CPSAT.swift:147-149) say nothing about the 4-ulp snap of bounds. Only the internal snapTolerance comment describes the 4-ulp rule, and it presents it as an integrality check.

So documented = false.

Severity is low. The failure is a clean, descriptive .unsupported error, not a wrong answer. It affects only 4 integer values on each side out of about 9e15, so the published number is off by 4: a minor number mismatch.

The same root cause produces B5-01. With CPSAT(), an accepted bound U = 2^53-5 (or 2^53-6, -8, -16, -2^20) returns .optimal with x = U+4. B5-01 is a separate finding, so I did not use it to rate this one.

Incidental, outside scope and not checked further: BranchAndBound() on x in \[0, 2^53-1], max x, returns .optimal with x = 9007199353820190. That is 99,079,199 above the upper bound, a relative error of 1.1e-8. It may be worth a look in area F4.

Command:

```sh
cd verification/probes/cycle-B && swift build --product V133 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V133 lower && perl -e 'alarm shift; exec @ARGV' 120 .build/release/V133 paths
```

The skeptic's full notes, commands and output: `verification/cycle-B/verdicts/B5-05-combined.md`.

</details>

#### <a id="b5-06"></a>B5-06 · SATLIB corpus tests are disabled, not reported as a known issue, when the corpus is missing

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle B (oracles first)
- **Verification:** The skeptic confirmed it.
- **Location:** Tests/ZTronLPCPSATTests/SATTests.swift:16,35,52
- **Claim tested:** HANDBOOK 'Testing': 'tests that need a missing instance report a known issue instead of failing'.
- **Observed:** Tests/ZTronLPCPSATTests/SATTests.swift:16, :35, :52 are @Test(.enabled(if: !Corpora.satlib(...).isEmpty, satlibHint)), so they are skipped. Only the MIPLIB corpus tests (Tests/ZTronLPIntegrationTests/CorpusTests.swift:115) use withKnownIssue.
- **Why it is wrong:** On a checkout without the fetched corpus, the three SATLIB tests (all of the uf50/uuf50 coverage) do not run and are not recorded as a known issue, contrary to the handbook.
- **Documented:** not stated

**Reproduction**

```sh
grep -n 'enabled(if' Tests/ZTronLPCPSATTests/SATTests.swift; grep -n withKnownIssue Tests/ZTronLPIntegrationTests/CorpusTests.swift
```

<details><summary>Probe output</summary>

```text
SATTests.swift:16: @Test(.enabled(if: !Corpora.satlib("uf50-218").isEmpty, satlibHint)); CorpusTests.swift:115: withKnownIssue("\(instance.name) has not been fetched; run Scripts/fetch-miplib.sh")
```

</details>

<details><summary>Skeptic, combined lens: confirmed, rated low, documented: no</summary>

The claim under test is HANDBOOK.md:152-154: "The MIPLIB 3 and SATLIB instances are fetched by the two scripts ...; tests that need a missing instance report a known issue instead of failing."

In this codebase "known issue" means Swift Testing's withKnownIssue. The HANDBOOK uses the term that way at :472, and README:713 does too.

I reproduced the finding by running the package's own tests, where the finder had only read the code. Corpora.root honours \$ZTRONLP\_CORPORA (Fixtures.swift:41-44), so I pointed it at an empty scratch directory. That simulates a checkout where the corpus was never fetched, without touching the repository.
- The three SATLIB tests (SATTests.swift:16, :35, :52) are reported as "skipped" with the satlibHint comment. The run ends "passed" with no known issue.
- In the same run, MIPLIBCorpusTests records "6 known issues" at CorpusTests.swift:116.
- So the HANDBOOK sentence holds for MIPLIB 3 and is false for SATLIB.
- My V136 probe counts .cnf files with POSIX readdir instead of Corpora.satlib and evaluates the traits word for word. It predicted exactly this: traits false on the empty root, true on the real corpus with 1000/1000 files.

Attempts to refute it failed.
- Oracle: the HANDBOOK sentence covers both corpora and uses "known issue" in the technical sense, so a skip is a different outcome.
- "By design" does not rescue it. The skip is deliberate and described in Fixtures.swift:3-6 and Scripts/fetch-satlib.sh:14 ("skipped while it is absent"). That only shows the package's own documents disagree, which is the mismatch. Fixtures.swift in turn calls the MIPLIB tests "skipped", which is wrong for MIPLIB.
- It is reproducible by execution.
- The finder's details check out. The lines are right, :115 is the only withKnownIssue for a missing corpus, and "all of the uf50/uuf50 coverage" is accurate, since Corpora.satlib is used only in SATTests.

Severity is low, a documentation mismatch.
- Without the corpus nothing fails, and the skip shows a hint naming the fetch script.
- CI fetches SATLIB in every job that runs tests.
- The always-on random 3-SAT and exhaustive-search tests still exercise the CDCL core.

Documented is false. Neither README §4 nor the HANDBOOK admits the mismatch, though the real skip behaviour is stated correctly in the two comments above.

Supplementary observation (info): with a partial family of 50 files, two SATLIB tests FAIL on #expect(files.count == 100), which also contradicts "instead of failing". satlibPortfolioAgrees passes having checked zero instances. The fetch script's count check makes that state unlikely.

Command:

```sh
mkdir -p <scratch> && cd . && ZTRONLP_CORPORA=<scratch> perl -e 'alarm shift; exec @ARGV' 580 swift test --filter 'ZTronLPCPSATTests.SATTests/satlib' --filter 'ZTronLPIntegrationTests.MIPLIBCorpusTests/branchAndBoundWithBothStrategies' 2>&1 | grep -E 'skipped|known issue|Test run with'
```

The skeptic's full notes, commands and output: `verification/cycle-B/verdicts/B5-06-combined.md`.

</details>

### <a id="f6-runtime"></a>F6 Runtime: cancellation, limits, events, concurrency, memory budget, Metal, Automatic, Portfolio

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** Cycle A / F6 probed the runtime of ZTronLPOptimizer (d9afebe) with about 30 executable checks in slot F6 plus the baseline logs. Most claims held: cancellation on standard problems (max 13 ms, no CPU after return), time limits as statuses and edge values, event-stream semantics (newest 256, .finished last, several consumers, no consumer), Portfolio race semantics, Automatic routing, B&B/CPSAT memory budgets, Metal thresholds, kernel agreement and the library-unavailable fallback, the lint claims and the TSAN baseline. Nine findings: one critical (A6-01: BranchAndBound stopped during the root's expansion reports bound = incumbent and gap 0, a false optimality certificate, reproduced on a random MILP and stein27, mod008, egout, and through Automatic); two high (A6-02: cancellation and time limits are not bounded regardless of problem size because interior-point factorizations, presolve and scaling are uninterruptible, giving 0.1-1 s latencies and 0.5 s overshoot; A6-03: Conditioned runs its whole analysis after a stop, about 0.34 s); four medium (A6-04 threads does not bound IPM or over-subscribed Portfolios; A6-05 Portfolio returns the first inconclusive result rather than the best; A6-06 an LPModel compile error leaves event-stream consumers waiting forever; A6-07 the L7 16 MB test never reaches its budget); two low (A6-08 the L1 time-limit test cannot fail in release; A6-09 the fp32 activity screen rejects feasible points with finite bounds above 3e38).

Claims and properties that held: 26.

Not checked:

- TSAN on ZTronLPSimplexTests, ZTronLPInteriorPointTests and ZTronLPOptimizerTests (own TSAN run not allowed; the baseline covers Integration, Liveness, BranchAndBound, CPSAT only)
- Systematic interleaving exploration beyond the 40-instance agreement sweep and random stops
- The precompiled metallib path (only compile-from-source and the library-unavailable fallbacks were exercised)
- End-to-end GPU pricing inside a simplex solve of >= 3,000,000 columns (the kernel was checked standalone at and above the threshold)
- The GPU rounding/activity path at >= 100,000 nnz through Automatic on a real MIP (README risk 14)
- iOS memory allowance and jetsam behaviour; devices other than the Apple M3 (iPhone latency, rule L8 UI-tick starvation)
- CPSAT's internal memory share under memoryBudgetBytes beyond the status checks
- Event-rate claims (progress every 100 pivots / 100 ms)
- Hour-long solves and long-running leaks
- Whether the debug build of timeLimitsAreHonouredPromptly would catch an ignored time limit (unlimited debug solve time vs 1.05 s)

Further notes (not verified):

- B&B node rate collapses under a binding memory budget (about 7,700 nodes/s, then 560 falling to 170 nodes/s): checkGapAndMemory copies and sorts the whole open list on every over-budget check (SearchTree.swift:436-461); F6 memory bnb-trace 6
- Portfolio(BnB, CPSAT) at timeLimit 0.3 s returned feasible 596 while each member alone reached optimal 599 (members get threads/2 and budget/2); 'never worse than its members' holds only against members run inside the portfolio
- timeLimit = -inf means no limit (non-finite = no deadline), documented only on Deadline.after
- README.md:714 lists the simplex, interior-point and facade targets as TSAN-clean, but the only TSAN command (ci.yml:65, HANDBOOK.md:177) runs the Integration, Liveness, BranchAndBound and CPSAT test targets
- MetalAccelerator.shared is process-global (actor-protected) state, the one exception to 'no global mutable state'
- Portfolio winner is the member's engine name; two members with the same engine name (for example two BranchAndBound() with different options) are indistinguishable
- Portfolio members' progress events come from separate EventSink actors and interleave without a common order (L10 still holds at the facade level)
- StopFlag's doc mentions stopping by a portfolio, but the Portfolio facade stops members through task-group cancellation
- No test covers Portfolio's inconclusive ranking, facade or Conditioned cancellation latency on large problems, or the Metal libraryUnavailable path

**Cycle B (oracles first).** Oracle-first audit of the runtime layer, using F6 probes (cancellation with idle-CPU checks, limits, budgets, event-stream suffix oracle, callback-concurrency probe, scripted and real Portfolio members, enumeration and netlib oracles, fp64 oracles for the Metal kernels) plus a broken-shader copy of the package. On moderate models, cancellation, time limits, memory budgets, events, thread limits for single engines, Automatic routing, Portfolio correctness and the Metal kernels all held. Six findings: Conditioned runs an uncancellable O(m^3) basis analysis after its inner solve stops, giving 317-778 ms cancellation latency and a 2x time-limit overrun at m=3,500 (high); InteriorPoint checks cancellation once per iteration, up to 621 ms on dense normal equations (medium); Portfolio returns the first inconclusive result to arrive rather than the best one (1008 vs 1090) (medium); Portfolio calls progress callbacks concurrently, so chained listeners disagree on event order (medium); the Metal kernel tests skip silently, and so pass, when the shader does not compile (medium); Portfolio exceeds threads=1 with several members (low).

Claims and properties that held: 19.

Not checked:

- TSAN on the simplex, interior-point and facade targets: README §5 claims no reports there, but the baseline TSAN step ran only Integration, Liveness, BranchAndBound and CPSAT, and I did not start my own TSAN run
- Precompiled default.metallib path (no Metal toolchain here); a solve end to end with a shader that fails to compile (only the test suite was run against a broken shader)
- Kernels at the real .automatic pricing threshold (3,000,000 columns): only .forced at up to 60,000 columns; the activity screen inside BranchAndBound at >=100,000 nonzeros under .automatic was not run end to end
- Memory (RSS) growth with an unconsumed event stream over a long solve: bounded by construction, not measured
- Ordering bugs in the shared search tree beyond differential checks against enumeration (no targeted interleaving fuzzing)
- Behaviour under an iOS memory allowance (os\_proc\_available\_memory path)
- Cancellation latency of the sparse-QR simplex and of Simplex at the 1,500-row dense-LU limit (only m=3,500 sparse-QR stays below 4 ms)

Further notes (not verified):

- info: InteriorPoint with threads=1 on the 100x1200 transport LP used 1.54 cores once (Accelerate internal threading?); re-runs gave 1.04 and 0.77 - not confirmed
- info: engineName does not identify the configuration (BranchAndBound(nodeLimit:3) and (nodeLimit:3000) are both 'BranchAndBound&lt;Simplex(.primal)>', Automatic's sparse-QR choice reports 'Simplex(.dual)'), so PortfolioAnalysis.winner can be ambiguous
- info: timeLimit = NaN or +inf means no deadline (documented only at Deadline.after(seconds:), not at SolveContext.timeLimit)
- info: Simplex(.primal) on the 660x36,000 transport LP did not finish phase 1 within 20 s under load (noSolution(timeLimit)); Simplex(.dual) solves it in 0.43 s (F2 area)
- info: Automatic at exactly 4,000 rows (dual simplex) took 8.4 s on a cycle-cover LP that the IPM solves in 0.04 s at 4,001 rows

</details>

#### <a id="a6-01"></a>A6-01 · BranchAndBound stopped during the root's expansion reports bound = incumbent and gap 0 (false optimality certificate)

- **Severity:** critical (finder) · **Category:** certificate · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-05](#a4-05) (cycle A)
- **Location:** Sources/ZTronLPBranchAndBound/BranchAndBound.swift:313-322 (a StopSignal from the root's expand leaves rootChildren empty; tree.begin(root:children: \[]) is followed by tree.close(.timeLimit/.cancelled), so the root's bound never enters the tree); Sources/ZTronLPBranchAndBound/SearchTree.swift:402-406 (provenBound = min(prunedBound, incumbent, best open, in-flight) falls back to the incumbent when nothing is open)
- **Claim tested:** README §3 risk 3 (README.md:410): 'read bound and BranchAndBoundAnalysis.gap to know how far the incumbent may be from the optimum'; README §2.4 bound; SolveStatus.feasible means optimality was not proven. A stopped run's bound must be a valid bound on the optimum.
- **Observed:** randomMILP(14,70,seed 4242) (maximize, optimum 599): timeLimit 0.0001-0.0005 s (or Task cancelled after 0.5-1 ms) -> feasible(stoppedBy: .timeLimit/.cancelled), objective 520, bound 520, gap 0.0, nodes 1, open 0; at timeLimit 0.001 the same run reports the valid root bound 618.33. MIPLIB 3: stein27 (min, optimum 18) limit 0.001-0.005 s -> objective 27 or 19 with bound 27 or 19, gap 0; mod008 (optimum 307) -> 510 / 510 / gap 0; egout (optimum 568.1007) -> 689.45 / 689.45 / gap 0. In a 40-instance random sweep 18 of 117 stopped runs had a bound beyond the optimum. Automatic and Conditioned(Automatic) pass the same false bound through. CPSAT under the same limits always reported a valid bound; nodeLimit 1/2/3 bounds are valid.
- **Why it is wrong:** The bound is the only certificate a stopped MIP run carries. Here it equals the incumbent, so gap 0 asserts the incumbent is optimal while it is 13% (randomMILP), up to 50% (stein27), 66% (mod008) and 21% (egout) from the optimum. The root LP bound was computed and then dropped. A user following risk 3, or stopping on gap &lt;= tolerance, accepts a wrong answer as proven optimal.
- **Documented:** Not documented; risk 3 and the defect list say nothing about stops during the root.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F6 bound-detail ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bound-miplib stein27 mod008 egout ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bnbagree 40 1 ; perl -e 'alarm shift; exec @ARGV' 120 .build/release/F6 misc bound-facades
```

<details><summary>Probe output</summary>

```text
limit 0.0005 BnB(dual): feasible(stoppedBy: timeLimit) obj Optional(520.0) bound Optional(520.0) gap Optional(0.0) nodes 1 open 0 incumbents 1 root optimal  <-- bound below the optimum (maximize); limit 0.001: bound 618.332 gap 0.189 open 2. stein27 obj 19 bound 19 gap 0 (opt 18); mod008 510/510/0 (opt 307); egout 689.45/689.45/0 (opt 568.1007); bnbagree: 18 invalid bounds in 117 stopped runs (CPSAT 0).
```

</details>

#### <a id="a6-02"></a>A6-02 · Cancellation and time limits wait for uninterruptible interior-point factorizations and presolve/scaling: latency grows with problem size

- **Severity:** high (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B6-02](#b6-02) (cycle B)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:674 (one gate.check() per iteration) and :384-441 (factorNormalEquations, startingPoint: no gate); Sources/ZTronLPSimplex/Simplex.swift:146 (Presolve.run) and :197 (Scaler.scale) run before the WorkGate is created at :228
- **Claim tested:** Sources/ZTronLPNumerics/WorkGate.swift:84-87 'keeps cancellation latency bounded regardless of problem size'; rule L1 (Tests/ZTronLPLivenessTests/L1CancellationTests.swift:39-40 'every loop that can run more than \~1 ms calls gate.tick(); cancellation is seen within the latency bound', release p99 &lt;= 50 ms, max &lt;= 200 ms); README §5 cancellation p99 &lt;= 50 ms; README risk 2 'Always set timeLimit'.
- **Observed:** Automatic() on a 6,500 x 322,501 LP with one dense column (routed to InteriorPoint, dense normal equations): interior-point iterations 667-714 ms apart with one gate check each; cancel latency 141, 316 and 663 ms; timeLimit 1.0 s returns after 1.514 s. Same structure at m = 4,500: 75-134 ms. Automatic on m = 10,000 with a 50%-dense column: timeLimit 0.5 -> 0.798 s, 1.0 -> 1.180 s; cancel 93 and 353 ms. InteriorPoint() on transport(400,5000) (5,400 rows, 2,000,000 columns) cancelled 20 ms after start: 1,021 and 1,033 ms. Simplex(.dual) on the same LP: 181 and 238 ms. Load average 3.6-5.4 on 8 cores; gaps of 0.1-1 s were repeated and are far beyond what load explains.
- **Why it is wrong:** Each of these steps is one uninterruptible call (dense Cholesky of the normal equations, symbolic analysis and starting point, presolve, scaling) with no gate inside, so latency is proportional to problem size, exceeds the documented 50 ms p99 / 200 ms max by up to 20x, and time limits are overshot by up to 0.5 s on an M3 (more on slower devices).
- **Documented:** Not documented as a latency limitation; README §4 mentions dense normal equations only as slowness, and defect 3 only as memory.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 dense-detail 6500 1.0 ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 cancel-large ipmdense 2.0 3 6500 ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 cancel-large presolve-ipm 0.02 2 ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 cancel-large presolve 0.02 2 ; perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 automatic limit10000
```

<details><summary>Probe output</summary>

```text
dense-detail 6500 1.0: elapsed 1.514 s, event gaps 667-714 ms; ipmdense cancel latencies 141/316/663 ms (m=4500: 75-134 ms); presolve-ipm cancel at 20 ms -> 1021/1033 ms; presolve (Simplex dual) 181/238 ms; limit10000: 0.5 -> 0.798 s, 1.0 -> 1.180 s, cancel 93/353 ms.
```

</details>

#### <a id="a6-03"></a>A6-03 · Conditioned runs the full conditioning analysis after a cancelled or timed-out inner solve

- **Severity:** high (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B6-01](#b6-01) (cycle B)
- **Location:** Sources/ZTronLPOptimizer/Conditioned.swift:39 (ConditioningAnalyzer.analyze runs unconditionally, with no cancellation or deadline check; the analyzer has no WorkGate)
- **Claim tested:** README §5 cancellation p99 &lt;= 50 ms; rules L1/L2 (Tests/ZTronLPLivenessTests/L1CancellationTests.swift:39-40, 142-143: cancellation and time limits return the best available result within the latency bound); SolveContext.timeLimit is wall-clock seconds.
- **Observed:** transport(400,3600) (m = 4,000): Simplex(.dual) alone cancels in 5-7 ms; Conditioned(Simplex(.dual)) in 337-338 ms; the analyzer alone takes 0.380 s (dense LU of the 4,000-row basis). timeLimit 0.5 -> 0.848-0.882 s; 1.0 -> 1.330-1.403 s, for Conditioned(Simplex(.dual)) and Conditioned(Automatic). In the 0.3 s limit sweep Conditioned(Simplex(.dual)) overshot by 71 ms against under 15 ms for the plain engines.
- **Why it is wrong:** After the inner solve has stopped for cancellation or the deadline, Conditioned still performs an uninterruptible analysis whose cost grows with m up to the analyzer's m &lt;= 4000 dense-LU cap, so its cancellation latency is about 60x the inner engine's and time limits are overshot by 0.35-0.4 s on an M3.
- **Documented:** README §2.5 says Conditioned costs the inner solve plus one analysis; nothing says the analysis runs after a cancellation or past the time limit.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 cancel-large conditioned 0.5 2 ; perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 cancel-large conditioned-inner 0.5 2 ; perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 cancel-large analyzer ; perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 cancel-large conditioned-limit
```

<details><summary>Probe output</summary>

```text
Conditioned(Simplex(.dual)) cancel latency 337/338 ms vs Simplex(.dual) 5-7 ms; analyzer alone 0.380 s; timeLimit 0.5 -> 0.848-0.882 s; 1.0 -> 1.330-1.403 s (load 5.6-7.1).
```

</details>

#### <a id="b6-01"></a>B6-01 · Conditioned keeps running its uncancellable conditioning analysis after cancellation or the time limit

- **Severity:** high (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A6-03](#a6-03) (cycle A)
- **Location:** Sources/ZTronLPOptimizer/Conditioned.swift:39 (analyze runs unconditionally after the inner solve, also when it stopped by cancellation/time limit); Sources/ZTronLPConditioning/ConditioningAnalyzer.swift:209-213 and 471-490 (dense factor, no gate)
- **Claim tested:** SolverStrategy doc (Sources/ZTronLPCore/Solve/Strategy.swift:193) 'Limits and cancellation end in the analysis's status'; README §5 cancellation-latency acceptance p99 &lt;= 50 ms (rule L1); WorkGate doc (Sources/ZTronLPNumerics/WorkGate.swift:84-87) 'keeps cancellation latency bounded regardless of problem size'. The task contract: cancelling returns promptly for every strategy including Conditioned.
- **Observed:** Conditioned(Simplex(.dual)) on InstanceGenerator.constructedOptimum(rows:3500, columns:7000, seed:31, density 0.0015): 6 cancels at random delays -> latency p50 317 ms, worst 778 ms; Simplex(.dual) alone in the same run: p50 1.7 ms, worst 4.0 ms. timeLimit 0.3 -> Conditioned returns after 0.588 s (Simplex alone 0.302 s); timeLimit 1 -> 1.60 s. ConditioningAnalyzer.analyze(after:) on the stopped basis takes 0.294 s by itself, and cancelling its task after 5 ms does not shorten it (0.366 s). Status is still the inner one (noSolution(timeLimit)/feasible(cancelled)).
- **Why it is wrong:** The inner engine stops within milliseconds, but the decorator then always runs ConditioningAnalyzer.analyze, whose basis analysis builds and LU-factors the dense m x m basis (m &lt;= 4,000) with no Task.isCancelled or deadline check. Cancellation and time limits are therefore exceeded by the full analysis time, which grows as m^3 (about 0.3 s at 3,500 rows on a loaded M3, up to roughly a second at the 4,000-row cap) - 6x the p99 bound even at the median. Load cannot explain it: the inner engine measured 4 ms worst in the same run.
- **Documented:** Not documented. README §2.5 gives Conditioned's time as 'inner's plus one ConditioningAnalyzer.analyze', but neither §3/§4 nor HANDBOOK says that the analysis ignores cancellation and time limits; the §5 latency table does not cover Conditioned.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bigcancel conditioned 6 && .build/release/F6 analyzer && .build/release/F6 util2   (sources: Slots/F6/Threads.swift runBigCancel, runAnalyzerTiming, runUtil2)
```

<details><summary>Probe output</summary>

```text
CANCEL Simplex(.dual)/m3500: reps=6 interrupted=6 p50=1.74ms worst=4.00ms | CANCEL Conditioned(Simplex(.dual))/m3500: reps=6 interrupted=6 p50=316.93ms p99=778.13ms worst=778.13ms | LIMIT Conditioned(Simplex(.dual))/m3500 limit=0.3 elapsed=0.588 status=noSolution(timeLimit) vs Simplex(.dual) elapsed=0.302 | ANALYZER analyze(after:) m=3500 took 0.294 s; cancelledAfter=0.005 took 0.366 s | THREADS Conditioned(Simplex(.dual))/m3500 limit 1 wall=1.60
```

</details>

#### <a id="a6-04"></a>A6-04 · SolveContext.threads does not bound InteriorPoint (Accelerate threads) or a Portfolio with more members than threads

- **Severity:** medium (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B6-06](#b6-06) (cycle B)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:384-441 (Accelerate sparse/dense factorization with no thread control); Sources/ZTronLPOptimizer/Portfolio.swift:44 (child.threads = max(1, resolvedThreads / count))
- **Claim tested:** README §3 risk 7 mitigation 'give each its share with SolveContext.threads'; README §2.8 ConcurrencyBudget 'so that nested parallel regions never exceed threads'; Sources/ZTronLPCore/Solve/Strategy.swift:162 resolvedThreads 'The number of worker threads this run may use'.
- **Observed:** InteriorPoint() with threads = 1 on transport(200,2000) (2,200 x 400,000): process CPU/wall 2.62-3.22 over 3 runs; with VECLIB\_MAXIMUM\_THREADS=1 it is 1.00-1.07 and the solve is faster (1.20 s vs 1.62 s). Portfolio(\[BnB, CPSAT, BnB(dual)]) with threads = 1: CPU/wall 2.37. BranchAndBound and CPSAT alone do honour threads.
- **Why it is wrong:** An app that splits cores between concurrent solves, or limits a background solve to one thread on iOS, gets about 3x the CPU it asked for from the interior point (and so from Automatic on large LPs) and k-fold from a Portfolio of k > threads members; threads only counts the package's own tasks.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 threads lp ; VECLIB_MAXIMUM_THREADS=1 perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 threads lp ; perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 threads
```

<details><summary>Probe output</summary>

```text
IPM threads=1: CPU/wall 2.62-3.22; with VECLIB_MAXIMUM_THREADS=1: 1.00-1.07, wall 1.20 s vs 1.62 s; Portfolio of 3 members, threads=1: CPU/wall 2.37; BnB/CPSAT at threads 1/2/4: 0.74/0.66, 1.96/1.89, 3.37/3.74.
```

</details>

#### <a id="a6-05"></a>A6-05 · Portfolio returns the first inconclusive result to arrive, not the best: a worse incumbent than one of its members

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B6-03](#b6-03) (cycle B)
- **Location:** Sources/ZTronLPOptimizer/Portfolio.swift:68-76 (rank by status only) and :104-112 (strict &lt; keeps the first entry of the best class)
- **Claim tested:** README §2.5 Portfolio: 'If none concludes, the best of what came back is returned (feasible before undecided before no solution before failure)'; Sources/ZTronLPOptimizer/Portfolio.swift:12-13 the same.
- **Observed:** randomMILP(30,200,99) (maximize). Members alone, deterministic: BnB(dual, nodeLimit 30) feasible 1762 in 0.04 s; BnB(dual, nodeLimit 4000) feasible 1852 in 0.60 s. Portfolio of both, in either order: feasible 1762 with bound 1893.795 (the other member's tighter bound 1893.700 is dropped). With time limits, Portfolio(BnB, CPSAT) at 0.3/0.6 s returned CPSAT's 1826/1827 while BnB alone reached 1865/1869.
- **Why it is wrong:** The ranking compares status classes only and keeps the first entry of the best class in arrival order, ignoring objective and bound, so among feasible results the earliest (usually the weakest) wins and a better incumbent and tighter bound from another member are discarded. That is not 'the best of what came back'.
- **Documented:** The parenthetical orders status classes only; nowhere does it say that among feasible results the first to arrive wins.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 portfolio worse2 ; perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 portfolio timelimit
```

<details><summary>Probe output</summary>

```text
alone: feasible 1762 (nodeLimit 30), feasible 1852 (nodeLimit 4000); Portfolio, both orders: feasible 1762, bound 1893.795.
```

</details>

#### <a id="a6-06"></a>A6-06 · LPModel convenience solve: a compile error exits with no .started/.finished, so a makeEventStream consumer never ends

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPCore/Solve/Strategy.swift:212 (try model.compile() runs before solve(compiled.lp, context:) creates the EventSink)
- **Claim tested:** HANDBOOK.md:113 '.finished is the last progress event and is delivered exactly once on every exit path'; Sources/ZTronLPCore/Solve/Status.swift:144-145 the same; Strategy.swift:169-171 makeEventStream 'The stream ends after .finished'.
- **Observed:** Automatic().solve(LPModel with a NaN objective coefficient, context:) throws invalid model; the stream from context.makeEventStream() receives 0 events and its consumer is still waiting 5 s later (it ends only when the consumer task is cancelled). Control with a valid model: the same consumer ends with 4 events.
- **Why it is wrong:** model.compile() throws before any EventSink exists, so nothing emits .finished or finishes the stream; an app that awaits its event consumer (progress UI, task group) hangs forever after an invalid model, contrary to the every-exit-path contract.
- **Documented:** Not documented; the L10 test aThrowingSolveStillFinishesOnce covers CompiledLP paths only.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 60 .build/release/F6 events-model
```

<details><summary>Probe output</summary>

```text
valid true: solve optimal; consumer ended within 5 s: yes, 4 events. valid false: solve threw invalid model: the coefficient of y in the objective is not finite; consumer ended within 5 s: NO (still waiting); after cancelling the consumer task: ended true.
```

</details>

#### <a id="a6-07"></a>A6-07 · Test sixteenMegabytesIsEnoughAndIsRespected never reaches its budget, so it cannot fail if memoryBudgetBytes is ignored

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-08](#a4-08) (cycle A), [A7-01](#a7-01) (cycle A)
- **Location:** Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:190-200
- **Claim tested:** Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:190-200, test name and rule L7: a 16 MB budget 'is enough and is respected'.
- **Observed:** Same problem and strategy as the test (LivenessProblems.mip() = randomMILP(14,70,4242), BranchAndBound(engine: Simplex(.dual), nodeSelection: .bestBound)): 16 MB budget -> optimal 599, 6,133 nodes, at most 1,549 open; budget Int.max/2 -> optimal 599, 5,847 nodes, at most 1,596 open. By the tree's own accounting (SearchTree.swift:29-30, 61-62, about 1.5 KB per open node here) the open list peaks near 2-3 MB, so neither parent-state stripping nor .memoryBudget is ever reached.
- **Why it is wrong:** The test asserts '.optimal || stopReason == .memoryBudget' and hasSolution only; with the budget ignored the run is still optimal and the test passes. Nothing checks memory against the budget. (The behaviour itself holds in a separate probe: 31.0 MB peak RSS with 16 MB vs 843.9 MB without.)
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F6 memory l7
```

<details><summary>Probe output</summary>

```text
budget 16777216: optimal obj Optional(599.0) nodes 6133 max open seen 1549; budget 4611686018427387903: optimal obj Optional(599.0) nodes 5847 max open seen 1596.
```

</details>

#### <a id="b6-02"></a>B6-02 · InteriorPoint checks cancellation and the deadline only once per iteration, so latency grows with problem size

- **Severity:** medium (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A6-02](#a6-02) (cycle A)
- **Location:** Sources/ZTronLPInteriorPoint/IPMWorker.swift:672-674 (single gate.check per iteration), 383-430 (normalMatrixValues + DenseCholesky without checks)
- **Claim tested:** WorkGate doc (Sources/ZTronLPNumerics/WorkGate.swift:84-87): 'a check still happens every millisecond or so, which keeps cancellation latency bounded regardless of problem size'; README §5 acceptance p99 &lt;= 50 ms (rule L1), InteriorPoint measured p99 3.46 ms; IPMWorker.swift:672-673 comment claims that one check per iteration satisfies rule L1.
- **Observed:** InteriorPoint() on constructedOptimum(rows:3000, columns:6000, seed:32, density 0.08), nnz 1,440,811 (dense normal equations): 6 cancels -> p50 95 ms, worst 621 ms; timeLimit 0.3 -> returns after 0.741 s; timeLimit 4 -> 4.03 s (threads 1) and 4.53 s (threads 2). On the 660 x 36,000 transport LP the same engine stays at p99 17 ms.
- **Why it is wrong:** The gate is checked once at the top of each iteration; forming A\*Theta\*A^T and the dense Cholesky (O(sum z\_j^2) + m^3/3) run without a check, so cancellation and time-limit latency equal one iteration, which is hundreds of ms at m = 3,000 and grows as m^3. This contradicts the 'regardless of problem size' claim and the 50 ms bound.
- **Documented:** Partly: README §5 'What these numbers do not say' disclaims models larger than 2,000 x 20,000, but README §4 does not list it and the WorkGate doc claim is unqualified.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 bigcancel ipm 6 && .build/release/F6 util2
```

<details><summary>Probe output</summary>

```text
BIG ipm problem m=3000 n=6000 nnz=1440811 | CANCEL InteriorPoint/dense-m3000: reps=6 interrupted=6 p50=95.17ms p99=620.50ms worst=620.50ms idleCPU=0.000s | LIMIT InteriorPoint/dense-m3000 limit=0.3 elapsed=0.741 over=0.441 status=noSolution(timeLimit) | THREADS InteriorPoint/dense-m3000 threads=2 limit 4 wall=4.53
```

</details>

#### <a id="b6-03"></a>B6-03 · Portfolio returns the first inconclusive result to arrive, even when another member returned a strictly better feasible objective

- **Severity:** medium (finder) · **Category:** contract-violation · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A6-05](#a6-05) (cycle A)
- **Location:** Sources/ZTronLPOptimizer/Portfolio.swift:105-113 (best-rank selection ignores objectiveValue and sense)
- **Claim tested:** README §2.5 Portfolio row: 'If none concludes, the best of what came back is returned (feasible before undecided before no solution before failure)'; Sources/ZTronLPOptimizer/Portfolio.swift:11-13 'if none concludes, the best of what came back is returned'. Derived contract: a portfolio is never worse than its members.
- **Observed:** Scripted members (custom SolverStrategy returning fixed records): minimize, feasible 10 after 50 ms and feasible 5 after 300 ms -> portfolio obj=10 (winner=fastWorse) in both list orders; maximize, 5 then 10 -> 5. Real engines: Portfolio(\[BranchAndBound(nodeLimit:3, deterministic:true), BranchAndBound(nodeLimit:3000, deterministic:true)]) on InstanceGenerator.randomMILP(rows:25, columns:120, seed:99, upper:1) (maximize): members alone 1008 and 1090; the portfolio returns 1008 in both orders while its `others` holds the 1090 result.
- **Why it is wrong:** Among inconclusive results the code ranks by status class only (rank(): feasible=1, ...) with a strict '&lt;', so ties keep arrival order and objectiveValue is never compared. The faster member - typically the one with the worse incumbent - wins, and a better incumbent the portfolio already holds is discarded. This happens whenever a time or node limit stops every member.
- **Documented:** Not documented in README §4 or HANDBOOK Known gaps; README §2.5 states the opposite ('the best of what came back').

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 portfolio scripted && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 portfolio real   (Slots/F6/PortfolioProbe.swift S1, S1b, S7, R1)
```

<details><summary>Probe output</summary>

```text
PORT S1 two feasible (min; members 10 then 5): status=feasible(timeLimit) obj=10 winner=fastWorse others=[slowBetter:feasible(timeLimit)] | PORT S7 (max; 5 then 10): obj=5 | PORT R1 members alone: small=feasible(nodeLimit) obj=1008 large=feasible(nodeLimit) obj=1090 | PORT R1 portfolio([small,large]) obj=1008; portfolio([large,small]) obj=1008
```

</details>

#### <a id="b6-04"></a>B6-04 · Portfolio invokes the progress callback concurrently from its members; chained listeners see different event orders

- **Severity:** medium (finder) · **Category:** concurrency · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPOptimizer/Portfolio.swift:42 (members share context.attachingMetal().nested()); Sources/ZTronLPCore/Solve/Strategy.swift:266-277 (nested() forwards directly), 172-183 (chained listeners)
- **Claim tested:** EventSink doc (Sources/ZTronLPCore/Solve/Strategy.swift:222) and README §2.3: 'serializes the events of one solve (rule C2) and enforces their order'; Portfolio doc (Portfolio.swift:16-18) 'forwarded as it comes, interleaved'; makeEventStream doc: a previously installed progress callback keeps receiving every event; task contract: events keep order and several consumers work.
- **Observed:** Callback with a 20 us critical section counting in-flight calls: Portfolio(\[BranchAndBound(), BranchAndBound(engine: Simplex(.dual))]) on randomMILP(25x120, seed 99), timeLimit 1 -> maxConcurrentCallbacks=2 in 3/3 runs; BranchAndBound() alone (8 workers) -> 1 in 3/3 runs; also 2 for Portfolio(bnb,cpsat,bnb-dual). With an EventRecorder plus two makeEventStream on one context, Portfolio(\[Conditioned(BranchAndBound()), Automatic()]) produced streams whose 256 events differ from the recorder's last 256 (suffixMatch=false for both); every non-portfolio case matched exactly.
- **Why it is wrong:** Each member runs with context.nested() and its own EventSink actor, so two members call the user's closure at the same time. A solve's events are then not serialized: a callback written against the documented serialization races, and listeners chained on one context (recorder, stream1, stream2) record different interleavings of the same solve.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 events concurrency && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 events nested   (Slots/F6/Events.swift CallbackProbe, streamSuffixCheck)
```

<details><summary>Probe output</summary>

```text
CALLBACK run0/1/2 Portfolio([BnB(primal), BnB(dual)])/mipHard: maxConcurrentCallbacks=2 finished=1 afterFinished=0 | CALLBACK run0/1/2 BnB(primal) alone: maxConcurrentCallbacks=1 | EVENTS FAIL Portfolio(Conditioned(bnb), Automatic)/mipHard: total=1024 stream1=256(ended=true, suffixMatch=false) stream2=256(ended=true, suffixMatch=false) finished=1 lastIsFinished=true
```

</details>

#### <a id="b6-05"></a>B6-05 · The Metal kernel tests pass, by skipping, when the shader library does not compile

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Tests/ZTronLPMetalTests/MetalTestSupport.swift:15-19; Tests/ZTronLPMetalTests/MetalTierTests.swift:31-45 and 105-116
- **Claim tested:** Tests named for kernel correctness (ReducedCostScanTests.scoresMatchTheDoubleReference, BatchedActivityTests.aPointOnItsBoundsIsNeverRejectedBySinglePrecision, ...) and README §5 'Building and testing'; MetalContext design rule 'if neither works the tier is disabled' is meant for machines without a toolchain, not to hide a broken shader on a Mac with a GPU.
- **Observed:** In a copy of the package (verification/cycle-B/F6-shadercheck) with one invalid line appended to Sources/ZTronLPMetal/Shaders/Kernels.metal, `swift test --filter ZTronLPMetalTests` exits 0: 'Test run with 28 tests in 3 suites passed'; BatchedActivityTests and ReducedCostScanTests are skipped with 'the GPU tier is unavailable on this machine' on an Apple M3; MetalTierTests passes.
- **Why it is wrong:** The .requiresMetal trait skips whenever MetalAccelerator.shared.isAvailable is false, and that includes .libraryUnavailable (a compile error), not only .noDevice. statusIsAlwaysOneOfTheThreeOutcomes accepts .libraryUnavailable, and theShaderIsBundledAsALibraryOrAsSource only greps the source for the two kernel names. A shader regression therefore turns every kernel test into a skip, and the gate stays green.
- **Documented:** Not documented (README §4 Not verified mentions only that the precompiled-library path was not exercised).

**Reproduction**

```sh
D=verification/cycle-B/F6-shadercheck; mkdir -p $D && cd . && cp -R Package.swift Package.resolved Sources Tests $D/ && printf 'this is not valid metal source;\n' >> $D/Sources/ZTronLPMetal/Shaders/Kernels.metal && cd $D && swift test --filter ZTronLPMetalTests
```

<details><summary>Probe output</summary>

```text
metal-tests-broken-shader.log: '-> Suite BatchedActivityTests skipped: "the GPU tier is unavailable on this machine"', '-> Suite ReducedCostScanTests skipped: ...', 18 tests skipped, 'Suite MetalTierTests passed', 'Test run with 28 tests in 3 suites passed after 1.144 seconds', rc=0
```

</details>

#### <a id="a6-08"></a>A6-08 · Test timeLimitsAreHonouredPromptly cannot fail in release for an ignored time limit

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Tests/ZTronLPLivenessTests/L1CancellationTests.swift:123-139
- **Claim tested:** Tests/ZTronLPLivenessTests/L1CancellationTests.swift:123-139: a 0.25 s limit on BnB, BnB(IPM) and CPSAT must be honoured within 0.25 + LatencyBounds.max.
- **Observed:** With no time limit at all, 9/9 release runs (3 engines x 3 reps, load average 36.7) end optimal in 0.189-0.430 s, inside the release bound 0.25 + 0.200 = 0.45 s. The baseline release run of the test took 0.500 s for all three solves. In debug the limit binds (0.755 s for three runs, bound 1.05 s); whether an unlimited debug solve exceeds 1.05 s was not measured.
- **Why it is wrong:** The test accepts .optimal, and in an optimized build the MIP finishes before the limit, so the release job (ci.yml:48) stays green if timeLimit were ignored by all three engines; only the debug job can catch it, and only if the unoptimized solve exceeds 1.05 s. Under heavy load the 0.45 s bound is also close to flaky.
- **Documented:** Not documented.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 120 .build/release/F6 misc l1
```

<details><summary>Probe output</summary>

```text
rep 0: optimal 0.189/0.299/0.381 s; rep 1: 0.409/0.382/0.430 s; rep 2: 0.373/0.422/0.388 s (no limit set; test bound 0.45 s).
```

</details>

#### <a id="a6-09"></a>A6-09 · Metal activity screen rejects a feasible point when a finite row bound exceeds 3e38

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Sources/ZTronLPMetal/KernelSupport.swift:11 (infinityStandIn = 3.0e38) and :55-58 (write(clampInfinities:) clamps every value, finite ones included), used for the row bounds in BatchedActivityKernel's init
- **Claim tested:** README.md:398 MetalBatchedActivity 'Never rejects a point that is feasible in exact arithmetic'; Sources/ZTronLPMetal/BatchedActivityKernel.swift:27 the same.
- **Observed:** Row x0 + x1 &lt;= 1e39 (finite), point (1.6e38, 1.6e38): fp64 maxViolation 0, GPU feasibility flag false; (1e38, 1e38) and (0, 0) accepted.
- **Why it is wrong:** Every bound is clamped to the fp32 stand-in 3.0e38, which is below a finite bound such as 1e39, so a feasible point whose activity lies between 3e38 and the bound is rejected. Harmless for practical models (the screen only discards candidates), but the absolute claim is false.
- **Documented:** Not documented; the single-precision tier is described without a bound-magnitude limit.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build --product F6 -c release && perl -e 'alarm shift; exec @ARGV' 60 .build/release/F6 metal bigbound
```

<details><summary>Probe output</summary>

```text
point (1.6e38, 1.6e38) on x0 + x1 <= 1e39: fp64 violation 0, GPU flag false; (1e38, 1e38): true; (0, 0): true.
```

</details>

#### <a id="b6-06"></a>B6-06 · Portfolio uses more threads than SolveContext.threads when threads &lt; number of members

- **Severity:** low (finder) · **Category:** limit-not-honoured · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A6-04](#a6-04) (cycle A)
- **Location:** Sources/ZTronLPOptimizer/Portfolio.swift:44
- **Claim tested:** SolveContext.threads: 'the number of worker threads this run may use' (Strategy.swift:147,162); README §2.5 Portfolio 'with threads ÷ k each'; risk 7: share the machine with SolveContext.threads.
- **Observed:** threads=1: Portfolio(\[BranchAndBound(), CPSAT()]) CPU utilisation 1.55, Portfolio of 3 members 1.79; BranchAndBound/CPSAT alone at threads=1: 0.84/0.74; Portfolio(bnb,cpsat) at threads=2: 1.66.
- **Why it is wrong:** child.threads = max(1, resolvedThreads / count) rounds 1/k up to 1 for every member, so k members run at once and the run uses k threads when the caller allowed fewer.
- **Documented:** README §2.5 says 'threads ÷ k each' and does not mention the case k > threads.

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build -c release --product F6 && perl -e 'alarm shift; exec @ARGV' 600 .build/release/F6 threads util
```

<details><summary>Probe output</summary>

```text
THREADS OVER Portfolio(bnb,cpsat)/mipHard threads=1 wall=2.51 cpu=3.87 utilisation=1.55 | THREADS OVER Portfolio(bnb,cpsat,bnbdual)/mipHard threads=1 cpu=4.52 utilisation=1.79
```

</details>

### <a id="f7-integrity"></a>F7 Package integrity: gates, docs, published numbers, tests, layering

<details><summary>Finder summaries, what they did not check, and further notes</summary>

**Cycle A (claims first).** Cycle A / F7: the gates, the 546-test count, the README §1 example, the §2 defaults and API shapes, the layering (no engine imports Metal; BLAS/LAPACK only through the shim), the netlib, transport and MIPLIB benchmark counts, deterministic B&B on nine MIPLIB instances, Oracle 1 (an independent KKT certificate on every suite) and TSAN on simplex/IPM/facade all hold. No critical or high defect was found. Nine findings: one medium (two memory-budget tests accept the result an unbudgeted solve gives, so they cannot catch a loosely honoured budget or a dead degrade step; only the 4,096-byte L7 test and L10 catch a budget ignored entirely), six low (README Hilbert warning counts wrong for orders 4-5; lint misses waitUntilScheduled, column-0 sleep(, nanosleep, @MainActor globals and anything under Tests/; debug and TSAN runs report skipped MIPLIB cases as passes; fetch-miplib.sh ignores ZTRONLP\_CORPORA; the fixture complementarity test checks columns only; the manifest declares three never-imported collections products and the HANDBOOK misstates the LP-engine consumers), and two info (a stale 'never green' README statement; latency samples that count a solve that finished first as 0 ms, with negligible effect on the published p99). Checkpoint: verification/cycle-A/F7-integrity.md; probes in verification/probes/cycle-A/Slots/F7/.

Claims and properties that held: 18.

Not checked:

- Metal benchmark rows and Metal threshold claims; the iOS Simulator CI job (xcodebuild); the demo app
- CP-SAT benchmark rows with the 60 s limit and parallel workers (7 of 7 optimal with CPSAT(), 5 of 7 without the LP propagator); only the deterministic single-worker runs at 40 s were checked, and stein45 was not run under CP-SAT
- README 'the release run of eight targets passes with one recorded known issue' (only the baseline release integration+liveness run was available; the other six targets were not run in release)
- Peak-memory numbers (1.16 GB / 1360 MB), event-frequency claims (simplex every 100 iterations, nodes every 100 ms)
- Exact count of public declarations (117 / 22 / \~700); rough recount 122 top-level / \~600 members
- Swift 6.0-6.3 toolchain path; the README comparison 'LP pivots within 1% of the changes switched off' (needs the old code)
- Transport LP timings per basis and method beyond the totals

Further notes (not verified):

- Tests/ZTronLPOptimizerTests/FacadeTests.swift:173 `#expect(simplex.method == .dual || simplex.method == .primal)` is a tautology (Simplex.Method has only these two cases) after line 171 has established Simplex(.dual)
- README.md:650 and HANDBOOK.md:203 'the primal node engine takes 0.60-1.65x the dual's LP pivots' is a single-run range: enigma 5.11x in this parallel run and 0.165x in deterministic mode (97,889 vs 594,890)
- .github/workflows/ci.yml thread-sanitizer comment 'Rule C10: Thread Sanitizer is clean on the integration suite with threads = 8': the job sets no thread count, so the runner's core count applies
- README risk 13 'CP-SAT on mod008 took about 50 s in the debug test suite': the default debug suite never runs mod008 under CP-SAT (it needs ZTRONLP\_SLOW\_TESTS=1)
- README risk 1 says solutions are recovered 'up to a condition number of about 1e10', and defect 9 says 'beyond about 1e11'; the measured edge lies between 3e10 (order 8) and 1e12 (order 9)
- README.md:181 'Three things to know before reading the bounds' is followed by four bullets
- README §2 LPFormat row does not say that LPFormat.write throws
- HANDBOOK says a missing corpus instance shows as a known issue; the SATLIB tests use an .enabled(if:) skip instead
- InteriorPoint on degen2 returned .optimal after Task.cancel() in 23 of 40 latency samples (all within 8.05 ms): the tail of the IPM solve may not poll the gate; not investigated (liveness area)
- README §1 item 6 'deterministic: true ... the same result and the same event sequence every run' has no time-limit caveat: CPSAT(lpPropagator: false, deterministic: true) on mod008 stopped at 40 s with 669,025 conflicts in one run and 676,188 in the next (same incumbent, 372)

**Cycle B (oracles first).** Cycle B / F7 (oracles first). Every baseline gate passed. 546 tests ran in 13 targets, which matches README §5. I also ran the simplex, interior-point and facade test targets under TSAN, which neither CI nor the baseline covers: no reports. The deterministic published numbers I re-ran all match: netlib pivots, IPM and crossover counts, the transport LP, 20/20 B&B optima, CP-SAT 7/7 and 5/7, Metal candidates, and the Hilbert table except one column. The README §1 example prints exactly its comments. README §2 matches the public symbol graph: 117 top-level declarations, 22 nested types, every listed member and labelled signature present, every listed default equal. Independent KKT and certificate oracles confirm the duals, reduced costs and rays of the LP engines on the package's generator suite in both senses, which the integration tests never check. Findings: (B7-01, medium) 12 MIPLIB corpus cases return early and are reported as passed in every debug build, so CI's test job and its TSAN job never run the slow B&B and CP-SAT searches; (B7-02) the lint misses several spellings of C3 and C6 violations and never scans Tests/ (latent); (B7-03) the README Hilbert warning counts are wrong at orders 4 and 5; (B7-04) one IllConditioned assertion is satisfied by the IPM's unconditional dense-column warning; (B7-05) HANDBOOK and SPEC deny the InteriorPoint->Simplex import; (B7-06) a test name overpromises; (B7-07, B7-08, info) stale CP-SAT collection dependencies and an unenforced 'threads = 8' in ci.yml.

Claims and properties that held: 23.

Not checked:

- The iOS Simulator xcodebuild job of ci.yml and the demo app build (needs Xcode builds writing DerivedData)
- CI behaviour on a real GitHub runner (3 vCPU, possibly no Metal device): which Metal tests skip there, and whether the timing tests hold
- Deterministic B&B node counts: README publishes none, and the 'within 1 % with the changes switched off' comparison needs the old engine
- Clean-build time ('about 22 s'): not repeatable on a shared machine without cleaning a build directory
- MPS/LP write-then-read identity, presolve, CP-SAT domain and B&B correctness were left to the F1-F5 finders of this cycle (they report e.g. B5-06 on the SATLIB gating)
- Shapes beyond names and labels in §2 (return types, throws, async) were not checked type by type

Further notes (not verified):

- HANDBOOK Testing 'tests that need a missing instance report a known issue instead of failing' is false for the SATLIB tests: they are disabled with .enabled(if:) (SATTests.swift:16,35,52); already reported in this cycle as B5-06
- Scripts/fetch-miplib.sh:37 skips any non-empty .mps already present without re-checking it (the SHA-256 covers only fresh .gz downloads), so a truncated or replaced corpus file is accepted until tests fail
- README §2 'about 700 public members and enum cases': the public symbol graph has 885 (130 enum cases, 394 properties, 179 methods, 64 inits, 62 static methods, 39 static properties, ...)
- L7MemoryBudgetTests.sixteenMegabytesIsEnoughAndIsRespected accepts a .memoryBudget stop and never measures memory, so neither half of its name is asserted (the scenario does end optimal today)
- IllConditionedTests.beyondDoublePrecisionNothingIsCalledInfeasible accepts .numericalFailure, while README §5 says every solve at every order ends optimal (the test is looser than the claim; observed 120/120 optimal)
- README §5 B&B text 'the primal node engine takes between 0.60 and 1.65 times the LP pivots of the dual one': a fresh parallel run gave 1.02-2.01 (lseu 2.01); the counts are nondeterministic (risk 8), so this is not a finding

</details>

#### <a id="a7-01"></a>A7-01 · The memory-budget tests accept the result of a solve that ignores the budget

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A4-08](#a4-08) (cycle A), [A6-07](#a6-07) (cycle A)
- **Location:** Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:246; Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:198 (code under test Sources/ZTronLPBranchAndBound/SearchTree.swift:428-462)
- **Claim tested:** L7 suite doc (Tests/ZTronLPLivenessTests/L3ToL10Tests.swift:186-188): 'the node pool respects the budget; exceeding it degrades (drops bases) and, if still exceeded, stops with .feasible(stoppedBy: .memoryBudget)'; test names sixteenMegabytesIsEnoughAndIsRespected (L3ToL10Tests.swift:190) and memoryBudgetDegradesThenStops (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:241); HANDBOOK Testing 'The liveness rules of §12.2 each have a test'.
- **Observed:** Both tests assert `status == .optimal || stopReason == .memoryBudget` (L3ToL10Tests.swift:198, BranchAndBoundTests.swift:246) and read no byte count, dropped-basis count or warning. On memoryBudgetDegradesThenStops' own instance and solver (randomMILP 12x60 seed 4242, BranchAndBound(nodeSelection: .bestBound, heuristics: .none)): 2,000 B -> noSolution(stoppedBy: memoryBudget) after 19 nodes; 4,096 B -> same after 29; 16 MiB -> optimal 593 (3191 nodes); no budget -> optimal 593 (3269 nodes). The unbudgeted result satisfies both assertions.
- **Why it is wrong:** A regression that stops enforcing the budget (or the degrade step in SearchTree.checkGapAndMemory) or undercounts openBytes turns the 2,000-byte case into .optimal, which the test accepts; the 16 MiB test cannot fail on a node pool that grows past 16 MiB; neither test checks degradation. Mitigation: aBudgetTooSmallForTheTreeStopsWithTheIncumbent (4,096 B, L3ToL10Tests.swift:202-215) and the L10 exit-path test require .memoryBudget, so a budget ignored entirely is still caught; a loosely honoured budget or a dead degrade step is not.
- **Documented:** No. README risk 4 and the 'Memory is budgeted, partly' bullet say what the budget counts, not that these tests leave it unchecked.

**Reproduction**

```sh
cd verification/probes/cycle-A && swift build -c release --product F7 && perl -e 'alarm shift; exec @ARGV' 300 .build/release/F7 membudget   (Slots/F7/Extra.swift memBudget)
```

<details><summary>Probe output</summary>

```text
budget 2000: noSolution(stoppedBy: ZTronLPCore.StopReason.memoryBudget) nodes 19 | budget 4096: noSolution(stoppedBy: memoryBudget) nodes 29 | budget 16777216: optimal nodes 3191 objective 593.0 | budget nil (default): optimal nodes 3269 objective 593.0
```

</details>

#### <a id="b7-01"></a>B7-01 · Twelve MIPLIB corpus cases pass silently in every debug build, including CI's test job and its Thread Sanitizer job

- **Severity:** medium (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A7-04](#a7-04) (cycle A)
- **Location:** Tests/ZTronLPIntegrationTests/CorpusTests.swift:9-17, 125, 151, 171; .github/workflows/ci.yml:62-65
- **Claim tested:** HANDBOOK Testing: 'tests that need a missing instance report a known issue instead of failing', 'A debug build runs a reduced corpus'; .github/workflows/ci.yml:50 'Rule C10: Thread Sanitizer is clean on the integration suite'; README §5 'Thread Sanitizer: No reports on the ... branch-and-bound, CP-SAT, ... integration and liveness targets'; CorpusTests.swift:144-148 'CP-SAT as it runs by default ... proves every pure-integer instance of the set optimal'.
- **Observed:** CorpusTests.swift:125/151/171 'guard !Self.slow.contains(instance.name) || Slow.enabled else { return }', and Slow.enabled is false in any DEBUG build without ZTRONLP\_SLOW\_TESTS=1 (CorpusTests.swift:9-17). 12 of the 23 MIPLIB parameter cases (BranchAndBound with both node engines on stein45/lseu/enigma/mod008; CPSAT() on stein45/lseu/mod008/p0201; CPSAT(lpPropagator:false) on stein45/lseu/enigma/mod008) return before solving and are reported as passed, with no skip and no known issue. In debug, cpSatWithoutTheLPPropagator reports '6 test cases passed after 4.107 seconds' with no known issue, because its mod008 case returns before solving. In release the same case runs into its 60 s limit and records the known issue (75.9 s). Baseline TSAN, also a debug build: 66.5 s, no known issue. CI's build-and-test job ('swift test') and its thread-sanitizer job are debug builds without ZTRONLP\_SLOW\_TESTS. Only the release 'corpora' job runs the twelve cases. So TSAN never runs the largest parallel searches: stein45 B&B (55k nodes), lseu and enigma B&B, and CP-SAT on stein45, lseu, mod008 and p0201. The smaller parallel searches (p0033, stein27, flugpl, egout, misc03 and p0201 B&B) still run under TSAN.
- **Why it is wrong:** A case that runs nothing is counted as a pass, and it is among the 546 that README §5 reports as passed. The package itself uses .enabled(if:) (SATTests) and withKnownIssue (missing corpus) to make such gaps visible. Correctness is still covered by CI's release corpora job. The race check is not: the TSAN gate covers less than README §5's TSAN row and ci.yml's 'clean on the integration suite' suggest, and it leaves out the longest multi-worker searches.
- **Documented:** Partly: HANDBOOK Testing says a debug build runs a reduced corpus and that ZTRONLP\_SLOW\_TESTS=1 adds the slow MIPLIB instances. It does not say the omitted cases report as passed, nor that the TSAN job (debug) excludes them; README §5's TSAN row does not mention it.

**Reproduction**

```sh
cd . && swift test --filter 'MIPLIBCorpusTests/cpSatWithoutTheLPPropagator'  (passes in ~4 s, no known issue; log verification/cycle-B/F7-debug-cpsat-nolp.log)  vs  swift test -c release --filter 'MIPLIBCorpusTests/cpSatWithoutTheLPPropagator'  (~76 s, records the mod008 known issue). Baseline: grep -n 'Test cpSatWithoutTheLPPropagator\|known issue' verification/baseline/03-test-debug.log verification/baseline/04-test-release-integration-liveness.log verification/baseline/05-tsan.log
```

<details><summary>Probe output</summary>

```text
debug: '✔ Test cpSatWithoutTheLPPropagator(_:) with 6 test cases passed after 4.107 seconds.' (no known issue); release baseline: '━ Test cpSatWithoutTheLPPropagator(_:) with 6 test cases passed after 75.888 seconds with 1 known issue.' ('mod008: .feasible(stoppedBy: timeLimit), incumbent 333.0 vs 307.0'); TSAN baseline: '✔ Test cpSatWithoutTheLPPropagator(_:) with 6 test cases passed after 66.481 seconds.' (no known issue)
```

</details>

#### <a id="a7-02"></a>A7-02 · README §5 Hilbert table: 'Answers with a warning' is wrong for orders 4 and 5

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-05](#a2-05) (cycle A), [A3-10](#a3-10) (cycle A), [B7-03](#b7-03) (cycle B)
- **Location:** README.md:615-616 (warning emitted at Sources/ZTronLPInteriorPoint/IPMWorker.swift:638-639)
- **Claim tested:** README.md:615-616: order 4 '0 of 12', order 5 '3 of 12' answers with a warning.
- **Observed:** Order 4: 4 of 12 (each of the four InteriorPoint() answers carries '4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)'); order 5: 4 of 12 (3 stall warnings plus 1 dense-column warning). Every other cell reproduces: condition estimates 7e2..4e16, dense-solve and per-engine distances (order 8: 4.0e-7/8.7e-7/7.6e-7; orders 9-12: 1..3), objective errors &lt;= 7.9e-12, warning counts of orders 3 and 6-12, every answer .optimal.
- **Why it is wrong:** The column evidently counted only stall/ill-conditioning warnings, but SolutionAnalysis.warnings also carries the IPM dense-column warning (Sources/ZTronLPInteriorPoint/IPMWorker.swift:638-639), which a dense Hilbert matrix of order >= 4 always triggers.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-A && .build/release/F7 hilbert 3 12 && .build/release/F7 hilbertwarn 3 6
```

<details><summary>Probe output</summary>

```text
hilbert: 'order 4 ... warned 4 of 12', 'order 5 ... warned 4 of 12'; hilbertwarn order 4: InteriorPoint on all 4 forms -> '4 column(s) have more than 30% nonzeros; the normal equations will be dense'
```

</details>

#### <a id="a7-03"></a>A7-03 · Scripts/lint.sh misses violations inside its own stated C2/C3/C6 scope

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B7-02](#b7-02) (cycle B)
- **Location:** Scripts/lint.sh:21-23 (code() scope), :35 (global-var regex), :66 (C6 pattern list)
- **Claim tested:** Scripts/lint.sh:2-8 'CI runs this; it exits non-zero on the first rule that is broken ... C2 no global mutable variables in library code ... C3 every @unchecked Sendable is listed and must carry an // INVARIANT: comment ... C6 no DispatchSemaphore, Thread.sleep, blocking command-buffer wait or DispatchGroup wait'; HANDBOOK 'no global mutable state ... no blocking primitives'; SPEC v0.2 §2.2 'no new @unchecked Sendable (the count stays at one)'.
- **Observed:** Mutation test on a copy of the script, one injected line per run. Not caught (rc=0): `@MainActor var counter = 0` in Sources; `commandBuffer.waitUntilScheduled()` (only waitUntilCompleted is listed); `sleep(1)` starting in column 0 (pattern '\[^A-Za-z\_.]sleep\\(' needs a preceding character); `nanosleep(&ts, nil)`; any `@unchecked Sendable` without INVARIANT under Tests/ (code() greps Sources only). Caught: nonisolated(unsafe) in Sources and Tests, `var`/`public var` globals at column 0, every `static var x =`, @unchecked without INVARIANT in Sources, DispatchSemaphore/Thread.sleep/waitUntilCompleted/DispatchGroup/usleep(/indented sleep(.
- **Why it is wrong:** CI relies on this gate for C2/C3/C6, and these forms pass it. Mitigation: Swift 6 language mode (Package.swift:23) rejects nonisolated global vars, covering `public private(set) var` and indented globals inside #if that lint also misses, but not @MainActor globals or blocking calls. No current violation exists in Sources/ or Tests/, so the gap is latent.
- **Documented:** not stated

**Reproduction**

```sh
cd . && T=verification/cycle-A/F7-lint-mutation/t && mkdir -p $T/Scripts $T/Sources/X && cp Scripts/lint.sh $T/Scripts/ && printf 'func f() {\nsleep(1)\n}\n' > $T/Sources/X/V.swift && bash $T/Scripts/lint.sh; echo rc=$?   (repeat with each one-liner above)
```

<details><summary>Probe output</summary>

```text
'lint: all rules hold' with rc=0 for each uncaught mutation; rc=1 with the rule's message for each caught one
```

</details>

#### <a id="a7-04"></a>A7-04 · Debug and Thread-Sanitizer runs report skipped MIPLIB cases as passed

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B7-01](#b7-01) (cycle B)
- **Location:** Tests/ZTronLPIntegrationTests/CorpusTests.swift:125,151,171; .github/workflows/ci.yml:65
- **Claim tested:** README 'Building and testing': 546 tests pass in a debug build; README §5 'Thread Sanitizer: no reports on ... branch-and-bound, CP-SAT, ... integration ...' with the CI thread-sanitizer job (.github/workflows/ci.yml:65) as the gate.
- **Observed:** CorpusTests.swift:125, :151, :171 `guard !Self.slow.contains(instance.name) || Slow.enabled else { return }`; Slow.enabled is false in any DEBUG build without ZTRONLP\_SLOW\_TESTS=1 (CorpusTests.swift:9-17). In debug, branchAndBoundWithBothStrategies runs 6 of 10 instances, cpSatClosesEveryPureIntegerInstance 3 of 7, cpSatWithoutTheLPPropagator 2 of 6; the other 12 cases return at their first line and count as passes (baseline 03: 'cpSatWithoutTheLPPropagator(\_:) with 6 test cases passed after 7.784 seconds', no known issue; release 04 records the mod008 known issue after 60 s). The CI TSAN job and HANDBOOK's TSAN command are debug builds, so under Thread Sanitizer B&B never runs stein45, lseu, enigma or mod008, CPSAT() never runs stein45, lseu, mod008 or p0201, and CPSAT(lpPropagator: false) never runs stein45, lseu, enigma or mod008.
- **Why it is wrong:** Skipped cases are reported as passes in the 546-test count and in CI, and the TSAN claim on the integration target covers only the reduced corpus, without the longest parallel searches. Swift Testing's .enabled(if:), which the SATLIB tests use, would show them as skipped.
- **Documented:** Partly: HANDBOOK Testing says 'A debug build runs a reduced corpus ... ZTRONLP\_SLOW\_TESTS=1 runs the slow MIPLIB instances in a debug build as well'. It does not say the skipped cases count as passes, or that the TSAN gate therefore never covers them.

**Reproduction**

```sh
cd . && grep -n 'Slow.enabled else { return }' Tests/ZTronLPIntegrationTests/CorpusTests.swift; grep -h 'cpSatWithoutTheLPPropagator\|cpSatClosesEvery\|branchAndBoundWithBoth' verification/baseline/03-test-debug.log verification/baseline/04*.log
```

<details><summary>Probe output</summary>

```text
03-test-debug.log: 'cpSatClosesEveryPureIntegerInstance(_:) with 7 test cases passed after 8.283 seconds', 'cpSatWithoutTheLPPropagator(_:) with 6 test cases passed after 7.784 seconds'; 04 release: 'recorded a known issue ... mod008 ... CorpusTests.swift:184:17'
```

</details>

#### <a id="a7-05"></a>A7-05 · fetch-miplib.sh ignores ZTRONLP\_CORPORA although the tests and its doc comment say the fetch scripts use it

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** code-reading-only · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Scripts/fetch-miplib.sh:15
- **Claim tested:** Sources/ZTronLPTestSupport/Fixtures.swift:39 'The directory the fetch scripts write to: \$ZTRONLP\_CORPORA when set, otherwise ...'.
- **Observed:** Scripts/fetch-miplib.sh:15 `DEST="${1:-${ROOT}/.corpora/miplib3}"` never reads ZTRONLP\_CORPORA; fetch-satlib.sh:31 does honour it.
- **Why it is wrong:** With ZTRONLP\_CORPORA set, fetch-miplib.sh writes to .corpora/miplib3 while Corpora.root looks under \$ZTRONLP\_CORPORA. Every MIPLIB test then records 'has not been fetched' as a known issue (CorpusTests.swift:113-121), and the run is green with the corpus untested.
- **Documented:** not stated

**Reproduction**

```sh
cd . && grep -n ZTRONLP_CORPORA Scripts/fetch-miplib.sh Scripts/fetch-satlib.sh Sources/ZTronLPTestSupport/Fixtures.swift
```

<details><summary>Probe output</summary>

```text
fetch-miplib.sh: no match; fetch-satlib.sh:31 CORPORA="${ZTRONLP_CORPORA:-$ROOT/.corpora}"; Fixtures.swift:42 reads the variable
```

</details>

#### <a id="a7-06"></a>A7-06 · FixtureTests.constructedInstancesAreFeasibleAndComplementary checks only the column half of the certificate

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Tests/ZTronLPTestSupportTests/FixtureTests.swift:46-50
- **Claim tested:** Test name (Tests/ZTronLPTestSupportTests/FixtureTests.swift:39) and comment 'Dual feasibility of the constructed pair'. Oracle 1 is the reference for every engine's duals.
- **Observed:** The dual check loops over 0..&lt;lp.n only (FixtureTests.swift:46-50). The m row entries of reducedCosts(forDuals:) (row-dual sign against row activity, row complementarity) and the duality gap are never checked.
- **Why it is wrong:** A generator change that gave an inactive inequality row a nonzero dual, or a dual of the wrong sign, would pass. The oracle is correct today: an independent KKT certificate (row and column signs, complementarity, duality gap &lt;= 2.4e-13) holds on every suite (.build/release/F7 gen).
- **Documented:** not stated

**Reproduction**

```sh
cd . && sed -n 39,53p Tests/ZTronLPTestSupportTests/FixtureTests.swift
```

<details><summary>Probe output</summary>

```text
`for j in 0..<lp.n { ... }` is the only dual assertion
```

</details>

#### <a id="a7-07"></a>A7-07 · Manifest and HANDBOOK misstate the dependency and import graph

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [B7-05](#b7-05) (cycle B), [B7-07](#b7-07) (cycle B)
- **Location:** Package.swift:69-70, 159, 182; HANDBOOK.md:134-135
- **Claim tested:** Package.swift:69-70 'The only two dependencies (§2): ... Heap / OrderedDictionary / BitSet'; Package.swift:159 gives ZTronLPCPSAT heap, orderedCollections, bitCollections; Package.swift:182 gives ZTronLPTestSupport ZTronLPNumerics; HANDBOOK.md:134-135 'branch and bound and CP-SAT are the two that import an LP engine'.
- **Observed:** No file imports OrderedCollections or BitCollections. HeapModule is imported only by Sources/ZTronLPBranchAndBound/SearchTree.swift. ZTronLPCPSAT imports only Atomics, Foundation, Core, Numerics and Simplex. ZTronLPTestSupport imports Core, Dispatch and Foundation, not Numerics. ZTronLPInteriorPoint imports ZTronLPSimplex for crossover-lite, which makes it a third LP-engine consumer.
- **Why it is wrong:** Three declared products are dead dependencies for every client of ZTronLPCPSAT. The manifest comment and the HANDBOOK sentence describe a graph that is not the real one.
- **Documented:** IPM -> Simplex is recorded elsewhere in HANDBOOK as a design decision, which contradicts the Targets sentence.

**Reproduction**

```sh
cd . && grep -rln 'import HeapModule\|import OrderedCollections\|import BitCollections' Sources Tests; grep -h '^import' Sources/ZTronLPCPSAT/*.swift Sources/ZTronLPTestSupport/*.swift Sources/ZTronLPInteriorPoint/*.swift | sort | uniq -c
```

<details><summary>Probe output</summary>

```text
Only Sources/ZTronLPBranchAndBound/SearchTree.swift matches the first grep; the CP-SAT, TestSupport and IPM imports are as listed
```

</details>

#### <a id="b7-02"></a>B7-02 · Scripts/lint.sh enforces less than rules C3 and C6 (and C2) state; C3 and C6 never scan Tests/

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A7-03](#a7-03) (cycle A)
- **Location:** Scripts/lint.sh:21-23 (code(), line-based), 35, 40, 57, 61, 66-67
- **Claim tested:** Scripts/lint.sh:5-8 ('C3 every @unchecked Sendable is listed and must carry an // INVARIANT: comment', 'C6 no DispatchSemaphore, Thread.sleep, blocking command-buffer wait or DispatchGroup wait', 'C2 no global mutable variables'); HANDBOOK Testing ('every @unchecked Sendable listed with its invariant, no blocking primitives'); SPECIFICATION-v0.2 §2.2 ('no new @unchecked Sendable (the count stays at one); Scripts/lint.sh must hold after every package').
- **Observed:** On a synthetic tree with one violation per file, lint flags only 'var plainGlobal = 0', 'static var a = 0' and an @unchecked Sendable without an INVARIANT comment (rc=1, 3 hits). It lets through: '@unchecked' and 'Sendable' on separate lines (not even counted, so the count of one is not enforced); an @unchecked Sendable whose only '// INVARIANT:' belongs to a neighbouring declaration within 8 lines; MTLCommandBuffer.waitUntilScheduled() (a blocking command-buffer wait); DispatchQueue.global().sync {}; NSLock; NSCondition.wait(); Darwin.sleep(1); 'public private(set) var'; an indented file-scope var inside #if; 'static var b : Int = 0'; a static var initialised on the next line; and a Tests/ file with @unchecked Sendable, Thread.sleep and DispatchSemaphore.
- **Why it is wrong:** The checks are line-based greps for fixed spellings, and C3/C6 scan Sources only. Swift 6 mode rejects the C2 cases at compile time, but it does not reject blocking calls or a hidden @unchecked Sendable, so for C3 and C6 the lint is the only gate. The gap is latent: none of these constructs is in the tree today.
- **Documented:** not stated

**Reproduction**

```sh
bash verification/cycle-B/F7-lint/Scripts/lint.sh   (a verbatim copy of Scripts/lint.sh; its ROOT is verification/cycle-B/F7-lint, whose Sources/T/*.swift and Tests/TT/*.swift hold one case each)
```

<details><summary>Probe output</summary>

```text
Output lists only Sources/T/c2_plain.swift:1, Sources/T/c2_static.swift:1, the C3 entries c3_borrowed_invariant.swift:3 (accepted) and c3_noinvariant.swift:1 (flagged), '2 in total'; c3_split.swift, c6_*.swift, c2_privateset/indented/static_spacecolon/static_multiline.swift and Tests/TT/tests_violations.swift produce no output.
```

</details>

#### <a id="b7-03"></a>B7-03 · README §5 Hilbert table: the 'Answers with a warning' column is wrong at orders 4 and 5

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A2-05](#a2-05) (cycle A), [A3-10](#a3-10) (cycle A), [A7-02](#a7-02) (cycle A)
- **Location:** README.md:615-616; Sources/ZTronLPInteriorPoint/IPMWorker.swift:639
- **Claim tested:** README.md:615-616 (Linear programs: ill-conditioned ones): order 4 '0 of 12', order 5 '3 of 12'; 'The warnings at orders 5 and 6 are the interior point's, whose normal equations stall there'; 'Measured with the engines as they are now.'
- **Observed:** 4 of 12 at order 4 and 4 of 12 at order 5. InteriorPoint() attaches 'N column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)' to every Hilbert answer from order 4 on, and at order 5 the stall warning is on 3 of the 4 forms. Every other cell of the table matches what I measured (condition estimate, dense-solve error, per-engine distance, worst objective error, all 120 solves optimal).
- **Why it is wrong:** The count is deterministic and differs from the table. The dense-column warning is the one README §4 Limits documents ('a warning says so').
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && swift build --product F7 && .build/debug/F7 hilbert ; .build/debug/F7 hilbertwarn 4 5 6   (Slots/F7/Hilbert.swift)
```

<details><summary>Probe output</summary>

```text
'4 2.84e+04 5.30e-13 5.30e-13 6.12e-13 5.30e-13 3.50e-16 4/12 optimalx12'; '5 9.44e+05 5.77e-12 5.84e-12 8.21e-12 5.77e-12 1.38e-16 4/12 optimalx12'; 'order 4 equality ipm: optimal warnings=["4 column(s) have more than 30% nonzeros; the normal equations will be dense (§8.3)"]' (same for the other three forms)
```

</details>

#### <a id="b7-04"></a>B7-04 · IllConditionedTests' 'an answer this fragile must carry a warning' cannot fail for InteriorPoint()

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Related:** [A3-08](#a3-08): interior-point tests that cannot fail
- **Location:** Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:99
- **Claim tested:** Tests/ZTronLPIntegrationTests/IllConditionedTests.swift:99 '#expect(!analysis.warnings.isEmpty, "...: an answer this fragile must carry a warning")'; README §4 defect 9 'The answer carries a warning that the optimal basis is ill-conditioned'.
- **Observed:** On these dense matrices (orders >= 4), InteriorPoint() always attaches the dense-column note, and so does Portfolio when the IPM answer wins. The assertion therefore holds whether or not an ill-conditioning or stall warning is produced. Nothing is hidden today: at orders 9 to 12, 0 of 144 solves carry only the dense-column note.
- **Why it is wrong:** The assertion is satisfied by a warning that has nothing to do with conditioning, so for the IPM it cannot catch a missing ill-conditioning warning, which is what it is there for.
- **Documented:** not stated

**Reproduction**

```sh
cd verification/probes/cycle-B && .build/debug/F7 hilbertwarn 4 5 6 ; .build/debug/F7 hilbertonly 9 10 11 12
```

<details><summary>Probe output</summary>

```text
Every IPM answer from order 4 carries the dense-column warning; hilbertonly: 'order 10: 36 solves, far(>=1e-3) 36, any warning 36, only the dense-column warning 0' (identical at 11 and 12; order 9: far 30, any warning 36, only the dense-column warning 0)
```

</details>

#### <a id="b7-05"></a>B7-05 · HANDBOOK and SPEC v0.2 say each layer imports only the layers beneath it; ZTronLPInteriorPoint imports ZTronLPSimplex

- **Severity:** low (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Same defect:** [A7-07](#a7-07) (cycle A), [B7-07](#b7-07) (cycle B)
- **Location:** HANDBOOK.md:134; SPECIFICATION-v0.2.md:57; Sources/ZTronLPInteriorPoint/InteriorPoint.swift:12
- **Claim tested:** HANDBOOK.md:134 'Each layer imports only the layers beneath it; branch and bound and CP-SAT are the two that import an LP engine (§3)'; SPECIFICATION-v0.2.md:57 'The layering of v0.1 §3 stands: each layer imports only layers beneath it.'
- **Observed:** Sources/ZTronLPInteriorPoint/InteriorPoint.swift:12 has 'import ZTronLPSimplex', and Package.swift declares the dependency. That is an LP engine importing another engine of the same layer (Package.swift 'MARK: Layer 3'). Package.swift:13-16 documents this edge itself; HANDBOOK and the SPEC deny it. Every other import matches Package.swift.
- **Why it is wrong:** Both documents state the layering as an invariant that the code does not satisfy.
- **Documented:** Only in Package.swift comments ('Two edges deserve a note ... ZTronLPInteriorPoint imports ZTronLPSimplex'); HANDBOOK and SPEC state the opposite.

**Reproduction**

```sh
grep -rn '^import' Sources/ZTronLPInteriorPoint/*.swift
```

<details><summary>Probe output</summary>

```text
Sources/ZTronLPInteriorPoint/InteriorPoint.swift:12:import ZTronLPSimplex
```

</details>

#### <a id="b7-06"></a>B7-06 · Test mixedModelsAgreeAcrossStrategiesAndWorkerCounts runs one strategy

- **Severity:** low (finder) · **Category:** test-integrity · **Confidence:** code-reading-only · **Found by:** cycle B (oracles first)
- **Verification:** Not yet checked by a skeptic.
- **Location:** Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:187-205
- **Claim tested:** The test name (Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift:187) promises agreement across strategies and across worker counts.
- **Observed:** Over 8 random mixed models, the body runs only BranchAndBound(engine: Simplex(.dual)), at threads 1, 2 and 8. Each run is checked for status optimal and an integral, feasible point, and the runs are compared with each other to 1e-4 relative. There is no second strategy (no primal node engine, no CP-SAT, no Portfolio) and no reference optimum.
- **Why it is wrong:** A disagreement between node engines, or one shared wrong answer, on mixed models would not be caught. The name promises more than the assertions check.
- **Documented:** not stated

**Reproduction**

```sh
sed -n 187,205p Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift
```

<details><summary>Probe output</summary>

```text
'let analysis = try await BranchAndBound(engine: Simplex(.dual)).solve(lp, context: context)' inside 'for threads in [1, 2, 8]'; reference is the first run
```

</details>

#### <a id="a7-08"></a>A7-08 · README 'no single full debug run of it was green' is stale

- **Severity:** info (finder) · **Category:** doc-claim-false · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not verified: info items are recorded only.
- **Location:** README.md:715
- **Claim tested:** README.md:715 'Every other test passed in those runs, so every test of the final tree has passed, but no single full debug run of it was green'.
- **Observed:** The baseline full debug run (verification/baseline/03-test-debug.log, rc=0) passed all 546 tests in 13 runs.
- **Why it is wrong:** The statement understates the current state: a green full debug run of this tree exists.
- **Documented:** not stated

**Reproduction**

```sh
cd . && grep 'Test run with' verification/baseline/03-test-debug.log
```

<details><summary>Probe output</summary>

```text
13 'Test run with N tests ... passed' lines summing to 546; baseline/progress.txt debug suite rc=0
```

</details>

#### <a id="a7-09"></a>A7-09 · Cancellation-latency figures count solves that finished before the cancel as 0 ms

- **Severity:** info (finder) · **Category:** performance-claim · **Confidence:** reproduced · **Found by:** cycle A (claims first)
- **Verification:** Not verified: info items are recorded only.
- **Location:** Sources/ZTronLPTestSupport/LivenessHarness.swift:45-48; Sources/ZTronLPBenchmarks/main.swift:262-270
- **Claim tested:** README §5 / HANDBOOK 'Cancellation latency, 240 solves: p99 3.64 ms, worst 4.43 ms'; L1 test p99 bounds.
- **Observed:** LivenessHarness.cancellationLatency records latency 0 when the solve returned before Task.cancel() (LivenessHarness.swift:45-48), and both the benchmark and the L1 test put those zeros into their quantiles. A probe on the benchmark's own instances, windows and seed gave Simplex(.primal) 30 interrupted / 8 finished first / 2 finished after the cancel; InteriorPoint 9 / 8 / 23; BranchAndBound 35 / 5 / 0. With 40 samples per row p99 = max, so the published per-row p99 and max are unaffected. p50 shifts (primal 0.16 -> 0.21 ms), and the all-engines p99 over 240 samples is taken at a slightly lower rank of the real latencies. Worst observed was 8.05 ms (IPM), within the 50 ms acceptance.
- **Why it is wrong:** A latency quantile that includes non-cancellations is optimistic. The measured effect on the published numbers is negligible.
- **Documented:** The CancellationSample.finishedFirst doc describes the flag, but the benchmark and README do not say that zeros are included.

**Reproduction**

```sh
cd verification/probes/cycle-A && perl -e 'alarm shift; exec @ARGV' 400 .build/release/F7 latency
```

<details><summary>Probe output</summary>

```text
verification/cycle-A/F7-latency.txt
```

</details>

#### <a id="b7-07"></a>B7-07 · Package.swift declares Heap, OrderedCollections and BitCollections for ZTronLPCPSAT, which imports none of them

- **Severity:** info (finder) · **Category:** other · **Confidence:** reproduced · **Found by:** cycle B (oracles first)
- **Verification:** Not verified: info items are recorded only.
- **Same defect:** [A7-07](#a7-07) (cycle A), [B7-05](#b7-05) (cycle B)
- **Location:** Package.swift:69-70, 159
- **Claim tested:** Package.swift:69-70 'Heap / OrderedDictionary / BitSet' as the reason for swift-collections; Package.swift:159 CPSAT dependencies 'atomics, heap, orderedCollections, bitCollections'.
- **Observed:** No file of Sources/ZTronLPCPSAT imports HeapModule, OrderedCollections or BitCollections. OrderedDictionary, OrderedSet, BitSet and BitArray appear nowhere in Sources, and Heap is used only by ZTronLPBranchAndBound/SearchTree.swift.
- **Why it is wrong:** These are stale dependency declarations: every client compiles and links two collection modules it never uses, and the manifest's rationale is out of date.
- **Documented:** not stated

**Reproduction**

```sh
grep -rnE 'import (HeapModule|OrderedCollections|BitCollections)|OrderedDictionary|BitSet' Sources
```

<details><summary>Probe output</summary>

```text
Only hits: Sources/ZTronLPBranchAndBound/SearchTree.swift:4:import HeapModule and :153 Heap<OpenNode<State>>
```

</details>

#### <a id="b7-08"></a>B7-08 · ci.yml's TSAN rule says threads = 8, but nothing sets it

- **Severity:** info (finder) · **Category:** doc-claim-false · **Confidence:** code-reading-only · **Found by:** cycle B (oracles first)
- **Verification:** Not verified: info items are recorded only.
- **Location:** .github/workflows/ci.yml:50, 62-65; Sources/ZTronLPCore/Solve/Strategy.swift:163-165
- **Claim tested:** .github/workflows/ci.yml:50 'Rule C10: Thread Sanitizer is clean on the integration suite with threads = 8.'
- **Observed:** ZTronLPIntegrationTests never sets SolveContext.threads, and resolvedThreads defaults to ProcessInfo.activeProcessorCount (Strategy.swift:163-165). On a GitHub macos-latest arm64 runner (3 vCPUs) that means 3 workers; 8 holds only on an 8-core machine such as the baseline's.
- **Why it is wrong:** The stated configuration of the race check is not what the CI job runs.
- **Documented:** not stated

**Reproduction**

```sh
grep -rn 'threads' Tests/ZTronLPIntegrationTests  (no hit)
```

<details><summary>Probe output</summary>

```text
public var resolvedThreads: Int { Swift.max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount) }
```

</details>

## Reproducing a finding

Most reproduction commands run probe programs from two SwiftPM workspaces, `verification/probes/cycle-A` and `verification/probes/cycle-B`. These workspaces are not part of the package.

- Each one depends on the package by path and has one executable target ("slot") per agent: `F1`–`F7` for the finders and `V001`–`V240` for the skeptics.
- A slot's code is in `Slots/<slot>/main.swift`.
- The workspaces are available only if `verification/probes/` is pushed along with this file.

To run a command:

1. In the workspace's `Package.swift`, point `.package(path: ...)` at your checkout of the package.
2. Run the command as written. It starts with `cd verification/probes/cycle-X`.

`swift build --product <slot>` builds one slot; add `-c release` when the command runs `.build/release/<slot>`. `perl -e 'alarm shift; exec @ARGV' <s> <binary>` limits a run to s seconds, and exit status 142 means that limit was reached. Commands of the form `swift test --filter …` run the package's own tests.

Timings were measured on a machine shared with other agents' runs, so treat absolute times as rough.

