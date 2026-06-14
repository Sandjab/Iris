import XCTest

@testable import IrisAppCore

final class AlertsSummaryTests: XCTestCase {
    // WHY: lifts the "0 unread" vs visible-alerts contradiction — the header always shows the TOTAL
    // alongside the unread count, so a list of read alerts no longer reads as "nothing here".
    func test_showsTotalAlongsideUnread() {
        XCTAssertEqual(alertsSummary(total: 3, unread: 0), "3 alerts • 0 unread")
    }

    // WHY: polish — singular must read naturally, not "1 alerts".
    func test_singularPluralization() {
        XCTAssertEqual(alertsSummary(total: 1, unread: 1), "1 alert • 1 unread")
    }
}
