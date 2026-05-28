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

    func testReconnectBackoffFollowsExponentialSequence() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        // Both transports broken → backoff grows monotonically (no reset path hit).
        admin.shouldThrow = AdminClientError.connectFailed(path: "/tmp/iris.sock", message: "connection refused")
        let events = FakeEventsSubscribing()
        events.autoFinishCount = 100  // every subscribe yields an empty, finished stream
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        try await coord.bootstrap()
        try await coord.runStreamWithReconnect(maxAttempts: 6)

        // 6 attempts → 6 sleeps observed (one per attempt after stream end).
        XCTAssertEqual(Array(sleeper.delays.prefix(5)), [1, 2, 4, 8, 16])
    }

    func testReconnectCapsAt30Seconds() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.shouldThrow = AdminClientError.connectFailed(path: "/tmp/iris.sock", message: "connection refused")
        let events = FakeEventsSubscribing()
        events.autoFinishCount = 100
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        try await coord.bootstrap()
        try await coord.runStreamWithReconnect(maxAttempts: 10)

        XCTAssertEqual(Array(sleeper.delays.suffix(2)), [30, 30])
    }

    func testReconnectResetsBackoffAfterSuccessfulStatus() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()  // fetchStatus succeeds throughout
        let events = FakeEventsSubscribing()
        events.autoFinishCount = 100
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        try await coord.bootstrap()
        try await coord.runStreamWithReconnect(maxAttempts: 5)

        // Each attempt: drop → sleep(1s) → fetchStatus succeeds → reset → next loop.
        // So every sleep stays at 1s (not exponential growth) since RPC keeps working.
        XCTAssertEqual(sleeper.delays, [1, 1, 1, 1, 1])
    }

    func testReconnectMarksDaemonDownAfterThreeStatusFailures() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let events = FakeEventsSubscribing()
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        // bootstrap fails (daemon down) → status starts as .down
        admin.shouldThrow = AdminClientError.connectFailed(path: "/tmp/iris.sock", message: "connection refused")
        events.subscribeError = AdminClientError.connectFailed(path: "/tmp/iris.sock", message: "connection refused")
        try await coord.bootstrap()
        // Force a transition to .up so the reconnect path observes 3 status failures
        // demoting back to .down (proves the failure counter triggers the demotion).
        model.daemonStatus = .up(stats: .zero, uptime: 0, paused: false)
        events.autoFinishCount = 4

        try await coord.runStreamWithReconnect(maxAttempts: 4)

        XCTAssertEqual(model.daemonStatus, .down(reason: .notRunning))
    }
}
