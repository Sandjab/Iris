import Foundation
import Crypto
import NIOSSL
import X509
import SwiftASN1

/// Mints and caches per-host leaf certificates signed by the local CA.
/// SPECS §11.2: validity 90 days, CN+SAN = host, signed by the CA private key.
public actor LeafCertCache {
    public struct Leaf: Sendable {
        public let host: String
        public let nioCertificate: NIOSSLCertificate
        public let nioPrivateKey: NIOSSLPrivateKey
        public let notBefore: Date
        public let notAfter: Date
    }

    private struct CacheEntry: Sendable {
        let leaf: Leaf
    }

    private let caManager: CAManager
    private let validityDays: Int
    private var cache: [String: CacheEntry] = [:]

    public init(caManager: CAManager, validityDays: Int = 90) {
        self.caManager = caManager
        self.validityDays = validityDays
    }

    public func leaf(forHost host: String) async throws -> Leaf {
        if let cached = cache[host] {
            return cached.leaf
        }
        let leaf = try await mint(for: host)
        cache[host] = CacheEntry(leaf: leaf)
        return leaf
    }

    private func mint(for host: String) async throws -> Leaf {
        let caKey = try await caManager.signingKey()
        let issuer = try await caManager.issuerDistinguishedName()

        let leafKey = P256.Signing.PrivateKey()
        let subject: DistinguishedName
        do {
            subject = try DistinguishedName {
                CommonName(host)
            }
        } catch {
            throw CAError.certificateBuildFailed(message: "leaf DN: \(error)")
        }

        // Back-date notBefore by 1h to tolerate sub-second clock skew between
        // mint time and validation time — BoringSSL rounds ASN.1 times to the
        // second, which can briefly flag a freshly-minted cert as not yet valid.
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let later = now.addingTimeInterval(Double(validityDays) * 86_400)

        let extensions: Certificate.Extensions
        do {
            extensions = try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            }
        } catch {
            throw CAError.certificateBuildFailed(message: "leaf extensions: \(error)")
        }

        let serial = Self.randomSerial()
        let cert: Certificate
        do {
            cert = try Certificate(
                version: .v3,
                serialNumber: serial,
                publicKey: Certificate.PublicKey(leafKey.publicKey),
                notValidBefore: notBefore,
                notValidAfter: later,
                issuer: issuer,
                subject: subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: extensions,
                issuerPrivateKey: Certificate.PrivateKey(caKey)
            )
        } catch {
            throw CAError.certificateBuildFailed(message: "leaf certificate: \(error)")
        }

        var serializer = DER.Serializer()
        do {
            try serializer.serialize(cert)
        } catch {
            throw CAError.certificateSerializationFailed(message: "leaf DER: \(error)")
        }
        let der = Array(serializer.serializedBytes)

        let nioCert: NIOSSLCertificate
        do {
            nioCert = try NIOSSLCertificate(bytes: der, format: .der)
        } catch {
            throw CAError.certificateSerializationFailed(message: "NIOSSLCertificate: \(error)")
        }

        let pemKey = leafKey.pemRepresentation
        let nioKey: NIOSSLPrivateKey
        do {
            nioKey = try NIOSSLPrivateKey(bytes: Array(pemKey.utf8), format: .pem)
        } catch {
            throw CAError.certificateSerializationFailed(message: "NIOSSLPrivateKey: \(error)")
        }

        return Leaf(
            host: host,
            nioCertificate: nioCert,
            nioPrivateKey: nioKey,
            notBefore: now,
            notAfter: later
        )
    }

    private static func randomSerial() -> Certificate.SerialNumber {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 0x01 }
        return Certificate.SerialNumber(bytes: bytes)
    }
}
