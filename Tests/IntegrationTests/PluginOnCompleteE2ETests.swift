import Foundation
import IrisKit
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import XCTest

/// onComplete Task 7: end-to-end proofs that a request flowing through the live
/// proxy (1) fires the `onComplete` chain once, AT completion, with the upstream
/// status and the ORIGINAL (pre-substitution) request URI; and (2) never gates
/// the client response on the onComplete sink (DoD #2 — fire-and-forget).
///
/// No `onRequest` plugin is involved here — only the onComplete chain — so the
/// harness is the proxy + mock upstream from `PluginDispatchE2ETests` minus the
/// real `PluginHost`. The recorders are in-process `PluginInvoking`s.
final class PluginOnCompleteE2ETests: XCTestCase {

    // MARK: - Invokers

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

    /// A sink whose onComplete BLOCKS until the test opens the gate, then records.
    /// Models a slow/hung plugin to prove the response is not gated on onComplete.
    private final class GatedInvoker: PluginInvoking, @unchecked Sendable {
        let id: String
        private let releasedBox = NIOLockedValueBox(false)
        private let recordedBox = NIOLockedValueBox(false)
        init(id: String) { self.id = id }
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult
        {
            .init(action: .pass)
        }
        func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
            while !releasedBox.withLockedValue({ $0 }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            recordedBox.withLockedValue { $0 = true }
        }
        func release() { releasedBox.withLockedValue { $0 = true } }
        var recorded: Bool { recordedBox.withLockedValue { $0 } }
    }

    // MARK: - Harness

    /// A started proxy whose upstream is a MockUpstream replying 200 OK, with an
    /// EMPTY chain. Each test pushes its own onComplete chain before sending.
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
        return Fixture(proxy: proxy, proxyPort: proxyPort, proxyCANIO: proxyCANIO, mock: mock)
    }

    private func onCompleteHook() -> PluginHook {
        PluginHook(
            event: .onComplete,
            match: HookMatch(hosts: ["localhost"]),
            mutates: false,
            onFailure: .skip,
            timeoutMs: 1000
        )
    }

    // MARK: - Tests

    func testRequestThroughProxyFiresOnCompleteWithUpstreamStatus() async throws {
        let f = try await makeFixture()

        // Only the COMPLETE chain is populated; no onRequest hook runs.
        let records = NIOLockedValueBox<[PluginRPC.OnCompleteParams]>([])
        f.proxy.hookDispatcher.updateCompleteChain([
            PluginChainEntry(
                pluginId: "rec",
                invoker: RecordingInvoker(id: "rec", box: records),
                hook: onCompleteHook()
            )
        ])

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: f.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [f.proxyCANIO]
            )
            // Confirm the request reached the upstream (so the response status is real).
            _ = try await f.mock.receivedRequest()
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

        await f.teardown()
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

    /// DoD #2: the client response MUST NOT be gated on the onComplete sink. A
    /// blocked (hung) sink must still let the response through; the sink runs once
    /// the gate opens (dispatched, not dropped). If a regression moved onComplete
    /// onto the request/response path (awaited before forwarding), this send would
    /// hang until release → the test hangs (red).
    func testOnCompleteDoesNotBlockResponse() async throws {
        let f = try await makeFixture()

        let gated = GatedInvoker(id: "gated")
        f.proxy.hookDispatcher.updateCompleteChain([
            PluginChainEntry(pluginId: "gated", invoker: gated, hook: onCompleteHook())
        ])

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            // The sink is BLOCKED (gate not released). The response must still arrive.
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: f.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [f.proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        // Non-blocking proof: the response returned while the sink is STILL blocked.
        // The gate is closed, so `recorded` is deterministically false here.
        let recordedAtResponse = gated.recorded

        // Open the gate and confirm the sink WAS dispatched (eventually runs).
        gated.release()
        var done = false
        if caughtError == nil {
            for _ in 0..<300 {
                if gated.recorded {
                    done = true
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await f.teardown()
        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status, .ok, "a blocked onComplete sink must not gate the response")
        XCTAssertEqual(response?.body, Data("OK".utf8), "the upstream body must still reach the client")
        XCTAssertFalse(recordedAtResponse, "client response returned before the blocked sink completed")
        XCTAssertTrue(done, "onComplete runs once the gate opens (it was dispatched, not dropped)")
    }
}
