import Foundation
import Security

/// Builds the per-binary Keychain ACL that grants silent read access ONLY to the
/// signed `irisd` binary and prompts/denies every other process (CLAUDE.md §6.2,
/// SPECS §12.3). Design: `docs/superpowers/specs/2026-06-03-phase-8b-keychain-acl-design.md`.
public enum KeychainACL {
    /// Item name shown in the system consent dialog when a non-trusted process
    /// tries to read the secret. Mirrors the Keychain service/account naming.
    public static func accessDescription(forSecret name: String) -> String {
        "io.iris.secret.\(name)"
    }

    /// Item name shown in the consent dialog for the CA private key.
    public static func caPrivateKeyDescription() -> String {
        "io.iris.ca.privatekey"
    }

    /// Builds a `SecAccess` whose restricted operations (decrypt/read) are silent
    /// ONLY for the calling binary (`irisd`) and prompt every other process.
    /// Passing `nil` as the trusted list means "trust only the calling app"
    /// (Apple docs, `SecAccessCreate`). The security property is structural —
    /// carried by the `nil`, not by a policy table.
    ///
    /// Uses the deprecated `SecAccessCreate` (SecKeychain family): the modern
    /// data-protection keychain has no per-binary ACL primitive. This is a
    /// deliberate, documented exception to CLAUDE.md §5 (design 8b §3). The lone
    /// deprecation warning is localized here and non-fatal (CI has no
    /// warnings-as-errors). Smoke-only: relies on the calling binary being
    /// Developer-ID signed for a stable identity.
    public static func selfOnlyAccess(description: String) throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate(description as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainACLError.creationFailed(status)
        }
        return access
    }
}

/// Failure building a Keychain `SecAccess`. Propagated through the stores'
/// existing `throws` (`add` / `storeKey`).
public enum KeychainACLError: Error, LocalizedError, Equatable {
    case creationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain ACL creation failed: \(message ?? "OSStatus \(status)")"
        }
    }
}
