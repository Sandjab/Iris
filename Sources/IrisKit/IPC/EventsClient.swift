import Foundation
import NIO
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - Errors

public enum EventsClientError: Error, Equatable, LocalizedError {
    case invalidURL(String)
    case httpStatus(Int)
    case streamClosed
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid events URL: \(url)"
        case .httpStatus(let code): return "Events endpoint returned HTTP \(code)"
        case .streamClosed: return "Events stream closed by server"
        case .decodeFailed(let message): return "Failed to decode SSE event: \(message)"
        }
    }
}

// MARK: - Item

public enum EventsClientItem: Sendable, Equatable {
    case event(Event)
    case ping
}

// MARK: - Client

/// Minimal SSE consumer for the `/events` endpoint (SPECS §14). Uses a
/// swift-nio HTTP/1.1 client (loopback, plain HTTP) and parses the standard
/// `event:` / `id:` / `data:` SSE format.
///
/// The inbound handler splits the response body on the LF byte (`0x0A`) and
/// emits every completed line — **including the blank line that terminates a
/// frame** — the instant it arrives. This is the whole reason for moving off
/// `URLSession.bytes.lines`: its `AsyncLineSequence` retained a frame's
/// trailing blank line until a *later* byte arrived, so an isolated event
/// never materialized in real time (it surfaced only when the next event or
/// the 15 s heartbeat pushed the buffered blank line through).
public struct EventsClient: Sendable {
    public let baseURL: URL
    private let group: EventLoopGroup
    private let ownsGroup: Bool

    public init(
        host: String = "127.0.0.1",
        port: Int,
        group: EventLoopGroup? = nil
    ) {
        // URLComponents path/host parsing is overkill here: assemble the
        // loopback URL by string and force-unwrap with a precondition. If
        // the inputs are non-sensical the daemon would never have started.
        guard let url = URL(string: "http://\(host):\(port)/events") else {
            preconditionFailure("EventsClient cannot build URL from host=\(host) port=\(port)")
        }
        self.baseURL = url
        if let group = group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    /// Caller-owned lifecycle: invoke `await shutdown()` before dropping the
    /// client when no `group` was supplied at init. Mirrors `AdminClient`: we
    /// never shut down from `deinit` (a blocking call from ARC teardown can
    /// deadlock), and never touch a group the caller injected.
    public func shutdown() async throws {
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }

    public func subscribe(
        since: Date? = nil,
        kinds: [Event.Kind]? = nil,
        host: String? = nil
    ) async throws -> AsyncThrowingStream<EventsClientItem, Error> {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []
        if let since = since {
            let formatter = ISO8601DateFormatter()
            queryItems.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        if let kinds = kinds, !kinds.isEmpty {
            queryItems.append(
                URLQueryItem(name: "kind", value: kinds.map(\.rawValue).joined(separator: ","))
            )
        }
        if let host = host {
            queryItems.append(URLQueryItem(name: "host", value: host))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url,
            let connectHost = url.host,
            let connectPort = url.port
        else {
            throw EventsClientError.invalidURL(baseURL.absoluteString)
        }
        var uri = url.path
        if let query = url.query {
            uri += "?" + query
        }

        // Build the stream and capture its continuation synchronously (the
        // build closure runs inline). Done before connecting so the SSE handler
        // can yield into it. No `Task {}` is spawned: `subscribe` is already
        // `async`, so we connect in line — that also keeps the connect/HTTP
        // errors surfacing from `subscribe()` itself, as the URLSession version
        // did, and avoids a `sending`-closure capture race under Swift 6.
        var capturedContinuation: AsyncThrowingStream<EventsClientItem, Error>.Continuation?
        let stream = AsyncThrowingStream<EventsClientItem, Error> { capturedContinuation = $0 }
        guard let continuation = capturedContinuation else {
            // Unreachable: the build closure above runs synchronously.
            throw EventsClientError.streamClosed
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            SSEInboundHandler(continuation: continuation)
                        )
                    }
                }
            }

        let channel = try await bootstrap.connect(host: connectHost, port: connectPort).get()

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
        head.headers.add(name: "Host", value: "\(connectHost):\(connectPort)")
        head.headers.add(name: "Accept", value: "text/event-stream")
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        do {
            try await channel.writeAndFlush(HTTPClientRequestPart.end(nil))
        } catch {
            channel.close(promise: nil)
            throw error
        }

        // The handler drives every yield; this closure just tears down the
        // connection when the consumer stops iterating (or the stream is
        // dropped). `Channel.close` is thread-safe off the event loop; a stored
        // `ChannelHandlerContext` would not be — the CONNECT-502 lesson.
        continuation.onTermination = { _ in channel.close(promise: nil) }
        return stream
    }
}

