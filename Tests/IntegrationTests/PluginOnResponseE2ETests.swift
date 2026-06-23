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

    /// Like `TaggingInvoker` but its `onResponse` SLEEPS ~300ms before resolving —
    /// modelling a real out-of-process plugin (never sub-ms). The slow hook lets NIO
    /// fire `channelInactive` + schedule `removeHandlers` (the mock upstream closes
    /// promptly after a complete response) BEFORE the hook resolves. Under a
    /// `[weak self]` drain the relay would already be nil → the queued response would
    /// never drain → the client hangs forever. The strong-self fix keeps the relay
    /// alive until the bounded hook future resolves.
    private struct SlowTaggingInvoker: PluginInvoking {
        let id: String
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult
        { .init(action: .pass) }
        func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnResponseResult
        {
            try await Task.sleep(nanoseconds: 300_000_000)
            return .init(action: .modify, headers: [["x-iris-tagged", "1"]])
        }
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

    func testStreamingPreservedWithResponseHook() async throws {
        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        let mockCA = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCA.ensureCA()

        // Barrier: the mock waits before sending chunk2 + end.
        let barrierGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? barrierGroup.syncShutdownGracefully() }
        let release = barrierGroup.next().makePromise(of: Void.self)

        let mock = try await MockUpstream.startStreaming(host: "localhost", caManager: mockCA) { _ in
            MockUpstream.StreamingResponsePlan(
                firstChunk: Data("AAAA".utf8),
                remainingChunks: [Data("BBBB".utf8)],
                releaseRest: release.futureResult
            )
        }
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1",
                listenPort: 0,
                allowedHosts: ["localhost"],
                upstreamPort: mock.port,
                upstreamTrustRoots: .certificates([mockCANIO])
            ),
            secretStore: InMemorySecretStore(),
            caManager: proxyCA,
            hookDispatcher: HookDispatcher()
        )
        // Active onResponse plugin: overlays a header at the head.
        proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(
                pluginId: "tag",
                invoker: TaggingInvoker(id: "tag"),
                hook: responseHook(hosts: ["localhost"])
            )
        ])
        let addr = try await proxy.start()
        guard let proxyPort = addr.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)

        let resp = try await TestProxyClient().sendStreaming(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            targetHost: "localhost",
            targetPort: 443,
            method: .POST,
            path: "/v1/messages",
            headers: [("host", "localhost")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [proxyCANIO],
            streamTimeout: .seconds(3)
        )

        // PROOF: chunk1 arrives before chunk2 is released → the body is NOT buffered.
        try await resp.firstChunk.get()
        release.succeed(())

        var collected = Data()
        for await chunk in resp.bodyChunks { collected.append(chunk) }
        try? await proxy.stop()
        try? await mock.stop()

        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(
            resp.headers.first(name: "x-iris-tagged"),
            "1",
            "header overlaid even on a streaming response"
        )
        XCTAssertEqual(collected, Data("AAAABBBB".utf8), "body streamed intact")
    }

    /// Liveness regression: a SLOW onResponse hook (300ms) must not hang the client
    /// when the upstream closes promptly after a complete response. On the pre-fix
    /// `[weak self]` drain, NIO's `removeHandlers` nils the relay before the hook
    /// resolves → the queued response never drains → this `send` hangs forever.
    ///
    /// The send is raced against a 5s watchdog via a CONTINUATION (first-wins), NOT a
    /// task group: `TestProxyClient.send` blocks on a NIO `future.get()` that ignores
    /// Task cancellation, so `withThrowingTaskGroup` would join the hung child and the
    /// whole test would hang to the outer alarm anyway. The continuation race abandons
    /// the loser, so a regression FAILS deterministically at ~5s (mutation-verified:
    /// reverting to `[weak self]` makes this test hang→timeout; strong self → green).
    func testSlowResponseHookDoesNotHang() async throws {
        let f = try await makeFixture()
        f.proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(
                pluginId: "slow",
                invoker: SlowTaggingInvoker(id: "slow"),
                hook: responseHook(hosts: ["localhost"])
            )
        ])
        let proxyPort = f.proxyPort
        let proxyCANIO = f.proxyCANIO
        let resp: TestProxyClient.Response = try await withCheckedThrowingContinuation { cont in
            let resumed = NIOLockedValueBox(false)
            func resumeOnce(_ result: Result<TestProxyClient.Response, Error>) {
                let isFirst = resumed.withLockedValue { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                if isFirst { cont.resume(with: result) }
            }
            Task {
                do {
                    let r = try await TestProxyClient().send(
                        proxyHost: "127.0.0.1",
                        proxyPort: proxyPort,
                        targetHost: "localhost",
                        targetPort: 443,
                        method: .POST,
                        path: "/v1/messages",
                        headers: [("host", "localhost"), ("content-type", "application/json")],
                        body: Data(#"{"p":1}"#.utf8),
                        trustingCAs: [proxyCANIO]
                    )
                    resumeOnce(.success(r))
                } catch {
                    resumeOnce(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                resumeOnce(.failure(IntegrationTestError.timedOut))
            }
        }
        await f.teardown()
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(
            resp.headers.first(name: "x-iris-tagged"),
            "1",
            "slow plugin-overlaid response header still reaches the client"
        )
        XCTAssertEqual(resp.body, Data("OK".utf8), "the upstream body is relayed unchanged after a slow hook")
    }
}
