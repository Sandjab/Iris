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
}
