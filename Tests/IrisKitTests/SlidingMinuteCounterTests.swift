import XCTest

@testable import IrisKit

final class SlidingMinuteCounterTests: XCTestCase {
    func testEmptyCounterIsZero() {
        var c = SlidingMinuteCounter()
        XCTAssertEqual(c.count(at: Date()), 0)
    }

    func testRecordedTimestampIsCounted() {
        var c = SlidingMinuteCounter()
        let t0 = Date()
        c.record(at: t0)
        XCTAssertEqual(c.count(at: t0), 1)
    }

    func testTimestampKeptUntilWindowEdgeInclusive() {
        var c = SlidingMinuteCounter()
        let t0 = Date()
        c.record(at: t0)
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(59)), 1)
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(60)), 1)
    }

    func testTimestampDroppedJustPastWindow() {
        var c = SlidingMinuteCounter()
        let t0 = Date()
        c.record(at: t0)
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(60.0001)), 0)
    }

    func testMultipleTimestampsAccumulateAndExpireIndependently() {
        var c = SlidingMinuteCounter()
        let t0 = Date()
        c.record(at: t0)
        c.record(at: t0.addingTimeInterval(30))
        c.record(at: t0.addingTimeInterval(60))
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(60)), 3)
        // Advance 61s: t0 just expired, t0+30 and t0+60 still within window.
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(61)), 2)
        // Advance 91s: t0+30 just expired, only t0+60 remains.
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(91)), 1)
        // Advance 121s: all expired.
        XCTAssertEqual(c.count(at: t0.addingTimeInterval(121)), 0)
    }
}
