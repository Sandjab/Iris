import Foundation
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

final class ProxyStreamingTests: XCTestCase {
    /// The client must receive chunk1 BEFORE the mock is allowed to send chunk2.
    ///
    /// Mutation-verified discriminator: on the OLD buffered code the response
    /// head is withheld until `.end`, which never comes here (the mock waits on
    /// a barrier the test only releases *after* chunk1 has arrived). So
    /// `sendStreaming` never sees a head and its EL deadline fires →
    /// `timedOut` is thrown → this test FAILS. It only passes once the proxy
    /// relays parts at the wire as they arrive.
    func testResponseChunksArriveIncrementally() async throws {
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data("sk-XYZ".utf8),
            named: "k",
            allowedHosts: ["localhost"],
            createdAt: Date()
        )
        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        let mockCA = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCA.ensureCA()

        // Barrier: the mock waits on this before sending chunk2 + end.
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
            secretStore: secretStore,
            caManager: proxyCA
        )
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
            headers: [("host", "localhost"), ("x-api-key", "{{kc:k}}")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [proxyCANIO],
            streamTimeout: .seconds(3)
        )

        // PROOF: chunk1 must arrive before we release chunk2. The bounded
        // `firstChunk` future resolves on chunk1, or throws `timedOut`.
        try await resp.firstChunk.get()
        release.succeed(())  // now the mock sends chunk2 + end

        var collected = Data()
        for await chunk in resp.bodyChunks { collected.append(chunk) }
        try? await proxy.stop()
        try? await mock.stop()

        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(collected, Data("AAAABBBB".utf8))
    }
}
