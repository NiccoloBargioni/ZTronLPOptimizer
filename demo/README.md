# ZTronLP Demo

A small SwiftUI app that tours the solving strategies of ZTronLPOptimizer. There is one tab
per strategy, and each tab lists a few small problems: well conditioned, badly conditioned,
without an optimum, and, where it makes sense, one that stops at a limit. Each problem has a
**Solve** button that runs the tab's strategy on it and writes a short log underneath: did the
run finish, with which verdict, what bound it proved, and what certificate backs the verdict.

The app runs on macOS 15, iOS 18 and iPadOS 18.

## Run it

1. Open `demo/ZTronLPDemo.xcodeproj` in Xcode 16 or later. It was made with Xcode 27.
2. Choose the **ZTronLPDemo** scheme and a run destination: *My Mac*, or an iPhone or iPad simulator.
3. Press ⌘R.

The project uses the package in the repository root (`..`) as a local package, so changes to
the library show up on the next build. When the project is first opened, Swift Package Manager
fetches the two dependencies, swift-atomics and swift-collections.

To run on a real iPhone or iPad, choose your team under *Signing & Capabilities* first.

### If the build stops at the Metal shaders

Inside Xcode, the package compiles the GPU kernels in `Sources/ZTronLPMetal/Shaders` with
the Metal compiler. That compiler is a separate Xcode component. If the build fails because
the Metal Toolchain is missing, do one of the following:

- Install the toolchain from *Xcode ▸ Settings ▸ Components*, or with
  `xcodebuild -downloadComponent MetalToolchain`.
- Or quit Xcode and reopen the project with shader precompilation turned off. The package then
  ships the shader source and compiles it the first time the GPU is used:

  ```bash
  open --env ZTRONLP_METAL_PRECOMPILE=0 demo/ZTronLPDemo.xcodeproj
  ```

  The variable only reaches Xcode if Xcode is not already running.

### Debug or Release

The Run action builds the Debug configuration, so the solvers run unoptimized. Every example
is small, and the slowest one stops itself after one second, so Debug works fine. For
realistic timings, switch *Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Build Configuration* to
Release.

## The tabs

| Tab | Runs | Well conditioned | Badly conditioned | No optimum | Other |
|---|---|---|---|---|---|
| Simplex | `Simplex(.dual)` or `Simplex(.primal)` | Furniture workshop, Transport plan | Hilbert system 7 × 7, Feed blend in mixed units | Forgotten capacity limit (unbounded, with a ray), Overbooked production line (infeasible, with a Farkas certificate) | |
| Interior Point | `InteriorPoint(crossover: .lite)` or `.none` | Furniture workshop, Transport plan | Hilbert system 5 × 5, Feed blend in mixed units | The same two; the interior point can only say "infeasible or unbounded" | |
| Branch & Bound | `BranchAndBound(engine:)` with primal simplex, dual simplex or interior-point node LPs | Backpack for a hike, Facility location | Facility location with a big M | Crates of 6 and 9 (infeasible), Unlimited tokens (no verdict) | Research portfolio (stops at 300 nodes) |
| CP-SAT | `CPSAT(lpPropagator:)`, with or without the LP relaxation | Backpack for a hike | Job sequencing with a big M | Seven guests, six rooms (infeasible) | Research portfolio (stops after 1 s), Facility location (rejected: continuous variables) |
| Automatic | `Automatic()` | Furniture workshop, Workshop with an overtime shift | Hilbert system 7 × 7 | Forgotten capacity limit | |
| Portfolio | `Portfolio([…])`: both simplex methods and the interior point for LPs; two branch-and-bound variants and CP-SAT for integer models | Transport plan, Backpack for a hike | Feed blend in mixed units, Facility location with a big M | Overbooked production line | |
| Conditioned | `Conditioned(Automatic())` | Furniture workshop | Feed blend in mixed units, Hilbert system 7 × 7, Two almost identical limits, Facility location with a big M | | |

Each problem's page shows its summary, the formulation in mathematical notation, and the LP
file the engine reads. Where a tab offers a choice, such as the simplex method or the node
engine, a picker sits above the Solve button.

## Reading the log

The log answers, in order:

1. Which engine ran, and the size of the problem.
2. Whether the run finished, and how: an optimum, proven infeasible, proven unbounded, no
   verdict ("infeasible or unbounded"), stopped by a limit or by the Stop button, or a
   numerical failure.
3. The objective, the proven bound and the gap between them.
4. The certificate behind a verdict without an optimum: a ray for an unbounded problem,
   Farkas multipliers for an infeasible one, or a note that the search closed every branch.
5. The solution, the shadow prices, and a check: the worst constraint violation and, for
   integer models, the worst distance from an integer. Some examples add their own check, for
   example the error against the known exact answer of the Hilbert system.
6. What the engine did: pivots, iterations, nodes, conflicts, the portfolio's winner, or the
   conditioning report.
7. Warnings from the engine.

In the list, the icon next to a problem shows the outcome of its last run:

| Icon | Meaning |
|---|---|
| Green check | Optimal |
| Purple "no" sign | Proven infeasible |
| Purple infinity | Proven unbounded |
| Orange question mark | No verdict |
| Orange stop sign | Stopped by a limit |
| Red octagon | Failed or rejected |

## How the code is organized

- `ZTronLPDemo/Model/` holds plain Swift with no SwiftUI:
  - `Catalog.swift`: the examples, written with the DSL.
  - `StrategyKind.swift`: the tabs, their variants, and which strategy each one runs.
  - `Runner.swift`: compiles an example and solves it under a time limit.
  - `Report.swift`: turns the analysis into the log.
  - `Example.swift` and `Format.swift`: the example type and number formatting.
- `ZTronLPDemo/Views/` holds the tabs (`ContentView`), the example list (`StrategyView`), a
  problem's page (`ExampleDetailView`) and the log (`LogView`).
- `ZTronLPDemo/RunStore.swift` keeps each tab's choices and logs, and starts and cancels solves.

The project uses a folder-synchronized group, so files added under `ZTronLPDemo/` join the
app target without editing the project.

To add an example, add a static `Example` to `Catalog` with a title, subtitle, summary,
formulation and build closure. Then list it in `StrategyKind.groups` for each tab that should
show it.

## Why the Hilbert systems are 7 × 7 and 5 × 5

The condition number of a Hilbert matrix grows about thirtyfold with each added row. When
the demo was written (November 2026), the engines behaved as follows:

| Size | Simplex | Interior point |
|---|---|---|
| 5 × 5 | exact answer to about 11 digits | the same with crossover-lite; without crossover it stops with a numerical failure |
| 6 × 6, 7 × 7 | about 9 and 7 digits | "infeasible or unbounded", which is wrong: the system has a unique solution |
| 8 × 8 and up | "unbounded", which is wrong | "infeasible or unbounded" |

So the simplex-based tabs use 7 × 7 and the interior-point tab uses 5 × 5. To watch the
engines break down, change the sizes in `Catalog.hilbert` and `Catalog.hilbertSmall`.
