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

    func testEnsureCAIsIdempotentWithinSameManager() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID()).pem")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempPath) }
        let manager = CAManager(
            keyStore: InMemoryCAKeyStore(),
            options: .init(publicCertPath: tempPath)
        )
        let first = try await manager.ensureCA()
        let second = try await manager.ensureCA()
        XCTAssertEqual(first.fingerprintSHA256, second.fingerprintSHA256)
        XCTAssertEqual(first.derBytes, second.derBytes)
    }

    func testEnsureCAIsIdempotentAcrossManagerInstances() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID()).pem")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempPath) }
        let key = P256.Signing.PrivateKey()
        let store = InMemoryCAKeyStore(initial: key)
        let first = try await CAManager(
            keyStore: store,
            options: .init(publicCertPath: tempPath)
        ).ensureCA()
        // Same key store + same on-disk PEM = same cert. Simulates daemon restart.
        let second = try await CAManager(
            keyStore: store,
            options: .init(publicCertPath: tempPath)
        ).ensureCA()
        XCTAssertEqual(first.fingerprintSHA256, second.fingerprintSHA256)
    }

    func testInMemoryKeyStoreDeleteKeyIsIdempotent() async throws {
        let store = InMemoryCAKeyStore()
        _ = try await store.loadOrGenerateKey()  // key now present
        let first = try await store.deleteKey()
        XCTAssertTrue(first, "deleting an existing key returns true")
        let loaded = try await store.loadKey()
        XCTAssertNil(loaded, "key is gone after delete")
        let second = try await store.deleteKey()
        XCTAssertFalse(second, "deleting an absent key returns false (idempotent)")
    }

    func testEnsureCARegeneratesWhenOnDiskCertHasMismatchingKey() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID()).pem")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempPath) }
        // Seed disk with a cert signed by a different key.
        let firstKey = P256.Signing.PrivateKey()
        _ = try await CAManager(
            keyStore: InMemoryCAKeyStore(initial: firstKey),
            options: .init(publicCertPath: tempPath)
        ).ensureCA()

        // Run a second manager with a different key — must regenerate, not
        // serve the stale on-disk cert (which would no longer chain to its
        // signing key).
        let secondKey = P256.Signing.PrivateKey()
        let regenerated = try await CAManager(
            keyStore: InMemoryCAKeyStore(initial: secondKey),
            options: .init(publicCertPath: tempPath)
        ).ensureCA()
        let parsed = try Certificate(derEncoded: Array(regenerated.derBytes))
        XCTAssertEqual(parsed.publicKey, Certificate.PublicKey(secondKey.publicKey))
    }
}
