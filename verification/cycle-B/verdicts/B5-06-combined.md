# B5-06 — sceptic verdict (cycle B, lens: reproduce and contract, slot V136)

- **Verdict:** confirmed
- **Documented:** false. The HANDBOOK is the document making the claim, and nothing in README §4 or the HANDBOOK's known gaps admits the mismatch. The skip behaviour itself is described correctly in two package comments, `Sources/ZTronLPTestSupport/Fixtures.swift:3-6` and `Scripts/fetch-satlib.sh:14`. So the documentation contradicts itself rather than omitting the behaviour.
- **Severity:** low. This is a documentation mismatch: the tests skip instead of recording a known issue. Without the corpus nothing fails, the skip is shown per test with a hint naming the fetch script, and CI fetches both corpora in every job that runs tests.

## Claim under test

HANDBOOK.md:152-154 (Testing): "The MIPLIB 3 and SATLIB instances are fetched by the two scripts
into `.corpora/` …; tests that need a missing instance report a known issue instead of failing."
In this package "known issue" means the Swift Testing mechanism `withKnownIssue`. The HANDBOOK uses the term that way at :472 (mod008), and README:713 does too ("one recorded known issue").

## Reproduction (independent of the finder, who only read the code)

The finder grepped the source. I ran the package's own tests and read what Swift Testing reported. `Corpora.root` honours `$ZTRONLP_CORPORA` (Fixtures.swift:41-44), so pointing it at an empty directory simulates a checkout where the corpus was never fetched. The repository is not touched.

1. Probe `verification/probes/cycle-B/Slots/V136/main.swift`. It counts `.cnf` files with POSIX `readdir`, not `Corpora.satlib`, evaluates the three traits word for word, and predicts each test's outcome.
   `swift build --product V136` (build complete). Then
   `ZTRONLP_CORPORA=<root> perl -e 'alarm shift; exec @ARGV' 60 .build/debug/V136` for each root:
   - default root `.corpora`: uf50-218 1000 / uuf50-218 1000 (the API and readdir agree), all traits true, all three tests run.
   - empty root: 0 / 0 ("no directory"), traits :16 false, :35 false, :52 false. The probe predicts all three skipped and 10 MIPLIB instances missing, each a `withKnownIssue`.
   - partial root (the first 50 files of each family copied): traits true. The probe predicts :16 and :35 fail on `files.count == 100` and :52 runs on 0 of 20.
2. The decisive check, the package's own tests against the empty root:
   `cd /Users/admin/Documents/ZTronLPOptimizer && ZTRONLP_CORPORA=<scratch>/empty-corpora perl -e 'alarm shift; exec @ARGV' 580 swift test --filter 'ZTronLPCPSATTests.SATTests/satlib' --filter 'ZTronLPIntegrationTests.MIPLIBCorpusTests/branchAndBoundWithBothStrategies'`
   exit 0; full log in `verdicts/B5-06-combined-empty-corpus.log`
   ```
   ➜ Test satlibUF50AllSatisfiable() skipped: "SATLIB is not bundled: run Scripts/fetch-satlib.sh to fetch uf50-218 and uuf50-218"
   ➜ Test satlibPortfolioAgrees() skipped: "SATLIB is not bundled: ..."
   ➜ Test satlibUUF50AllUnsatisfiable() skipped: "SATLIB is not bundled: ..."
   ✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.            <- no known issue
   ━ Test branchAndBoundWithBothStrategies(_:) recorded a known issue ... "p0033" ... at CorpusTests.swift:116:29
   ━ Test run with 1 test in 1 suite passed after 0.001 seconds with 6 known issues.   <- MIPLIB: as the HANDBOOK says
   ```
   (In debug, the 4 slow MIPLIB instances return before `load` by design, hence 6 known issues rather than 10.)
   The HANDBOOK sentence holds for MIPLIB 3 and is false for SATLIB, as the finding says. With the real corpus all three SATLIB tests run and pass (baseline/03-test-debug.log:1557-1699).

## Contract assessment and attempts to refute

- **Wrong oracle?** No. The sentence's subject is "the MIPLIB 3 and SATLIB instances", and "known issue" has a precise meaning in this Swift Testing codebase. A skip with a comment is a different outcome: it counts as a skipped test and is never recorded as a known issue.
- **By design?** The skip is deliberate. Fixtures.swift:3-6 says "the tests that need them are skipped when the directory is absent", and fetch-satlib.sh:14 says "The tests that need the corpus are skipped while it is absent". But that only shows the documents disagree. The HANDBOOK claims known issues for both corpora; Fixtures.swift claims skipping for both, which is wrong for MIPLIB. The finding is a documentation mismatch, and design intent does not make the HANDBOOK sentence true.
- **Not reproducible?** It reproduces by execution, above.
- **Finder's details:** the lines :16, :35 and :52 are correct. CorpusTests.swift:115 is the only `withKnownIssue` for a missing corpus; :183 is an unrelated known issue about the CP-SAT proof. Saying it is "all of the uf50/uuf50 coverage" is accurate: `Corpora.satlib` is used only in SATTests.swift. The CDCL core is still exercised without the corpus by the always-on `randomThreeSATAtTheThreshold` and `smallFormulasMatchExhaustiveSearch` (SATTests.swift:1-3, :72, :101), which lowers the impact.
- **Severity reasoning:** low. Nothing is wrong at run time, no failure is masked when the corpus is absent, the skip is visible with a remedy, and CI (`.github/workflows/ci.yml`: build-and-test, corpora and thread-sanitizer) always fetches SATLIB before testing.

## Supplementary observation (info; beyond the finding)

With a partially present family (fewer than 100 `.cnf` files), the SATLIB tests fail instead of reporting a known issue. This also contradicts "instead of failing":
`ZTRONLP_CORPORA=<scratch>/partial-corpora perl -e 'alarm shift; exec @ARGV' 580 swift test --filter 'ZTronLPCPSATTests.SATTests/satlib'`
exit 1; log in `verdicts/B5-06-combined-partial-corpus.log`
```
✘ Test satlibUF50AllSatisfiable() recorded an issue at SATTests.swift:19:9: Expectation failed: files.count == 100
✘ Test satlibUUF50AllUnsatisfiable() recorded an issue at SATTests.swift:38:9: Expectation failed: files.count == 100
✔ Test satlibPortfolioAgrees() passed after 0.003 seconds.     <- zero instances checked (no count check, dropFirst(100) of 50 is empty)
```
This state is unlikely in practice. fetch-satlib.sh extracts into a scratch directory, replaces the target, and exits non-zero unless it finds 1000 files (lines 75-87); a rerun fetches again when the count differs. Separately, `satlibPortfolioAgrees` can pass without checking anything whenever a family has 100 files or fewer.

## Files

- Probe: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B/Slots/V136/main.swift
- Logs: /Users/admin/Documents/ZTronLPOptimizer/verification/cycle-B/verdicts/B5-06-combined-empty-corpus.log, /Users/admin/Documents/ZTronLPOptimizer/verification/cycle-B/verdicts/B5-06-combined-partial-corpus.log
- Temporary corpora (scratch, not in the repository): /private/tmp/claude-501/-Users-admin--claude-spares-spare-zzrljs/7aab57cc-e0cf-4457-93b0-57da6847eb38/scratchpad/V136-B5-06/{empty-corpora,partial-corpora}
