import Foundation
import NIO
import NIOHTTP1
import NIOSSL

/// First handler in the per-connection pipeline. Accepts a single
/// `CONNECT host:port` request and either upgrades to MITM (whitelisted) or
/// splices a raw TCP tunnel to the upstream (non-whitelisted; SPECS §8.3).
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case awaitingHead
        case awaitingEnd(host: String, port: Int)
        case upgrading
    }

    private let server: ProxyServer
    private let plainDecoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let plainEncoder: HTTPResponseEncoder
    private var state: State = .awaitingHead

    init(
        server: ProxyServer,
        plainDecoder: ByteToMessageHandler<HTTPRequestDecoder>,
        plainEncoder: HTTPResponseEncoder
    ) {
        self.server = server
        self.plainDecoder = plainDecoder
        self.plainEncoder = plainEncoder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .upgrading:
            return
        case .awaitingHead, .awaitingEnd:
            break
        }

        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard head.method == .CONNECT else {
                server.logger.warning("Proxy received non-CONNECT", metadata: ["method": "\(head.method)"])
                respondAndClose(context: context, status: .methodNotAllowed)
                return
            }
            guard let (host, port) = Self.parseAuthority(head.uri) else {
                respondAndClose(context: context, status: .badRequest)
                return
            }
            state = .awaitingEnd(host: host, port: port)
        case .body:
            break
        case .end:
            guard case .awaitingEnd(let host, let port) = state else {
                respondAndClose(context: context, status: .badRequest)
                return
            }
            state = .upgrading
            performUpgrade(context: context, host: host, port: port)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.logger.warning("Proxy connection error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }

    // MARK: - Upgrade

    private func performUpgrade(context: ChannelHandlerContext, host: String, port: Int) {
        guard server.configuration.allowedHosts.contains(host) else {
            // SPECS §8.3: non-whitelisted hosts are CONNECT-tunneled
            // byte-for-byte. The proxy never decrypts the bytes, so any
            // placeholders inside the tunneled TLS are sent encrypted to
            // upstream unchanged.
            performPassthrough(context: context, host: host, port: port)
            return
        }

        let server = self.server
        let channel = context.channel
        let eventLoop = context.eventLoop
        let selfRef = self
        let plainDecoder = self.plainDecoder
        let plainEncoder = self.plainEncoder

        // 1. Pause autoRead so any TLS bytes the client sends after our 200
        //    accumulate at the socket instead of being parsed by the (still
        //    in-place) HTTP request decoder.
        channel.setOption(ChannelOptions.autoRead, value: false).flatMap { _ -> EventLoopFuture<Void> in
            // 2. Send 200 Connection Established via the still-installed
            //    HTTPResponseEncoder. Explicit Content-Length: 0 prevents the
            //    encoder from adding Transfer-Encoding: chunked, which would
            //    be malformed for a CONNECT response.
            var responseHeaders = HTTPHeaders()
            responseHeaders.add(name: "Content-Length", value: "0")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: responseHeaders)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            let flushPromise = eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: flushPromise)
            return flushPromise.futureResult
        }.flatMap { _ -> EventLoopFuture<LeafCertCache.Leaf> in
            return eventLoop.makeFutureWithTask {
                try await server.leafCertCache.leaf(forHost: host)
            }
        }.flatMap { leaf -> EventLoopFuture<Void> in
            do {
                let sslHandler = try Self.makeServerTLSHandler(leaf: leaf)
                return Self.installMITMPipeline(
                    on: channel,
                    sslHandler: sslHandler,
                    plainDecoder: plainDecoder,
                    plainEncoder: plainEncoder,
                    connectHandler: selfRef,
                    server: server,
                    host: host
                )
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap { _ -> EventLoopFuture<Void> in
            // 3. Resume autoRead so the queued TLS handshake bytes flow
            //    through the new TLS handler.
            channel.setOption(ChannelOptions.autoRead, value: true)
        }.whenComplete { result in
            switch result {
            case .success:
                channel.read()
            case .failure(let error):
                server.logger.error(
                    "MITM upgrade failed",
                    metadata: ["host": "\(host)", "error": "\(error)"]
                )
                channel.close(promise: nil)
            }
        }
    }

    // MARK: - Passthrough

    private func performPassthrough(context: ChannelHandlerContext, host: String, port: Int) {
        let server = self.server
        let clientChannel = context.channel
        let eventLoop = context.eventLoop
        let selfRef = self
        let plainDecoder = self.plainDecoder
        let plainEncoder = self.plainEncoder
        let startTime = Date()

        eventLoop.makeFutureWithTask { () async throws -> Void in
            // 1. Pause client autoRead until the glue pipeline is wired so
            //    any bytes sent right after our 200 do not hit the still-
            //    installed HTTP request decoder.
            try await clientChannel.setOption(ChannelOptions.autoRead, value: false).get()

            // 2. Open a TCP connection to the CONNECT target. The CONNECT URI
            //    port is honored verbatim; `configuration.upstreamPort` is
            //    MITM-only (the daemon forwards plaintext over its own TLS).
            let upstreamChannel: Channel
            do {
                upstreamChannel = try await ClientBootstrap(group: eventLoop)
                    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .connect(host: host, port: port).get()
            } catch {
                // Cannot reach upstream — surface a 502 to the client before
                // closing, matching standard forward-proxy semantics.
                selfRef.respondAndClose(context: context, status: .badGateway)
                throw error
            }

            // 3. Send 200 Connection Established to the client through the
            //    still-installed HTTPResponseEncoder.
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            clientChannel.write(selfRef.wrapOutboundOut(.head(head)), promise: nil)
            try await clientChannel.writeAndFlush(selfRef.wrapOutboundOut(.end(nil))).get()

            // 4. Atomic pipeline swap on the EL: drop the HTTP codec and this
            //    handler from the client side, install matched GlueHandlers
            //    on both channels.
            let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
            try await eventLoop.submit {
                let sync = clientChannel.pipeline.syncOperations
                try sync.removeHandler(plainDecoder)
                try sync.removeHandler(plainEncoder)
                try sync.removeHandler(selfRef)
                try sync.addHandler(clientGlue)
            }.get()
            try await upstreamChannel.pipeline.addHandler(upstreamGlue).get()

            // 5. Resume client reads. Both ends of the tunnel are now wired.
            try await clientChannel.setOption(ChannelOptions.autoRead, value: true).get()
        }.whenComplete { result in
            let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
            switch result {
            case .success:
                clientChannel.read()
                let event = Event(
                    timestamp: startTime,
                    kind: .passThrough,
                    host: host,
                    method: "CONNECT",
                    path: "\(host):\(port)",
                    durationMs: duration
                )
                Task { await server.eventRing.append(event) }
                server.logger.info(
                    "Passthrough tunnel established",
                    metadata: ["host": "\(host)", "port": "\(port)"]
                )
            case .failure(let error):
                server.logger.warning(
                    "Passthrough setup failed",
                    metadata: ["host": "\(host)", "port": "\(port)", "error": "\(error)"]
                )
                clientChannel.close(promise: nil)
            }
        }
    }

    // MARK: - MITM

    private static func makeServerTLSHandler(leaf: LeafCertCache.Leaf) throws -> NIOSSLServerHandler {
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leaf.nioCertificate)],
            privateKey: .privateKey(leaf.nioPrivateKey)
        )
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        return NIOSSLServerHandler(context: context)
    }

    private static func installMITMPipeline(
        on channel: Channel,
        sslHandler: NIOSSLServerHandler,
        plainDecoder: ByteToMessageHandler<HTTPRequestDecoder>,
        plainEncoder: HTTPResponseEncoder,
        connectHandler: ConnectHandler,
        server: ProxyServer,
        host: String
    ) -> EventLoopFuture<Void> {
        // Perform the swap atomically on the event loop using syncOperations.
        // The async chain of removeHandler/addHandler had cases where the
        // ChannelHandlerContext for the original handlers could no longer be
        // located, producing notFound.
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            do {
                let sync = channel.pipeline.syncOperations
                try sync.removeHandler(plainDecoder)
                try sync.removeHandler(plainEncoder)
                try sync.removeHandler(connectHandler)
                try sync.addHandler(sslHandler, position: .first)
                // Add HTTP server handlers explicitly (no HTTPServerPipelineHandler
                // — its pipelining guards interact badly with our MITM model
                // where the request is consumed by MITMHandler and the response
                // comes back asynchronously from a separate upstream channel).
                try sync.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
                try sync.addHandler(HTTPResponseEncoder())
                try sync.addHandler(MITMHandler(server: server, host: host))
                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    private func respondAndClose(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(version: .http1_1, status: status)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let p = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: p)
        p.futureResult.whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private static func parseAuthority(_ uri: String) -> (String, Int)? {
        let parts = uri.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty,
            let port = Int(parts[1]),
            (1...65535).contains(port)
        else { return nil }
        return (String(parts[0]), port)
    }
}
