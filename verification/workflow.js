export const meta = {
  name: 'ztronlp-two-cycle-skeptical-verification',
  description: 'Two independent skeptical verification cycles over ZTronLPOptimizer (A claims-first, B oracles-first): 7 area finders per cycle, adversarial skeptics per finding with tiebreak, then cross-cycle reconciliation, contradiction adjudication, completeness critique and a final report; every agent checkpoints to verification/',
  whenToUse: 'Auditing ZTronLPOptimizer end to end for wrong answers, crashes, hangs, false claims and test-suite gaps',
  phases: [
    { title: 'Cycle A: find', detail: 'claims-first finders, one per area' },
    { title: 'Cycle A: verify', detail: 'skeptics try to refute each finding; tiebreak on a split' },
    { title: 'Cycle B: find', detail: 'oracles-first finders, one per area' },
    { title: 'Cycle B: verify', detail: 'skeptics try to refute each finding; tiebreak on a split' },
    { title: 'Reconcile', detail: 'match across cycles, adjudicate contradictions, gaps, final report' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronLPOptimizer'
const VER = ROOT + '/verification'
const SEVERITIES = ['critical', 'high', 'medium', 'low', 'info']
const RANK = { critical: 4, high: 3, medium: 2, low: 1, info: 0 }
const MAX_FINDINGS = 10
const MAX_CONTRADICTIONS = 15
const pad = (n, w) => String(n).padStart(w, '0')

// ---------------------------------------------------------------------------------------------
// Methods of the two cycles

const CYCLES = {
  A: {
    id: 'A',
    name: 'claims first',
    method: `Method of cycle A: claims first. Start from what the package says about itself in your area: README and HANDBOOK statements, the API tables, doc comments on public declarations, comments that state invariants or tolerances, defaults, test names and the assertions behind them. Turn them into a list of concrete, checkable claims. Then try to falsify each one with an executable check (a probe or a targeted test run), not by re-reading the code that implements it. Order the list by what a failure would cost a user: a wrong answer reported as optimal, a crash on valid input or a limit not honoured come first, cosmetic wording last. Audit the tests in your area as claims too. For each important property, would some test fail if it were false? Look for tolerances loose enough to pass a wrong answer, assertions on status only, silent skips, reference values that are themselves wrong, and test names that promise more than the assertions check.`,
  },
  B: {
    id: 'B',
    name: 'oracles first',
    method: `Method of cycle B: oracles first. Do not start from the package's self-assessment. Derive the contract from first principles, meaning what any correct implementation must satisfy: primal and dual feasibility and complementary slackness at an LP optimum; Farkas or ray certificates for infeasible and unbounded models; exhaustive enumeration for small integer programs; clause satisfaction for SAT; identity for write-then-read; invariance under row and column permutation, scaling, added redundant rows and min/max reformulation; monotonicity under tighter limits. Build independent oracles for these in your slot. Attack the public API with adversarial and edge-case inputs: degenerate vertices; free, negative, fixed and infinite bounds; ranged and equality rows; empty models; redundant or duplicate rows; huge and tiny coefficients; maximize vs minimize; ill-conditioned data; many optima. Add randomized differential testing between engines and configurations, with fixed and recorded seeds. When something disagrees, read the code path behind it to locate the cause. Only once you have results, read README §4 and HANDBOOK "Known gaps" to mark the findings that are already documented.`,
  },
}

// ---------------------------------------------------------------------------------------------
// Areas: same seven for both cycles. Slot F<k> belongs to the finder of area k.

const AREAS = [
  {
    k: 1, slug: 'core', title: 'Core: modelling DSL, compile, presolve, scaling, MPS/LP I/O, result types',
    scope: `Sources/ZTronLPCore/DSL/{LinearExpr,Variables,Constraints,LPModel}.swift, Sources/ZTronLPCore/Model/{Compile,CompiledLP,SparseCSC,Presolve,Scaling}.swift, Sources/ZTronLPCore/IO/{MPSFormat,LPFormat}.swift, Sources/ZTronLPCore/Solve/{Status,Analysis,Strategy}.swift; tests Tests/ZTronLPCoreTests/** (with Golden/); README §2.1-2.4 and the Presolve, Results, File formats and Misuse limits in §4.`,
    focus: [
      'DSL semantics: sums and constants on both sides of a relation, range constraints, named constraints, duplicate terms merged, minimize/maximize sign handling, variable domains (continuous, integer, binary) and bounds, the relaxation helpers (continuous(...)), the objective constant.',
      'Compile: the CompiledLP equals the model (coefficients, column and row bounds, sense, constant); maxViolation(at:) is right.',
      'Presolve and postsolve: every rule (fixed columns, singleton rows, empty rows and columns, integer bound rounding) keeps the optimum; postsolved primal values, duals, reduced costs and basis are those of the original LP; infeasibility or unboundedness detected in presolve is reported correctly; presolve on vs off gives the same answer with each engine.',
      'Scaling: unscaled primal and dual values belong to the unscaled LP; scaling on vs off gives the same answer.',
      'MPS (free and fixed) and LP formats: ROWS/COLUMNS/RHS/RANGES/BOUNDS semantics (RANGES on E rows by the sign of R; MI, PL, BV, LI, UI, FR, FX bound types; a negative UP bound with no lower bound; an RHS entry on the objective row, meaning the objective constant and its sign; OBJSENSE sections; MARKER INTORG/INTEND); the LP reader\'s sections, bounds, generals and binaries. A write-then-read round trip is exact on random models (free format), and a ranged row in LP format becomes an equality with an Rg column, as documented.',
      'Malformed input: README says malformed inputs yield SolverError.invalidModel. Fuzz both readers (truncation, token mutation, huge or non-finite numbers, duplicate names, missing sections, wrong field counts) with recorded seeds, and report any trap, crash or hang with a minimal input (risk 12 admits there was no fuzzing).',
      'Solution and Status API: value(of:), dual(ofConstraintNamed:), reduced costs, the objective sign under maximize, hasSolution, and what each status promises.',
    ],
  },
  {
    k: 2, slug: 'simplex', title: 'Simplex engine and the numerics under it',
    scope: `Sources/ZTronLPSimplex/{Simplex,SimplexEngine,SimplexEngine+Primal,SimplexEngine+Dual,SimplexEngine+Driver,SimplexEngine+Crossover}.swift, Sources/ZTronLPNumerics/{Dense,Sparse,Kernels,CandidateKernels,BasisFactorization}.swift, Sources/CLAPACKShim/**; tests Tests/ZTronLPSimplexTests/**, Tests/ZTronLPNumericsTests/** (except Concurrency and WorkGate), Tests/ZTronLPIntegrationTests/{CorpusTests,IllConditionedTests}.swift; netlib fixtures in Sources/ZTronLPTestSupport/Fixtures/netlib/; README §2.5 (Simplex), §2.7, §3 risks 1-2, §4 defects 8-9 and the Linear algebra and Results limits, §5 netlib, larger-LP and ill-conditioned tables; HANDBOOK decisions 16-18 (refinement pass, second look below the pivot tolerance).`,
    focus: [
      'Optimality certificates on random and constructed LPs. Pick x* and y*, then build c and b so that KKT holds; include degenerate vertices and non-unique optima; free, negative, fixed and boxed columns; ranged and equality rows. Every Simplex configuration (primal and dual, each Factorization option, presolve and scaling on and off, warm and cold) must return optimal at the right objective. Check primal feasibility, dual feasibility and complementary slackness of the returned primal values, duals and reduced costs, plus the documented sign conventions (y >= 0 at a row\'s lower bound, <= 0 at its upper bound; maximize handled consistently).',
      'Infeasible and unbounded LPs: the right status; the returned ray or Farkas certificate really certifies (check it independently); no .optimal on an infeasible model.',
      'Netlib: compare the reference objectives in ReferenceValues.swift with the published netlib optima you know independently; each Simplex configuration reaches them within the stated tolerance.',
      'Ill-conditioned (Hilbert-based) LPs. README claims that up to order 8 every LP strategy recovers the solution to about 1e-6, that beyond a condition number of about 1e10-1e11 only the objective is recovered, and that an ill-conditioned optimal basis gets a warning. Verify these, and that no configuration reports optimal at a wrong objective.',
      'Limits and warm starts: iteration and time limits give the documented status with a usable iterate; a warm start from an optimal basis takes (nearly) no iterations; degenerate problems (Klee-Minty-like, highly degenerate assignment LPs) do not cycle or stall.',
      'Numerical building blocks against naive references: dense and sparse products, triangular solves, LU, BasisFactorization solves and product-form updates, refactorization triggers, the residual check, and singular-basis repair (NumericalError.singular).',
    ],
  },
  {
    k: 3, slug: 'ipm', title: 'Interior point, crossover-lite, conditioning analyzer and the Conditioned facade',
    scope: `Sources/ZTronLPInteriorPoint/{InteriorPoint,IPMWorker}.swift, Sources/ZTronLPSimplex/SimplexEngine+Crossover.swift, Sources/ZTronLPConditioning/{ConditioningAnalyzer,ConditioningReport,ConditionedAnalysis}.swift, Sources/ZTronLPOptimizer/Conditioned.swift; tests Tests/ZTronLPInteriorPointTests/**, Tests/ZTronLPConditioningTests/**, the ill-conditioned and corpus tests in Tests/ZTronLPIntegrationTests/; README §2.5 (InteriorPoint), §2.6, §4 defects 7, 9, 10 and the Interior point limit (no dense-column handling, crossover-lite), §5 tables.`,
    focus: [
      'Optimality on random and constructed LPs with known optima (KKT check of the returned point, duals and reduced costs), with crossover on and .none and presolve on and off. The objective must agree with the simplex, and with crossover on, the basis it ends with must be optimal.',
      'Infeasible and unbounded models: the statuses. README defect 7 allows .infeasibleOrUnbounded "for some models". Find out how often that happens, and whether any infeasible model is ever called optimal or unbounded (or the reverse).',
      'Defect 10 and the ill-conditioned family: .numericalFailure from a condition number of about 1e6 with crossover .none; the default (with crossover) recovers. Verify the thresholds, and that a stall is handed to the simplex as stated.',
      'Dense columns: a column with more than 30 % nonzeros makes the normal equations dense, and a warning says so. Verify the warning and the answer.',
      'Conditioning analyzer and Conditioned facade: check condition estimates against a dense reference (e.g. an SVD of small matrices computed independently in the probe), the scaling and conditioning warnings, the memoryBudgetBytes cap on its factorization, and that Conditioned returns the same answer as the engine it wraps.',
      'Netlib with the interior point: objectives against the published optima. Compare iteration counts and times with README §5 only for gross mismatches.',
    ],
  },
  {
    k: 4, slug: 'bnb', title: 'Branch and bound',
    scope: `Sources/ZTronLPBranchAndBound/{BranchAndBound,NodeLPStrategy,SearchTree,TreeSearch}.swift; tests Tests/ZTronLPBranchAndBoundTests/**, the MIPLIB parts of Tests/ZTronLPIntegrationTests/**, Tests/ZTronLPLivenessTests/L4SearchTreeTests.swift; corpora ${ROOT}/.corpora/miplib3/ (10 instances); Sources/ZTronLPTestSupport/{ReferenceValues,Generators}.swift; README §2.5 (BranchAndBound), §3 risks 3, 8, 10, 15, §4 defect 4 and the Branch and bound limits, §5 MIP table.`,
    focus: [
      'MILP optimality against exhaustive enumeration on many small random instances: binary; general integer with negative and asymmetric bounds; mixed integer (enumerate the integer part and solve each continuous LP with an independent method); equality-constrained; infeasible; with an unbounded relaxation. Run BranchAndBound with both node strategies, deterministic and parallel, presolve on and off. Check status, objective, the incumbent\'s feasibility and integrality, and that `bound` is a valid bound.',
      'Gap semantics. README says .optimal means incumbent - bound <= max(1e-6, 1e-4*max(1, |incumbent|)) and that a custom Gap tightens it. Construct instances where the default gap accepts a suboptimal incumbent, and check that a tight Gap finds the true optimum.',
      'Limits: nodeLimit and timeLimit give .feasible(reason) with a feasible incumbent and a valid bound, or .noSolution, never a false .optimal or .infeasible. memoryBudgetBytes bounds the open nodes as documented.',
      'Determinism: deterministic: true gives identical results run to run (README risk 8, rule C9); parallel runs agree on the objective.',
      'MIPLIB 3: compare the reference optima in ReferenceValues.swift with the published values you know independently; solve each instance to them with both node strategies (release build, generous time limits).',
      'Search-tree invariants: node bounds are monotone; pruning never discards a node that could hold a better solution (compare against enumeration); incumbent updates are correct under concurrency.',
    ],
  },
  {
    k: 5, slug: 'cpsat', title: 'CP-SAT',
    scope: `Sources/ZTronLPCPSAT/{CPModel,CPSAT,CPSearch,CPWorker,LPRelaxation,CPAnalysis,Portfolio}.swift; tests Tests/ZTronLPCPSATTests/**; corpora ${ROOT}/.corpora/satlib/ (uf50-218 satisfiable, uuf50-218 unsatisfiable) and the pure-integer MIPLIB 3 instances in ${ROOT}/.corpora/miplib3/; Sources/ZTronLPTestSupport/{DIMACS,ReferenceValues,Generators}.swift; README §2.5 (CPSAT), §3 risks 3, 8, 10, §4 defect 1 and the CP-SAT limits, §5 CP-SAT table.`,
    focus: [
      'SAT and UNSAT: every uf50 instance is SAT, with a model you check against every clause; every uuf50 instance is UNSAT (cross-check a sample, and random small formulas, by brute force or an independent DPLL in the probe); no wrong SAT/UNSAT claim on random 3-SAT near the threshold.',
      'Optimization against exhaustive enumeration on small pure-integer models (binary and general integer, negative bounds, equality rows, infeasible ones), with lpPropagator on and off, deterministic and parallel.',
      'The documented input domain. Data that becomes integral after multiplying by a power of 10 up to 1e6 must be accepted and solved exactly. Beyond that, and for continuous columns or infinite bounds, the model must be rejected with the documented error: not trapped, not silently rounded. Bounds and scaled coefficients near 2^53 and row activities near +-2^61 must be handled or rejected as documented. Look for overflow.',
      'The fixed gap: README says the CP-SAT proof is exact for integral costs only while the objective stays below 10^4. Check what happens above that (a non-optimal answer labelled .optimal?).',
      'Limits, determinism and the Portfolio inside CP-SAT: time limits, reproducibility with deterministic: true, agreement between the portfolio\'s workers, and whether the reported result is the best one.',
      'MIPLIB 3 pure-integer instances: the optima in README §5 with the default configuration (release build).',
    ],
  },
  {
    k: 6, slug: 'runtime', title: 'Runtime: cancellation, limits, events, concurrency, memory budget, Metal tier, Automatic and Portfolio facades',
    scope: `Sources/ZTronLPNumerics/{Concurrency,WorkGate}.swift, Sources/ZTronLPCore/Solve/Strategy.swift (SolveContext, events, limits), Sources/ZTronLPMetal/** (MetalContext, MetalAccelerator, KernelSupport, BatchedActivityKernel, ReducedCostScanKernel, Shaders/Kernels.metal), Sources/ZTronLPOptimizer/{Automatic,Portfolio,Exports}.swift, Sources/ZTronLPTestSupport/LivenessHarness.swift; tests Tests/ZTronLPLivenessTests/**, Tests/ZTronLPMetalTests/**, Tests/ZTronLPOptimizerTests/**, Tests/ZTronLPNumericsTests/{ConcurrencyTests,WorkGateTests}.swift; README §2.8, §2.9, §3 risks 4, 7, 14, 15, §4 defects 2-4, §5 Metal, cancellation latency and memory sections; the Thread Sanitizer baseline log ${VER}/baseline/05-tsan.log (check ${VER}/baseline/progress.txt; the step may still be running; do not start your own TSAN run unless the baseline step failed to run).`,
    focus: [
      'Cancellation: cancelling the solve\'s Task returns promptly (README cancellation latency) for every strategy (Simplex, InteriorPoint, BranchAndBound, CPSAT, Automatic, Portfolio, Conditioned) with the documented status: no hang, no crash, and no work left running afterwards (CPU use returns to idle).',
      'Time limits and budgets: timeLimit is honoured by every strategy within a sane margin and reported as a status, not a thrown error; memoryBudgetBytes and the .memoryBudget status work where README claims them.',
      'Events: makeEventStream keeps the newest 256 events, always delivers .finished and keeps order; several consumers work; there is no deadlock or leak when nobody consumes.',
      'Concurrency: SolveContext.threads is honoured. Look for ordering bugs in the parallel search that TSAN cannot see (shared tree, incumbent and bound updates). Check that the lint claims hold in the source: exactly one @unchecked Sendable, no nonisolated(unsafe), no global mutable state, no blocking waits. Review the TSAN baseline log.',
      'Facades: Automatic routes as documented (which engine for which model and size, e.g. the interior point above 4,000 rows; when Metal is attached). Portfolio\'s race semantics hold: the first acceptable answer wins, the others are cancelled, the reported strategy matches, and the result is never worse than its members\'.',
      'Metal tier: the kernels give the same results as the CPU path (correctness, not speed) at and above their thresholds; MetalPolicy.off and the .automatic thresholds are as documented (3,000,000 columns and 6,000,000 nonzeros for pricing; batches of 64 points on 100,000 nonzeros for the feasibility screen); check the behaviour when the shader library cannot be compiled.',
    ],
  },
  {
    k: 7, slug: 'integrity', title: 'Package integrity: gates, documentation claims, measured numbers, test-suite integrity, layering',
    scope: `Package.swift, Scripts/{lint,fetch-miplib,fetch-satlib}.sh, .github/workflows/ci.yml, README.md (all of it, especially the §1 example, the §2 API tables and the §5 numbers), HANDBOOK.md (decisions, known gaps, not verified, benchmarks), SPECIFICATION-v0.2.md §1-§2 (its statements about the package as it stands), Sources/ZTronLPTestSupport/** (Fixtures, Generators, DIMACS, LivenessHarness), Sources/ZTronLPBenchmarks/main.swift (workloads: netlib, transport, mip, cpsat, metal, latency; build it in the repository with \`swift build -c release --product ZTronLPBenchmarks\` and run \`.build/release/ZTronLPBenchmarks <workloads>\` directly), Tests/** as a whole, demo/ (read only); the baseline logs in ${VER}/baseline/.`,
    focus: [
      'Gates: from the baseline logs, did the build with -warnings-as-errors, lint, the debug suite, the release integration and liveness suite and TSAN pass? Count executed, skipped and failed tests per target and compare with what README "Building and testing" and HANDBOOK "Testing" say. Find the tests that skip (XCTSkip, early returns, #if, environment or corpus gates) and say what each one hides, in local runs and in CI.',
      'Lint: does Scripts/lint.sh enforce what it claims (C2, C3, C6)? A pattern that can never match, or a rule checked in only part of the tree, is a finding.',
      'Layering: compare the actual import graph of Sources/* with Package.swift and with the layering claims in README, HANDBOOK and the spec.',
      'The README §1 example, run verbatim in your slot: do the printed numbers match the comments? Does ReadmeExampleTests check those numbers?',
      'README §2 API tables: every listed declaration exists with the stated shape and meaning; note any notable public declarations missing from the tables.',
      'Measured numbers (README §5, HANDBOOK Benchmarks, spec v0.2 §1 table): spot-check the deterministic ones, i.e. node counts with deterministic: true, iteration counts, objectives, and the number of instances closed. Machine load inflates timings, so count only gross mismatches (more than 3x).',
      'Test-suite integrity across Tests/**: tolerances that would accept wrong answers, assertions on status only, generators whose "known optimum" is not optimal (check a few independently), test names that promise more than the assertions check, and flaky timing assumptions.',
    ],
  },
]

// Scheduling order: the areas where a wrong answer is most likely first; the two areas that read
// the TSAN log last. Cycles interleaved so both progress evenly if the run is cut short.
const ORDER = [2, 4, 5, 1, 3, 6, 7]

// ---------------------------------------------------------------------------------------------
// Shared prompt text

const SEVERITY_TEXT = `Severity scale
- critical: a wrong answer reported with a success status (.optimal or .feasible with a wrong value or an infeasible point; a false .infeasible or .unbounded), memory unsafety, or a data race.
- high: a crash, trap or hang on valid input; a limit or cancellation not honoured; a published claim that is materially false.
- medium: a wrong status or an invalid certificate on edge cases; misleading API behaviour; a test that cannot catch the bug it is named for; a malformed file that traps instead of throwing.
- low: a minor documentation or number mismatch; a small inconsistency.
- info: an observation worth recording. It is not verified further.`

const FINDING_RULES = `What counts as a finding
A finding is a discrepancy you reproduced between behaviour and one of: (a) the mathematical contract; (b) a claim the package makes about itself (README, HANDBOOK, a doc comment, a comment stating an invariant, or SPECIFICATION-v0.2 about the current package); (c) an internal invariant. Test-suite integrity problems also count (a test that cannot fail for the bug it targets, a wrong reference value, a silent skip), and so do gate failures. A defect that README §4 or HANDBOOK "Known gaps" already describes accurately is not a finding. One they describe wrongly is: worse than stated, a different trigger, or claimed fixed when it is not.

Discipline
- Be sceptical of yourself too: the commonest false finding comes from a wrong oracle. Before you report, derive the expected value another way, re-run, and minimise the reproduction.
- Every finding gives: an exact repro command (probe slot and arguments, or a swift test filter), the observed output, why it is wrong, the likely culprit as file:line, and whether and where it is documented.
- Report at most ${MAX_FINDINGS} findings, most severe first. Put anything beyond that in overflow, one line each.
- Record the claims you checked that held, with how you checked them; coverage is as much the product as the failures are. Also record what you meant to check but could not.`

function preamble(c, slot) {
  return `You are an agent in skeptical verification cycle ${c.id} (${c.name}) of the Swift package ZTronLPOptimizer at ${ROOT}: git main @ d9afebe, Swift 6.4, Apple M3 with 8 cores, macOS 27. The package solves linear and mixed-integer programs. It has a modelling DSL, presolve and scaling, MPS/LP readers and writers, primal and dual simplex, an interior point with crossover-lite, branch and bound, a CP-SAT solver for pure integer models, a conditioning analyzer, an optional Metal tier, and facades (Automatic, Portfolio, Conditioned). Three documents make claims about it. README.md is the outside view: API tables in §2, risks in §3, known defects and limits in §4, measured numbers in §5. HANDBOOK.md records decisions, known gaps and what was not verified. SPECIFICATION-v0.2.md is mostly a plan for work NOT yet implemented (sparse LU, cutting planes, a larger presolve); only its statements about the package as it stands are claims to check.

Ground rules
- Independence. Another cycle is auditing the same package at the same time, independently. Under ${VER}/, read only baseline/, cycle-${c.id}/ and probes/cycle-${c.id}/. Never open the other cycle's directories or probes, nor REPORT.md, RECONCILE.md, GAPS.md or adjudications/.
- The repository is read-only for you. Create or change files only inside ${VER}/cycle-${c.id}/ and your own probe slot. Run no state-changing git commands. Never delete or clean any .build directory.
- Existing tests. You may run targeted existing tests in the repository: \`cd ${ROOT} && swift test --filter '<Target>.<Class>/<test>'\` (or with -c release). SwiftPM serializes concurrent invocations on one build directory with a lock, so "Another instance of SwiftPM is already running..." just means wait. Do not run the whole suite. A clean run of every gate, made before any agent started, is in ${VER}/baseline/. Its progress.txt has the exit code and time of each step: build with -warnings-as-errors, lint, debug suite, release integration and liveness suite, Thread Sanitizer (the TSAN step may still be running).
- Probes. Your probe workspace is the SwiftPM package ${VER}/probes/cycle-${c.id}/. It depends on the package by path. \`import ZTronLPOptimizer\` re-exports the public API of every layer, and \`import ZTronLPTestSupport\` gives fixtures, generators, reference values and DIMACS parsing. It uses the Swift 5 language mode, and top-level await works in main.swift. You own exactly one executable slot: ${slot}. Put your code in ${VER}/probes/cycle-${c.id}/Slots/${slot}/ (main.swift plus any other .swift files) and build only that product: \`cd ${VER}/probes/cycle-${c.id} && swift build --product ${slot}\` (add \`-c release\` for heavy or timed probes). Run the binary directly: \`.build/debug/${slot} [args]\` or \`.build/release/${slot}\`. Never build without --product, and never edit another slot or the workspace's Package.swift. Debug and release builds of the package are already warm, so a build compiles only your slot. Probes cannot reach internal (non-public) API; for that, read the code or use the package's own tests.
- Bound every run: set SolveContext.timeLimit in probes, and run binaries under \`perl -e 'alarm shift; exec @ARGV' <seconds> <binary> [args]\` so that a hang is killed. Exit status 142 means the alarm fired, which is itself evidence of a hang.
- Shared machine. Up to five other agents build and solve at the same time, so wall-clock numbers are inflated, sometimes several times over. Report a timing or latency claim as false only when the gap is too large for load to explain, and only after repeating it. For the package's liveness tests, ZTRONLP_LATENCY_SCALE relaxes the latency bounds (see ${ROOT}/.github/workflows/ci.yml and Tests/ZTronLPLivenessTests).
- Economy. Read what you need, not whole subsystems: grep and targeted reads first. Prefer one decisive executable check to long reasoning.`
}

function crossPreamble(slot) {
  return `You work in the cross-cycle stage of a skeptical verification of the Swift package ZTronLPOptimizer at ${ROOT} (main @ d9afebe). Two independent cycles have finished. Cycle A worked claims first: it tried to falsify what the docs, comments and tests claim. Cycle B worked oracles first: it built independent oracles and fed adversarial inputs to the public API. Each cycle had seven area finders (core, simplex, ipm, bnb, cpsat, runtime, integrity), and each finding was checked by sceptics with a tiebreak. Their files are under ${VER}/cycle-A/ and ${VER}/cycle-B/: finder logs F<k>-<area>.md, results F<k>-<area>.json, verdicts in verdicts/<id>-<lens>.md. Clean gate logs are in ${VER}/baseline/. You may read everything under ${VER}/. The repository is read-only.${slot ? ` If you need to run something, you own probe slot ${slot} of the workspace ${VER}/probes/cycle-A/. Build it with \`cd ${VER}/probes/cycle-A && swift build --product ${slot}\` and run \`.build/debug/${slot}\`. Never build without --product, and bound runs with \`perl -e 'alarm shift; exec @ARGV' <seconds> <binary>\`.` : ''}`
}

const LENSES = {
  reproduce: {
    key: 'reproduce',
    text: `Lens: REPRODUCE. Reproduce the finding yourself, from scratch, in your own slot, with a minimal independent probe written from the description. You may read the finder's probe to see what was done, but do not reuse its oracle. Compute the expected result a different way: by hand, by enumeration, with a second engine or configuration, or by checking certificates or KKT conditions directly. Establish three things: (1) the observed behaviour happens; (2) the expected behaviour the finder states is actually correct; (3) the effect does not depend on machine load or on randomness you did not control. A wrong oracle, a misuse of the API, or an effect you cannot reproduce refutes the finding.`,
  },
  contract: {
    key: 'contract',
    text: `Lens: CONTRACT. Decide whether this is really a defect. Establish what the package promises here, from: the README (§2 API tables, §3 risks, §4 defects and limits by design); HANDBOOK (decisions, known gaps, not verified); the doc comments of the declarations involved; SPECIFICATION-v0.2 statements about the current package; the mathematical contract. Is the behaviour by design, inside documented tolerances or status semantics, a misuse of the API, or already accurately documented (then documented=true)? Read the implicated code and check that the causal story holds, and run what you need to settle it. Rate severity on the scale above, independently of the finder's rating.`,
  },
  combined: {
    key: 'combined',
    text: `Lens: REPRODUCE AND CONTRACT. First reproduce the finding yourself in your own slot, with an independent oracle: compute the expected result a different way from the finder. Then decide whether it is really a defect against what the package promises (README §2-§4, HANDBOOK, doc comments, the mathematical contract), and whether it is already accurately documented (documented=true). Rate severity on the scale above, independently of the finder's rating.`,
  },
}

// ---------------------------------------------------------------------------------------------
// Prompts

function finderPrompt(c, a) {
  const base = `${VER}/cycle-${c.id}/F${a.k}-${a.slug}`
  return `${preamble(c, 'F' + a.k)}

Your role: finder for area F${a.k}, ${a.title}.

Scope (start here, and follow a lead wherever it goes):
${a.scope}

At least examine:
${a.focus.map((x, i) => `${i + 1}. ${x}`).join('\n')}

${c.method}

${FINDING_RULES}

${SEVERITY_TEXT}

Checkpoints (mandatory: the user's quota may run out mid-run, and these files are the only thing that survives)
- At the start, create ${base}.md with a header (cycle, area, slot, method) and your plan: the list of claims or properties you intend to check.
- After every check you finish, append one line: "HELD | <claim> | <command> | <key output>" or "FAIL | ...". After every finding, append the complete finding with all its fields. Keep the file current, so a successor can resume from it.
- Probe sources stay in your slot; name the file and the arguments in the log.
- Just before returning, write the final structured result as JSON to ${base}.json, then return the same object.

Return the structured result. Number the findings ${c.id}${a.k}-01, ${c.id}${a.k}-02, ... in order of severity. Aim to finish within about an hour of work. Depth on the claims that matter beats breadth on cosmetic ones.`
}

function verifierPrompt(c, a, f, lens, slot) {
  return `${preamble(c, slot)}

Your role: independent sceptic for finding ${f.id} of cycle ${c.id} (area F${a.k}, ${a.title}). Your task is to try to REFUTE it. Return 'confirmed' only when your own execution, or a precise reading of the code, demonstrates the defect. Return 'refuted' when the evidence does not hold up: wrong oracle, misuse, by design, within a documented tolerance, or not reproducible. Return 'uncertain' when you cannot decide. Other sceptics may examine the same finding through a different lens, so do not read the other files in ${VER}/cycle-${c.id}/verdicts/.

The finding, as the finder reported it (every statement in it is unverified):
${JSON.stringify(f, null, 2)}

The finder's probe code is in ${VER}/probes/cycle-${c.id}/Slots/F${a.k}/, and its running log is ${VER}/cycle-${c.id}/F${a.k}-${a.slug}.md. You may read both.

${lens.text}

${SEVERITY_TEXT}

Checkpoint: before returning, write your verdict to ${VER}/cycle-${c.id}/verdicts/${f.id}-${lens.key}.md: verdict, documented, severity, reasoning, and the commands you ran with their key output.`
}

function tiebreakPrompt(c, a, f, votes, slot) {
  return `${preamble(c, slot)}

Your role: adjudicator for finding ${f.id} of cycle ${c.id} (area F${a.k}, ${a.title}). The sceptics who examined it disagreed, could not decide, or one of them failed to report. Examine the disputed points yourself, re-run what is needed in your slot, and rule: 'confirmed' (defect demonstrated), 'plausible' (credible and partly supported, but not demonstrated) or 'refuted'. Rule 'refuted' when the evidence is thin.

The finding (unverified):
${JSON.stringify(f, null, 2)}

The sceptics' verdicts:
${JSON.stringify(votes, null, 2)}

The finder's probe is in ${VER}/probes/cycle-${c.id}/Slots/F${a.k}/ and its log is ${VER}/cycle-${c.id}/F${a.k}-${a.slug}.md; the verdict files are ${VER}/cycle-${c.id}/verdicts/${f.id}-*.md.

${SEVERITY_TEXT}

Checkpoint: before returning, write your ruling with its evidence to ${VER}/cycle-${c.id}/verdicts/${f.id}-tiebreak.md.`
}

function reconcilePrompt(findings, coverage) {
  return `${crossPreamble(null)}

Your role: reconcile the two cycles.
1. Group the findings that describe the same underlying defect (same root cause or same observable failure), across and within cycles. Every finding id below must appear in exactly one group. For each group give: foundBy (A, B or both); the strongest status among its members (CONFIRMED > KNOWN > PLAUSIBLE > UNVERIFIED-INFO/UNVERIFIED > REFUTED; keep REFUTED-only groups too); and the group's severity (the highest severity among the members whose status is not REFUTED, otherwise the highest).
2. Find contradictions: a CONFIRMED or PLAUSIBLE finding of one cycle against a check the other cycle recorded as held (see coverage below), or a finding REFUTED in one cycle that the other cycle confirmed. Give each one with the finding id and the exact conflicting check. List at most ${MAX_CONTRADICTIONS}, most consequential first.
3. Summarise agreement: how many defects both cycles found, how many only one found, and what that says about confidence.
Write the result as markdown to ${VER}/RECONCILE.md before returning it.

Findings with their verification status (the id prefix is the cycle and the area number):
${JSON.stringify(findings, null, 1)}

Coverage per cycle and area (checks that held, checks not done, the finder's summary):
${JSON.stringify(coverage, null, 1)}`
}

function adjudicatePrompt(x, j) {
  const slot = 'V' + pad(221 + j, 3)
  return `${crossPreamble(slot)}

Your role: settle a contradiction between the cycles by running the decisive check yourself.
${JSON.stringify(x, null, 2)}
Read the finding (its finder log and verdicts) and the other cycle's check (its finder log). Work out why they disagree: different inputs, configuration or tolerance, an oracle error on one side, or a misread claim. Then run the decisive experiment and rule: finding-stands, finding-refuted, both-partly-right, or undetermined. Prefer undetermined to a guess.
Checkpoint: before returning, write your ruling with its evidence to ${VER}/adjudications/${x.id}.md.`
}

function gapsPrompt(findings, coverage) {
  return `${crossPreamble(null)}

Your role: completeness critic. From the coverage below and the package itself (README §2 API tables, §3 risks, §4 claims; HANDBOOK; the Sources/ tree), list what neither cycle examined that could still hide a wrong answer, crash, hang or false claim: an untested strategy or option, a claim nobody executed, a code path no probe reached, a module no finder read. Rank by priority (high means it could hide a critical or high defect). Be concrete: name the declaration, file or claim, and the check that would settle it. List at most 20 gaps. Write them as markdown to ${VER}/GAPS.md before returning.

Findings (only the titles and areas matter here):
${JSON.stringify(findings.map(f => ({ id: f.id, status: f.status, title: f.title })), null, 1)}

Coverage:
${JSON.stringify(coverage, null, 1)}`
}

function reportPrompt(findings, rec, adjs, gaps, uncovered, overflow) {
  return `${crossPreamble(null)}

Your role: write the final report of both cycles to ${VER}/REPORT.md, for the package's author. Then update the Status checklist at the end of ${VER}/CHECKPOINT.md: tick the boxes that are done and leave the "Spot checks" box for the main session. Edit only that section.

Structure of REPORT.md:
1. The verdict, in a few sentences: is the package's main promise (correct answers with honest statuses, documented limits) supported? What is the most serious confirmed problem?
2. Gates, from ${VER}/baseline/progress.txt and the logs: exit codes, test counts, failures.
3. Confirmed defects, most severe first, one subsection each: id(s), severity, found by A, B or both, what is wrong, a minimal repro (exact commands), the culprit file:line, whether it is documented, and the adjudication outcome if any. Then KNOWN (accurately documented) and PLAUSIBLE ones, briefly. Then the REFUTED ones as a table (id, title, why refuted), since they show what was checked.
4. Agreement between the cycles and what it implies.
5. The claims that held: a compact table per area, from the cycle JSON files.
6. Gaps neither cycle covered (from the critic), areas whose finder failed, and findings over the per-finder cap that were never verified.
Use plain, exact language: numbers with units, no speculation presented as fact. Return a summary of at most 25 lines: counts by status and severity, the top confirmed defects (id, severity, one line each), and the path of the report.

Findings with statuses:
${JSON.stringify(findings, null, 1)}

Reconciliation:
${JSON.stringify(rec, null, 1)}

Adjudications:
${JSON.stringify(adjs, null, 1)}

Gaps:
${JSON.stringify(gaps, null, 1)}

Areas not covered (the finder failed): ${JSON.stringify(uncovered)}
Findings over the cap, not verified: ${JSON.stringify(overflow)}`
}

// ---------------------------------------------------------------------------------------------
// Schemas

const FINDING = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    title: { type: 'string' },
    severity: { type: 'string', enum: SEVERITIES },
    category: { type: 'string', enum: ['wrong-result', 'crash', 'hang', 'limit-not-honoured', 'certificate', 'contract-violation', 'doc-claim-false', 'test-integrity', 'gate-failure', 'performance-claim', 'concurrency', 'api', 'other'] },
    claim: { type: 'string', description: 'What the contract, docs or code promise, with the source (doc section or file:line)' },
    observed: { type: 'string' },
    whyWrong: { type: 'string' },
    location: { type: 'string', description: 'Likely culprit as file:line' },
    repro: { type: 'string', description: 'Exact commands that reproduce it' },
    evidence: { type: 'string', description: 'Key output' },
    documented: { type: 'string', description: 'Empty, or where it is documented and how the docs misstate it' },
    confidence: { type: 'string', enum: ['reproduced', 'code-reading-only'] },
  },
  required: ['id', 'title', 'severity', 'category', 'claim', 'observed', 'whyWrong', 'location', 'repro', 'evidence', 'confidence'],
}

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    area: { type: 'string' },
    findings: { type: 'array', items: FINDING },
    overflow: { type: 'array', items: { type: 'string' } },
    claimsHeld: {
      type: 'array',
      items: { type: 'object', properties: { claim: { type: 'string' }, howChecked: { type: 'string' } }, required: ['claim', 'howChecked'] },
    },
    notChecked: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['area', 'findings', 'claimsHeld', 'notChecked', 'summary'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'uncertain'] },
    documented: { type: 'boolean' },
    severity: { type: 'string', enum: SEVERITIES },
    reasoning: { type: 'string' },
    evidence: { type: 'string', description: 'Commands run and key output' },
    reproCommand: { type: 'string' },
  },
  required: ['verdict', 'documented', 'severity', 'reasoning', 'evidence'],
}

