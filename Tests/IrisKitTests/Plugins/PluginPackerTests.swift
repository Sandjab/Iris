import XCTest

@testable import IrisKit

final class PluginPackerTests: XCTestCase {
    private func makeDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Source tree whose plugin.json executable points THROUGH a symlinked build
    /// dir, mirroring SwiftPM's `.build/release` layout: `.build/release` is a
    /// symlink to `.build/real-bin`, so `.build/release/tool` resolves to a real
    /// file. The whole tree is unsafe for the installer; pack must flatten it.
    private func makeSourceWithSymlinkedExecutable() throws -> URL {
        let source = try makeDir("packsrc")
        let realBin = source.appendingPathComponent(".build/real-bin")
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi\n".write(
            to: realBin.appendingPathComponent("tool"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent(".build/release"),
            withDestinationURL: realBin
        )
        let manifest = """
            {
              "id": "com.example.tool",
              "name": "Tool",
              "version": "1.0.0",
              "api_version": 1,
              "executable": ".build/release/tool",
              "hooks": [
                { "event": "on_request",
                  "match": { "hosts": ["api.example.com"], "methods": ["POST"] },
                  "mutates": true, "on_failure": "skip", "timeout_ms": 100 }
              ],
              "capabilities": {}
            }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        return source
    }

    func testPackProducesInstallableBundle() throws {
        let source = try makeSourceWithSymlinkedExecutable()
        defer { try? FileManager.default.removeItem(at: source) }

        let bundle = try PluginPacker.pack(
            source: source,
            output: source.appendingPathComponent("dist"),
            force: false
        )

        // executable rewritten to basename, binary copied flat
        let bundled = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: bundle.appendingPathComponent("plugin.json"))
        )
        XCTAssertEqual(bundled.executable, "tool")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("tool").path)
        )

        // the bundle satisfies the installer's own validator (no symlinks survive)
        XCTAssertNoThrow(try PluginSourceValidator.validate(directory: bundle))
    }

    func testPackRefusesNonEmptyOutputWithoutForce() throws {
        let source = try makeSourceWithSymlinkedExecutable()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = source.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "stale".write(
            to: output.appendingPathComponent("old"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try PluginPacker.pack(source: source, output: output, force: false)) {
            error in
            guard case PluginError.ioError = error else {
                return XCTFail("expected ioError, got \(error)")
            }
        }
        // --force overwrites cleanly: the stale file is gone
        let bundle = try PluginPacker.pack(source: source, output: output, force: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("old").path)
        )
    }

    func testPackFailsWhenExecutableMissing() throws {
        let source = try makeDir("packsrc")
        defer { try? FileManager.default.removeItem(at: source) }
        let manifest = """
            {
              "id": "com.example.tool", "name": "Tool", "version": "1.0.0",
              "api_version": 1, "executable": "nope/tool",
              "hooks": [ { "event": "on_request", "match": { "hosts": ["api.example.com"] },
                          "mutates": true, "on_failure": "skip", "timeout_ms": 100 } ],
              "capabilities": {}
            }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try PluginPacker.pack(
                source: source,
                output: source.appendingPathComponent("dist"),
                force: false
            )
        ) { error in
            guard case PluginError.ioError = error else {
                return XCTFail("expected ioError, got \(error)")
            }
        }
    }
}
