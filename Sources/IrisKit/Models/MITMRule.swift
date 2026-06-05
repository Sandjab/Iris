import Foundation

public struct MITMRule: Codable, Sendable, Hashable {
    /// Where a host came from. Replaces the former `Source` (`.toml`/`.runtime`).
    /// Wire values stay short: `"default"` for built-in (seeded, protected) hosts,
    /// `"user"` for hosts added via `rule.add`. The Swift case is `builtin` to avoid
    /// the reserved word `default`.
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case builtin = "default"  // seeded host, protected (not deletable via RPC)
        case user  // host added via rule.add
    }

    public let host: String
    public let createdAt: Date
    public let origin: Origin

    enum CodingKeys: String, CodingKey {
        case host
        case createdAt = "created_at"
        case origin
    }

    public init(host: String, createdAt: Date, origin: Origin) {
        self.host = host
        self.createdAt = createdAt
        self.origin = origin
    }
}
