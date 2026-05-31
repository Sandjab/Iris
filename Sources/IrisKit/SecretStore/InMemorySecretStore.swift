import Foundation

public actor InMemorySecretStore: SecretStore {
    private struct Entry {
        var metadata: Secret
        var value: Data
    }

    private var items: [String: Entry] = [:]

    public init() {}

    public func add(
        _ value: Data,
        named name: String,
        allowedHosts: [String],
        createdAt: Date
    ) async throws -> Secret {
        try Secret.validateName(name)
        try Secret.validateAllowedHosts(allowedHosts)

        if items[name] != nil {
            throw SecretStoreError.duplicate(name)
        }
        let secret = Secret(name: name, allowedHosts: allowedHosts, createdAt: createdAt)
        items[name] = Entry(metadata: secret, value: value)
        return secret
    }

    public func update(named name: String, allowedHosts: [String]) async throws -> Secret {
        try Secret.validateAllowedHosts(allowedHosts)
        guard var entry = items[name] else {
            throw SecretStoreError.unknownSecret(name)
        }
        let updated = Secret(
            name: entry.metadata.name,
            allowedHosts: allowedHosts,
            createdAt: entry.metadata.createdAt,
            lastUsedAt: entry.metadata.lastUsedAt,
            usageCount: entry.metadata.usageCount
        )
        entry.metadata = updated
        items[name] = entry
        return updated
    }

    public func rotate(named name: String, newValue: Data) async throws -> Secret {
        guard var entry = items[name] else {
            throw SecretStoreError.unknownSecret(name)
        }
        entry.value = newValue
        items[name] = entry
        return entry.metadata
    }

    public func delete(named name: String) async throws {
        guard items.removeValue(forKey: name) != nil else {
            throw SecretStoreError.unknownSecret(name)
        }
    }

    public func value(forName name: String) async throws -> Data {
        guard let entry = items[name] else {
            throw SecretStoreError.unknownSecret(name)
        }
        return entry.value
    }

    public func secret(named name: String) async throws -> Secret {
        guard let entry = items[name] else {
            throw SecretStoreError.unknownSecret(name)
        }
        return entry.metadata
    }

    public func list() async throws -> [Secret] {
        items.values
            .map(\.metadata)
            .sorted { $0.name < $1.name }
    }

    public func recordUsage(of name: String, at date: Date) async throws -> Secret {
        guard var entry = items[name] else {
            throw SecretStoreError.unknownSecret(name)
        }
        let updated = Secret(
            name: entry.metadata.name,
            allowedHosts: entry.metadata.allowedHosts,
            createdAt: entry.metadata.createdAt,
            lastUsedAt: date,
            usageCount: entry.metadata.usageCount &+ 1
        )
        entry.metadata = updated
        items[name] = entry
        return updated
    }
}
