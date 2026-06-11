import NIOCore
import NIOHTTP1

/// Shared response for the reserved `GET /__iris_ping` diagnostic endpoint
/// (used by `iris doctor`): bypasses all proxy logic and emits no event.
enum PingResponder {
    static func matches(_ head: HTTPRequestHead) -> Bool {
        head.uri == "/__iris_ping" && head.method == .GET
    }

    /// Writes `200 ok\n` on the channel. Routes via `Channel.write` (typed,
    /// thread-safe) rather than the handler context.
    static func respond(on channel: Channel, closeAfter: Bool) {
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", "text/plain"),
                ("Content-Length", "3"),
                ("Cache-Control", "no-store"),
            ])
        )
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        var buf = channel.allocator.buffer(capacity: 3)
        buf.writeString("ok\n")
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        if closeAfter {
            let p = channel.eventLoop.makePromise(of: Void.self)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: p)
            p.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        } else {
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }
    }
}