// MARK: - Per-connection inbound handler

/// Parses the SSE wire format off the inbound `ByteBuffer`s. All state is
/// confined to the channel's event loop (touched only from `channelRead` /
/// `errorCaught` / `channelInactive`), so `@unchecked Sendable` is sound —
/// same pattern as `UpstreamResponseCollector`.
private final class SSEInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private struct SSEFrame {
        var eventName: String?
        var id: String?
        var data: String = ""
    }

    private let continuation: AsyncThrowingStream<EventsClientItem, Error>.Continuation
    private var streamOK = false
    private var finished = false
    private var pending = ByteBuffer()
    private var frame = SSEFrame()

    init(continuation: AsyncThrowingStream<EventsClientItem, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            if head.status.code == 200 {
                streamOK = true
            } else {
                finish(throwing: EventsClientError.httpStatus(Int(head.status.code)))
                context.close(promise: nil)
            }
        case .body(var chunk):
            guard streamOK else { return }
            pending.writeBuffer(&chunk)
            drainLines(context: context)
        case .end:
            finish(throwing: nil)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Clean EOF: finish WITHOUT throwing so `SyncCoordinator`'s reconnect
        // loop treats it as a transient drop (a stable run resets its backoff).
        finish(throwing: nil)
        context.fireChannelInactive()
    }

    /// Emit every complete line in `pending` (split on LF), including the blank
    /// line that materializes a frame — the core fix. No look-ahead, so an
    /// isolated event flushes the instant its terminating blank line arrives.
    private func drainLines(context: ChannelHandlerContext) {
        while true {
            let view = pending.readableBytesView
            guard let lfIndex = view.firstIndex(of: 0x0A) else { break }
            // `distance(from:to:)` yields the line length whatever the view's
            // index base is. `readableBytesView` indices are buffer-absolute
            // (startIndex == readerIndex), so this equals `lfIndex - readerIndex`
            // — but expressing it as a Collection distance keeps the parser from
            // coupling to that internal detail.
            let lineLength = view.distance(from: view.startIndex, to: lfIndex)
            guard var lineSlice = pending.readSlice(length: lineLength) else { break }
            pending.moveReaderIndex(forwardBy: 1)  // consume the LF
            var line = lineSlice.readString(length: lineSlice.readableBytes) ?? ""
            if line.hasSuffix("\r") { line.removeLast() }  // tolerate CRLF
            handle(line: line, context: context)
            if finished { return }
        }
        pending.discardReadBytes()
    }

    private func handle(line: String, context: ChannelHandlerContext) {
        if line.isEmpty {
            do {
                if let item = try materialize(frame: frame) {
                    continuation.yield(item)
                }
            } catch {
                finish(throwing: error)  // already `.decodeFailed` from materialize
                context.close(promise: nil)
            }
            frame = SSEFrame()
            return
        }
        if line.hasPrefix(":") {
            // SSE comment — used as heartbeat / connection primer by the server.
            continuation.yield(.ping)
            return
        }
        absorb(line: line, into: &frame)
    }

    private func absorb(line: String, into frame: inout SSEFrame) {
        // Each line is `field: value` or `field:value`.
        guard let colonIndex = line.firstIndex(of: ":") else { return }
        let field = String(line[..<colonIndex])
        var valueStart = line.index(after: colonIndex)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        let value = String(line[valueStart...])
        switch field {
        case "event": frame.eventName = value
        case "id": frame.id = value
        case "data":
            if !frame.data.isEmpty { frame.data.append("\n") }
            frame.data.append(value)
        default:
            break
        }
    }

    private func materialize(frame: SSEFrame) throws -> EventsClientItem? {
        guard frame.eventName != nil else { return nil }
        guard let payloadData = frame.data.data(using: .utf8) else { return nil }
        do {
            let event = try JSONRPCCoder.makeDecoder().decode(Event.self, from: payloadData)
            return .event(event)
        } catch {
            throw EventsClientError.decodeFailed("\(error)")
        }
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
