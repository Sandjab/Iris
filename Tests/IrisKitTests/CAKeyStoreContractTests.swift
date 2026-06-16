import Crypto
import XCTest

@testable import IrisKit

/// Regression for audit finding M-1: a `CAKeyStore` must never silently
/// overwrite/adopt a key item that already exists. The Keychain implementation
/// stores the CA key with `SecItemAdd` and fails on `errSecDuplicateItem`
/// (mirroring `KeychainSecretStore.add`) so that a private key pre-positioned by
/// another local process is rejected loudly instead of being adopted and used to
/// mint the root CA. `InMemoryCAKeyStore` models that contract.
final class CAKeyStoreContractTests: XCTestCase {
    func testStoreKeyRejectsPreexistingItem() async throws {
        let store = InMemoryCAKeyStore()
        let first = P256.Signing.PrivateKey()
        try await store.storeKey(first)

        let second = P256.Signing.PrivateKey()
        do {
            try await store.storeKey(second)
            XCTFail("expected storeKey to reject a pre-existing item")
        } catch {
            // expected — duplicate rejected
        }

        // The original key must be preserved, not overwritten by the second store.
        let loaded = try await store.loadKey()
        XCTAssertEqual(loaded?.rawRepresentation, first.rawRepresentation)
    }

    func testLoadOrGenerateStillWorksOnFreshStore() async throws {
        let store = InMemoryCAKeyStore()
        let generated = try await store.loadOrGenerateKey()
        let reloaded = try await store.loadOrGenerateKey()
        XCTAssertEqual(generated.rawRepresentation, reloaded.rawRepresentation)
    }
}
