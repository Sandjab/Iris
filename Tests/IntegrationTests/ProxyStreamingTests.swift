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

    /// Drives a large multi-chunk response through the backpressure-gated relay
    /// and asserts byte-for-byte integrity + termination.
    ///
    /// Backpressure note: the relay gates upstream reads on the client's
    /// writability (canonical swift-nio `GlueHandler` model — `read(context:)`
    /// defers when `clientChannel.isWritable` is false; `ClientWritabilityHandler`
    /// resumes it). A *precise* "reads paused exactly at the watermark" assertion
    /// is intentionally omitted: `EmbeddedChannel` does not flip `isWritable` for
    /// flushed writes, and a real-socket assertion of the pause moment is
    /// timing-fragile (TCP buffer sizes). Instead this test floods ~1 MiB across
    /// 256 chunks: if the pause/resume cycle were broken (e.g. a deferred read
    /// never resumed), the transfer would deadlock and `drain` would time out
    /// rather than hang. The real-world backpressure check is the manual SSE
    /// smoke (Task 11).
    func testLargeStreamedResponseSurvivesGatedPath() async throws {
        let mockCA = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCA.ensureCA()
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let chunks = (0..<256).map { Data(repeating: UInt8($0 & 0xFF), count: 4096) }
        let expected = chunks.reduce(into: Data()) { $0.append($1) }

        let mock = try await MockUpstream.startStreaming(host: "localhost", caManager: mockCA) { el in
            MockUpstream.StreamingResponsePlan(
                firstChunk: chunks[0],
                remainingChunks: Array(chunks[1...]),
                releaseRest: el.makeSucceededVoidFuture()
            )
        }

        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1",
                listenPort: 0,
                allowedHosts: ["localhost"],
                upstreamPort: mock.port,
                upstreamTrustRoots: .certificates([mockCANIO])
            ),
            secretStore: InMemorySecretStore(),
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
            method: .GET,
            path: "/v1/messages",
            headers: [("host", "localhost")],
            body: nil,
            trustingCAs: [proxyCANIO],
            streamTimeout: .seconds(5)
        )

        let collected = try await drainStream(resp.bodyChunks, timeout: 15)
        try? await proxy.stop()
        try? await mock.stop()

        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(collected.count, expected.count)
        XCTAssertEqual(collected, expected)
    }
}

extension ProxyStreamingTests {
    /// Upstream unreachable (connect refused) before any response head is
    /// relayed → the client must receive a `502 Bad Gateway`, mirroring the
    /// passthrough path (SPECS §5 case 1). The buffered `send` is fine: 502 is a
    /// complete small response.
    func testUnreachableUpstreamReturns502() async throws {
        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        // upstreamPort 1 is reserved/closed → connect fails before any head.
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1",
                listenPort: 0,
                allowedHosts: ["localhost"],
                upstreamPort: 1
            ),
            secretStore: InMemorySecretStore(),
            caManager: proxyCA
        )
        let addr = try await proxy.start()
        guard let proxyPort = addr.port else {
            try? await proxy.stop()
            return XCTFail("proxy did not bind")
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)

        let resp = try await TestProxyClient().send(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            targetHost: "localhost",
            targetPort: 443,
            method: .GET,
            path: "/x",
            headers: [("host", "localhost")],
            body: nil,
            trustingCAs: [proxyCANIO]
        )
        try? await proxy.stop()
        XCTAssertEqual(resp.status, .badGateway)
    }
}

/// Drains an `AsyncStream<Data>` to completion, throwing `timedOut` if it does
/// not finish in time. Unlike `EventLoopFuture.get()`, `AsyncStream` iteration
/// honors task cancellation, so the timeout actually unblocks (no hang on a
/// gating deadlock).
func drainStream(_ stream: AsyncStream<Data>, timeout: Double) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            var data = Data()
            for await chunk in stream { data.append(chunk) }
            return data
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw IntegrationTestError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
