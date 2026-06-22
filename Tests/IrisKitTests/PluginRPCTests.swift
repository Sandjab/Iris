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

    func testEncodeOnRequestParamsIsCompactSingleLine() throws {
        let params = PluginRPC.OnRequestParams(
            method: "POST",
            uri: "/v1/messages",
            host: "api.anthropic.com",
            headers: [["x-api-key", "{{kc:k}}"], ["content-type", "application/json"]],
            body: PluginRPC.Body(encoding: "utf8", data: "hello")
        )
        let line = try PluginRPC.encodeRequest(method: PluginRPC.Method.onRequest, params: params, id: 7)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "must be exactly one NDJSON line")
        XCTAssertTrue(line.contains("on_request"))
        XCTAssertTrue(line.contains("\"{{kc:k}}\""), "placeholder must survive encoding verbatim")
        XCTAssertTrue(line.contains("api.anthropic.com"), "host encoded")
        XCTAssertTrue(line.contains("\"method\":\"POST\""), "HTTP method encoded")
    }

    func testDecodeOnRequestResultModify() throws {
        let json = #"{"action":"modify","body":{"data":"z","encoding":"utf8"},"headers":[["a","b"]],"uri":"/v1/x"}"#
        let value = try JSONRPCCoder.makeDecoder().decode(PluginRPC.OnRequestResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.action, .modify)
        XCTAssertEqual(value.uri, "/v1/x")
        XCTAssertEqual(value.headers ?? [], [["a", "b"]])
        XCTAssertEqual(value.body?.data, "z")
    }

    func testDecodeOnRequestResultBlock() throws {
        let block = try JSONRPCCoder.makeDecoder().decode(
            PluginRPC.OnRequestResult.self,
            from: Data(#"{"action":"block","reason":"nope"}"#.utf8)
        )
        XCTAssertEqual(block.action, .block)
        XCTAssertEqual(block.reason, "nope")
    }

    func testDecodeOnRequestResultRespond() throws {
        let respond = try JSONRPCCoder.makeDecoder().decode(
            PluginRPC.OnRequestResult.self,
            from: Data(
                #"{"action":"respond","body":{"data":"teapot","encoding":"utf8"},"headers":[["x","y"]],"status":418}"#
                    .utf8
            )
        )
        XCTAssertEqual(respond.action, .respond)
        XCTAssertEqual(respond.status, 418)
    }

    func testDecodeOnRequestResultPass() throws {
        let pass = try JSONRPCCoder.makeDecoder().decode(
            PluginRPC.OnRequestResult.self,
            from: Data(#"{"action":"pass"}"#.utf8)
        )
        XCTAssertEqual(pass.action, .pass)
        // Absent fields must decode to nil (not a default), proving tolerant decode.
        XCTAssertNil(pass.body)
        XCTAssertNil(pass.reason)
        XCTAssertNil(pass.status)
        XCTAssertNil(pass.uri)
    }

    func testEncodeOnCompleteNotificationHasNoIdAndCarriesParams() throws {
        let params = PluginRPC.OnCompleteParams(
            method: "POST",
            uri: "/v1/messages",
            host: "api.anthropic.com",
            status: 200,
            durationMs: 1342
        )
        let line = try PluginRPC.encodeNotification(method: PluginRPC.Method.onComplete, params: params)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(line.contains("\"id\""), "a notification carries no id")
        XCTAssertTrue(line.contains("\"method\":\"on_complete\""))
        XCTAssertTrue(line.contains("\"status\":200"))
        XCTAssertTrue(line.contains("\"duration_ms\":1342"))
        XCTAssertTrue(line.contains("\"host\":\"api.anthropic.com\""))
    }

    func testOnCompleteParamsRoundTrips() throws {
        let params = PluginRPC.OnCompleteParams(
            method: "GET",
            uri: "/v1/x",
            host: "h",
            status: 0,
            durationMs: 5
        )
        let data = try JSONEncoder().encode(params)
        let back = try JSONDecoder().decode(PluginRPC.OnCompleteParams.self, from: data)
        XCTAssertEqual(back, params)
    }

    func testEncodeOnResponseRequestLine() throws {
        let params = PluginRPC.OnResponseParams(
            method: "POST",
            uri: "/v1/messages",
            host: "api.anthropic.com",
            status: 200,
            headers: [["content-type", "text/event-stream"]]
        )
        let line = try PluginRPC.encodeRequest(method: PluginRPC.Method.onResponse, params: params, id: 7)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains("\"method\":\"on_response\""))
        XCTAssertTrue(line.contains("\"status\":200"))
        XCTAssertTrue(line.contains("api.anthropic.com"), "host encoded")
        XCTAssertTrue(line.contains("text/event-stream"), "response header survives encoding")
    }

    func testDecodeOnResponseResultPassAndModify() throws {
        let passLine = #"{"jsonrpc":"2.0","id":7,"result":{"action":"pass"}}"#
        let pass = try PluginRPC.decodeResponse(passLine).result!.decode(as: PluginRPC.OnResponseResult.self)
        XCTAssertEqual(pass.action, .pass)
        XCTAssertNil(pass.headers)

        let modLine = #"{"jsonrpc":"2.0","id":7,"result":{"action":"modify","headers":[["x-iris-tagged","1"]]}}"#
        let mod = try PluginRPC.decodeResponse(modLine).result!.decode(as: PluginRPC.OnResponseResult.self)
        XCTAssertEqual(mod.action, .modify)
        XCTAssertEqual(mod.headers ?? [], [["x-iris-tagged", "1"]])
    }
}
