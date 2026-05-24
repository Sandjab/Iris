import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL

/// Aggregated upstream response (head + buffered body). Phase 2 buffers
/// the full response; streaming arrives in Phase 2.x.
struct UpstreamResponse: Sendable {
    let head: HTTPResponseHead
    let body: ByteBuffer?
}

final class UpstreamClient: @unchecked Sendable {
    private let group: EventLoopGroup
    private let trustRoots: NIOSSLTrustRoots
    private let logger: Logger

    init(group: EventLoopGroup, trustRoots: NIOSSLTrustRoots, logger: Logger) {
        self.group = group
        self.trustRoots = trustRoots
        self.logger = logger
    }

    func send(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        host: String,
        port: Int
    ) async throws -> UpstreamResponse {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = trustRoots
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let responsePromise = group.next().makePromise(of: UpstreamResponse.self)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.pipeline.addHTTPClientHandlers().flatMap {
                            channel.pipeline.addHandler(
                                UpstreamResponseCollector(promise: responsePromise)
                            )
                        }
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            responsePromise.fail(error)
            throw error
        }

        // Send request
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body = body, body.readableBytes > 0 {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
        }
        let writePromise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: writePromise)

        do {
            try await writePromise.futureResult.get()
        } catch {
            responsePromise.fail(error)
            try? await channel.close().get()
            throw error
        }

        let response: UpstreamResponse
        do {
            response = try await responsePromise.futureResult.get()
        } catch {
            try? await channel.close().get()
            throw error
        }

        try? await channel.close().get()
        return response
    }
}

private final class UpstreamResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<UpstreamResponse>
    private var head: HTTPResponseHead?
    private var body: ByteBuffer?
    private var completed = false

    init(promise: EventLoopPromise<UpstreamResponse>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head
        case .body(var chunk):
            if body == nil {
                body = chunk
            } else {
                body?.writeBuffer(&chunk)
            }
        case .end:
            guard let head = head, !completed else { return }
            completed = true
            promise.succeed(UpstreamResponse(head: head, body: body))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ChannelError.alreadyClosed)
        }
    }
}
