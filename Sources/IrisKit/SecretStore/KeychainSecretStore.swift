import Foundation
import Security

/// Keychain-backed `SecretStore`. Items are stored as `kSecClassGenericPassword`
/// with `service = io.iris.secret` and `account = <name>`, value = secret bytes,
/// generic attribute = JSON-encoded metadata (allowed_hosts, timestamps, usage).
///
/// Phase 1 uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` without
/// per-application ACL. Per-binary ACL via `SecAccessCreateWithOwnerAndACL` is
/// scheduled for Phase 8 (codesign required to bind the ACL to the signed
/// `irisd` identity).
public actor KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "io.iris.secret") {
        self.service = service
    }

    public func add(
        _ value: Data,
        named name: String,
        allowedHosts: [String],
        createdAt: Date
    ) async throws -> Secret {
        try Secret.validateName(name)
        try Secret.validateAllowedHosts(allowedHosts)

        let metadata = StoredMetadata(
            allowedHosts: allowedHosts,
            createdAt: createdAt,
            lastUsedAt: nil,
            usageCount: 0,
            quarantined: false
        )
        let metadataBlob = try encode(metadata)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrGeneric as String: metadataBlob,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return Secret(name: name, allowedHosts: allowedHosts, createdAt: createdAt)
        case errSecDuplicateItem:
            throw SecretStoreError.duplicate(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func update(named name: String, allowedHosts: [String]) async throws -> Secret {
        try Secret.validateAllowedHosts(allowedHosts)
        let current = try fetchSecret(named: name)
        let metadata = StoredMetadata(
            allowedHosts: allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: current.lastUsedAt,
            usageCount: current.usageCount,
            quarantined: current.quarantined
        )
        try updateMetadata(name: name, metadata: metadata)
        return Secret(
            name: name,
            allowedHosts: allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: current.lastUsedAt,
            usageCount: current.usageCount,
            quarantined: current.quarantined
        )
    }

    public func rotate(named name: String, newValue: Data) async throws -> Secret {
        _ = try fetchSecret(named: name)
        let query: [String: Any] = baseQuery(for: name)
        let attrs: [String: Any] = [
            kSecValueData as String: newValue
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch status {
        case errSecSuccess:
            return try fetchSecret(named: name)
        case errSecItemNotFound:
            throw SecretStoreError.unknownSecret(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func delete(named name: String) async throws {
        let query: [String: Any] = baseQuery(for: name)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw SecretStoreError.unknownSecret(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func value(forName name: String) async throws -> Data {
        var query: [String: Any] = baseQuery(for: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError.dataCorruption("expected Data for secret value")
            }
            return data
        case errSecItemNotFound:
            throw SecretStoreError.unknownSecret(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func secret(named name: String) async throws -> Secret {
        try fetchSecret(named: name)
    }

    public func list() async throws -> [Secret] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                throw SecretStoreError.dataCorruption("expected [[String: Any]] for list")
            }
            return try items.compactMap { item in
                guard let name = item[kSecAttrAccount as String] as? String,
                    let blob = item[kSecAttrGeneric as String] as? Data
                else { return nil }
                let metadata = try decode(blob)
                return Secret(
                    name: name,
                    allowedHosts: metadata.allowedHosts,
                    createdAt: metadata.createdAt,
                    lastUsedAt: metadata.lastUsedAt,
                    usageCount: metadata.usageCount,
                    quarantined: metadata.quarantined
                )
            }.sorted { $0.name < $1.name }
        case errSecItemNotFound:
            return []
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func recordUsage(of name: String, at date: Date) async throws -> Secret {
        let current = try fetchSecret(named: name)
        let metadata = StoredMetadata(
            allowedHosts: current.allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: date,
            usageCount: current.usageCount &+ 1,
            quarantined: current.quarantined
        )
        try updateMetadata(name: name, metadata: metadata)
        return Secret(
            name: name,
            allowedHosts: current.allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: date,
            usageCount: current.usageCount &+ 1,
            quarantined: current.quarantined
        )
    }

    public func setQuarantined(_ quarantined: Bool, named name: String) async throws -> Secret {
        let current = try fetchSecret(named: name)
        let metadata = StoredMetadata(
            allowedHosts: current.allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: current.lastUsedAt,
            usageCount: current.usageCount,
            quarantined: quarantined
        )
        try updateMetadata(name: name, metadata: metadata)
        return Secret(
            name: name,
            allowedHosts: current.allowedHosts,
            createdAt: current.createdAt,
            lastUsedAt: current.lastUsedAt,
            usageCount: current.usageCount,
            quarantined: quarantined
        )
    }

    // MARK: - Internals

    private struct StoredMetadata: Codable {
        let allowedHosts: [String]
        let createdAt: Date
        let lastUsedAt: Date?
        let usageCount: UInt64
        let quarantined: Bool

        enum CodingKeys: String, CodingKey {
            case allowedHosts, createdAt, lastUsedAt, usageCount, quarantined
        }

        init(
            allowedHosts: [String],
            createdAt: Date,
            lastUsedAt: Date?,
            usageCount: UInt64,
            quarantined: Bool
        ) {
            self.allowedHosts = allowedHosts
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.usageCount = usageCount
            self.quarantined = quarantined
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.allowedHosts = try c.decode([String].self, forKey: .allowedHosts)
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
            self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            self.usageCount = try c.decode(UInt64.self, forKey: .usageCount)
            self.quarantined = try c.decodeIfPresent(Bool.self, forKey: .quarantined) ?? false
        }
    }

    private func baseQuery(for name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    private func fetchSecret(named name: String) throws -> Secret {
        var query: [String: Any] = baseQuery(for: name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let item = result as? [String: Any],
                let blob = item[kSecAttrGeneric as String] as? Data
            else {
                throw SecretStoreError.dataCorruption("missing metadata blob for \(name)")
            }
            let metadata = try decode(blob)
            return Secret(
                name: name,
                allowedHosts: metadata.allowedHosts,
                createdAt: metadata.createdAt,
                lastUsedAt: metadata.lastUsedAt,
                usageCount: metadata.usageCount,
                quarantined: metadata.quarantined
            )
        case errSecItemNotFound:
            throw SecretStoreError.unknownSecret(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    private func updateMetadata(name: String, metadata: StoredMetadata) throws {
        let blob = try encode(metadata)
        let query: [String: Any] = baseQuery(for: name)
        let attrs: [String: Any] = [
            kSecAttrGeneric as String: blob
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw SecretStoreError.unknownSecret(name)
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    private func encode(_ metadata: StoredMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(metadata)
        } catch {
            throw SecretStoreError.dataCorruption("metadata encode failed: \(error)")
        }
    }

    private func decode(_ data: Data) throws -> StoredMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(StoredMetadata.self, from: data)
        } catch {
            throw SecretStoreError.dataCorruption("metadata decode failed: \(error)")
        }
    }
}
