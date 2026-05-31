import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelCRUDTests: XCTestCase {
    private func makeModel() -> AppModel {
        AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testAddSecretCallsRPCThenRefetchesAndSorts() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubSecrets = [Secret(name: "zeta", allowedHosts: ["z.com"], createdAt: .distantPast)]
        try await model.addSecret(
            name: "alpha",
            allowedHosts: ["a.com"],
            value: Data("v".utf8),
            via: admin
        )
        XCTAssertEqual(admin.calls, ["addSecret(alpha,hosts:a.com,value:1B)", "listSecrets"])
        XCTAssertEqual(model.secrets.map(\.name), ["alpha", "zeta"])  // sorted by name
    }

    func testDeleteSecretCallsRPCThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubSecrets = [Secret(name: "a", allowedHosts: ["a.com"], createdAt: .distantPast)]
        try await model.deleteSecret(name: "a", via: admin)
        XCTAssertEqual(admin.calls, ["deleteSecret(a)", "listSecrets"])
        XCTAssertTrue(model.secrets.isEmpty)
    }

    func testAddRuleCallsRPCThenRefetchesAndSorts() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubRules = [MITMRule(host: "z.com", createdAt: .distantPast, source: .toml)]
        try await model.addRule(host: "a.com", via: admin)
        XCTAssertEqual(admin.calls, ["addRule(a.com)", "listRules"])
        XCTAssertEqual(model.rules.map(\.host), ["a.com", "z.com"])
    }

    func testMutationErrorPropagatesAndLeavesStateUnchanged() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.shouldThrow = JSONRPCError(code: -32009, message: "secret already exists")
        do {
            try await model.addSecret(
                name: "a",
                allowedHosts: ["a.com"],
                value: Data("v".utf8),
                via: admin
            )
            XCTFail("expected throw")
        } catch let e as JSONRPCError {
            XCTAssertEqual(e.code, -32009)
        }
        XCTAssertTrue(model.secrets.isEmpty)  // no partial state
    }

    func testSecretsStateNeverCarriesValue() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        let secret = "SUPER-SECRET-VALUE-9000"
        try await model.addSecret(
            name: "tok",
            allowedHosts: ["a.com"],
            value: Data(secret.utf8),
            via: admin
        )
        let json = String(data: try JSONEncoder().encode(model.secrets), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(secret), "secret value must never appear in AppModel state (I2)")
    }

    func testSetQuarantinedCallsRPCThenRefetches() async throws {
        let fake = FakeAdminCalling()
        fake.stubSecrets = [Secret(name: "a", allowedHosts: ["h"], createdAt: Date())]
        let model = makeModel()
        try await model.setQuarantined(name: "a", quarantined: true, via: fake)
        XCTAssertTrue(fake.calls.contains("setQuarantined(a,true)"))
        XCTAssertTrue(fake.calls.contains("listSecrets"))
        XCTAssertEqual(model.secrets.first { $0.name == "a" }?.quarantined, true)
    }
}
