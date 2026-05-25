import XCTest

@testable import IrisKit

final class PlaceholderScannerTests: XCTestCase {
    func testHitInCanonicalHeaderValue() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/v1/messages",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "foo")
        XCTAssertEqual(hits[0].location, .header(name: "authorization"))
    }

    func testHitInHeaderName() {
        let hits = PlaceholderScanner.scan(
            headers: [("X-{{kc:foo}}", "bar")],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "foo")
        if case .header(let n) = hits[0].location {
            XCTAssertTrue(n.contains("{{kc:foo}}"))
        } else {
            XCTFail("expected header location")
        }
    }

    func testHitInURLPath() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo/{{kc:bar}}/baz",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .urlPath)
    }

    func testHitInQueryString() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo?key={{kc:bar}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .queryString)
    }

    func testHitInBody() {
        let body = Data(#"{"key":"{{kc:bar}}"}"#.utf8)
        let hits = PlaceholderScanner.scan(headers: [], uri: "/", body: body)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .body)
    }

    func testMultipleHitsSameSecretMultipleLocations() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/foo?x={{kc:foo}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.name)), ["foo"])
    }

    func testMultipleDistinctSecrets() {
        let hits = PlaceholderScanner.scan(
            headers: [
                ("Authorization", "Bearer {{kc:foo}}"),
                ("X-Other", "{{kc:bar}}"),
            ],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(Set(hits.map(\.name)), ["foo", "bar"])
    }

    func testNonUTF8BodyYieldsNoHit() {
        var bytes: [UInt8] = [0xFF, 0xFE, 0xFD]
        bytes.append(contentsOf: Array("{{kc:foo}}".utf8))
        let hits = PlaceholderScanner.scan(headers: [], uri: "/", body: Data(bytes))
        XCTAssertTrue(hits.isEmpty)
    }

    func testURIWithoutQueryHasNoQueryStringLocation() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo/{{kc:bar}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .urlPath)
    }

    func testInvalidPlaceholderEmptyNameIgnored() {
        let hits = PlaceholderScanner.scan(
            headers: [("X", "{{kc:}}")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testInvalidPlaceholderNameTooLongIgnored() {
        let longName = String(repeating: "a", count: 65)
        let hits = PlaceholderScanner.scan(
            headers: [("X", "{{kc:\(longName)}}")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testHeaderNameInLocationIsLowercased() {
        let hits = PlaceholderScanner.scan(
            headers: [("X-API-KEY", "{{kc:foo}}")],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(hits[0].location, .header(name: "x-api-key"))
    }

    func testSnippetContainsPlaceholderLiteral() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}} suffix")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits[0].snippet.contains("{{kc:foo}}"))
        XCTAssertLessThanOrEqual(hits[0].snippet.count, 256)
    }
}
