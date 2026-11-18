# A4-06, sceptic verdict (lens: reproduce and contract)

- Finding: `deterministic: true` results depend on `SolveContext.threads`. Threads 1 and threads >= 2 give different runs.
- Verdict: **confirmed**
- Documented: **false**
- Severity: **low**. The impact is larger than the finder reported (see "Impact"), so a reviewer could argue for medium on the grounds of misleading API behaviour.
- Probe: `verification/probes/cycle-A/Slots/V106/main.swift`, built with `swift build --product V106 -c release`.
- Package state: git main @ d9afebe, unchanged.

## How this check is independent of the finder

The finder compared each run with a first run at threads 4, using `SolverEvent ==`. This probe does it differently:

- Every field is fingerprinted by its exact bit pattern: objective, bound, gap, nodes, open, lpIterations, primal, incumbent history (objective bits, node and source) and the full event sequence. Only the `.finished` seconds are left out.
- Runs are grouped by fingerprint instead of being compared with one reference run.
- Threads 1 is repeated three times, to tell a thread-count effect apart from run-to-run nondeterminism.
- The default context (`threads = nil`, which is 8 here) is included.
- A causal test moves the strong-branching candidate count across the borrow threshold in the code (`candidates.count >= 4`).
- Both points returned on MIPLIB are checked by my own code: row activity, bounds, integrality and c·x + c0, computed straight from the CSC data and compared with the published optimum.

## Commands and key output

All binaries ran under `perl -e 'alarm shift; exec @ARGV' <s>`. No run hit the alarm, and every exit code was 0.

### 1. `.build/release/V106 repro PDI r10 m8 r14`

Default branching `.pseudocost(4)`, seed 7. Thread sequence: 1, 1, 2, 3, 4, 8, nil, 1.

```
randomMILP(10,40,s9,u1) P: groups A=[t1,t1,t1] B=[t2,t3,t4,t8,tnil]  B vs A: lpIterations 6111/6102
randomMILP(10,40,s9,u1) D: A=[t1 x3] B=[t2..tnil]  lpIterations 5595/5597
randomMILP(10,40,s9,u1) I: A=[t1 x3] B=[t2..tnil]  lpIterations 5585/5587
mixed(8,30,s5) P: A=[t1 x3] B=[t2..tnil]  incumbentHistory; events first diff #4:
    newIncumbent(791.7420184186276[...848],node 19) vs newIncumbent(791.7420184186277[...849],node 19)   (1 ulp)
mixed(8,30,s5) D, I: one group (identical at every thread count)
randomMILP(14,50,s21,u2) P: lpIterations 18914/18912; D: 9498/9499; I: 9432/9433
```

These are exactly the finder's numbers. The instance and configuration of r10 are those of the package's own test `twentyRunsAreIdentical`: randomMILP(10,40,s9,upper 1), `BranchAndBound(deterministic: true, seed: 7)`. That test pins `threads = 4`.

### 2. `.build/release/V106 mech P r10 m8 r14`

This is the causal check. Thread sequence: 1, 1, 2, 4, 4, 8.

```
mostFractional        : 1 group on all 3 instances          (no probes)
strong(candidates: 3) : 1 group on all 3 instances          (probes < 4, never borrow, always inline)
strong(candidates: 4) : A=[t1,t1] B=[t2,t4,t4,t8]; r10 nodes 219/215, iters 19738/19468; r14 nodes 1206/1205
strong(candidates: 8) : A=[t1,t1] B=[...]; bound events differ in the last bits
pseudocost(4)         : A=[t1,t1] B=[...]
```

The dependence switches on at exactly 4 candidates. That matches TreeSearch.swift:583-584, `if candidates.count >= 4 { extra = await budget.borrow(...) }`.

### 3. `.build/release/V106 scan P 40`

40 random MILPs, threads 1 against 4 and nil:

- 24 of 40 differ between threads 1 and threads 4.
- threads nil (8) equals threads 4 on all 40.
- Fields that differed: lpIterations 24, events 5, incumbentHistory 3, nodes 2 (seed 126: 1653 against 2155; seed 124: 1733 against 1752), objective, bound and primal 1.

