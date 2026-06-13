import Foundation
import IrisKit

/// Buckets recent events into a fixed number of equal-width time bins for the
/// Overview sparkline. Pure, deterministic — covers only the in-memory events
/// window (labelled "recent" in the UI), not the daemon lifetime.
public enum ActivitySeries {
    /// Per-bin event counts over `[minTimestamp, maxTimestamp]` split into `count`
    /// equal time intervals. Empty input or non-positive `count` → `[]`.
    /// Zero span (all simultaneous) → all events in the last bin.
    public static func buckets(from events: [Event], count: Int) -> [Int] {
        let times = events.map { $0.timestamp.timeIntervalSince1970 }
        guard count > 0, let lo = times.min(), let hi = times.max() else { return [] }
        var bins = Array(repeating: 0, count: count)
        let span = hi - lo
        guard span > 0 else {
            bins[count - 1] = events.count
            return bins
        }
        for t in times {
            var idx = Int((t - lo) / span * Double(count))
            if idx >= count { idx = count - 1 }
            if idx < 0 { idx = 0 }
            bins[idx] += 1
        }
        return bins
    }
}
