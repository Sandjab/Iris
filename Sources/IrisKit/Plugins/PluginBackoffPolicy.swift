import Foundation

/// Pure restart/backoff policy for a crashing plugin process (cf.
/// docs/plugins-design.md §14 #5). Exponential backoff capped at `maxBackoff`;
/// a plugin that crashes `crashThreshold` times within the manager's sliding
/// window is auto-disabled. All values are injectable so tests can shrink them.
public struct PluginBackoffPolicy: Sendable, Equatable {
    public let initialBackoff: TimeInterval
    public let maxBackoff: TimeInterval
    public let crashThreshold: Int

    public init(
        initialBackoff: TimeInterval = 0.25,
        maxBackoff: TimeInterval = 30,
        crashThreshold: Int = 5
    ) {
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.crashThreshold = crashThreshold
    }

    /// Delay before the `crashCount`-th restart: `initial * 2^(crashCount-1)`,
    /// capped at `maxBackoff`. `crashCount <= 1` returns `initialBackoff`.
    public func delay(forCrashCount crashCount: Int) -> TimeInterval {
        let exponent = max(0, crashCount - 1)
        let scaled = initialBackoff * pow(2, Double(exponent))
        return min(scaled, maxBackoff)
    }

    /// Whether a plugin with `recentCrashCount` crashes inside the sliding
    /// window should be auto-disabled.
    public func shouldDisable(recentCrashCount: Int) -> Bool {
        recentCrashCount >= crashThreshold
    }
}
