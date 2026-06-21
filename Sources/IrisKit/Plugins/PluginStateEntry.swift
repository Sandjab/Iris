import Foundation

/// Per-plugin state persisted in `config.json` (never in Keychain — non-secret).
/// The source of truth for the *installed set*: a plugin exists iff it has an entry.
public struct PluginStateEntry: Codable, Sendable, Hashable {
    public let id: String
    public let enabled: Bool
    public let order: Int
    /// Capabilities the user approved at enable time (nil = never enabled yet).
    public let approvedCapabilities: PluginCapabilities?
    /// TOFU: SHA-256 of the plugin directory pinned at install time.
    public let pinnedHash: String
    /// Non-secret plugin config values (schema-driven UI lands in a later phase).
    public let configValues: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, enabled, order
        case approvedCapabilities = "approved_capabilities"
        case pinnedHash = "pinned_hash"
        case configValues = "config_values"
    }

    public init(
        id: String,
        enabled: Bool,
        order: Int,
        approvedCapabilities: PluginCapabilities?,
        pinnedHash: String,
        configValues: [String: String] = [:]
    ) {
        self.id = id
        self.enabled = enabled
        self.order = order
        self.approvedCapabilities = approvedCapabilities
        self.pinnedHash = pinnedHash
        self.configValues = configValues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.approvedCapabilities =
            try c.decodeIfPresent(PluginCapabilities.self, forKey: .approvedCapabilities)
        self.pinnedHash = try c.decode(String.self, forKey: .pinnedHash)
        self.configValues =
            try c.decodeIfPresent([String: String].self, forKey: .configValues) ?? [:]
    }
}
