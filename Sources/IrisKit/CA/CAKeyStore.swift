import Crypto
import Foundation

public protocol CAKeyStore: Sendable {
    func loadKey() async throws -> P256.Signing.PrivateKey?
    func storeKey(_ key: P256.Signing.PrivateKey) async throws
}

extension CAKeyStore {
    public func loadOrGenerateKey() async throws -> P256.Signing.PrivateKey {
        if let existing = try await loadKey() {
            return existing
        }
        let new = P256.Signing.PrivateKey()
        try await storeKey(new)
        return new
    }
}
