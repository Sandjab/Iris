import Foundation

/// One item delivered to an SSE subscriber. Either a normal event, or the
/// terminal `dropped` sentinel sent when the daemon falls more than
/// `EventsBus.maxQueueDepth` events behind a slow consumer (SPECS §14.4).
public enum SSEItem: Sendable, Equatable {
    case event(Event)
    case dropped(count: UInt64)
}

/// In-process pub/sub for live events. The proxy (`MITMHandler`) emits
/// events into the `EventRing`, which forwards them here; the SSE server
/// (`EventsServer`) holds one subscription per connected HTTP client.
///
/// SPECS §14.4 backpressure: each subscriber gets a bounded
/// `AsyncStream<SSEItem>` of `maxQueueDepth` items. If the underlying
/// continuation reports a dropped element on `yield`, we mark the
/// subscriber as poisoned, emit a final `.dropped(count:)` sentinel and
/// finish the stream so the server-side reader can close the connection.
public actor EventsBus {
    /// Default per-subscriber buffer (SPECS §14.4: 1000).
    public static let maxQueueDepth = 1000

    private struct Subscriber {
        let continuation: AsyncStream<SSEItem>.Continuation
        var droppedCount: UInt64
        var poisoned: Bool
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let queueDepth: Int

    public init(queueDepth: Int = EventsBus.maxQueueDepth) {
        precondition(queueDepth > 0, "queueDepth must be positive")
        self.queueDepth = queueDepth
    }

    public func subscribe() -> (id: UUID, stream: AsyncStream<SSEItem>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SSEItem>.makeStream(
            bufferingPolicy: .bufferingNewest(queueDepth)
        )
        subscribers[id] = Subscriber(
            continuation: continuation,
            droppedCount: 0,
            poisoned: false
        )
        return (id, stream)
    }

    public func unsubscribe(id: UUID) {
        guard let sub = subscribers.removeValue(forKey: id) else { return }
        sub.continuation.finish()
    }

    public func publish(_ event: Event) {
        for id in subscribers.keys {
            guard var subscriber = subscribers[id], !subscriber.poisoned else { continue }
            let result = subscriber.continuation.yield(.event(event))
            switch result {
            case .enqueued:
                break
            case .dropped:
                subscriber.poisoned = true
                subscriber.droppedCount &+= 1
                _ = subscriber.continuation.yield(.dropped(count: subscriber.droppedCount))
                subscriber.continuation.finish()
            case .terminated:
                // Consumer already closed; drop the entry on the next pass
                // via unsubscribe-on-termination semantics. For now, leave
                // it; the next subscribe()/unsubscribe() cleans up.
                break
            @unknown default:
                break
            }
            subscribers[id] = subscriber
        }
    }

    /// Number of currently-registered subscribers. Exposed for tests and
    /// for the `daemon.status` extension we may add later.
    public var subscriberCount: Int { subscribers.count }
}
