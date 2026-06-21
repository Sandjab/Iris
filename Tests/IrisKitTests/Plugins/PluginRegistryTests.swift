import Logging
import XCTest

@testable import IrisKit

final class PluginRegistryTests: XCTestCase {
    var root: URL!
    var cfgDir: URL!
    var store: ConfigStore!
    let logger = Logger(label: "t")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugins-\(UUID().uuidString)")
        cfgDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugincfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        store = try ConfigStore(
            path: cfgDir.appendingPathComponent("config.json"),
            logger: logger
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cfgDir)
    }

    /// Writes a minimal valid plugin source dir, returns it.
    func writeSource(id: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"""
            { "id": "\#(id)", "name": "Tagger", "version": "1.0.0", "api_version": 1,
              "executable": "run",
              "hooks": [ { "event": "on_request", "match": { "hosts": ["api.anthropic.com"] }, "mutates": true } ],
              "capabilities": { "network": [], "filesystem": ["scratch"] } }
            """#
        try manifest.write(
            to: dir.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\n".write(
            to: dir.appendingPathComponent("run"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    func testInstallThenListReturnsDisabledPlugin() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }

        let installed = try await reg.install(from: src)
        XCTAssertEqual(installed.manifest.id, "org.example.tagger")
        XCTAssertFalse(installed.enabled)
        XCTAssertTrue(installed.hashMatches)
        XCTAssertEqual(installed.displayState, .disabled)

        let list = try await reg.list()
        XCTAssertEqual(list.map(\.manifest.id), ["org.example.tagger"])
        // Persisted in config too.
        let storedIds = await store.plugins().map(\.id)
        XCTAssertEqual(storedIds, ["org.example.tagger"])
    }

    func testInstallRejectsDuplicate() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "dup.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        await XCTAssertThrowsErrorAsync(try await reg.install(from: src)) { error in
            XCTAssertEqual(error as? PluginError, .duplicateId("dup.id"))
        }
    }
}

// Small async-throws assertion helper (place once in the test target if absent).
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error")
    } catch { handler(error) }
}
