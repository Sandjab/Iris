import XCTest

@testable import IrisKit

final class RelativeTimeTests: XCTestCase {
    func testParseMinutesHoursDays() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try RelativeTime.parse("5m", relativeTo: now), now.addingTimeInterval(-300))
        XCTAssertEqual(try RelativeTime.parse("2h", relativeTo: now), now.addingTimeInterval(-7200))
        XCTAssertEqual(try RelativeTime.parse("1d", relativeTo: now), now.addingTimeInterval(-86400))
        XCTAssertEqual(try RelativeTime.parse("90s", relativeTo: now), now.addingTimeInterval(-90))
    }

    func testParseISO8601() throws {
        let iso = "2026-05-25T10:00:00Z"
        let now = Date()
        let parsed = try RelativeTime.parse(iso, relativeTo: now)
        let expected = ISO8601DateFormatter().date(from: iso)!
        XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRejectsInvalid() {
        XCTAssertThrowsError(try RelativeTime.parse("", relativeTo: Date()))
        XCTAssertThrowsError(try RelativeTime.parse("abc", relativeTo: Date()))
        XCTAssertThrowsError(try RelativeTime.parse("5x", relativeTo: Date()))
        XCTAssertThrowsError(try RelativeTime.parse("-5m", relativeTo: Date()))
    }
}
