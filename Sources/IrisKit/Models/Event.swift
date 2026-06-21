import Foundation

public struct Event: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let host: String
    public let method: String
    public let path: String
    public let statusCode: Int?
    public let durationMs: UInt32?
    public let substitutedSecrets: [String]
    public let alert: Alert?
    /// Non-nil only for `kind == .systemAlert`. Mutually exclusive with `alert`.
    public let systemAlert: SystemAlert?
    /// Non-nil when `kind` is `.pluginBlocked` or `.pluginResponded`.
    /// Identifies the installed plugin that handled the request.
    /// Never carries a secret value — only the plugin bundle identifier.
    public let pluginId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case kind
        case host
        case method
        case path
        case statusCode = "status_code"
        case durationMs = "duration_ms"
        case substitutedSecrets = "substituted_secrets"
        case alert
        case systemAlert = "system_alert"
        case pluginId = "plugin_id"
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case substituted
        case passThrough
        case noMatch
        case exfilBlocked
        case error
        /// A daemon-level, non-exfil alert (e.g. degraded boot after config
        /// corruption). Carries a `SystemAlert` payload, never an `Alert`.
        case systemAlert
        /// Terminal plugin outcome: a plugin blocked the request; it was NOT
        /// forwarded upstream. `pluginId` identifies the plugin.
        case pluginBlocked
        /// Terminal plugin outcome: a plugin returned a synthetic response; the
        /// request was NOT forwarded upstream. `pluginId` identifies the plugin.
        case pluginResponded
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        kind: Kind,
        host: String,
        method: String,
        path: String,
        statusCode: Int? = nil,
        durationMs: UInt32? = nil,
        substitutedSecrets: [String] = [],
        alert: Alert? = nil,
        systemAlert: SystemAlert? = nil,
        pluginId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.host = host
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.substitutedSecrets = substitutedSecrets
        self.alert = alert
        self.systemAlert = systemAlert
        self.pluginId = pluginId
    }
}
