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
        on eventLoop: EventLoop,
        headWritten: NIOLoopBoundBox<Bool>
    ) -> EventLoopFuture<StreamOutcome> {
        let completion = eventLoop.makePromise(of: StreamOutcome.self)
        do {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = trustRoots
            tlsConfig.applicationProtocols = ["http/1.1"]
            let sslContext = try NIOSSLContext(configuration: tlsConfig)

            // Backpressure pairing: the relay lives on the upstream pipeline and
            // gates its reads on the client's writability; the client-side
            // handler (tail of the client pipeline, same EL) resumes the relay
            // when the client drains and closes the upstream if the client drops.
            // `stream` runs on the client EL (forwardRequest flatMap), so
            // syncOperations on the client pipeline is valid here.
            let relay = UpstreamResponseRelay(
                clientChannel: clientChannel,
                completion: completion,
                headWritten: headWritten
            )
            let clientSide = ClientWritabilityHandler(relay: relay)
            try clientChannel.pipeline.syncOperations.addHandler(clientSide)
            let boundRelay = NIOLoopBound(relay, eventLoop: eventLoop)

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
                            try sync.addHandler(boundRelay.value)
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
