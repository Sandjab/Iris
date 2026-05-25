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
}
