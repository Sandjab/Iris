import Crypto
import Foundation
import SwiftASN1
import X509

public actor CAManager {
    public struct Options: Sendable, Hashable {
        public var commonName: String
        public var organization: String
        public var validityYears: Int
        public var publicCertPath: URL?

        public init(
            commonName: String = "IRIS local CA",
            organization: String = "iris",
            validityYears: Int = 10,
            publicCertPath: URL? = nil
        ) {
            self.commonName = commonName
            self.organization = organization
            self.validityYears = validityYears
            self.publicCertPath = publicCertPath
        }
    }

    private let keyStore: any CAKeyStore
    private let options: Options

    public init(keyStore: any CAKeyStore, options: Options = .init()) {
        self.keyStore = keyStore
        self.options = options
    }

    public func ensureCA() async throws -> CACertificate {
        let key = try await keyStore.loadOrGenerateKey()

        // Reuse the on-disk certificate when it still matches our signing
        // key and hasn't expired. Without this, every restart rebuilt the
        // certificate (random serial + fresh notBefore + ECDSA nonce),
        // producing a new fingerprint and silently invalidating any trust
        // store entry the user had set up.
        if let existing = try? loadCertificateMatching(key: key) {
            return existing
        }

        let cert = try makeSelfSignedCertificate(signingKey: key)
        if let path = options.publicCertPath {
            try writePEM(cert.pem, to: path)
        }
        return cert
    }

    private func loadCertificateMatching(
        key: P256.Signing.PrivateKey
    ) throws -> CACertificate? {
        guard let path = options.publicCertPath,
            let pemString = try? String(contentsOf: path, encoding: .utf8)
        else {
            return nil
        }

        let pemDoc: PEMDocument
        let cert: Certificate
        do {
            pemDoc = try PEMDocument(pemString: pemString)
            cert = try Certificate(pemDocument: pemDoc)
        } catch {
            return nil
        }

        // Reject if the cert was issued for a different key — the key store
        // and the on-disk PEM are out of sync, regenerate to recover.
        guard cert.publicKey == Certificate.PublicKey(key.publicKey) else {
            return nil
        }

        // Reject if the cert's subject no longer matches our options (e.g.
        // commonName/organization were reconfigured). Without this, the
        // returned CACertificate metadata could lie about the bytes.
        let expectedSubject = try DistinguishedName {
            CommonName(options.commonName)
            OrganizationName(options.organization)
        }
        guard cert.subject == expectedSubject else {
            return nil
        }

        // Reject if expired or not yet valid (clock skew aside, we leave
        // the 1h backdate margin in the freshly-generated path).
        let now = Date()
        guard cert.notValidBefore <= now, cert.notValidAfter > now else {
            return nil
        }

        let der = Data(pemDoc.derBytes)
        let hash = SHA256.hash(data: der)
        let hexBytes = hash.map { String(format: "%02x", $0) }
        let fingerprint = hexBytes.joined(separator: ":")

        return CACertificate(
            derBytes: der,
            pem: pemString,
            fingerprintSHA256: fingerprint,
            notBefore: cert.notValidBefore,
            notAfter: cert.notValidAfter,
            commonName: options.commonName
        )
    }

    /// Returns the persistent CA signing key, generating it if absent. Used by
    /// `LeafCertCache` to sign per-host leaf certificates.
    public func signingKey() async throws -> P256.Signing.PrivateKey {
        try await keyStore.loadOrGenerateKey()
    }

    /// Returns the issuer DN that leaf certs must reference.
    public func issuerDistinguishedName() throws -> DistinguishedName {
        do {
            return try DistinguishedName {
                CommonName(options.commonName)
                OrganizationName(options.organization)
            }
        } catch {
            throw CAError.certificateBuildFailed(message: "DistinguishedName: \(error)")
        }
    }

    // MARK: - Internals

    private func makeSelfSignedCertificate(
        signingKey: P256.Signing.PrivateKey
    ) throws -> CACertificate {
        let subject: DistinguishedName
        do {
            subject = try DistinguishedName {
                CommonName(options.commonName)
                OrganizationName(options.organization)
            }
        } catch {
            throw CAError.certificateBuildFailed(message: "DistinguishedName: \(error)")
        }

        // Back-date notBefore by 1h to tolerate sub-second clock skew between
        // CA creation and TLS validation (BoringSSL rounds ASN.1 times to the
        // second; a freshly-issued cert can read as "not yet valid").
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let calendar = Calendar(identifier: .gregorian)
        let later =
            calendar.date(byAdding: .year, value: options.validityYears, to: now)
            ?? now.addingTimeInterval(Double(options.validityYears) * 365 * 86_400)

        let extensions: Certificate.Extensions
        do {
            extensions = try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            }
        } catch {
            throw CAError.certificateBuildFailed(message: "Extensions: \(error)")
        }

        let serial = Self.randomSerial()
        let issuerPrivateKey = Certificate.PrivateKey(signingKey)
        let publicKey = Certificate.PublicKey(signingKey.publicKey)

        let cert: Certificate
        do {
            cert = try Certificate(
                version: .v3,
                serialNumber: serial,
                publicKey: publicKey,
                notValidBefore: notBefore,
                notValidAfter: later,
                issuer: subject,
                subject: subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: extensions,
                issuerPrivateKey: issuerPrivateKey
            )
        } catch {
            throw CAError.certificateBuildFailed(message: String(describing: error))
        }

        var serializer = DER.Serializer()
        do {
            try serializer.serialize(cert)
        } catch {
            throw CAError.certificateSerializationFailed(message: String(describing: error))
        }
        let der = Data(serializer.serializedBytes)

        let pemDoc: PEMDocument
        do {
            pemDoc = try cert.serializeAsPEM()
        } catch {
            throw CAError.certificateSerializationFailed(message: "PEM: \(error)")
        }
        let pem = pemDoc.pemString

        let digest = SHA256.hash(data: der)
        let fingerprint =
            digest
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        return CACertificate(
            derBytes: der,
            pem: pem,
            fingerprintSHA256: fingerprint,
            notBefore: notBefore,
            notAfter: later,
            commonName: options.commonName
        )
    }

    private static func randomSerial() -> Certificate.SerialNumber {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        // Strip the high bit so the encoded INTEGER is unambiguously positive.
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 0x01 }
        return Certificate.SerialNumber(bytes: bytes)
    }

    private func writePEM(_ pem: String, to path: URL) throws {
        let directory = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CAError.directoryCreationFailed(path: directory.path)
        }
        guard let data = pem.data(using: .utf8) else {
            throw CAError.pemWriteFailed(path: path.path)
        }
        do {
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: path.path
            )
        } catch {
            throw CAError.pemWriteFailed(path: path.path)
        }
    }
}
