import XCTest

@testable import IrisKit

final class HookMatchTests: XCTestCase {
    func testEmptyMatchMatchesEverything() {
        let m = HookMatch()
        XCTAssertTrue(m.matches(host: "x.example", method: "GET", path: "/", requestContentType: nil))
    }

    func testHostExactCaseInsensitivePortStripped() {
        let m = HookMatch(hosts: ["api.anthropic.com"])
        XCTAssertTrue(m.matches(host: "API.Anthropic.com", method: "POST", path: "/v1", requestContentType: nil))
        XCTAssertTrue(
            m.matches(host: "api.anthropic.com:443", method: "POST", path: "/v1", requestContentType: nil)
        )
        XCTAssertFalse(m.matches(host: "evil.com", method: "POST", path: "/v1", requestContentType: nil))
    }

    func testMethodFilter() {
        let m = HookMatch(methods: ["POST"])
        XCTAssertTrue(m.matches(host: "h", method: "post", path: "/", requestContentType: nil))
        XCTAssertFalse(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil))
    }

    func testPathRegex() {
        let m = HookMatch(pathRegex: "^/v1/")
        XCTAssertTrue(m.matches(host: "h", method: "POST", path: "/v1/messages", requestContentType: nil))
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/v2/x", requestContentType: nil))
    }

    func testContentType() {
        let m = HookMatch(contentType: "application/json")
        XCTAssertTrue(
            m.matches(
                host: "h",
                method: "POST",
                path: "/",
                requestContentType: "application/json; charset=utf-8"
            )
        )
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/", requestContentType: "text/plain"))
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/", requestContentType: nil))
    }

    func testAllConditionsAreAnded() {
        let m = HookMatch(
            hosts: ["h"],
            methods: ["POST"],
            pathRegex: "^/v1/",
            contentType: "application/json"
        )
        XCTAssertTrue(
            m.matches(host: "h", method: "POST", path: "/v1/x", requestContentType: "application/json")
        )
        XCTAssertFalse(
            m.matches(host: "h", method: "GET", path: "/v1/x", requestContentType: "application/json")
        )
    }

    func testInvalidRegexNeverMatches() {
        let m = HookMatch(pathRegex: "[")
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/anything", requestContentType: nil))
    }
}
