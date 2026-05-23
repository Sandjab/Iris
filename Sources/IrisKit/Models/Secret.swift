import Foundation

public struct Secret: Codable, Sendable, Hashable {
    public let name: String
    public let allowedHosts: [String]
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let usageCount: UInt64

    public init(
        name: String,
        allowedHosts: [String],
        createdAt: Date,
        lastUsedAt: Date? = nil,
        usageCount: UInt64 = 0
    ) {
        self.name = name
        self.allowedHosts = allowedHosts
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
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
