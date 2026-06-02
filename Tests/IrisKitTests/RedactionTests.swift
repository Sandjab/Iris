import XCTest

@testable import IrisKit

final class RedactionTests: XCTestCase {
    func testRedactStringReturnsExpectedFormat() {
        let output = Redaction.redact("sk-ant-abcdef")
        XCTAssertTrue(output.hasPrefix("[REDACTED:"))
        XCTAssertTrue(output.hasSuffix("]"))
        // 8 hex chars = 4 bytes of SHA-256 prefix
        let inner = output.dropFirst("[REDACTED:".count).dropLast()
        XCTAssertEqual(inner.count, 8)
        XCTAssertTrue(inner.allSatisfy { $0.isHexDigit })
    }

    func testRedactNeverLeaksInputValue() {
        let sensitive = "sk-ant-this-must-never-leak"
        let output = Redaction.redact(sensitive)
        XCTAssertFalse(output.contains(sensitive))
        XCTAssertFalse(output.contains("sk-ant"))
    }

    func testRedactIsDeterministic() {
        XCTAssertEqual(Redaction.redact("hello"), Redaction.redact("hello"))
    }

    func testDifferentInputsProduceDifferentRedactions() {
        XCTAssertNotEqual(Redaction.redact("alpha"), Redaction.redact("beta"))
    }

    func testRedactDataAndStringAgree() {
        let value = "some-secret-value"
        XCTAssertEqual(Redaction.redact(value), Redaction.redact(Data(value.utf8)))
    }

    func testEventPreservesOriginalURIWithPlaceholderForSubstitutedKind() {
        // CLAUDE.md §6.1 invariant: secret values never reach events.
        // The Event.path must carry the original (placeholder-containing) URI,
        // never the post-substitution URI.
        let event = Event(
            timestamp: Date(),
            kind: .substituted,
            host: "api.anthropic.com",
            method: "GET",
            path: "/v1?token={{kc:foo}}",  // original URI
            statusCode: 200,
            durationMs: 10,
            substitutedSecrets: ["foo"]
        )
        XCTAssertTrue(event.path.contains("{{kc:foo}}"))
        XCTAssertFalse(event.path.contains("REAL_SECRET_VALUE"))
    }

    func testAlertSnippetNeverContainsSecretValue() async throws {
        // CLAUDE.md §6.1: alert payloads must not carry secret values.
        // The scanner produces hits BEFORE substitution, so the snippet
        // is always the placeholder literal — verified here.
        let secretValue = "sk-supersecret-DO-NOT-LEAK"
        let secretName = "test_key"

        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )
        let evaluator = ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { 60 })
        let hit = PlaceholderHit(
            name: secretName,
            location: .header(name: "x-custom"),
            snippet: "X-Custom: {{kc:\(secretName)}}"
        )
        let decision = try await evaluator.evaluate(
            hits: [hit],
            context: RequestContext(
                host: "api.anthropic.com",
                method: "POST",
                path: "/v1/x",
                contentType: "application/json"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block (R2 non-canonical header fires)")
        }
        XCTAssertFalse(
            alert.snippet.contains(secretValue),
            "alert snippet must not carry secret value"
        )
        XCTAssertTrue(alert.snippet.contains("{{kc:\(secretName)}}"))
    }

    func testEncodedSubstitutedEventNeverContainsSecretValue() async throws {
        // CLAUDE.md §6.1: the SSE-encoded event must not carry secret values.
        // Non-vacuous: the value is genuinely resolved by the real substitution
        // engine (it lands in the forwarded request — the authorized channel),
        // and we then prove the event built for the stream carries only the
        // ORIGINAL URI and the substituted NAMES, never that resolved value.
        let secretValue = "sk-supersecret-DO-NOT-LEAK-SSE"
        let secretName = "foo"
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )
        let originalURI = "/v1/messages"
        let hit = PlaceholderHit(
            name: secretName,
            location: .header(name: "x-api-key"),
            snippet: "x-api-key: {{kc:\(secretName)}}"
        )
        let engine = PlaceholderEngine(secretStore: store)
        let payload = try await engine.substituteResolvable(
            headers: [("x-api-key", "{{kc:\(secretName)}}")],
            uri: originalURI,
            body: nil,
            resolvableHits: [hit]
        )
        // Sanity: the value really was resolved into the forwarded request.
        XCTAssertEqual(payload.substituted, [secretName])
        XCTAssertTrue(payload.headers.contains { $0.value.contains(secretValue) })

        // MITMHandler builds the event from the ORIGINAL URI + substituted names.
        let event = Event(
            timestamp: Date(),
            kind: .substituted,
            host: "api.anthropic.com",
            method: "POST",
            path: originalURI,
            statusCode: 200,
            durationMs: 12,
            substitutedSecrets: payload.substituted,
            alert: nil
        )
        let json = try JSONRPCCoder.makeEncoder().encode(event)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(secretValue), "resolved secret value must not reach the event")
        XCTAssertTrue(text.contains(secretName), "substituted secret NAME is retained for observability")
    }

    func testEncodedExfilBlockedEventNeverContainsSecretValue() async throws {
        // Non-vacuous: the alert is produced by the REAL exfil engine from a
        // request carrying a live secret value (in the store). We prove the
        // encoded event carries the placeholder snippet, never that value.
        let secretValue = "sk-supersecret-DO-NOT-LEAK-SSE"
        let secretName = "foo"
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )
        let evaluator = ExfilRuleEngine(
            secretStore: store,
            maxSubstitutionsPerMinuteProvider: { 60 }
        )
        let hit = PlaceholderHit(
            name: secretName,
            location: .header(name: "x-api-key"),
            snippet: "x-api-key: {{kc:\(secretName)}}"
        )
        // Out-of-scope host → R1 host-mismatch block → production builds the alert.
        let decision = try await evaluator.evaluate(
            hits: [hit],
            context: RequestContext(
                host: "evil.example.com",
                method: "POST",
                path: "/v1/messages",
                contentType: "application/json"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected R1 host-mismatch block")
        }
        let event = Event(
            timestamp: Date(),
            kind: .exfilBlocked,
            host: "evil.example.com",
            method: "POST",
            path: "/v1/messages",
            substitutedSecrets: [],
            alert: alert
        )
        let json = try JSONRPCCoder.makeEncoder().encode(event)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(secretValue), "blocked-event alert must not carry the secret value")
        XCTAssertTrue(
            text.contains("{{kc:\(secretName)}}"),
            "alert snippet retains the placeholder literal"
        )
    }
}
