// MetalContext (specification §3, §6.4).
//
// The device-level state of the optional GPU tier: the device, one command queue and the two
// compute pipelines. Design rules of the tier:
//
//   * the context is created lazily, on the first kernel request;
//   * `MTLCreateSystemDefaultDevice()` returning nil (CI without a GPU, some simulators)
//     silently disables the tier;
//   * the shaders come from default.metallib when Xcode built the package, and are compiled
//     from the bundled source file at first use when a command-line build copied it instead;
//     if neither works the tier is disabled;
//   * nothing here ever blocks a cooperative-pool thread: library and pipeline creation use
//     Metal's asynchronous entry points, and kernels await command-buffer completion through
//     a continuation.

import Foundation
import Metal

/// Whether the GPU tier can be used, and if not, why.
public enum MetalTierStatus: Sendable, Hashable {
    /// The kernels are loaded and ready on the named device.
    case ready(device: String, library: MetalContext.LibrarySource)
    /// There is no Metal device.
    case noDevice
    /// A device exists but the kernels could not be loaded or compiled; the string says why.
    case libraryUnavailable(String)

    /// True for `.ready`.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Where the tier takes its device from.
enum MetalDeviceChoice: Sendable {
    /// `MTLCreateSystemDefaultDevice()`, asked at first use.
    case systemDefault
    /// A device supplied by the caller; `nil` stands for a machine without one.
    case explicit((any MTLDevice)?)
}

/// The device, command queue and compute pipelines of the GPU tier.
///
/// Every stored property is an immutable reference to a thread-safe Metal object, so the
/// context is shared freely between kernels and workers. Buffers are not part of it: each
/// kernel actor owns its own.
public final class MetalContext: Sendable {
    /// How the shader library was obtained.
    public enum LibrarySource: Sendable, Hashable {
        /// default.metallib, compiled by Xcode from the target's shader file.
        case precompiled
        /// The shader source file copied into the resource bundle, compiled at first use.
        case compiledFromSource
    }

    public let device: any MTLDevice
    public let librarySource: LibrarySource
    let queue: any MTLCommandQueue
    let scanPipeline: any MTLComputePipelineState
    let activityPipeline: any MTLComputePipelineState

    private init(
        device: any MTLDevice, librarySource: LibrarySource, queue: any MTLCommandQueue,
        scanPipeline: any MTLComputePipelineState, activityPipeline: any MTLComputePipelineState
    ) {
        self.device = device
        self.librarySource = librarySource
        self.queue = queue
        self.scanPipeline = scanPipeline
        self.activityPipeline = activityPipeline
    }

    /// The names of the two kernel functions in the shader library.
    static let scanFunction = "reducedCostScan"
    static let activityFunction = "batchedActivity"

    /// Builds the context, or reports why the tier is unavailable. Never throws and never traps.
    static func make(_ choice: MetalDeviceChoice) async -> (context: MetalContext?, status: MetalTierStatus) {
        let device: (any MTLDevice)?
        switch choice {
        case .systemDefault: device = MTLCreateSystemDefaultDevice()
        case .explicit(let supplied): device = supplied
        }
        guard let device else { return (nil, .noDevice) }

        let loaded = await loadLibrary(device: device)
        guard let library = loaded.library else {
            return (nil, .libraryUnavailable(loaded.failure))
        }
        guard let scan = library.makeFunction(name: scanFunction),
              let activity = library.makeFunction(name: activityFunction)
        else {
            return (nil, .libraryUnavailable("the shader library does not contain both kernels"))
        }
        guard let queue = device.makeCommandQueue() else {
            return (nil, .libraryUnavailable("the device could not create a command queue"))
        }
        do {
            let scanPipeline = try await device.makeComputePipelineState(function: scan)
            let activityPipeline = try await device.makeComputePipelineState(function: activity)
            let context = MetalContext(
                device: device, librarySource: loaded.source, queue: queue, scanPipeline: scanPipeline,
                activityPipeline: activityPipeline)
            return (context, .ready(device: device.name, library: loaded.source))
        } catch {
            return (nil, .libraryUnavailable("pipeline creation failed: \(error.localizedDescription)"))
        }
    }

    /// default.metallib first, then the bundled source file.
    private static func loadLibrary(
        device: any MTLDevice
    ) async -> (library: (any MTLLibrary)?, source: LibrarySource, failure: String) {
        guard let bundle = ShaderResources.bundle else {
            return (nil, .compiledFromSource, "the ZTronLPMetal resource bundle was not found")
        }
        if let precompiled = try? device.makeDefaultLibrary(bundle: bundle),
           precompiled.functionNames.contains(scanFunction)
        {
            return (precompiled, .precompiled, "")
        }
        guard let source = ShaderResources.source(in: bundle) else {
            return (nil, .compiledFromSource, "the bundle holds neither default.metallib nor Kernels.metal")
        }
        do {
            let compiled = try await device.makeLibrary(source: source, options: nil)
            return (compiled, .compiledFromSource, "")
        } catch {
            return (nil, .compiledFromSource, "shader compilation failed: \(error.localizedDescription)")
        }
    }
}

/// Finds the target's resources without the package-generated bundle accessor, which traps
/// when the bundle is missing. A missing bundle must only disable the tier.
enum ShaderResources {
    private final class Anchor {}

    /// The resource bundle SwiftPM builds for this target, or `nil` when it cannot be found.
    static var bundle: Bundle? {
        let exactName = "ZTronLPOptimizer_ZTronLPMetal.bundle"
        let codeBundle = Bundle(for: Anchor.self)
        // The places SwiftPM puts a target's resource bundle: inside an app, inside a
        // framework or test bundle, next to a command-line tool.
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            codeBundle.resourceURL,
            Bundle.main.bundleURL,
            codeBundle.bundleURL,
            codeBundle.bundleURL.deletingLastPathComponent(),
        ]
        for case let base? in candidates {
            if let found = Bundle(url: base.appendingPathComponent(exactName)) { return found }
        }
        // The bundle is named <package>_<target>; tolerate a different package name.
        for case let base? in candidates {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { continue }
            for name in names.sorted() where name.hasSuffix("_ZTronLPMetal.bundle") {
                if let found = Bundle(url: base.appendingPathComponent(name)) { return found }
            }
        }
        return nil
    }

    /// The URL of the shader source file a command-line build copied into the bundle: under
    /// `Shaders/` (the directory is copied as it is) or at the bundle root.
    static func sourceURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "Kernels", withExtension: "metal", subdirectory: "Shaders")
            ?? bundle.url(forResource: "Kernels", withExtension: "metal")
    }

    /// The text of the bundled shader source file.
    static func source(in bundle: Bundle) -> String? {
        guard let url = sourceURL(in: bundle), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True when the bundle carries a library Xcode compiled.
    static func hasPrecompiledLibrary(in bundle: Bundle) -> Bool {
        bundle.url(forResource: "default", withExtension: "metallib") != nil
    }
}
