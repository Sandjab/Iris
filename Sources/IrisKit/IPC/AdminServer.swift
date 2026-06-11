import Darwin
import Foundation
import Logging
import NIO
import NIOCore
import NIOPosix

// MARK: - Errors

public enum AdminServerError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case bindFailed(path: String, message: String)
    case unsafeExistingFile(path: String, ownerUID: uid_t, currentUID: uid_t)
    case permissionsFailed(syscall: String, errno: Int32)
    case ownerMismatch(expected: uid_t, got: uid_t)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "AdminServer already started"
        case .bindFailed(let path, let message):
            return "Failed to bind admin socket at \(path): \(message)"
        case .unsafeExistingFile(let path, let owner, let current):
            return
                "Refusing to bind admin socket: existing file at \(path) is owned by uid \(owner), not current uid \(current)"
        case .permissionsFailed(let syscall, let err):
            return "Admin socket \(syscall) failed: errno=\(err)"
        case .ownerMismatch(let expected, let got):
            return "Admin socket owner uid \(got) does not match current uid \(expected)"
        }
    }
}

// MARK: - AdminServer

/// Local Unix-domain JSON-RPC 2.0 listener (SPECS §13). Owns no socket file
/// outside its own lifetime: `start()` enforces a 0600 + owning-uid invariant
/// before bind, `stop()` removes the socket file on the way out.
///
/// `@unchecked Sendable` follows the `ProxyServer` pattern (Phase 2): the only
/// mutable state (`serverChannel`) is touched only from `start()` / `stop()`
/// which are not called concurrently in practice. NIO `Channel` is `Sendable`.
public final class AdminServer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse

    public let socketPath: String
    public let logger: Logger

    private let handler: RequestHandler
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var serverChannel: Channel?

    public init(
        socketPath: String,
        handler: @escaping RequestHandler,
        group: EventLoopGroup? = nil,
        logger: Logger = Logger(label: "io.iris.admin")
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.logger = logger
        if let group = group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    /// Returns the bound `SocketAddress` (Unix domain). Idempotent on repeated
    /// calls only in the sense that a second call throws `.alreadyStarted` —
    /// callers should pair `start()` with exactly one `stop()`.
    @discardableResult
    public func start() async throws -> SocketAddress {
        guard serverChannel == nil else { throw AdminServerError.alreadyStarted }

        try Self.preflightExistingFile(at: socketPath)
        // Tighten the inode mode mask before NIO creates the socket file.
        // chmod after the fact is also performed below to cover the corner
        // case where some umask layer overrides this (e.g. tests running
        // under a sandbox).
        let originalUmask = umask(0o177)
        defer { _ = umask(originalUmask) }

        let handler = self.handler
        let connectionLogger = logger
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture(
                    withResultOf: {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(JSONRPCFrameDecoder()))
                        try sync.addHandler(MessageToByteHandler(JSONRPCFrameEncoder()))
                        try sync.addHandler(
                            AdminConnectionHandler(handler: handler, logger: connectionLogger)
                        )
                    }
                )
            }

        let channel: Channel
        do {
            // We don't pass `cleanupExistingSocketFile: true` because the
            // preflight above has already unlinked any self-owned residue,
            // and we want NIO to fail loudly if a different file appeared
            // between preflight and bind.
            channel =
                try await bootstrap
                .bind(unixDomainSocketPath: socketPath)
                .get()
        } catch {
            throw AdminServerError.bindFailed(path: socketPath, message: "\(error)")
        }
        self.serverChannel = channel

        try Self.enforcePermissions(socketPath: socketPath)

        guard let address = channel.localAddress else {
            // Should never happen for a bound UDS channel, but the API is
            // optional so treat it as a soft bind failure.
            throw AdminServerError.bindFailed(path: socketPath, message: "no local address")
        }
        logger.info(
            "AdminServer listening",
            metadata: ["path": "\(socketPath)"]
        )
        return address
    }

    public func stop() async throws {
        if let channel = serverChannel {
            try await channel.close().get()
            serverChannel = nil
        }
        // Best-effort cleanup. If unlink fails (file already gone, permission
        // race), don't fail stop() — the only invariant we owe upstream is
        // "channel closed, group shut down".
        try? FileManager.default.removeItem(atPath: socketPath)
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }

    // MARK: - Permission gates

    /// If a file already exists at `socketPath`, ensure it belongs to the
    /// current user before we unlink it. `lstat` (not `stat`) blocks the
    /// symlink-swap attack where another local user plants a symlink
    /// pointing at a sensitive path. Once ownership is confirmed we unlink
    /// the residue ourselves so the upcoming `bind()` can be strict about
    /// any unexpected file appearing between the two calls.
    private static func preflightExistingFile(at path: String) throws {
        var sb = stat()
        let probe = path.withCString { lstat($0, &sb) }
        if probe != 0 {
            if errno == ENOENT { return }
            throw AdminServerError.permissionsFailed(syscall: "lstat", errno: errno)
        }
        let currentUID = getuid()
        if sb.st_uid != currentUID {
            throw AdminServerError.unsafeExistingFile(
                path: path,
                ownerUID: sb.st_uid,
                currentUID: currentUID
            )
        }
        let unlinkResult = path.withCString { unlink($0) }
        if unlinkResult != 0 && errno != ENOENT {
            throw AdminServerError.permissionsFailed(syscall: "unlink", errno: errno)
        }
    }

    private static func enforcePermissions(socketPath: String) throws {
        let chmodResult = socketPath.withCString { chmod($0, 0o600) }
        if chmodResult != 0 {
            throw AdminServerError.permissionsFailed(syscall: "chmod", errno: errno)
        }
        var sb = stat()
        let statResult = socketPath.withCString { stat($0, &sb) }
        if statResult != 0 {
            throw AdminServerError.permissionsFailed(syscall: "stat", errno: errno)
        }
        let currentUID = getuid()
        if sb.st_uid != currentUID {
            throw AdminServerError.ownerMismatch(expected: currentUID, got: sb.st_uid)
        }
    }
}

