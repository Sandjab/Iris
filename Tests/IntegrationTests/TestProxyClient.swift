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
