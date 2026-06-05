import Foundation
import IrisKit
import XCTest

/// Integration tests for `iris config reload` against a live ephemeral daemon.
final class CLIConfigReloadTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    // MARK: - Round-trip

    func testConfigReloadExitsZeroAndReportsReloadedTrue() throws {
        let result = try harness.runIris(["config", "reload"])
        XCTAssertEqual(result.code, 0, "config reload should exit 0\nstderr=\(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("reloaded: true"),
            "stdout should contain 'reloaded: true', got: \(result.stdout)"
        )
    }

    func testConfigReloadJsonOutputIsWellFormed() throws {
        let result = try harness.runIris(["config", "reload", "--json"])
        XCTAssertEqual(result.code, 0, "config reload --json should exit 0\nstderr=\(result.stderr)")

        // Verify we can round-trip the output as ConfigReloadResult JSON.
        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(ConfigReloadResult.self, from: data)
        XCTAssertTrue(decoded.reloaded)
    }

    func testConfigReloadWithIgnoredFieldWarnsOnStderr() throws {
        // Modify config.json on disk to change broker.listen (structural field).
        let original = try String(contentsOfFile: harness.configPath, encoding: .utf8)
        let modified = original.replacingOccurrences(
            of: "127.0.0.1:\(harness.brokerPort)",
            with: "127.0.0.1:19999"
        )
        XCTAssertNotEqual(modified, original, "listen value should be present to edit")
        try modified.write(toFile: harness.configPath, atomically: true, encoding: .utf8)

        let result = try harness.runIris(["config", "reload"])
        XCTAssertEqual(result.code, 0, "should exit 0 even with ignored changes\nstderr=\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("broker.listen"),
            "stderr should mention ignored field 'broker.listen', got: \(result.stderr)"
        )
    }

    func testConfigReloadHotReloadsSecurityPolicy() throws {
        // Change max_substitutions_per_minute in config.json (hot-reloadable).
        let original = try String(contentsOfFile: harness.configPath, encoding: .utf8)
        let modified = original.replacingOccurrences(
            of: "\"max_substitutions_per_minute\": 60",
            with: "\"max_substitutions_per_minute\": 7"
        )
        XCTAssertNotEqual(modified, original, "max_substitutions_per_minute value should be present to edit")
        try modified.write(toFile: harness.configPath, atomically: true, encoding: .utf8)

        let reload = try harness.runIris(["config", "reload", "--json"])
        XCTAssertEqual(reload.code, 0, "reload should succeed\nstderr=\(reload.stderr)")

        let decoded = try JSONDecoder().decode(
            ConfigReloadResult.self,
            from: Data(reload.stdout.utf8)
        )
        XCTAssertTrue(decoded.reloaded)
        XCTAssertFalse(
            decoded.ignored.contains("security.max_substitutions_per_minute"),
            "hot-reloadable field should not appear in ignored list"
        )

        // Confirm the new value actually took effect.
        let get = try harness.runIris(["config", "get"])
        XCTAssertTrue(
            get.stdout.contains("max_substitutions_per_minute = 7"),
            "hot reload should apply the new value, got: \(get.stdout)"
        )
    }
}
