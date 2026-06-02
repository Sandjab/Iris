import NIO
import NIOHTTP1

/// Result of relaying an upstream response: the status captured at the head.
struct StreamOutcome: Sendable {
    let statusCode: Int
}

/// Installed on the UPSTREAM channel. Translates each `HTTPClientResponsePart`
/// into an `HTTPServerResponsePart` and writes it to the CLIENT channel, which
/// is co-located on the same `EventLoop` (the upstream is opened via
/// `ClientBootstrap(group: clientEventLoop)`). Each part is flushed immediately
/// so the bytes reach the client at the wire as they arrive — no buffering
/// (SPECS §7.3 / §10.12). The status is captured at the head; `completion`
/// resolves at `.end`.
///
/// Backpressure (read-gating on the client's writability) is added in Phase 2.x
/// Task 6; this version forwards eagerly.
final class UpstreamResponseRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let clientChannel: Channel
    private let completion: EventLoopPromise<StreamOutcome>
    private var status: Int = 0
    private var done = false

    init(clientChannel: Channel, completion: EventLoopPromise<StreamOutcome>) {
        self.clientChannel = clientChannel
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            // Route via `clientChannel` (not `context`): the typed Channel.write
            // overload is preferred (see ConnectHandler) and the response must
            // traverse the client pipeline's HTTPResponseEncoder.
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

    private func finish(_ result: Result<StreamOutcome, Error>) {
        guard !done else { return }
        done = true
        switch result {
        case .success(let outcome): completion.succeed(outcome)
        case .failure(let error): completion.fail(error)
        }
    }
}
