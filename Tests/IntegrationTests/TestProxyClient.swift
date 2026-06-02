import Foundation
import NIO
import NIOHTTP1
import NIOSSL

/// Manual NIO-based HTTP/1.1 client that goes through a forward HTTPS
/// proxy: TCP → CONNECT → TLS handshake → HTTP request → response.
final class TestProxyClient: @unchecked Sendable {
    struct Response: Sendable {
        let status: HTTPResponseStatus
        let headers: HTTPHeaders
        let body: Data
    }

    /// Streaming response surface: every body chunk is yielded as soon as it is
    /// received. `firstChunk` resolves on the FIRST body chunk (proof of
    /// incremental arrival). `bodyChunks` finishes at `.end` (or on close).
    struct StreamingResponse: Sendable {
        let status: HTTPResponseStatus
        let headers: HTTPHeaders
        let firstChunk: EventLoopFuture<Void>
        let bodyChunks: AsyncStream<Data>
    }

    func send(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        method: HTTPMethod,
        path: String,
        headers: [(String, String)],
        body: Data?,
        trustingCAs: [NIOSSLCertificate]
    ) async throws -> Response {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let connectPromise = group.next().makePromise(of: HTTPResponseStatus.self)
        let encoder = HTTPRequestEncoder()
        let decoder = ByteToMessageHandler(
            HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)
        )
        let expectation = ConnectExpectationHandler(promise: connectPromise)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(encoder)
                    .flatMap { channel.pipeline.addHandler(decoder) }
                    .flatMap { channel.pipeline.addHandler(expectation) }
            }

        let channel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()

        let connectHead = HTTPRequestHead(
            version: .http1_1,
            method: .CONNECT,
            uri: "\(targetHost):\(targetPort)"
        )
        channel.write(HTTPClientRequestPart.head(connectHead), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let status = try await connectPromise.futureResult.get()
        guard status == .ok else {
            try? await channel.close().get()
            throw IntegrationTestError.connectFailed(status: status)
        }

        // Atomic swap on the EL: drop plain HTTP handlers, install TLS.
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = .certificates(trustingCAs)
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: targetHost)

        try await channel.eventLoop.submit {
            let sync = channel.pipeline.syncOperations
            try sync.removeHandler(encoder)
            try sync.removeHandler(decoder)
            try sync.removeHandler(expectation)
            try sync.addHandler(sslHandler, position: .first)
        }.get()
        try await channel.pipeline.addHTTPClientHandlers().get()

        let responsePromise = group.next().makePromise(of: Response.self)
        try await channel.pipeline
            .addHandler(ResponseCollectorHandler(promise: responsePromise))
            .get()

        // Send actual request through the TLS tunnel.
        var requestHeaders = HTTPHeaders()
        for (name, value) in headers {
            requestHeaders.add(name: name, value: value)
        }
        if let body = body, !requestHeaders.contains(name: "content-length") {
            requestHeaders.add(name: "content-length", value: "\(body.count)")
        }
        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: path,
            headers: requestHeaders
        )
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        if let body = body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let response = try await responsePromise.futureResult.get()
        try? await channel.close().get()
        return response
    }

    /// Streaming counterpart to `send`: identical up to the TLS swap, but installs
    /// `StreamingCollectorHandler` so each body chunk surfaces immediately via an
    /// `AsyncStream`. The EventLoopGroup is NOT torn down here — the handler shuts
    /// it down when the stream ends (the caller drains `bodyChunks`).
    func sendStreaming(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        method: HTTPMethod,
        path: String,
        headers: [(String, String)],
        body: Data?,
        trustingCAs: [NIOSSLCertificate],
        streamTimeout: TimeAmount = .seconds(5)
    ) async throws -> StreamingResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connectPromise = group.next().makePromise(of: HTTPResponseStatus.self)
        let encoder = HTTPRequestEncoder()
        let decoder = ByteToMessageHandler(
            HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)
        )
        let expectation = ConnectExpectationHandler(promise: connectPromise)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(encoder)
                    .flatMap { channel.pipeline.addHandler(decoder) }
                    .flatMap { channel.pipeline.addHandler(expectation) }
            }

        let channel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()

        let connectHead = HTTPRequestHead(
            version: .http1_1,
            method: .CONNECT,
            uri: "\(targetHost):\(targetPort)"
        )
        channel.write(HTTPClientRequestPart.head(connectHead), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let status = try await connectPromise.futureResult.get()
        guard status == .ok else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw IntegrationTestError.connectFailed(status: status)
        }

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = .certificates(trustingCAs)
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: targetHost)

        try await channel.eventLoop.submit {
            let sync = channel.pipeline.syncOperations
            try sync.removeHandler(encoder)
            try sync.removeHandler(decoder)
            try sync.removeHandler(expectation)
            try sync.addHandler(sslHandler, position: .first)
        }.get()
        try await channel.pipeline.addHTTPClientHandlers().get()

        let headPromise = group.next().makePromise(of: (HTTPResponseStatus, HTTPHeaders).self)
        let firstChunkPromise = group.next().makePromise(of: Void.self)
        // A non-streaming proxy withholds the response head until the whole body
        // is buffered. Awaiting `headPromise`/`firstChunk` would then hang
        // forever: swift-nio's `EventLoopFuture.get()` ignores task cancellation,
        // so a Task-based timeout cannot interrupt it. Instead we arm an
        // EL-scheduled deadline that *fails the promises*, so `get()` returns a
        // clean `timedOut` error. `PromiseResolver` guards the resolver against
        // the handler's normal completion racing the deadline.
        let headResolver = PromiseResolver(promise: headPromise)
        let firstResolver = PromiseResolver(promise: firstChunkPromise)
        group.next().scheduleTask(in: streamTimeout) {
            headResolver.fail(IntegrationTestError.timedOut)
            firstResolver.fail(IntegrationTestError.timedOut)
        }
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let collector = StreamingCollectorHandler(
            headResolver: headResolver,
            firstResolver: firstResolver,
            continuation: continuation,
            group: group,
            channel: channel
        )
        try await channel.pipeline.addHandler(collector).get()

        var requestHeaders = HTTPHeaders()
        for (name, value) in headers {
            requestHeaders.add(name: name, value: value)
        }
        if let body = body, !requestHeaders.contains(name: "content-length") {
            requestHeaders.add(name: "content-length", value: "\(body.count)")
        }
        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: path,
            headers: requestHeaders
        )
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        if let body = body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let st: HTTPResponseStatus
        let hdrs: HTTPHeaders
        do {
            (st, hdrs) = try await headPromise.futureResult.get()
        } catch {
            // Head never arrived within `streamTimeout` (e.g. a buffering proxy):
            // tear down so we do not leak the channel/group, then surface the error.
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        return StreamingResponse(
            status: st,
            headers: hdrs,
            firstChunk: firstChunkPromise.futureResult,
            bodyChunks: stream
        )
    }

    /// Connects through the proxy, sends the request, and closes the client
    /// connection as soon as the FIRST response body chunk arrives — simulating
    /// a client dropping mid-stream. Returns once chunk1 has been received (and
    /// the close initiated), or throws `timedOut` if no chunk arrives.
    func dropAfterFirstResponseChunk(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        method: HTTPMethod,
        path: String,
        headers: [(String, String)],
        body: Data?,
        trustingCAs: [NIOSSLCertificate],
        streamTimeout: TimeAmount = .seconds(5)
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connectPromise = group.next().makePromise(of: HTTPResponseStatus.self)
        let encoder = HTTPRequestEncoder()
        let decoder = ByteToMessageHandler(
            HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)
        )
        let expectation = ConnectExpectationHandler(promise: connectPromise)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(encoder)
                    .flatMap { channel.pipeline.addHandler(decoder) }
                    .flatMap { channel.pipeline.addHandler(expectation) }
            }
        let channel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()

        let connectHead = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "\(targetHost):\(targetPort)")
        channel.write(HTTPClientRequestPart.head(connectHead), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        let status = try await connectPromise.futureResult.get()
        guard status == .ok else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw IntegrationTestError.connectFailed(status: status)
        }

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = .certificates(trustingCAs)
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: targetHost)
        try await channel.eventLoop.submit {
            let sync = channel.pipeline.syncOperations
            try sync.removeHandler(encoder)
            try sync.removeHandler(decoder)
            try sync.removeHandler(expectation)
            try sync.addHandler(sslHandler, position: .first)
        }.get()
        try await channel.pipeline.addHTTPClientHandlers().get()

        let firstChunkPromise = group.next().makePromise(of: Void.self)
        let firstResolver = PromiseResolver(promise: firstChunkPromise)
        group.next().scheduleTask(in: streamTimeout) {
            firstResolver.fail(IntegrationTestError.timedOut)
        }
        try await channel.pipeline.addHandler(
            DropAfterFirstChunkHandler(firstChunk: firstResolver, group: group)
        ).get()

        var requestHeaders = HTTPHeaders()
        for (name, value) in headers {
            requestHeaders.add(name: name, value: value)
        }
        if let body = body, !requestHeaders.contains(name: "content-length") {
            requestHeaders.add(name: "content-length", value: "\(body.count)")
        }
        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: path,
            headers: requestHeaders
        )
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        if let body = body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        // Block until chunk1 arrives; the handler then closes the channel (the drop).
        try await firstChunkPromise.futureResult.get()
    }

    /// CONNECT-only helper, used to assert non-whitelisted hosts get a 502.
    static func sendConnectOnly(
        proxyHost: String,
        proxyPort: Int,
        targetAuthority: String
    ) async throws -> HTTPResponseStatus {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let promise = group.next().makePromise(of: HTTPResponseStatus.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let encoder = HTTPRequestEncoder()
                let decoder = ByteToMessageHandler(HTTPResponseDecoder())
                let expectation = ConnectExpectationHandler(promise: promise)
                return channel.pipeline.addHandler(encoder).flatMap {
                    channel.pipeline.addHandler(decoder)
                }.flatMap {
                    channel.pipeline.addHandler(expectation)
                }
            }

        let channel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .CONNECT,
            uri: targetAuthority
        )
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        let status = try await promise.futureResult.get()
        try? await channel.close().get()
        return status
    }
}

