import NIO

/// Bidirectional byte-glue used to splice two `Channel`s into a raw TCP tunnel.
/// SPECS §8.3: non-whitelisted CONNECT requests are tunneled without decryption.
///
/// A matched pair is installed at the tail of the client pipeline and the tail
/// of the upstream pipeline. Each handler forwards inbound `ByteBuffer`s to its
/// partner's downstream `write`, mirrors `flush`, and propagates close.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // `weak` breaks the A↔B reference cycle between the matched pair so the
    // handlers can deallocate cleanly even if `handlerRemoved` is missed on
    // one side. Safe because each handler is independently retained by its
    // own `ChannelPipeline`, and both channels share the same `EventLoop`
    // (the upstream is opened via `ClientBootstrap(group: clientEventLoop)`).
    private weak var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerClose()
        context.close(promise: nil)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerClose() {
        context?.close(promise: nil)
    }
}
