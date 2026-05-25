import Foundation
import Logging
import NIO
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - Errors

public enum EventsServerError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case bindFailed(host: String, port: Int, message: String)
    case refusingNonLoopbackHost(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "EventsServer already started"
        case .bindFailed(let host, let port, let message):
            return "Failed to bind events listener on \(host):\(port): \(message)"
        case .refusingNonLoopbackHost(let host):
            return "Refusing to bind events listener on non-loopback host '\(host)'"
        }
    }
}

// MARK: - EventsServer

/// HTTP/1.1 SSE listener that streams `EventRing` events to connected
/// subscribers (SPECS §14). Bound to loopback only — refuses to start on
/// any external interface.
public final class EventsServer: @unchecked Sendable {
    public let listenHost: String
    public let listenPort: Int
    public let bus: EventsBus
    public let eventRing: EventRing
    public let logger: Logger

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var serverChannel: Channel?

    public init(
        listenHost: String,
        listenPort: Int,
        bus: EventsBus,
        eventRing: EventRing,
        group: EventLoopGroup? = nil,
        logger: Logger = Logger(label: "io.iris.events")
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.bus = bus
        self.eventRing = eventRing
        self.logger = logger
        if let group = group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    @discardableResult
    public func start() async throws -> SocketAddress {
        guard serverChannel == nil else { throw EventsServerError.alreadyStarted }
        // Loopback-only invariant: an external bind would expose the event
        // stream (which carries no secrets but does carry hostnames + paths
        // visible to other LAN nodes). Refuse anything that isn't a
        // loopback literal.
        guard Self.isLoopback(listenHost) else {
            throw EventsServerError.refusingNonLoopbackHost(listenHost)
        }

        let bus = self.bus
        let eventRing = self.eventRing
        let logger = self.logger
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    .flatMap {
                        channel.eventLoop.makeCompletedFuture(
                            withResultOf: {
                                try channel.pipeline.syncOperations.addHandler(
                                    SSEHandler(
                                        bus: bus,
                                        eventRing: eventRing,
                                        logger: logger
                                    )
                                )
                            }
                        )
                    }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: listenHost, port: listenPort).get()
        } catch {
            throw EventsServerError.bindFailed(
                host: listenHost,
                port: listenPort,
                message: "\(error)"
            )
        }
        self.serverChannel = channel
        guard let address = channel.localAddress else {
            throw EventsServerError.bindFailed(
                host: listenHost,
                port: listenPort,
                message: "no local address"
            )
        }
        logger.info(
            "EventsServer listening",
            metadata: ["address": "\(address)"]
        )
        return address
    }

    public func stop() async throws {
        if let channel = serverChannel {
            try await channel.close().get()
            serverChannel = nil
        }
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}

// MARK: - Per-connection handler

