import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    func testBackoffDelayClampsBoundsAndNeverCrashes() {
        let backoffs: [Double] = [1, 2, 4, 8, 16, 30]
        // Regression: attempt == 0 occurs right after a stable-run reset. The old code did
        // backoffs[min(-1, 5)] == backoffs[-1] and crashed with "Index out of range".
        // It must clamp the lower bound to the shortest delay instead.
        XCTAssertEqual(SyncCoordinator.backoffDelay(attempt: 0, backoffs: backoffs), 1)
        XCTAssertEqual(SyncCoordinator.backoffDelay(attempt: 1, backoffs: backoffs), 1)
        XCTAssertEqual(SyncCoordinator.backoffDelay(attempt: 2, backoffs: backoffs), 2)
        XCTAssertEqual(SyncCoordinator.backoffDelay(attempt: 6, backoffs: backoffs), 30)
        XCTAssertEqual(SyncCoordinator.backoffDelay(attempt: 100, backoffs: backoffs), 30)
    }

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

        XCTAssertEqual(
            admin.calls,
            ["status", "queryEvents(since:-1.0,limit:100)", "listSecrets", "listRules", "fetchConfig", "isCATrusted"]
        )
        XCTAssertEqual(model.config?.version, 1)
        XCTAssertEqual(model.caTrusted, false)  // FakeAdminCalling.stubCATrusted default
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

    func testStatsPollUpdatesDaemonStatsWhenUp() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let events = FakeEventsSubscribing()
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        model.daemonStatus = .up(stats: .zero, uptime: 0, paused: false)
        admin.stubStats = DaemonStats(reqTotal: 42, subTotal: 7, exfilBlockedTotal: 1, errorsTotal: 0)

        try await coord.runStatsPoll(intervalSeconds: 5, maxTicks: 3)

        XCTAssertEqual(sleeper.delays, [5, 5, 5])
        if case .up(let stats, _, _) = model.daemonStatus {
            XCTAssertEqual(stats.reqTotal, 42)
        } else {
            XCTFail("expected up")
        }
    }

    func testStatsPollSkipsUpdateIfNotUp() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        let events = FakeEventsSubscribing()
        let sleeper = FakeSleeper()
        let coord = SyncCoordinator(model: model, admin: admin, events: events, sleeper: sleeper)

        model.daemonStatus = .down(reason: .notRunning)

        try await coord.runStatsPoll(intervalSeconds: 5, maxTicks: 2)

        XCTAssertEqual(model.daemonStatus, .down(reason: .notRunning))
        XCTAssertEqual(admin.calls.filter { $0 == "stats" }.count, 0)
    }

    func testBootstrapPopulatesSecretsAndRules() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let admin = FakeAdminCalling()
        admin.stubSecrets = [
            Secret(name: "z", allowedHosts: ["z.com"], createdAt: .distantPast),
            Secret(name: "a", allowedHosts: ["a.com"], createdAt: .distantPast),
        ]
        admin.stubRules = [MITMRule(host: "api.anthropic.com", createdAt: .distantPast, origin: .builtin)]
        let coord = SyncCoordinator(model: model, admin: admin, events: FakeEventsSubscribing())

        try await coord.bootstrap()

        XCTAssertEqual(model.secrets.map(\.name), ["a", "z"])  // sorted
        XCTAssertEqual(model.rules.map(\.host), ["api.anthropic.com"])
    }
}
