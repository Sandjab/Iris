import XCTest
import NIO
import NIOHTTP1
import NIOSSL
import Crypto
import X509
import IrisKit

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

    func testNonWhitelistedHostIsRejected() async throws {
        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["api.anthropic.com"],
            upstreamPort: 443
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

        let status = try await TestProxyClient.sendConnectOnly(
            proxyHost: "127.0.0.1",
            proxyPort: port,
            targetAuthority: "not-whitelisted.example.com:443"
        )
        try? await proxy.stop()
        XCTAssertEqual(status, .badGateway)
    }
}
