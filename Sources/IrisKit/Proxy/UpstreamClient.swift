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
        on eventLoop: EventLoop,
        headWritten: NIOLoopBoundBox<Bool>
    ) -> EventLoopFuture<StreamOutcome> {
        let completion = eventLoop.makePromise(of: StreamOutcome.self)
        do {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = trustRoots
            tlsConfig.applicationProtocols = ["http/1.1"]
            let sslContext = try NIOSSLContext(configuration: tlsConfig)

            // Backpressure pairing: the client-side handler (tail of the client
            // pipeline, same EL) resumes upstream reads when the client drains
            // and closes the upstream if the client drops. It drives the WINNING
            // upstream channel (recorded in `upstreamBox` on connect success),
            // not a relay instance — `ClientBootstrap.connect(host:)` may create
            // several channels (happy eyeballs), each with its own fresh relay.
            // `stream` runs on the client EL (forwardRequest flatMap), so
            // syncOperations on the client pipeline is valid here.
            let upstreamBox = UpstreamChannelBox()
            let clientSide = ClientWritabilityHandler(upstream: upstreamBox)
            try clientChannel.pipeline.syncOperations.addHandler(clientSide)

            // Same EventLoop as the client channel: the relay writes across
            // channels without hopping, which is the safety invariant of the
            // inter-channel relay (mirrors `performPassthrough`). A FRESH relay
            // per channel — never share a handler instance across pipelines.
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
                                    completion: completion,
                                    headWritten: headWritten
                                )
                            )
                        })
                }

            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .failure(let error):
                    completion.fail(error)
                case .success(let upstream):
                    // The client may have disconnected while the upstream was
                    // still connecting: `clientSide.channelInactive` then fired
                    // with an empty `upstreamBox`, so nothing would ever close
                    // this upstream. Drop it immediately rather than leak it.
                    guard clientChannel.isActive else {
                        upstream.close(promise: nil)
                        completion.fail(ChannelError.alreadyClosed)
                        return
                    }
                    upstreamBox.channel = upstream
                    upstream.write(HTTPClientRequestPart.head(head), promise: nil)
                    if let body = body, body.readableBytes > 0 {
                        upstream.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    }
                    // On a request-write failure, close the upstream rather than
                    // failing `completion` directly: the channel is active here,
                    // so closing fires `channelInactive` → the relay resolves
                    // `completion` exactly once. (Avoids the double-completion a
                    // `cascadeFailure` would cause when both the write future and
                    // the relay's inactivity race to fail the same promise.)
                    upstream.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { _ in
                        upstream.close(promise: nil)
                    }
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
