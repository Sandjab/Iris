import Logging
import NIO
import XCTest

@testable import IrisKit

final class ProxyServerHotReloadTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestProxyServer(
        group: EventLoopGroup,
        allowedHosts: Set<String>,
        maxSubstitutionsPerMinute: Int = 60,
        onExfilAttempt: ExfilAttemptPolicy = .blockAndNotify
    ) -> ProxyServer {
        let config = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: allowedHosts,
            upstreamPort: 443,
            maxSubstitutionsPerMinute: maxSubstitutionsPerMinute,
            onExfilAttempt: onExfilAttempt
        )
        return ProxyServer(
            configuration: config,
            secretStore: InMemorySecretStore(),
            caManager: CAManager(keyStore: InMemoryCAKeyStore()),
            group: group,
            logger: Logger(label: "io.iris.test.hotreload")
        )
    }

    // MARK: - Tests

    func testUpdateAllowedHostsVisibleViaSnapshot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let proxy = makeTestProxyServer(group: group, allowedHosts: ["a.example.com"])
        let initial = await proxy.allowedHostsSnapshot()
        XCTAssertEqual(initial, ["a.example.com"])

        await proxy.updateAllowedHosts(["b.example.com", "c.example.com"])
        let after = await proxy.allowedHostsSnapshot()
        XCTAssertEqual(after, ["b.example.com", "c.example.com"])
    }

    func testUpdateSecurityPolicySwapsValues() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let proxy = makeTestProxyServer(
            group: group,
            allowedHosts: [],
            maxSubstitutionsPerMinute: 60,
            onExfilAttempt: .blockAndNotify
        )
        let initial = await proxy.securityPolicySnapshot()
        XCTAssertEqual(initial.maxSubstitutionsPerMinute, 60)
        XCTAssertEqual(initial.onExfilAttempt, .blockAndNotify)

        await proxy.updateSecurityPolicy(maxSubstitutionsPerMinute: 999, onExfilAttempt: .blockNotifyPause)
        let after = await proxy.securityPolicySnapshot()
        XCTAssertEqual(after.maxSubstitutionsPerMinute, 999)
        XCTAssertEqual(after.onExfilAttempt, .blockNotifyPause)
    }

    func testConcurrentUpdatesConverge() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let proxy = makeTestProxyServer(group: group, allowedHosts: [])
        await withTaskGroup(of: Void.self) { tg in
            for i in 0..<50 {
                tg.addTask { await proxy.updateAllowedHosts(["h\(i % 5).example.com"]) }
            }
        }
        // After 50 concurrent writes from the set {h0..h4}, the final snapshot
        // must be one of those single-host sets — non-empty and atomic.
        let final = await proxy.allowedHostsSnapshot()
        XCTAssertFalse(final.isEmpty, "snapshot must contain exactly one host from the concurrent set")
        XCTAssertEqual(final.count, 1, "each update is a full replacement — snapshot must be one atomic value")
        let host = try XCTUnwrap(final.first)
        XCTAssertTrue(
            (0..<5).map { "h\($0).example.com" }.contains(host),
            "host \(host) must be one of h0..h4.example.com"
        )
    }
}
