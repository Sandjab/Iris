import Foundation
import IrisKit
import Logging
import XCTest

@testable import irisd

/// Unit-level tests for `Daemon.reload()` — exercises the real reload logic
/// (re-read config.json, validate, diff, apply) end-to-end without going through
/// the IPC layer. Uses in-memory secret/CA backends and a temp config.json.
final class DaemonReloadTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(
        proxyPort: Int,
        eventsPort: Int,
        adminSocket: String,
        maxSubs: Int = 60,
        onExfil: ExfilAttemptPolicy = .blockOnly,
        logLevel: LogLevel = .error,
        retentionDays: Int = 1,
        ringSize: Int = 100,
        listenHost: String = "127.0.0.1",
        hosts: [String] = ["api.anthropic.com"]
    ) -> Config {
        Config(
            version: 1,
            broker: BrokerConfig(
                listen: "\(listenHost):\(proxyPort)",
                eventsListen: "127.0.0.1:\(eventsPort)",
                adminSocket: adminSocket,
                logLevel: logLevel,
                eventRetentionDays: retentionDays,
                eventRingSize: ringSize
            ),
            security: SecurityConfig(onExfilAttempt: onExfil, maxSubstitutionsPerMinute: maxSubs),
            backups: BackupsConfig(maxCount: 10),
            hosts: hosts.map {
                HostEntry(host: $0, origin: .user, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            }
        )
    }

    private func write(_ config: Config, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(config).write(to: url)
    }

    /// Boots an ephemeral Daemon backed by a temp config.json, using in-memory
    /// stores and an unbound proxy (Daemon never calls run() in these tests, so
    /// no actual sockets are opened).
    private func makeDaemon(config: Config, configURL: URL) async throws -> Daemon {
        try write(config, to: configURL)
        let configStore = try ConfigStore(path: configURL, logger: Logger(label: "test.daemon.reload"))
        let caURL = configURL.deletingLastPathComponent().appendingPathComponent("ca.pem")
        return try await Daemon(
            configStore: configStore,
            secretBackend: .inMemoryFromEnvironment,
            caBackend: .inMemory,
            caPath: caURL,
            pluginsDirectory: configURL.deletingLastPathComponent().appendingPathComponent("plugins"),
            logger: Logger(label: "test.daemon.reload")
        )
    }

    private func makeTempDir() throws -> URL {
        let tmp = URL(fileURLWithPath: "/tmp/iris-reload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Derive two adjacent ephemeral ports from a short ID. Same trick as
    /// CLIDaemonHarness — collisions vanishingly rare across parallel runs.
    private func ports(from id: String) -> (proxy: Int, events: Int) {
        let seed = id.utf8.reduce(0 as UInt32) { acc, byte in acc &* 31 &+ UInt32(byte) }
        let base = 49152 + Int(seed % 15848)
        return (base, base + 1)
    }

    // MARK: - Tests

    func testReloadHotSwapsSecurityPolicy() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.json")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let daemon = try await makeDaemon(
            config: makeConfig(
                proxyPort: proxyPort,
                eventsPort: eventsPort,
                adminSocket: adminSocket,
                maxSubs: 60,
                onExfil: .blockOnly
            ),
            configURL: configURL
        )

        let before = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(before.maxSubstitutionsPerMinute, 60)
        XCTAssertEqual(before.onExfilAttempt, .blockOnly)

        try write(
            makeConfig(
                proxyPort: proxyPort,
                eventsPort: eventsPort,
                adminSocket: adminSocket,
                maxSubs: 999,
                onExfil: .blockNotifyPause
            ),
            to: configURL
        )

        let result = try await daemon.reload()
        XCTAssertTrue(result.reloaded)
        XCTAssertEqual(result.ignored, [])

        let after = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(after.maxSubstitutionsPerMinute, 999)
        XCTAssertEqual(after.onExfilAttempt, .blockNotifyPause)
    }

    func testReloadOnInvalidJSONLeavesStateIntact() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.json")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let daemon = try await makeDaemon(
            config: makeConfig(
                proxyPort: proxyPort,
                eventsPort: eventsPort,
                adminSocket: adminSocket,
                hosts: ["api.boot.example.com"]
            ),
            configURL: configURL
        )

        let policyBefore = await daemon.proxyForTesting.securityPolicySnapshot()
        let hostsBefore = await daemon.proxyForTesting.allowedHostsSnapshot()

        // Overwrite with garbage. The explicit reload path surfaces the parse
        // failure as an error WITHOUT re-seeding (that only happens at boot).
        try "not valid json &&".write(to: configURL, atomically: true, encoding: .utf8)

        do {
            _ = try await daemon.reload()
            XCTFail("reload should throw on invalid JSON")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.configReloadFailed("x").code)
        } catch {
            XCTFail("expected JSONRPCError, got \(error)")
        }

        let policyAfter = await daemon.proxyForTesting.securityPolicySnapshot()
        let hostsAfter = await daemon.proxyForTesting.allowedHostsSnapshot()
        XCTAssertEqual(policyAfter, policyBefore)
        XCTAssertEqual(hostsAfter, hostsBefore)
    }

    func testReloadIgnoresStructuralFields() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.json")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let daemon = try await makeDaemon(
            config: makeConfig(proxyPort: proxyPort, eventsPort: eventsPort, adminSocket: adminSocket),
            configURL: configURL
        )

        // Rewrite changing ALL 6 structural fields at once.
        let altSocket = tmp.appendingPathComponent("other.sock").path
        try write(
            makeConfig(
                proxyPort: proxyPort + 100,
                eventsPort: eventsPort + 100,
                adminSocket: altSocket,
                logLevel: .debug,
                retentionDays: 30,
                ringSize: 500
            ),
            to: configURL
        )

        let result = try await daemon.reload()
        XCTAssertTrue(result.reloaded)
        let ignored = Set(result.ignored)
        XCTAssertTrue(ignored.contains("broker.listen"))
        XCTAssertTrue(ignored.contains("broker.events_listen"))
        XCTAssertTrue(ignored.contains("broker.admin_socket"))
        XCTAssertTrue(ignored.contains("broker.log_level"))
        XCTAssertTrue(ignored.contains("broker.event_retention_days"))
        XCTAssertTrue(ignored.contains("broker.event_ring_size"))
    }

    func testReloadRefreshesHostsInAllowedSet() async throws {
        // Regression: reload() must apply the NEW host set to the proxy, not the
        // boot-time one.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.json")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let daemon = try await makeDaemon(
            config: makeConfig(
                proxyPort: proxyPort,
                eventsPort: eventsPort,
                adminSocket: adminSocket,
                hosts: ["original.example.com"]
            ),
            configURL: configURL
        )

        let bootHosts = await daemon.proxyForTesting.allowedHostsSnapshot()
        XCTAssertTrue(bootHosts.contains("original.example.com"), "boot hosts=\(bootHosts)")

        try write(
            makeConfig(
                proxyPort: proxyPort,
                eventsPort: eventsPort,
                adminSocket: adminSocket,
                hosts: ["replaced.example.com"]
            ),
            to: configURL
        )
        let result = try await daemon.reload()
        XCTAssertTrue(result.reloaded)

        let afterHosts = await daemon.proxyForTesting.allowedHostsSnapshot()
        XCTAssertTrue(afterHosts.contains("replaced.example.com"), "after-reload hosts=\(afterHosts)")
        XCTAssertFalse(
            afterHosts.contains("original.example.com"),
            "original host must no longer be in allowedHosts after reload; got \(afterHosts)"
        )
    }

    func testReloadRejectsSemanticallyInvalidConfig() async throws {
        // Parses fine, but Config.validate() rejects port 0 → reload must reject
        // BEFORE any swap or diff (atomicity), leaving state intact.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.json")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let daemon = try await makeDaemon(
            config: makeConfig(proxyPort: proxyPort, eventsPort: eventsPort, adminSocket: adminSocket),
            configURL: configURL
        )

        // events_listen port 0 — valid JSON, fails validate().
        try write(
            makeConfig(proxyPort: proxyPort, eventsPort: 0, adminSocket: adminSocket),
            to: configURL
        )

        let policyBefore = await daemon.proxyForTesting.securityPolicySnapshot()

        do {
            _ = try await daemon.reload()
            XCTFail("reload should reject semantically invalid config (port 0)")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.configReloadFailed("x").code)
        } catch {
            XCTFail("expected JSONRPCError.configReloadFailed, got \(error)")
        }

        let policyAfter = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(policyAfter, policyBefore)
    }
}
