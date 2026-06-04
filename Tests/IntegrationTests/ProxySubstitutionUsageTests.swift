import Crypto
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

final class ProxySubstitutionUsageTests: XCTestCase {
    /// After a SUCCESSFUL substitution at the wire, the secret's usage metadata
    /// must be recorded: `usageCount` incremented and `lastUsedAt` set.
    ///
    /// WHY this matters (not just WHAT): operators read the `USES` / `LAST_USED`
    /// columns of `iris secret list` to spot secrets that are stale (never used →
    /// candidate for removal) or unexpectedly hot (used far more than the host it
    /// guards would warrant → possible exfil/misconfig). Without the hot-path
    /// wiring those columns are dead at `0` / `-` forever and the signal is lost.
    /// This test fails if substitution ever stops recording usage.
    func testSuccessfulSubstitutionRecordsSecretUsage() async throws {
        let secretValue = "sk-ant-substituted-value"
        let secretName = "test_key"
        let placeholder = "{{kc:\(secretName)}}"

        // Secret scoped to the destination host → substitution is allowed.
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["localhost"],
            createdAt: Date()
        )

        // Baseline: a freshly added secret has never been used.
        let before = try await secretStore.secret(named: secretName)
        XCTAssertEqual(before.usageCount, 0, "precondition: new secret starts unused")
        XCTAssertNil(before.lastUsedAt, "precondition: new secret has no lastUsedAt")

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
            maxSubstitutionsPerMinute: 60,
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

        var received: MockUpstream.ReceivedRequest?
        var caughtError: Error?
        do {
            _ = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    // Canonical auth header → not flagged by exfil R2.
                    ("x-api-key", placeholder),
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

        // The substitution must actually have happened (placeholder → value),
        // otherwise "usage recorded" would be meaningless.
        let wire = try XCTUnwrap(received, "substituted request must reach upstream")
        XCTAssertEqual(
            wire.head.headers.first(name: "x-api-key"),
            secretValue,
            "substitution must replace the placeholder with the secret value"
        )

        // The behavior under test: usage recorded after a successful substitution.
        let after = try await secretStore.secret(named: secretName)
        XCTAssertEqual(after.usageCount, 1, "usageCount must increment on a successful substitution")
        XCTAssertNotNil(after.lastUsedAt, "lastUsedAt must be set on a successful substitution")
    }
}
