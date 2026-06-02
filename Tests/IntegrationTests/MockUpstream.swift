import Foundation
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL

/// Minimal in-process TLS HTTPS server used as the proxy's upstream target
/// in integration tests. Records the first complete request it sees.
final class MockUpstream: @unchecked Sendable {
    struct ReceivedRequest: Sendable {
        let head: HTTPRequestHead
        let body: Data?
    }

    let port: Int

    private let group: EventLoopGroup
    private let channel: Channel
    private let receivedPromise: EventLoopPromise<ReceivedRequest>
    private let resolver: PromiseResolver<ReceivedRequest>
    /// Mirror of the recorded request that can be read WITHOUT awaiting the
    /// promise. Lets a test ask "did any complete request arrive?" without
    /// blocking when none does. Additive — `receivedRequest()` is unchanged.
    private let recorder: RequestRecorder

    private init(
        port: Int,
        group: EventLoopGroup,
        channel: Channel,
        promise: EventLoopPromise<ReceivedRequest>,
        resolver: PromiseResolver<ReceivedRequest>,
        recorder: RequestRecorder
    ) {
        self.port = port
        self.group = group
        self.channel = channel
        self.receivedPromise = promise
        self.resolver = resolver
        self.recorder = recorder
    }

    static func start(host: String, caManager: CAManager) async throws -> MockUpstream {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let leafCache = LeafCertCache(caManager: caManager)
        let leaf = try await leafCache.leaf(forHost: host)

        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leaf.nioCertificate)],
            privateKey: .privateKey(leaf.nioPrivateKey)
        )
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let receivedPromise = group.next().makePromise(of: ReceivedRequest.self)
        let resolver = PromiseResolver(promise: receivedPromise)
        let recorder = RequestRecorder()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                return channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                }.flatMap {
                    channel.pipeline.addHandler(MockHandler(resolver: resolver, recorder: recorder))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else {
            throw IntegrationTestError.bindFailed
        }
        return MockUpstream(
            port: port,
            group: group,
            channel: channel,
            promise: receivedPromise,
            resolver: resolver,
            recorder: recorder
        )
    }

    func receivedRequest(timeout: TimeAmount = .seconds(5)) async throws -> ReceivedRequest {
        let timeoutTask = group.next().scheduleTask(in: timeout) { [resolver] in
            resolver.fail(IntegrationTestError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await receivedPromise.futureResult.get()
    }

    /// Non-blocking snapshot of the already-recorded request, or `nil` if no
    /// complete HTTP request has been received yet. Unlike `receivedRequest()`,
    /// this never awaits — safe to call on a path where no request may arrive.
    func receivedRequestIfAny() -> ReceivedRequest? {
        recorder.snapshot()
    }

    func stop() async throws {
        resolver.fail(IntegrationTestError.stoppedBeforeRequest)
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

/// Wraps an `EventLoopPromise` with a one-shot guard so that succeed/fail can
/// be invoked from multiple call sites (handler, timeout, teardown) without
/// triggering NIO's double-completion crash.
final class PromiseResolver<Value: Sendable>: @unchecked Sendable {
    private let promise: EventLoopPromise<Value>
    private let lock = NSLock()
    private var resolved = false

    init(promise: EventLoopPromise<Value>) {
        self.promise = promise
    }

    func succeed(_ value: Value) {
        lock.lock()
        let already = resolved
        if !already { resolved = true }
        lock.unlock()
        if !already { promise.succeed(value) }
    }

    func fail(_ error: Error) {
        lock.lock()
        let already = resolved
        if !already { resolved = true }
        lock.unlock()
        if !already { promise.fail(error) }
    }
}

/// Thread-safe holder for the most recently received request, readable without
/// awaiting. Mirrors what the one-shot promise records so a test can poll
/// "did anything arrive?" without blocking when nothing does.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MockUpstream.ReceivedRequest?

    func record(_ request: MockUpstream.ReceivedRequest) {
        lock.lock()
        if stored == nil { stored = request }
        lock.unlock()
    }

    func snapshot() -> MockUpstream.ReceivedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class MockHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let resolver: PromiseResolver<MockUpstream.ReceivedRequest>
    private let recorder: RequestRecorder
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(resolver: PromiseResolver<MockUpstream.ReceivedRequest>, recorder: RequestRecorder) {
        self.resolver = resolver
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let h):
            self.head = h
        case .body(var chunk):
            if body == nil {
                body = chunk
            } else {
                body?.writeBuffer(&chunk)
            }
        case .end:
            guard let head = head else { return }
            let bodyData = body.map { Data($0.readableBytesView) }
            let request = MockUpstream.ReceivedRequest(head: head, body: bodyData)
            recorder.record(request)
            resolver.succeed(request)
            replyOK(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resolver.fail(error)
        context.close(promise: nil)
    }

    private func replyOK(context: ChannelHandlerContext) {
        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "content-length", value: "2")
        responseHeaders.add(name: "content-type", value: "text/plain")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: responseHeaders
        )
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.writeString("OK")
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

enum IntegrationTestError: Error {
    case bindFailed
    case timedOut
    case stoppedBeforeRequest
    case connectFailed(status: HTTPResponseStatus)
    case unexpectedResponse(String)
}
