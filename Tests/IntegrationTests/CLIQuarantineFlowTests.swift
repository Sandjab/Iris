import XCTest

final class CLIQuarantineFlowTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    func testQuarantineUnquarantineRoundTrip() throws {
        let secretValue = "sk-QUAR-TEST-cafef00d"
        let add = try harness.runIris(
            ["secret", "add", "foo", "--allowed-hosts", "api.x.com", "--value-from-stdin"],
            stdin: Data((secretValue + "\n").utf8)
        )
        XCTAssertEqual(add.code, 0, "add failed\n\(add.stderr)")

        let quar = try harness.runIris(["secret", "quarantine", "foo"])
        XCTAssertEqual(quar.code, 0, "quarantine failed\n\(quar.stderr)")

        let showJSON = try harness.runIris(["secret", "show", "foo", "--json"])
        XCTAssertEqual(showJSON.code, 0)
        XCTAssertTrue(
            showJSON.stdout.contains("\"quarantined\":true") || showJSON.stdout.contains("\"quarantined\" : true"),
            "expected quarantined=true in:\n\(showJSON.stdout)"
        )

        let unquar = try harness.runIris(["secret", "unquarantine", "foo"])
        XCTAssertEqual(unquar.code, 0, "unquarantine failed\n\(unquar.stderr)")

        let showJSON2 = try harness.runIris(["secret", "show", "foo", "--json"])
        XCTAssertTrue(
            showJSON2.stdout.contains("\"quarantined\":false") || showJSON2.stdout.contains("\"quarantined\" : false"),
            "expected quarantined=false in:\n\(showJSON2.stdout)"
        )
    }
}
