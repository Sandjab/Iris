import IrisKit
import UserNotifications
import XCTest

@testable import IrisAppCore

final class NotificationBuilderTests: XCTestCase {
    private func makeAlertEvent(
        severity: Alert.Severity,
        kind: Event.Kind = .exfilBlocked,
        secretName: String = "anthropic_api_key",
        host: String = "api.github.com",
        snippet: String = "x-api-key: REDACTED"
    ) -> Event {
        let alert = Alert(
            severity: severity,
            rule: .hostMismatch,
            secretName: secretName,
            detectedAt: .header,
            snippet: snippet
        )
        return Event(
            timestamp: Date(),
            kind: kind,
            host: host,
            method: "POST",
            path: "/issues",
            alert: kind == .exfilBlocked ? alert : nil
        )
    }

    func testReturnsNilForSubstitutedEvent() {
        let evt = Event(
            timestamp: Date(),
            kind: .substituted,
            host: "x.com",
            method: "GET",
            path: "/"
        )
        XCTAssertNil(NotificationBuilder.build(from: evt))
    }

    func testReturnsNilForLowSeverityAlert() {
        let evt = makeAlertEvent(severity: .low)
        XCTAssertNil(NotificationBuilder.build(from: evt))
    }

    func testReturnsContentForMediumSeverity() {
        let evt = makeAlertEvent(severity: .medium)
        let content = NotificationBuilder.build(from: evt)
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Exfiltration attempt blocked")
        XCTAssertTrue(content?.subtitle.contains("anthropic_api_key") == true)
        XCTAssertTrue(content?.subtitle.contains("api.github.com") == true)
    }

    func testUserInfoCarriesEventID() {
        let evt = makeAlertEvent(severity: .high)
        let content = NotificationBuilder.build(from: evt)
        XCTAssertEqual(content?.userInfo["event_id"] as? String, evt.id.uuidString)
    }

    /// CLAUDE.md §6.2 invariant: notification content NEVER leaks the raw secret value.
    /// We construct an event whose snippet (Alert.snippet) is by design redacted, then assert
    /// that the rendered title/subtitle/body never substring-contains a known secret value
    /// that we DID NOT pass into the alert. This locks the contract: builder never invents
    /// or splices values from anywhere other than alert.snippet (which is redaction-locked
    /// by Phase 4 PlaceholderScanner).
    func testNotificationContentNeverContainsSecretValue() {
        let dangerousValue = "sk-ant-this-must-never-appear-12345"
        let evt = makeAlertEvent(
            severity: .high,
            secretName: "anthropic_api_key",
            snippet: "x-api-key: {{kc:anthropic_api_key}}"
        )
        let content = NotificationBuilder.build(from: evt)!
        XCTAssertFalse(content.title.contains(dangerousValue))
        XCTAssertFalse(content.subtitle.contains(dangerousValue))
        XCTAssertFalse(content.body.contains(dangerousValue))
    }
}
