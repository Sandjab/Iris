import NIO
import NIOHTTP1

/// Result of relaying an upstream response: the status captured at the head.
struct StreamOutcome: Sendable {
    let statusCode: Int
}

/// Installed at the tail of the UPSTREAM pipeline. Translates each
/// `HTTPClientResponsePart` into an `HTTPServerResponsePart` and writes it to
/// the CLIENT channel, which is co-located on the same `EventLoop` (the upstream
/// is opened via `ClientBootstrap(group: clientEventLoop)`). Each part is
/// flushed immediately so bytes reach the client at the wire as they arrive — no
/// buffering (SPECS §7.3 / §10.12). The status is captured at the head;
/// `completion` resolves at `.end`.
///
/// Backpressure (canonical swift-nio `GlueHandler` model): the handler is a
/// `ChannelDuplexHandler` whose `read(context:)` only pulls more from upstream
/// when the client channel is writable. When the client's outbound buffer fills
/// (slow client), `isWritable` flips false and the read is deferred; the paired
/// `ClientWritabilityHandler` resumes it once the client drains below the low
/// watermark. Upstream `autoRead` stays enabled — it issues the `read()` that
/// this override gates. Memory is bounded by the client channel's watermark.
final class UpstreamResponseRelay: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let completion: EventLoopPromise<StreamOutcome>
    private var context: ChannelHandlerContext?
    private var status: Int = 0
    private var done = false
    private var pendingRead = false

    init(clientChannel: Channel, completion: EventLoopPromise<StreamOutcome>) {
        self.clientChannel = clientChannel
        self.completion = completion
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    // MARK: - Inbound: relay response parts to the client

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            // Route via `clientChannel` (typed Channel.write overload, preferred
            // per ConnectHandler): the response traverses the client pipeline's
            // HTTPResponseEncoder.
            let outHead = HTTPResponseHead(
                version: head.version,
                status: head.status,
                headers: head.headers
            )
            clientChannel.writeAndFlush(HTTPServerResponsePart.head(outHead), promise: nil)
        case .body(let buffer):
            clientChannel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        case .end(let trailers):
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { [weak self] _ in
                guard let self = self else { return }
                self.finish(.success(StreamOutcome(statusCode: self.status)))
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.alreadyClosed))
    }

    // MARK: - Outbound: gate reads on the client's writability

    func read(context: ChannelHandlerContext) {
        if clientChannel.isWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    /// Called by the paired `ClientWritabilityHandler` when the client channel
    /// drains below its low watermark. Resumes a read deferred by `read`.
    func clientBecameWritable() {
        guard pendingRead, let context = context else { return }
        pendingRead = false
        context.read()
    }

    /// Called by the paired `ClientWritabilityHandler` when the client channel
    /// goes inactive (client dropped mid-stream). Closes the upstream so the
    /// connection is not leaked (SPECS §5 case 3).
    func clientGone() {
        context?.close(promise: nil)
    }

    private func finish(_ result: Result<StreamOutcome, Error>) {
        guard !done else { return }
        done = true
        switch result {
        case .success(let outcome): completion.succeed(outcome)
        case .failure(let error): completion.fail(error)
        }
    }
}

/// Installed at the tail of the CLIENT pipeline, paired with an
/// `UpstreamResponseRelay`. Bridges two signals the relay (which lives on the
/// upstream pipeline) cannot observe directly:
/// - client became writable → resume the gated upstream read (backpressure);
/// - client went inactive → close the upstream (no leaked connection).
///
/// Holds the relay `weak`: the relay is retained by the upstream pipeline, and
/// this avoids a `clientChannel → pipeline → here → relay → clientChannel`
/// retain cycle.
final class ClientWritabilityHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    private weak var relay: UpstreamResponseRelay?

    init(relay: UpstreamResponseRelay) {
        self.relay = relay
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            relay?.clientBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        relay?.clientGone()
        context.fireChannelInactive()
    }
}
