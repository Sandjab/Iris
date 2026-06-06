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
}
