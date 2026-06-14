import XCTest

@testable import IrisKit

final class TextFormatterTests: XCTestCase {
    func testRenderTableAlignsColumns() {
        let rendered = TextFormatter.table(
            headers: ["NAME", "USES", "HOSTS"],
            rows: [
                ["alpha", "3", "api.example.com"],
                ["bravo", "127", "a,b,c"],
            ]
        )
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("NAME"))
        XCTAssertTrue(lines[0].contains("USES"))
        let widths = lines.map { $0.count }
        XCTAssertEqual(Set(widths).count, 1, "rows must align: \(lines)")
    }

    func testRenderTableEmptyRowsReturnsHeaderOnly() {
        let rendered = TextFormatter.table(
            headers: ["NAME"],
            rows: []
        )
        XCTAssertEqual(rendered, "NAME")
    }

    func testFormatDaemonStatusContainsAllFields() {
        let status = DaemonStatus(
            pid: 4242,
            uptimeS: 3661,
            version: "0.5.0-phase5",
            stats: DaemonStats(reqTotal: 10, subTotal: 7, exfilBlockedTotal: 1, errorsTotal: 0),
            paused: false
        )
        let line = TextFormatter.status(status)
        XCTAssertTrue(line.contains("pid=4242"))
        XCTAssertTrue(line.contains("uptime=1h"))
        XCTAssertTrue(line.contains("version=0.5.0-phase5"))
        XCTAssertTrue(line.contains("req=10"))
        XCTAssertTrue(line.contains("sub=7"))
        XCTAssertTrue(line.contains("exfil=1"))
        XCTAssertTrue(line.contains("err=0"))
    }

    func testFormatUptimeUnits() {
        XCTAssertEqual(TextFormatter.uptime(seconds: 0), "0s")
        XCTAssertEqual(TextFormatter.uptime(seconds: 45), "45s")
        XCTAssertEqual(TextFormatter.uptime(seconds: 90), "1m30s")
        XCTAssertEqual(TextFormatter.uptime(seconds: 3661), "1h1m")
        XCTAssertEqual(TextFormatter.uptime(seconds: 86_400), "1d")
        XCTAssertEqual(TextFormatter.uptime(seconds: 90_061), "1d1h")
    }
}
