import Foundation

public struct Alert: Codable, Sendable, Hashable {
    public let severity: Severity
    public let rule: ExfilRule
    public let secretName: String
    public let detectedAt: Location
    public let snippet: String

    enum CodingKeys: String, CodingKey {
        case severity
        case rule
        case secretName = "secret_name"
        case detectedAt = "detected_at"
        case snippet
    }

    public enum ExfilRule: String, Codable, Sendable, CaseIterable {
        case hostMismatch
        case nonCanonicalLocation
        case multipleSecrets
        case suspiciousContentType
        case volumeAnomaly
    }

    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case low
        case medium
        case high

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            order(of: lhs) < order(of: rhs)
        }

        private static func order(of severity: Severity) -> Int {
            switch severity {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            }
        }
    }

    public enum Location: String, Codable, Sendable, CaseIterable {
        case header
        case queryString
        case urlPath
        case body
    }

    public init(
        severity: Severity,
        rule: ExfilRule,
        secretName: String,
        detectedAt: Location,
        snippet: String
    ) {
        self.severity = severity
        self.rule = rule
        self.secretName = secretName
        self.detectedAt = detectedAt
        self.snippet = snippet
    }
}

/// A daemon-level alert that is **not** tied to an exfiltration attempt, a
/// secret, or a request. It rides the same `Event` channel (ring → SSE →
/// Security tab / `iris logs`) as `Alert`, but carries only a severity and a
/// human-readable message. Introduced for degraded-boot reporting when
/// `config.json` is corrupted (Phase 6.3a): the daemon stays up, re-seeds
/// defaults, and emits a `severity: .high` `SystemAlert` so the recovery is
/// loud and reaches the user.
public struct SystemAlert: Codable, Sendable, Hashable {
    public let severity: Alert.Severity
    public let message: String

    public init(severity: Alert.Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}
