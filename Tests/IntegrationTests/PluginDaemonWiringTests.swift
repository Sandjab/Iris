import Foundation
import IrisKit
import Logging
import XCTest

@testable import irisd

/// Boots a real Daemon (isolated ephemeral ports + in-memory CA/secrets) with an
/// installed + enabled fixture plugin and asserts the host manager starts it at
/// boot: the fixture writes a scratch marker during the initialize handshake.
/// Proves Daemon → PluginHostManager → PluginHost → sandbox → NDJSON initialize.
final class PluginDaemonWiringTests: XCTestCase {
    /// Two adjacent ephemeral ports derived from the temp id (same trick as
    /// DaemonReloadTests / CLIDaemonHarness — collisions vanishingly rare). Keeps
    /// the boot off the default ports so it never collides with a running irisd.
    private func ports(from id: String) -> (proxy: Int, events: Int) {
        let seed = id.utf8.reduce(0 as UInt32) { acc, byte in acc &* 31 &+ UInt32(byte) }
        let base = 49152 + Int(seed % 15848)
        return (base, base + 1)
    }

    func testDaemonStartsEnabledPluginAtBoot() async throws {
        // Root under /tmp with a short id, NOT FileManager.temporaryDirectory:
        // the daemon binds a real admin socket under `root`, and the macOS
        // sun_path limit (~104 chars) rejects a socket under the long
        // /var/folders/.../T/ temp path with `unixDomainSocketPathTooLong`.
        let root = URL(fileURLWithPath: "/tmp/iris-wire-\(UUID().uuidString.prefix(8))")
        let pluginsDir = root.appendingPathComponent("plugins")
        let scratch = root.appendingPathComponent("scratch")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Install + enable a fixture plugin (run.sh launcher → fixture "ok" mode).
        let bin = source.appendingPathComponent("bin")
        try FileManager.default.copyItem(at: ExecutableLocator.testPlugin, to: bin)
        let launcher = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexec \"$(dirname \"$0\")/bin\" ok\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        let manifest = """
            { "id": "test.wire.plugin", "name": "Wire Fixture", "version": "1.0.0",
              "api_version": 1, "executable": "run.sh",
              "hooks": [ { "event": "on_request", "match": {}, "timeout_ms": 200 } ],
              "capabilities": { "network": [], "filesystem": [] } }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        // Isolated config: ephemeral ports + a unique admin socket under `root`,
        // so the daemon boot never collides with a developer's running irisd.
        let (proxyPort, eventsPort) = ports(from: root.lastPathComponent)
        let adminSocket = root.appendingPathComponent("admin.sock").path
        let config = Config(
            version: 1,
            broker: BrokerConfig(
                listen: "127.0.0.1:\(proxyPort)",
                eventsListen: "127.0.0.1:\(eventsPort)",
                adminSocket: adminSocket,
                logLevel: .error,
                eventRetentionDays: 1,
                eventRingSize: 100
            ),
            security: SecurityConfig(onExfilAttempt: .blockOnly, maxSubstitutionsPerMinute: 60),
            backups: BackupsConfig(maxCount: 10),
            hosts: [
                HostEntry(
                    host: "api.anthropic.com",
                    origin: .user,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
        let configPath = root.appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configPath)

        let store = try ConfigStore(path: configPath, logger: Logger(label: "test"))
        let registry = PluginRegistry(
            pluginsDirectory: pluginsDir,
            configStore: store,
            logger: Logger(label: "test")
        )
        _ = try await registry.install(from: source)
        _ = try await registry.enable(id: "test.wire.plugin")

        let daemon = try await Daemon(
            configStore: store,
            secretBackend: .inMemoryFromEnvironment,
            caBackend: .inMemory,
            caPath: root.appendingPathComponent("ca.pem"),
            pluginsDirectory: pluginsDir,
            sandboxExecPath: ExecutableLocator.sandboxExec,
            scratchRoot: scratch,
            logger: Logger(label: "test")
        )

        let runTask = Task { try await daemon.run() }
        defer { runTask.cancel() }

        let marker = scratch.appendingPathComponent("test.wire.plugin/initialized")
        var started = false
        for _ in 0..<160 {  // up to 8s
            if FileManager.default.fileExists(atPath: marker.path) {
                started = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await daemon.stop()
        XCTAssertTrue(started, "daemon should have started the enabled plugin and run initialize")
    }
}
