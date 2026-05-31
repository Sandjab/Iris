import Foundation
import XCTest

@testable import IrisKit

final class SecretQuarantineTests: XCTestCase {
    func testSecretDefaultsToNotQuarantined() {
        let s = Secret(name: "a", allowedHosts: ["h"], createdAt: Date())
        XCTAssertFalse(s.quarantined)
    }

    func testSecretRoundTripPreservesQuarantined() throws {
        let s = Secret(name: "a", allowedHosts: ["h"], createdAt: Date(), quarantined: true)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Secret.self, from: data)
        XCTAssertTrue(decoded.quarantined)
    }

    func testSecretDecodesLegacyJSONWithoutQuarantinedAsFalse() throws {
        // Simulate a record written before the field existed: encode then drop the key.
        let s = Secret(name: "a", allowedHosts: ["h"], createdAt: Date(), quarantined: true)
        let data = try JSONEncoder().encode(s)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "quarantined")
        let legacy = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Secret.self, from: legacy)
        XCTAssertFalse(decoded.quarantined)
    }
}
