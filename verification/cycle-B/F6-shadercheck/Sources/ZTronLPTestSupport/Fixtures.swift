// Corpus access (specification §14.1).
//
// The netlib LP instances are bundled with this target as MPS. The MIPLIB 3 and SATLIB
// instances are not bundled: `Scripts/fetch-miplib.sh` and `Scripts/fetch-satlib.sh` download
// them (with pinned SHA-256 checksums) into `.corpora/` at the package root, and the tests
// that need them are skipped when the directory is absent.

import Foundation
import ZTronLPCore

public enum NetlibFixtures {
    /// The names of the bundled instances, in the order of the specification's table.
    public static var names: [String] { ReferenceValues.netlib.map(\.name) }

    /// The URL of a bundled instance.
    public static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "mps", subdirectory: "Fixtures/netlib")
    }

    /// Parses a bundled instance.
    public static func load(_ name: String) throws -> CompiledLP {
        guard let url = url(name) else {
            throw SolverError.unsupported("netlib fixture '\(name)' is not bundled")
        }
        return try MPSFormat.read(contentsOf: url)
    }

    /// The text of the netlib README the reference values were verified against.
    public static func readme() -> String? {
        guard let url = Bundle.module.url(forResource: "README.netlib", withExtension: "txt", subdirectory: "Fixtures/netlib"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// Corpora that are fetched by a script instead of being bundled.
public enum Corpora {
    /// The directory the fetch scripts write to: `$ZTRONLP_CORPORA` when set, otherwise
    /// `.corpora` at the package root (found from this source file's location).
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["ZTRONLP_CORPORA"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // …/Sources/ZTronLPTestSupport/Fixtures.swift → package root is three levels up.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".corpora", isDirectory: true)
    }

    /// The URL of a fetched MIPLIB 3 instance, or `nil` when it has not been fetched.
    public static func miplib3(_ name: String) -> URL? {
        let url = root.appendingPathComponent("miplib3", isDirectory: true).appendingPathComponent("\(name).mps")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Parses a fetched MIPLIB 3 instance; `nil` when it has not been fetched.
    public static func loadMIPLIB3(_ name: String) throws -> CompiledLP? {
        guard let url = miplib3(name) else { return nil }
        return try MPSFormat.read(contentsOf: url)
    }

    /// The fetched files of a SATLIB family (`uf50-218`, `uuf50-218`), sorted by name; empty
    /// when the family has not been fetched.
    public static func satlib(_ family: String) -> [URL] {
        let directory = root.appendingPathComponent("satlib", isDirectory: true).appendingPathComponent(family, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents.filter { $0.pathExtension == "cnf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
