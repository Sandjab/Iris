import Crypto
import Foundation
import Security
import SwiftASN1

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

    /// Parses a PEM-encoded certificate into a `SecCertificate`. Pure — no
    /// keychain or trust-store side effects, so it is the CI-testable seam of
    /// the install path. Throws `CAError.dataCorruption` on malformed input.
    public static func makeCertificate(fromPEM pem: String) throws -> SecCertificate {
        let der: Data
        do {
            der = try Data(PEMDocument(pemString: pem).derBytes)
        } catch {
            throw CAError.dataCorruption("invalid CA PEM: \(error)")
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CAError.dataCorruption("SecCertificateCreateWithData returned nil")
        }
        return cert
    }

    /// Adds `cert` to the current user's trust settings as an always-trusted
    /// root (`SecTrustSettingsSetTrustSettings(.user, nil)`; passing `nil`
    /// means "always trust this root regardless of use", valid for a
    /// self-signed root). The system presents a login-password auth panel and
    /// may block — GUI session required, so this is exercised by manual smoke,
    /// not CI.
    public static func install(_ cert: SecCertificate) throws {
        let status = SecTrustSettingsSetTrustSettings(cert, .user, nil)
        guard status == errSecSuccess else {
            throw CAError.trustSettingsFailed(status)
        }
    }

    /// Removes `cert`'s trust settings from the current user's domain
    /// (`SecTrustSettingsRemoveTrustSettings(.user)`). Same GUI-auth caveat as
    /// `install`.
    public static func uninstall(_ cert: SecCertificate) throws {
        let status = SecTrustSettingsRemoveTrustSettings(cert, .user)
        guard status == errSecSuccess else {
            throw CAError.trustSettingsFailed(status)
        }
    }
}
