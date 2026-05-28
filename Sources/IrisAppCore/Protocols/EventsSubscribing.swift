import Foundation
import IrisKit

/// Abstraction for events subscription used by SyncCoordinator.
/// Enables testing with mocks without touching IrisKit.
public protocol EventsSubscribing: Sendable {
    /// Subscribe to live events stream from a given point in time.
    /// Yields either Event or ping heartbeat items.
    func subscribe(since: Date?) async throws -> AsyncThrowingStream<EventsClientItem, Error>
}