private final class ConnectExpectationHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<HTTPResponseStatus>
    private var completed = false

    init(promise: EventLoopPromise<HTTPResponseStatus>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            if !completed {
                completed = true
                promise.succeed(head.status)
            }
        case .body, .end:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            completed = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ChannelError.alreadyClosed)
        }
    }
}

private final class ResponseCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<TestProxyClient.Response>
    private var head: HTTPResponseHead?
    private var body: ByteBuffer?
    private var completed = false

    init(promise: EventLoopPromise<TestProxyClient.Response>) {
        self.promise = promise
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
            guard let head = head, !completed else { return }
            completed = true
            let bodyData = body.map { Data($0.readableBytesView) } ?? Data()
            promise.succeed(
                TestProxyClient.Response(status: head.status, headers: head.headers, body: bodyData)
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            completed = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ChannelError.alreadyClosed)
        }
    }
}

/// Receives the response head, then closes the channel on the FIRST body chunk
/// — a client dropping mid-stream. `firstChunk` resolves when chunk1 arrives.
private final class DropAfterFirstChunkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let firstChunk: PromiseResolver<Void>
    private let group: EventLoopGroup

    init(firstChunk: PromiseResolver<Void>, group: EventLoopGroup) {
        self.firstChunk = firstChunk
        self.group = group
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            break
        case .body:
            firstChunk.succeed(())
            context.close(promise: nil)  // drop mid-stream
        case .end:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        firstChunk.fail(error)
        context.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        firstChunk.fail(ChannelError.alreadyClosed)
        group.shutdownGracefully { _ in }
    }
}

