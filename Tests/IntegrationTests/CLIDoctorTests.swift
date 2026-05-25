import XCTest

final class CLIDoctorTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    func testDoctorReportsExpectedChecks() throws {
        let result = try harness.runIris(["doctor"])
        // Check exit code: 0 if all OK; 1 if ca-trusted fails (dev CA — expected on test machine).
        XCTAssertTrue(
            result.code == 0 || result.code == 1,
            "code=\(result.code) stderr=\(result.stderr)"
        )
        // Locked invariants (regardless of trust store state):
        XCTAssertTrue(
            result.stdout.contains("admin-socket-present"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("daemon-alive"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("ca-cert-present"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("ca-trusted-system"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("shell-env-vars"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("proxy-ping"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("claude-apikeyhelper-absent"),
            "stdout=\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("[ok]  admin-socket-present"),
            "socket check should be ok"
        )
        XCTAssertTrue(
            result.stdout.contains("[ok]  daemon-alive"),
            "daemon should be alive"
        )
    }

    func testDoctorJSONIsValidArray() throws {
        let result = try harness.runIris(["doctor", "--json"])
        XCTAssertTrue(
            result.code == 0 || result.code == 1,
            "code=\(result.code) stderr=\(result.stderr)"
        )
        let data = result.stdout.data(using: .utf8) ?? Data()
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return XCTFail("not valid JSON array of objects: \(result.stdout)")
        }
        let names = parsed.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("admin-socket-present"))
        XCTAssertTrue(names.contains("daemon-alive"))
        XCTAssertTrue(names.contains("proxy-ping"))
        XCTAssertTrue(names.contains("claude-apikeyhelper-absent"))
    }

    func testDoctorExitsTwoWhenDaemonDown() throws {
        harness.stop()
        // doctor needs to call daemon RPCs; if daemon is down, withAdminClient throws ExitCode(2)
        let result = try harness.runIris(["doctor"])
        XCTAssertEqual(
            result.code,
            2,
            "expected exit 2 when daemon down, got code=\(result.code) stderr=\(result.stderr)"
        )
    }
}
