import Foundation

/// In-process pub/sub for live events. The proxy (`MITMHandler`) emits
/// events into the `EventRing`, which forwards them here; the SSE server
/// (`EventsServer`) holds one subscription per connected HTTP client.
///
/// SPECS §14.4 backpressure (slow-consumer detection + `event: dropped`
/// sentinel + close) is **not implemented in Phase 3**. The earlier draft
/// branched on `AsyncStream.Continuation.YieldResult.dropped`, but with the
/// `.bufferingNewest` policy `yield` always returns `.enqueued`
/// (oldest item discarded silently to make room), making the branch
/// unreachable. Properly supporting slow-consumer detection requires either
/// a custom `AsyncSequence` that exposes overflow, or a migration to
/// `NIOAsyncWriter` so that the SSE writer suspends on real TCP
/// backpressure. Tracked as a Phase 3.x follow-up; in current usage the bus
/// silently drops items if a consumer lags by > `queueDepth` events.
public actor EventsBus {
    /// Default per-subscriber buffer.
    public static let defaultQueueDepth = 1000

    private struct Subscriber {
        let continuation: AsyncStream<Event>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let queueDepth: Int

    public init(queueDepth: Int = EventsBus.defaultQueueDepth) {
        precondition(queueDepth > 0, "queueDepth must be positive")
        self.queueDepth = queueDepth
    }

    public func subscribe() -> (id: UUID, stream: AsyncStream<Event>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(queueDepth)
        )
        subscribers[id] = Subscriber(continuation: continuation)
        // Eager cleanup: when the consumer drops its stream/iterator the
        // continuation fires `onTermination` and we evict the subscriber
        // from the dictionary on the bus actor. Without this the only
        // cleanup path is the next `publish` detecting `.terminated`,
        // which leaks the registration if no further events arrive.
        // `nonmutating set` on the continuation lets us assign even from
        // an actor-isolated context.
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        return (id, stream)
    }

    public func unsubscribe(id: UUID) {
        guard let sub = subscribers.removeValue(forKey: id) else { return }
        sub.continuation.finish()
    }

    public func publish(_ event: Event) {
        // Iterate over a snapshot of the keys: a `.terminated` yield below
        // mutates `subscribers` which would otherwise invalidate iteration.
        for id in Array(subscribers.keys) {
            guard let subscriber = subscribers[id] else { continue }
            let result = subscriber.continuation.yield(event)
            switch result {
            case .enqueued, .dropped:
                // `.dropped` is the documented but unreachable case under
                // `.bufferingNewest` (oldest items are evicted silently).
                // Treat both as success at this layer.
                break
            case .terminated:
                // Consumer has finished iterating — drop the registration so
                // the dictionary doesn't leak entries for abruptly-closed
                // clients.
                subscribers.removeValue(forKey: id)
            @unknown default:
                break
            }
        }
    }

    /// Number of currently-registered subscribers. Exposed for tests and
    /// for `daemon.status`-style introspection.
    public var subscriberCount: Int { subscribers.count }
}
