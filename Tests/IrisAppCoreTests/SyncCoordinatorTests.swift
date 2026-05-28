import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    func testBootstrapWithDaemonUpFetchesStatusAndEvents() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.stubStatus = IrisKit.DaemonStatus(
            pid: 42,
            uptimeS: 100,
            version: "test",
            stats: DaemonStats(reqTotal: 5, subTotal: 3, exfilBlockedTotal: 0, errorsTotal: 0)
        )
        admin.stubEvents = [
            Event(
                timestamp: Date(timeIntervalSince1970: 1),
                kind: .substituted,
                host: "x.com",
                method: "GET",
                path: "/"
            )
        ]
        let events = FakeEventsSubscribing()
        let coord = SyncCoordinator(model: model, admin: admin, events: events)

        try await coord.bootstrap()

        XCTAssertEqual(admin.calls, ["status", "queryEvents(since:-1.0,limit:100)"])
        XCTAssertEqual(model.events.count, 1)
        if case .up(let stats, let uptime, let paused) = model.daemonStatus {
            XCTAssertEqual(stats.reqTotal, 5)
            XCTAssertEqual(uptime, 100)
            XCTAssertFalse(paused)
        } else {
            XCTFail("expected .up, got \(model.daemonStatus)")
        }
    }

    func testBootstrapWithDaemonDownSetsDownState() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.shouldThrow = AdminClientError.connectFailed(path: "/tmp/iris.sock", message: "connection refused")
        let events = FakeEventsSubscribing()
        let coord = SyncCoordinator(model: model, admin: admin, events: events)

        try await coord.bootstrap()

        XCTAssertEqual(model.daemonStatus, .down(reason: .notRunning))
        XCTAssertTrue(model.events.isEmpty)
    }

    func testSSEStreamIngestsEvents() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let events = FakeEventsSubscribing()
        let coord = SyncCoordinator(model: model, admin: admin, events: events)

        try await coord.bootstrap()
        let evt = Event(
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .substituted,
            host: "api.example.com",
            method: "GET",
            path: "/x"
        )
        // Pre-buffer event and finish — replayed when runStream calls subscribe.
        events.push(.event(evt))
        events.finish()
        try await coord.runStream()

        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events[0].id, evt.id)
    }

    func testSSESubscribeUsesLastEventTimestampWhenAvailable() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let preExisting = Event(
            timestamp: Date(timeIntervalSince1970: 500),
            kind: .substituted,
            host: "x.com",
            method: "GET",
            path: "/"
        )
        admin.stubEvents = [preExisting]
        let events = FakeEventsSubscribing()
        let coord = SyncCoordinator(model: model, admin: admin, events: events)

        try await coord.bootstrap()
        events.finish()  // pre-buffered → consumed when runStream subscribes
        try await coord.runStream()

        XCTAssertEqual(events.subscribedSince, [Date(timeIntervalSince1970: 500)])
    }

    func testSSEPingItemsAreIgnoredAndDoNotCrash() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let events = FakeEventsSubscribing()
        let coord = SyncCoordinator(model: model, admin: admin, events: events)

        try await coord.bootstrap()
        events.push(.ping)
        events.push(.ping)
        events.finish()
        try await coord.runStream()

        XCTAssertTrue(model.events.isEmpty)
    }
}
