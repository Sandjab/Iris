import Crypto
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import X509
import XCTest

final class ProxyEndToEndTests: XCTestCase {
    func testSubstitutedValueReachesUpstream() async throws {
        let secretValue = "sk-ant-real-XYZ-2026"
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

        let mock = try await MockUpstream.start(
            host: "localhost",
            caManager: mockCAManager
        )

        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO])
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
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
        var received: MockUpstream.ReceivedRequest?
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
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [proxyCANIO]
            )
            received = try await mock.receivedRequest()
        } catch {
            caughtError = error
        }

        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError {
            throw caughtError
        }

        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(response?.body, Data("OK".utf8))

        XCTAssertEqual(received?.head.uri, "/v1/messages")
        XCTAssertEqual(received?.head.method, .POST)
        XCTAssertEqual(received?.head.headers.first(name: "x-api-key"), secretValue)
        XCTAssertEqual(received?.body.map { String(data: $0, encoding: .utf8) }, #"{"prompt":"hi"}"#)
    }

    func testNonWhitelistedHostTunnelsTLSAndPreservesUpstreamCertificate() async throws {
        // SPECS §8.3: non-whitelisted hosts are CONNECT-tunneled byte-for-byte
        // without MITM. The client must see the real upstream certificate
        // (signed by mockCA), not the proxy CA. Placeholders inside the
        // encrypted tunnel must NOT be substituted because the proxy never
        // decrypts the bytes.

        let secretValue = "sk-ant-should-not-leak"
        let secretName = "test_anthropic_key"
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["localhost"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()

        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(
            host: "localhost",
            caManager: mockCAManager
        )

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            // localhost is NOT in the whitelist — must trigger passthrough.
            allowedHosts: ["api.anthropic.com"],
            upstreamPort: mock.port
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }

        // The client trusts ONLY the mock CA. If the proxy were intercepting
        // (MITM), it would present a leaf signed by the proxy CA, and this
        // TLS handshake would fail with an untrusted issuer error.
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let client = TestProxyClient()

        var caughtError: Error?
        var response: TestProxyClient.Response?
        var received: MockUpstream.ReceivedRequest?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: mock.port,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-api-key", "{{kc:\(secretName)}}"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [mockCANIO]
            )
            received = try await mock.receivedRequest()
        } catch {
            caughtError = error
        }

        let events = await proxy.eventRing.all
        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError {
            throw caughtError
        }

        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(response?.body, Data("OK".utf8))

        // The placeholder reached the upstream verbatim — the proxy never
        // saw the cleartext, so it could not substitute.
        XCTAssertEqual(
            received?.head.headers.first(name: "x-api-key"),
            "{{kc:\(secretName)}}",
            "passthrough must not substitute placeholders"
        )

        // SPECS §8.3: a passThrough event must be emitted for the tunneled
        // connection.
        let passThroughEvents = events.filter { $0.kind == .passThrough }
        XCTAssertEqual(
            passThroughEvents.count,
            1,
            "expected exactly one passThrough event, got \(events.map { $0.kind })"
        )
        XCTAssertEqual(passThroughEvents.first?.host, "localhost")
    }

    func testNonWhitelistedHostWithUnreachableUpstreamReturns502() async throws {
        // Regression: previously, a CONNECT to a host whose passthrough TCP
        // dial fails (DNS NXDOMAIN, refused, etc.) crashed the daemon with a
        // NIO precondition failure because the 502 response was written via
        // `ChannelHandlerContext` from inside a `makeFutureWithTask` Task,
        // which is not guaranteed to run on the channel's EventLoop. The fix
        // performs the write directly on the `Channel`, which is thread-safe.

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            // localhost is not whitelisted → passthrough path
            allowedHosts: ["api.anthropic.com"]
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: InMemorySecretStore(),
            caManager: proxyCAManager
        )
        let address = try await proxy.start()
        guard let port = address.port else {
            try? await proxy.stop()
            return XCTFail("proxy did not bind")
        }

        // RFC 6761: .invalid is guaranteed not to resolve. The passthrough
        // ClientBootstrap.connect() must fail and the proxy must respond 502
        // instead of crashing.
        let status = try await TestProxyClient.sendConnectOnly(
            proxyHost: "127.0.0.1",
            proxyPort: port,
            targetAuthority: "this-host-does-not-exist.invalid:443"
        )
        try? await proxy.stop()
        XCTAssertEqual(status, .badGateway, "unreachable passthrough upstream must yield 502")
    }

    func testHostMismatchEmitsExfilBlockedEventAndForwardsPlaceholder() async throws {
        // SPECS §10 R1: a placeholder whose `allowed_hosts` does NOT include the
        // request host must trigger an `exfilBlocked` event with rule
        // `hostMismatch` and severity `high`. The proxy must forward the
        // request with the placeholder LITERAL — no substitution occurs.
        let secretValue = "sk-real-XYZ-DO-NOT-LEAK"
        let secretName = "test_anthropic_key"

        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            // Does NOT include localhost — request to localhost must trip R1.
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()

        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(
            host: "localhost",
            caManager: mockCAManager
        )

        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            // localhost IS whitelisted at the proxy level — request must be
            // MITM'd and reach the exfil rule engine.
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            maxSubstitutionsPerMinute: 60,
            // Use blockOnly to avoid auto-pause side effects on the proxy.
            onExfilAttempt: .blockOnly
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
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
        var received: MockUpstream.ReceivedRequest?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                // Authorization is a CANONICAL secret location for Bearer
                // tokens; R2 (non-canonical) must not fire — R1 must be the
                // rule that triggers.
                headers: [
                    ("host", "localhost"),
                    ("Authorization", "Bearer {{kc:\(secretName)}}"),
                ],
                body: nil,
                trustingCAs: [proxyCANIO]
            )
            received = try await mock.receivedRequest()
        } catch {
            caughtError = error
        }

        // Give the async event append a brief moment to land before reading.
        try await Task.sleep(nanoseconds: 100_000_000)
        let events = await proxy.eventRing.recent(100)
        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError {
            throw caughtError
        }

        XCTAssertEqual(response?.status, .ok)

        // Upstream must have received the placeholder LITERAL — substitution
        // was blocked by R1, so the original bytes flow through.
        XCTAssertEqual(
            received?.head.headers.first(name: "Authorization"),
            "Bearer {{kc:\(secretName)}}",
            "host-mismatch block must forward the placeholder verbatim"
        )

        let blocked = events.first(where: { $0.kind == .exfilBlocked })
        XCTAssertNotNil(blocked, "expected an exfilBlocked event in the ring")
        XCTAssertEqual(blocked?.alert?.rule, .hostMismatch)
        XCTAssertEqual(blocked?.alert?.severity, .high)
        XCTAssertEqual(blocked?.alert?.secretName, secretName)
        XCTAssertEqual(blocked?.substitutedSecrets, [])

        // CLAUDE.md §6.1 invariant: events must never embed the secret value.
        XCTAssertFalse(blocked?.host.contains(secretValue) ?? true)
        XCTAssertFalse(blocked?.path.contains(secretValue) ?? true)
    }

    func testBlockNotifyPauseAutoPausesDaemon() async throws {
        let secretValue = "sk-XYZ"
        let secretName = "test_anthropic_key"

        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()

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
            maxSubstitutionsPerMinute: 60,
            onExfilAttempt: .blockNotifyPause
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }

        XCTAssertFalse(proxy.isPaused, "proxy should not start paused")

        let proxyCACert = try await proxyCAManager.ensureCA()
        let proxyCANIO = try NIOSSLCertificate(
            bytes: Array(proxyCACert.derBytes),
            format: .der
        )

        let client = TestProxyClient()
        _ = try await client.send(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            targetHost: "localhost",
            targetPort: 443,
            method: .POST,
            path: "/v1/messages",
            headers: [("Authorization", "Bearer {{kc:\(secretName)}}")],
            body: nil,
            trustingCAs: [proxyCANIO]
        )

        // Allow async event emission + policy execution to complete.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(proxy.isPaused, "daemon must auto-pause after exfil with block_notify_pause")

        try? await proxy.stop()
        try? await mock.stop()
    }
}
