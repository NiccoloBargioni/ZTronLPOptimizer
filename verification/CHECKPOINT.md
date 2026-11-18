# Skeptical verification — checkpoint

Started 2026-11-18 against `main` @ d9afebe (clean tree). Request: *run two independent
skeptical verification cycles against this package; save progress checkpoints because quota
is running out.* Verification only. No source file is changed.

**If you are resuming in a new session, read this file first, then the "Status" section.**

## Design

| | Cycle A — claims first | Cycle B — oracles first |
|---|---|---|
| Method | List what README/HANDBOOK/doc comments/tests claim, then try to falsify each claim by running a check | Derive the contract from first principles (KKT, certificates, enumeration, round trips), build independent oracles, then attack the public API with adversarial inputs |
| Areas (one finder each) | F1 core (DSL, compile, presolve, scaling, MPS/LP I/O, result types) · F2 simplex + numerics · F3 interior point + crossover + conditioning + `Conditioned` · F4 branch and bound · F5 CP-SAT · F6 runtime (cancellation, limits, events, concurrency, memory budget, Metal, `Automatic`, `Portfolio`) · F7 package integrity (gates, docs, numbers, tests, layering) | same seven areas |
| Verification | critical/high: 2 independent skeptics (lens *reproduce*, lens *contract*), tiebreak unless they agree · medium/low: 1 skeptic (lens *combined*), escalated to a second skeptic and a tiebreak if it rates the finding high or critical · info: recorded, not verified · at most 10 findings per finder are verified | same |

