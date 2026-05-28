import IrisKit
import XCTest

@testable import IrisAppCore

final class LogFiltersTests: XCTestCase {
    private func makeEvent(
        kind: Event.Kind,
        host: String,
        path: String = "/v1/x",
        secret: String? = nil
    ) -> Event {
        Event(
            timestamp: Date(),
            kind: kind,
            host: host,
            method: "GET",
            path: path,
            substitutedSecrets: secret.map { [$0] } ?? []
        )
    }

    func testEmptyFiltersPassThrough() {
        let filters = LogFilters()
        let event = makeEvent(kind: .substituted, host: "api.anthropic.com")
        XCTAssertTrue(filters.matches(event))
    }

    func testKindFilterMatchesOnlyListed() {
        var filters = LogFilters()
        filters.kinds = [.exfilBlocked]
        XCTAssertFalse(filters.matches(makeEvent(kind: .substituted, host: "x.com")))
        XCTAssertTrue(filters.matches(makeEvent(kind: .exfilBlocked, host: "x.com")))
    }

    func testHostFilterCaseInsensitiveSubstring() {
        var filters = LogFilters()
        filters.host = "ANTHROPIC"
        XCTAssertTrue(filters.matches(makeEvent(kind: .substituted, host: "api.anthropic.com")))
        XCTAssertFalse(filters.matches(makeEvent(kind: .substituted, host: "api.github.com")))
    }

    func testSearchMatchesPathHostOrSecretName() {
        var filters = LogFilters()
        filters.search = "messages"
        XCTAssertTrue(
            filters.matches(makeEvent(kind: .substituted, host: "x.com", path: "/v1/messages"))
        )
        XCTAssertFalse(
            filters.matches(makeEvent(kind: .substituted, host: "x.com", path: "/v1/chat"))
        )
        filters.search = "anthropic_api_key"
        XCTAssertTrue(
            filters.matches(
                makeEvent(kind: .substituted, host: "x.com", secret: "anthropic_api_key")
            )
        )
    }

    func testFiltersAreANDed() {
        var filters = LogFilters()
        filters.kinds = [.substituted]
        filters.host = "anthropic"
        let match = makeEvent(kind: .substituted, host: "api.anthropic.com")
        let kindMismatch = makeEvent(kind: .exfilBlocked, host: "api.anthropic.com")
        let hostMismatch = makeEvent(kind: .substituted, host: "api.github.com")
        XCTAssertTrue(filters.matches(match))
        XCTAssertFalse(filters.matches(kindMismatch))
        XCTAssertFalse(filters.matches(hostMismatch))
    }
}
