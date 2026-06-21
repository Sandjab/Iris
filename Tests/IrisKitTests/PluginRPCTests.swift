import XCTest

@testable import IrisKit

final class PluginRPCTests: XCTestCase {
    func testEncodeRequestIsSingleCompactLineTerminatedByNewline() throws {
        let params = PluginRPC.InitializeParams(
            apiVersion: 1,
            configValues: ["k": "v"],
            capabilities: PluginCapabilities(network: [], filesystem: []),
            scratchDir: "/tmp/scratch"
        )
        let line = try PluginRPC.encodeRequest(
            method: "initialize",
            params: params,
            id: 7
        )
        // Exactly one trailing newline, no embedded newlines.
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains("\"method\":\"initialize\""))
        XCTAssertTrue(line.contains("\"api_version\":1"))
        XCTAssertTrue(line.contains("\"scratch_dir\":\"/tmp/scratch\""))
        XCTAssertTrue(line.contains("\"id\":7"))
    }

    func testEncodeNotificationHasNoId() throws {
        let line = try PluginRPC.encodeNotification(method: "shutdown")
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertFalse(line.contains("\"id\""))
        XCTAssertTrue(line.contains("\"method\":\"shutdown\""))
    }

    func testDecodeResponseParsesResultAndId() throws {
        let response = try PluginRPC.decodeResponse(
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ready\":true}}"
        )
        XCTAssertEqual(response.id, .integer(7))
        let result = try XCTUnwrap(response.result).decode(as: PluginRPC.InitializeResult.self)
        XCTAssertTrue(result.ready)
    }

    func testDecodeResponseRejectsGarbage() {
        XCTAssertThrowsError(try PluginRPC.decodeResponse("not json"))
    }
}
