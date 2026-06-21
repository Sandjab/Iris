import Crypto
import Foundation

public protocol CAKeyStore: Sendable {
    func loadKey() async throws -> P256.Signing.PrivateKey?
    /// Persists the CA private key. Must fail (rather than overwrite or adopt) if
    /// a key item already exists — see audit M-1 / `KeychainCAKeyStore.storeKey`.
    func storeKey(_ key: P256.Signing.PrivateKey) async throws
    /// Removes the persisted CA private key. Returns `true` if an item was
    /// removed, `false` if none was present (idempotent).
    func deleteKey() async throws -> Bool
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
