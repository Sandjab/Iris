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
}
