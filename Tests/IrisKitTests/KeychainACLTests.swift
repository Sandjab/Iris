import XCTest

@testable import IrisKit

final class KeychainACLTests: XCTestCase {
    // Le descripteur est le nom de l'item affiché dans le panneau de consentement
    // macOS quand un process non-irisd tente de lire l'item, et il calque le
    // nommage service/account du Keychain. On le verrouille pour qu'un refactor ne
    // change pas silencieusement ce que voit l'utilisateur ni le contrat de nommage.
    func testSecretAccessDescription() {
        XCTAssertEqual(
            KeychainACL.accessDescription(service: "io.iris.secret", account: "anthropic_api_key"),
            "io.iris.secret.anthropic_api_key"
        )
    }

    func testCAPrivateKeyDescription() {
        XCTAssertEqual(
            KeychainACL.accessDescription(service: "io.iris.ca", account: "privatekey"),
            "io.iris.ca.privatekey"
        )
    }

    func testACLErrorHasNonEmptyDescription() {
        let error = KeychainACLError.creationFailed(errSecParam)
        XCTAssertFalse((error.errorDescription ?? "").isEmpty)
    }
}
