import Foundation

/// In-memory ring buffer of `Event` instances. SPECS §19.3: max 10 000 entries.
/// Backed by the SSE stream and admin RPC `events.query` (Phase 3).
public actor EventRing {
    private let capacity: Int
    private var entries: [Event] = []

    public init(capacity: Int = 10_000) {
        self.capacity = capacity
    }

    public func append(_ event: Event) {
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(event)
    }

    public var all: [Event] { entries }

    public func recent(_ n: Int) -> [Event] {
        Array(entries.suffix(n))
    }

    public func events(since date: Date) -> [Event] {
        entries.filter { $0.timestamp >= date }
    }
}
