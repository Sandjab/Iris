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

    func testRefreshCATrustReloadAndConfigPath() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.stubConfig = .default
        admin.stubCATrusted = true
        admin.stubConfigPath = "/tmp/iris/config.json"

        try await model.refreshCATrust(via: admin)
        XCTAssertEqual(model.caTrusted, true)

        try await model.reloadConfig(via: admin)
        let path = try await model.configFilePath(via: admin)
        XCTAssertEqual(path, "/tmp/iris/config.json")
        XCTAssertEqual(admin.calls, ["isCATrusted", "reloadConfig", "fetchConfig", "configPath"])
    }

    func testInstallCAExportsPathThenInstallsAndRefreshes() async throws {
        let admin = FakeAdminCalling()
        admin.stubCAExportPath = "/tmp/iris/ca.pem"
        admin.stubCATrusted = true  // post-install refresh sees trusted
        let installer = FakeCATrustInstaller()
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, caInstaller: installer)
        model.caTrusted = false  // not yet trusted → install proceeds

        try await model.installCA(via: admin)

        XCTAssertEqual(installer.installedPath, "/tmp/iris/ca.pem")
        XCTAssertEqual(admin.calls, ["caExportPath", "isCATrusted"])
        XCTAssertEqual(model.caTrusted, true)
    }

    func testInstallCANoopWhenAlreadyTrusted() async throws {
        let admin = FakeAdminCalling()
        let installer = FakeCATrustInstaller()
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, caInstaller: installer)
        model.caTrusted = true
        try await model.installCA(via: admin)
        XCTAssertNil(installer.installedPath)
        XCTAssertEqual(admin.calls, [])  // idempotent: no RPC, no shell-out
    }

    func testUninstallCAExportsPathThenUninstallsAndRefreshes() async throws {
        let admin = FakeAdminCalling()
        admin.stubCAExportPath = "/tmp/iris/ca.pem"
        admin.stubCATrusted = false
        let installer = FakeCATrustInstaller()
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, caInstaller: installer)
        model.caTrusted = true
        try await model.uninstallCA(via: admin)
        XCTAssertEqual(installer.uninstalledPath, "/tmp/iris/ca.pem")
        XCTAssertEqual(admin.calls, ["caExportPath", "isCATrusted"])
        XCTAssertEqual(model.caTrusted, false)
    }
}
