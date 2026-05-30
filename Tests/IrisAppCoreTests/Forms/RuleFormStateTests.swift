import XCTest

@testable import IrisAppCore

@MainActor
final class RuleFormStateTests: XCTestCase {
    func testPristineShowsNoErrorAndCannotSubmit() {
        let f = RuleFormState()
        XCTAssertNil(f.displayError)  // no premature error on an empty field
        XCTAssertFalse(f.canSubmit)
    }

    func testValidHostSubmittable() {
        let f = RuleFormState()
        f.host = "api.anthropic.com"
        XCTAssertNil(f.displayError)
        XCTAssertTrue(f.canSubmit)
    }

    func testTrimsWhitespace() {
        let f = RuleFormState()
        f.host = "  api.example.com  "
        XCTAssertEqual(f.trimmedHost, "api.example.com")
        XCTAssertTrue(f.canSubmit)
    }

    func testMalformedShowsErrorOnceTyped() {
        let f = RuleFormState()
        f.host = "has space.com"
        XCTAssertEqual(f.displayError, "Invalid host (DNS-like, ≤253 chars).")
        XCTAssertFalse(f.canSubmit)
    }

    func testOverlongHostNotSubmittable() {
        let f = RuleFormState()
        f.host = String(repeating: "a", count: 254)
        XCTAssertFalse(f.canSubmit)
        XCTAssertNotNil(f.displayError)
    }
}
