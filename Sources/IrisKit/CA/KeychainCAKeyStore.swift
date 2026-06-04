import Crypto
import Foundation
import Security

/// Persists the CA private key in the Keychain as a `kSecClassGenericPassword`
/// containing the raw 32-byte P256 private key representation.
///
/// Phase 8b: the create path attaches a per-binary `SecAccess` (`KeychainACL`)
/// granting silent access only to the signed `irisd` binary (CLAUDE.md §6.2).
/// `kSecAttrAccess` replaces `kSecAttrAccessible` (mutually exclusive). NOTE: the
/// key is still loaded as raw bytes to sign leaf certs — SPECS §11.2 ("never
/// exported to memory", i.e. a non-extractable `SecKey`) is a separate hardening
/// card, out of scope for 8b.
public actor KeychainCAKeyStore: CAKeyStore {
    private let service: String
    private let account: String

    public init(service: String = "io.iris.ca", account: String = "privatekey") {
        self.service = service
        self.account = account
    }

    public func loadKey() async throws -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CAError.dataCorruption("expected Data for CA private key")
            }
            do {
                return try P256.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw CAError.dataCorruption("invalid P256 raw representation: \(error)")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw CAError.keychainStatus(status)
        }
    }

    public func storeKey(_ key: P256.Signing.PrivateKey) async throws {
        let raw = key.rawRepresentation

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: raw
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw CAError.keychainStatus(updateStatus)
        }

        let access = try KeychainACL.selfOnlyAccess(
            description: KeychainACL.accessDescription(service: service, account: account)
        )
        let addAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccess as String: access,
        ]
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CAError.keychainStatus(addStatus)
        }
    }
}
