import Foundation
import IrisKit
import XCTest

/// Integration tests for `iris config set` against a live ephemeral daemon.
final class CLIConfigSetTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    func testConfigSetHotFieldAppliedAndVisibleInGet() throws {
        let set = try harness.runIris(["config", "set", "security.max_substitutions_per_minute", "30"])
        XCTAssertEqual(set.code, 0, "config set should exit 0\nstderr=\(set.stderr)")
        XCTAssertTrue(
            set.stdout.contains("applied"),
            "stdout should report the applied key, got: \(set.stdout)"
        )

        // The change is persisted and reflected by config.get.
        let get = try harness.runIris(["config", "get"])
        XCTAssertEqual(get.code, 0, "config get failed\nstderr=\(get.stderr)")
        XCTAssertTrue(
            get.stdout.contains("max_substitutions_per_minute = 30"),
            "config get should show the new value, got: \(get.stdout)"
        )
    }

    func testConfigSetStructuralFieldReportsRequiresRestart() throws {
        let set = try harness.runIris(["config", "set", "broker.event_ring_size", "500", "--json"])
        XCTAssertEqual(set.code, 0, "config set --json should exit 0\nstderr=\(set.stderr)")
        let result = try JSONDecoder().decode(ConfigSetResult.self, from: Data(set.stdout.utf8))
        XCTAssertEqual(result.requiresRestart, ["broker.event_ring_size"])
        XCTAssertTrue(result.applied.isEmpty, "structural field must not be reported as applied")
    }

    func testConfigSetUnknownKeyFails() throws {
        let set = try harness.runIris(["config", "set", "broker.nope", "x"])
        XCTAssertNotEqual(set.code, 0, "unknown key must fail")
    }

    func testConfigSetInvalidValueFails() throws {
        // max_substitutions_per_minute = 0 parses but fails Config.validate().
        let set = try harness.runIris(["config", "set", "security.max_substitutions_per_minute", "0"])
        XCTAssertNotEqual(set.code, 0, "invalid value must fail")
    }
}
