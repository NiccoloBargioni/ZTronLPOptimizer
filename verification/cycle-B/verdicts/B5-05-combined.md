# B5-05 — sceptic verdict (lens: reproduce and contract), cycle B

- verdict: **confirmed**
- documented: **false**
- severity: **low** (same as the finder)
- probe: verification/probes/cycle-B/Slots/V133/main.swift (modes sweep, lower, paths, coef)

## Reasoning

Claim under test. README §2.5 (CPSAT row) says CPSAT throws `.unsupported` for "bounds or
scaled coefficients of magnitude 2⁵³ or more". README §4 (Limits) says the supported class has
"bounds and scaled coefficients below 2⁵³".

Independent oracle. Exact Int64 arithmetic plus the README's own threshold. Take one integer
column with integral bounds L ≤ U and no rows. If |L|, |U| < 2⁵³, max x must give exactly U and
min x exactly L. If a bound has magnitude 2⁵³ or more, the solve must throw. All the test values
are exactly representable as Doubles: I checked `Int64(exactly: Double(v)) == v`. I built each
model three independent ways: a hand-made `CompiledLP` (no DSL, no presolve), the DSL with
`.integer(.range(0...9_007_199_254_740_991))`, and free MPS text read by `MPSFormat.read`.

Result. Reproduced, deterministic, the same across all three construction paths and in two runs:
- U = 2⁵³−1, 2⁵³−2, 2⁵³−3, 2⁵³−4: CPSAT() and CPSAT(deterministic: true) both throw
  `unsupported: the bounds of column x1 are too large for exact integer arithmetic`.
  The README says these bounds are accepted.
- U = 2⁵³−5 and below: accepted.
- U = 2⁵³ and 2⁵³+2: throw, as the README says.
- The lower side is symmetric. L = −(2⁵³−1) and −(2⁵³−4) throw; −(2⁵³−5) is accepted.
- x in [−(2⁵³−1), 2⁵³−1] throws.

So for bounds the real threshold is a magnitude of 2⁵³−4, not 2⁵³. The cause is in
Sources/ZTronLPCPSAT/CPModel.swift:173-178. The snap tolerance max(1e-9, 4·ulp), which is 4 at
this magnitude, is added before the `|hi| < 2⁵³` guard. For example
(2⁵³−1) + 4 = 2⁵³+3, which rounds to 2⁵³+4 in Double, and that value is not below 2⁵³.

For coefficients the README threshold is exact. An objective coefficient of 2⁵³−1 is accepted
(optimal), and 2⁵³ is rejected. The guard at CPModel.swift:130 applies no shift. So only the
bound path deviates from the documented number.

Why the finding is not refuted:
- **Wrong oracle?** No. 2⁵³−1 < 2⁵³ is unambiguous, and the model has no rows. The objective
  activity (≤ 2⁵³) is far inside ±2⁶¹, and the error names the column bounds.
- **Misuse?** No. A valid integer column with finite integral bounds fails the same way through
  the DSL, MPS and hand-built paths.
- **By design?** No. The intended threshold is 2⁵³: the guard literal, and the package test
  comment "Bounds beyond 2^53 cannot be read exactly from a Double"
  (Tests/ZTronLPCPSATTests/AcceptanceTests.swift:83, which only tests 1e17). The shift of 4 is
  a side effect of the noise snap.
- **Within a documented tolerance?** No. Neither the README, the HANDBOOK nor the public doc
  comment of `CPSAT.solve` (CPSAT.swift:147-149) mentions the 4-ulp snap of bounds or the
  2⁵³−4 limit. Only the internal `snapTolerance` comment (CPModel.swift:114-118) describes the
  4-ulp rule, and it describes it as an integrality check.

Severity: low. The failure is a clean, descriptive `.unsupported` throw, not a wrong answer. It
hits 4 integer values on each side out of about 9e15, and the README number is off by 4. That is
"a minor documentation or number mismatch".

