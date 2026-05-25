import Foundation
import XCTest

final class PingEndpointTests: XCTestCase {
    var harness: CLIDaemonHarness!

    override func setUpWithError() throws {
        harness = try CLIDaemonHarness()
        try harness.start()
    }

    override func tearDownWithError() throws {
        harness.stop()
    }

    // MARK: - Basic response

    /// `GET /__iris_ping` must return HTTP 200 with body `ok\n`.
    func testPingEndpointReturns200OK() throws {
        let url = URL(string: "http://127.0.0.1:\(harness.brokerPort)/__iris_ping")!
        let (data, response) = try syncDataTask(url: url)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200, "expected 200, got \(http.statusCode)")
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "ok\n",
            "unexpected body: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")"
        )
    }

    /// `GET /__iris_ping` must set `Cache-Control: no-store`.
    func testPingResponseHasNoCacheHeader() throws {
        let url = URL(string: "http://127.0.0.1:\(harness.brokerPort)/__iris_ping")!
        let (_, response) = try syncDataTask(url: url)
        let http = response as! HTTPURLResponse
        let cacheControl = http.value(forHTTPHeaderField: "Cache-Control") ?? ""
        XCTAssertTrue(
            cacheControl.contains("no-store"),
            "Cache-Control header missing 'no-store': '\(cacheControl)'"
        )
    }

    // MARK: - No-event invariant

    /// Hitting `/__iris_ping` must NOT increment `req_total` in daemon stats.
    /// This locks the invariant: a ping request must never produce an Event
    /// in the EventRing / SSE stream.
    func testPingEndpointEmitsNoEvent() throws {
        let url = URL(string: "http://127.0.0.1:\(harness.brokerPort)/__iris_ping")!

        // Hit ping several times.
        for _ in 0..<3 {
            let (data, response) = try syncDataTask(url: url)
            let http = response as! HTTPURLResponse
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok\n")
        }

        // Allow any async event flush a moment to settle.
        Thread.sleep(forTimeInterval: 0.2)

        // Verify via `iris status` that req_total is still 0.
        let status = try harness.runIris(["status"])
        XCTAssertEqual(status.code, 0, "iris status failed\nstderr=\(status.stderr)")
        XCTAssertTrue(
            status.stdout.contains("req=0"),
            "ping request leaked into req_total — event was emitted: \(status.stdout)"
        )
    }

    // MARK: - Helpers

    private func syncDataTask(url: URL) throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let done = expectation(description: "request \(url)")
        var capturedData: Data?
        var capturedResp: URLResponse?
        var capturedErr: Error?
        URLSession.shared.dataTask(with: request) { d, r, e in
            capturedData = d
            capturedResp = r
            capturedErr = e
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let err = capturedErr { throw err }
        return (capturedData ?? Data(), capturedResp!)
    }
}
