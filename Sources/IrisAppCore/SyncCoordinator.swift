import Foundation
import IrisKit
import Logging

@MainActor
public final class SyncCoordinator {
    private let model: AppModel
    private let admin: AdminCalling
    private let events: EventsSubscribing
    private let sleeper: AsyncSleeper
    private let logger: Logger

    public init(
        model: AppModel,
        admin: AdminCalling,
        events: EventsSubscribing,
        sleeper: AsyncSleeper = SystemSleeper(),
        logger: Logger = Logger(label: "io.iris.app.sync")
    ) {
        self.model = model
        self.admin = admin
        self.events = events
        self.sleeper = sleeper
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

    /// Consume SSE stream until the underlying stream finishes or is cancelled.
    /// Caller is responsible for relaunching on error (Task 9 handles backoff).
    public func runStream() async throws {
        let since = model.lastEventTimestamp ?? Date(timeIntervalSinceNow: -60)
        let stream = try await events.subscribe(since: since)
        for try await item in stream {
            switch item {
            case .event(let event):
                model.ingest(event)
            case .ping:
                continue
            }
        }
    }

    /// Reconnect loop with exponential backoff. `maxAttempts == nil` runs forever (production).
    /// Tests pass a finite cap. Backoff sequence: 1, 2, 4, 8, 16, 30 s (capped).
    /// After each successful `fetchStatus()`, reset the backoff counter.
    /// After 3 consecutive `fetchStatus()` failures, mark daemon as down.
    public func runStreamWithReconnect(maxAttempts: Int? = nil) async throws {
        let backoffs: [Double] = [1, 2, 4, 8, 16, 30]
        var statusFailures = 0
        var attempt = 0
        var iterations = 0  // Separate from `attempt` so successful reset doesn't dodge the cap.
        while true {
            if let max = maxAttempts, iterations >= max { return }
            iterations += 1
            attempt += 1
            do {
                try await runStream()
                // Stream finished cleanly (server closed) → treat as transient drop.
            } catch is CancellationError {
                return
            } catch {
                logger.warning("SSE stream error: \(error)")
            }

            let delay = backoffs[min(attempt - 1, backoffs.count - 1)]
            try await sleeper.sleep(seconds: delay)

            do {
                let status = try await admin.fetchStatus()
                statusFailures = 0
                attempt = 0  // Reset backoff so a future drop after stability starts at 1s.
                if case .up(_, _, let paused) = model.daemonStatus {
                    model.daemonStatus = .up(
                        stats: status.stats,
                        uptime: TimeInterval(status.uptimeS),
                        paused: paused
                    )
                } else {
                    model.daemonStatus = .up(
                        stats: status.stats,
                        uptime: TimeInterval(status.uptimeS),
                        paused: false
                    )
                }
            } catch {
                statusFailures += 1
                if statusFailures >= 3 {
                    model.daemonStatus = .down(reason: .notRunning)
                }
            }
        }
    }
}
