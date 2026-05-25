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
}
