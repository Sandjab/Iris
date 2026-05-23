import XCTest
@testable import IrisKit

final class ModelsTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    func testSecretRoundTrip() throws {
        let secret = Secret(
            name: "anthropic_api_key",
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000),
            usageCount: 42
        )
        XCTAssertEqual(try roundTrip(secret), secret)
    }

    func testMITMRuleRoundTrip() throws {
        let rule = MITMRule(
            host: "api.github.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(try roundTrip(rule), rule)
    }

    func testEventRoundTripWithAlert() throws {
        let alert = Alert(
            severity: .high,
            rule: .hostMismatch,
            secretName: "anthropic_api_key",
            detectedAt: .body,
            snippet: "[REDACTED:abcd1234]"
        )
        let event = Event(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .exfilBlocked,
            host: "api.github.com",
            method: "POST",
            path: "/repos/foo/bar/issues",
            statusCode: 201,
            durationMs: 423,
            substitutedSecrets: [],
            alert: alert
        )
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testEventKindRawValues() {
        XCTAssertEqual(Event.Kind.substituted.rawValue, "substituted")
        XCTAssertEqual(Event.Kind.passThrough.rawValue, "passThrough")
        XCTAssertEqual(Event.Kind.noMatch.rawValue, "noMatch")
        XCTAssertEqual(Event.Kind.exfilBlocked.rawValue, "exfilBlocked")
        XCTAssertEqual(Event.Kind.error.rawValue, "error")
    }

    func testAlertSeverityIsOrdered() {
        XCTAssertLessThan(Alert.Severity.low, Alert.Severity.medium)
        XCTAssertLessThan(Alert.Severity.medium, Alert.Severity.high)
        XCTAssertEqual([Alert.Severity.high, .low, .medium].max(), .high)
    }

    func testHostValidation() {
        XCTAssertTrue(Secret.isValidHost("api.anthropic.com"))
        XCTAssertTrue(Secret.isValidHost("a"))
        XCTAssertTrue(Secret.isValidHost("foo-bar.example.com"))
        XCTAssertFalse(Secret.isValidHost(""))
        XCTAssertFalse(Secret.isValidHost("-leading.example.com"))
        XCTAssertFalse(Secret.isValidHost("trailing-.example.com"))
        XCTAssertFalse(Secret.isValidHost("under_score.example.com"))
        XCTAssertFalse(Secret.isValidHost("api..example.com"))
        XCTAssertFalse(Secret.isValidHost(String(repeating: "a", count: 64) + ".example.com"))
    }

    func testNameValidation() {
        XCTAssertNoThrow(try Secret.validateName("anthropic_api_key"))
        XCTAssertNoThrow(try Secret.validateName("a"))
        XCTAssertNoThrow(try Secret.validateName(String(repeating: "x", count: 64)))
        XCTAssertThrowsError(try Secret.validateName(""))
        XCTAssertThrowsError(try Secret.validateName("has space"))
        XCTAssertThrowsError(try Secret.validateName("dotted.name"))
        XCTAssertThrowsError(try Secret.validateName(String(repeating: "x", count: 65)))
    }
}
