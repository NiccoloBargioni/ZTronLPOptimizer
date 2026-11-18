# A2-06, sceptic (lens: reproduce and contract), cycle A, slot V046

- verdict: confirmed
- documented: false. The m-only rule is stated correctly elsewhere: README 2.5 (`denseBasisLimit` 1,500), README 2.7 (DenseLUBasis "up to 1,500 rows", SparseQRBasis "above 1,500 rows", basisDensity "no engine"), README 3 risk 2, README 4 Limits, README 5, HANDBOOK line 202, SPECIFICATION-v0.2 line 100, and the `Simplex.Factorization.automatic` and `DenseLUBasis` doc comments. No document records that the SparseQRBasis doc comment says otherwise, so the discrepancy itself is undocumented.
- severity: low. A false sentence in the doc comment of a public type. Behaviour is correct and documented correctly elsewhere, so no wrong answer follows from it.

## Claim
Sources/ZTronLPNumerics/BasisFactorization.swift:204-205 (the line numbers in the finding are right): "Chosen when m > 1,500 or the basis density is below 2%." The doc rule and the code differ only for m <= 1,500 with density < 2%. There the doc predicts SparseQRBasis.

## Code reading (git d9afebe, tracked files unmodified)
- Simplex.swift:78-90: `makeFactorization(rows m: Int)`. `.automatic` tests only `m <= Self.denseBasisLimit` (1,500). It takes no basis and no matrix, so it cannot test density.
- It is called at Simplex.swift:103 (makeEngine, used by branch and bound), Simplex.swift:198 (solve) and InteriorPoint.swift:267 (crossover), always with `rows:` only.
- `SimplexEngine.factor` is assigned in one place only, its init (SimplexEngine.swift:245). Nothing switches the factorization mid-solve.
- `basisDensity(` is defined at BasisFactorization.swift:283 and called only in Tests/ZTronLPNumericsTests/BasisFactorizationTests.swift:528-533.
- `Automatic.choice(for:)` routes to the sparse-QR simplex only for m > 10,000 with a column more than 30% dense. That is the opposite of a low-density rule, and `.automatic` would pick SparseQR at that size anyway.
- The DenseLUBasis doc comment says "Chosen when m ≤ 1,500" (BasisFactorization.swift:122). For m <= 1,500 with density < 2%, the two doc comments contradict each other.
- History: `git log -S "basis density is below 2%"` shows only d13d602 (v1.0). `makeFactorization` is identical in d13d602, d674d8e, 9fd4f24 and d9afebe. No density rule was ever implemented, and SPECIFICATION-v0.2 does not plan one ("SparseQRBasis stays, selectable, and is no longer chosen automatically").

## Execution with independent oracles (the finder only type-checked makeFactorization)
Probe: verification/probes/cycle-A/Slots/V046/main.swift. Each LP is `InstanceGenerator.transport(sources: 20, sinks: k, seed: 46)` with every column holding 2 nonzeros, so every basis has density <= 2/m. Each LP is solved with `Simplex(.dual, factorization: f, presolve: false)` for f in .denseLU, .sparseQR and .automatic, with timeLimit 150 s.

Oracle 1 is a fingerprint of the factorization a real solve used. DenseLUBasis refactors every 100 updates and SparseQRBasis every 50 (their doc comments, README 2.7, and the README 5 table showing 11 vs 21 refactorizations), so pivots, refactorizations, objective bits and primal bit-hash are compared.

Oracle 3 is the basis density computed by probing every entry of B through `SparseCSC` subscript. It matched `basisDensity` exactly.

```
cd verification/probes/cycle-A && swift build --product V046 -c release
perl -e 'alarm shift; exec @ARGV' 60 .build/release/V046 sweep
  Simplex().factorization == .automatic: true; denseBasisLimit 1500
  from m = 0: DenseLUBasis
  from m = 1501: SparseQRBasis
perl -e 'alarm shift; exec @ARGV' 580 .build/release/V046        (exit 0; full output in A2-06-combined-V046-fingerprint.txt)
  m=200  final basis density 0.9750% (slack 0.5000%)
     denseLU   pivots 206  refactorizations 4  primalBits 32598c5ef93b7c65
     sparseQR  pivots 210  refactorizations 6  primalBits cdec5e09be7104e
     automatic pivots 206  refactorizations 4  primalBits 32598c5ef93b7c65   => denseLU (doc predicts sparseQR)
  m=1000 final basis density 0.1983%
     denseLU 1011/12, sparseQR 1017/22, automatic 1011/12 (bit-identical to denseLU)       => denseLU (doc predicts sparseQR)
  m=1500 final basis density 0.1327%
     denseLU 1527/17 1.96 s, sparseQR 1530/32 0.63 s, automatic 1527/17 1.89 s (bits = denseLU) => denseLU (doc predicts sparseQR)
  m=1501 final basis density 0.1326%
     denseLU 1554/17, sparseQR 1552/33, automatic 1552/33 (bits = sparseQR)                 => sparseQR (both rules agree)
```
The same run was repeated 4 more times by accident (an unsplit zsh argument; see A2-06-combined-V046-fingerprint-repeats.txt). Pivots, refactorization counts and primal bits were identical every time, so the fingerprint is deterministic.

Oracle 2 is peak resident memory, one fresh process per configuration. DenseLUBasis holds an m x m dense matrix (8 m^2 = 18 MB at m = 1,500). Full output is in A2-06-combined-V046-rss.txt.
```
for cfg in "auto 20 1480" "dense 20 1480" "sparse 20 1480" "auto 20 1481" "dense 20 1481"; do perl -e 'alarm shift; exec @ARGV' 200 .build/release/V046 rss ${=cfg}; done
  automatic m=1500: pivots 1527 refactorizations 17, peak RSS growth 45.7 MB   (basis density 0.07%..0.13%)
  denseLU   m=1500: pivots 1527 refactorizations 17, peak RSS growth 45.7 MB
  sparseQR  m=1500: pivots 1530 refactorizations 32, peak RSS growth  7.9 MB
  automatic m=1501: pivots 1552 refactorizations 33, peak RSS growth  7.8 MB
  denseLU   m=1501: pivots 1554 refactorizations 17, peak RSS growth 45.7 MB
```
All exits were 0, and no alarm fired.

## Reasoning
All three oracles agree with the finder and with the code reading.
- The `.automatic` factorization depends on m alone.
- Bases with density from 0.07% to 0.98% (far below 2%) at m = 200, 1,000 and 1,500 are factored by DenseLUBasis. This is shown by bit-identical solves, the refactor cadence of 100, and an m x m dense allocation.
- The same density at m = 1,501 is factored by SparseQRBasis.

The doc comment's "or the basis density is below 2%" therefore describes a rule that no code path implements and that never existed in history.

Attempts to refute it failed:
- Not misuse: default `Simplex()` / `.automatic` was used, and presolve was off only to pin m. `makeFactorization` has no density input anyway.
- Not a reading issue: under every reading of "density" (basis nnz/m², slack basis, or A's nnz/(m·n)), the probe LPs are below 2%.
- Not by design: the sibling DenseLUBasis comment uses "Chosen when" for the automatic rule.
- No tolerance applies, since this is a discrete choice.

Impact is limited to someone reading Quick Help for SparseQRBasis. README and the other doc comments state the true rule.

Side note (info): README 2.7 groups `basisDensity` with helpers that "serve the tests and the analyzer and no engine". As a group statement that holds, but `basisDensity` itself is used only by tests.
