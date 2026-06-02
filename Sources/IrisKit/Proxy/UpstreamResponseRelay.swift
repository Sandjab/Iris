import NIO
import NIOHTTP1

/// Result of relaying an upstream response: the status captured at the head.
struct StreamOutcome: Sendable {
    let statusCode: Int
}

/// Holds the winning upstream channel for the client-side handler. A single
/// `ClientBootstrap.connect(host:)` may create MULTIPLE channels (happy eyeballs
/// over A/AAAA records); each gets its own fresh relay, but only the winner
/// actually connects. The winner is recorded here on connect success so the
/// client side can drive backpressure-resume and upstream-close on it. Holds the
/// channel `weak` (NIO retains the open channel) to avoid a retain cycle.
final class UpstreamChannelBox: @unchecked Sendable {
    weak var channel: Channel?
}

/// Installed at the tail of the UPSTREAM pipeline, fresh per connection attempt.
/// Translates each `HTTPClientResponsePart` into an `HTTPServerResponsePart` and
/// writes it to the CLIENT channel (co-located on the same `EventLoop`). Each
/// part is flushed immediately so bytes reach the client at the wire as they
/// arrive — no buffering (SPECS §7.3 / §10.12). Status captured at the head;
/// `completion` resolves at `.end`.
///
/// Backpressure (canonical swift-nio `GlueHandler` model): `read(context:)` only
/// pulls more from upstream while the client channel is writable; otherwise the
/// read is swallowed. The paired `ClientWritabilityHandler` re-issues a read on
/// the upstream channel once the client drains below its low watermark. Upstream
/// `autoRead` stays enabled. Memory is bounded by the client channel's watermark.
final class UpstreamResponseRelay: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let completion: EventLoopPromise<StreamOutcome>
    /// Set to `true` the moment the response head is relayed. `MITMHandler` reads
    /// it on stream failure to choose between a `502` (no head yet) and a
    /// truncated close (head already sent). EL-confined to the shared loop.
    private let headWritten: NIOLoopBoundBox<Bool>
    private var status: Int = 0
    private var done = false

    init(
        clientChannel: Channel,
        completion: EventLoopPromise<StreamOutcome>,
        headWritten: NIOLoopBoundBox<Bool>
    ) {
        self.clientChannel = clientChannel
        self.completion = completion
        self.headWritten = headWritten
    }

    // MARK: - Inbound: relay response parts to the client

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headWritten.value = true
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
        context.fireChannelInactive()
    }

    // MARK: - Outbound: gate reads on the client's writability

    func read(context: ChannelHandlerContext) {
        // Only pull more from upstream while the client can absorb it. When the
        // client's buffer is full the read is swallowed; `ClientWritabilityHandler`
        // re-issues `upstreamChannel.read()` once the client drains.
        if clientChannel.isWritable {
            context.read()
        }
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

/// Installed at the tail of the CLIENT pipeline. Bridges two signals the relay
/// (on the upstream pipeline) cannot observe directly:
/// - client became writable → resume the gated upstream read (backpressure);
/// - client went inactive → close the upstream (no leaked connection, §5 case 3).
///
/// Drives the winning upstream channel via `UpstreamChannelBox` rather than a
/// relay reference, so happy-eyeballs' multiple per-channel relays are a non-issue.
final class ClientWritabilityHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    private let upstream: UpstreamChannelBox

    init(upstream: UpstreamChannelBox) {
        self.upstream = upstream
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            upstream.channel?.read()
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream.channel?.close(promise: nil)
        context.fireChannelInactive()
    }
}