final class SSEHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bus: EventsBus
    private let eventRing: EventRing
    private let logger: Logger

    private var requestHead: HTTPRequestHead?
    private var streamingTask: Task<Void, Never>?
    private var heartbeat: RepeatedTask?

    init(bus: EventsBus, eventRing: EventRing, logger: Logger) {
        self.bus = bus
        self.eventRing = eventRing
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            // SSE is a request/response pattern with no client body; ignore.
            break
        case .end:
            guard let head = requestHead else { return }
            startStreaming(context: context, head: head)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamingTask?.cancel()
        heartbeat?.cancel()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("SSE connection error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }

    // MARK: Streaming

    private func startStreaming(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard head.uri.split(separator: "?").first == "/events" else {
            writeStatus(.notFound, to: context)
            return
        }
        guard head.method == .GET else {
            writeStatus(.methodNotAllowed, to: context)
            return
        }
        let filters = SSEFilters.parse(uri: head.uri)

        let headers = HTTPHeaders([
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
        ])
        var responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        // Force chunked transfer for the streaming body; otherwise NIO
        // computes a Content-Length we don't know.
        responseHead.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        // URLSession.bytes(for:) buffers the first chunk until *some* body
        // arrives — without this priming comment the client wouldn't see
        // an event until the 15 s heartbeat fired. Comment lines (`:`) are
        // valid SSE no-ops.
        var primer = context.channel.allocator.buffer(capacity: 16)
        primer.writeString(": connected\n\n")
        context.writeAndFlush(
            self.wrapOutboundOut(.body(.byteBuffer(primer))),
            promise: nil
        )

        let channel = context.channel
        let eventLoop = context.eventLoop
        let bus = self.bus
        let eventRing = self.eventRing
        let logger = self.logger

        // 15-second keep-alive comment (SPECS §14.2).
        heartbeat = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(15),
            delay: .seconds(15)
        ) { _ in
            var buffer = channel.allocator.buffer(capacity: 8)
            buffer.writeString(": ping\n\n")
            channel.writeAndFlush(
                HTTPServerResponsePart.body(.byteBuffer(buffer)),
                promise: nil
            )
        }

        // Send any historical events the caller asked for, then attach to
        // the live bus stream. We subscribe BEFORE walking the backlog so
        // events emitted concurrently are not lost.
        streamingTask = Task {
            let (subscriberID, stream) = await bus.subscribe()
            defer { Task { await bus.unsubscribe(id: subscriberID) } }

            if let since = filters.since {
                let backlog = await eventRing.events(since: since)
                for event in backlog where filters.matches(event) {
                    await Self.writeSSEEvent(event, to: channel, logger: logger)
                }
            }

            for await item in stream {
                switch item {
                case .event(let event):
                    guard filters.matches(event) else { continue }
                    await Self.writeSSEEvent(event, to: channel, logger: logger)
                case .dropped(let count):
                    await Self.writeSSEDropped(count: count, to: channel, logger: logger)
                    _ = try? await channel.close()
                    return
                }
            }
        }
    }

    private func writeStatus(_ status: HTTPResponseStatus, to context: ChannelHandlerContext) {
        let head = HTTPResponseHead(
            version: requestHead?.version ?? .http1_1,
            status: status,
            headers: HTTPHeaders([("Content-Length", "0")])
        )
        let channel = context.channel
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    private static func writeSSEEvent(
        _ event: Event,
        to channel: Channel,
        logger: Logger
    ) async {
        let payload: Data
        do {
            payload = try JSONRPCCoder.makeEncoder().encode(event)
        } catch {
            logger.error("SSE encode event failed", metadata: ["error": "\(error)"])
            return
        }
        let body =
            "event: \(event.kind.rawValue)\n"
            + "id: \(event.id.uuidString)\n"
            + "data: \(String(data: payload, encoding: .utf8) ?? "{}")\n\n"
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        _ = try? await channel.writeAndFlush(
            HTTPServerResponsePart.body(.byteBuffer(buffer))
        )
    }

    private static func writeSSEDropped(
        count: UInt64,
        to channel: Channel,
        logger: Logger
    ) async {
        let body = "event: dropped\ndata: {\"count\":\(count)}\n\n"
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        _ = try? await channel.writeAndFlush(
            HTTPServerResponsePart.body(.byteBuffer(buffer))
        )
        // Cleanly terminate the chunked response so the client sees EOF.
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
    }
}

// MARK: - Filter parsing

struct SSEFilters {
    var since: Date?
    var kinds: Set<Event.Kind>?
    var host: String?

    static func parse(uri: String) -> SSEFilters {
        var result = SSEFilters()
        guard let queryStart = uri.firstIndex(of: "?") else { return result }
        let query = uri[uri.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            switch key {
            case "since":
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: value) {
                    result.since = date
                }
            case "kind":
                let raw = value.split(separator: ",").map(String.init)
                let parsed = raw.compactMap(Event.Kind.init(rawValue:))
                result.kinds = Set(parsed)
            case "host":
                result.host = value
            default:
                break
            }
        }
        return result
    }

    func matches(_ event: Event) -> Bool {
        if let kinds = kinds, !kinds.contains(event.kind) { return false }
        if let host = host, event.host != host { return false }
        return true
    }
}
