import Foundation
import Crypto
import X509
import SwiftASN1

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
        let cert = try makeSelfSignedCertificate(signingKey: key)
        if let path = options.publicCertPath {
            try writePEM(cert.pem, to: path)
        }
        return cert
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

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let later = calendar.date(byAdding: .year, value: options.validityYears, to: now)
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
                notValidBefore: now,
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
        let fingerprint = digest
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        return CACertificate(
            derBytes: der,
            pem: pem,
            fingerprintSHA256: fingerprint,
            notBefore: now,
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
