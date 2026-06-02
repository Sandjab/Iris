import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL

final class UpstreamClient: @unchecked Sendable {
    private let group: EventLoopGroup
    private let trustRoots: NIOSSLTrustRoots
    private let logger: Logger

    init(group: EventLoopGroup, trustRoots: NIOSSLTrustRoots, logger: Logger) {
        self.group = group
        self.trustRoots = trustRoots
        self.logger = logger
    }

    /// Opens the upstream connection ON THE CLIENT'S EVENTLOOP (co-location, as
    /// the passthrough tunnel does), sends the request, and installs an
    /// `UpstreamResponseRelay` that streams each response part back to
    /// `clientChannel` at the wire. Returns a future resolved at the end of the
    /// stream, carrying the status captured at the head. Pure NIO future chain —
    /// no `async` on this hot path.
    func stream(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        host: String,
        port: Int,
        to clientChannel: Channel,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<StreamOutcome> {
        let completion = eventLoop.makePromise(of: StreamOutcome.self)
        do {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = trustRoots
            tlsConfig.applicationProtocols = ["http/1.1"]
            let sslContext = try NIOSSLContext(configuration: tlsConfig)

            // Same EventLoop as the client channel: the relay writes across
            // channels without hopping, which is the safety invariant of the
            // inter-channel relay (mirrors `performPassthrough`).
            let bootstrap = ClientBootstrap(group: eventLoop)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture(
                        withResultOf: {
                            let sslHandler = try NIOSSLClientHandler(
                                context: sslContext,
                                serverHostname: host
                            )
                            let sync = channel.pipeline.syncOperations
                            try sync.addHandler(sslHandler)
                            try sync.addHTTPClientHandlers()
                            try sync.addHandler(
                                UpstreamResponseRelay(
                                    clientChannel: clientChannel,
                                    completion: completion
                                )
                            )
                        })
                }

            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .failure(let error):
                    completion.fail(error)
                case .success(let upstream):
                    upstream.write(HTTPClientRequestPart.head(head), promise: nil)
                    if let body = body, body.readableBytes > 0 {
                        upstream.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    }
                    upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
                        .cascadeFailure(to: completion)
                    // Close the upstream once the stream is done (either end).
                    completion.futureResult.whenComplete { _ in upstream.close(promise: nil) }
                }
            }
        } catch {
            completion.fail(error)
        }
        return completion.futureResult
    }
}