/// Streaming counterpart to `ResponseCollectorHandler`: surfaces the head via a
/// resolver, signals `firstResolver` on the first body part, and yields every
/// body chunk into an `AsyncStream` as it arrives. Tears down the group at
/// `.end` / error / inactive so the caller does not have to. The resolvers are
/// `PromiseResolver`-guarded, so racing the EL deadline (see `sendStreaming`)
/// is safe — first completion wins.
private final class StreamingCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let headResolver: PromiseResolver<(HTTPResponseStatus, HTTPHeaders)>
    private let firstResolver: PromiseResolver<Void>
    private let continuation: AsyncStream<Data>.Continuation
    private let group: EventLoopGroup
    private let channel: Channel

    init(
        headResolver: PromiseResolver<(HTTPResponseStatus, HTTPHeaders)>,
        firstResolver: PromiseResolver<Void>,
        continuation: AsyncStream<Data>.Continuation,
        group: EventLoopGroup,
        channel: Channel
    ) {
        self.headResolver = headResolver
        self.firstResolver = firstResolver
        self.continuation = continuation
        self.group = group
        self.channel = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            headResolver.succeed((h.status, h.headers))
        case .body(let buf):
            firstResolver.succeed(())
            continuation.yield(Data(buf.readableBytesView))
        case .end:
            continuation.finish()
            channel.close(promise: nil)
            group.shutdownGracefully { _ in }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        headResolver.fail(error)
        firstResolver.fail(error)
        continuation.finish()
        context.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        headResolver.fail(ChannelError.alreadyClosed)
        firstResolver.fail(ChannelError.alreadyClosed)
        continuation.finish()
        group.shutdownGracefully { _ in }
    }
}
