// swift-tools-version: 6.0
import Foundation
import PackageDescription

// ZTronLPOptimizer — linear and mixed-integer linear programming on Apple platforms
// (technical specification v0.1, §2 and §3).
//
// One package, ten library targets, one C shim and a facade that most apps import.
// Layering (§3): Core and CLAPACKShim at the bottom, Numerics above them, the engines and
// the optional Metal and Conditioning targets above Numerics, branch and bound and CP-SAT
// above the LP engines, and the `ZTronLPOptimizer` facade on top.
//
// Two edges deserve a note because the specification's diagram does not draw them:
//   * ZTronLPInteriorPoint imports ZTronLPSimplex. Crossover-lite (§8.4) hands the interior
//     point to the simplex engine and `InteriorPointAnalysis.crossover` is a
//     `SimplexAnalysis` (§11.3), so the import cannot be avoided.
//   * No engine imports ZTronLPMetal. The GPU kernels reach the engines by dependency
//     injection: the kernel protocols live in ZTronLPNumerics and the provider travels in
//     `SolveContext.accelerator` (§6.4, §7.5, §9.5).

// Every target opts into the Swift 6 language mode, so complete concurrency checking is an
// error, not a warning (§2, rule C1).
var swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

// `associatedtype Worker: ~Copyable` (§9.1) is SE-0503. Toolchains older than 6.4 only have
// it behind the experimental flag; 6.4 and later ship it and deprecate the flag.
#if compiler(<6.4)
swiftSettings.append(.enableExperimentalFeature("SuppressedAssociatedTypes"))
#endif

// Metal shaders (§3). Xcode compiles `Shaders/Kernels.metal` into default.metallib, which is
// what `.process` asks for. A command-line build may have no Metal compiler at all — the
// Metal Toolchain is a separate Xcode component, and a `.process`ed shader fails the whole
// build without it — so there the source file is copied verbatim and `MetalContext` compiles
// it with `makeLibrary(source:)` at first use; if that fails too, the GPU tier is disabled.
// ZTRONLP_METAL_PRECOMPILE=1 / =0 overrides the detection in either direction.
let precompileShaders: Bool = {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["ZTRONLP_METAL_PRECOMPILE"] { return override == "1" }
    return environment["__CFBundleIdentifier"] == "com.apple.dt.Xcode"
}()
let shaderResources: [Resource] = [precompileShaders ? .process("Shaders") : .copy("Shaders")]

let atomics: Target.Dependency = .product(name: "Atomics", package: "swift-atomics")
let heap: Target.Dependency = .product(name: "HeapModule", package: "swift-collections")
let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
let bitCollections: Target.Dependency = .product(name: "BitCollections", package: "swift-collections")

