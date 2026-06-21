import XCTest

@testable import IrisKit

final class EventPluginTests: XCTestCase {
    func testPluginBlockedEventCarriesIdNoPayload() throws {
        let e = Event(
            timestamp: Date(),
            kind: .pluginBlocked,
            host: "api.anthropic.com",
            method: "POST",
            path: "/v1/messages",
            statusCode: 403,
            durationMs: 5,
            pluginId: "org.example.tagger"
        )
        let data = try JSONRPCCoder.makeEncoder().encode(e)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"plugin_id\""))
        XCTAssertTrue(json.contains("org.example.tagger"))
        let back = try JSONRPCCoder.makeDecoder().decode(Event.self, from: data)
        XCTAssertEqual(back.kind, .pluginBlocked)
        XCTAssertEqual(back.pluginId, "org.example.tagger")
    }

    func testPluginRespondedKindRoundTrips() throws {
        let e = Event(
            timestamp: Date(),
            kind: .pluginResponded,
            host: "h",
            method: "GET",
            path: "/",
            statusCode: 418,
            pluginId: "p"
        )
        let back = try JSONRPCCoder.makeDecoder().decode(
            Event.self,
            from: try JSONRPCCoder.makeEncoder().encode(e)
        )
        XCTAssertEqual(back.kind, .pluginResponded)
        XCTAssertEqual(back.pluginId, "p")
    }

    func testOlderEventWithoutPluginIdStillDecodes() throws {
        let json =
            #"{"id":"00000000-0000-0000-0000-000000000000","timestamp":"2026-06-21T00:00:00Z","kind":"substituted","host":"h","method":"POST","path":"/","substituted_secrets":[]}"#
        let e = try JSONRPCCoder.makeDecoder().decode(Event.self, from: Data(json.utf8))
        XCTAssertNil(e.pluginId)
    }
}
