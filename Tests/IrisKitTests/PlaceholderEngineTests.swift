import XCTest

@testable import IrisKit

final class PlaceholderEngineTests: XCTestCase {
    private func makeEngine(with secrets: [String: String]) async throws -> PlaceholderEngine {
        let store = InMemorySecretStore()
        for (name, value) in secrets {
            _ = try await store.add(
                Data(value.utf8),
                named: name,
                allowedHosts: ["example.com"],
                createdAt: Date()
            )
        }
        return PlaceholderEngine(secretStore: store)
    }

    func testFindsPlaceholderNamesInString() {
        let names = PlaceholderEngine.findPlaceholderNames(in: "x-api-key: {{kc:foo}}, x-other: {{kc:bar}}")
        XCTAssertEqual(Set(names), Set(["foo", "bar"]))
    }

    func testReturnsOrderedDistinctNames() {
        let names = PlaceholderEngine.findPlaceholderNames(in: "{{kc:a}}-{{kc:b}}-{{kc:a}}-{{kc:c}}")
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    func testIgnoresMalformedPlaceholders() {
        let names = PlaceholderEngine.findPlaceholderNames(in: "{{kc:}}-{{kc:has space}}-{kc:foo}}-{{kc:ok}}")
        XCTAssertEqual(names, ["ok"])
    }

    func testRejectsOverlongName() {
        let long = String(repeating: "a", count: 65)
        let text = "{{kc:\(long)}}"
        XCTAssertTrue(PlaceholderEngine.findPlaceholderNames(in: text).isEmpty)
    }

    func testCacheReturnsSameValueWithoutSecondKeychainCall() async throws {
        // Verify the LRU cache is hit: rotate the secret value in the store
        // after the first substitution — the cached value must still be served.
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v1".utf8), named: "tok", allowedHosts: ["h.com"], createdAt: Date())
        let engine = PlaceholderEngine(secretStore: store)
        let hit = PlaceholderHit(name: "tok", location: .header(name: "authorization"), snippet: "")

        let first = try await engine.substituteResolvable(
            headers: [("Authorization", "{{kc:tok}}")],
            uri: "/",
            body: nil,
            resolvableHits: [hit]
        )
        XCTAssertEqual(first.headers[0].value, "v1")

        // Rotate value in the store — if cache is working, engine still sees "v1".
        _ = try await store.rotate(named: "tok", newValue: Data("v2".utf8))

        let second = try await engine.substituteResolvable(
            headers: [("Authorization", "{{kc:tok}}")],
            uri: "/",
            body: nil,
            resolvableHits: [hit]
        )
        XCTAssertEqual(
            second.headers[0].value,
            "v1",
            "LRU cache must serve the first resolved value within TTL"
        )
    }

    func testSubstituteResolvableLeavesNonUTF8BodyUntouched() async throws {
        // SPECS §7.4: a body that does not decode as UTF-8 is never rewritten,
        // even when an authorized hit substitutes elsewhere in the request.
        let engine = try await makeEngine(with: ["k": "X"])
        var body = Data([0x00, 0xff, 0x01])
        body.append(Data("{{kc:k}}".utf8))
        body.append(Data([0x02, 0x03]))
        let hit = PlaceholderHit(name: "k", location: .header(name: "x-api-key"), snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [("x-api-key", "{{kc:k}}")],
            uri: "/",
            body: body,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.body, body, "binary body must pass through unchanged")
        XCTAssertEqual(payload.headers[0].value, "X", "header substitution still applies")
    }

    // MARK: - substituteResolvable

    func testSubstituteResolvableReplacesOnlyAuthorizedHits() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO", "bar": "VALUE_BAR"])
        let authorizedHit = PlaceholderHit(
            name: "foo",
            location: .header(name: "authorization"),
            snippet: ""
        )
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:foo}}"), ("X-Other", "{{kc:bar}}")],
            uri: "/v1/messages",
            body: nil,
            resolvableHits: [authorizedHit]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
        XCTAssertEqual(payload.headers[0].value, "Bearer VALUE_FOO")
        XCTAssertEqual(payload.headers[1].value, "{{kc:bar}}")  // not authorized
    }

    func testSubstituteResolvableEmptyHitsReturnsVerbatim() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/v1/messages",
            body: nil,
            resolvableHits: []
        )
        XCTAssertEqual(payload.substituted, [])
        XCTAssertEqual(payload.headers[0].value, "Bearer {{kc:foo}}")
    }

    func testSubstituteResolvableSubstitutesInBody() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])
        let body = Data(#"{"key":"{{kc:foo}}"}"#.utf8)
        let hit = PlaceholderHit(name: "foo", location: .body, snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [],
            uri: "/",
            body: body,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
        XCTAssertEqual(
            String(data: payload.body!, encoding: .utf8),
            #"{"key":"VALUE_FOO"}"#
        )
    }

    func testSubstituteResolvableSubstitutesInURI() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])
        let hit = PlaceholderHit(name: "foo", location: .queryString, snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [],
            uri: "/v1?x={{kc:foo}}",
            body: nil,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
        XCTAssertEqual(payload.uri, "/v1?x=VALUE_FOO")
    }

    func testSubstituteResolvableUnresolvedNameReportedInPayload() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])  // bar absent
        let hit = PlaceholderHit(
            name: "bar",
            location: .header(name: "authorization"),
            snippet: ""
        )
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:bar}}")],
            uri: "/v1",
            body: nil,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, [])
        XCTAssertEqual(payload.unresolved, ["bar"])
        XCTAssertEqual(payload.headers[0].value, "Bearer {{kc:bar}}")
    }

    func testSubstituteResolvableSubstitutesAllOccurrencesOfSameName() async throws {
        let engine = try await makeEngine(with: ["k": "V"])
        let hit = PlaceholderHit(name: "k", location: .header(name: "authorization"), snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [
                ("Authorization", "Bearer {{kc:k}}"),
                ("X-Echo", "{{kc:k}}"),
            ],
            uri: "/x?t={{kc:k}}",
            body: Data(#"{"t":"{{kc:k}}"}"#.utf8),
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, ["k"])  // reported once despite 4 occurrences
        XCTAssertEqual(payload.headers[0].value, "Bearer V")
        XCTAssertEqual(payload.headers[1].value, "V")
        XCTAssertEqual(payload.uri, "/x?t=V")
        XCTAssertEqual(String(data: payload.body!, encoding: .utf8), #"{"t":"V"}"#)
    }

    func testSubstituteResolvableReportsNonUTF8SecretValueAsUnresolved() async throws {
        // A secret with non-UTF-8 bytes (random binary) cannot be spliced into
        // request strings. Must be surfaced via `unresolved`, not silently dropped.
        let store = InMemorySecretStore()
        let nonUTF8Bytes = Data([0xFF, 0xFE, 0xFD, 0xFC])
        _ = try await store.add(nonUTF8Bytes, named: "binkey", allowedHosts: ["api.x"], createdAt: Date())
        let engine = PlaceholderEngine(secretStore: store)
        let hit = PlaceholderHit(name: "binkey", location: .header(name: "authorization"), snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:binkey}}")],
            uri: "/",
            body: nil,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, [])
        XCTAssertEqual(payload.unresolved, ["binkey"])
        XCTAssertEqual(payload.headers[0].value, "Bearer {{kc:binkey}}")
    }
}
