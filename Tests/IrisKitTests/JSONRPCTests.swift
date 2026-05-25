import XCTest

@testable import IrisKit

final class JSONRPCTests: XCTestCase {

    // MARK: - Envelope round trips

    func testRequestRoundTripPreservesAllFields() throws {
        let request = JSONRPCRequest(
            method: "secret.add",
            params: try JSONValue.encoding(
                SecretAddParams(
                    name: "anthropic",
                    allowedHosts: ["api.anthropic.com"],
                    value: Data("sk-test".utf8)
                )
            ),
            id: .integer(7)
        )

        let data = try JSONRPCCoder.makeEncoder().encode(request)
        let decoded = try JSONRPCCoder.makeDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
    }

    func testSuccessResponseEncodesResultNotError() throws {
        let response = JSONRPCResponse.success(
            id: .integer(1),
            result: .object(["paused": .bool(true)])
        )
        let data = try JSONRPCCoder.makeEncoder().encode(response)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertFalse(json.contains("\"error\""))
    }

    func testFailureResponseEncodesErrorNotResult() throws {
        let response = JSONRPCResponse.failure(id: .integer(1), error: .unknownSecret("ghost"))
        let data = try JSONRPCCoder.makeEncoder().encode(response)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"error\""))
        XCTAssertFalse(json.contains("\"result\""))
    }

    // MARK: - ID variants

    func testIDDecodesInteger() throws {
        let json = #"{"jsonrpc":"2.0","method":"daemon.status","id":42}"#
        let request = try JSONRPCCoder.makeDecoder().decode(
            JSONRPCRequest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(request.id, .integer(42))
    }

    func testIDDecodesString() throws {
        let json = #"{"jsonrpc":"2.0","method":"daemon.status","id":"call-1"}"#
        let request = try JSONRPCCoder.makeDecoder().decode(
            JSONRPCRequest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(request.id, .string("call-1"))
    }

    func testIDDecodesNull() throws {
        let json = #"{"jsonrpc":"2.0","method":"daemon.status","id":null}"#
        let request = try JSONRPCCoder.makeDecoder().decode(
            JSONRPCRequest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(request.id, .null)
    }

    // MARK: - Custom error codes (SPECS §13.2)

    func testCustomErrorCodes() {
        XCTAssertEqual(JSONRPCError.unknownSecret("k").code, -32001)
        XCTAssertEqual(JSONRPCError.invalidName("bad").code, -32002)
        XCTAssertEqual(JSONRPCError.invalidAllowedHosts([]).code, -32003)
        XCTAssertEqual(JSONRPCError.duplicate("k").code, -32004)
        XCTAssertEqual(JSONRPCError.daemonPaused.code, -32005)
        XCTAssertEqual(JSONRPCError.notFound("x").code, -32006)
    }

    // MARK: - Snake case wire format

    func testEncoderEmitsSnakeCaseKeys() throws {
        let params = SecretAddParams(
            name: "key",
            allowedHosts: ["example.com"],
            value: Data("v".utf8)
        )
        let data = try JSONRPCCoder.makeEncoder().encode(params)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"allowed_hosts\""), "got: \(json)")
        XCTAssertFalse(json.contains("\"allowedHosts\""), "camelCase leaked: \(json)")
    }

    func testDecoderAcceptsSnakeCaseKeys() throws {
        let json = #"{"name":"k","allowed_hosts":["example.com"],"value":"YWJj"}"#
        let params = try JSONRPCCoder.makeDecoder().decode(
            SecretAddParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(params.name, "k")
        XCTAssertEqual(params.allowedHosts, ["example.com"])
        XCTAssertEqual(params.value, Data("abc".utf8))
    }

    // MARK: - JSONValue tree

    func testJSONValuePreservesIntegerVsDouble() throws {
        let value: JSONValue = .object([
            "i": .integer(42),
            "d": .double(2.5),
            "mixed": .array([.integer(1), .double(1.5), .string("ok"), .bool(false), .null]),
        ])
        let data = try JSONRPCCoder.makeEncoder().encode(value)
        let back = try JSONRPCCoder.makeDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
    }

    func testJSONValueRoundTripThroughTypedPayload() throws {
        let original = EventsQueryParams(
            since: Date(timeIntervalSince1970: 1_700_000_000),
            until: nil,
            limit: 50,
            kind: [.substituted, .exfilBlocked],
            host: "api.example.com"
        )
        let value = try JSONValue.encoding(original)
        let decoded = try value.decode(as: EventsQueryParams.self)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Method enum

    func testAdminMethodRawValuesMatchSPECS() {
        XCTAssertEqual(AdminMethod.secretAdd.rawValue, "secret.add")
        XCTAssertEqual(AdminMethod.eventsQuery.rawValue, "events.query")
        XCTAssertEqual(AdminMethod.caExportPath.rawValue, "ca.export_path")
        XCTAssertEqual(AdminMethod.caIsTrusted.rawValue, "ca.is_trusted")
        XCTAssertEqual(AdminMethod.daemonResume.rawValue, "daemon.resume")
    }
}
