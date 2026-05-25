import Foundation
import Logging
import NIO
import NIOCore
import NIOPosix

// MARK: - Errors

public enum AdminClientError: Error, Equatable, LocalizedError {
    case connectionClosedBeforeResponse
    case connectFailed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .connectionClosedBeforeResponse:
            return "Admin socket closed before sending a JSON-RPC response"
        case .connectFailed(let path, let message):
            return "Failed to connect to admin socket at \(path): \(message)"
        }
    }
}

// MARK: - AdminClient

/// One-shot JSON-RPC 2.0 client over a Unix-domain socket (SPECS §13).
/// Each call opens a fresh connection, writes one framed request, reads one
/// framed response, and closes — keeping the implementation symmetric with
/// the `AdminServer` per-connection handler and avoiding any in-flight ID
/// bookkeeping. For the menu-bar app (Phase 6) we may revisit and add a
/// persistent connection.
public actor AdminClient {
    public let socketPath: String
    public let logger: Logger

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var nextID: Int64 = 1

    public init(
        socketPath: String,
        group: EventLoopGroup? = nil,
        logger: Logger = Logger(label: "io.iris.admin.client")
    ) {
        self.socketPath = socketPath
        self.logger = logger
        if let group = group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    /// Caller-owned lifecycle: invoke `await shutdown()` before dropping the
    /// client when no `group` was supplied at init. We deliberately do **not**
    /// shut down from `deinit` — `EventLoopGroup.syncShutdownGracefully()` is
    /// a blocking call and running it from ARC-driven teardown can deadlock
    /// the calling thread (NIO documents this as an anti-pattern). If a
    /// shared `group` was passed in, the caller already owns its lifetime.
    public func shutdown() async throws {
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }

    // MARK: - Public API

    /// Untyped call: caller supplies a pre-built `JSONValue` for params and
    /// receives the raw `result` tree.
    public func call(_ method: AdminMethod, params: JSONValue? = nil) async throws -> JSONValue {
        let id = nextRequestID()
        let request = JSONRPCRequest(method: method.rawValue, params: params, id: id)
        let response = try await sendOne(request)
        if let error = response.error {
            throw error
        }
        return response.result ?? .null
    }

    /// Typed convenience: encode `params` and decode the result into `R`.
    public func call<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: AdminMethod,
        params: P,
        returning: R.Type
    ) async throws -> R {
        let value = try JSONValue.encoding(params)
        let result = try await call(method, params: value)
        return try result.decode(as: R.self)
    }

    /// Typed convenience for methods with no params.
    public func call<R: Decodable & Sendable>(
        _ method: AdminMethod,
        returning: R.Type
    ) async throws -> R {
        let result = try await call(method, params: nil)
        return try result.decode(as: R.self)
    }

    // MARK: - Internals

    private func nextRequestID() -> JSONRPCID {
        let id = nextID
        nextID &+= 1
        return .integer(id)
    }

    private func sendOne(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        let payload = try JSONRPCCoder.makeEncoder().encode(request)
        let loop = group.next()
        let promise = loop.makePromise(of: JSONRPCResponse.self)

        let bootstrap = ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture(
                    withResultOf: {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(JSONRPCFrameDecoder()))
                        try sync.addHandler(MessageToByteHandler(JSONRPCFrameEncoder()))
                        try sync.addHandler(AdminClientHandler(promise: promise))
                    }
                )
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
        } catch {
            // Drain the promise so the caller never sees a dangling future.
            promise.fail(error)
            throw AdminClientError.connectFailed(path: socketPath, message: "\(error)")
        }

        var buf = channel.allocator.buffer(capacity: payload.count)
        buf.writeBytes(payload)
        do {
            try await channel.writeAndFlush(buf).get()
        } catch {
            promise.fail(error)
            _ = try? await channel.close().get()
            throw error
        }

        let response = try await promise.futureResult.get()
        _ = try? await channel.close().get()
        return response
    }
}

// MARK: - Per-connection inbound handler

final class AdminClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<JSONRPCResponse>
    private var completed = false

    init(promise: EventLoopPromise<JSONRPCResponse>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        completed = true
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        do {
            let response = try JSONRPCCoder.makeDecoder().decode(
                JSONRPCResponse.self,
                from: Data(bytes)
            )
            promise.succeed(response)
        } catch {
            promise.fail(error)
        }
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        promise.fail(AdminClientError.connectionClosedBeforeResponse)
    }
}
