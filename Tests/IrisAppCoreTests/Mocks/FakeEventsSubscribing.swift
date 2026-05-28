import Foundation
import IrisKit

@testable import IrisAppCore

/// AsyncThrowingStream that you can push items into from tests.
///
/// Pre-buffering : `push` and `finish` called BEFORE the first `subscribe`
/// are queued and replayed at subscribe-time, so tests don't need to manage
/// timing between Task creation and consumer registration.
///
/// `autoFinishCount` : number of subscribes that should immediately emit a
/// finish event after returning the stream — used to model rapid SSE drops
/// in reconnect tests without juggling background tasks.
final class FakeEventsSubscribing: EventsSubscribing, @unchecked Sendable {
    var subscribedSince: [Date?] = []
    var subscribeError: Error?
    var autoFinishCount: Int = 0

    private var pending: [AsyncThrowingStream<EventsClientItem, Error>.Continuation] = []
    private var preBuffered: [EventsClientItem] = []
    private var preBufferedFinish: Error??

    func push(_ item: EventsClientItem) {
        if let last = pending.last {
            last.yield(item)
        } else {
            preBuffered.append(item)
        }
    }

    func finish(throwing error: Error? = nil) {
        if let last = pending.last {
            last.finish(throwing: error)
        } else {
            preBufferedFinish = error  // Encodes "finish queued" via outer Optional non-nil.
        }
    }

    func subscribe(since: Date?) async throws -> AsyncThrowingStream<EventsClientItem, Error> {
        subscribedSince.append(since)
        if let e = subscribeError { throw e }
        let (stream, cont) = AsyncThrowingStream<EventsClientItem, Error>.makeStream()
        pending.append(cont)
        for item in preBuffered { cont.yield(item) }
        preBuffered.removeAll()
        if let optErr = preBufferedFinish {
            cont.finish(throwing: optErr)
            preBufferedFinish = nil
        } else if autoFinishCount > 0 {
            autoFinishCount -= 1
            cont.finish()
        }
        return stream
    }
}
