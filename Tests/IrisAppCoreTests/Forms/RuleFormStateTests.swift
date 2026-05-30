import XCTest

@testable import IrisAppCore

@MainActor
final class RuleFormStateTests: XCTestCase {
    func testEmptyHostNotSubmittable() {
        let f = RuleFormState()
        XCTAssertEqual(f.validationError, "Host is required.")
        XCTAssertFalse(f.canSubmit)
    }

    func testValidHostSubmittable() {
        let f = RuleFormState()
        f.host = "api.anthropic.com"
        XCTAssertNil(f.validationError)
        XCTAssertTrue(f.canSubmit)
    }

    func testTrimsWhitespace() {
        let f = RuleFormState()
        f.host = "  api.example.com  "
        XCTAssertEqual(f.trimmedHost, "api.example.com")
        XCTAssertTrue(f.canSubmit)
    }

    func testRejectsMalformed() {
        let f = RuleFormState()
        f.host = "has space.com"
        XCTAssertEqual(f.validationError, "Invalid host (DNS-like, ≤253 chars).")
        f.host = String(repeating: "a", count: 254)
        XCTAssertFalse(f.canSubmit)
    }
}
