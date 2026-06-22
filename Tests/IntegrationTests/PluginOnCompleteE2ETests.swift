import Foundation
import IrisKit
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import XCTest

/// onComplete Task 7: end-to-end proof that a request flowing through the live
/// proxy fires the `onComplete` chain once, AT completion, with the upstream
/// status and the ORIGINAL (pre-substitution) request URI.
///
/// No `onRequest` plugin is involved here — only the onComplete chain — so the
/// harness is the proxy + mock upstream from `PluginDispatchE2ETests` minus the
/// real `PluginHost`. The recorder is an in-process `PluginInvoking` that just
/// captures the `OnCompleteParams` it is handed.
final class PluginOnCompleteE2ETests: XCTestCase {

    /// In-process sink: records every `onComplete` it receives. `onRequest` is a
    /// no-op `pass` (it is never called here — no onRequest hook is registered).
    private struct RecordingInvoker: PluginInvoking {
        let id: String
        let box: NIOLockedValueBox<[PluginRPC.OnCompleteParams]>
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult
        {
            .init(action: .pass)
        }
        func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
            box.withLockedValue { $0.append(params) }
        }
    }

    func testRequestThroughProxyFiresOnCompleteWithUpstreamStatus() async throws {
        let secretStore = InMemorySecretStore()

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

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
            hookDispatcher: HookDispatcher()
        )

        // Only the COMPLETE chain is populated; no onRequest hook runs.
        let records = NIOLockedValueBox<[PluginRPC.OnCompleteParams]>([])
        proxy.hookDispatcher.updateCompleteChain([
            PluginChainEntry(
                pluginId: "rec",
                invoker: RecordingInvoker(id: "rec", box: records),
                hook: PluginHook(
                    event: .onComplete,
                    match: HookMatch(hosts: ["localhost"]),
                    mutates: false,
                    onFailure: .skip,
                    timeoutMs: 1000
                )
            )
        ])

        let proxyAddress: SocketAddress
        do {
            proxyAddress = try await proxy.start()
        } catch {
            try? await mock.stop()
            throw error
        }
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            throw IntegrationTestError.bindFailed
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
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [proxyCANIO]
            )
            // Confirm the request reached the upstream (so the response status is real).
            _ = try await mock.receivedRequest()
        } catch {
            caughtError = error
        }

        // onComplete is dispatched from a DETACHED Task off the response path, so
        // poll the recorder after the response has been received.
        var seen: [PluginRPC.OnCompleteParams] = []
        if caughtError == nil {
            for _ in 0..<100 {
                seen = records.withLockedValue { $0 }
                if !seen.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        try? await proxy.stop()
        try? await mock.stop()
        if let caughtError = caughtError { throw caughtError }

        // The MockUpstream's `MockHandler` always replies 200 OK.
        XCTAssertEqual(response?.status, .ok)

        XCTAssertEqual(seen.count, 1, "exactly one onComplete per request")
        XCTAssertEqual(seen.first?.host, "localhost")
        XCTAssertEqual(seen.first?.status, 200, "status captured from the upstream response")
        // Security (§6.1): the params carry the ORIGINAL request URI (pre-substitution),
        // never a resolved secret. The sent path round-trips verbatim.
        XCTAssertEqual(seen.first?.uri, "/v1/messages", "onComplete sees the original (pre-substitution) URI")
    }
}