const TIEBREAK_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'plausible', 'refuted'] },
    documented: { type: 'boolean' },
    severity: { type: 'string', enum: SEVERITIES },
    reasoning: { type: 'string' },
    evidence: { type: 'string' },
  },
  required: ['verdict', 'documented', 'severity', 'reasoning', 'evidence'],
}

const RECONCILE_SCHEMA = {
  type: 'object',
  properties: {
    groups: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          key: { type: 'string' },
          title: { type: 'string' },
          members: { type: 'array', items: { type: 'string' } },
          foundBy: { type: 'string', enum: ['A', 'B', 'both'] },
          severity: { type: 'string', enum: SEVERITIES },
          status: { type: 'string' },
          note: { type: 'string' },
        },
        required: ['key', 'title', 'members', 'foundBy', 'severity', 'status'],
      },
    },
    contradictions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'X01, X02, ...' },
          findingId: { type: 'string' },
          otherCycleCheck: { type: 'string' },
          description: { type: 'string' },
        },
        required: ['id', 'findingId', 'otherCycleCheck', 'description'],
      },
    },
    agreementSummary: { type: 'string' },
  },
  required: ['groups', 'contradictions', 'agreementSummary'],
}

const ADJ_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    ruling: { type: 'string', enum: ['finding-stands', 'finding-refuted', 'both-partly-right', 'undetermined'] },
    reasoning: { type: 'string' },
    evidence: { type: 'string' },
  },
  required: ['id', 'ruling', 'reasoning', 'evidence'],
}

