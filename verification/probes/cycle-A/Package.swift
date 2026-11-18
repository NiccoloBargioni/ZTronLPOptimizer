// swift-tools-version: 6.0
import PackageDescription

// Probe workspace of skeptical-verification cycle A. Each agent owns one executable slot
// (Slots/<slot>/). Build only that slot: `swift build --product <slot>` (add -c release for
// heavy or timed probes), then run the binary directly: .build/debug/<slot>.
// Public API of ZTronLPOptimizer (the facade re-exports every layer) and ZTronLPTestSupport.
let finders = (1...7).map { "F\($0)" }
let verifiers = (1...240).map { (i: Int) -> String in
    let s = String(i)
    return "V" + String(repeating: "0", count: 3 - s.count) + s
}
let deps: [Target.Dependency] = [
    .product(name: "ZTronLPOptimizer", package: "ZTronLPOptimizer"),
    .product(name: "ZTronLPTestSupport", package: "ZTronLPOptimizer"),
]
let package = Package(
    name: "ProbesA",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../..")],
    targets: (finders + verifiers).map {
        .executableTarget(
            name: $0, dependencies: deps, path: "Slots/\($0)",
            swiftSettings: [.swiftLanguageMode(.v5)])
    }
)
