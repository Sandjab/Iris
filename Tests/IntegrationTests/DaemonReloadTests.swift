import Foundation
import IrisKit
import Logging
import XCTest

@testable import irisd

/// Unit-level tests for `Daemon.reload()` — exercises the real reload logic
/// (parse, validate, diff, apply) end-to-end without going through the IPC
/// layer. Uses in-memory secret/CA backends and a temp TOML file.
final class DaemonReloadTests: XCTestCase {

    // MARK: - Helpers

    /// Boots an ephemeral Daemon backed by a temp TOML, using in-memory
    /// stores and an unbound proxy (Daemon never calls run() in these tests,
    /// so no actual sockets are opened).
    private func makeDaemon(
        tomlText: String,
        configURL: URL
    ) async throws -> Daemon {
        try tomlText.write(to: configURL, atomically: true, encoding: .utf8)
        let config = try ConfigLoader.load(from: configURL)
        let caURL = configURL.deletingLastPathComponent().appendingPathComponent("ca.pem")
        let logger = Logger(label: "test.daemon.reload")
        return try await Daemon(
            config: config,
            configPath: configURL,
            secretBackend: .inMemoryFromEnvironment,
            caBackend: .inMemory,
            caPath: caURL,
            logger: logger
        )
    }

    private func makeTempDir() throws -> URL {
        let tmp = URL(fileURLWithPath: "/tmp/iris-reload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeToml(
        proxyPort: Int,
        eventsPort: Int,
        adminSocket: String,
        maxSubs: Int = 60,
        onExfil: String = "block_only",
        listenHost: String = "127.0.0.1",
        hosts: [String] = ["api.anthropic.com"]
    ) -> String {
        var lines = [
            "[broker]",
            "listen               = \"\(listenHost):\(proxyPort)\"",
            "events_listen        = \"127.0.0.1:\(eventsPort)\"",
            "admin_socket         = \"\(adminSocket)\"",
            "log_level            = \"error\"",
            "event_retention_days = 1",
            "event_ring_size      = 100",
            "",
            "[security]",
            "on_exfil_attempt             = \"\(onExfil)\"",
            "max_substitutions_per_minute = \(maxSubs)",
            "",
        ]
        for host in hosts {
            lines.append("[[mitm_host]]")
            lines.append("host = \"\(host)\"")
            lines.append("")
        }
        return lines.joined(separator: "\n")
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
        let configURL = tmp.appendingPathComponent("config.toml")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let initialToml = makeToml(
            proxyPort: proxyPort,
            eventsPort: eventsPort,
            adminSocket: adminSocket,
            maxSubs: 60,
            onExfil: "block_only"
        )
        let daemon = try await makeDaemon(tomlText: initialToml, configURL: configURL)

        // Verify boot-time policy.
        let before = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(before.maxSubstitutionsPerMinute, 60)
        XCTAssertEqual(before.onExfilAttempt, .blockOnly)

        // Rewrite TOML with new hot-reloadable values.
        let updated = makeToml(
            proxyPort: proxyPort,
            eventsPort: eventsPort,
            adminSocket: adminSocket,
            maxSubs: 999,
            onExfil: "block_notify_pause"
        )
        try updated.write(to: configURL, atomically: true, encoding: .utf8)

        let result = try await daemon.reload()
        XCTAssertTrue(result.reloaded)
        XCTAssertEqual(result.ignored, [])

        // Verify proxy now reflects the new policy.
        let after = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(after.maxSubstitutionsPerMinute, 999)
        XCTAssertEqual(after.onExfilAttempt, .blockNotifyPause)
    }

    func testReloadOnInvalidTomlLeavesStateIntact() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.toml")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let initialToml = makeToml(
            proxyPort: proxyPort,
            eventsPort: eventsPort,
            adminSocket: adminSocket,
            maxSubs: 60,
            onExfil: "block_only",
            hosts: ["api.boot.example.com"]
        )
        let daemon = try await makeDaemon(tomlText: initialToml, configURL: configURL)

