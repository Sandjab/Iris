import Foundation

public struct MITMRule: Codable, Sendable, Hashable {
    public let host: String
    public let createdAt: Date

    public init(host: String, createdAt: Date) {
        self.host = host
        self.createdAt = createdAt
    }
}
