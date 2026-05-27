import Foundation

public struct MITMRule: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case toml
        case runtime
    }

    public let host: String
    public let createdAt: Date
    public let source: Source

    enum CodingKeys: String, CodingKey {
        case host
        case createdAt = "created_at"
        case source
    }

    public init(host: String, createdAt: Date, source: Source) {
        self.host = host
        self.createdAt = createdAt
        self.source = source
    }
}
