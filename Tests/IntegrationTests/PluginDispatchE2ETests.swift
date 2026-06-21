import Crypto
import Foundation
import IrisKit
import Logging
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

/// P3 Task 8: end-to-end proofs of the design §3 security invariant with a REAL
/// sandboxed plugin process (the iris-test-plugin fixture), not a stub. A full
/// `ProxyServer` runs the `onRequest` chain (one real `PluginHost`) BEFORE the
/// Iris scan/substitution, and the upstream-received bytes are inspected to prove:
///   1. modify (plugin) THEN substitution (Iris) both apply, in that order;
///   2. block   → 403, nothing reaches the upstream;
///   3. respond → synthetic 418, nothing reaches the upstream;
///   4. a failing (timed-out, onFailure:.skip) plugin neither breaks the request
///      nor bypasses Iris substitution.
///
/// The fixture answers `on_request` by the `x-test-action` request header:
/// pass / modify (adds `x-iris-plugin: test`) / block (reason "test-block") /
/// respond (418, header `x-from-plugin:1`, body "teapot") / hang (never replies).
final class PluginDispatchE2ETests: XCTestCase {

    // MARK: - Harness

    /// A live proxy whose `hookDispatcher` chain holds one entry backed by a real
    /// started `PluginHost`, plus the mock upstream and the CA the client trusts.
    private struct Harness {
        let proxy: ProxyServer
        let proxyPort: Int
        let proxyCANIO: NIOSSLCertificate
        let host: PluginHost
        let mock: MockUpstream
        let scratch: URL

        func teardown() async {
            await host.shutdown()
            try? await proxy.stop()
            try? await mock.stop()
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// Canonical (realpath) scratch dir — Seatbelt canonicalises write paths, so
    /// the profile must carry the realpath (handoff #3). `realpath()` is the URL
    /// extension defined in PluginHostTests.swift (same target).
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-e2e-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir.resolvingSymlinksInPath().realpath())
    }

    /// Builds the full E2E harness: a real `PluginHost` (fixture) started under the
    /// sandbox, an `onRequest` chain entry built from `hook`, a mock upstream, and
    /// a `ProxyServer` constructed with the dispatcher injected. The chain is
    /// pushed via `proxy.hookDispatcher.updateChain` AFTER the host starts so the
    /// proxy and the dispatcher we feed are the exact same instance.
    private func makeHarness(
        hook: PluginHook,
        secret: (name: String, value: String, hosts: [String])? = nil
    ) async throws -> Harness {
        let secretStore = InMemorySecretStore()
        if let secret = secret {
            _ = try await secretStore.add(
                Data(secret.value.utf8),
                named: secret.name,
                allowedHosts: secret.hosts,
                createdAt: Date()
            )
        }

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        // Real plugin process, through the real PluginSandbox + iris-sandbox-exec.
        let scratch = try scratchDir()
        let host = PluginHost(
            spec: PluginLaunchSpec(
                id: "e2e.plugin",
                executablePath: ExecutableLocator.testPlugin.path,
                capabilities: PluginCapabilities(),
                configValues: [:],
                scratchDir: scratch
            ),
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1),
            logger: Logger(label: "test"),
            onUnexpectedExit: { _ in }
        )
        try await host.start()

        let dispatcher = HookDispatcher()
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
        proxy.hookDispatcher.updateChain([
            PluginChainEntry(pluginId: "e2e.plugin", invoker: host, hook: hook)
        ])

        let proxyAddress: SocketAddress
        do {
            proxyAddress = try await proxy.start()
        } catch {
            await host.shutdown()
            try? await mock.stop()
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        guard let proxyPort = proxyAddress.port else {
            await host.shutdown()
            try? await proxy.stop()
            try? await mock.stop()
            try? FileManager.default.removeItem(at: scratch)
            throw IntegrationTestError.bindFailed
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)

        return Harness(
            proxy: proxy,
            proxyPort: proxyPort,
            proxyCANIO: proxyCANIO,
            host: host,
            mock: mock,
            scratch: scratch
        )
    }

    // MARK: - Tests

