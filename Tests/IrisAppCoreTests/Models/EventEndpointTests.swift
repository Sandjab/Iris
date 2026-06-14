import XCTest

@testable import IrisAppCore

final class EventEndpointTests: XCTestCase {
    // WHY: a CONNECT tunnel carries the authority "host:port" as its path, which duplicates the
    // host cell ("github.com  github.com:443" — V3). Collapse it to the authority shown once.
    func test_connectCollapsesDuplicatedAuthority() {
        let e = eventEndpoint(method: "CONNECT", host: "github.com", path: "github.com:443")
        XCTAssertEqual(e.primary, "github.com:443")
        XCTAssertEqual(e.secondary, "")
    }

    // WHY: a normal request keeps host (primary) and its real path (secondary) distinct.
    func test_normalRequestKeepsHostAndPath() {
        let e = eventEndpoint(method: "GET", host: "api.anthropic.com", path: "/v1/messages")
        XCTAssertEqual(e.primary, "api.anthropic.com")
        XCTAssertEqual(e.secondary, "/v1/messages")
    }

    // WHY: defensive — a CONNECT with an empty path falls back to the host, never an empty row.
    func test_connectWithoutPathFallsBackToHost() {
        let e = eventEndpoint(method: "CONNECT", host: "github.com", path: "")
        XCTAssertEqual(e.primary, "github.com")
        XCTAssertEqual(e.secondary, "")
    }
}
