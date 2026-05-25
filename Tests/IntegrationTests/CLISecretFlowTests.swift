import XCTest

final class CLISecretFlowTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    // MARK: - Round-trip + no-leak invariant

    func testAddListShowRotateRmRoundTrip() throws {
        let secretValue = "sk-INTEGRATION-TEST-VALUE-deadbeef"

        // --- add ---
        let add = try harness.runIris(
            ["secret", "add", "foo", "--allowed-hosts", "api.x.com", "--value-from-stdin"],
            stdin: Data((secretValue + "\n").utf8)
        )
        XCTAssertEqual(add.code, 0, "secret add failed\nstderr=\(add.stderr)")
        assertNoLeak(add, secret: secretValue)

        // --- list (text) ---
        let listTxt = try harness.runIris(["secret", "list"])
        XCTAssertEqual(listTxt.code, 0, "secret list failed\nstderr=\(listTxt.stderr)")
        XCTAssertTrue(listTxt.stdout.contains("foo"), "secret 'foo' missing from list output")
        assertNoLeak(listTxt, secret: secretValue)

        // --- list (JSON) ---
        let listJSON = try harness.runIris(["secret", "list", "--json"])
        XCTAssertEqual(listJSON.code, 0, "secret list --json failed\nstderr=\(listJSON.stderr)")
        assertNoLeak(listJSON, secret: secretValue)

        // --- show ---
        let show = try harness.runIris(["secret", "show", "foo"])
        XCTAssertEqual(show.code, 0, "secret show failed\nstderr=\(show.stderr)")
        XCTAssertTrue(show.stdout.contains("api.x.com"), "allowed host missing from show output")
        assertNoLeak(show, secret: secretValue)

        // --- edit (add a second host) ---
        let edit = try harness.runIris(
            ["secret", "edit", "foo", "--allowed-hosts", "api.x.com,api.y.com"]
        )
        XCTAssertEqual(edit.code, 0, "secret edit failed\nstderr=\(edit.stderr)")
        assertNoLeak(edit, secret: secretValue)

        let postEdit = try harness.runIris(["secret", "show", "foo"])
        XCTAssertTrue(
            postEdit.stdout.contains("api.y.com"),
            "new host 'api.y.com' missing after edit"
        )

        // --- rotate ---
        let newValue = "sk-ROTATED-cafebabe"
        let rotate = try harness.runIris(
            ["secret", "rotate", "foo"],
            stdin: Data((newValue + "\n").utf8)
        )
        XCTAssertEqual(rotate.code, 0, "secret rotate failed\nstderr=\(rotate.stderr)")
        assertNoLeak(rotate, secret: newValue)
        assertNoLeak(rotate, secret: secretValue)

        // --- rm ---
        let rm = try harness.runIris(["secret", "rm", "foo", "--yes"])
        XCTAssertEqual(rm.code, 0, "secret rm failed\nstderr=\(rm.stderr)")

        let listAfter = try harness.runIris(["secret", "list"])
        XCTAssertFalse(
            listAfter.stdout.contains("foo"),
            "secret 'foo' still visible after rm"
        )
    }

    // MARK: - Helpers

    private func assertNoLeak(
        _ result: (stdout: String, stderr: String, code: Int32),
        secret: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            result.stdout.contains(secret),
            "secret value leaked to stdout",
            file: file,
            line: line
        )
        XCTAssertFalse(
            result.stderr.contains(secret),
            "secret value leaked to stderr",
            file: file,
            line: line
        )
    }
}
