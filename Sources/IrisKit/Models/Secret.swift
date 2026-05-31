import Foundation

public struct Secret: Codable, Sendable, Hashable {
    public let name: String
    public let allowedHosts: [String]
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let usageCount: UInt64
    public let quarantined: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case allowedHosts = "allowed_hosts"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case usageCount = "usage_count"
        case quarantined
    }

    public init(
        name: String,
        allowedHosts: [String],
        createdAt: Date,
        lastUsedAt: Date? = nil,
        usageCount: UInt64 = 0,
        quarantined: Bool = false
    ) {
        self.name = name
        self.allowedHosts = allowedHosts
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
        self.quarantined = quarantined
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.allowedHosts = try c.decode([String].self, forKey: .allowedHosts)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.usageCount = try c.decode(UInt64.self, forKey: .usageCount)
        self.quarantined = try c.decodeIfPresent(Bool.self, forKey: .quarantined) ?? false
    }
}

extension Secret {
    public static let nameValidationRegex = #"^[a-zA-Z0-9_-]{1,64}$"#

    public static func validateName(_ name: String) throws {
        guard name.range(of: nameValidationRegex, options: .regularExpression) != nil else {
            throw SecretStoreError.invalidName(name)
        }
    }

    public static func validateAllowedHosts(_ hosts: [String]) throws {
        guard !hosts.isEmpty else {
            throw SecretStoreError.invalidAllowedHosts(hosts)
        }
        for host in hosts where !isValidHost(host) {
            throw SecretStoreError.invalidAllowedHosts(hosts)
        }
    }

    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for char in label {
                if !char.isASCII { return false }
                if !(char.isLetter || char.isNumber || char == "-") { return false }
            }
        }
        return true
    }
}