The two cycles do not read each other's files. Cross-cycle work starts only after both are
done. It matches findings, adjudicates contradictions (one cycle's finding against the other
cycle's "held" check), and runs a completeness critique. The orchestration script is
`verification/workflow.js`.

Status rules (to recompute from the verdict files if the run dies):
both skeptics `confirmed` → CONFIRMED, or KNOWN if both say it is already accurately
documented · both `refuted` → REFUTED · otherwise the tiebreaker decides CONFIRMED / PLAUSIBLE /
REFUTED · one skeptic: confirmed → CONFIRMED (KNOWN if documented), refuted → REFUTED,
uncertain → PLAUSIBLE.

## Layout (everything under `verification/`, untracked)

- `baseline/`: clean run of the official gates before any agent started (machine quiet).
  `progress.txt` has rc and elapsed time per step. Steps: `01-build-warnings-as-errors`,
  `02-lint`, `03-test-debug`, `04-test-release-integration-liveness`, `05-tsan`.
- `probes/cycle-A/`, `probes/cycle-B/`: SwiftPM probe workspaces. They depend on the package
  by path and use its public API. Slots `F1`–`F7` belong to the finders and `V001`–`V210` to
  the verifiers (area k, finding i, sceptic j → `V(30(k−1)+3i+j+1)`); `V221`–`V240` of cycle A
  are for the cross-cycle adjudicators. Build one slot with `swift build --product <slot>` and
  run `.build/debug/<slot>`. Warm debug and release builds exist (`probes/warm.log`; the README
  §1 example ran from an external package: 2600, 56, 1, 2725, 3.1666…).
- `cycle-A/`, `cycle-B/`:
  - `F<k>-<area>.md`: a finder's running log (appended as it goes).
  - `F<k>-<area>.json`: its final structured result (exists only if the finder finished).
  - `verdicts/<findingId>-<lens>.md`: the skeptics' verdicts.
- `REPORT.md`: reconciled final report (written at the end).
- `GAPS.md`: completeness critique.
- `adjudications/`: cross-cycle contradiction rulings.

## How to resume

State when stopped (14:12, by the main session, because the usage limit was about to run
out): all 14 finders are done, 31 of the 136 first-round skeptic verdicts are done, and the
cross-cycle stage has not started. Details are in "Status" below.

0. **First, move two files out of the working tree:** `VERIFICATION-FINDINGS.md` (repo root)
   and `verification/make-findings-md.py`. Both hold both cycles' results and the hand matching
   between them, which the resumed skeptics must not read. After the run, move them back, then
   regenerate the findings file with `python3 -I verification/make-findings-md.py`. It picks up
   new verdicts from every journal of the launching session.
1. **Same session: one call, nothing to edit.**

   ```
   Workflow({scriptPath: "/Users/admin/Documents/ZTronLPOptimizer/verification/workflow.js",
             resumeFromRunId: "wf_a4cd4cde-7c5"})
   ```

   The run was launched from this file with no `args`, and the file is unchanged since 11:29.
   Keep it byte-identical: any edit changes the cache keys. The journal keys every agent by a
   hash of its prompt and options (`"key":"v2:…"`), so the 45 finished agents (14 finders, 31
   skeptics) should come back from cache, and only the rest should run. Check this in the
   first minute: the 14 "find" agents must complete at once. If any finder starts working,
   stop the run with TaskStop and use step 2.
2. **New session, or step 1 re-runs finders.** `resumeFromRunId` works only in the session that
   launched the run (`7aab57cc-e0cf-4457-93b0-57da6847eb38`). Write `verification/resume.js`
   from `workflow.js` so that no finder runs again:
   - Build `args` with jq. `findings`: per finder key (A1 … B7), the `[id, severity]` pairs
     from `cycle-*/F*.json`. `prior`: the finished skeptic results from the journal, plus any
     verdict file written after this checkpoint. The journal command is below.
   - Replace the finder stage with one that returns `args.findings[key]`. Keep the
     id-by-position rule.
   - Point `verifierPrompt` and `tiebreakPrompt` at the finding's entry in its JSON file
     instead of embedding its text. Skip any skeptic call already in `prior`.
   - Point the reconcile, adjudicate, gaps and report prompts at the 14 JSON files and the two
     `verdicts/` directories.
   - Keep the slot formula, lenses, severity policy and independence rules unchanged.

   ```
   J=~/.claude/projects/-Users-admin-Documents-ZTronLPOptimizer/7aab57cc-e0cf-4457-93b0-57da6847eb38/subagents/workflows/wf_a4cd4cde-7c5/journal.jsonl
   jq -rs '(map(select(.type=="started")) | map({(.key): .label}) | add) as $L
     | map(select(.type=="result")) | .[] | [($L[.key]), .result.verdict?, .result.severity?] | @tsv' "$J"
   ```
3. Killed skeptics left partial files, for example `cycle-B/verdicts/B5-02-reproduce-cases.log`.
   They are harmless: the re-run agent overwrites or ignores them.

## Status

- [x] Survey of the package (20.3k lines of source, 14.0k of tests, 13 netlib + 10 MIPLIB 3
      fixtures, SAT corpora uf50/uuf50 present in `.corpora/`)
- [x] Baseline gates (`baseline/progress.txt`): build −warnings-as-errors rc=0 (31 s), lint
      rc=0, debug suite rc=0 (250 s), release integration+liveness rc=0 (246 s; its log shows
      "17 tests in 5 suites passed … with 1 known issue"), TSAN rc=0 (838 s, 0 ThreadSanitizer
      warnings; XCTest "Executed 0 tests", swift-testing runs of 17, 91 and 26 tests)
- [x] Probe workspaces built (debug + release), 247 slots each
- [x] Workflow launched 11:31 (run id: `wf_a4cd4cde-7c5`, task `wk2d0rsyr`; agent journal:
      `~/.claude/projects/-Users-admin-Documents-ZTronLPOptimizer/7aab57cc-e0cf-4457-93b0-57da6847eb38/subagents/workflows/wf_a4cd4cde-7c5/journal.jsonl`)
- [x] **Run stopped 14:12** with TaskStop (usage limit). Resume as described above.
- [x] Interim findings committed on branch `claude/verification-findings` (e837636, not pushed):
      `VERIFICATION-FINDINGS.md`, `verification/.gitignore` and the probe sources. The probe
      manifests now reach the package by the relative path `../../..`, and both workspaces build.
      Package sources are unchanged from d9afebe, so the resumed run is unaffected.
- [x] Cycle A finders done (F1–F7): 60 findings, 9 rated critical and 6 high (`cycle-A/F*.json`)
- [x] Cycle B finders done (F1–F7): 50 findings, 11 rated critical and 5 high (`cycle-B/F*.json`)
- [ ] Verification: 31 of 136 first-round skeptics done (30 confirmed, 1 refuted)
  - Done: A2-01 and A2-02 (both lenses), A2-03 … A2-07, A4-01 … A4-05 (both lenses),
    A4-06 … A4-09, A5-01 (contract only), A5-02 … A5-05, B5-01 (contract only), B5-05, B5-06.
  - Owed by the policy: an escalation for A2-03 and A5-02. Their combined skeptic rated each
    of them critical.
  - Killed in flight, to re-run: A5-01 reproduce, B5-01 reproduce, B5-02 reproduce and
    contract, B5-03 reproduce and contract.
  - Not started: B5-04, and every finding of A1, A3, A6, A7, B1, B2, B3, B4, B6 and B7. Info
    items (A4-10, A7-08, A7-09, B7-07, B7-08) are not verified, by design.
- [ ] Reconciliation, adjudication, gaps → `REPORT.md`
- [ ] Spot checks of the top findings by the main session