`.build/release/V106 detail P 19` (seed 119): the objective is 757.2987423489985 against ...986, one ulp apart. The bound is the same. Five continuous columns differ by at most 2.9e-15, and the integer columns are identical.

### 4. `.build/release/V106 repro PD p0033 flugpl enigma mod008 lseu` (MIPLIB 3)

```
p0033  P: nodes 1605/1575, iters 11840/11756, incumbent nodes differ        D: identical
flugpl P: iters 12599/12600                                                 D: identical
enigma P: nodes 6579/21263, iters 97889/273523, primal differs              D: nodes 24460/59 (!), iters 594890/7137, wall 2.8 s vs 0.03 s
mod008 P: nodes 3720/4126                                                   D: nodes 6656/6851
lseu   P: nodes 27187/14179, iters 118719/70181, primal differs, wall 1.2 s vs 0.55 s   D: identical
```

In every case threads 2, 3, 4, 8 and nil form one group, and threads 1 (three runs) forms another.

### 5. `.build/release/V106 mdetail P enigma lseu` and `mdetail D enigma`

The returned optimal solution differs between threads 1 and threads 4:

- enigma P: G1, G2, I1, I2 swap between 0 and 1.
- lseu P: C134, C135, C143, C144 swap between 0 and 1.

My own check finds both points of each pair feasible: row and bound violation 0, integrality violation 0. c·x + c0 equals the published optimum (enigma 0, lseu 1120). enigma D returns equal values; the bit differences there are 0.0 against -0.0.

## Reasoning

**The code**

The mechanism is confirmed by a precise reading of the code:

- BranchAndBound.swift:204-205 and 296 compute `workerCount = deterministic ? 1 : threads`, but build `ConcurrencyBudget(threads: threads, occupied: workerCount)`. A deterministic search therefore has `threads - 1` free slots.
- TreeSearch.swift:582-598: when the budget grants slots, the probes run in child tasks on fresh private engines. When it grants none (threads == 1), they run inline on the worker's own engine (`&worker`). That changes which basis and factorization the engine holds when the next node LP warm-starts.
- At threads >= 2, the result does not depend on how the probes are split up. Threads 2, 3, 4, 8 and the default were always identical.

**The contract**

- Run-to-run reproducibility at a fixed context holds. Threads 1 repeated three times, and threads 4 repeated, were identical.
- Thread-count independence is not stated literally. But every description of the mode leads a reader to expect it:
  - the doc comment: "Single worker ... identical results and identical event sequences across runs";
  - README §1 principle 6: "same result and the same event sequence every run";
  - risk 8 mitigation: "runs a single worker with a fixed seed";
  - §4: "unless deterministic: true, which uses one worker".
- Risk 8 lists "the solution returned" among the things that vary, and deterministic mode is offered as the cure. Across threads 1 and >= 2, the solution returned still varies (enigma, lseu).
- Risk 7 advises "give each its share with SolveContext.threads". A user who follows it and sets threads 1 gets a different deterministic run from one made with the defaults.
- CPSAT's deterministic LP worker pins `context.threads = 1` (LPRelaxation.swift:225). Branch and bound has no such guard, so the difference does not look like a deliberate design choice.
- This is not a wrong oracle, not misuse and not within a documented tolerance. So: confirmed.

**Documented**

No. README, HANDBOOK and the SPECIFICATION never say that deterministic results depend on `threads`. The only description of the two probe paths is the internal doc comment on `runProbes`, which says nothing about reproducibility. `twentyRunsAreIdentical` pins threads = 4, so it cannot see the effect.

**Severity: low**

- Status and objective agree in every run, apart from one ulp on one instance. The README's own advice is "Compare objectives, not solutions".
- Only threads == 1 differs. The default on any multi-core Apple machine falls in the consistent >= 2 group.
- The finder said "objective, bound and primal were equal in all of them". That is not true in general:
  - on MIPLIB enigma and lseu with the primal engine, a different optimal integer solution is returned;
  - node counts differ by up to about 415× (enigma, dual engine: 59 against 24,460 nodes; 0.03 s against 2.8 s);
  - on seed 119, objective and bound differ by one ulp.
- Anyone who relies on deterministic mode to reproduce a solution or a node count across thread settings is affected. That is why medium ("misleading API behaviour") is arguable.
