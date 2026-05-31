import Foundation
import Security

public protocol SecretStore: Sendable {
    func add(
        _ value: Data,
        named name: String,
        allowedHosts: [String],
        createdAt: Date
    ) async throws -> Secret

    func update(named name: String, allowedHosts: [String]) async throws -> Secret
    func rotate(named name: String, newValue: Data) async throws -> Secret
    func delete(named name: String) async throws

    func value(forName name: String) async throws -> Data
    func secret(named name: String) async throws -> Secret
    func list() async throws -> [Secret]

    func recordUsage(of name: String, at date: Date) async throws -> Secret
}

public enum SecretStoreError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case invalidAllowedHosts([String])
    case unknownSecret(String)
    case duplicate(String)
    case keychainStatus(OSStatus)
    case dataCorruption(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "Invalid secret name: \(name)"
        case .invalidAllowedHosts(let hosts):
            return "Invalid allowed_hosts: \(hosts)"
        case .unknownSecret(let name):
            return "Unknown secret: \(name)"
        case .duplicate(let name):
            return "Duplicate secret: \(name)"
        case .keychainStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error: \(message ?? "OSStatus \(status)")"
        case .dataCorruption(let reason):
            return "Secret data corruption: \(reason)"
        }
    }
}
