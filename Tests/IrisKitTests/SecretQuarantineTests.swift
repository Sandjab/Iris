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

    func testSetQuarantinedTogglesFlag() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "a", allowedHosts: ["h"], createdAt: Date())
        let q = try await store.setQuarantined(true, named: "a")
        XCTAssertTrue(q.quarantined)
        let back = try await store.setQuarantined(false, named: "a")
        XCTAssertFalse(back.quarantined)
    }

    func testSetQuarantinedUnknownThrows() async throws {
        let store = InMemorySecretStore()
        do {
            _ = try await store.setQuarantined(true, named: "ghost")
            XCTFail("expected unknownSecret")
        } catch SecretStoreError.unknownSecret {}
    }

    func testUpdatePreservesQuarantined() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "a", allowedHosts: ["h"], createdAt: Date())
        _ = try await store.setQuarantined(true, named: "a")
        let updated = try await store.update(named: "a", allowedHosts: ["h2"])
        XCTAssertTrue(updated.quarantined, "editing allowed_hosts must not lift quarantine")
        XCTAssertEqual(updated.allowedHosts, ["h2"])
    }

    func testRecordUsagePreservesQuarantined() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "a", allowedHosts: ["h"], createdAt: Date())
        _ = try await store.setQuarantined(true, named: "a")
        let used = try await store.recordUsage(of: "a", at: Date())
        XCTAssertTrue(used.quarantined)
    }

    func testRotatePreservesQuarantined() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "a", allowedHosts: ["h"], createdAt: Date())
        _ = try await store.setQuarantined(true, named: "a")
        let rotated = try await store.rotate(named: "a", newValue: Data("w".utf8))
        XCTAssertTrue(rotated.quarantined)
    }
}
