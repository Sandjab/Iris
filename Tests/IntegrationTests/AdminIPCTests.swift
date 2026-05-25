import Darwin
import Foundation
import IrisKit
import Logging
import NIO
import NIOPosix
import XCTest

final class AdminIPCTests: XCTestCase {

    private func tmpSocketPath() -> String {
        // UDS path on Darwin is capped at 104 bytes including NUL — keep it
        // anchored under /tmp rather than NSTemporaryDirectory() which can
        // already eat 50+ chars on macOS.
        "/tmp/iris-admin-\(UUID().uuidString.prefix(8)).sock"
    }

    // MARK: - Round trip

    func testEchoRequestRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let socketPath = tmpSocketPath()
        let server = AdminServer(
            socketPath: socketPath,
            handler: { request in
                JSONRPCResponse.success(
                    id: request.id,
                    result: .object([
                        "echoed_method": .string(request.method)
                    ])
                )
            },
            group: group
        )
        try await server.start()
        defer { Task { try? await server.stop() } }

        let client = AdminClient(socketPath: socketPath, group: group)

        let result = try await client.call(.daemonStatus)
        guard case .object(let dict) = result else {
            return XCTFail("expected object result, got \(result)")
        }
        XCTAssertEqual(dict["echoed_method"], .string("daemon.status"))

        try await server.stop()
    }

    // MARK: - Error mapping

    func testErrorResponseSurfacesAsThrownJSONRPCError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let socketPath = tmpSocketPath()
        let server = AdminServer(
            socketPath: socketPath,
            handler: { request in
                JSONRPCResponse.failure(id: request.id, error: .unknownSecret("ghost"))
            },
            group: group
        )
        try await server.start()
        defer { Task { try? await server.stop() } }

        let client = AdminClient(socketPath: socketPath, group: group)

        do {
            _ = try await client.call(.secretGet, params: nil)
            XCTFail("expected JSONRPCError")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32001)
            XCTAssertTrue(error.message.contains("ghost"))
        }

        try await server.stop()
    }

    // MARK: - Permissions invariant

    func testServerEnforces0600PermissionsOnBoundSocket() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let socketPath = tmpSocketPath()
        let server = AdminServer(
            socketPath: socketPath,
            handler: { JSONRPCResponse.success(id: $0.id, result: .null) },
            group: group
        )
        try await server.start()
        defer { Task { try? await server.stop() } }

        var sb = stat()
        let result = socketPath.withCString { stat($0, &sb) }
        XCTAssertEqual(result, 0)
        let mode = sb.st_mode & 0o777
        XCTAssertEqual(mode, 0o600, "expected 0600 perms, got \(String(mode, radix: 8))")
        XCTAssertEqual(sb.st_uid, getuid())

        try await server.stop()
    }

    func testServerUnlinksSelfOwnedResidueBeforeBind() async throws {
        // The preflight must accept a regular (non-socket) file owned by the
        // current user — typical leftover from a crashed daemon — and
        // unlink it so bind() can recreate the socket inode cleanly.
        // (Refusing a file owned by a different uid cannot be tested here
        // without root; covered by manual inspection of preflightExistingFile.)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let socketPath = tmpSocketPath()
        FileManager.default.createFile(atPath: socketPath, contents: Data("not-a-socket".utf8))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = AdminServer(
            socketPath: socketPath,
            handler: { JSONRPCResponse.success(id: $0.id, result: .null) },
            group: group
        )
        try await server.start()
        try await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - Parse error

    func testServerReturnsParseErrorOnMalformedJSON() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let socketPath = tmpSocketPath()
        let server = AdminServer(
            socketPath: socketPath,
            handler: { JSONRPCResponse.success(id: $0.id, result: .null) },
            group: group
        )
        try await server.start()
        defer { Task { try? await server.stop() } }

        // Hand-roll a length-prefixed garbage frame and read the response off
        // the wire to bypass the typed AdminClient (which never produces
        // malformed JSON).
        let response = try await sendRawFrame(
            socketPath: socketPath,
            payload: Data("not-json".utf8),
            group: group
        )
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, JSONRPCError.parseError.code)

        try await server.stop()
    }

    // MARK: - Helpers

    private func sendRawFrame(
        socketPath: String,
        payload: Data,
        group: EventLoopGroup
    ) async throws -> JSONRPCResponse {
        let loop = group.next()
        let promise = loop.makePromise(of: JSONRPCResponse.self)

        let bootstrap = ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture(
                    withResultOf: {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(JSONRPCFrameDecoder()))
                        try sync.addHandler(
                            RawAdminResponseCollector(promise: promise)
                        )
                    }
                )
            }

        let channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
        // Manually build the length-prefixed frame so we can stuff non-JSON
        // bytes through it.
        var buf = channel.allocator.buffer(capacity: 4 + payload.count)
        buf.writeInteger(UInt32(payload.count), endianness: .big)
        buf.writeBytes(payload)
        try await channel.writeAndFlush(buf).get()
        let response = try await promise.futureResult.get()
        _ = try? await channel.close().get()
        return response
    }
}

private final class RawAdminResponseCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<JSONRPCResponse>
    private var completed = false

    init(promise: EventLoopPromise<JSONRPCResponse>) { self.promise = promise }

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
