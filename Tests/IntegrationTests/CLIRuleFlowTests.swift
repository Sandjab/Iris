import Foundation
import IrisKit
import XCTest

/// Integration tests for `iris rule add / list / rm` against a live ephemeral daemon.
final class CLIRuleFlowTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    // MARK: - Round-trip

    func testRuleAddListRm() throws {
        // add
        let add = try harness.runIris(["rule", "add", "api.runtime.example.com"])
        XCTAssertEqual(add.code, 0, "rule add failed\nstderr=\(add.stderr)")
        XCTAssertTrue(
            add.stdout.contains("api.runtime.example.com"),
            "add stdout should show the new host, got: \(add.stdout)"
        )

        // list (text) — should contain both TOML host and new runtime host
        let listTxt = try harness.runIris(["rule", "list"])
        XCTAssertEqual(listTxt.code, 0, "rule list failed\nstderr=\(listTxt.stderr)")
        XCTAssertTrue(listTxt.stdout.contains("api.anthropic.com"), "TOML host missing from list")
        XCTAssertTrue(listTxt.stdout.contains("api.runtime.example.com"), "runtime host missing from list")
        XCTAssertTrue(listTxt.stdout.contains("toml"), "TOML source label missing")
        XCTAssertTrue(listTxt.stdout.contains("runtime"), "runtime source label missing")

        // list (JSON)
        let listJSON = try harness.runIris(["rule", "list", "--json"])
        XCTAssertEqual(listJSON.code, 0, "rule list --json failed\nstderr=\(listJSON.stderr)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rules = try decoder.decode([MITMRule].self, from: Data(listJSON.stdout.utf8))
        let hosts = rules.map(\.host).sorted()
        XCTAssertTrue(hosts.contains("api.anthropic.com"), "TOML host missing from JSON list")
        XCTAssertTrue(hosts.contains("api.runtime.example.com"), "runtime host missing from JSON list")

        // rm
        let rm = try harness.runIris(["rule", "rm", "api.runtime.example.com"])
        XCTAssertEqual(rm.code, 0, "rule rm failed\nstderr=\(rm.stderr)")

        // list after rm — runtime host should be gone, TOML host remains
        let listAfter = try harness.runIris(["rule", "list", "--json"])
        XCTAssertEqual(listAfter.code, 0)
        let rulesAfter = try decoder.decode([MITMRule].self, from: Data(listAfter.stdout.utf8))
        XCTAssertFalse(
            rulesAfter.map(\.host).contains("api.runtime.example.com"),
            "runtime host should be absent after rm"
        )
        XCTAssertTrue(
            rulesAfter.map(\.host).contains("api.anthropic.com"),
            "TOML host must survive rm of a different host"
        )
    }

    // MARK: - TOML rule protection

    func testRuleRmTomlRefused() throws {
        let result = try harness.runIris(["rule", "rm", "api.anthropic.com"])
        XCTAssertNotEqual(result.code, 0, "removing a TOML rule must fail")
        XCTAssertTrue(
            result.stderr.contains("config TOML") || result.stderr.contains("edit the file directly"),
            "stderr should explain TOML-rule protection, got: \(result.stderr)"
        )
    }

    // MARK: - Persistence across daemon restart

    func testRulePersistsAcrossDaemonRestart() throws {
        _ = try harness.runIris(["rule", "add", "api.persistent.example.com"])

        harness.stopDaemon()
        try harness.restartDaemon()

        let listResult = try harness.runIris(["rule", "list", "--json"])
        XCTAssertEqual(listResult.code, 0, "rule list failed after restart\nstderr=\(listResult.stderr)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rules = try decoder.decode([MITMRule].self, from: Data(listResult.stdout.utf8))
        XCTAssertTrue(
            rules.contains(where: {
                $0.host == "api.persistent.example.com" && $0.source == .runtime
            }),
            "runtime rule should survive daemon restart; got hosts: \(rules.map(\.host))"
        )
    }

    // MARK: - Not-found error

    func testRuleRmNotFoundReturnsNonZero() throws {
        let result = try harness.runIris(["rule", "rm", "api.nonexistent.example.com"])
        XCTAssertNotEqual(result.code, 0, "removing a non-existent rule must fail")
        XCTAssertTrue(
            result.stderr.contains("not found"),
            "stderr should mention 'not found', got: \(result.stderr)"
        )
    }
}
