import Foundation
import XCTest

@testable import IrisKit

final class DaemonStatusCodableTests: XCTestCase {
    /// Forward-compat: a daemon older than #54 omits `paused` from `daemon.status`.
    /// A newer app must still decode the status (paused → false) instead of failing the
    /// whole RPC with `keyNotFound`, which would render the app "unreachable".
    func testDecodesWithoutPausedKeyDefaultsToFalse() throws {
        let json = """
            {"pid":42,"uptime_s":100,"version":"1.0.0",
             "stats":{"req_total":3,"sub_total":1,"exfil_blocked_total":0,"errors_total":0}}
            """
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertFalse(status.paused, "missing paused key must default to false, not throw")
        XCTAssertEqual(status.pid, 42)
        XCTAssertEqual(status.stats.reqTotal, 3)
    }

    func testDecodesWithPausedKey() throws {
        let json = """
            {"pid":7,"uptime_s":5,"version":"1.1.0","paused":true,
             "stats":{"req_total":0,"sub_total":0,"exfil_blocked_total":0,"errors_total":0}}
            """
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.paused)
    }

    func testEncodeRoundTripPreservesPaused() throws {
        let original = DaemonStatus(pid: 1, uptimeS: 2, version: "v", stats: .zero, paused: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