const GAPS_SCHEMA = {
  type: 'object',
  properties: {
    gaps: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          area: { type: 'string' },
          gap: { type: 'string' },
          whyItMatters: { type: 'string' },
          suggestedCheck: { type: 'string' },
          priority: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['area', 'gap', 'whyItMatters', 'suggestedCheck', 'priority'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['gaps', 'summary'],
}

// ---------------------------------------------------------------------------------------------
// Verification of one finding

function lower(x, y) {
  const rx = RANK[x] === undefined ? 2 : RANK[x]
  const ry = RANK[y] === undefined ? 2 : RANK[y]
  return rx <= ry ? x : y
}

function statusOf(verdict) {
  if (!verdict) return 'UNVERIFIED'
  if (verdict.verdict === 'confirmed') return verdict.documented ? 'KNOWN' : 'CONFIRMED'
  if (verdict.verdict === 'refuted') return 'REFUTED'
  return 'PLAUSIBLE'
}

async function tiebreak(c, a, f, votes, slot, phase) {
  const tb = await agent(tiebreakPrompt(c, a, f, votes, slot), { label: `tiebreak ${f.id}`, phase, schema: TIEBREAK_SCHEMA })
  return { status: statusOf(tb), severity: tb && tb.severity ? tb.severity : f.severity, tiebreak: tb }
}

async function verifyFinding(c, a, f, i) {
  const phase = `Cycle ${c.id}: verify`
  const slot = (j) => 'V' + pad((a.k - 1) * 30 + i * 3 + j + 1, 3)
  const sev = SEVERITIES.includes(f.severity) ? f.severity : 'medium'
  if (sev === 'info') return { f, status: 'UNVERIFIED-INFO', severity: 'info', votes: [], tiebreak: null }

  if (sev === 'medium' || sev === 'low') {
    // One combined sceptic; a second one if it rates the finding high or critical.
    const v = await agent(verifierPrompt(c, a, f, LENSES.combined, slot(0)), { label: `verify ${f.id} (combined)`, phase, schema: VERDICT_SCHEMA })
    if (!v) return { f, status: 'UNVERIFIED', severity: sev, votes: [], tiebreak: null }
    if (v.verdict !== 'confirmed' || RANK[v.severity] < RANK.high) return { f, status: statusOf(v), severity: v.severity || sev, votes: [v], tiebreak: null }
    const v2 = await agent(verifierPrompt(c, a, f, LENSES.reproduce, slot(1)), { label: `verify ${f.id} (reproduce, escalated)`, phase, schema: VERDICT_SCHEMA })
    if (v2 && v2.verdict === 'confirmed') return { f, status: v.documented && v2.documented ? 'KNOWN' : 'CONFIRMED', severity: lower(v.severity, v2.severity), votes: [v, v2], tiebreak: null }
    const t = await tiebreak(c, a, f, [v, v2].filter(Boolean), slot(2), phase)
    return { f, status: t.status, severity: t.severity, votes: [v, v2].filter(Boolean), tiebreak: t.tiebreak }
  }

  // critical or high: two sceptics with different lenses, a tiebreak unless they agree.
  const votes = (await parallel([LENSES.reproduce, LENSES.contract].map((L, j) => () =>
    agent(verifierPrompt(c, a, f, L, slot(j)), { label: `verify ${f.id} (${L.key})`, phase, schema: VERDICT_SCHEMA })))).filter(Boolean)
  const conf = votes.filter(v => v.verdict === 'confirmed').length
  const ref = votes.filter(v => v.verdict === 'refuted').length
  if (votes.length === 2 && conf === 2) {
    return { f, status: votes.every(v => v.documented) ? 'KNOWN' : 'CONFIRMED', severity: lower(votes[0].severity, votes[1].severity), votes, tiebreak: null }
  }
  if (votes.length === 2 && ref === 2) return { f, status: 'REFUTED', severity: lower(votes[0].severity, votes[1].severity), votes, tiebreak: null }
  const t = await tiebreak(c, a, f, votes, slot(2), phase)
  return { f, status: t.status, severity: t.severity, votes, tiebreak: t.tiebreak }
}

// ---------------------------------------------------------------------------------------------
// The two cycles, pipelined: each area's findings are verified as soon as its finder is done.

const ITEMS = []
for (const k of ORDER) for (const id of ['A', 'B']) ITEMS.push({ c: CYCLES[id], a: AREAS.find(x => x.k === k) })

log(`Launching ${ITEMS.length} finders (2 cycles x ${AREAS.length} areas). At most ${MAX_FINDINGS} findings per finder go to verification; the rest are listed, not verified.`)

const results = await pipeline(
  ITEMS,
  (item) => agent(finderPrompt(item.c, item.a), {
    label: `find ${item.c.id}${item.a.k} ${item.a.slug}`,
    phase: `Cycle ${item.c.id}: find`,
    schema: FINDINGS_SCHEMA,
  }),
  async (found, item) => {
    const { c, a } = item
    if (!found) {
      log(`Cycle ${c.id} F${a.k} (${a.slug}): the finder returned nothing, so this cycle does not cover the area`)
      return { c: c.id, a: a.slug, k: a.k, found: null, verified: [] }
    }
    const all = Array.isArray(found.findings) ? found.findings : []
    const kept = all.slice(0, MAX_FINDINGS).map((f, i) => ({ ...f, finderId: f.id, id: `${c.id}${a.k}-${pad(i + 1, 2)}` }))
    if (all.length > MAX_FINDINGS) log(`Cycle ${c.id} F${a.k}: ${all.length - MAX_FINDINGS} findings over the cap are not verified: ${all.slice(MAX_FINDINGS).map(x => x.title).join(' | ')}`)
    log(`Cycle ${c.id} F${a.k} (${a.slug}): ${kept.length} findings to verify, ${(found.claimsHeld || []).length} claims held, ${(found.notChecked || []).length} not checked`)
    const verified = (await parallel(kept.map((f, i) => () => verifyFinding(c, a, f, i)))).filter(Boolean)
    const tally = {}
    for (const v of verified) tally[v.status] = (tally[v.status] || 0) + 1
    log(`Cycle ${c.id} F${a.k} (${a.slug}) verified: ${JSON.stringify(tally)}`)
    return { c: c.id, a: a.slug, k: a.k, found, verified, capped: all.slice(MAX_FINDINGS).map(x => `${c.id}${a.k}: ${x.title}`) }
  },
)

// ---------------------------------------------------------------------------------------------
// Cross-cycle stage: needs every result, so it waits for both cycles.

phase('Reconcile')
const done = results.filter(Boolean)
const uncovered = ITEMS
  .filter(it => !done.some(r => r.c === it.c.id && r.k === it.a.k && r.found))
  .map(it => `${it.c.id}${it.a.k} ${it.a.slug}`)
const findings = done.flatMap(r => r.verified.map(v => ({
  id: v.f.id,
  cycle: r.c,
  area: r.a,
  status: v.status,
  severity: v.severity,
  finderSeverity: v.f.severity,
  title: v.f.title,
  category: v.f.category,
  claim: v.f.claim,
  observed: v.f.observed,
  whyWrong: v.f.whyWrong,
  location: v.f.location,
  repro: v.f.repro,
  documented: v.f.documented || '',
  votes: v.votes.map(x => `${x.verdict}${x.documented ? ' (documented)' : ''}, ${x.severity}: ${String(x.reasoning).slice(0, 400)}`),
  tiebreak: v.tiebreak ? `${v.tiebreak.verdict}, ${v.tiebreak.severity}: ${String(v.tiebreak.reasoning).slice(0, 400)}` : null,
})))
const overflow = done.flatMap(r => [...(r.capped || []), ...((r.found && r.found.overflow) ? r.found.overflow.map(o => `${r.c}${r.k} (overflow): ${o}`) : [])])
const coverage = done.map(r => ({
  cycle: r.c,
  area: r.a,
  summary: r.found ? r.found.summary : 'the finder failed',
  held: r.found ? r.found.claimsHeld : [],
  notChecked: r.found ? r.found.notChecked : [],
}))
const tally = {}
for (const f of findings) tally[f.status] = (tally[f.status] || 0) + 1
log(`Both cycles done: ${findings.length} findings verified ${JSON.stringify(tally)}; areas not covered: ${uncovered.length ? uncovered.join(', ') : 'none'}`)

const rec = findings.length
  ? await agent(reconcilePrompt(findings, coverage), { label: 'reconcile cycles', phase: 'Reconcile', schema: RECONCILE_SCHEMA })
  : null
const contradictions = rec && Array.isArray(rec.contradictions) ? rec.contradictions.slice(0, MAX_CONTRADICTIONS) : []
if (rec && Array.isArray(rec.contradictions) && rec.contradictions.length > MAX_CONTRADICTIONS) {
  log(`${rec.contradictions.length - MAX_CONTRADICTIONS} contradictions over the cap of ${MAX_CONTRADICTIONS} are not adjudicated`)
}
log(`${contradictions.length} contradictions to adjudicate`)

const [adjsRaw, gaps] = await parallel([
  () => parallel(contradictions.map((x, j) => () => agent(adjudicatePrompt(x, j), { label: `adjudicate ${x.id}`, phase: 'Reconcile', schema: ADJ_SCHEMA }))),
  () => agent(gapsPrompt(findings, coverage), { label: 'completeness critic', phase: 'Reconcile', schema: GAPS_SCHEMA }),
])
const adjs = (adjsRaw || []).filter(Boolean)

const report = await agent(reportPrompt(findings, rec, adjs, gaps, uncovered, overflow), { label: 'write report', phase: 'Reconcile' })

return {
  report,
  tally,
  uncovered,
  overflow,
  findings: findings.map(f => ({ id: f.id, status: f.status, severity: f.severity, title: f.title, location: f.location, repro: f.repro, votes: f.votes, tiebreak: f.tiebreak })),
  groups: rec ? rec.groups : [],
  agreement: rec ? rec.agreementSummary : null,
  adjudications: adjs,
  gaps: gaps ? gaps.gaps : [],
}
