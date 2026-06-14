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
        XCTAssertTrue(model.pausedSnapshot.isEmpty)
    }

    func testSetStreamPausedSnapshotsEventsAndFreezesThem() {
        let model = AppModel(defaults: defaults)
        model.ingest(makeEvent())
        model.ingest(makeEvent())

        // Pausing captures the current events as a frozen snapshot owned by the model.
        model.setStreamPaused(true)
        XCTAssertTrue(model.streamPaused)
        XCTAssertEqual(model.pausedSnapshot.count, 2)
        let frozen = model.pausedSnapshot.map(\.id)
        XCTAssertEqual(frozen, model.events.map(\.id))

        // Events keep flowing in while paused, but the snapshot must stay frozen — this is
        // the bug the fix prevents (a paused Logs list that empties when the view rebuilds).
        model.ingest(makeEvent())
        XCTAssertEqual(model.events.count, 3)
        XCTAssertEqual(model.pausedSnapshot.map(\.id), frozen)

        // Re-asserting pause while already paused must NOT re-capture (no transition).
        model.setStreamPaused(true)
        XCTAssertEqual(model.pausedSnapshot.map(\.id), frozen)

        // A fresh pause cycle re-captures the now-larger event set.
        model.setStreamPaused(false)
        model.setStreamPaused(true)
        XCTAssertEqual(model.pausedSnapshot.count, 3)
    }

    func testSelectedTabPersistsAcrossInstances() {
        let model1 = AppModel(defaults: defaults)
        model1.selectedTab = .security
        let model2 = AppModel(defaults: defaults)
        XCTAssertEqual(model2.selectedTab, .security)
    }

    func testMenubarIconSetDefaultsToBust() {
        // New default menu-bar icon set is the winged-head bust, not the key.
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.menubarIconSet, .bust)
    }

    func testMenubarIconSetPersistsAcrossInstances() {
        let model1 = AppModel(defaults: defaults)
        model1.menubarIconSet = .key
        let model2 = AppModel(defaults: defaults)
        XCTAssertEqual(model2.menubarIconSet, .key)
    }

    func testLastAcknowledgedAtPersists() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let model1 = AppModel(defaults: defaults)
        model1.markAllAlertsRead(now: when)
        let model2 = AppModel(defaults: defaults)
        XCTAssertEqual(model2.lastAcknowledgedAt, when)
    }

    private func makeEvent(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Event.Kind = .substituted,
        host: String = "api.example.com"
    ) -> Event {
        Event(id: id, timestamp: timestamp, kind: kind, host: host, method: "GET", path: "/x")
    }

    private func makeAlertEvent(
        timestamp: Date = Date(),
        severity: Alert.Severity = .high
    ) -> Event {
        let alert = Alert(
            severity: severity,
            rule: .hostMismatch,
            secretName: "anthropic_api_key",
            detectedAt: .header,
            snippet: "x-api-key: {{kc:anthropic_api_key}}"
        )
        return Event(
            timestamp: timestamp,
            kind: .exfilBlocked,
            host: "api.github.com",
            method: "POST",
            path: "/issues",
            alert: alert
        )
    }

    func testIngestAppendsNewestFirst() {
        let model = AppModel(defaults: defaults)
        let older = makeEvent(timestamp: Date(timeIntervalSince1970: 1_000))
        let newer = makeEvent(timestamp: Date(timeIntervalSince1970: 2_000))
        model.ingest(older)
        model.ingest(newer)
        XCTAssertEqual(model.events.map(\.id), [newer.id, older.id])
    }

    func testIngestDedupsByUUID() {
        let model = AppModel(defaults: defaults)
        let id = UUID()
        let e1 = makeEvent(id: id, timestamp: Date(timeIntervalSince1970: 1_000))
        let e2 = makeEvent(id: id, timestamp: Date(timeIntervalSince1970: 2_000))
        model.ingest(e1)
        model.ingest(e2)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events[0].id, id)
    }

    func testIngestRespectsCap() {
        let model = AppModel(defaults: defaults)
        for i in 0..<(AppModel.eventsCap + 50) {
            model.ingest(makeEvent(timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        XCTAssertEqual(model.events.count, AppModel.eventsCap)
    }

    func testExfilEventIsAlsoAddedToAlerts() {
        let model = AppModel(defaults: defaults)
        let evt = makeAlertEvent()
        model.ingest(evt)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.alerts.count, 1)
        XCTAssertEqual(model.alerts[0].id, evt.id)
    }

    func testSystemAlertEventIsAlsoAddedToAlerts() {
        let model = AppModel(defaults: defaults)
        let evt = Event(
            timestamp: Date(),
            kind: .systemAlert,
            host: "config",
            method: "-",
            path: "-",
            systemAlert: SystemAlert(severity: .high, message: "config.json corrupted — defaults re-seeded")
        )
        model.ingest(evt)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.alerts.count, 1)
        XCTAssertEqual(model.alerts[0].id, evt.id)
    }

    func testNonAlertEventIsNotAddedToAlerts() {
        let model = AppModel(defaults: defaults)
        model.ingest(makeEvent(kind: .substituted))
        XCTAssertEqual(model.events.count, 1)
        XCTAssertTrue(model.alerts.isEmpty)
    }

    func testUnreadCountIncrementsForNewAlerts() {
        let model = AppModel(defaults: defaults)
        model.markAllAlertsRead(now: Date(timeIntervalSince1970: 1_000))
        let newAlert = makeAlertEvent(timestamp: Date(timeIntervalSince1970: 2_000))
        model.ingest(newAlert)
        XCTAssertEqual(model.unreadAlertCount, 1)
    }

    func testUnreadCountIgnoresAcknowledgedAlerts() {
        let model = AppModel(defaults: defaults)
        let oldAlert = makeAlertEvent(timestamp: Date(timeIntervalSince1970: 1_000))
        model.ingest(oldAlert)
        model.markAllAlertsRead(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(model.unreadAlertCount, 0)
    }

    func testLastEventTimestampReturnsNewestSeen() {
        let model = AppModel(defaults: defaults)
        XCTAssertNil(model.lastEventTimestamp)
        model.ingest(makeEvent(timestamp: Date(timeIntervalSince1970: 1_000)))
        model.ingest(makeEvent(timestamp: Date(timeIntervalSince1970: 3_000)))
        model.ingest(makeEvent(timestamp: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(model.lastEventTimestamp, Date(timeIntervalSince1970: 3_000))
    }

    func testTogglePauseInvokesAdminPauseWhenUp() async throws {
        let model = AppModel(defaults: defaults)
        model.daemonStatus = .up(stats: .zero, uptime: 0, paused: false)
        let admin = FakeAdminCalling()
        try await model.togglePause(via: admin)
        XCTAssertEqual(admin.calls, ["pause"])
        XCTAssertEqual(
            model.daemonStatus,
            .up(stats: .zero, uptime: 0, paused: true)
        )
    }

    func testTogglePauseInvokesAdminResumeWhenPaused() async throws {
        let model = AppModel(defaults: defaults)
        model.daemonStatus = .up(stats: .zero, uptime: 0, paused: true)
        let admin = FakeAdminCalling()
        try await model.togglePause(via: admin)
        XCTAssertEqual(admin.calls, ["resume"])
        XCTAssertEqual(
            model.daemonStatus,
            .up(stats: .zero, uptime: 0, paused: false)
        )
    }
}
