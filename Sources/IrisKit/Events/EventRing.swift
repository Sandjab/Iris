import Foundation

/// In-memory ring buffer of `Event` instances. SPECS §19.3: max 10 000 entries.
/// Backed by the SSE stream and admin RPC `events.query` (Phase 3).
///
/// The ring also tracks per-kind running totals (incremented on every
/// `append` and never reset), which back the `daemon.stats` admin method
/// without depending on the ring window.
public actor EventRing {
    private let capacity: Int
    private var entries: [Event] = []
    private var totals: [Event.Kind: UInt64] = [:]

    public init(capacity: Int = 10_000) {
        // A zero-capacity ring would crash `append` (`removeFirst` on an
        // empty array). The default — and only sensible value — is positive.
        precondition(capacity > 0, "EventRing capacity must be > 0, got \(capacity)")
        self.capacity = capacity
    }

    public func append(_ event: Event) {
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(event)
        totals[event.kind, default: 0] &+= 1
    }

    public var all: [Event] { entries }

    /// Returns the last `n` events in insertion order. `n` ≤ 0 yields an
    /// empty array — the bare `Array.suffix(_:)` traps on negative input
    /// and this method is reachable from the admin IPC in Phase 3+.
    public func recent(_ n: Int) -> [Event] {
        guard n > 0 else { return [] }
        return Array(entries.suffix(n))
    }

    public func events(since date: Date) -> [Event] {
        entries.filter { $0.timestamp >= date }
    }

    /// Cumulative count of `append` calls partitioned by `Event.Kind`. Never
    /// decreases. Includes events that have since fallen out of the ring.
    public var counts: [Event.Kind: UInt64] { totals }

    public func count(of kind: Event.Kind) -> UInt64 { totals[kind, default: 0] }
}
