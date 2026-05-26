import Foundation

/// Exponential backoff with a cap. Caller invokes `next()` after each
/// consecutive failure to obtain the delay before the next retry. Call
/// `reset()` after a successful attempt.
public struct BackoffPolicy: Sendable {
    private let cap: Duration
    private var failures: Int = 0

    public init(cap: Duration = .seconds(30)) {
        self.cap = cap
    }

    public mutating func next() -> Duration {
        failures += 1
        // delay = min(2^(n-1), cap) seconds
        let seconds = min(1 << (failures - 1), Int(cap.components.seconds))
        return .seconds(seconds)
    }

    public mutating func reset() {
        failures = 0
    }
}
