import Crypto
import X509
import XCTest

@testable import IrisKit

final class LeafCertCacheTests: XCTestCase {
    func testMintsLeafSignedByCA() async throws {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        let caCert = try await caManager.ensureCA()
        let parsedCA = try Certificate(derEncoded: Array(caCert.derBytes))

        let cache = LeafCertCache(caManager: caManager)
        let leaf = try await cache.leaf(forHost: "example.com")

        // Round-trip the NIO cert into an X509 Certificate to inspect it.
        let derBytes = try leaf.nioCertificate.toDERBytes()
        let leafCert = try Certificate(derEncoded: Array(derBytes))

        // The issuer of the leaf must match the CA's subject.
        XCTAssertEqual(leafCert.issuer, parsedCA.subject)

        // CN of the leaf should be the requested host.
        let subjectDescription = String(describing: leafCert.subject)
        XCTAssertTrue(subjectDescription.contains("example.com"))

        // SAN should include the host.
        let san = try leafCert.extensions.subjectAlternativeNames
        XCTAssertNotNil(san)
        let names = san!.map { String(describing: $0) }.joined(separator: ",")
        XCTAssertTrue(names.contains("example.com"))
    }

    func testCacheReturnsSameLeafForSameHost() async throws {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let cache = LeafCertCache(caManager: caManager)
        let first = try await cache.leaf(forHost: "host1.example.com")
        let second = try await cache.leaf(forHost: "host1.example.com")
        let firstBytes = try first.nioCertificate.toDERBytes()
        let secondBytes = try second.nioCertificate.toDERBytes()
        XCTAssertEqual(firstBytes, secondBytes)
    }

    func testDifferentHostsGetDifferentLeaves() async throws {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let cache = LeafCertCache(caManager: caManager)
        let a = try await cache.leaf(forHost: "alpha.example.com")
        let b = try await cache.leaf(forHost: "beta.example.com")
        let aBytes = try a.nioCertificate.toDERBytes()
        let bBytes = try b.nioCertificate.toDERBytes()
        XCTAssertNotEqual(aBytes, bBytes)
    }

    func testLeafValidityIs90DaysByDefault() async throws {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let cache = LeafCertCache(caManager: caManager)
        let leaf = try await cache.leaf(forHost: "x.example.com")
        let days = leaf.notAfter.timeIntervalSince(leaf.notBefore) / 86_400
        XCTAssertGreaterThan(days, 89.9)
        XCTAssertLessThan(days, 90.1)
    }
}
