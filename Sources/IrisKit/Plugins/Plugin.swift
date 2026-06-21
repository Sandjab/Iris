import Foundation

/// A plugin as presented to the CLI/UI: its manifest plus the persisted state,
/// plus a derived display status. P1 has no running process, so `displayState`
/// is computed purely from persisted flags + the TOFU hash check.
public struct Plugin: Codable, Sendable, Hashable {
    public let manifest: PluginManifest
    public let enabled: Bool
    public let order: Int
    public let approvedCapabilities: PluginCapabilities?
    public let pinnedHash: String
    /// Whether the current on-disk content still matches the pinned hash (TOFU).
    public let hashMatches: Bool

    enum CodingKeys: String, CodingKey {
        case manifest, enabled, order
        case approvedCapabilities = "approved_capabilities"
        case pinnedHash = "pinned_hash"
        case hashMatches = "hash_matches"
    }

    public init(
        manifest: PluginManifest,
        enabled: Bool,
        order: Int,
        approvedCapabilities: PluginCapabilities?,
        pinnedHash: String,
        hashMatches: Bool
    ) {
        self.manifest = manifest
        self.enabled = enabled
        self.order = order
        self.approvedCapabilities = approvedCapabilities
        self.pinnedHash = pinnedHash
        self.hashMatches = hashMatches
    }

    public enum DisplayState: String, Codable, Sendable {
        case disabled
        case enabled
        case needsReapproval  // on-disk content changed since the pin
    }

    public var displayState: DisplayState {
        if !hashMatches { return .needsReapproval }
        return enabled ? .enabled : .disabled
    }
}
