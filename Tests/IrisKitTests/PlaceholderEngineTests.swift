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

    func testSubstitutesKnownSecret() async throws {
        let engine = try await makeEngine(with: ["api_key": "sk-real"])
        let outcome = try await engine.substituteString("x-api-key: {{kc:api_key}}")
        XCTAssertEqual(String(data: outcome.output, encoding: .utf8), "x-api-key: sk-real")
        XCTAssertEqual(outcome.substituted, ["api_key"])
        XCTAssertTrue(outcome.unresolved.isEmpty)
    }

    func testLeavesUnknownPlaceholdersUnchanged() async throws {
        let engine = try await makeEngine(with: [:])
        let outcome = try await engine.substituteString("x: {{kc:missing}}")
        XCTAssertEqual(String(data: outcome.output, encoding: .utf8), "x: {{kc:missing}}")
        XCTAssertTrue(outcome.substituted.isEmpty)
        XCTAssertEqual(outcome.unresolved, ["missing"])
    }

    func testSubstitutesMultipleSecretsInOnePass() async throws {
        let engine = try await makeEngine(with: ["a": "A", "b": "B"])
        let outcome = try await engine.substituteString("{{kc:a}}-{{kc:b}}-{{kc:a}}")
        XCTAssertEqual(String(data: outcome.output, encoding: .utf8), "A-B-A")
        XCTAssertEqual(Set(outcome.substituted), Set(["a", "b"]))
    }

    func testEmitsNoSubstitutionWhenNoPlaceholders() async throws {
        let engine = try await makeEngine(with: ["a": "A"])
        let outcome = try await engine.substituteString("plain text")
        XCTAssertEqual(String(data: outcome.output, encoding: .utf8), "plain text")
        XCTAssertTrue(outcome.substituted.isEmpty)
        XCTAssertTrue(outcome.unresolved.isEmpty)
    }

    func testNonUTF8BodyIsNotScanned() async throws {
        // SPECS §7.4: non-UTF-8 bodies are not scanned.
        let engine = try await makeEngine(with: ["k": "X"])
        var body = Data([0x00, 0xff, 0x01])
        body.append(Data("{{kc:k}}".utf8))
        body.append(Data([0x02, 0x03]))
        let outcome = try await engine.substitute(body)
        XCTAssertEqual(outcome.output, body, "binary body must pass through unchanged")
        XCTAssertTrue(outcome.substituted.isEmpty)
        XCTAssertTrue(outcome.nonUtf8, "nonUtf8 flag must be set for binary payloads")
    }

    func testValidUTF8BodyHasNonUtf8False() async throws {
        let engine = try await makeEngine(with: ["k": "val"])
        let outcome = try await engine.substituteString("x-api-key: {{kc:k}}")
        XCTAssertFalse(outcome.nonUtf8)
    }

    func testCacheReturnsSameValueWithoutSecondKeychainCall() async throws {
        // Verify the LRU cache is hit: replace the secret value in the store
        // after first substitution — the cached value should still be used.
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v1".utf8), named: "tok", allowedHosts: ["h.com"], createdAt: Date())
        let engine = PlaceholderEngine(secretStore: store)

        let first = try await engine.substituteString("{{kc:tok}}")
        XCTAssertEqual(String(data: first.output, encoding: .utf8), "v1")

        // Rotate value in the store — if cache is working, engine still sees "v1".
        _ = try await store.rotate(named: "tok", newValue: Data("v2".utf8))

        let second = try await engine.substituteString("{{kc:tok}}")
        XCTAssertEqual(
            String(data: second.output, encoding: .utf8),
            "v1",
            "LRU cache must serve the first resolved value within TTL"
        )
    }

    func testSubstitutesInsideUTF8JSONBody() async throws {
        let engine = try await makeEngine(with: ["k": "real-value"])
        let body = Data(#"{"key":"{{kc:k}}","other":42}"#.utf8)
        let outcome = try await engine.substitute(body)
        XCTAssertEqual(
            String(data: outcome.output, encoding: .utf8),
            #"{"key":"real-value","other":42}"#
        )
        XCTAssertEqual(outcome.substituted, ["k"])
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
}
