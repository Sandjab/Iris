import Foundation

public struct MITMRule: Codable, Sendable, Hashable {
    public let host: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case host
        case createdAt = "created_at"
    }

    public init(host: String, createdAt: Date) {
        self.host = host
        self.createdAt = createdAt
    }
}
