import Crypto
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

/// P3 Task 7: the onRequest plugin chain runs in `MITMHandler` BEFORE the Iris
/// scan/substitution, and a `block`/`respond` outcome short-circuits the upstream
/// forward with a synthetic response. These tests drive a full proxy with a stub
/// `PluginInvoking` injected via `HookDispatcher.updateChain` and assert at the
/// wire that:
///   (a) block   → 403 to the client, nothing reaches the upstream,
///   (b) respond → the plugin's synthetic status + body, nothing reaches upstream,
///   (c) the emitted event is `.pluginBlocked` / `.pluginResponded` with the
///       right `pluginId`.
final class ProxyPluginShortCircuitTests: XCTestCase {

    /// Stub plugin process: returns a fixed `OnRequestResult` for every call.
    /// Conforms to the public `PluginInvoking` so the integration target needs no
    /// `@testable` access.
    private struct StubInvoker: PluginInvoking {
        let id: String
        let result: PluginRPC.OnRequestResult
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult
        {
            result
        }
    }

    /// Wildcard onRequest hook (matches any host/method/path) backed by `invoker`.
    private func chainEntry(_ invoker: any PluginInvoking) -> PluginChainEntry {
        PluginChainEntry(
            pluginId: invoker.id,
            invoker: invoker,
            hook: PluginHook(event: .onRequest, match: HookMatch(), timeoutMs: 1000)
        )
    }

    func testPluginBlockReturns403AndNeverForwardsUpstream() async throws {
        // A secret IS present and in scope: if the short-circuit failed and the
        // request fell through to scanAndSubstitute + forward, the upstream would
        // see the substituted value. Asserting the upstream got NOTHING proves the
        // block fired before any forward.
        let secretValue = "sk-ant-block-must-not-leak"
        let secretName = "test_anthropic_key"
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["localhost"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let dispatcher = HookDispatcher()
        dispatcher.updateChain([
            chainEntry(StubInvoker(id: "blocker", result: .init(action: .block, reason: "nope")))
        ])

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            onExfilAttempt: .blockOnly
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager,
            hookDispatcher: dispatcher
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }

        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
        let client = TestProxyClient()

        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-api-key", "{{kc:\(secretName)}}"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        // The block path never forwards, so the upstream must have recorded
        // nothing. Read the non-blocking snapshot AFTER the response is collected.
        let upstreamGot = mock.receivedRequestIfAny()
        try await Task.sleep(nanoseconds: 100_000_000)
        let events = await proxy.eventRing.recent(100)
        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status.code, 403, "plugin block must yield 403")
        XCTAssertEqual(response?.body, Data(), "plugin block returns an empty body")
        XCTAssertNil(upstreamGot, "blocked request must NOT reach the upstream")

        let blocked = events.first(where: { $0.kind == .pluginBlocked })
        XCTAssertNotNil(blocked, "expected a pluginBlocked event")
        XCTAssertEqual(blocked?.pluginId, "blocker")
        XCTAssertEqual(blocked?.host, "localhost")
        XCTAssertEqual(blocked?.statusCode, 403)

        // §6.1: neither the block reason nor the secret value may surface in events.
        // The "nope" check is a documentation assertion: the reason is discarded at
        // makeEvent (only pluginId is carried), so it structurally cannot reach an
        // event, and log redaction is structural in logOutcome (id/host only).
        for event in events {
            XCTAssertFalse(event.host.contains(secretValue))
            XCTAssertFalse(event.path.contains(secretValue))
            XCTAssertFalse(event.host.contains("nope"))
        }
    }

    func testPluginRespondReturnsSyntheticResponseAndNeverForwardsUpstream() async throws {
        let secretStore = InMemorySecretStore()
        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let syntheticBody = "brewed-by-plugin"
        let dispatcher = HookDispatcher()
        dispatcher.updateChain([
            chainEntry(
                StubInvoker(
                    id: "responder",
                    result: .init(
                        action: .respond,
                        headers: [["x-iris-synthetic", "1"]],
                        body: PluginRPC.Body(encoding: "utf8", data: syntheticBody),
                        status: 418
                    )
                )
            )
        ])

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            onExfilAttempt: .blockOnly
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager,
            hookDispatcher: dispatcher
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }

        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
        let client = TestProxyClient()

        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .GET,
                path: "/v1/models",
                headers: [("host", "localhost")],
                body: nil,
                trustingCAs: [proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        let upstreamGot = mock.receivedRequestIfAny()
        try await Task.sleep(nanoseconds: 100_000_000)
        let events = await proxy.eventRing.recent(100)
        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status.code, 418, "plugin respond must yield the synthetic status")
        XCTAssertEqual(response?.body, Data(syntheticBody.utf8), "synthetic body must reach the client")
        XCTAssertEqual(
            response?.headers.first(name: "x-iris-synthetic"),
            "1",
            "synthetic headers must reach the client"
        )
        XCTAssertEqual(
            response?.headers.first(name: "content-length"),
            "\(syntheticBody.utf8.count)",
            "writeSynthetic must set a correct content-length"
        )
        XCTAssertNil(upstreamGot, "responded request must NOT reach the upstream")

        let responded = events.first(where: { $0.kind == .pluginResponded })
        XCTAssertNotNil(responded, "expected a pluginResponded event")
        XCTAssertEqual(responded?.pluginId, "responder")
        XCTAssertEqual(responded?.host, "localhost")
        XCTAssertEqual(responded?.statusCode, 418)
    }
}
