import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelUninstallTests: XCTestCase {
    private func makeModel(
        ca: FakeCATrustInstaller = FakeCATrustInstaller(),
        shell: FakeShellConfigurator = FakeShellConfigurator(),
        autoStart: FakeAutoStartService = FakeAutoStartService(),
        mcp: FakeMCPUnwrapper = FakeMCPUnwrapper()
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "io.iris.app.tests.\(UUID().uuidString)")!,
            caInstaller: ca,
            shellConfigurator: shell,
            autoStart: autoStart,
            mcpUnwrapper: mcp
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
        let ca = FakeCATrustInstaller()
        ca.shouldThrow = Boom()
        let autoStart = FakeAutoStartService()
        let model = makeModel(ca: ca, autoStart: autoStart)

        let report = await model.uninstall(deleteSecrets: false, via: admin)

        XCTAssertTrue(report.failures.contains { $0.step == .ca })
        XCTAssertTrue(report.steps.contains(.unregisterDaemon))
        XCTAssertTrue(report.steps.contains(.shell))
    }
}
