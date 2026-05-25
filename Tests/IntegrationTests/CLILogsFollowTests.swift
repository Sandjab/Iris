import XCTest

final class CLILogsFollowTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    func testLogsOneShotEmpty() throws {
        let result = try harness.runIris(["logs"])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("no events"), "stdout=\(result.stdout)")
    }

    func testLogsOneShotJSONIsValidEmptyArray() throws {
        let result = try harness.runIris(["logs", "--json"])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let data = result.stdout.data(using: .utf8) ?? Data()
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(parsed, "stdout was not valid JSON array: \(result.stdout)")
        XCTAssertEqual(parsed?.count, 0)
    }

    func testLogsFollowIncompatibleWithSince() throws {
        let result = try harness.runIris(["logs", "--follow", "--since", "5m"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(
            result.stderr.contains("incompatible") || result.stderr.contains("--follow"),
            "stderr=\(result.stderr)"
        )
    }

    func testLogsFollowIncompatibleWithLimit() throws {
        let result = try harness.runIris(["logs", "--follow", "--limit", "10"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(
            result.stderr.contains("incompatible") || result.stderr.contains("--follow"),
            "stderr=\(result.stderr)"
        )
    }

    func testLogsInvalidKindRejected() throws {
        let result = try harness.runIris(["logs", "--kind", "bogus"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(
            result.stderr.contains("unknown event kind") || result.stderr.contains("bogus"),
            "stderr=\(result.stderr)"
        )
    }

    func testLogsInvalidSinceRejected() throws {
        let result = try harness.runIris(["logs", "--since", "5x"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(
            result.stderr.contains("Invalid time spec") || result.stderr.contains("5x"),
            "stderr=\(result.stderr)"
        )
    }
}
