import Crypto
import X509
import XCTest

@testable import IrisKit

final class CAManagerTests: XCTestCase {
    func testEnsureCAProducesValidPEM() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        XCTAssertTrue(cert.pem.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(cert.pem.contains("-----END CERTIFICATE-----"))
        XCTAssertFalse(cert.derBytes.isEmpty)
        XCTAssertEqual(cert.commonName, "IRIS local CA")
    }

    func testCertificateValiditySpansApproximately10Years() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        let years = cert.notAfter.timeIntervalSince(cert.notBefore) / (365 * 86_400)
        XCTAssertGreaterThan(years, 9.9)
        XCTAssertLessThan(years, 10.1)
    }

    func testSubjectAndIssuerAreEqualAndContainCommonName() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        let parsed = try Certificate(derEncoded: Array(cert.derBytes))
        XCTAssertEqual(parsed.subject, parsed.issuer)
        let description = String(describing: parsed.subject)
        XCTAssertTrue(description.contains("IRIS local CA"))
        XCTAssertTrue(description.contains("iris"))
    }

    func testCertificateIsMarkedAsCA() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        let parsed = try Certificate(derEncoded: Array(cert.derBytes))
        let basicConstraints = try parsed.extensions.basicConstraints
        switch basicConstraints {
        case .isCertificateAuthority:
            break
        default:
            XCTFail("expected BasicConstraints.isCertificateAuthority, got \(String(describing: basicConstraints))")
        }
    }

    func testKeyPersistsAcrossInvocations() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let firstCert = try await manager.ensureCA()
        let secondCert = try await manager.ensureCA()
        let firstParsed = try Certificate(derEncoded: Array(firstCert.derBytes))
        let secondParsed = try Certificate(derEncoded: Array(secondCert.derBytes))
        XCTAssertEqual(firstParsed.publicKey, secondParsed.publicKey)
    }

    func testWritesPEMToDisk() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID()).pem")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempPath)
        }
        let store = InMemoryCAKeyStore()
        let manager = CAManager(
            keyStore: store,
            options: .init(publicCertPath: tempPath)
        )
        let cert = try await manager.ensureCA()
        let onDisk = try String(contentsOf: tempPath, encoding: .utf8)
        XCTAssertEqual(onDisk, cert.pem)
        let attrs = try FileManager.default.attributesOfItem(atPath: tempPath.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o644)
    }

    func testFingerprintIsHexWithColons() async throws {
        let store = InMemoryCAKeyStore()
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        let parts = cert.fingerprintSHA256.split(separator: ":")
        XCTAssertEqual(parts.count, 32)
        for part in parts {
            XCTAssertEqual(part.count, 2)
            XCTAssertTrue(part.allSatisfy { $0.isHexDigit })
        }
    }

    func testInMemoryKeyStoreReusesProvidedKey() async throws {
        let key = P256.Signing.PrivateKey()
        let store = InMemoryCAKeyStore(initial: key)
        let manager = CAManager(keyStore: store)
        let cert = try await manager.ensureCA()
        let parsed = try Certificate(derEncoded: Array(cert.derBytes))
        let expected = Certificate.PublicKey(key.publicKey)
        XCTAssertEqual(parsed.publicKey, expected)
    }
}