// MARK: - Per-connection handler

/// NIO inbound handler that consumes a single framed JSON-RPC payload,
/// hands it to the user-provided async handler, and writes the response back.
/// Multiple requests on the same connection are supported (admin protocol is
/// stateless), but the client we ship in Phase 3 closes after one round-trip.
final class AdminConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let handler: AdminServer.RequestHandler
    private let logger: Logger

    init(handler: @escaping AdminServer.RequestHandler, logger: Logger) {
        self.handler = handler
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let payload = Data(bytes)
        let channel = context.channel
        let eventLoop = context.eventLoop
        let handler = self.handler
        let logger = self.logger

        // Bridge async dispatcher work back to the EL via NIO's task helper
        // so the region-based isolation checker can see the data flow.
        eventLoop.makeFutureWithTask { () async -> Data? in
            let response = await Self.process(payload: payload, handler: handler, logger: logger)
            do {
                return try JSONRPCCoder.makeEncoder().encode(response)
            } catch {
                logger.error("AdminServer encode response failed", metadata: ["error": "\(error)"])
                return nil
            }
        }
        .whenComplete { result in
            switch result {
            case .success(.some(let encoded)):
                var out = channel.allocator.buffer(capacity: encoded.count)
                out.writeBytes(encoded)
                channel.writeAndFlush(out, promise: nil)
            case .success(.none), .failure:
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Framing errors surface here (e.g. oversized frame). Reply with a
        // standard parse-error response on a best-effort basis, then close.
        let channel = context.channel
        let resp = JSONRPCResponse.failure(
            id: .null,
            error: .parseError(message: "\(error)")
        )
        if let data = try? JSONRPCCoder.makeEncoder().encode(resp) {
            var out = channel.allocator.buffer(capacity: data.count)
            out.writeBytes(data)
            channel.writeAndFlush(out, promise: nil)
        }
        context.close(promise: nil)
        logger.warning("AdminServer connection error", metadata: ["error": "\(error)"])
    }

    private static func process(
        payload: Data,
        handler: AdminServer.RequestHandler,
        logger: Logger
    ) async -> JSONRPCResponse {
        let request: JSONRPCRequest
        do {
            request = try JSONRPCCoder.makeDecoder().decode(JSONRPCRequest.self, from: payload)
        } catch {
            return JSONRPCResponse.failure(
                id: .null,
                error: .parseError(message: "Malformed JSON-RPC request: \(error)")
            )
        }
        return await handler(request)
    }
}
