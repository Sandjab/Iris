import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelUninstallTests: XCTestCase {
    private func makeModel(
        ca: FakeCATrustInstaller = FakeCATrustInstaller(),
        shell: FakeShellConfigurator = FakeShellConfigurator(),
        autoStart: FakeAutoStartService = FakeAutoStartService(),
        mcp: FakeMCPUnwrapper = FakeMCPUnwrapper(),
        logPaths: [String] = []
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "io.iris.app.tests.\(UUID().uuidString)")!,
            caInstaller: ca,
            shellConfigurator: shell,
            autoStart: autoStart,
            mcpUnwrapper: mcp,
            daemonLogPaths: logPaths
        )
    }

    func testUninstallRunsRPCBeforeUnregister() async {
        let admin = FakeAdminCalling()
        let autoStart = FakeAutoStartService()
        let model = makeModel(autoStart: autoStart)
        let report = await model.uninstall(deleteSecrets: false, via: admin)

        let rpcIdx = report.steps.firstIndex(of: .rpc)
        let unregIdx = report.steps.firstIndex(of: .unregisterDaemon)
        XCTAssertNotNil(rpcIdx)
        XCTAssertNotNil(unregIdx)
        XCTAssertLessThan(rpcIdx!, unregIdx!)
        XCTAssertTrue(admin.calls.contains("uninstall"))
        XCTAssertEqual(admin.uninstallDeleteSecretsArg, false)
    }

    func testUninstallPropagatesDeleteSecretsFlag() async {
        let admin = FakeAdminCalling()
        let model = makeModel()
        _ = await model.uninstall(deleteSecrets: true, via: admin)
        XCTAssertEqual(admin.uninstallDeleteSecretsArg, true)
    }

    func testUninstallAggregatesErrorsAndContinues() async {
        struct Boom: Error {}
        let admin = FakeAdminCalling()
        admin.stubCATrusted = true  // trust removal only runs (and can fail) when trusted
        let ca = FakeCATrustInstaller()
        ca.shouldThrow = Boom()
        let autoStart = FakeAutoStartService()
        let model = makeModel(ca: ca, autoStart: autoStart)

        let report = await model.uninstall(deleteSecrets: false, via: admin)

        XCTAssertTrue(report.failures.contains { $0.step == .ca })
        XCTAssertTrue(report.steps.contains(.unregisterDaemon))
        XCTAssertTrue(report.steps.contains(.shell))
    }

    func testUninstallSkipsTrustRemovalWhenCANotTrusted() async {
        // When the CA was never added to the trust store, removing it is a no-op,
        // not a failure: `security remove-trusted-cert` would exit non-zero and the
        // user would see a spurious "Could not complete: ca".
        let admin = FakeAdminCalling()
        admin.stubCATrusted = false
        let ca = FakeCATrustInstaller()
        let model = makeModel(ca: ca)

        let report = await model.uninstall(deleteSecrets: false, via: admin)

        XCTAssertFalse(report.failures.contains { $0.step == .ca })
        XCTAssertNil(ca.uninstalledPath)
    }

    func testUninstallQueriesTrustBeforeDeletingCAKey() async {
        // Trust must be checked BEFORE the RPC deletes the CA key. The daemon's
        // is_trusted handler runs `ensureCA()`, which regenerates the key if absent —
        // querying it after deletion resurrects the key the uninstall just removed.
        let admin = FakeAdminCalling()
        admin.stubCATrusted = true
        let model = makeModel()

        _ = await model.uninstall(deleteSecrets: false, via: admin)

        let trustIdx = admin.calls.firstIndex(of: "isCATrusted")
        let rpcIdx = admin.calls.firstIndex(of: "uninstall")
        XCTAssertNotNil(trustIdx)
        XCTAssertNotNil(rpcIdx)
        XCTAssertLessThan(trustIdx!, rpcIdx!)
    }

    func testUninstallDeletesDaemonLogs() async throws {
        // Daemon logs live in world-readable /tmp; "clean uninstall" must remove them.
        let dir = FileManager.default.temporaryDirectory
        let out = dir.appendingPathComponent("irisd-test-\(UUID().uuidString).out.log")
        let err = dir.appendingPathComponent("irisd-test-\(UUID().uuidString).err.log")
        try Data("stdout".utf8).write(to: out)
        try Data("stderr".utf8).write(to: err)

        let admin = FakeAdminCalling()
        let model = makeModel(logPaths: [out.path, err.path])
        _ = await model.uninstall(deleteSecrets: false, via: admin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: err.path))
    }
}
