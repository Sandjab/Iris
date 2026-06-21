import Logging
import XCTest

@testable import IrisKit

final class ConfigPluginsTests: XCTestCase {
    var tmpDir: URL!
    var path: URL!
    let logger = Logger(label: "t")

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-cfg-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        path = tmpDir.appendingPathComponent("config.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testDefaultConfigHasEmptyPlugins() {
        XCTAssertTrue(Config.default.plugins.isEmpty)
    }

    func testDecodesLegacyConfigWithoutPluginsKey() throws {
        // A config.json written before the plugins feature has no `plugins` key.
        let legacy = #"""
            { "version": 1,
              "broker": { "listen": "127.0.0.1:8888", "events_listen": "127.0.0.1:8899",
                          "admin_socket": "~/x.sock", "log_level": "info",
                          "event_retention_days": 7, "event_ring_size": 10000 },
              "security": { "on_exfil_attempt": "block_and_notify", "max_substitutions_per_minute": 60 },
              "backups": { "max_count": 10 },
              "hosts": [] }
            """#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let cfg = try d.decode(Config.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.plugins, [])
    }

    func testSetPluginsPersistsAndReloads() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let entry = PluginStateEntry(
            id: "org.example.tagger",
            enabled: true,
            order: 0,
            approvedCapabilities: PluginCapabilities(network: [], filesystem: ["scratch"]),
            pinnedHash: "abc123",
            configValues: ["mode": "fast"]
        )
        try await store.setPlugins([entry])
        let reloaded = try await ConfigStore(path: path, logger: logger).current
        XCTAssertEqual(reloaded.plugins, [entry])
    }
}
