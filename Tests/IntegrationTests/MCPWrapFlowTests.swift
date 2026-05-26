import IrisKit
import XCTest

final class MCPWrapFlowTests: XCTestCase {
    var harness: CLIDaemonHarness!
    var tmpDir: URL!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-wrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        harness.stop()
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, content: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Wrap tests

    func testWrapEmptyEntryAddsSixEnvVars() throws {
        let url = try writeFile(
            "test.mcp.json",
            content: """
                {
                  "mcpServers": {
                    "alpha": {
                      "command": "node"
                    }
                  }
                }
                """
        )
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let patched = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(patched.contains("HTTPS_PROXY"), "HTTPS_PROXY missing: \(patched)")
        XCTAssertTrue(patched.contains("HTTP_PROXY"), "HTTP_PROXY missing: \(patched)")
        XCTAssertTrue(
            patched.contains("NODE_EXTRA_CA_CERTS"),
            "NODE_EXTRA_CA_CERTS missing: \(patched)"
        )
        XCTAssertTrue(patched.contains("SSL_CERT_FILE"), "SSL_CERT_FILE missing: \(patched)")
        XCTAssertTrue(patched.contains("CURL_CA_BUNDLE"), "CURL_CA_BUNDLE missing: \(patched)")
        XCTAssertTrue(
            patched.contains("REQUESTS_CA_BUNDLE"),
            "REQUESTS_CA_BUNDLE missing: \(patched)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path + ".iris.bak"),
            "backup not created"
        )
    }

    func testWrapIdempotent() throws {
        let url = try writeFile(
            "idempotent.json",
            content: """
                {
                  "mcpServers": {
                    "foo": { "command": "node" }
                  }
                }
                """
        )
        let first = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(first.code, 0, "first wrap: stderr=\(first.stderr)")
        let firstContent = try String(contentsOf: url, encoding: .utf8)
        let second = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(second.code, 0, "second wrap: stderr=\(second.stderr)")
        XCTAssertTrue(
            second.stdout.contains("already compliant"),
            "expected 'already compliant' in stdout=\(second.stdout)"
        )
        let secondContent = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(firstContent, secondContent, "file changed on second wrap")
    }

