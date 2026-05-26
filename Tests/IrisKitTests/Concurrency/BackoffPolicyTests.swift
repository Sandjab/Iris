import XCTest
@testable import IrisKit

final class BackoffPolicyTests: XCTestCase {
    func testDelaysFollowDoublingPattern() {
        var p = BackoffPolicy(cap: .seconds(30))
        XCTAssertEqual(p.next(), .seconds(1))  // first failure
        XCTAssertEqual(p.next(), .seconds(2))
        XCTAssertEqual(p.next(), .seconds(4))
        XCTAssertEqual(p.next(), .seconds(8))
        XCTAssertEqual(p.next(), .seconds(16))
        XCTAssertEqual(p.next(), .seconds(30))  // capped
        XCTAssertEqual(p.next(), .seconds(30))
    }

    func testResetReturnsToFirstDelay() {
        var p = BackoffPolicy(cap: .seconds(30))
        _ = p.next()
        _ = p.next()
        _ = p.next()
        p.reset()
        XCTAssertEqual(p.next(), .seconds(1))
    }

    func testCustomCap() {
        var p = BackoffPolicy(cap: .seconds(5))
        XCTAssertEqual(p.next(), .seconds(1))
        XCTAssertEqual(p.next(), .seconds(2))
        XCTAssertEqual(p.next(), .seconds(4))
        XCTAssertEqual(p.next(), .seconds(5))
    }
}