let package = Package(
    name: "ZTronLPOptimizer",
    platforms: [.iOS(.v15), .macOS(.v12), .macCatalyst(.v15)],
    products: [
        // The facade: `Automatic`, `Portfolio`, `Conditioned` and re-exports of every public type.
        .library(name: "ZTronLPOptimizer", targets: ["ZTronLPOptimizer"]),
        // Individual layers, for clients that want less than the facade.
        .library(name: "ZTronLPCore", targets: ["ZTronLPCore"]),
        .library(name: "ZTronLPNumerics", targets: ["ZTronLPNumerics"]),
        .library(name: "ZTronLPMetal", targets: ["ZTronLPMetal"]),
        .library(name: "ZTronLPSimplex", targets: ["ZTronLPSimplex"]),
        .library(name: "ZTronLPInteriorPoint", targets: ["ZTronLPInteriorPoint"]),
        .library(name: "ZTronLPBranchAndBound", targets: ["ZTronLPBranchAndBound"]),
        .library(name: "ZTronLPCPSAT", targets: ["ZTronLPCPSAT"]),
        .library(name: "ZTronLPConditioning", targets: ["ZTronLPConditioning"]),
        .library(name: "ZTronLPTestSupport", targets: ["ZTronLPTestSupport"]),
        // Prints the §14.3 benchmark table; run before a tagged release, not in CI.
        .executable(name: "ZTronLPBenchmarks", targets: ["ZTronLPBenchmarks"]),
    ],
    dependencies: [
        // The only two dependencies (§2): lock-free incumbent bound and counters, and Heap /
        // OrderedDictionary / BitSet. Both are Apple-maintained and support iOS 13+.
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        // MARK: Layer 1

        // DSL, LPModel, CompiledLP, presolve-lite, scaling, Solution, options, events,
        // MPS/LP reader and writer. Pure Swift; compiles on any platform.
        .target(
            name: "ZTronLPCore",
            dependencies: [atomics],
            swiftSettings: swiftSettings
        ),

        // Legacy BLAS/LAPACK declarations with deprecation warnings suppressed and
        // int32_t-typed wrappers (§2).
        .target(
            name: "CLAPACKShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),

        // MARK: Layer 2

        // Dense/sparse containers, BLAS/LAPACK/vDSP kernels, Accelerate Sparse wrappers,
        // BasisFactorization strategies, Deadline, WorkGate, ConcurrencyBudget, and the
        // candidate-kernel protocols the GPU tier implements.
        .target(
            name: "ZTronLPNumerics",
            dependencies: ["ZTronLPCore", "CLAPACKShim", atomics],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("Accelerate")]
        ),

        // MARK: Layer 3

        // Optional GPU tier: MetalContext, reducedCostScan and batchedActivity kernels, fp32
        // buffers, automatic fallback. Xcode compiles the shaders into default.metallib;
        // under `swift build` the source file is copied and compiled at first use.
        .target(
            name: "ZTronLPMetal",
            dependencies: ["ZTronLPCore", "ZTronLPNumerics"],
            resources: shaderResources,
            swiftSettings: swiftSettings
        ),

        // Primal and dual bounded simplex, pricing, ratio tests, phase 1, anti-cycling, warm
        // starts, certificates.
        .target(
            name: "ZTronLPSimplex",
            dependencies: ["ZTronLPCore", "ZTronLPNumerics"],
            swiftSettings: swiftSettings
        ),

        // Mehrotra predictor–corrector, normal equations, regularization, crossover-lite.
        .target(
            name: "ZTronLPInteriorPoint",
            dependencies: ["ZTronLPCore", "ZTronLPNumerics", "ZTronLPSimplex"],
            swiftSettings: swiftSettings
        ),

        // Optional analyzer producing ConditioningReport.
        .target(
            name: "ZTronLPConditioning",
            dependencies: ["ZTronLPCore", "ZTronLPNumerics"],
            swiftSettings: swiftSettings
        ),

        // MARK: Layer 4

        // NodeLPStrategy and its concrete strategies, SearchTree actor, workers, branching
        // rules, node selection, heuristics, reduced-cost fixing.
        .target(
            name: "ZTronLPBranchAndBound",
            dependencies: [
                "ZTronLPCore", "ZTronLPNumerics", "ZTronLPSimplex", "ZTronLPInteriorPoint",
                atomics, heap,
            ],
            swiftSettings: swiftSettings
        ),

        // CDCL core, lazy bound literals, clause and linear propagators, restarts, portfolio
        // workers, and the LP propagator, which solves the relaxation with the simplex engine
        // (§3: branch and bound and CP-SAT are the two consumers of the LP engines).
        .target(
            name: "ZTronLPCPSAT",
            dependencies: [
                "ZTronLPCore", "ZTronLPNumerics", "ZTronLPSimplex",
                atomics, heap, orderedCollections, bitCollections,
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Layer 5

        // SolverStrategy facade: Automatic, Portfolio, Conditioned; re-exports every public type.
        .target(
            name: "ZTronLPOptimizer",
            dependencies: [
                "ZTronLPCore", "ZTronLPNumerics", "ZTronLPMetal", "ZTronLPSimplex",
                "ZTronLPInteriorPoint", "ZTronLPBranchAndBound", "ZTronLPCPSAT",
                "ZTronLPConditioning",
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Support

        // MPS fixtures, reference values, random-instance generators, liveness harness.
        .target(
            name: "ZTronLPTestSupport",
            dependencies: ["ZTronLPCore", "ZTronLPNumerics"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),

        // Prints the §14.3 table.
        .executableTarget(
            name: "ZTronLPBenchmarks",
            dependencies: ["ZTronLPOptimizer", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),

        // MARK: Tests — one per library target, plus integration, liveness and compile budget.

        .testTarget(
            name: "ZTronLPCoreTests",
            dependencies: ["ZTronLPCore", "ZTronLPTestSupport"],
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPNumericsTests",
            dependencies: ["ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport", "CLAPACKShim"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPMetalTests",
            dependencies: ["ZTronLPMetal", "ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPSimplexTests",
            dependencies: ["ZTronLPSimplex", "ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPInteriorPointTests",
            dependencies: [
                "ZTronLPInteriorPoint", "ZTronLPSimplex", "ZTronLPNumerics", "ZTronLPCore",
                "ZTronLPTestSupport",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPBranchAndBoundTests",
            dependencies: [
                "ZTronLPBranchAndBound", "ZTronLPSimplex", "ZTronLPInteriorPoint",
                "ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPCPSATTests",
            dependencies: ["ZTronLPCPSAT", "ZTronLPSimplex", "ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPConditioningTests",
            dependencies: ["ZTronLPConditioning", "ZTronLPNumerics", "ZTronLPCore", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPOptimizerTests",
            dependencies: ["ZTronLPOptimizer", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronLPTestSupportTests",
            dependencies: ["ZTronLPTestSupport", "ZTronLPCore"],
            swiftSettings: swiftSettings
        ),
        // Netlib and MIPLIB corpora (§14.1): published optima and cross-engine agreement.
        .testTarget(
            name: "ZTronLPIntegrationTests",
            dependencies: ["ZTronLPOptimizer", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        // Every L-rule of §12.2.
        .testTarget(
            name: "ZTronLPLivenessTests",
            dependencies: ["ZTronLPOptimizer", "ZTronLPTestSupport"],
            swiftSettings: swiftSettings
        ),
        // §4.3 / §14.2: a 40-term operator expression must type-check in under two seconds.
        // The frontend flag turns a slower expression into a warning, and warnings are errors
        // in this target, so exceeding the budget fails the build. (Unsafe flags are confined
        // to this test target; they never reach a product.)
        .testTarget(
            name: "ZTronLPCompileBudgetTests",
            dependencies: ["ZTronLPCore"],
            swiftSettings: swiftSettings + [
                .unsafeFlags([
                    "-Xfrontend", "-warn-long-expression-type-checking=2000",
                    "-Xfrontend", "-warn-long-function-bodies=4000",
                    "-warnings-as-errors",
                ]),
            ]
        ),
    ]
)
