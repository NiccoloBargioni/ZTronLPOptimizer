# ZTronLPOptimizer — Technical Specification v0.2

**Cutting planes, a sparse LU factorization, a larger presolve**

Nov 15, 2026 · extends *ZTronLPOptimizer — Technical Specification v0.1* (Nov 6, 2026, @Nick).
References of the form "v0.1 §7.3" are to that document; "§4.5" is a section of this one.
The package as it stands is described in [README.md](README.md) (outside view, measured
numbers) and [HANDBOOK.md](HANDBOOK.md) (inside view, decisions).

1. [Purpose and scope](#1-purpose-and-scope)
2. [Ground rules](#2-ground-rules)
3. [Sparse LU factorization](#3-sparse-lu-factorization)
4. [Cutting planes](#4-cutting-planes)
5. [A larger presolve](#5-a-larger-presolve)
6. [Test strategy](#6-test-strategy)
7. [Benchmarks and acceptance](#7-benchmarks-and-acceptance)
8. [Work packages](#8-work-packages)
9. [Cut list, risks, open questions](#9-cut-list-risks-open-questions)

Appendix A lists every public declaration this specification adds.

## 1. Purpose and scope

v0.1 left three things out on purpose (v0.1 §1 non-goals, §5.3, §9.5, §15 backlog), and the
measurements of v0.1 show what each costs:

| Left out of v0.1 | What it costs today (README §5, M3, release build) |
|---|---|
| A sparse LU of the basis | The simplex factors the basis densely up to 1,500 rows (⅔·m³ flops and 8·m² bytes per refactorization) and with Accelerate's sparse QR above. On the 2,000 × 20,000 transport LP the dual simplex takes 2.04 s on the dense basis and 0.64 s on sparse QR, while the interior point needs 0.14 s. Nothing larger was solved end to end. |
| Cutting planes | Branch and bound closes `p0033` (16 × 33) in 915 nodes and `lseu` (28 × 89) in 31,697; `stein45` takes 55,254 nodes and 16–20 s. The LP bound at the root is all the bound there is. |
| A larger presolve | Presolve removes fixed columns, singleton rows, empty rows and columns. Branch and bound runs it in a mode that only tightens bounds. Duplicate rows, dominated columns and anything that reasons with row activities reach the engines untouched. |

This specification adds the three, in that order of dependency: the factorization is a
building block the other two use (cuts need rows of B⁻¹; a presolved LP is solved by the
simplex), the presolve changes what every engine receives, and cuts change what branch and
bound searches.

**Goals**, each with a number in §7:

1. A basis factorization in pure Swift whose cost follows the nonzeros of the basis, behind
   the existing `BasisFactorization` protocol, with product-form updates first and
   Forrest–Tomlin updates second; the automatic choice wherever it is measured faster.
2. Cut-and-branch: rounds of Gomory mixed-integer and knapsack cover cuts at the root of
   `BranchAndBound`, each cut valid by construction and checked by enumeration in the tests.
3. Presolve rules that remove rows and columns of an LP with a complete postsolve — primal
   values, duals, reduced costs, basis — and rules that tighten a MILP without changing its
   shape.

**Not in v0.2:** cuts below the root, or cut families other than the two named (mixed-integer
rounding is on the stretch list); hyper-sparse triangular solves; doubleton-equation
aggregation and probing (stretch list); anything in CP-SAT; a Linux build.

## 2. Ground rules

### 2.1 Where things go

The layering of v0.1 §3 stands: each layer imports only layers beneath it.

| Feature | Target | May import | Callers |
|---|---|---|---|
| Sparse LU | `ZTronLPNumerics` (new file `SparseLU.swift`; `SparseLUBasis` in `BasisFactorization.swift`) | `ZTronLPCore`, `CLAPACKShim` | `ZTronLPSimplex` selects it; nothing else names it |
| Cutting planes | `ZTronLPBranchAndBound` (new files under `Cuts/`) | `ZTronLPCore`, `ZTronLPNumerics`, `ZTronLPSimplex` | `BranchAndBound.search` |
| Presolve | `ZTronLPCore` (`Model/Presolve.swift`, new `Model/PresolveWorkspace.swift`, `Model/PresolveRules+*.swift`) | nothing | `Simplex`, `InteriorPoint`, `BranchAndBound` |
| Row append | `ZTronLPCore` (`Model/CompiledLP.swift`) | nothing | the cut loop |
| Test oracles, generators | `ZTronLPTestSupport` | `ZTronLPCore`, `ZTronLPNumerics` | test targets, `ZTronLPBenchmarks` |

No new package dependency. No new use of Accelerate outside the existing wrappers: the three
features are plain Swift over `[Double]`, `[Int32]` and `[Int]`.

### 2.2 Rules that carry over

- **Concurrency (v0.1 §12.1).** Swift 6 language mode; no `nonisolated(unsafe)`, no global
  mutable state, **no new `@unchecked Sendable`** (the count stays at one); `Scripts/lint.sh`
  must hold after every package. `SparseLUBasis` is a struct of arrays and is `Sendable` by
  construction.
- **Liveness (v0.1 §12.2).** Every loop whose length depends on the problem calls the
  caller's `WorkGate` (the cut loop, once per round and inside separation over rows) or is
  bounded by a pass count (presolve: at most `Options.maxPasses` passes of O(z + m + n)).
  A stop inside the cut loop is not an error: the search goes on with the cuts it has.
- **Determinism (rule C9).** Factorization, presolve and cut separation are functions of
  their input: no randomness, no dependence on thread timing.
  `BranchAndBound(deterministic: true)` stays byte-identical from run to run with cuts on.
- **Numerics.** Double precision decides. Every tolerance comes from `Tolerances` or is a
  named constant with a comment saying what it protects. The engine conventions that today's
  code relies on stay as they are: minimization form inside, `y_i ≥ 0` on a row active at
  its lower bound and `y_i ≤ 0` at its upper bound, reduced cost of the logical of row i
  equal to `y_i`, logical form `[A −I]` (v0.1 §5.5).
- **What the simplex engine already does and these features must not undo:** the refinement
  pass at the end of an unlimited run and the second look below the pivot tolerance
  (HANDBOOK, decisions 16–18), the residual check of v0.1 §6.3, the repair of a singular
  basis from `NumericalError.singular(positions:rows:)`.

### 2.3 Public API policy

Additions only; Appendix A has them all. Three defaults change, each only if its gate in §7
holds, and otherwise stays as in v0.1 with the reason recorded in HANDBOOK:

| Default | v0.1 | v0.2 if the gate holds |
|---|---|---|
| `Simplex.Factorization.automatic` | dense LU up to 1,500 rows, sparse QR above | the faster of dense LU and sparse LU by row count, as measured; sparse QR only on request |
| `BranchAndBound(cuts:)` | no cuts exist | `.default` (Gomory and cover cuts at the root) |
| Presolve of `Simplex`, `InteriorPoint`, `BranchAndBound` with `presolve: true` | six rules | the rules of §5 as well |

One addition is source-breaking for a client that switches exhaustively over a public enum:
the case `Simplex.Factorization.sparseLU`. That is accepted while no release is tagged and is
listed in the README's API risk.

### 2.4 What a work package is

The unit of v0.1 §15 is *agentic coding tool time*. A **work package** here is at most
**30 minutes** of it, measured from reading the package to its "done when" commands passing:

- one deliverable that leaves the package building and its tests green;
- at most two source files and one test file changed, as a rule about 150 lines of code and
  100 lines of tests;
- a "done when" made of commands, not judgement: a test filter that passes, a benchmark line
  that appears;
- nothing that needs the full suite: a debug build with tests takes about 20 s and a single
  test target a few seconds, so the loop inside a package is short. The full runs (debug
  suite ≈ 4 min, release corpus ≈ 3 min, Thread Sanitizer ≈ 10 min) belong to the **gates**
  of §8.3, which are packages of their own and are mostly machine time.

A package that is not done after 45 minutes is stopped and split; the split is recorded in
this file. Estimates below are upper bounds, not targets.

Standing "done" conditions of every package, not repeated in each:

```bash
swift build --build-tests -Xswiftc -warnings-as-errors
```

```bash
Scripts/lint.sh
```

## 3. Sparse LU factorization

### 3.1 The seam that exists

`BasisFactorization` (`Sources/ZTronLPNumerics/BasisFactorization.swift`) is the whole
contract: `refactor(basic:lp:)`, `ftran`, `btran`, `update(alpha:leaving:)`,
`updatesSinceRefactor`, `needsRefactor`, `conditionEstimate()`. The engine calls nothing else.
Three facts of the existing code shape the design:

- `EtaFile`, the product-form update file, is an internal type of the module that both
  existing strategies share. A third strategy can use it unchanged.
- A singular basis is reported as `NumericalError.singular(positions:rows:)`: basis
  positions that got no pivot, each paired with a row that no pivot covers. The engine
  replaces those columns by the logicals of those rows (`SimplexEngine.repairBasis`).
- `update(alpha:leaving:)` receives the entering column already transformed by `ftran`. A
  Forrest–Tomlin update needs the column *before* the U-solve (the "spike"); it is recovered
  as U·α, so the protocol does not change.

### 3.2 The factorization

`SparseLU` factors the m × m basis matrix B (columns `basic` of `[A −I]`) as a sequence of
m pivots (i_t, j_t), t = 1…m, where i_t is a row and j_t a basis position, by Gaussian
elimination with **Markowitz ordering and threshold pivoting**:

- **Active matrix.** Rows are stored as lists of (position, value); for each position the
  list of rows that hold an entry in it (pattern only; an entry removed by elimination is
  dropped lazily). Counts `rowCount[i]`, `colCount[j]` over the active part.
- **Phase 1, singletons.** While a position has one active entry, pivot on it (no
  elimination, no fill: the row becomes a row of U). While a row has one active entry, pivot
  on it (its column becomes a column of L; nothing else changes). Both run from queues, in
  O(nonzeros). On LP bases this phase usually takes most pivots.
- **Phase 2, the nucleus.** Among the four active positions with the fewest entries (ties to
  the lower index), every entry (i, j) with `|a_ij| ≥ u·max_k |a_kj|`, u = 0.1, is a
  candidate; the one with the smallest Markowitz count (rowCount − 1)·(colCount − 1) wins,
  ties to the larger magnitude, then the lower row. Rows that become singletons re-enter
  phase 1's queue.
- **Elimination.** For the pivot (i, j): U gets row i as it stands (pivot value and the
  other active entries); L gets, for every other active row k with an entry in j, the
  multiplier `a_kj / a_ij`; row k ← row k − multiplier·row i, with fill-in appended and
  entries below `dropTolerance` (1e-14) dropped.
- **Singularity.** A position whose largest active entry is below
  `singularityTolerance·(largest entry of B)` (1e-11, as `DenseLUBasis`) cannot be pivoted.
  When only such positions remain, the factorization throws `.singular` with those
  positions and the rows still active, paired in order.

L is the pivot-ordered list of column etas (row i_t, multipliers); U is the pivot-ordered
list of rows (pivot value u_t, entries in positions pivoted later). `fillRatio` is
(nonzeros of L and U) / (nonzeros of B).

The pivot search scans the active positions for the four sparsest: O(active) per pivot,
O(nucleus²) in all. That is the simple choice and it is enough for the size envelope (§3.7);
count-bucket lists are on the stretch list.

### 3.3 Solves

With y indexed by row and x by basis position:

- `ftran` (B·x = b): for t = 1…m, `y[k] −= l_k·y[i_t]` over the eta of t; then for
  t = m…1, `x[j_t] = (y[i_t] − Σ v·x[j]) / u_t` over the entries (j, v) of U's row t.
- `btran` (Bᵀ·w = c): for t = 1…m, `v_t = c[j_t] / u_t`, then `c[j] −= v·v_t` over row t,
  and `w[i_t] = v_t`; then for t = m…1, `w[i_t] −= Σ l_k·w[k]`.

Both run over dense right-hand sides and skip a pivot whose value is zero. After LU-10 the
factors are flat arrays (`start`, `index`, `value`) and the loops run on unsafe buffers.

### 3.4 Updates

**Product form (required).** `SparseLUBasis.update` appends to its `EtaFile`, exactly as
the two existing strategies do; `ftran` applies the file after the base solve, `btran`
before it.

**Forrest–Tomlin (second stage).** Replacing the column at position p = j_s by the entering
column a_q changes U only in column p, which becomes the spike w = U·α (α is the `ftran`'d
column the engine passes). Then:

1. Move pivot s to the end of the pivot order. Every other row stays upper triangular; row s
   now has its old entries (positions pivoted after s) on the wrong side.
2. Eliminate them: with ρ the entries of row s, for t after s in the old order with
   ρ[j_t] ≠ 0: μ_t = ρ[j_t] / u_t; ρ ← ρ − μ_t·(row t); record (i_t, μ_t).
3. New pivot value `u_s' = w[i_s] − Σ μ_t·w[i_t]`; row s becomes that pivot alone.
4. Column p of U: remove the old entries from the rows before s (found through the column
   index), insert `w[i_t]` into every other row t where it is not zero.
5. Append the row eta (i_s; the pairs (i_t, μ_t)). `ftran` applies row etas between the
   L-solve and the U-solve (`y[i_s] −= Σ μ_t·y[i_t]`), `btran` in reverse, transposed.

The update is refused with `NumericalError.unstableUpdate` — the engine then refactors —
when `|u_s'| < 1e-9·max|w|` or when `u_s'` disagrees with `α[p]·u_s` by more than 1e-6
relative (the two are equal in exact arithmetic). Tombstones in the pivot order and dead
entries in the column index are tolerated until the next refactorization.

`SparseLUBasis.Update` selects `.productForm` or `.forrestTomlin`; which is the default is
decided by measurement (LU-16).

### 3.5 Refactorization, accuracy, condition

- `needsRefactor`: after `refactorInterval` updates (100); when the update storage exceeds
  three times the factor's nonzeros plus m; when an update's growth (largest |α_i / α_r|,
  or |μ|) exceeds 1e7.
- Accuracy is the engine's business as before: the residual check of v0.1 §6.3 runs on any
  factorization.
- `conditionEstimate()` returns `nil`. The engine estimates κ₁ itself, by Hager's method on
  `ftran`/`btran`, for a factorization that has no estimate of its own
  (`SimplexEngine.basisConditionEstimate`).

### 3.6 Selection

- `Simplex.Factorization` gains `.sparseLU`; `makeFactorization(rows:)` returns
  `SparseLUBasis` for it.
- `.automatic`: dense LU up to `Simplex.denseBasisLimit` rows and sparse LU above, with the
  limit set where the benchmark of LU-11 puts the crossover (expected well under 1,500;
  the netlib bases, 27 to 444 rows, decide the low end).
- Dependents that name a factorization and follow the change: `Automatic.Choice.sparseSimplex`
  (`Simplex(.dual, factorization: .sparseQR)` → `.sparseLU`), the size estimate of CP-SAT's
  LP worker (`Sources/ZTronLPCPSAT/LPRelaxation.swift`, `8·m·m` or `96·nonzeros` today), the
  transport section of `ZTronLPBenchmarks`, README §2.5 and §2.7.
- `SparseQRBasis` stays, selectable, and is no longer chosen automatically.

### 3.7 Complexity and memory

| | Time | Space |
|---|---|---|
| `refactor` | O(nonzeros of B) for phase 1; O(nucleus² + fill work) for phase 2 | 12 bytes per nonzero of L and U, plus O(m) |
| `ftran`, `btran` | O(nonzeros of L and U + update storage) | in place |
| Product-form update | O(m) | up to 12·m bytes per update |
| Forrest–Tomlin update | O(m + entries touched) | one sparse row eta and the spike's nonzeros |

Design envelope: bases up to 50,000 rows whose nucleus stays under 5,000. Outside it the
factorization is still correct; the benchmark says where it stops being fast.

## 4. Cutting planes

### 4.1 Scope: cut and branch

Cuts are separated **at the root only**, in rounds, before the tree is created. The search
then runs on the LP with the surviving cuts as ordinary rows. Nothing in `SearchTree`, in the
workers or in `NodeLPStrategy`'s requirements changes; no cut is added or removed below the
root. This is the v0.1 §9.5 entry "Gomory mixed-integer cuts at the root", widened by cover
cuts.

### 4.2 Data model

```swift
struct Cut: Sendable {
    var columns: [Int32]        // structural columns, ascending
    var coefficients: [Double]
    var lower: Double           // Σ a_j·x_j ≥ lower: every cut is stored in ≥ form
    var family: CutFamily       // .gomory, .knapsackCover
    var efficacy: Double        // (lower − a·x*) / ‖a‖₂ at the point it was separated from
}
```

A cut lives in the space of the n structural columns: logical variables are substituted out
before a cut is stored (§4.5). The **pool** of one round is an array of cuts; selection
(§4.7) reduces it to the cuts that become rows.

### 4.3 The loop

```
x*, basis ← root LP (solved by the node engine as today; its analysis stays the root analysis)
repeat up to cuts.maxRounds:
    gate.check()
    pool ← separators(lp, x*, basis)            // §4.5, §4.6
    chosen ← select(pool)                       // §4.7; stop if empty
    lp ← lp.appendingRows(chosen)               // §4.4
    x*, basis ← dual simplex on lp from basis extended by the new logicals
    stop if the LP is infeasible (the MILP is), if the bound moved by less than
        1e-4·max(1, |bound|) in each of the last three rounds, or on a stop signal
drop the cuts whose logical is basic at the last optimum (§4.4)
```

The loop re-solves with its own `Simplex(.dual, presolve: false)` whatever the node engine
is: after rows are appended the old basis with the new logicals basic is dual feasible, which
is the dual method's start. Each re-solve has the iteration budget of a node,
`max(1,000, 10·(m + n))`, times four; a re-solve that hits it ends the loop with the cuts of
the previous round.

### 4.4 The augmented LP

`CompiledLP.appendingRows(_:)` (Core) returns the problem with rows appended: same columns,
bounds, costs, integer columns and names, new row names `cut1…`, `scaling: nil`, the
transpose rebuilt. It is O(z + m + n + new entries).

**Extended basis.** For k appended rows the basis gains k logical columns, all basic:
statuses appended as `.basic`, positions appended to `basic`.

**Dropping slack cuts.** A cut whose logical is basic at the final optimum is not binding;
removing its row and its logical from the basis leaves an optimal basis of the smaller LP.
The LP handed to the tree therefore holds the binding cuts only, and the tree's root state
is that basis.

**Engines.** The tree's workers are made by the node engine on the augmented LP
(`engine.makeWorker(lp:context:)`). The root state they start from is the cut loop's final
basis when `Engine.State` is `Basis` (both shipped engines); for any other state type the
engine solves the augmented LP once more with `solveRoot`. A user-defined engine therefore
needs nothing new.

### 4.5 Gomory mixed-integer cuts

For a basic integer column with value x̄ and fraction f₀ = x̄ − ⌊x̄⌋ in [0.01, 0.99]:

1. **Tableau row.** ρ = B⁻ᵀ·e_r by `btran` on a factorization of the final basis
   (`Simplex.makeFactorization(rows:)` on the unscaled LP); ᾱ_j = ρᵀ·a_j for nonbasic
   structural j and ᾱ_{n+i} = −ρ_i for a nonbasic logical.
2. **Shift.** The row reads x_B + Σ ᾱ_j·x_j = 0 over the nonbasic columns, each of which is
   at a bound: put t_j = x_j − l_j at lower and t_j = u_j − x_j at upper, so that the row
   becomes x_B + Σ a′_j·t_j = x̄ with a′_j = ᾱ_j at lower and −ᾱ_j at upper, and t ≥ 0. A
   nonbasic free variable with ᾱ_j ≠ 0 disqualifies the row. A logical counts as integer
   when its row has integral coefficients on integer columns only and integral bounds.
3. **Formula.** With f_j = a′_j − ⌊a′_j⌋ for integer t_j:
   γ_j = f_j / f₀ if f_j ≤ f₀, else (1 − f_j) / (1 − f₀); for continuous t_j:
   γ_j = a′_j / f₀ if a′_j ≥ 0, else −a′_j / (1 − f₀). The cut is Σ γ_j·t_j ≥ 1.
4. **Back-substitution.** Replace t_j by its definition, and each logical s_i by a_iᵀ·x;
   collect terms on structural columns; move constants to the right.

At most `maxCutsPerRound` rows are tried per round, most fractional first (distance of f₀
from 0.5, ties to the lower column).

### 4.6 Knapsack cover cuts

For each side of each row that can be written Σ a_j·x_j ≤ b over binary columns with
a_j > 0 — after complementing binaries with negative coefficients (x → 1 − x̄) and replacing
every other column by the bound that weakens the row, which must be finite:

1. **Cover.** Take columns in order of increasing (1 − x*_j) / a_j until Σ a_j > b; then
   drop columns, largest (1 − x*_j) first, while the sum stays above b (a minimal cover C).
2. **Extension.** Add every column with a_j ≥ max over C.
3. **Cut.** Σ_{j ∈ E(C)} x_j ≤ |C| − 1, mapped back through the complementation and stored
   in ≥ form. It is kept when violated by x* by more than 1e-6.

### 4.7 Selection and safeguards

A cut is **rejected** when, after dropping coefficients below 1e-12 times its largest (each
dropped term moved to the right-hand side at the bound that weakens the cut; a dropped term
on an unbounded column rejects the cut): its largest and smallest coefficients differ by
more than 1e6; it has more than max(100, n/2) terms; its efficacy is below
`cuts.minEfficacy` (1e-5). A Gomory cut's right-hand side is then relaxed by
1e-9·(1 + |lower|).

**Selection** of a round: by efficacy, highest first; a cut is skipped when its cosine with
a cut already chosen exceeds `cuts.maxParallelism` (0.9); at most `maxCutsPerRound` (100)
are chosen. Identical cuts (same columns, coefficients equal to 1e-9 relative) are one cut.

### 4.8 Integration

- **Bound and events.** The root bound the tree starts from is the LP value after the last
  round. Each round that raises it emits `.boundImproved`. No event case is added.
- **Analysis.** `BranchAndBoundAnalysis.cuts` is a `CutSummary`: rounds, cuts separated and
  applied per family, cuts kept for the search, root bound before and after, LP iterations
  and seconds of the loop. `root` remains the engine's analysis of the LP relaxation as
  given, without cuts.
- **Presolve.** The loop runs after the bound-only presolve of the search and before the
  tree, on the same column space, so incumbents, bound changes and reduced-cost fixing are
  unaffected.
- **Memory.** The augmented LP is one more copy of the problem plus the cut rows, shared by
  the workers; at most `maxRounds·maxCutsPerRound` rows are ever appended.
- **Liveness.** A cancellation or the deadline inside the loop ends the loop, not the
  solve's contract: the status comes from the search as in v0.1.

### 4.9 Options

```swift
public struct Cuts: Sendable, Hashable {
    public var gomory: Bool = true
    public var knapsackCover: Bool = true
    public var maxRounds: Int = 10
    public var maxCutsPerRound: Int = 100
    public var minEfficacy: Double = 1e-5
    public var maxParallelism: Double = 0.9
    public static let `default` = Cuts()
    public static let none = Cuts(gomory: false, knapsackCover: false)
}
```

`BranchAndBound(engine:branching:nodeSelection:heuristics:cuts:gap:nodeLimit:deterministic:seed:)`;
the parameter sits after `heuristics`, in both initializers.

## 5. A larger presolve

### 5.1 Structure

`Presolve.run` is one function of 250 lines today. It becomes a driver over a
**workspace** (`PresolveWorkspace`, internal): working bounds, row bounds and costs, active
flags and counts for rows and columns, row activity bounds (§5.2, P1), the list of steps.
The matrix itself stays immutable — every rule of this specification removes rows and
columns or changes bounds, row bounds and costs, and none changes a coefficient — so the
reduced problem is still assembled by filtering the original entries.

- `Presolve.Options`: `rules` (an option set, `.all` by default), `maxPasses` (20).
- `Presolve.Statistics`: how many times each rule fired, rows and columns removed, bounds
  tightened. `Presolve.statistics` is public; the `.presolved` event is unchanged.
- `Presolve.run(_:tolerances:mode:options:)`; the three-argument form stays.
- Each rule is one file `PresolveRules+<Name>.swift` with its reduction and its postsolve.
  Postsolve walks the steps in reverse, as today.

### 5.2 Rules for linear programs (mode `.full`)

Notation: row i with bounds [rl, ru], minimum and maximum activity L_i, U_i over the
current column bounds (infinite contributions counted, not summed); d_j = c_j − a_jᵀ·y.
"MILP-safe" says whether the rule may also run when integer columns are present.

**P1 — Activity bounds.** Not a reduction: L_i and U_i for every active row, maintained
when a column bound changes. `L_i > ru + τ` or `U_i < rl − τ` (τ the feasibility
tolerance scaled by the row's magnitude) is infeasibility.

**P2 — Redundant rows** (MILP-safe). `L_i ≥ rl − τ` and `U_i ≤ ru + τ`: the row can never
bind. Remove it. A side that alone is redundant is relaxed to ±∞ and recorded. *Postsolve:*
y_i = 0, logical basic.

**P3 — Forcing rows** (MILP-safe). `L_i ≥ ru − τ` (forcing at upper; symmetric at lower):
the row holds only with every column at the bound that attains L_i. Fix them there, remove
the row. *Postsolve:* each column takes that bound, status at lower or at upper — not
"fixed", the original problem does not fix it. With d⁰_j the reduced cost before row i has a
dual, `y_i = min(0, min_j d⁰_j / a_ij)` (forcing at upper; `max(0, max_j …)` at lower): the
largest magnitude that leaves every d_j on the right side. If y_i ≠ 0 the column attaining
it becomes basic and the logical nonbasic at the forced bound; otherwise the logical is basic.

**P4 — Dominated columns by dual fixing** (MILP-safe). c_j ≥ 0 and no row can be violated by
lowering x_j (for a_ij > 0: rl_i = −∞; for a_ij < 0: ru_i = +∞): fix x_j at its lower bound;
symmetric for c_j ≤ 0 and the upper bound. An infinite bound with c_j ≠ 0 is recorded like
today's empty column that improves forever (`unboundedColumn`); with c_j = 0 the rule does
not apply. *Postsolve:* value at the bound, status at lower or upper; d_j has the right sign
by the condition, nothing to repair.

**P5 — Slack column singletons** (continuous columns only). Column j in one row i, c_j = 0:
it is a slack. Remove the column and widen the row: with a = a_ij > 0,
`rl ← rl − a·xu_j`, `ru ← ru − a·xl_j` (reversed for a < 0; infinite bounds give infinite
row bounds, and a row left without bounds is removed by P2). *Postsolve:* with r the row's
activity without j — if the reduced row was active at a bound that came from a bound of
x_j, x_j is at that bound and nonbasic, the original logical nonbasic at the matching
original bound, y_i unchanged; if the reduced logical was basic, x_j goes to a bound that
keeps `rl ≤ r + a·x_j ≤ ru` when one does (logical stays basic) and otherwise becomes basic
at `(bound − r) / a` with the logical nonbasic at that bound.

**P6 — Free column singletons in equality rows** (continuous columns only). Column j in one
row i, rl = ru = b, and x_j free or with bounds that P1 shows the row implies ("implied
free"): the row defines x_j. Remove both; costs `c_k ← c_k − c_j·a_ik / a_ij` for the
other columns of the row; `c0 ← c0 + c_j·b / a_ij`. *Postsolve:*
`x_j = (b − Σ_{k≠j} a_ik·x_k) / a_ij`, basic; `y_i = c_j / a_ij`; logical nonbasic, fixed.

**P7 — Duplicate rows** (MILP-safe). Rows i and k with a_k = λ·a_i (same pattern, ratio
constant to 1e-10 relative; found by hashing each row's pattern and normalized values): the
second says `rl_k/λ ≤ a_iᵀx ≤ ru_k/λ` (ends swapped for λ < 0). Intersect into row i,
remove row k, remember for each end which row supplied it. Empty beyond τ is infeasibility.
*Postsolve:* if the active end of the merged row came from row k, `y_k = y / λ`, `y_i = 0`,
logical k nonbasic at the matching bound and logical i basic; otherwise `y_i = y`, `y_k = 0`
and logical k basic.

**P8 — Duplicate columns** (continuous columns only). Columns j and k with a_k = λ·a_j:
- costs proportional (c_k = λ·c_j): merge into z = x_j + λ·x_k with the bounds that sum
  implies, kept as column j. *Postsolve:* split z, putting x_k at a bound that leaves x_j in
  range, x_j basic if z was; d_k = λ·d_j.
- otherwise one of the two is always the cheaper way to make z; if the cheaper one is
  unbounded in the useful direction, fix the other at the bound it would be pushed to.
  *Postsolve:* as P4.

**Rules already in v0.1** (fixed columns, singleton rows, empty rows, empty columns, integer
bound rounding) move into the workspace unchanged and run in the same passes.

### 5.3 Rules for mixed-integer programs (mode `.boundsOnly`)

Branch and bound keeps every row and column (HANDBOOK, decision 7), and reports no duals,
so its presolve may tighten anything that keeps the shape and needs only a primal postsolve
— which is the identity:

**M1 — Bound tightening by activity.** From row i and column j: for a_ij > 0,
`x_j ≤ (ru − (L_i − a_ij·xl_j)) / a_ij` and `x_j ≥ (rl − (U_i − a_ij·xu_j)) / a_ij`
(mirrored for a_ij < 0), when the activities involved are finite. Integer columns round
inward. A bound is replaced only when it improves by more than 1e-3·max(1, range) or
becomes finite, to keep the passes finite.

**M2 — P2, P3 and P4 as bound changes.** A forcing row fixes its columns through their
bounds and stays; a redundant row has its bounds set to ±∞ and stays; a dominated column is
fixed through its bounds.

**M3 — Integer rows.** A row whose columns are all integer with coefficients that a power of
ten up to 10⁶ makes integral: divide by their greatest common divisor g and round the
bounds inward, `ru ← g·⌊ru/g⌋`, `rl ← g·⌈rl/g⌉`.

**M4 — Coefficient tightening** (first on the cut list). For a row Σ a_j·x_j ≤ b and a
binary column with a_j > 0: if `U_i − a_j < b` the row is redundant whenever x_j = 0, and
with δ = b − (U_i − a_j) both a_j and b may be lowered by δ. This changes coefficients, so
the reduced problem gets a matrix with the same pattern and new values.

### 5.4 Order and limits

One pass: integer rounding and fixed columns; P1; P2 and P3; singleton rows; P4; P5 and P6;
empty rows and columns; P7; P8. Passes repeat while something changed, at most
`Options.maxPasses` times. P7 and P8 hash every row or column and run at most twice per
solve. Each pass is O(z + m + n) expected.

### 5.5 Certificates

A reduced problem that turns out infeasible or unbounded has a ray in the reduced space.
The v0.1 rules map such rays back; for the rules of this specification that is not required.
When any of P2–P8 fired and the reduced problem is infeasible, unbounded, or neither can be
told, the engine solves the original problem without presolve and returns that answer and
its certificate — what `Simplex` already does when presolve itself proves infeasibility.

### 5.6 Warm starts

`reducePrimal` drops removed columns (a merged pair of P8 contributes x_j + λ·x_k).
`reduceBasis` keeps the statuses of kept rows and columns; it is a hint, and the engine
repairs it, as today.

## 6. Test strategy

The oracles of v0.1 §14.1 stay: constructed optima, published optima, cross-engine
agreement, certificates. This specification adds:

| Oracle | For | Where |
|---|---|---|
| Dense reference | every `SparseLU` solve against `denseSolve` on the same basis; every factorization reconstructs B | `ZTronLPNumericsTests` |
| Update against refactorization | after k updates, solves equal those of a fresh factorization of the same basis, for both update kinds | `ZTronLPNumericsTests` |
| Enumeration | every cut holds at every integer point of small pure-integer models; a larger MILP presolve keeps the optimum | `IntegerEnumeration` in `ZTronLPTestSupport` |
| Known solution | on mixed models, every cut holds at an optimal solution found with cuts off, and the optimum does not change | `ZTronLPBranchAndBoundTests`, corpus |
| Presolve on and off | same objective to 1e-9, expanded primal feasible, expanded duals feasible and complementary | `ZTronLPCoreTests`, `ZTronLPSimplexTests` |
| Zero-pivot basis | the postsolved basis, given to a solve without presolve, is optimal in 0 iterations | `ZTronLPSimplexTests` |
| Planted structure | instances built from a constructed optimum by adding exactly the structure a rule removes; the rule must find it and the optimum must not move | `InstanceGenerator.planted` |

Debug builds run reduced sizes; the corpora and the 1,000-instance families run in release,
as in v0.1. Thread Sanitizer covers the simplex, branch-and-bound, integration and liveness
targets at every gate.

## 7. Benchmarks and acceptance

`ZTronLPBenchmarks` gains the lines below. "Baseline" is v0.1 on the development machine
(Apple M3, release build; README §5), re-measured by X-01 for the workloads that are new.

| Workload | Metric | Baseline | Acceptance for v0.2 |
|---|---|---|---|
| Netlib set, dual simplex, `.sparseLU` forced | total seconds | 0.087 s (dense) | ≤ 1.5× the dense total |
| Transport 2,000 × 20,000, dual simplex | seconds, `SparseLUBasis` | 0.64 s (sparse QR), 2.04 s (dense) | ≤ half the sparse QR time |
| Transport 10,000 × 100,000 (or the size X-01 fixes), dual simplex | seconds, `SparseLUBasis` vs `SparseQRBasis` | X-01 | ≥ 3× faster than sparse QR |
| Same two transport LPs, Forrest–Tomlin vs product form | seconds, refactorizations | — | the faster becomes the default update |
| Netlib set and both transport LPs | fill ratio of the final basis | — | reported |
| MIPLIB 3 set, B&B with cuts on and off, both node engines | nodes, seconds, root gap closed | nodes and seconds of README §5 | every instance optimal; nodes at most half on at least 5 of 10 instances; no instance more than 1.25× slower; total seconds not higher. Otherwise the default is `.none` |
| Netlib set, presolve of §5.2 on and off | rows and columns removed, pivots, seconds | 0.087 s dual, 0.112 s primal | every optimum unchanged; totals not more than 1.1× the baseline; at least 6 of 13 instances lose a row or a column |
| MIPLIB 3 set, presolve of §5.3 on and off | bounds tightened, nodes, seconds | README §5 | every instance optimal; total nodes not higher |
| Planted family, 300 instances | planted reductions found | — | all of them |
| Cancellation latency with cuts on | p99 ms | 3.6 ms | ≤ 50 ms (rule L1) |

Peak resident memory is printed after each section, as today.

## 8. Work packages

### 8.1 Overview

68 packages — 63 work packages and 5 gates — and 30 h 20 min of tool time at the upper
bounds, none longer than 30 minutes, in three tracks plus shared and closing work.

| ID | Package | Min | Needs |
|---|---|---|---|
| **X — shared** | | | |
| X-01 | Baseline numbers and a larger LP in the benchmark | 30 | — |
| X-02 | Enumeration oracle in the test support | 25 | — |
| **LU — sparse LU** | | | |
| LU-01 | Active matrix from a basis | 25 | — |
| LU-02 | Singleton pivots | 30 | LU-01 |
| LU-03 | Pivot search with a threshold | 25 | LU-01 |
| LU-04 | Elimination and fill | 30 | LU-02, LU-03 |
| LU-05 | Factors in solve order, `ftran`, `btran` | 30 | LU-04 |
| LU-06 | Singular bases | 25 | LU-05 |
| LU-07 | `SparseLUBasis` with product-form updates | 25 | LU-06 |
| LU-08 | Selection in `Simplex`, corpus tests | 25 | LU-07 |
| LU-09 | Refactorization triggers and growth | 25 | LU-07 |
| LU-10 | Flat storage, unsafe loops | 30 | LU-08 |
| LU-11 | Benchmark lines, automatic rule, dependents | 30 | LU-10, X-01 |
| G1 | Gate: sparse LU with product-form updates | 30 | LU-09, LU-11 |
| LU-12 | Pivot order and column index for updates | 25 | G1 |
| LU-13 | Spike and row elimination | 30 | LU-12 |
| LU-14 | Applying the update; row etas in the solves | 30 | LU-13 |
| LU-15 | Stability test, refusal, policy | 25 | LU-14 |
| LU-16 | Update kinds measured; the default | 20 | LU-15 |
| G2 | Gate: Forrest–Tomlin | 20 | LU-16 |
| **PRE — presolve** | | | |
| PRE-01 | Workspace; the v0.1 rules moved | 30 | — |
| PRE-02 | Steps, options, statistics | 25 | PRE-01 |
| PRE-03 | Planted rows in the generator | 25 | — |
| PRE-04 | Planted columns in the generator | 25 | — |
| PRE-05 | Activity bounds (P1) | 25 | PRE-02 |
| PRE-06 | Redundant rows (P2) | 25 | PRE-05, PRE-03 |
| PRE-07 | Forcing rows: reduction and primal values (P3) | 25 | PRE-06 |
| PRE-08 | Forcing rows: duals and basis | 30 | PRE-07 |
| PRE-09 | Dominated columns (P4) | 30 | PRE-02, PRE-04 |
| PRE-10 | Slack column singletons (P5) | 30 | PRE-02, PRE-04 |
| PRE-11 | Free column singletons (P6) | 30 | PRE-10 |
| PRE-12 | Implied free columns | 20 | PRE-11, PRE-05 |
| PRE-13 | Duplicate rows: detection (P7) | 25 | PRE-02, PRE-03 |
| PRE-14 | Duplicate rows: merge and postsolve | 30 | PRE-13 |
| PRE-15 | Duplicate columns: detection and domination (P8) | 30 | PRE-09, PRE-13 |
| PRE-16 | Duplicate columns: merge and postsolve | 30 | PRE-15 |
| PRE-17 | Order, passes, limits | 20 | PRE-08, PRE-12, PRE-14, PRE-16 |
| PRE-18 | Certificates: the solve without presolve | 25 | PRE-17 |
| PRE-19 | Simplex round trips and the zero-pivot basis | 30 | PRE-18 |
| PRE-20 | Interior-point round trips | 20 | PRE-18 |
| G3 | Gate: LP presolve | 30 | PRE-19, PRE-20 |
| PRE-21 | MILP: bound tightening by activity (M1) | 30 | PRE-05, X-02 |
| PRE-22 | MILP: fixing, forcing and freed rows as bounds (M2) | 25 | PRE-21, PRE-08, PRE-09 |
| PRE-23 | MILP: integer rows (M3) | 25 | PRE-21 |
| PRE-24 | MILP: coefficient tightening (M4) | 30 | PRE-22 |
| PRE-25 | Corpus and benchmark lines | 30 | PRE-23, X-01 |
| G4 | Gate: MILP presolve | 20 | PRE-25 |
| **CUT — cutting planes** | | | |
| CUT-01 | `CompiledLP.appendingRows` | 25 | — |
| CUT-02 | Options and summary | 20 | — |
| CUT-03 | `Cut`: form, cleaning, measures | 30 | CUT-02 |
| CUT-04 | Tableau rows from a basis | 30 | — |
| CUT-05 | Gomory: the shifted row and the formula | 30 | CUT-04 |
| CUT-06 | Gomory: back to structural columns | 25 | CUT-05, CUT-03 |
| CUT-07 | Gomory separator, validity by enumeration | 25 | CUT-06, X-02 |
| CUT-08 | Knapsack rows | 25 | CUT-03 |
| CUT-09 | Cover cuts | 30 | CUT-08, X-02 |
| CUT-10 | Selection | 25 | CUT-03 |
| CUT-11 | Re-solving with appended rows | 30 | CUT-01 |
| CUT-12 | The loop | 30 | CUT-07, CUT-09, CUT-10, CUT-11 |
| CUT-13 | Dropping slack cuts | 20 | CUT-12 |
| CUT-14 | Wiring into the search | 30 | CUT-13 |
| CUT-15 | Engines with another state type | 20 | CUT-14 |
| CUT-16 | Liveness and determinism | 25 | CUT-14 |
| CUT-17 | Corpus tests | 25 | CUT-14 |
| CUT-18 | Benchmark lines and the default | 30 | CUT-17, X-01 |
| G5 | Gate: cuts | 30 | CUT-15, CUT-16, CUT-18 |
| **Closing** | | | |
| X-03 | README and HANDBOOK | 30 | G2, G4, G5 |
| X-04 | Release gate | 30 | X-03 |

Per track, gates included: shared 55 min; sparse LU 8 h; presolve 12 h; cuts 8 h 25 min;
closing 1 h.

### 8.2 Order and parallel work

The three tracks touch different targets and can run in separate sessions. They meet in five
files, where the later package rebases on the earlier one:

| File | Packages, in order |
|---|---|
| `Sources/ZTronLPSimplex/Simplex.swift` | LU-08, LU-11, PRE-18 |
| `Sources/ZTronLPBranchAndBound/BranchAndBound.swift` | PRE-21/22 (the mode's options), CUT-02, CUT-14 |
| `Sources/ZTronLPBenchmarks/main.swift` | X-01, LU-11, LU-16, PRE-25, CUT-18 |
| `Sources/ZTronLPTestSupport/Generators.swift` | X-02, PRE-03, PRE-04 |
| `README.md`, `HANDBOOK.md` | X-03 only; gates record their numbers in HANDBOOK's benchmark section |

Recommended single-session order: X-01, X-02, LU-01…G1, PRE-01…G3, CUT-01…G5, PRE-21…G4,
LU-12…G2, X-03, X-04. Forrest–Tomlin is last because it is the first thing to cut (§9).

### 8.3 Gates

A gate is a package: it runs the commands, records the numbers, and decides a default.

```bash
swift test
```

```bash
swift test -c release --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests|ZTronLPSimplexTests|ZTronLPBranchAndBoundTests'
```

```bash
ZTRONLP_LATENCY_SCALE=20 swift test --sanitize=thread --filter 'ZTronLPSimplexTests|ZTronLPBranchAndBoundTests|ZTronLPIntegrationTests|ZTronLPLivenessTests'
```

```bash
swift run -c release ZTronLPBenchmarks
```

| Gate | Passes when | Decides |
|---|---|---|
| G1 | the four commands are green; the three sparse-LU rows of §7 hold | the automatic factorization rule and `Simplex.denseBasisLimit` |
| G2 | green; the update comparison of §7 is recorded | the default `SparseLUBasis.Update` |
| G3 | green; the netlib presolve row and the planted row hold | whether P2–P8 are in `.all` |
| G4 | green; the MIPLIB presolve row holds | whether M1–M4 run in `.boundsOnly` by default |
| G5 | green; the cut row and the latency row hold | whether `BranchAndBound(cuts:)` defaults to `.default` |

A gate that fails on a number, not on a test, does not block: the default stays as in v0.1,
the feature stays selectable, and HANDBOOK records the measurement.

### 8.4 The packages

Paths are relative to the package root. "Tests" names the suite or test function that must
pass; filters are for `swift test --filter`.

#### Shared

**X-01 — Baseline numbers and a larger LP in the benchmark** · 30 min
- *Files:* `Sources/ZTronLPBenchmarks/main.swift`, `HANDBOOK.md`.
- *Do:* add a section "Random transport LP, large" built with the existing
  `sparseTransport(sources:sinks:arcs:seed:)` at 10,000 rows × 100,000 columns; if the
  section takes more than three minutes with `SparseQRBasis`, halve the size until it does
  not and write the size chosen into §7 of this file. Print dual simplex on `.sparseQR` and
  the interior point. Run the benchmark once and paste the full output into HANDBOOK under
  "Baseline for v0.2".
- *Done when:* `swift run -c release ZTronLPBenchmarks` prints the new section; §7 names the
  size; HANDBOOK has the output.

**X-02 — Enumeration oracle in the test support** · 25 min
- *Files:* `Sources/ZTronLPTestSupport/Enumeration.swift` (new),
  `Tests/ZTronLPTestSupportTests/EnumerationTests.swift` (new).
- *Do:* `IntegerEnumeration.feasiblePoints(of:limit:) -> [[Double]]?` for a `CompiledLP`
  whose columns are all integer with finite bounds and whose box has at most `limit`
  (default 200,000) points, `nil` otherwise; `optimum(of:)`, returning the best objective and
  a point that attains it, or `nil`. Feasibility through `CompiledLP.maxViolation(at:)` at 1e-9.
- *Done when:* tests cover a 3-column knapsack with a hand-computed optimum, an infeasible
  model (empty list), a model over the limit (`nil`), and agreement with
  `BranchAndBound().solve` on 50 `InstanceGenerator.randomMILP` instances.
  Filter: `EnumerationTests`.

#### Sparse LU

**LU-01 — Active matrix from a basis** · 25 min
- *Files:* `Sources/ZTronLPNumerics/SparseLU.swift` (new),
  `Tests/ZTronLPNumericsTests/SparseLUTests.swift` (new).
- *Do:* `struct SparseLU: Sendable` and its internal `Workspace`: from `(basic, lp)` build
  the rows as lists of (position, value), the per-position row lists, the two count arrays
  and the largest magnitude of B. A logical column n + i is the single entry (i, −1).
- *Done when:* for the bases of `mixedBasis` on `matrixLP` (the helpers of the test
  target's `Support.swift`) the workspace reproduces `basisMatrix` entry for entry, counts
  included, and m = 0 works. Filter: `SparseLUTests`.

**LU-02 — Singleton pivots** · 30 min · needs LU-01
- *Do:* phase 1 of §3.2: the two queues, pivots recorded as (row, position, value), L etas
  for row singletons, U rows for position singletons, counts kept current. Stop when no
  singleton is left and report how many pivots were taken.
- *Done when:* a permuted triangular matrix of order 200 takes 200 pivots with fill ratio 1;
  the all-logical basis takes m; a matrix with a 3 × 3 dense block stops with 3 rows left.

**LU-03 — Pivot search with a threshold** · 25 min · needs LU-01
- *Do:* `Workspace.choosePivot() -> (row, position)?` as §3.2 phase 2: the four sparsest
  active positions, the column-relative threshold u = 0.1 (`pivotThreshold`), Markowitz
  count, the tie rules. `nil` when no position has an entry above the singularity
  tolerance.
- *Done when:* unit tests on hand-built 4 × 4 and 6 × 6 patterns pin the pivot chosen: the
  smallest count wins; an entry below a tenth of its column's largest is never chosen; ties
  resolve as specified; the result does not depend on the order entries were inserted.

**LU-04 — Elimination and fill** · 30 min · needs LU-02, LU-03
- *Do:* `Workspace.eliminate(row:position:)` and the loop that alternates phase 1 and
  phase 2 until m pivots are taken or `choosePivot` returns `nil`: multipliers into L, the
  pivot row into U, row updates through a dense scatter of the pivot row, fill-in, the drop
  tolerance, counts and the singleton queue kept current.
- *Done when:* on 40 random sparse matrices (m from 4 to 160, densities as in
  `BasisFactorizationTests.randomBasesMatchDenseSolve`) the product of the recorded L etas
  and U rows, expanded densely, equals B to 1e-10 relative; `fillRatio` is ≥ 1 and finite.

**LU-05 — Factors in solve order, `ftran`, `btran`** · 30 min · needs LU-04
- *Do:* a throwing initializer (`throws(NumericalError)`),
  `SparseLU.init(basic:lp:pivotThreshold:dropTolerance:singularityTolerance:)`, that runs
  the workspace and keeps L and U in pivot order;
  `ftran(_:)` and `btran(_:)` as §3.3.
- *Done when:* both solves match `denseSolve` on the basis matrix and on its transpose to
  1e-8 relative for the matrices of LU-04, for the all-logical basis and for m = 0.

**LU-06 — Singular bases** · 25 min · needs LU-05
- *Do:* when pivots run out, throw `.singular(positions:rows:)` with the unpivoted positions
  and the still-active rows, paired in ascending order.
- *Done when:* the cases of `aRepeatedColumnIsReportedAndRepaired`,
  `linearlyDependentColumnsAreReportedAndRepaired` and
  `aNearlySingularBasisIsTreatedAsSingularByDenseLU` in `BasisFactorizationTests`, run on
  `SparseLU`, report positions whose replacement by the named logicals gives a basis that
  factors; a well-conditioned basis never throws.

**LU-07 — `SparseLUBasis` with product-form updates** · 25 min · needs LU-06
- *Files:* `Sources/ZTronLPNumerics/BasisFactorization.swift`,
  `Tests/ZTronLPNumericsTests/BasisFactorizationTests.swift`.
- *Do:* `public struct SparseLUBasis: BasisFactorization` holding a `SparseLU?` and an
  `EtaFile`; `refactorInterval` 100; `needsRefactor` on the interval, on growth above 1e7
  and on update storage above 3·(factor nonzeros) + m; `conditionEstimate()` returns `nil`;
  `public var fillRatio: Double?`. Add it to `strategies()` in the test file so that every
  parameterized test covers it, and to `etaUpdatesMatchRefactorization`.
- *Done when:* the whole suite `Basis factorization` passes with three strategies.

**LU-08 — Selection in `Simplex`, corpus tests** · 25 min · needs LU-07
- *Files:* `Sources/ZTronLPSimplex/Simplex.swift`,
  `Tests/ZTronLPSimplexTests/NetlibSimplexTests.swift`.
- *Do:* `Simplex.Factorization.sparseLU`; `makeFactorization(rows:)` returns
  `SparseLUBasis(dropTolerance: tolerances.dropZero)` for it. `.automatic` is not touched
  here.
- *Done when:* a new parameterized test solves the 13 netlib instances with
  `Simplex(method, factorization: .sparseLU)` for both methods to the reference optima;
  `everyConfigurationAgreesOnConstructedOptima` and `badlyScaledInstances` in
  `SimplexTests.swift` include `.sparseLU`; `RefinementTests` passes with it added to
  `theConditionEstimateDoesNotNeedADenseBasis`. Filter: `ZTronLPSimplexTests`.

**LU-09 — Refactorization triggers and growth** · 25 min · needs LU-07
- *Do:* record the largest multiplier of a factorization (`SparseLU.growth`); a
  factorization whose growth exceeds 1e10 is retried once with `pivotThreshold` 0.5 before
  it is returned. Tests for each `needsRefactor` trigger, in the style of
  `needsRefactorTripsAtTheDocumentedCounts`.
- *Done when:* the trigger tests pass; a matrix built to have growth 1e12 at u = 0.1 is
  factored with growth under 1e6 after the retry and still solves to 1e-8.

**LU-10 — Flat storage, unsafe loops** · 30 min · needs LU-08
- *Do:* after factorization copy L and U into `start`/`index`/`value` arrays; rewrite
  `ftran` and `btran` on `withUnsafeBufferPointer`, as `EtaFile` does. No behaviour change.
- *Done when:* `SparseLUTests` and `Basis factorization` pass unchanged; a micro-benchmark
  line in `ZTronLPBenchmarks` ("factorization kernels") prints refactor milliseconds, fill
  ratio and microseconds per `ftran` for the final bases of `degen2` and of the 2,000 ×
  20,000 transport LP, for all three strategies.

**LU-11 — Benchmark lines, automatic rule, dependents** · 30 min · needs LU-10, X-01
- *Files:* `Sources/ZTronLPBenchmarks/main.swift`, `Sources/ZTronLPSimplex/Simplex.swift`,
  `Sources/ZTronLPOptimizer/Automatic.swift`, `Sources/ZTronLPCPSAT/LPRelaxation.swift`.
- *Do:* add `SparseLUBasis` rows to both transport sections and a netlib total with
  `.sparseLU` forced; run; set `Simplex.denseBasisLimit` to the measured crossover and make
  `.automatic` pick sparse LU above it; `Automatic` uses `.sparseLU` for `.sparseSimplex`;
  the size estimate of CP-SAT's LP worker uses `24·nonzeros + 64·m` bytes above the limit.
- *Done when:* the benchmark prints the rows; `ZTronLPOptimizerTests`, `ZTronLPCPSATTests`
  (`aBudgetTooSmallForTheEngineRunsWithoutIt` adjusted if its numbers depended on the old
  estimate) and `ZTronLPSimplexTests` pass.

**G1 — Gate: sparse LU with product-form updates** · 30 min — §8.3.

**LU-12 — Pivot order and column index for updates** · 25 min · needs G1
- *Do:* `SparseLU` keeps U row-wise with spare capacity per row (rows as arrays again, or
  flat with overflow — the choice is free), a pivot order array with tombstones and a
  position → rows index. `ftran`/`btran` walk the order array.
- *Done when:* all existing tests pass; a test that moves random pivots to the end of the
  order (without changing values) still solves the correspondingly permuted system.

**LU-13 — Spike and row elimination** · 30 min · needs LU-12
- *Do:* `SparseLU.forrestTomlinStep(alpha:leaving:)` computing w = U·α, the multipliers μ
  and the new pivot value of §3.4 steps 1–3, without modifying the factors; return them.
- *Done when:* for 200 random (basis, entering column, leaving position) triples the new
  pivot value equals `α[p]·u_s` to 1e-9 relative, and applying the multipliers to a dense
  copy of U with its column replaced leaves row s with one entry.

**LU-14 — Applying the update; row etas in the solves** · 30 min · needs LU-13
- *Do:* steps 4–5 of §3.4 and the row-eta file in `ftran`/`btran`;
  `SparseLUBasis.Update.forrestTomlin` routes `update` here.
- *Done when:* `etaUpdatesMatchRefactorization` passes for `.forrestTomlin` (140 and 260
  successive pivots against refactorization) and the netlib test of LU-08 passes with it.

**LU-15 — Stability test, refusal, policy** · 25 min · needs LU-14
- *Do:* the two refusal conditions of §3.4 (`.unstableUpdate`), `needsRefactor` for this
  update kind (interval, row-eta nonzeros, growth of μ).
- *Done when:* a pivot built to be unstable is refused and the engine's solve of the same
  problem still ends optimal (it refactors); `aZeroOrNonFinitePivotIsRefused` covers the new
  kind.

**LU-16 — Update kinds measured; the default** · 20 min · needs LU-15
- *Do:* benchmark rows for both update kinds on the two transport LPs and the netlib total;
  set the default of `SparseLUBasis(update:)` to the faster.
- *Done when:* the rows print; the default is the measured winner, with the numbers in a
  comment beside it.

**G2 — Gate: Forrest–Tomlin** · 20 min — §8.3.

#### Presolve

**PRE-01 — Workspace; the v0.1 rules moved** · 30 min
- *Files:* `Sources/ZTronLPCore/Model/PresolveWorkspace.swift` (new),
  `Sources/ZTronLPCore/Model/Presolve.swift`.
- *Do:* move the state of `Presolve.run` (working bounds, counts, active flags, `rowShift`,
  steps, `removedValue`, the unbounded-column record) into `struct PresolveWorkspace`, the
  six rules into methods, the assembly of the reduced problem into `assemble()`. No
  behaviour change.
- *Done when:* `PresolveTests` (22 tests) passes unmodified, and a new test asserts that
  `Presolve.run` gives an identical `reduced` problem, `columnOrigin` and `rowOrigin` on the
  13 netlib instances before and after (the expected values are captured as counts of rows,
  columns and nonzeros in the test). Filter: `PresolveTests`.

**PRE-02 — Steps, options, statistics** · 25 min · needs PRE-01
- *Do:* `Presolve.Options` (`rules: Rules` option set with one member per rule of §5.2 and
  §5.3, `.all`, `.v01`; `maxPasses`), `Presolve.Statistics`, the four-argument `run`, a
  `usedRulesBeyondV01` flag for §5.5. New `Step` cases are added by the rule packages.
- *Done when:* `run(lp)` and `run(lp, options: .init())` agree while no new rule exists;
  statistics count the v0.1 rules correctly on three hand-built problems.

**PRE-03 — Planted rows in the generator** · 25 min
- *Files:* `Sources/ZTronLPTestSupport/Generators.swift`,
  `Tests/ZTronLPTestSupportTests/FixtureTests.swift`.
- *Do:* `InstanceGenerator.planted(_:rows:seed:)` taking a `ConstructedInstance` and adding
  rows that do not change its optimum: scaled duplicates of existing rows (looser or equal
  bounds), rows that are redundant by activity, forcing rows built on columns that are at a
  bound in the known solution. It returns the instance with the planted rows listed by kind.
- *Done when:* for 100 seeds the known primal solution is feasible for the planted problem
  and `Simplex(presolve: false)` returns the same objective to 1e-9.

**PRE-04 — Planted columns in the generator** · 25 min
- *Do:* `InstanceGenerator.planted(_:columns:seed:)`: slack column singletons (a row's slack
  made explicit), free column singletons in equality rows, dominated columns (cost ≥ 0, no
  row helped by raising them), duplicate columns (proportional and dominated).
- *Done when:* as PRE-03, and the known optimum extended by the planted columns' values is
  optimal (objective unchanged to 1e-9).

**PRE-05 — Activity bounds (P1)** · 25 min · needs PRE-02
- *Files:* `Sources/ZTronLPCore/Model/PresolveRules+Activity.swift` (new),
  `Tests/ZTronLPCoreTests/PresolveActivityTests.swift` (new).
- *Do:* per row the finite parts of L and U and the counts of infinite contributions;
  `updateActivities(column:oldLower:oldUpper:)`; infeasibility by activity.
- *Done when:* tests compare with a direct recomputation after random sequences of bound
  changes, including bounds that become finite or infinite.

**PRE-06 — Redundant rows (P2)** · 25 min · needs PRE-05, PRE-03
- *Do:* the rule, the step `.redundantRow(row:)`, postsolve of duals and basis, one-sided
  relaxation.
- *Done when:* every planted redundant row of 100 instances is removed;
  `postsolveInvariantsHoldOnRandomProblems` and
  `postsolvedDualsAreOptimalOnConstructedProblems` pass with the rule on.

**PRE-07 — Forcing rows: reduction and primal values (P3)** · 25 min · needs PRE-06
- *Do:* the reduction and `.forcingRow(row:atUpper:columns:)`; `expandPrimal`; the statuses
  of the forced columns in `expandBasis` (at lower or upper, not fixed).
- *Done when:* every planted forcing row is found; expanded primal values are feasible for
  the original and reproduce the objective.

**PRE-08 — Forcing rows: duals and basis** · 30 min · needs PRE-07
- *Do:* the dual of §5.2 P3 and the basis exchange (the column attaining the minimum
  becomes basic when y_i ≠ 0).
- *Done when:* on the planted family the expanded duals are feasible and complementary
  (the helper of `postsolvedDualsAreOptimalOnConstructedProblems`), and the basis has m
  basic columns.

**PRE-09 — Dominated columns (P4)** · 30 min · needs PRE-02, PRE-04
- *Do:* locks from the row bounds, the rule, `.dominatedColumn(column:value:atUpper:)`,
  the unbounded case through the existing `unboundedColumn` record.
- *Done when:* planted dominated columns are fixed; an instance with a column that improves
  forever is reported unbounded with a valid ray (`isImprovingRay`) and one that is
  infeasible as well is reported infeasible.

**PRE-10 — Slack column singletons (P5)** · 30 min · needs PRE-02, PRE-04
- *Do:* the rule, `.slackColumn(...)`, the postsolve cases of §5.2 P5.
- *Done when:* planted slacks are removed; primal, dual and basis invariants hold on the
  planted family, including slacks with one or both bounds infinite.

**PRE-11 — Free column singletons (P6)** · 30 min · needs PRE-10
- *Do:* the rule for free columns in equality rows: cost update, constant, step, postsolve.
- *Done when:* planted free singletons are removed with the row; x_j, y_i and the basis
  satisfy the invariants; a singleton in an inequality row is left alone.

**PRE-12 — Implied free columns** · 20 min · needs PRE-11, PRE-05
- *Do:* treat a column singleton whose bounds are implied by its row's activity bounds as
  free in PRE-11's rule.
- *Done when:* a test family where the bound is implied passes the invariants; one where it
  is not is left alone.

**PRE-13 — Duplicate rows: detection (P7)** · 25 min · needs PRE-02, PRE-03
- *Do:* hash of (pattern, values divided by the first nonzero) per active row; exact
  comparison inside a bucket; λ returned with each pair.
- *Done when:* every planted duplicate is found, across permutations of the entry order and
  scalings by powers of two and by 3 and −7; rows that differ in one coefficient by 1e-6
  are not paired.

**PRE-14 — Duplicate rows: merge and postsolve** · 30 min · needs PRE-13
- *Do:* the intersection, infeasibility, the step
  `.duplicateRow(kept:removed:ratio:lowerFromRemoved:upperFromRemoved:)`, postsolve of duals
  and basis.
- *Done when:* invariants hold on the planted family; two duplicate rows with disjoint
  ranges give `.infeasible`.

**PRE-15 — Duplicate columns: detection and domination (P8)** · 30 min · needs PRE-09, PRE-13
- *Do:* the same hashing on columns; the domination case of §5.2 P8 as a `.dominatedColumn`
  step.
- *Done when:* planted dominated duplicates are fixed and the invariants hold.

**PRE-16 — Duplicate columns: merge and postsolve** · 30 min · needs PRE-15
- *Do:* the proportional case: merged bounds, `.mergedColumn(kept:removed:ratio:…)`,
  the split in `expandPrimal`, statuses and reduced costs.
- *Done when:* invariants hold on the planted family; `reducePrimal` maps a point of the
  original to the merged column's value.

**PRE-17 — Order, passes, limits** · 20 min · needs PRE-08, PRE-12, PRE-14, PRE-16
- *Do:* the pass of §5.4, `maxPasses`, the two-run cap on hashing rules.
- *Done when:* `theRulesRunToAFixedPoint` and
  `aChainLongerThanThePassLimitLeavesAConsistentRemainder` pass with all rules; a test with
  every plant at once reaches a fixed point within the limit.

**PRE-18 — Certificates: the solve without presolve** · 25 min · needs PRE-17
- *Files:* `Sources/ZTronLPSimplex/Simplex.swift`,
  `Sources/ZTronLPInteriorPoint/InteriorPoint.swift`.
- *Do:* §5.5 in `Simplex.solve` and `InteriorPoint.solve`.
- *Done when:* infeasible and unbounded instances built on the planted family return
  certificates that pass `farkasGap` and `isImprovingRay`, with a warning naming the second
  solve.

**PRE-19 — Simplex round trips and the zero-pivot basis** · 30 min · needs PRE-18
- *Files:* `Tests/ZTronLPSimplexTests/PresolveRoundTripTests.swift` (new).
- *Do:* on 300 planted instances and the 13 netlib instances, for both methods: presolve
  on and off agree on the objective to 1e-9; the postsolved basis warm-starts
  `Simplex(method, presolve: false)` to optimality in 0 iterations.
- *Done when:* the suite passes (debug: 60 planted instances; release: 300).

**PRE-20 — Interior-point round trips** · 20 min · needs PRE-18
- *Done when:* the same family solved by `InteriorPoint()` agrees with the simplex to 1e-7
  on objective and to 1e-6 on primal values where the optimum is unique.

**G3 — Gate: LP presolve** · 30 min — §8.3.

**PRE-21 — MILP: bound tightening by activity (M1)** · 30 min · needs PRE-05, X-02
- *Files:* `Sources/ZTronLPCore/Model/PresolveRules+MILP.swift` (new),
  `Tests/ZTronLPCoreTests/PresolveMILPTests.swift` (new).
- *Do:* M1 in `.boundsOnly`, with the improvement threshold.
- *Done when:* on 200 small `randomMILP` instances the set of integer-feasible points
  (`IntegerEnumeration`) is unchanged and at least one bound tightens on most of them;
  `boundsOnlyKeepsEveryRowAndColumn` still passes.

**PRE-22 — MILP: fixing, forcing and freed rows as bounds (M2)** · 25 min · needs PRE-21, PRE-08, PRE-09
- *Done when:* enumeration shows the optimum unchanged; `BranchAndBoundTests` passes.

**PRE-23 — MILP: integer rows (M3)** · 25 min · needs PRE-21
- *Done when:* `2x + 4y ≤ 7` over integers becomes `≤ 6`; enumeration unchanged on 200
  instances with integral data; rows with a continuous column are left alone.

**PRE-24 — MILP: coefficient tightening (M4)** · 30 min · needs PRE-22
- *Do:* M4 and the reduced matrix with new values (same pattern).
- *Done when:* a big-M row `x ≤ 100·y`, x ≤ 10, y binary, becomes `x ≤ 10·y`; enumeration
  unchanged; the LP relaxation's bound does not get worse on 200 instances.

**PRE-25 — Corpus and benchmark lines** · 30 min · needs PRE-23, X-01
- *Do:* the two presolve rows of §7 in the benchmark; corpus tests assert the published
  optima with the new modes.
- *Done when:* the rows print; `ZTronLPIntegrationTests` passes in release.

**G4 — Gate: MILP presolve** · 20 min — §8.3.

#### Cutting planes

**CUT-01 — `CompiledLP.appendingRows`** · 25 min
- *Files:* `Sources/ZTronLPCore/Model/CompiledLP.swift`,
  `Tests/ZTronLPCoreTests/SolveTypesTests.swift`.
- *Do:* a public `appendingRows(_:names:)` returning a `CompiledLP`; each row is a tuple of
  `columns: [Int32]`, `coefficients: [Double]`, `lower: Double`, `upper: Double`, and `names`
  is an optional `[String]`.
- *Done when:* dimensions, entries (through `subscript`), transpose, names and integer
  columns are right for 0, 1 and 50 appended rows; a row naming a column out of range is a
  precondition failure documented in the comment.

**CUT-02 — Options and summary** · 20 min
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/Cuts.swift` (new),
  `Sources/ZTronLPBranchAndBound/BranchAndBound.swift`.
- *Do:* `Cuts`, `CutFamily`, `CutSummary`; the `cuts:` parameter and stored property in both
  initializers, default `.none` until G5; `BranchAndBoundAnalysis.cuts` (empty summary).
- *Done when:* `BranchAndBoundTests` passes with a new test of the defaults; existing call
  sites compile unchanged.

**CUT-03 — `Cut`: form, cleaning, measures** · 30 min · needs CUT-02
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/Cut.swift` (new),
  `Tests/ZTronLPBranchAndBoundTests/CutTests.swift` (new).
- *Do:* `Cut`, construction from ≤ or ≥ rows, `clean(against:)` as §4.7 (dropping small
  terms into the right-hand side, the three rejections), `violation(at:)`, `efficacy`,
  `cosine(with:)`.
- *Done when:* tests pin each rule: a dropped term on a bounded column weakens the cut by
  exactly its bound; on an unbounded column the cut is rejected; dynamism and support limits
  reject; measures match hand computation.

**CUT-04 — Tableau rows from a basis** · 30 min
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/Tableau.swift` (new), tests in `CutTests`.
- *Do:* `struct Tableau`: from `(lp, basis)` factor the basis with the factorization
  `Simplex` would pick; `row(ofBasicColumn:)` returns the row's entries on the structural
  columns and on the logicals, and the basic variable's value.
- *Done when:* on 30 small LPs solved to optimality, every row agrees with the dense
  computation B⁻¹·[A −I] to 1e-8.

**CUT-05 — Gomory: the shifted row and the formula** · 30 min · needs CUT-04
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/GomoryCuts.swift` (new).
- *Do:* steps 2 and 3 of §4.5 on one tableau row: shifts, disqualification, integer
  logicals, γ.
- *Done when:* the textbook example (two rows, two integer columns) gives the published
  cut; a row with a free nonbasic column is skipped; f₀ outside [0.01, 0.99] is skipped.

**CUT-06 — Gomory: back to structural columns** · 25 min · needs CUT-05, CUT-03
- *Do:* step 4 of §4.5, then `Cut.clean`.
- *Done when:* the cut is violated at x* by exactly 1 − Σ γ·t* scaled as the substitution
  implies (test on the textbook example), and holds at every integer point of it.

**CUT-07 — Gomory separator, validity by enumeration** · 25 min · needs CUT-06, X-02
- *Do:* `gomoryCuts(lp:basis:x:limit:) -> [Cut]`, most fractional rows first.
- *Done when:* on 200 `randomMILP` instances (pure integer, ≤ 12 columns) every cut
  separated from the LP optimum holds at every point of `IntegerEnumeration.feasiblePoints`
  to 1e-7 and at least one cut is violated by the LP optimum whenever that optimum is
  fractional.

**CUT-08 — Knapsack rows** · 25 min · needs CUT-03
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/KnapsackCoverCuts.swift` (new).
- *Do:* extraction of §4.6: both sides of a row, complementation, bound substitution.
- *Done when:* tests cover a pure knapsack, negative coefficients, a row with a bounded
  continuous column, and rows that must be skipped (an unbounded column, no binaries).

**CUT-09 — Cover cuts** · 30 min · needs CUT-08, X-02
- *Do:* cover, minimization, extension, mapping back, `coverCuts(lp:x:) -> [Cut]`.
- *Done when:* validity by enumeration on 200 binary knapsack-row instances; on a knapsack
  whose LP optimum is fractional a violated cover is found.

**CUT-10 — Selection** · 25 min · needs CUT-03
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/CutPool.swift` (new).
- *Done when:* tests pin the order, the parallelism filter, the cap and the treatment of
  duplicates; the result is independent of the order cuts were added.

**CUT-11 — Re-solving with appended rows** · 30 min · needs CUT-01
- *Files:* `Sources/ZTronLPBranchAndBound/Cuts/CutLoop.swift` (new).
- *Do:* `Basis.extended(byRows:)`; `resolve(lp:from:gate:)` running
  `Simplex(.dual, presolve: false)` through `makeEngine(for:context:)` with
  `.basis(extended)` and the budget of §4.3.
- *Done when:* after appending a violated row to 30 solved LPs the re-solve equals a cold
  solve of the augmented LP (objective to 1e-9) in fewer pivots.

**CUT-12 — The loop** · 30 min · needs CUT-07, CUT-09, CUT-10, CUT-11
- *Do:* §4.3 with its three stopping rules and the summary.
- *Done when:* on 50 small MILPs the bound never decreases from round to round, the loop
  ends within `maxRounds`, every applied cut is valid by enumeration, and the MILP optimum
  (by enumeration) is feasible for the final LP.

**CUT-13 — Dropping slack cuts** · 20 min · needs CUT-12
- *Done when:* the LP after dropping has the same optimum (1e-9), the reduced basis is
  optimal in 0 pivots, and only cuts with a nonbasic logical remain.

**CUT-14 — Wiring into the search** · 30 min · needs CUT-13
- *Files:* `Sources/ZTronLPBranchAndBound/BranchAndBound.swift`.
- *Do:* run the loop after the root LP when `cuts` enables a family and the model has
  integer columns; build `TreeSearch` on the augmented LP; root state as §4.4; events;
  `CutSummary` in the analysis.
- *Done when:* `BranchAndBoundTests` passes with cuts on and off; a knapsack model's node
  count drops with cuts on; `cuts: .none` gives byte-identical deterministic results to
  before this package (the existing determinism tests).

**CUT-15 — Engines with another state type** · 20 min · needs CUT-14
- *Files:* `Tests/ZTronLPBranchAndBoundTests/EngineStubTests.swift`.
- *Done when:* a stub engine whose `State` is not `Basis` solves a small MILP with cuts on
  (the fallback of §4.4), and `L5LimitRetryTests` passes unchanged.

**CUT-16 — Liveness and determinism** · 25 min · needs CUT-14
- *Files:* `Tests/ZTronLPLivenessTests/L1CancellationTests.swift`,
  `Tests/ZTronLPBranchAndBoundTests/BranchAndBoundTests.swift`.
- *Done when:* cancellation latency with cuts on is inside `LatencyBounds`; `.finished` is
  delivered once when the stop lands inside the loop; twenty deterministic runs with cuts
  on are identical.

**CUT-17 — Corpus tests** · 25 min · needs CUT-14
- *Files:* `Tests/ZTronLPIntegrationTests/CorpusTests.swift`.
- *Done when:* the ten MIPLIB 3 instances reach the published optima with cuts on, with
  both node engines (release; the debug subset as today), and every cut kept for the search
  holds at the optimal solution found with cuts off.

**CUT-18 — Benchmark lines and the default** · 30 min · needs CUT-17, X-01
- *Do:* the cut row of §7: nodes, seconds and root gap closed, cuts on and off; set the
  default of `cuts:` by the acceptance.
- *Done when:* the table prints; the default matches the rule of §7.

**G5 — Gate: cuts** · 30 min — §8.3.

#### Closing

**X-03 — README and HANDBOOK** · 30 min
- *Do:* README §2 rows for every declaration of Appendix A; §4 (defects and limits) edited
  for what is no longer missing; §5 with the gate measurements; HANDBOOK decisions for each
  default that did or did not change.
- *Done when:* the cross-check script used for v0.1's README (every top-level public name
  appears in an API table; every benchmark number matches the log) reports no mismatch.

**X-04 — Release gate** · 30 min
- *Done when:* the four commands of §8.3 are green, plus the iOS and Mac Catalyst builds of
  v0.1 (`xcodebuild`, 0 warnings).

## 9. Cut list, risks, open questions

**Cut list, in order.** If time runs short, drop from the top; everything below the line is
required.

1. Forrest–Tomlin updates (LU-12 to LU-16, G2): product-form updates on the sparse factors
   are complete without them.
2. Coefficient tightening (PRE-24).
3. Duplicate columns (PRE-15, PRE-16): the least common structure of §5.2.
4. Knapsack cover cuts (CUT-08, CUT-09): Gomory cuts alone still make the loop.

---

**Stretch, after everything else:** mixed-integer rounding cuts on single rows; hyper-sparse
solves (symbolic reach before `ftran`/`btran`); count buckets for the pivot search; a dense
LAPACK factorization of the nucleus once it is more than half full; doubleton-equation
aggregation, which needs a presolve workspace that can change coefficients; probing on
binaries.

**Risks.**

| Risk | Likelihood | Impact | What limits it |
|---|---|---|---|
| A postsolve that is right for values and wrong for duals or the basis | High | A wrong dual or a non-optimal basis handed to a warm start | Each rule has its own package for duals and basis; the zero-pivot oracle of PRE-19; §5.5 removes rays from the problem |
| An invalid cut | Medium | A wrong optimum, silently | Validity by enumeration in every separator's package; the known-solution check on the corpus; safeguards of §4.7; cuts are off unless G5 passes |
| Cuts that slow the search down | Medium | Slower solves by default | The 1.25× rule of §7; root-only; slack cuts dropped |
| A nucleus that is large and fills | Medium | Refactorization slower than sparse QR on some problems | The O(nucleus²) search is stated; `fillRatio` is reported; the automatic rule follows the measurement, not the hope |
| Product-form etas growing dense between refactorizations | Medium | Solves slower than they need be | `needsRefactor` on storage; Forrest–Tomlin as stage two |
| Presolve removing what a warm start names | Low | A warm start that helps less | `reduceBasis` is a hint and the engine repairs it, as today |
| Tolerances in three new places | Medium | Flaky behaviour on ill-conditioned input | Every constant named and commented; the Hilbert family of `InstanceGenerator.hilbert` added to the round-trip tests of LU-08 and PRE-19 |

**Open questions for the author.**

1. Should cuts also feed CP-SAT's LP propagator, which solves the same relaxation? Not
   specified here; the cut loop is written so that it could.
2. `Simplex.Factorization.sparseLU` breaks exhaustive switches in client code. Acceptable
   before a tagged release, or should the selection move to a struct?
3. The acceptance for cuts is stated on ten small instances. Is there a model of your own
   that should be in the gate?

## Appendix A — Public declarations added

| Target | Declaration |
|---|---|
| `ZTronLPNumerics` | `struct SparseLUBasis: BasisFactorization` with `enum Update { productForm, forrestTomlin }`, `init(update:refactorInterval:pivotThreshold:dropTolerance:singularityTolerance:)`, `refactorInterval`, `pivotThreshold`, `dropTolerance`, `singularityTolerance`, `fillRatio` |
| `ZTronLPSimplex` | `Simplex.Factorization.sparseLU` |
| `ZTronLPCore` | `CompiledLP.appendingRows(_:names:)`; `Presolve.Options` (`rules`, `maxPasses`), `Presolve.Options.Rules`, `Presolve.Statistics`, `Presolve.statistics`, `Presolve.run(_:tolerances:mode:options:)` |
| `ZTronLPBranchAndBound` | `struct Cuts`, `enum CutFamily`, `struct CutSummary`; `BranchAndBound.cuts` and the `cuts:` initializer parameter; `BranchAndBoundAnalysis.cuts` |
| `ZTronLPTestSupport` (not part of the facade) | `enum IntegerEnumeration`; `InstanceGenerator.planted(_:rows:seed:)`, `planted(_:columns:seed:)` |

`SparseLU`, `PresolveWorkspace`, `Cut`, `Tableau` and the separators are internal.