    func testWrapDryRunDoesNotWrite() throws {
        let original = """
            {
              "mcpServers": {
                "foo": { "command": "node" }
              }
            }
            """
        let url = try writeFile("dryrun.json", content: original)
        let result = try harness.runIris(["mcp", "wrap", url.path, "--dry-run"])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, original, "dry-run must not write the file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path + ".iris.bak"),
            "dry-run must not create backup"
        )
    }

    func testWrapSkipsHttpTransport() throws {
        let original = """
            {
              "mcpServers": {
                "foo": {
                  "type": "http",
                  "url": "https://api.example.com/mcp"
                }
              }
            }
            """
        let url = try writeFile("http.json", content: original)
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            after.contains("HTTPS_PROXY"),
            "http transport should not get env injected: \(after)"
        )
    }

    func testWrapPreservesPlaceholder() throws {
        let url = try writeFile(
            "placeholder.json",
            content: """
                {
                  "mcpServers": {
                    "foo": {
                      "command": "node",
                      "env": {
                        "MY_KEY": "{{kc:my_secret}}"
                      }
                    }
                  }
                }
                """
        )
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            after.contains("{{kc:my_secret}}"),
            "placeholder was overwritten: \(after)"
        )
    }

    // MARK: - Unwrap tests

    func testUnwrapRestoresExact() throws {
        let original = """
            {
              "mcpServers": {
                "foo": { "command": "node" }
              }
            }
            """
        let url = try writeFile("roundtrip.json", content: original)
        let wrap = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(wrap.code, 0, "wrap: stderr=\(wrap.stderr)")
        // `mcp unwrap` has no ConnectionOptions, so use runIrisRaw (no --socket-path injection).
        let unwrap = try harness.runIrisRaw(["mcp", "unwrap", url.path])
        XCTAssertEqual(unwrap.code, 0, "unwrap: stderr=\(unwrap.stderr)")
        let restored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(restored, original, "unwrap did not restore original content")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path + ".iris.bak"),
            "backup should be removed after unwrap"
        )
    }

    func testUnwrapWithoutBackupExitsOne() throws {
        let url = try writeFile("nobak.json", content: "{}")
        // `mcp unwrap` has no ConnectionOptions, so use runIrisRaw.
        let result = try harness.runIrisRaw(["mcp", "unwrap", url.path])
        XCTAssertEqual(result.code, 1, "expected exit 1, got code=\(result.code)")
        XCTAssertTrue(
            result.stderr.contains("no backup"),
            "expected 'no backup' in stderr=\(result.stderr)"
        )
    }

    // MARK: - Error / edge case tests

    func testWrapInvalidJSONExitsOne() throws {
        let url = try writeFile("bad.json", content: "{ not json")
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 1, "expected exit 1, got code=\(result.code)")
        XCTAssertTrue(
            result.stderr.contains("not valid JSON") || result.stderr.contains("JSONC"),
            "expected JSON parse error in stderr=\(result.stderr)"
        )
    }

    func testWrapMissingFileExitsOne() throws {
        let nonExistentPath = "/tmp/does-not-exist-\(UUID().uuidString).json"
        let result = try harness.runIris(["mcp", "wrap", nonExistentPath])
        XCTAssertEqual(result.code, 1, "expected exit 1, got code=\(result.code)")
    }

    func testWrapRefusesBakInput() throws {
        let url = try writeFile("foo.json.iris.bak", content: "{}")
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 1, "expected exit 1, got code=\(result.code)")
        XCTAssertTrue(
            result.stderr.contains(".iris.bak"),
            "expected .iris.bak in stderr=\(result.stderr)"
        )
    }

    func testWrapDaemonDownExitsTwo() throws {
        harness.stop()
        let url = try writeFile("dd.json", content: "{}")
        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 2, "expected exit 2 when daemon down, got code=\(result.code)")
    }

    // MARK: - JSONC tests

    func testWrapRefusesCommentedFileButAcceptsDryRun() throws {
        let url = try writeFile(
            "commented.json",
            content: """
                // top
                { "mcpServers": { "foo": { "command": "echo", "args": [] } } }
                """
        )

        // dry-run: should succeed even though the file has comments
        let dry = try harness.runIris(["mcp", "wrap", "--dry-run", url.path])
        XCTAssertEqual(dry.code, 0, "dry-run should accept commented file, stderr: \(dry.stderr)")

        // wrap (write): should fail with exit 1 (IrisExitCode.logicError), file unchanged
        let mtimeBefore =
            try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let write = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(write.code, 1, "expected exit 1 for commented file, got \(write.code)")
        XCTAssertTrue(
            write.stderr.contains("comments detected"),
            "expected 'comments detected' in stderr: \(write.stderr)"
        )
        let mtimeAfter =
            try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter, "file must be unchanged after refusal")
    }

    func testWrapNormalizesTrailingCommaInWrite() throws {
        let url = try writeFile(
            "trailing-comma.json",
            content: """
                { "mcpServers": { "foo": { "command": "echo", "args": ["hi"], } } }
                """
        )

        let result = try harness.runIris(["mcp", "wrap", url.path])
        XCTAssertEqual(result.code, 0, "trailing-comma file should wrap cleanly, stderr: \(result.stderr)")

        // Patched output must be strict valid JSON (no trailing comma)
        let patched = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNoThrow(
            try OrderedJSONDocument.parse(patched),
            "patched output must be strict-mode parseable (no trailing commas): \(patched)"
        )
    }

    func testWrapWatchAndDryRunAreMutuallyExclusive() throws {
        let result = try harness.runIris(
            ["mcp", "wrap", "--watch", "--dry-run", "/tmp/nonexistent.json"]
        )
        XCTAssertEqual(result.code, 64)  // usage error
        XCTAssertTrue(
            result.stderr.contains("--watch") && result.stderr.contains("--dry-run"),
            "stderr: \(result.stderr)"
        )
    }
}
