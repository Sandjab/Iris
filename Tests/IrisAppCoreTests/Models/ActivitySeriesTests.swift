import IrisKit
import XCTest

@testable import IrisAppCore

final class ActivitySeriesTests: XCTestCase {
    private func event(at offset: TimeInterval) -> Event {
        Event(timestamp: Date(timeIntervalSince1970: offset), kind: .passThrough, host: "h", method: "GET", path: "/")
    }

    // WHY: no data → the view must hide the sparkline entirely, not draw an empty axis.
    func test_emptyEvents_returnsEmpty() {
        XCTAssertEqual(ActivitySeries.buckets(from: [], count: 12), [])
    }

    // WHY: defensive — a non-positive bucket count is a programming error, never a crash.
    func test_nonPositiveCount_returnsEmpty() {
        XCTAssertEqual(ActivitySeries.buckets(from: [event(at: 0)], count: 0), [])
    }

    // WHY: simultaneous events (zero time span) must not divide by zero; recency lands in the last bin.
    func test_simultaneousEvents_collapseToLastBucket() {
        let evts = [event(at: 5), event(at: 5), event(at: 5)]
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 4), [0, 0, 0, 3])
    }

    // WHY: the sparkline must reflect *temporal distribution*, not just a total (its whole purpose).
    func test_eventsDistributeAcrossBucketsByTime() {
        let evts = [event(at: 0), event(at: 1), event(at: 2), event(at: 3)]
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 4), [1, 1, 1, 1])
    }

    // WHY: no event may be silently dropped — sum of bins always equals the input count.
    func test_totalCountPreserved() {
        let evts = (0..<10).map { event(at: TimeInterval($0)) }
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 5).reduce(0, +), 10)
    }
}
