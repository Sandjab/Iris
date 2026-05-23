import Foundation
import Crypto

public actor InMemoryCAKeyStore: CAKeyStore {
    private var key: P256.Signing.PrivateKey?

    public init(initial: P256.Signing.PrivateKey? = nil) {
        self.key = initial
    }

    public func loadKey() async throws -> P256.Signing.PrivateKey? {
        key
    }

    public func storeKey(_ key: P256.Signing.PrivateKey) async throws {
        self.key = key
    }
}
