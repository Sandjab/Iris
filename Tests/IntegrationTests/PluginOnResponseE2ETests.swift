import Foundation
import IrisKit
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import XCTest

/// onResponse Task 7: a request through the live proxy fires the onResponse chain
/// at the response head; the plugin overlays a header that reaches the client while
/// the body relays unchanged; a non-matching request is untouched (gating).
final class PluginOnResponseE2ETests: XCTestCase {

    /// In-process onResponse plugin: overlays `x-iris-tagged: 1`. onRequest is a no-op.
    private struct TaggingInvoker: PluginInvoking {
        let id: String
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult
        { .init(action: .pass) }
        func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnResponseResult
        { .init(action: .modify, headers: [["x-iris-tagged", "1"]]) }
    }

    private struct Fixture {
        let proxy: ProxyServer
        let proxyPort: Int
        let proxyCANIO: NIOSSLCertificate
        let mock: MockUpstream
        func teardown() async {
            try? await proxy.stop()
            try? await mock.stop()
        }
    }

    private func makeFixture() async throws -> Fixture {
        let secretStore = InMemorySecretStore()
        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1",
                listenPort: 0,
                allowedHosts: ["localhost"],
                upstreamPort: mock.port,
                upstreamTrustRoots: .certificates([mockCANIO]),
                onExfilAttempt: .blockOnly
            ),
            secretStore: secretStore,
            caManager: proxyCAManager,
            hookDispatcher: HookDispatcher()
        )
        let addr: SocketAddress
        do { addr = try await proxy.start() } catch {
            try? await mock.stop()
            throw error
        }
        guard let proxyPort = addr.port else {
            try? await proxy.stop()
            try? await mock.stop()
            throw IntegrationTestError.bindFailed
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
        return Fixture(proxy: proxy, proxyPort: proxyPort, proxyCANIO: proxyCANIO, mock: mock)
    }

    private func responseHook(hosts: [String]) -> PluginHook {
        PluginHook(event: .onResponse, match: HookMatch(hosts: hosts), mutates: true, onFailure: .skip, timeoutMs: 1000)
    }

    func testResponseHeaderInjectedAndBodyIntact() async throws {
        let f = try await makeFixture()
        f.proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(
                pluginId: "tag",
                invoker: TaggingInvoker(id: "tag"),
                hook: responseHook(hosts: ["localhost"])
            )
        ])
        let resp = try await TestProxyClient().send(
            proxyHost: "127.0.0.1",
            proxyPort: f.proxyPort,
            targetHost: "localhost",
            targetPort: 443,
            method: .POST,
            path: "/v1/messages",
            headers: [("host", "localhost"), ("content-type", "application/json")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [f.proxyCANIO]
        )
        await f.teardown()
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(
            resp.headers.first(name: "x-iris-tagged"),
            "1",
            "plugin-overlaid response header reaches the client"
        )
        XCTAssertEqual(resp.body, Data("OK".utf8), "the upstream body is relayed unchanged")
    }

    func testNonMatchingRequestIsUntouched() async throws {
        let f = try await makeFixture()
        // Hook only matches host "other.com"; this request is to "localhost" → no hook.
        f.proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(
                pluginId: "tag",
                invoker: TaggingInvoker(id: "tag"),
                hook: responseHook(hosts: ["other.com"])
            )
        ])
        let resp = try await TestProxyClient().send(
            proxyHost: "127.0.0.1",
            proxyPort: f.proxyPort,
            targetHost: "localhost",
            targetPort: 443,
            method: .POST,
            path: "/v1/messages",
            headers: [("host", "localhost"), ("content-type", "application/json")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [f.proxyCANIO]
        )
        await f.teardown()
        XCTAssertEqual(resp.status, .ok)
        XCTAssertNil(resp.headers.first(name: "x-iris-tagged"), "non-matching request: no plugin header")
        XCTAssertEqual(resp.body, Data("OK".utf8))
    }
}
