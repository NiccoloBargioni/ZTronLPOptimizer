# Cycle A (claims first) - Finder F1 - Core: DSL, compile, presolve, scaling, MPS/LP I/O, result types

- Cycle: A (claims first; independent of cycle B)
- Area: F1 Core (Sources/ZTronLPCore/{DSL,Model,IO,Solve}, Tests/ZTronLPCoreTests/**)
- Probe slot: /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-A/Slots/F1/
- Package: /Users/admin/Documents/ZTronLPOptimizer @ d9afebe (main), Swift 6.4, Apple M3 8 cores, macOS 27
- Method: extract concrete claims from README §2.1-2.4, §3, §4 (Presolve, Results, File formats, Misuse), HANDBOOK, doc comments, test names;
  falsify each with an executable probe or targeted test; order by user cost (wrong optimal > crash on valid input > limits > cosmetic).

## Plan (claims/properties to check, by cost of failure)
1. Presolve/postsolve keeps optimum; postsolved primal/duals/reduced costs/basis belong to original LP; presolve on vs off same answer per engine.
2. Presolve infeasible/unbounded detection reports correct status (no false infeasible/unbounded).
3. Integer bound rounding in presolve is correct (negative bounds, near-integer tolerances).
4. Scaling: unscaled primal/dual belong to unscaled LP; scaling on/off same answer.
5. DSL semantics: constants both sides, ranges, duplicate term merge, max/min sign handling, objective constant, domains/bounds, continuous(...) relaxation.
6. Compile: CompiledLP equals model; maxViolation(at:) correct.
7. MPS free/fixed semantics: RANGES (E row sign rule), bound types MI/PL/BV/LI/UI/FR/FX, negative UP w/o lower bound, RHS on objective row (constant sign), OBJSENSE, MARKER INTORG/INTEND.
8. LP reader: sections, bounds, generals, binaries; LP ranged row -> equality + Rg column as documented.
9. Write-then-read round trip exact on random models (MPS free; LP).
10. Malformed input fuzz (both readers): must throw SolverError.invalidModel, never trap/hang. Seeds recorded.
11. Solution/Status API: value(of:), dual(ofConstraintNamed:), reduced costs, objective sign under maximize, hasSolution semantics.
12. Test integrity of Tests/ZTronLPCoreTests (tolerances, status-only asserts, golden refs).

## Log
Probe sources: verification/probes/cycle-A/Slots/F1/{main,Common,ProbePresolve,ProbeDSL,ProbeIO}.swift; build: swift build --product F1 -c release; run: perl -e 'alarm shift; exec @ARGV' 120 .build/release/F1 <cmd>
HELD | DSL: constants/variables on both sides folded (x+3<=2y+5 -> x-2y<=2; 3+x>=y-1+z -> x-y-z>=-4; x+y+z==7-z -> x+y+2z=7) | F1 dsl | rows exact
HELD | DSL: within(1...4) range row; 2 <= x+z; duplicate terms merged; x+x-2x cancels (count 1) | F1 dsl | exact
HELD | compile: maximize stores negated c, c0; objective(at:) reports model sense incl. constant; integer/binary domains; free var singleton lowered to bound | F1 dsl | exact
HELD | Solution: objective in max sense with constant (46), value(of:), dual(cap)=3, dual(lowered f>=-3)=-3, reducedCost(y)=-1 (max sense), unknown name nil, absent var 0, independent KKT ok | F1 dsl | exact
HELD | continuous(...) drops integrality, binary keeps [0,1]; bounding on binary intersected with [0,1]; MIP has no duals; B&B 2i<=3 -> i=1; 0.1i<=0.7 -> i=7 (rounding tolerance ok) | F1 dsl | exact
HELD | compile errors: duplicate name, NaN coefficient, non-integral fixed integer, infeasible constant constraint -> invalidModel; dropTolerance 1e-14 drops 1e-15 with one warning | F1 dsl | as documented
HELD | SolveStatus.hasSolution true only for optimal/feasible | F1 dsl |
FAIL | maxViolation(at:) flags a NaN point | F1 dsl | (bounds: 0.0, rows: 0.0) for x=[NaN,0.5] on bounds [0,1], row [1,2]
FAIL(semantic) | infeasible singleton constraint (x<=-1 on x>=0) gives a status | F1 dsl | compile/solve throws invalidModel 'variable x has lower bound 0.0 above upper bound -1.0'; lowerSingletonConstraints=false -> .infeasible; x>=1+1e-12 & x<=1 also throws
HELD | MPS RANGES semantics (E +R -> [b,b+R]; E -R -> [b-|R|,b]; L -> [b-|R|,b]; G -> [b,b+|R|]; E R=0) | F1 mps | rl=[5,3,3,5,5] ru=[7,5,5,7,5]
HELD | MPS bound types MI(upper stays inf) PL BV LI UI FR FX; negative UP w/o lower -> lower -inf; LO then neg UP keeps LO; UP 0; UP 1e30 -> inf | F1 mps | exact
HELD | MPS objective RHS 5 = constant -5 for MIN, OBJSENSE MAX/MAXIMIZE (one line and next line), MIN; solves give expected optimum | F1 mps | exact
HELD | MPS MARKER INTORG/INTEND integer columns; integer w/o bounds -> binary (documented convention); with UP keeps it | F1 mps | exact
INFO | MPS 'UI BND x -3' with no lower throws inconsistent bounds (convention applied to UP only) | F1 mps |
FAIL | MPS reader rejects non-finite/out-of-range values (README: malformed -> invalidModel; doc: >=1e20 mapped to inf only on the side where it makes sense) | F1 file mps Slots/F1/inputs/{up-minus-1e400,lo-1e400,rhs-1e400-G,objrhs-nan,rhs-nan}.mps | accepted; Simplex+IPM: UP -1e400 on x with row x=0 -> optimal obj -inf x=-inf; LO 1e400 -> optimal obj +inf; RHS 1e400 on G row -> unbounded; RHS COST nan -> optimal obj NaN; RHS r nan -> optimal
INFO | MPS truncated file (no ENDATA, cut after first COLUMNS line) accepted silently as a smaller model | F1 mps | n=1 m=1
INFO | MPS RANGES section before RHS: RHS header wipes the ranges (row [-inf,5] instead of [3,5]) | F1 mps |
LOW  | presolve '.solved' path: returned Simplex basis is optimal but not the basis of the returned duals (basic column with nonzero reported reduced cost) | F1 presolve 0 60 (seeds 14,28,34,46,59) | e.g. seed 14 basis duals [0,1.25] vs reported [0,0]
HELD | presolve on/off x scaling none/equil/geom x Simplex primal/dual + IPM: same status/objective, independent KKT on original LP (primal feas, d=c-A'y, signs, CS, duality gap), basis reproduces x, rays valid | F1 presolve 0 60 | 53 optimal, 7 unbounded (IPM infOrUnb), 0 KKT/objective failures
FAIL | postsolved basis is an optimal basis of the original LP (Presolve.expandBasis) | F1 basisrepro (min x s.t. -4x>=4, x in [-1,1]); F1 presolve 60 600 | presolve=true basis {x basic, row atLower}: own duals y=-0.25 -> dual infeasible; reported y=0, d_x=1 with x basic; warm start needs 1 pivot (0 without presolve). 24/540 random seeds give a dual-infeasible basis, 45/540 a basis inconsistent with reported duals; KKT of x,y,d always held
HELD | presolve/scaling/engine agreement on 540 more seeds (60..600): no KKT, objective, status or ray failure | F1 presolve 60 600 | optimal 523, unbounded 17 (+IPM infOrUnb 17)
INFO | LP reader: '2 <= x - y' stored as -x + y <= -2 (equivalent; row dual sign flips relative to the written orientation) | F1 lp |
HELD | LP reader: objective constant under Maximize, x<=8 keeps lower 0, -inf<=y<=3, free, w=2, u>=-5, double-sided rows, variables/constants on both sides, x+x merged, Binaries, Generals, solve of Binaries+Generals | F1 lp | exact
HELD | LP writer: range row -> equality with Rg column, optimum preserved | F1 lp |
LOW  | LP round trip drops a column with no cost/no row/default bounds and renumbers columns by first appearance (README 'Not verified' says LP exports round-trip; README §4 mentions only the Rg column) | F1 lp | ["a","b","c"] -> ["b","c"]; ["a","b","c"] -> ["b","a"]
FAIL | LP reader rejects non-finite values (same class as MPS) | F1 file lp Slots/F1/inputs/{lp-lo-1e400,lp-rhs-1e400,lp-fx-1e400,lp-coef-1e400,lp-rowcoef-1e400}.lp | x>=1e400 -> optimal obj inf; r: x>=1e400 -> unbounded; obj 1e400 y -> c=inf accepted, Simplex optimal obj NaN; r: 1e400 x + y >= 1 -> Simplex infeasible (false; y=1 feasible)
HELD | LP reader: x <= -1e400 / x <= -inf in Bounds rejected (inconsistent bounds) | F1 file lp | invalidModel
HELD | presolve infeasible variants (200 seeds): all configs agree infeasible (IPM infOrUnb allowed), every Simplex Farkas ray valid on the original LP | F1 presolve 0 200 infeasible | 0 problems
LOW  | MPS free round trip read(write(lp)) == lp (MPSFormat.swift header; test rangeRowsReadBackBitForBit) | F1 roundtrip 0 400 | 15/400 random models differ, all in range-row bounds, error <= 2.2e-16 relative to the larger end (exactRange search fails, fallback hi-lo)
HELD | MPS round trip with adversarial names (RHS, BOUNDS, ENDATA, 'MARKER', *star, N, 1e3, x[1,2], names with spaces -> '_') keeps every number except range-row ulps | F1 roundtrip 0 400 | no other diffs
HELD | LP write/read keeps status and optimum on 800 random models (incl. adversarial names, ranges, integers, max, c0) | F1 roundtrip 0 400 | 0 failures (unbounded objectives ignored)
HELD | fuzz MPS 28,000 mutated inputs (seeds 1:20000, 2:4000, 3:4000; truncation, token/line mutation, junk bytes, non-finite tokens) and LP 28,000: no trap, no hang (alarm never fired), every rejection is invalidModel or unsupported; accepted valid models solved by Simplex/IPM/B&B (8000 iters) without optimal-with-violation or Simplex/IPM disagreement | F1 fuzz mps|lp <seed> <count> 0 [solve] | only issue: accepted invalid models (non-finite class, already logged)
FAIL | Solution.dual(ofConstraintNamed:) of two named one-variable constraints implying the same bound (x>=2 named a, 2x>=4 named b) | F1 misc | ya=1, yb=0.5 -> ya+2yb = 2 != c_x = 1 (double counted); as rows presolve gives [1,0,0]
HELD | Scaler factors are powers of two; scalePrimal/unscalePrimal/unscaleRowActivity/objective invariant on 100 scaled problems | F1 misc | worst < 1e-12
HELD | integer presolve (rule 6 + all rules) keeps the integer optimum/feasibility, .full and .boundsOnly, 12,000 enumeration checks (tolerance-consistent oracle: bounds within 1e-9 rel of an integer snap, as the package does) | F1 intpresolve 0 6000 | 0 mismatches (exact oracle: 10 mismatches all from bounds like 1.9999999999999998 snapped to 2 by design)
HELD | HANDBOOK decision 9: empty improving column + infeasible rest -> infeasible (valid Farkas), + feasible rest -> unbounded (valid ray), presolve on/off, Simplex+IPM | F1 emptycol | as claimed
HELD | presolve '.solved' path: unbounded (ray [1]) and optimal (max 3x+1, x<=4 -> 13, dual 3) incl. IPM | F1 emptycol |
HELD | LinearExpr ==/hash independent of term order; SparseCSC.fromTriplets sums duplicates, drops zeros; integer column relaxed by LP engine with a warning; compile deterministic (override-only vars sorted by name) | F1 misc2 |
LOW  | LP writer: range row 'a' renamed 'a_' when column 'Rga' exists, colliding with an existing row 'a_' -> two rows labelled a_; reader accepts duplicate row names silently (optimum preserved) | F1 misc2 |
HELD | LPName.uniqued distinct on collisions (incl. empty names); Basis.allLogical statuses as documented | F1 names |
FAIL(low) | model.mpsString() of a constraint named "" reads back | F1 emptyname | writer emits ' G ' / '    x  1.0'; MPSFormat.read: 'line 4: a ROWS line needs a type and a name' (LP export reads back)
HELD | netlib (13 instances): Simplex primal/dual + IPM, presolve on/off: optimal, objective within 1e-6 of reference, duality gap < 1e-6 on the original LP | F1 netlib | 78/78 ok
LOW  | Simplex '.unbounded' result carries objectiveValue (-1.0) although hasSolution is false; SolutionAnalysis doc: 'objectiveValue nil without a primal solution' | F1 unbobj | presolve on/off identical

## Findings (complete; most severe first)

### A1-01 [high] MPS and LP readers accept non-finite / out-of-range numbers; engines then report success statuses with wrong answers
- category: contract-violation; confidence: reproduced
- claim: README §2.2 MPSFormat/LPFormat 'A malformed file throws SolverError.invalidModel'; README risk 12 'malformed inputs ... yield SolverError.invalidModel'; MPSFormat.swift:9-13 'map such values to ±∞ on the side where an infinite bound makes sense ... read as finite numbers they would poison ratio tests'; ModelDiagnostic.nonFiniteValue 'NaN, or infinite on the wrong side' (enforced by compile, not by the readers)
- observed: MPS 'UP BND x -1e400' (or -inf) with row x = 0 -> read OK, xl=xu=-inf; Simplex and IPM: .optimal, objective -inf, x=[-inf]. 'LO BND x 1e400' -> .optimal objective +inf x=[inf]. 'RHS r 1e400' on G row (min x s.t. x >= 1e400) -> .unbounded. 'RHS COST nan' -> .optimal objective NaN. 'RHS r nan' -> .optimal. LP: 'x >= 1e400' in Bounds -> .optimal obj inf; 'r: x >= 1e400' -> .unbounded; 'obj: x + 1e400 y' -> c=inf accepted, Simplex .optimal obj NaN; 'r: 1e400 x + y >= 1' -> Simplex .infeasible (y=1 is feasible). Fuzz: 8+5 MPS, 165+35+39 LP accepted-invalid models in 28k+28k inputs.
- why wrong: these inputs must be rejected (invalidModel) as compile() does; instead the engines answer .optimal at an infeasible/infinite point, .unbounded for a bounded model, .infeasible for a feasible one
- location: Sources/ZTronLPCore/IO/MPSFormat.swift:281-286 (RHS/RANGES value stored unchecked), :327-356 (bound value: only NaN rejected), :403-415 (only xl>xu checked); Sources/ZTronLPCore/IO/LPFormat.swift:335 (Double(...) overflow to inf accepted), :462-463, :465, :655-660
- repro: cd verification/probes/cycle-A && swift build --product F1 -c release && for f in up-minus-1e400 lo-1e400 rhs-1e400-G objrhs-nan rhs-nan; do perl -e 'alarm shift; exec @ARGV' 60 .build/release/F1 file mps Slots/F1/inputs/$f.mps; done; for f in lp-lo-1e400 lp-rhs-1e400 lp-coef-1e400 lp-rowcoef-1e400; do .build/release/F1 file lp Slots/F1/inputs/$f.lp; done; .build/release/F1 mps
- documented: no (risk 12 admits no fuzzing and predicts traps, not silent acceptance; MPSFormat doc claims wrong-side huge values stay finite)
- tests: MPSFormatTests.syntaxErrorsCarryTheirLineNumber / hugeBoundsAndRightHandSidesAreInfinite and LPFormatTests.malformedInputIsRejected never use NaN/inf/overflowing literals

### A1-02 [medium] Presolve.expandBasis returns a non-optimal basis (dual infeasible) that is inconsistent with the returned duals
- category: certificate; confidence: reproduced
- claim: postsolve maps 'a solution, a ray or a basis between the reduced and the original problem' (README §2.2); SimplexAnalysis.basis 'Reusable as WarmStart.basis'; the basis of an .optimal result
- observed: min x s.t. -4x >= 4, x in [-1,1] (Simplex(.dual), presolve on): basis {x basic, row logical atLower}; its own duals y=-0.25 -> logical at lower with d=-0.25 (dual infeasible); reported y=[0], d_x=1 with x basic; warm start from it takes 1 pivot (0 for the presolve-off basis). Random LPs: 24/540 seeds dual-infeasible basis, 45/540 basis inconsistent with duals; all with presolve on, every engine/scaling; x,y,d themselves always pass KKT.
- why wrong: a fixed column whose reduced cost points at its own original bound is made basic because a singleton row tightened the other side; expandDual (sign test) and expandBasis (no sign test) disagree
- location: Sources/ZTronLPCore/Model/Presolve.swift:438-445 (current == .fixed claims the row whichever side d points to) vs :401
- repro: cd verification/probes/cycle-A && .build/release/F1 basisrepro ; .build/release/F1 presolve 60 600 (grep 'dual-infeasible: \["')
- documented: no; tests PresolveTests.aBasisIsMappedBothWays / postsolveInvariantsHoldOnRandomProblems check only structure (m basics, round trip), never optimality or agreement with duals

### A1-03 [medium] CompiledLP.maxViolation(at:) reports zero violation for a point containing NaN
- category: api; confidence: reproduced
- claim: README risk 1 'CompiledLP.maxViolation(at:) checks a point'; doc 'The largest violation of a column bound and of a row bound at x, both >= 0'
- observed: bounds [0,1]^2, row 1 <= x0+x1 <= 2, x=[NaN,0.5] -> (bounds: 0.0, rows: 0.0)
- why wrong: NaN comparisons are false, Swift.max keeps the earlier value, the NaN coordinate and the NaN row activity vanish; the recommended independent check passes a meaningless point
- location: Sources/ZTronLPCore/Model/CompiledLP.swift:187 and :192
- repro: cd verification/probes/cycle-A && .build/release/F1 dsl (line 'maxViolation flags a NaN point')
- documented: no

### A1-04 [medium] An infeasible (or tolerance-level conflicting) one-variable constraint makes compile/solve throw invalidModel instead of returning .infeasible
- category: api; confidence: reproduced
- claim: README §2.1 CompileOptions.lowerSingletonConstraints 'a one-variable constraint becomes a bound; on by default' (a representation choice); SolveStatus.infeasible 'The model has no feasible point'
- observed: minimize x+y s.t. x <= -1 (x >= 0 by domain), x+y >= 0 -> Simplex().solve(model) throws 'invalid model: variable x has lower bound 0.0 above upper bound -1.0'; with lowerSingletonConstraints=false the same model returns .infeasible. x >= 1+1e-12 with x <= 1 also throws (presolve would treat a 1e-12 crossing as a fixed column)
- why wrong: an infeasible LP is not an invalid model; the outcome depends on an option documented as representational, and the diagnostic blames bounds the user never wrote; no tolerance is applied
- location: Sources/ZTronLPCore/Model/Compile.swift:209-227
- repro: cd verification/probes/cycle-A && .build/release/F1 dsl (INFO lines 'infeasible singleton')
- documented: partly: Compile.swift doc lists 'lower > upper on a variable' among the throws, but nothing says an infeasible constraint throws

### A1-05 [low] Solution.dual(ofConstraintNamed:) double counts when two named one-variable constraints imply the same bound
- category: wrong-result; confidence: reproduced
- claim: Analysis.swift:155-160 'the constraint receives the reduced cost when the bound it implies is the active one'; presolve handles the same case ('the last and tightest claims the reduced cost and the others see none left')
- observed: min x+y s.t. a: x >= 2, b: 2x >= 4, c: x+y >= 1 -> ya=1, yb=0.5, yc=0 : ya + 2yb = 2 != c_x = 1; as rows presolve gives [1,0,0]
- location: Sources/ZTronLPCore/Solve/Analysis.swift:173-185
- repro: cd verification/probes/cycle-A && .build/release/F1 misc
- documented: no

### A1-06 [low] MPS free round trip is not bit-exact for range rows
- claim: MPSFormat.swift:3-5 'so read(write(lp)) == lp'; test rangeRowsReadBackBitForBit
- observed: 15/400 random models differ, only in range-row bounds, by <= 2.2e-16 relative to the larger end (e.g. rl -388213.4614957075 -> -388213.4614957074; -5.323138532990446e-11 -> -5.3231197227887606e-11)
- location: Sources/ZTronLPCore/IO/MPSFormat.swift:517-527 (fallback '?? (hi - lo)')
- repro: .build/release/F1 roundtrip 0 400 (MPSDIFF lines)

### A1-07 [low] MPS writer emits an unreadable file for a constraint named ""
- observed: LPModel ... .named("") -> mpsString() writes ' G ' / '    x  1.0'; MPSFormat.read: 'line 4: a ROWS line needs a type and a name'
- location: Sources/ZTronLPCore/IO/MPSFormat.swift:447-452
- repro: .build/release/F1 emptyname

### A1-08 [low] LP export drops columns with no cost, no row and default bounds, and renumbers columns by first appearance; README only mentions the Rg column
- observed: columns [a,b,c] -> [b,c] (a has no cost/row) and -> [b,a]
- location: Sources/ZTronLPCore/IO/LPFormat.swift:32, :66-76
- repro: .build/release/F1 lp
- documented: README 'Not verified' says exports round-trip; README §4 'File formats' mentions only the Rg column; LPFormatTests helper comments acknowledge it

### A1-09 [low] .unbounded Simplex results carry objectiveValue although hasSolution is false
- observed: min -x-y s.t. x-y <= 1 -> .unbounded, hasSolution false, objectiveValue -1.0
- location: Sources/ZTronLPSimplex/Simplex.swift:259 vs Sources/ZTronLPCore/Solve/Analysis.swift:20
- repro: .build/release/F1 unbobj

### A1-10 [low] LP writer can emit duplicate row labels (range row renamed with '_' collides), and the LP reader accepts duplicate row names
- observed: rows [a (range), a_], column Rga -> both rows written as 'a_:'; read back rows [a_, a_] without error (optimum preserved)
- location: Sources/ZTronLPCore/IO/LPFormat.swift:24
- repro: .build/release/F1 misc2
Final JSON: verification/cycle-A/F1-core.json written (10 findings).
