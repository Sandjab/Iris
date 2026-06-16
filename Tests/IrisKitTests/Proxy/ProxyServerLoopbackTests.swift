import Logging
import NIO
import XCTest

@testable import IrisKit

/// Regression for audit finding M-4: the substitution proxy must refuse to bind
/// to a non-loopback interface, mirroring `EventsServer`. A `config set
/// broker.listen 0.0.0.0:…` would otherwise expose the credential-substituting
/// proxy to the LAN.
final class ProxyServerLoopbackTests: XCTestCase {
    private func makeProxyServer(
        group: EventLoopGroup,
        listenHost: String
    ) -> ProxyServer {
        let config = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: 0,
            allowedHosts: ["api.example.com"]
        )
        return ProxyServer(
            configuration: config,
            secretStore: InMemorySecretStore(),
            caManager: CAManager(keyStore: InMemoryCAKeyStore()),
            group: group,
            logger: Logger(label: "io.iris.test.loopback")
        )
    }

    func testStartRefusesNonLoopbackHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let proxy = makeProxyServer(group: group, listenHost: "0.0.0.0")
        do {
            _ = try await proxy.start()
            try? await proxy.stop()
            XCTFail("expected start() to refuse a non-loopback bind host")
        } catch let error as ProxyError {
            guard case .refusingNonLoopbackHost = error else {
                XCTFail("expected refusingNonLoopbackHost, got \(error)")
                return
            }
        }
    }

    func testStartAcceptsLoopbackHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let proxy = makeProxyServer(group: group, listenHost: "127.0.0.1")
        let address = try await proxy.start()
        defer { Task { try? await proxy.stop() } }
        XCTAssertEqual(address.ipAddress, "127.0.0.1")
    }
}
