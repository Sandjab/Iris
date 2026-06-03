import Foundation
import Security
import XCTest

@testable import IrisKit

final class CATrustStoreTests: XCTestCase {
    /// The SecCertificate we'd hand to the trust store must be byte-identical
    /// to the CA we generated — otherwise `install` would trust the wrong cert
    /// (or none), silently breaking MITM verification.
    func testMakeCertificateFromValidPEMRoundTripsDER() async throws {
        let manager = CAManager(keyStore: InMemoryCAKeyStore())
        let ca = try await manager.ensureCA()

        let cert = try CATrustStore.makeCertificate(fromPEM: ca.pem)

        let der = SecCertificateCopyData(cert) as Data
        XCTAssertEqual(der, ca.derBytes)
    }

    func testMakeCertificateFromGarbageThrows() {
        XCTAssertThrowsError(try CATrustStore.makeCertificate(fromPEM: "not a pem"))
    }

    func testMakeCertificateFromEmptyThrows() {
        XCTAssertThrowsError(try CATrustStore.makeCertificate(fromPEM: ""))
    }
}