    /// §3 CORE PROOF: the plugin's `modify` (header overlay) runs FIRST on the
    /// placeholder request, then Iris substitutes the real value AFTER. The
    /// upstream-received bytes must carry BOTH the plugin's overlay header AND the
    /// substituted credential — proving the ordering and that the overlay merge
    /// preserved the `x-api-key` placeholder so substitution could act on it.
    func testPluginModifyThenIrisSubstitutionBothApply() async throws {
        let secretName = "e2e_key"
        let secretValue = "sk-real-XYZ"
        let hook = PluginHook(
            event: .onRequest,
            match: HookMatch(hosts: ["localhost"]),
            mutates: true,
            onFailure: .skip,
            timeoutMs: 2000
        )
        let h = try await makeHarness(
            hook: hook,
            secret: (name: secretName, value: secretValue, hosts: ["localhost"])
        )

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        var received: MockUpstream.ReceivedRequest?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: h.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-api-key", "{{kc:\(secretName)}}"),
                    ("x-test-action", "modify"),
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [h.proxyCANIO]
            )
            received = try await h.mock.receivedRequest()
        } catch {
            caughtError = error
        }

        await h.teardown()
        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status, .ok)

        // The plugin's modify overlay ran (placeholder request).
        XCTAssertEqual(
            received?.head.headers.first(name: "x-iris-plugin"),
            "test",
            "plugin modify overlay must reach upstream"
        )
        // Iris substituted the REAL value AFTER the plugin — the placeholder was
        // preserved by the overlay merge and resolved by scanAndSubstitute.
        XCTAssertEqual(
            received?.head.headers.first(name: "x-api-key"),
            secretValue,
            "Iris must substitute the real value AFTER the plugin ran on the placeholder"
        )
        // The credential never appeared as the literal placeholder upstream.
        XCTAssertNotEqual(received?.head.headers.first(name: "x-api-key"), "{{kc:\(secretName)}}")
    }

    /// A `block` outcome short-circuits to a 403 and forwards NOTHING upstream.
    func testPluginBlockReturns403AndNoUpstream() async throws {
        let hook = PluginHook(
            event: .onRequest,
            match: HookMatch(hosts: ["localhost"]),
            onFailure: .skip,
            timeoutMs: 2000
        )
        let h = try await makeHarness(hook: hook)

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: h.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-test-action", "block"),
                ],
                body: nil,
                trustingCAs: [h.proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        // The block path never forwards: read the non-blocking snapshot.
        let upstreamGot = h.mock.receivedRequestIfAny()
        await h.teardown()
        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status.code, 403, "plugin block must yield 403")
        XCTAssertNil(upstreamGot, "blocked request must NOT reach the upstream")
    }

    /// A `respond` outcome short-circuits with the plugin's synthetic response and
    /// forwards NOTHING upstream.
    func testPluginRespondReturnsSyntheticAndNoUpstream() async throws {
        let hook = PluginHook(
            event: .onRequest,
            match: HookMatch(hosts: ["localhost"]),
            onFailure: .skip,
            timeoutMs: 2000
        )
        let h = try await makeHarness(hook: hook)

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: h.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .GET,
                path: "/v1/models",
                headers: [
                    ("host", "localhost"),
                    ("x-test-action", "respond"),
                ],
                body: nil,
                trustingCAs: [h.proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        let upstreamGot = h.mock.receivedRequestIfAny()
        await h.teardown()
        if let caughtError = caughtError { throw caughtError }

        XCTAssertEqual(response?.status.code, 418, "plugin respond must yield the synthetic status")
        XCTAssertEqual(response?.body, Data("teapot".utf8), "synthetic body must reach the client")
        XCTAssertEqual(
            response?.headers.first(name: "x-from-plugin"),
            "1",
            "synthetic headers must reach the client"
        )
        XCTAssertNil(upstreamGot, "responded request must NOT reach the upstream")
    }

    /// §3 PROOF: a plugin that fails (here: hangs past a SHORT host-side timeout,
    /// onFailure:.skip) is skipped — it neither breaks the request NOR bypasses
    /// Iris. After the skip, the request proceeds through scan+substitution, so the
    /// upstream must receive the REAL substituted value. If the skipped plugin had
    /// aborted the pipeline, the real value would never reach upstream.
    func testFailingSkipPluginDoesNotBypassIrisSubstitution() async throws {
        let secretName = "e2e_key"
        let secretValue = "sk-real-XYZ"
        let hook = PluginHook(
            event: .onRequest,
            match: HookMatch(hosts: ["localhost"]),
            mutates: true,
            onFailure: .skip,
            timeoutMs: 300  // short: the host-side per-call timeout fires → skip
        )
        let h = try await makeHarness(
            hook: hook,
            secret: (name: secretName, value: secretValue, hosts: ["localhost"])
        )

        let client = TestProxyClient()
        var caughtError: Error?
        var response: TestProxyClient.Response?
        var received: MockUpstream.ReceivedRequest?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: h.proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-api-key", "{{kc:\(secretName)}}"),
                    ("x-test-action", "hang"),  // plugin never replies → timeout → skip
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [h.proxyCANIO]
            )
            received = try await h.mock.receivedRequest()
        } catch {
            caughtError = error
        }

        await h.teardown()
        if let caughtError = caughtError { throw caughtError }

        // The request was NOT broken — it reached the upstream.
        XCTAssertEqual(response?.status, .ok, "a skipped failing plugin must not break the request")
        // And Iris still substituted: the skipped plugin did not bypass the scan.
        XCTAssertEqual(
            received?.head.headers.first(name: "x-api-key"),
            secretValue,
            "after skipping the failed plugin, Iris must still scan+substitute"
        )
    }
}
