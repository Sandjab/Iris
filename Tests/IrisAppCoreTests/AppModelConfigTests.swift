import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelConfigTests: XCTestCase {
    func testLoadConfigFetchesAndStores() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.stubConfig = .default
        try await model.loadConfig(via: admin)
        XCTAssertEqual(admin.calls, ["fetchConfig"])
        XCTAssertEqual(model.config?.version, 1)
        XCTAssertEqual(model.config?.security.onExfilAttempt, .blockAndNotify)
    }

    func testSetConfigCallsRPCThenReloads() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.stubConfig = .default
        admin.stubSetResult = ConfigSetResult(applied: ["security.on_exfil_attempt"], requiresRestart: [])
        let result = try await model.setConfig(
            [ConfigSetParams.Update(key: "security.on_exfil_attempt", value: "block_only")],
            via: admin
        )
        XCTAssertEqual(result.applied, ["security.on_exfil_attempt"])
        XCTAssertEqual(admin.calls, ["setConfig(security.on_exfil_attempt=block_only)", "fetchConfig"])
    }

    func testFakeRecordsAndReturnsConfigStubs() async throws {
        let admin = FakeAdminCalling()
        admin.stubConfig = .default
        admin.stubCATrusted = true
        admin.stubConfigPath = "/tmp/iris/config.json"
        admin.stubCAExportPath = "/tmp/iris/ca.pem"

        _ = try await admin.fetchConfig()
        _ = try await admin.setConfig(updates: [ConfigSetParams.Update(key: "backups.max_count", value: "3")])
        _ = try await admin.reloadConfig()
        let cfgPath = try await admin.configPath()
        let trusted = try await admin.isCATrusted()
        let caPath = try await admin.caExportPath()

        XCTAssertEqual(cfgPath, "/tmp/iris/config.json")
        XCTAssertTrue(trusted)
        XCTAssertEqual(caPath, "/tmp/iris/ca.pem")
        XCTAssertEqual(
            admin.calls,
            [
                "fetchConfig", "setConfig(backups.max_count=3)", "reloadConfig", "configPath", "isCATrusted",
                "caExportPath",
            ]
        )
    }
}
