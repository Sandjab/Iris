import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelShellTests: XCTestCase {
    private func makeModel(_ fake: FakeShellConfigurator) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "io.iris.app.tests.\(UUID().uuidString)")!,
            shellConfigurator: fake
        )
    }

    func testConfigureShellInstallsAndReflectsState() async throws {
        let fake = FakeShellConfigurator()
        let model = makeModel(fake)
        try await model.configureShell()
        XCTAssertTrue(fake.installed)
        XCTAssertEqual(model.shellConfigured, true)
    }

    func testUnconfigureShellRemovesAndReflectsState() async throws {
        let fake = FakeShellConfigurator()
        try fake.install()
        let model = makeModel(fake)
        try await model.unconfigureShell()
        XCTAssertFalse(fake.installed)
        XCTAssertEqual(model.shellConfigured, false)
    }

    func testRefreshShellConfiguredReadsSeam() throws {
        let fake = FakeShellConfigurator()
        try fake.install()
        let model = makeModel(fake)
        model.refreshShellConfigured()
        XCTAssertEqual(model.shellConfigured, true)
    }

    func testConfigureShellPropagatesErrorAndLeavesStateUnchanged() async {
        struct Boom: Error {}
        let fake = FakeShellConfigurator()
        fake.shouldThrow = Boom()
        let model = makeModel(fake)
        do {
            try await model.configureShell()
            XCTFail("expected configureShell to throw")
        } catch {
            // expected
        }
        XCTAssertFalse(fake.installed)
        // refreshShellConfigured() is never reached after the throw → state stays nil.
        XCTAssertNil(model.shellConfigured)
    }
}
