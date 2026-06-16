import NIOSSL
import XCTest

@testable import IrisKit

/// Regression for audit finding I-4: the upstream (egress) TLS client carries the
/// real secrets, so it must not silently negotiate down to a legacy TLS version.
/// The minimum is pinned to TLS 1.2.
final class UpstreamClientTLSTests: XCTestCase {
    func testUpstreamTLSMinimumIsTLS12() {
        let config = UpstreamClient.makeClientTLSConfiguration(trustRoots: .default)
        XCTAssertEqual(config.minimumTLSVersion, .tlsv12)
    }

    func testUpstreamTLSKeepsHTTP11ALPN() {
        let config = UpstreamClient.makeClientTLSConfiguration(trustRoots: .default)
        XCTAssertEqual(config.applicationProtocols, ["http/1.1"])
    }
}