Not part of this finding: the same 4-ulp snap also widens accepted bounds (finding B5-01). That
showed up here too. With CPSAT(), U = 2⁵³−5, −6, −8, −16 and −2²⁰ give `.optimal` with x = U+4,
and the lower side gives x = L−4. B5-01 is a separate, more severe finding, so I did not use it
to rate B5-05.

## Commands and key output

```
cd /Users/admin/Documents/ZTronLPOptimizer/verification/probes/cycle-B && swift build --product V133 -c release
  -> Build complete!
perl -e 'alarm shift; exec @ARGV' 300 .build/release/V133 all      (exit 0)
S k=0  U=9007199254740992 readmeAccept=false  CPSAT(det)/CPSAT(): THROW unsupported: the bounds of column x1 are too large ... -> ok
S k=1  U=9007199254740991 readmeAccept=true   CPSAT(det)/CPSAT(): THROW unsupported: the bounds of column x1 are too large ... -> MISMATCH
S k=2  U=9007199254740990                      same THROW -> MISMATCH
S k=3  U=9007199254740989                      same THROW -> MISMATCH
S k=4  U=9007199254740988                      same THROW -> MISMATCH
S k=5  U=9007199254740987  CPSAT(): status=optimal x=9007199254740991 (x-U=4; B5-01)   [accepted]
L k=1  L=-9007199254740991 THROW unsupported ... ;  L k=4 L=-9007199254740988 THROW ;  L k=5 accepted (x-L=-4, B5-01)
SYM x in [-(2^53-1), 2^53-1], max x: THROW unsupported: the bounds of column x1 are too large for exact integer arithmetic
DSL compiled: xl=[0.0] xu=["9007199254740991"] c=[-1.0] sense=maximize ints=[0]
DSL CPSAT(det): THROW unsupported: the bounds of column x are too large for exact integer arithmetic
MPS read: xl=[0.0] xu=["9007199254740991"] c=[-1.0] ints=[0]
MPS CPSAT(det): THROW unsupported: the bounds of column x1 are too large for exact integer arithmetic
ARITH U=2^53-1: ulp=1.0 U+4ulp=9007199254740996 (>= 2^53: true)
ARITH U=2^53-4: ulp=1.0 U+4ulp=9007199254740992 (>= 2^53: true)
ARITH U=2^53-5: ulp=1.0 U+4ulp=9007199254740991 (>= 2^53: false)
COEF objective coef 2^53-1 on binary, max: status=optimal x=1          (README threshold exact for coefficients)
COEF objective coef 2^53   on binary, max: THROW unsupported: the objective has coefficients that no power of 10 up to 1e6 makes integral
Repeated: V133 lower; V133 paths -> identical throws (exit 0).
```

Code and doc reads:
- Sources/ZTronLPCPSAT/CPModel.swift:117-119 (`snapTolerance = max(1e-9, 4*ulp)`), :173-180
  (bound snap, then the `< 9.007_199_254_740_992e15` guard), :130 (coefficient guard, no shift).
- README.md:324 (§2.5 CPSAT row) and README.md:486-488 (§4 Limits).
- No mention in HANDBOOK.md, and none in the public doc comment at CPSAT.swift:147-149.

## Other things seen, not checked further and not part of B5-05

- BranchAndBound() on x in [0, 2⁵³−1], max x (hand-built and MPS) returns `.optimal` with
  x = 9007199353820190. That is 99,079,199 above the upper bound, a relative error of 1.1e-8.
  For U = 2⁵³−4 it returns x = 9007199353820188. This belongs to area F4 (branch and bound or
  the LP bound tolerance at this scale). Whether a relative feasibility tolerance permits it was
  not checked.
- CPSAT(deterministic: true) on [0, 2⁵³−5], max x stops at the 5 s limit with x ≈ 1.7e6
  (`.feasible(timeLimit)`). The linear search is documented in §4.
- An objective coefficient of 2⁵³ is rejected with a message about integrality. The real reason
  is its magnitude. The outcome still matches the README.
