import XCTest

@testable import IrisAppCore

final class PlaceholderTests: XCTestCase {
    func testPlaceholderExists() {
        XCTAssertNotNil(IrisAppCorePlaceholder.unused)
    }
}
