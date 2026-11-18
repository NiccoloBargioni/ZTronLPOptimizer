# A5-03: sceptic verdict (lens: reproduce and contract), cycle A, slot V127

- verdict: **confirmed**, with corrections to the details (listed below)
- documented: **false**
- severity: **medium** (test-integrity: tests whose names state properties that fail in the documented domain, at magnitudes or structures the tests never use. The wrong answers themselves belong to A5-01, which is critical.)

## What was checked

1. **Test data, read from the sources.**
   - `LPPropagatorTests.dataNearTheLimitsOfInt64IsHandled` (LPPropagatorTests.swift:395-436): coefficients up to 1e9, rhs 2e9, x <= 1e6, activities 1e15; six-decimal costs (<= 31e6 after scaling); "millions" rows with coefficients <= 9e6 and sides that are multiples of 1e6.
   - `AcceptanceTests.largeButRepresentableDataIsAccepted` (:88-94): 1e9, 2e9, 1e6.
   - `columnBoundsRoundInward` (:204-212): |bounds| < 4.
   - `scalingToleratesFloatingPointNoiseOnly` (:252-262): the largest value is 123_456_789_012.5 (about 2^36.8).
   - Grep of Tests/ZTronLPCPSATTests found no test on the acceptance side with bounds or scaled coefficients >= 2^48, or activities near 2^61. The rejection tests use bounds of 1e17 and activities of 1.2e19 and about 4e18. Largest accepted values elsewhere: 3e12·(x+y) <= 10 (divided out) and activities of 1e15. The claim "only tested on the rejection side" holds.
2. **The tests pass now.** `swift test --filter 'AcceptanceTests/(columnBoundsRoundInward|scalingToleratesFloatingPointNoiseOnly|largeButRepresentableDataIsAccepted)|LPPropagatorTests/dataNearTheLimitsOfInt64IsHandled'` gave `Test run with 4 tests in 2 suites passed`. The baseline agrees: 03-test-debug.log lines 1620, 1624, 1647, 1689, and 05-tsan.log.
3. **Independent reproduction.** Probe Slots/V127/main.swift uses the public API only. Every datum is p/D with D a power of two, checked to be an exact Double. The oracle decides feasibility and the optimum in exact Int64 on the numerators by enumerating the domains, and uses no package code. It accounts for the documented CP-SAT gap (README risk 10): a feasible point within max(1e-6, 1e-4·max(1,|obj|)) counts as OK. Every case ran with the configurations det (`CPSAT(deterministic:true)`), par (`CPSAT()`) and detnolp (`CPSAT(lpPropagator:false, deterministic:true)`), with timeLimit 10 s.

## Key results (release build; the same in all three configurations unless noted)

