import Foundation
import IrisKit

// MARK: - AdminClient + AdminCalling

extension AdminClient: AdminCalling {
    public func fetchStatus() async throws -> IrisKit.DaemonStatus {
        try await call(.daemonStatus, returning: IrisKit.DaemonStatus.self)
    }

    public func fetchStats() async throws -> DaemonStats {
        try await call(.daemonStats, returning: DaemonStats.self)
    }

    public func pause() async throws {
        _ = try await call(.daemonPause, returning: DaemonPauseResult.self)
    }

    public func resume() async throws {
        _ = try await call(.daemonResume, returning: DaemonPauseResult.self)
    }

    public func queryEvents(since: Date?, limit: Int?) async throws -> [Event] {
        try await call(
            .eventsQuery,
            params: EventsQueryParams(since: since, until: nil, limit: limit, kind: nil, host: nil),
            returning: [Event].self
        )
    }
}

// MARK: - EventsClient + EventsSubscribing

extension EventsClient: EventsSubscribing {
    public func subscribe(since: Date?) async throws -> AsyncThrowingStream<EventsClientItem, Error> {
        try await subscribe(since: since, kinds: nil, host: nil)
    }
}
