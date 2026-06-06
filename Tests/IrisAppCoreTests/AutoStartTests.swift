import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AutoStartTests: XCTestCase {
    private func makeModel(_ fake: FakeAutoStartService) -> AppModel {
        AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, autoStart: fake)
    }

    func testRefreshAutoStartCopiesSeamStatus() {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .daemon)
        fake.setStatus(.requiresApproval, for: .app)
        let model = makeModel(fake)

        model.refreshAutoStart()

        XCTAssertEqual(model.daemonAutoStart, .enabled)
        XCTAssertEqual(model.appAutoStart, .requiresApproval)
    }

    func testEnableDaemonRegistersTargetOnly() async throws {
        let fake = FakeAutoStartService()  // tout .notRegistered par défaut
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: true)

        XCTAssertEqual(fake.calls, ["register(daemon)"])  // app jamais touché
        XCTAssertEqual(model.daemonAutoStart, .enabled)
        XCTAssertEqual(model.appAutoStart, .notRegistered)
    }

    func testDisableAppUnregistersTargetOnly() async throws {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .app)
        fake.setStatus(.enabled, for: .daemon)
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.app, enabled: false)

        XCTAssertEqual(fake.calls, ["unregister(app)"])  // daemon jamais touché
        XCTAssertEqual(model.appAutoStart, .notRegistered)
        XCTAssertEqual(model.daemonAutoStart, .enabled)
    }

    func testEnableIsIdempotentWhenAlreadyEnabled() async throws {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .daemon)
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: true)

        XCTAssertEqual(fake.calls, [])  // skip : aucun register
    }

    func testDisableIsIdempotentWhenAlreadyOff() async throws {
        let fake = FakeAutoStartService()  // .notRegistered
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: false)

        XCTAssertEqual(fake.calls, [])  // skip : aucun unregister
    }

    func testRegisterErrorPropagatesAndLeavesStateUnchanged() async throws {
        struct Boom: Error {}
        let fake = FakeAutoStartService()
        fake.shouldThrow = Boom()
        let model = makeModel(fake)
        model.refreshAutoStart()  // daemonAutoStart = .notRegistered

        do {
            try await model.setAutoStart(.daemon, enabled: true)
            XCTFail("expected setAutoStart to throw")
        } catch {
            // attendu
        }

        XCTAssertEqual(fake.calls, [])  // le fake throw avant d'enregistrer
        XCTAssertEqual(model.daemonAutoStart, .notRegistered)  // pas de refresh après throw
    }

    func testOpenLoginItemsSettingsForwardsToSeam() {
        let fake = FakeAutoStartService()
        let model = makeModel(fake)

        model.openLoginItemsSettings()

        XCTAssertEqual(fake.calls, ["openLoginItemsSettings"])
    }
}
