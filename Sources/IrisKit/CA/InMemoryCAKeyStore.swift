import Crypto
import Foundation

public actor InMemoryCAKeyStore: CAKeyStore {
    private var key: P256.Signing.PrivateKey?

    public init(initial: P256.Signing.PrivateKey? = nil) {
        self.key = initial
    }

    public func loadKey() async throws -> P256.Signing.PrivateKey? {
        key
    }

    public func storeKey(_ key: P256.Signing.PrivateKey) async throws {
        // Model the Keychain contract (audit M-1): never overwrite/adopt an
        // existing item — `storeKey` fails on a pre-existing key.
        guard self.key == nil else {
            throw CAError.duplicateCAKey
        }
        self.key = key
    }

    public func deleteKey() async throws -> Bool {
        let had = key != nil
        key = nil
        return had
    }
}
