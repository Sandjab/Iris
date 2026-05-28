import Foundation
import IrisKit
import Logging

@MainActor
public final class SyncCoordinator {
    private let model: AppModel
    private let admin: AdminCalling
    private let events: EventsSubscribing
    private let logger: Logger

    public init(
        model: AppModel,
        admin: AdminCalling,
        events: EventsSubscribing,
        logger: Logger = Logger(label: "io.iris.app.sync")
    ) {
        self.model = model
        self.admin = admin
        self.events = events
        self.logger = logger
    }

    /// Initial fetch: probe daemon, snapshot stats + recent events. Idempotent.
    public func bootstrap() async throws {
        do {
            let status = try await admin.fetchStatus()
            let recent = try await admin.queryEvents(since: nil, limit: 100)
            model.daemonStatus = .up(
                stats: status.stats,
                uptime: TimeInterval(status.uptimeS),
                paused: false  // SPECS §15.4 — pause state isn't in daemon.status; infer false on bootstrap
            )
            model.ingestBatch(recent.reversed())  // oldest first → newest will end up at head
        } catch is AdminClientError {
            model.daemonStatus = .down(reason: .notRunning)
        } catch {
            model.daemonStatus = .down(reason: .rpcError(String(describing: error)))
        }
    }
}