        let policyBefore = await daemon.proxyForTesting.securityPolicySnapshot()
        let hostsBefore = await daemon.proxyForTesting.allowedHostsSnapshot()

        // Overwrite with garbage.
        try "not valid toml &&".write(to: configURL, atomically: true, encoding: .utf8)

        do {
            _ = try await daemon.reload()
            XCTFail("reload should throw on invalid TOML")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.configReloadFailed("x").code)
        } catch {
            XCTFail("expected JSONRPCError, got \(error)")
        }

        // State must be unchanged.
        let policyAfter = await daemon.proxyForTesting.securityPolicySnapshot()
        let hostsAfter = await daemon.proxyForTesting.allowedHostsSnapshot()
        XCTAssertEqual(policyAfter, policyBefore)
        XCTAssertEqual(hostsAfter, hostsBefore)
    }

    func testReloadIgnoresStructuralFields() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.toml")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let initialToml = makeToml(
            proxyPort: proxyPort,
            eventsPort: eventsPort,
            adminSocket: adminSocket
        )
        let daemon = try await makeDaemon(tomlText: initialToml, configURL: configURL)

        // Rewrite TOML changing ALL 6 structural fields at once.
        let altSocket = tmp.appendingPathComponent("other.sock").path
        let mutated = """
            [broker]
            listen               = "127.0.0.1:\(proxyPort + 100)"
            events_listen        = "127.0.0.1:\(eventsPort + 100)"
            admin_socket         = "\(altSocket)"
            log_level            = "debug"
            event_retention_days = 30
            event_ring_size      = 500

            [security]
            on_exfil_attempt             = "block_only"
            max_substitutions_per_minute = 60

            [[mitm_host]]
            host = "api.anthropic.com"
            """
        try mutated.write(to: configURL, atomically: true, encoding: .utf8)

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

    func testReloadRejectsSemanticallyInvalidConfig() async throws {
        // Catches the bug where parse succeeds but semantics are bad.
        // Config.validate() rejects port 0 (`validateListenAddress`).
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("config.toml")
        let adminSocket = tmp.appendingPathComponent("admin.sock").path
        let (proxyPort, eventsPort) = ports(from: tmp.lastPathComponent)

        let initialToml = makeToml(
            proxyPort: proxyPort,
            eventsPort: eventsPort,
            adminSocket: adminSocket
        )
        let daemon = try await makeDaemon(tomlText: initialToml, configURL: configURL)

        // Write TOML that parses fine but fails validate() — port 0.
        // `broker.listen` is a structural field; even if validation didn't
        // catch it, the structural-diff path would just mark it ignored.
        // The semantic check must reject port 0 BEFORE any swap or diff.
        // Using `events_listen` with port 0 — same validator, same rejection.
        let semanticallyInvalid = """
            [broker]
            listen               = "127.0.0.1:\(proxyPort)"
            events_listen        = "127.0.0.1:0"
            admin_socket         = "\(adminSocket)"
            log_level            = "error"
            event_retention_days = 1
            event_ring_size      = 100

            [security]
            on_exfil_attempt             = "block_only"
            max_substitutions_per_minute = 60

            [[mitm_host]]
            host = "api.anthropic.com"
            """
        try semanticallyInvalid.write(to: configURL, atomically: true, encoding: .utf8)

        let policyBefore = await daemon.proxyForTesting.securityPolicySnapshot()

        do {
            _ = try await daemon.reload()
            XCTFail("reload should reject semantically invalid config (port 0)")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.configReloadFailed("x").code)
        } catch {
            XCTFail("expected JSONRPCError.configReloadFailed, got \(error)")
        }

        // State must be unchanged.
        let policyAfter = await daemon.proxyForTesting.securityPolicySnapshot()
        XCTAssertEqual(policyAfter, policyBefore)
    }
}
