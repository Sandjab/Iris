import Crypto
import Foundation
import Security

/// Reads the macOS user trust store to determine whether the IRIS CA is
/// trusted by the current user. Pure read, so no signed-binary entitlement
/// is needed. Backs the `ca.is_trusted` admin RPC (SPECS §13.2).
public enum CATrustStore {
    /// Returns `true` iff a user-domain trust setting exists for a certificate
    /// whose SHA-256 DER fingerprint matches `fingerprintSHA256`. The input
    /// follows the colon-separated lowercase hex format produced by
    /// `CACertificate.fingerprintSHA256`; case and `:` separators are
    /// normalised before comparison.
    public static func isTrusted(fingerprintSHA256: String) -> Bool {
        let target =
            fingerprintSHA256
            .lowercased()
            .replacingOccurrences(of: ":", with: "")

        var certs: CFArray?
        let status = SecTrustSettingsCopyCertificates(.user, &certs)
        // `errSecNoTrustSettings` = -25263 means the user has never added any
        // entries; that's a "not trusted" answer, not an error.
        if status == errSecNoTrustSettings { return false }
        guard status == errSecSuccess, let array = certs as? [SecCertificate] else {
            return false
        }

        for cert in array {
            let der = SecCertificateCopyData(cert) as Data
            let hex =
                SHA256.hash(data: der)
                .map { String(format: "%02x", $0) }
                .joined()
            if hex == target { return true }
        }
        return false
    }
}
