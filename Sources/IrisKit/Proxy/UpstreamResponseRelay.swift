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
    /// Optional metadata-mode onResponse hook. When set, the head is held until the
    /// hook resolves the (possibly header-overlaid) head; body/end parts that arrive
    /// during that timeout-bounded window are queued, then drained in order. nil →
    /// the head is relayed immediately (byte-for-byte the v1 path).
    private let responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)?
    private var headHookInFlight = false
    /// Parts that arrived while the head hook was in flight, drained in order once
    /// the resolved head is written. NOTE: the class invariant "memory bounded by
    /// the client watermark" is SUSPENDED during this timeout-bounded window —
    /// nothing is written to the client while the hook runs, so it stays writable
    /// and upstream keeps delivering into this queue. Bound = hook-timeout ×
    /// upstream throughput (negligible for metadata/SSE; a hung plugin on a large
    /// matched response is the pathological ceiling).
    private var queuedParts: [HTTPClientResponsePart] = []
    private var status: Int = 0
    private var done = false

    init(
        clientChannel: Channel,
        completion: EventLoopPromise<StreamOutcome>,
        headWritten: NIOLoopBoundBox<Bool>,
        responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)? = nil
    ) {
        self.clientChannel = clientChannel
        self.completion = completion
        self.headWritten = headWritten
        self.responseHeadHook = responseHeadHook
    }

    // MARK: - Inbound: relay response parts to the client

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        // Head hook pending: hold body/end until the resolved head is on the wire.
        if headHookInFlight {
            queuedParts.append(part)
            return
        }
        switch part {
        case .head(let head):
            guard let hook = responseHeadHook else {
                relayHead(head)
                return
            }
            // Hold the head; run the metadata-mode hook; relay the resolved head on
            // the EventLoop, then drain anything that arrived meanwhile.
            headHookInFlight = true
            // STRONG self (no `[weak self]`): when the upstream closes while the hook
            // is in flight, NIO fires `channelInactive` and then schedules
            // `removeHandlers` on the NEXT EL tick, releasing the pipeline's reference
            // to this relay. A slow hook (real out-of-process plugins are never
            // sub-ms) resolves AFTER that — a weak ref would already be nil, the queue
            // would never drain, `completion` would never resolve, and the client
            // would hang forever. Strong self keeps the relay alive until the hook
            // resolves. No retain cycle: `self` does not retain this future chain, and
            // the hook future ALWAYS resolves (bounded by the hook timeout), so the
            // closure — and thus the relay — is released once it runs.
            hook(head).hop(to: clientChannel.eventLoop).whenComplete { result in
                // `!done`: if the stream terminally failed during the hook window
                // (upstream RST before `.end` → channelInactive → finish(.failure)),
                // MITMHandler already wrote a 502 to the client. Skip relaying the
                // late-resolving head so we never write a SECOND head onto that
                // channel. In the happy path `.end` is still queued here (not
                // relayed), so `done` is false → a valid head is never skipped.
                guard !self.done else { return }
                let resolved: HTTPResponseHead
                switch result {
                case .success(let h): resolved = h
                case .failure: resolved = head  // defensive: hook never fails (R4 skip)
                }
                self.relayHead(resolved)
                self.clientChannel.flush()  // off a read cycle → channelReadComplete won't flush
                self.headHookInFlight = false
                self.drainQueued()
            }
        case .body, .end:
            relayPart(part)
        }
    }

    /// Relays the response head to the client. Routed via `clientChannel` (typed
    /// Channel.write overload, preferred per ConnectHandler): the response
    /// traverses the client pipeline's HTTPResponseEncoder. Written unflushed: on a
    /// read cycle, `channelReadComplete` coalesces the flush (the v1 behavior — one
    /// flush per upstream read cycle, far fewer syscalls than per-part). The hook
    /// path flushes explicitly (it runs off a read cycle).
    private func relayHead(_ head: HTTPResponseHead) {
        status = Int(head.status.code)
        headWritten.value = true
        let outHead = HTTPResponseHead(version: head.version, status: head.status, headers: head.headers)
        clientChannel.write(HTTPServerResponsePart.head(outHead), promise: nil)
    }

    private func relayPart(_ part: HTTPClientResponsePart) {
        switch part {
        case .head(let head):
            relayHead(head)
        case .body(let buffer):
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        case .end(let trailers):
            // Flush the terminator and resolve on its real result: a failed
            // write to a gone client must not be reported as a successful stream.
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success: self.finish(.success(StreamOutcome(statusCode: self.status)))
                case .failure(let error): self.finish(.failure(error))
                }
            }
        }
    }

    /// Drains parts queued during the head hook, in arrival order, then flushes.
    private func drainQueued() {
        let parts = queuedParts
        queuedParts.removeAll()
        for part in parts { relayPart(part) }
        clientChannel.flush()
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        clientChannel.flush()
        context.fireChannelReadComplete()
    }

    /// True when the head hook is in flight AND a terminal `.end` is already queued:
    /// the COMPLETE response was received before the upstream channel closed or
    /// errored. In that case the in-flight hook's completion drains the queue and
    /// resolves `completion`, so an upstream close/error must NOT fail the stream —
    /// doing so would clobber a good response with a spurious 502 / truncation. A
    /// premature close/error (no `.end` queued yet) is still a fatal failure.
    private var completeResponseQueued: Bool {
        guard headHookInFlight else { return false }
        return queuedParts.contains {
            if case .end = $0 { return true }
            return false
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Mirror channelInactive: an upstream error AFTER a complete response (e.g. an
        // RST following `.end`) must not fail the stream while the head hook is in
        // flight — the hook's completion drains the queued response to the (separate)
        // client channel. Closing the erroring upstream context is always fine.
        if !completeResponseQueued {
            finish(.failure(error))
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A graceful upstream teardown after a complete response (full body + `.end`
        // queued during the hook window) is not a failure: the hook's whenComplete
        // drains the queue and resolves `completion`. Only a premature close fails.
        if !completeResponseQueued {
            finish(.failure(ChannelError.alreadyClosed))
        }
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
