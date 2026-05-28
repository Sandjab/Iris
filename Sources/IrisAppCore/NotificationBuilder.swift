import Foundation
import IrisKit
import UserNotifications

public enum NotificationBuilder {
    /// SPECS §15.3 — notify only on exfiltration alerts of severity >= medium.
    public static func build(from event: Event) -> UNMutableNotificationContent? {
        guard event.kind == .exfilBlocked, let alert = event.alert else { return nil }
        guard alert.severity >= .medium else { return nil }

        let content = UNMutableNotificationContent()
        content.title = "Exfiltration attempt blocked"
        content.subtitle = "\(alert.secretName) → \(event.host)"
        content.body = "Rule: \(ruleLabel(alert.rule)). Click to inspect."
        content.userInfo = ["event_id": event.id.uuidString]
        return content
    }

    private static func ruleLabel(_ rule: Alert.ExfilRule) -> String {
        switch rule {
        case .hostMismatch: return "host mismatch"
        case .nonCanonicalLocation: return "non-canonical location"
        case .multipleSecrets: return "multiple secrets in one request"
        case .suspiciousContentType: return "suspicious content type"
        case .volumeAnomaly: return "volume anomaly"
        }
    }
}
