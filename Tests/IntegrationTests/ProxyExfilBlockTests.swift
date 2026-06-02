import Crypto
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

final class ProxyExfilBlockTests: XCTestCase {
    /// I3 at the wire: a secret scoped to `api.anthropic.com` only, referenced
    /// by a request to `localhost`, must trip R1 (host mismatch) and the real
    /// secret value must NEVER reach the upstream.
    ///
    /// NOTE on production behavior (verified in `MITMHandler.forwardRequest`):
    /// a `.block` decision does NOT drop the request. The handler returns the
    /// UNSUBSTITUTED head/body (`outcome: .blocked`) and `forwardRequest` then
    /// unconditionally forwards it upstream — the `.blocked` switch only logs /
    /// pauses, it never short-circuits the `upstreamClient.send`. This matches
    /// the existing `testHostMismatchEmitsExfilBlockedEventAndForwardsPlaceholder`,
    /// which asserts the placeholder is forwarded verbatim. So the upstream DOES
    /// receive an HTTP request — but it carries the placeholder LITERAL, never
    /// the resolved secret. The wire invariant is therefore "the secret value
    /// never appears upstream", which this test asserts across headers, URI, and
    /// body.
    func testOutOfScopeSecretIsBlockedAndNeverReachesUpstream() async throws {
        let secretValue = "sk-ant-must-not-leak-upstream"
        let secretName = "test_anthropic_key"
        let placeholder = "{{kc:\(secretName)}}"

        // Secret scoped to api.anthropic.com ONLY; request targets "localhost"
        // → R1 host mismatch must block substitution.
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            // MITM-whitelisted at the proxy level, but the secret's scope
            // excludes it → reaches the exfil engine and trips R1.
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            maxSubstitutionsPerMinute: 60,
            // blockOnly avoids auto-pause side effects on the proxy.
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

        var response: TestProxyClient.Response?
        var received: MockUpstream.ReceivedRequest?
        var caughtError: Error?
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
                    ("x-api-key", placeholder),
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [proxyCANIO]
            )
            // Safe to await here: the block path FORWARDS the (unsubstituted)
            // request, so a request DOES arrive. Bounded by the 5s timeout.
            received = try await mock.receivedRequest()
        } catch {
            caughtError = error
        }

        // Cross-check against the non-blocking accessor before teardown.
        let snapshot = mock.receivedRequestIfAny()

        try? await proxy.stop()
        try? await mock.stop()

        if let caughtError = caughtError {
            throw caughtError
        }

        // ─── Core invariant (I3 at the wire) ──────────────────────────────
        // The secret value must NOT appear anywhere in what reached upstream.
        let wireRequest = try XCTUnwrap(
            received,
            "block path must still forward the request upstream"
        )

        for header in wireRequest.head.headers {
            XCTAssertFalse(
                header.value.contains(secretValue),
                "secret value leaked to upstream in header \(header.name)"
            )
        }
        XCTAssertFalse(
            wireRequest.head.uri.contains(secretValue),
            "secret value leaked to upstream in the request URI"
        )
        if let body = wireRequest.body, let bodyString = String(data: body, encoding: .utf8) {
            XCTAssertFalse(
                bodyString.contains(secretValue),
                "secret value leaked to upstream in the request body"
            )
        }

        // The placeholder must have been forwarded VERBATIM — proof that R1
        // blocked the substitution rather than the proxy silently dropping it.
        XCTAssertEqual(
            wireRequest.head.headers.first(name: "x-api-key"),
            placeholder,
            "host-mismatch block must forward the placeholder literal, not the secret"
        )

        // The non-blocking accessor must agree with the awaited result.
        XCTAssertEqual(
            snapshot?.head.headers.first(name: "x-api-key"),
            placeholder,
            "non-blocking snapshot must mirror the recorded request"
        )

        // The client gets a normal upstream response (OK from the mock); the
        // body assertion is secondary — the proxy may relay the upstream reply
        // OR surface an error, so accept either.
        if let response = response {
            XCTAssertEqual(
                response.status,
                .ok,
                "upstream relayed its own response through the proxy"
            )
        } else {
            XCTAssertNotNil(caughtError, "expected either a response or a connection error")
        }
    }
}