| group (mirrors) | instance | result |
|---|---|---|
| T0 (the tests' own data) | 1e9·x0 + x1 >= 2e9, min x0; a = 123456789012.5 row | OK (2, 1) |
| T2 (scalingToleratesFloatingPointNoiseOnly: "a large value that is not an integer is not mistaken for one") | a·x + y >= a + 0.5, x binary, y in [0,3], min y; true optimum 1 | a = 2^36+0.5, 2^44+0.5, 2^48+0.5: OK. **a = 2^49+0.5 and 7e14+0.5, where 10a < 2^53 so the README's domain accepts them at scale 10: `.optimal obj=0 x=[1,0]`, row violated by 0.5.** a = 2^50+0.5: the same, although README says unsupported. |
| T1u / T1l (columnBoundsRoundInward); small objective, so the gap plays no part | x in [K-10, K+f] or [K-3-f, K+7], w = 1, a row that turns the bound into y <= 3, max y; true optimum 3 | Integral bounds (f = 0): OK up to K = 2^49+5. **K = 2^50+5: y = 4, bound violated by 1; 2^51+5: y = 5, violated by 2; 2^52+5: y = 7, violated by 4** (upper and lower alike). Fractional bounds round outward from 2^48 (f within 4 ulp of the outer integer), from 2^49 for f = 1/2, and for every f from 2^50. |
| T3 (largeButRepresentableDataIsAccepted with integral data) | a = 2^e+1, a·x + y >= 2a+1 (or a·x - y <= 2a-1 with x = 2), min y; true optimum 1 | OK for e <= 48. **e = 49, 50, 51: `.optimal obj=0`, row violated by 1** (the integral side 2a ± 1 >= 2^50 is widened by one unit). |
| T4 (acceptance side of ±2^61) | a = 2^40+1, a·x <= R (R < a·M), max x | **M = 1000: x = 1000, row violated by 232; M = 1,048,000 (activities about 2^60): x = M, violated by 192** (det and par; detnolp stopped within the gap). |
| T5 (a related path at the tests' own magnitude 1e9) | single-term row a·x <= 5a-1 (max x, true 4) and a·x >= 5a+1 (min x, true 6) | a = 99,999,999: OK. **a = 999,999,999, 1e9, 1e9+1, 1e10+1, 2^40+1: `.optimal` x = 5, row violated by 1**, in all 3 configurations. |

The mechanism, read from the code, matches the results:
- `CPModel.snapTolerance = max(1e-9, 4·ulp)` is added before `rounded(.down)` and subtracted before `rounded(.up)`. This is done for column bounds (CPModel.swift:173-174) and row sides (:335, :347; LPRelaxation.swift:95, 99), and the same tolerance decides integrality (:131). From 2^50 on, 4 ulp >= 1, so an exact integer moves outward to a different integer.
- T5 and T4 at M = 1000 come from the 1e-9 floor. It is applied after the row is divided by its common divisor (:316-335), so a unit offset over a divisor of 1e9 or more becomes a "fraction" below 1e-9 and is snapped outward. The finder's A5-01 (d) example (a = 2^40+1) is this mechanism, not the 4-ulp widening.

## Contract

- README §2.5 (line 324) and §4 "Limits by design / CP-SAT" (lines 486-488) define the accepted domain: a power of 10 up to 1e6, bounds and scaled coefficients below 2^53, activities within ±2^61. Everything else is rejected with `.unsupported`.
- The CPModel header says "exact Int64 arithmetic", "integral within 1e-9" and "Root domains, rounded inward to integers". The `integralScale` doc says "within 1e-9".
- The package's own tests compare CP-SAT objectives exactly with brute force.
- The 1e-7 tolerance of README §4 "Results" is an absolute bound/row tolerance "after scaling" (`Tolerances.primalFeasibility` doc). The violations found (0.25 to 232) are far above it.
- The documented gap applies to the objective only, and T1u, T1l, T2, T3 and T5 use objectives below 10, where CP-SAT's proof is documented as exact.

So the failures are defects, not something within a documented tolerance or by design. The 4-ulp snap appears only in a code comment ("so that noise in large data is not mistaken for a fraction"), and moving an exact integer contradicts even that intent. Neither README §3/§4 nor the HANDBOOK (Known gaps, Not verified) mentions the snap, the large-data behaviour or the gap in the tests, so documented = false.

## Corrections to the finding as reported

1. "pass in the baseline (debug, release, TSAN)": the CP-SAT unit suites ran only in debug (03) and TSAN (05). Step 04 (release) ran only the Integration and Liveness tests.
2. 1e15+0.5 (the finder's D14) is outside the accept-domain, because 10a >= 2^53, so the README's documented outcome for it is `.unsupported`. The answer is wrong either way. Strictly in-domain cases with the same wrong answer: 2^49+0.5 and 7e14+0.5 (T2).
3. "can only pass for data below 2^49" is imprecise. The threshold depends on the fraction (2^48 for fractions 1/4 from the outer integer, 2^49 for halves, 2^50 for exact integers). A related failure (T5) is already reachable at the tests' own coefficient magnitude, 1e9, with a structure the tests do not use: a single-term row or a large common divisor with a side that is not a multiple of it. So the gap is structural as well as one of magnitude. That widens the finding rather than refuting it.
4. How directly each test is "named for" the property: direct for `columnBoundsRoundInward` and for `scalingToleratesFloatingPointNoiseOnly`, whose comment states exactly the property that fails at 2^49+0.5. Weaker for `dataNearTheLimitsOfInt64IsHandled` (its doc is about overflow of the LP propagator's integer combination) and for `largeButRepresentableDataIsAccepted` (named for acceptance, which still holds). None of the four can catch the defect.

## Commands run and key output

- `cd verification/probes/cycle-A && swift build --product V127 -c release` gave Build complete.
- `perl -e 'alarm shift; exec @ARGV' 600 .build/release/V127 T0,T2,T3,T4` (exit 0) wrote verdicts/A5-03-combined-V127-run2.txt with T0 ok=6 wrong=0; T2 ok=9 wrong=9 (first wrong at a=2^49+0.5); T3 ok=18 wrong=18 (first wrong at a=2^49+1); T4 ok=1 wrong=5.
- `... 400 .build/release/V127 T1u` and `T1l` (exit 0) wrote A5-03-combined-V127-T1u.txt and -T1l.txt with T1u-int and T1l-int ok=12 wrong=9 (first wrong at 2^50+5) and T1u-frac and T1l-frac ok=27 wrong=21 (first wrong at 2^48+5, f=0.75).
- `... 300 .build/release/V127 T5` (exit 0) wrote A5-03-combined-V127-T5.txt with ok=6 (a=99,999,999) and wrong=30.
- A5-03-combined-V127-T0T2.txt and -T1T3T4.txt come from the first run, with an older classification that did not separate the gap. Its T1 "max x" cases between 2^36 and 2^49 are within the documented gap and are not defects; use T1u and T1l for the bounds. One intermediate run ended with exit 133 because of my own oracle's precondition (an enumeration domain that was too large) in the first T1u version. That was a probe bug, fixed, and not a package trap.
- `cd /Users/admin/Documents/ZTronLPOptimizer && swift test --filter '...four tests...'` gave `Test run with 4 tests in 2 suites passed after 0.538 seconds`.
