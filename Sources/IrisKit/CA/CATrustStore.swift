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

    /// Builds the `/usr/bin/security` argument vector that installs `pemPath`
    /// as an always-trusted root in the user's login keychain. Pure — the
    /// CI-testable seam. The flags are load-bearing: `-r trustRoot` marks the
    /// cert a trusted root, and `-k <login keychain>` is required for the trust
    /// setting to persist (an invocation without it was observed to no-op on
    /// macOS 26).
    public static func addTrustedCertArguments(pemPath: String, loginKeychainPath: String) -> [String] {
        ["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychainPath, pemPath]
    }

    /// Builds the `/usr/bin/security` argument vector that removes `pemPath`'s
    /// user trust settings.
    public static func removeTrustedCertArguments(pemPath: String) -> [String] {
        ["remove-trusted-cert", pemPath]
    }

    /// Installs the CA at `pemPath` into the current user's trust store by
    /// shelling out to the Apple-signed `/usr/bin/security` tool. The native
    /// `SecTrustSettingsSetTrustSettings` API returns `errSecInternalComponent`
    /// (-2070) from a non-Developer-ID-signed binary, so we delegate to
    /// `security` (the macOS convention, cf. mkcert). The system presents a
    /// login-password auth panel and blocks until the user responds — GUI
    /// session required, so this is exercised by manual smoke, not CI.
    public static func install(pemPath: String) throws {
        try runSecurity(addTrustedCertArguments(pemPath: pemPath, loginKeychainPath: loginKeychainPath()))
    }

    /// Removes the CA at `pemPath` from the current user's trust store via
    /// `/usr/bin/security remove-trusted-cert`. Same GUI-auth caveat as `install`.
    public static func uninstall(pemPath: String) throws {
        try runSecurity(removeTrustedCertArguments(pemPath: pemPath))
    }

    // MARK: - Internals

    private static func loginKeychainPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
            .path
    }

    private static func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CAError.trustCommandFailed(status: -1, message: "could not launch /usr/bin/security: \(error)")
        }
        // Drain stderr to EOF (i.e. until `security` exits) BEFORE waiting, so a
        // chatty error can't fill the pipe buffer and deadlock. This also blocks
        // cleanly while `security` shows its auth panel.
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            throw CAError.trustCommandFailed(
                status: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
