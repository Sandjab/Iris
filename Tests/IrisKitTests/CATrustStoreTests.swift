import XCTest

@testable import IrisKit

final class CATrustStoreTests: XCTestCase {
    /// The `/usr/bin/security` flags are load-bearing: live testing on macOS 26
    /// showed that an `add-trusted-cert` invocation WITHOUT `-k <login keychain>`
    /// returns success but silently fails to persist the trust setting, and that
    /// `-r trustRoot` is what marks the cert an always-trusted root. Lock the
    /// exact vector so a refactor can't drop a flag and break the install.
    func testAddTrustedCertArgumentsAreLoadBearing() {
        let args = CATrustStore.addTrustedCertArguments(
            pemPath: "/tmp/ca.pem",
            loginKeychainPath: "/keys/login.keychain-db"
        )
        XCTAssertEqual(
            args,
            ["add-trusted-cert", "-r", "trustRoot", "-k", "/keys/login.keychain-db", "/tmp/ca.pem"]
        )
    }

    func testRemoveTrustedCertArguments() {
        let args = CATrustStore.removeTrustedCertArguments(pemPath: "/tmp/ca.pem")
        XCTAssertEqual(args, ["remove-trusted-cert", "/tmp/ca.pem"])
    }
}
