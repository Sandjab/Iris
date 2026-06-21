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

    func testInstallRejectsSourceWithSymlink() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "sym.id")
        defer { try? FileManager.default.removeItem(at: src) }
        try FileManager.default.createSymbolicLink(
            at: src.appendingPathComponent("evil"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        await assertThrowsAsyncError(try await reg.install(from: src)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
        // Nothing committed, nothing copied.
        let count = await store.plugins().count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sym.id").path))
    }

    func testInstallRejectsDuplicate() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "dup.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        await assertThrowsAsyncError(try await reg.install(from: src)) { error in
            XCTAssertEqual(error as? PluginError, .duplicateId("dup.id"))
        }
    }

    func testListReportsNeedsReapprovalAfterTamper() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)

        // Tamper with the installed copy after the pin.
        let runFile = root.appendingPathComponent("org.example.tagger/run")
        try "#!/bin/sh\necho tampered\n".write(to: runFile, atomically: true, encoding: .utf8)

        let list = try await reg.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertFalse(list[0].hashMatches)
        XCTAssertEqual(list[0].displayState, .needsReapproval)
    }

    func testListSkipsBrokenManifest() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)

        // Corrupt the installed manifest: the entry stays in config but no longer loads.
        let manifestFile = root.appendingPathComponent("org.example.tagger/plugin.json")
        try "{ not json".write(to: manifestFile, atomically: true, encoding: .utf8)

        let list = try await reg.list()
        XCTAssertEqual(list, [])
    }

    func testInfoThrowsUnknownPlugin() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        await assertThrowsAsyncError(try await reg.info(id: "nope")) { error in
            XCTAssertEqual(error as? PluginError, .unknownPlugin("nope"))
        }
    }

    func testEnableApprovesCapabilitiesAndSetsFlag() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)

        let enabled = try await reg.enable(id: "org.example.tagger")
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.displayState, .enabled)
        // Declared capabilities are now the approved ones.
        XCTAssertEqual(enabled.approvedCapabilities, PluginCapabilities(network: [], filesystem: ["scratch"]))
    }

    func testEnableThrowsOnHashMismatch() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        // Tamper with the installed copy after the pin.
        let runFile = root.appendingPathComponent("org.example.tagger/run")
        try "#!/bin/sh\necho tampered\n".write(to: runFile, atomically: true, encoding: .utf8)

        await assertThrowsAsyncError(try await reg.enable(id: "org.example.tagger")) { error in
            XCTAssertEqual(error as? PluginError, .hashMismatch("org.example.tagger"))
        }
    }

    func testDisable() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "p.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        _ = try await reg.enable(id: "p.id")
        let disabled = try await reg.disable(id: "p.id")
        XCTAssertFalse(disabled.enabled)
        // Approved capabilities survive a disable (only the flag flips).
        XCTAssertEqual(disabled.approvedCapabilities, PluginCapabilities(network: [], filesystem: ["scratch"]))
    }

    func testEnableAfterDisable() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "p.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        _ = try await reg.enable(id: "p.id")
        _ = try await reg.disable(id: "p.id")
        let reEnabled = try await reg.enable(id: "p.id")
        XCTAssertTrue(reEnabled.enabled)
        XCTAssertEqual(reEnabled.approvedCapabilities, PluginCapabilities(network: [], filesystem: ["scratch"]))
    }

    func testRemoveDeletesDirAndState() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "p.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        try await reg.remove(id: "p.id")
        let remainingCount = await store.plugins().count
        XCTAssertEqual(remainingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("p.id").path))
    }

    func testReorderRenumbersByPosition() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        for id in ["a.1", "a.2", "a.3"] {
            let src = try writeSource(id: id)
            _ = try await reg.install(from: src)
            try? FileManager.default.removeItem(at: src)
        }
        // Move a.3 to the front.
        let reordered = try await reg.reorder(id: "a.3", to: 0)
        XCTAssertEqual(reordered.map(\.manifest.id), ["a.3", "a.1", "a.2"])
        XCTAssertEqual(reordered.map(\.order), [0, 1, 2])
    }

    func testEnableRejectsUnsafeId() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        await assertThrowsAsyncError(try await reg.enable(id: "../../etc")) { error in
            XCTAssertEqual(error as? PluginError, .unknownPlugin("../../etc"))
        }
    }

    func testEnableRejectsUnknownButValidId() async throws {
        // A well-formed id that simply isn't installed must surface a clean
        // `unknownPlugin`, never a filesystem `ioError` (which would leak the
        // plugins-directory path) — uniform with `info`/`disable`.
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        await assertThrowsAsyncError(try await reg.enable(id: "org.not.installed")) { error in
            XCTAssertEqual(error as? PluginError, .unknownPlugin("org.not.installed"))
        }
    }

    func testCachedHashStillDetectsTamperAfterCleanListing() async throws {
        // A first listing primes the per-id hash cache with a matching digest. A
        // later tamper must still flip hashMatches — the cache is keyed on a
        // stat-only signature that moves when the tree changes (#9), so it cannot
        // return a stale "matches". A naive id-only cache would fail this.
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "cache.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)

        let first = try await reg.list()
        XCTAssertTrue(first[0].hashMatches)  // primes the cache

        let runFile = root.appendingPathComponent("cache.id/run")
        try "#!/bin/sh\necho tampered\n".write(to: runFile, atomically: true, encoding: .utf8)

        let second = try await reg.list()
        XCTAssertFalse(second[0].hashMatches)
    }

    func testInfoRejectsUnsafeIdInConfigWithoutLeakingPath() async throws {
        // Inject a path-traversing id directly into persisted state (simulating a
        // hand-edited config.json). Deriving a filesystem path from it must be
        // refused centrally in directory(for:) — a clean invalidManifest, never a
        // filesystem ioError whose message echoes the derived path.
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        _ = try await store.updatePlugins { _ in
            [
                PluginStateEntry(
                    id: "../../etc",
                    enabled: false,
                    order: 0,
                    approvedCapabilities: nil,
                    pinnedHash: "x",
                    configValues: [:]
                )
            ]
        }
        await assertThrowsAsyncError(try await reg.info(id: "../../etc")) { error in
            XCTAssertEqual(error as? PluginError, .invalidManifest("invalid id: ../../etc"))
        }
    }

    func testRemoveRejectsUnsafeIdAsUnknown() async throws {
        // A path-traversing id that isn't installed surfaces unknownPlugin (the
        // appartenance check precedes any path derivation), uniform with enable.
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        await assertThrowsAsyncError(try await reg.remove(id: "../../etc")) { error in
            XCTAssertEqual(error as? PluginError, .unknownPlugin("../../etc"))
        }
    }

    func testReorderClampsPastEnd() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        for id in ["a.1", "a.2", "a.3"] {
            let src = try writeSource(id: id)
            _ = try await reg.install(from: src)
            try? FileManager.default.removeItem(at: src)
        }
        // Target index past the end is clamped to the last slot.
        let reordered = try await reg.reorder(id: "a.1", to: 99)
        XCTAssertEqual(reordered.map(\.manifest.id), ["a.2", "a.3", "a.1"])
        XCTAssertEqual(reordered.map(\.order), [0, 1, 2])
    }
}

// Small async-throws assertion helper (place once in the test target if absent).
func assertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error")
    } catch { handler(error) }
}
