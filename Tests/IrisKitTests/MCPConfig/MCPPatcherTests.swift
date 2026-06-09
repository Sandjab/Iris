import XCTest

@testable import IrisKit

final class MCPPatcherTests: XCTestCase {
    let broker = "127.0.0.1:8080"
    let caPath = "/Users/test/Library/Application Support/iris/ca.pem"

    private func patch(_ json: String) throws -> (OrderedJSONDocument, MCPPatcher.Summary) {
        let doc = try OrderedJSONDocument.parse(json)
        return try MCPPatcher.patch(document: doc, brokerListen: broker, caPemPath: caPath)
    }

    func testAddsAllSixVarsToEntryWithoutEnv() throws {
        let (out, summary) = try patch(
            #"""
            {
              "mcpServers": {
                "foo": {
                  "command": "node",
                  "args": []
                }
              }
            }
            """#
        )
        let s = OrderedJSONDocument.serialize(out)
        XCTAssertTrue(s.contains("\"HTTPS_PROXY\""))
        XCTAssertTrue(s.contains("\"HTTP_PROXY\""))
        XCTAssertTrue(s.contains("\"NODE_EXTRA_CA_CERTS\""))
        XCTAssertTrue(s.contains("\"SSL_CERT_FILE\""))
        XCTAssertTrue(s.contains("\"CURL_CA_BUNDLE\""))
        XCTAssertTrue(s.contains("\"REQUESTS_CA_BUNDLE\""))
        XCTAssertTrue(s.contains("http://\(broker)"))
        XCTAssertTrue(s.contains(caPath))
        XCTAssertEqual(summary.patched, 1)
        XCTAssertEqual(summary.alreadyCompliant, 0)
        XCTAssertEqual(summary.skippedHttpSse, 0)
    }

    func testAddsOnlyMissingVarsWhenEnvPartial() throws {
        let (out, summary) = try patch(
            #"""
            {
              "mcpServers": {
                "foo": {
                  "command": "node",
                  "env": {
                    "HTTPS_PROXY": "http://existing.example:9999"
                  }
                }
              }
            }
            """#
        )
        let s = OrderedJSONDocument.serialize(out)
        XCTAssertTrue(s.contains("http://existing.example:9999"), "user value preserved")
        XCTAssertFalse(s.contains("http://\(broker)"), "we did NOT overwrite the existing HTTPS_PROXY")
        XCTAssertTrue(s.contains(caPath), "missing CA var was added")
        XCTAssertEqual(summary.patched, 1)
    }

    func testSkipsHttpTransportWithoutEnv() throws {
        let (out, summary) = try patch(
            #"""
            {
              "mcpServers": {
                "foo": {
                  "type": "http",
                  "url": "https://api.example.com/mcp"
                }
              }
            }
            """#
        )
        let s = OrderedJSONDocument.serialize(out)
        XCTAssertFalse(s.contains("\"env\""), "no env added for type:http")
        XCTAssertEqual(summary.patched, 0)
        XCTAssertEqual(summary.skippedHttpSse, 1)
    }

    func testSkipsSseTransportWithoutEnv() throws {
        let (out, summary) = try patch(
            #"""
            {
              "mcpServers": {
                "foo": {
                  "type": "sse",
                  "url": "https://api.example.com/sse"
                }
              }
            }
            """#
        )
        XCTAssertFalse(OrderedJSONDocument.serialize(out).contains("\"env\""))
        XCTAssertEqual(summary.skippedHttpSse, 1)
    }

    func testPlaceholderPreserved() throws {
        let (out, _) = try patch(
            #"""
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
            """#
        )
        let s = OrderedJSONDocument.serialize(out)
        XCTAssertTrue(s.contains("{{kc:my_secret}}"))
    }

    func testIdempotenceSecondPassZeroDiff() throws {
        let input = #"""
            {
              "mcpServers": {
                "foo": {
                  "command": "node"
                }
              }
            }
            """#
        let (firstPass, _) = try patch(input)
        let firstSerialized = OrderedJSONDocument.serialize(firstPass)
        let (secondPass, summary2) = try MCPPatcher.patch(
            document: firstPass,
            brokerListen: broker,
            caPemPath: caPath
        )
        let secondSerialized = OrderedJSONDocument.serialize(secondPass)
        XCTAssertEqual(firstSerialized, secondSerialized)
        XCTAssertEqual(summary2.patched, 0)
        XCTAssertEqual(summary2.alreadyCompliant, 1)
    }

    func testNestedMcpServersAtOneLevel() throws {
        let (_, summary) = try patch(
            #"""
            {
              "wrapper": {
                "mcpServers": {
                  "foo": { "command": "node" }
                }
              }
            }
            """#
        )
        XCTAssertEqual(summary.patched, 1)
    }

    func testNoMcpServersIsNoOp() throws {
        let (_, summary) = try patch(
            #"""
            { "other": "data" }
            """#
        )
        XCTAssertEqual(summary.patched, 0)
        XCTAssertEqual(summary.alreadyCompliant, 0)
        XCTAssertEqual(summary.skippedHttpSse, 0)
    }

    func testUnwrapRestoresFromBackupAndRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-unwrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent(".mcp.json")
        let backup = dir.appendingPathComponent(".mcp.json.iris.bak")
        try Data(#"{"original":true}"#.utf8).write(to: backup)
        try Data(#"{"patched":true}"#.utf8).write(to: file)

        try MCPPatcher.unwrap(path: file.path)

        let restored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(restored.contains("original"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "backup is removed")
    }

    func testUnwrapThrowsWhenBackupMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-unwrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".mcp.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try MCPPatcher.unwrap(path: file.path))
    }

    func testPatcherWorksOnJSONCDocument() throws {
        let input = """
            // Top-level comment
            {
              "mcpServers": {
                "foo": {
                  "command": "node",
                  "args": ["server.js"],
                }
              }
            }
            """
        let doc = try OrderedJSONDocument.parse(input, options: .jsonc)
        XCTAssertFalse(doc.commentPositions.isEmpty)
        let (patched, summary) = try MCPPatcher.patch(
            document: doc,
            brokerListen: "127.0.0.1:9876",
            caPemPath: "/tmp/ca.pem"
        )
        XCTAssertEqual(summary.patched, 1)
        XCTAssertEqual(summary.alreadyCompliant, 0)
        // Serialize: result must be valid strict JSON (comments stripped)
        let serialized = OrderedJSONDocument.serialize(patched)
        let reparsed = try OrderedJSONDocument.parse(serialized)
        XCTAssertEqual(reparsed.root, patched.root)
        XCTAssertTrue(reparsed.commentPositions.isEmpty)
    }
}
