import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "io.iris.app.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testInitialState() {
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.daemonStatus, .connecting)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(model.alerts.isEmpty)
        XCTAssertEqual(model.unreadAlertCount, 0)
        XCTAssertFalse(model.streamPaused)
        XCTAssertEqual(model.logFilters, LogFilters())
        XCTAssertNil(model.focusedAlertID)
        XCTAssertEqual(model.selectedTab, .overview)
    }

    func testSelectedTabPersistsAcrossInstances() {
        let model1 = AppModel(defaults: defaults)
        model1.selectedTab = .security
        let model2 = AppModel(defaults: defaults)
        XCTAssertEqual(model2.selectedTab, .security)
    }

    func testLastAcknowledgedAtPersists() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let model1 = AppModel(defaults: defaults)
        model1.markAllAlertsRead(now: when)
        let model2 = AppModel(defaults: defaults)
        XCTAssertEqual(model2.lastAcknowledgedAt, when)
    }
}
