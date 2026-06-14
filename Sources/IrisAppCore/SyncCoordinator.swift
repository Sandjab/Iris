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
            let secrets = try await admin.listSecrets()
            let rules = try await admin.listRules()
            let config = try await admin.fetchConfig()
            let caTrusted = try await admin.isCATrusted()
            model.daemonStatus = .up(
                stats: status.stats,
                uptime: TimeInterval(status.uptimeS),
                paused: status.paused  // SPECS §15.4 — daemon.status carries the live pause state
            )
            model.ingestBatch(recent.reversed())  // oldest first → newest will end up at head
            model.secrets = secrets.sorted { $0.name < $1.name }
            model.rules = rules.sorted { $0.host < $1.host }
            model.config = config
            model.caTrusted = caTrusted
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
        let stableRunThreshold: TimeInterval = 5.0
        var statusFailures = 0
        var attempt = 0
        var iterations = 0  // Separate from `attempt` so successful reset doesn't dodge the cap.
        while true {
            if let max = maxAttempts, iterations >= max { return }
            iterations += 1
            attempt += 1
            let runStarted = Date()
            do {
                try await runStream()
                // Stream finished cleanly (server closed) → treat as transient drop.
                if Date().timeIntervalSince(runStarted) >= stableRunThreshold {
                    attempt = 0  // Reset backoff: a long stable run earns a fresh 1s start.
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning("SSE stream error: \(error)")
                if Date().timeIntervalSince(runStarted) >= stableRunThreshold {
                    attempt = 0  // Same reset: a long-running connection that errors out also resets.
                }
            }

            let delay = Self.backoffDelay(attempt: attempt, backoffs: backoffs)
            try await sleeper.sleep(seconds: delay)

            do {
                let status = try await admin.fetchStatus()
                statusFailures = 0
                attempt = 0  // Reset backoff so a future drop after stability starts at 1s.
                model.daemonStatus = .up(
                    stats: status.stats,
                    uptime: TimeInterval(status.uptimeS),
                    paused: status.paused
                )
            } catch {
                statusFailures += 1
                if statusFailures >= 3 {
                    model.daemonStatus = .down(reason: .notRunning)
                }
            }
        }
    }

    /// Backoff delay (seconds) for `attempt`, clamped into the table bounds.
    /// `attempt == 0` occurs after a stability reset and maps to the shortest delay;
    /// clamping the lower bound prevents the negative-index crash from `attempt - 1`
    /// when a stream that ran ≥ stableRunThreshold then drops.
    static func backoffDelay(attempt: Int, backoffs: [Double]) -> Double {
        guard !backoffs.isEmpty else { return 0 }
        let index = min(max(attempt - 1, 0), backoffs.count - 1)
        return backoffs[index]
    }

    /// Periodic status poll. Sleeps `intervalSeconds`, fetches `daemon.status`, refreshes
    /// `daemonStatus` (stats, uptime, and pause state) if the daemon is up. Polling the full
    /// status — not just stats — is what propagates an out-of-band `iris pause`/`resume` to the
    /// UI while the SSE stream stays connected (SPECS §15.4, #54).
    /// Skips update if daemon is not up (SSE reconnect path manages state transitions).
    /// Errors are logged at debug level and swallowed; poll errors do not promote daemon to down.
    /// `maxTicks == nil` runs forever (production). Tests pass a finite cap.
    public func runStatsPoll(intervalSeconds: Double = 5, maxTicks: Int? = nil) async throws {
        var ticks = 0
        while true {
            if let max = maxTicks, ticks >= max { return }
            ticks += 1
            try await sleeper.sleep(seconds: intervalSeconds)
            guard case .up = model.daemonStatus else { continue }
            do {
                let status = try await admin.fetchStatus()
                // Re-check after the await: another task (e.g. runStreamWithReconnect)
                // may have transitioned the daemon to .down while the fetch was in
                // flight — don't blindly re-promote it to .up (PR #66 race fix).
                if case .up = model.daemonStatus {
                    model.daemonStatus = .up(
                        stats: status.stats,
                        uptime: TimeInterval(status.uptimeS),
                        paused: status.paused
                    )
                }
            } catch {
                logger.debug("status poll skipped: \(error)")
            }
        }
    }
}
