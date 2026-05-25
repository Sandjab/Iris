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
        // EL-confined captures: NIO handler types are explicitly non-Sendable,
        // so wrap in NIOLoopBound for the @Sendable flatMap closures below.
        // Unwrapping (.value) only happens on the channel's EventLoop.
        let boundDecoder = NIOLoopBound(self.plainDecoder, eventLoop: eventLoop)
        let boundEncoder = NIOLoopBound(self.plainEncoder, eventLoop: eventLoop)

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
            let headPart: HTTPServerResponsePart = .head(head)
            channel.write(headPart, promise: nil)
            let flushPromise = eventLoop.makePromise(of: Void.self)
            let endPart: HTTPServerResponsePart = .end(nil)
            channel.writeAndFlush(endPart, promise: flushPromise)
            return flushPromise.futureResult
        }.flatMap { _ -> EventLoopFuture<LeafCertCache.Leaf> in
            return eventLoop.makeFutureWithTask {
                try await server.leafCertCache.leaf(forHost: host)
            }
        }.flatMap { leaf -> EventLoopFuture<Void> in
            do {
                let sslHandler = try Self.makeServerTLSHandler(leaf: leaf)
                let boundSSL = NIOLoopBound(sslHandler, eventLoop: eventLoop)
                return Self.installMITMPipeline(
                    on: channel,
                    sslHandler: boundSSL,
                    plainDecoder: boundDecoder,
                    plainEncoder: boundEncoder,
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
        // EL-confined captures (non-Sendable NIO handler types).
        let boundDecoder = NIOLoopBound(self.plainDecoder, eventLoop: eventLoop)
        let boundEncoder = NIOLoopBound(self.plainEncoder, eventLoop: eventLoop)
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
                //
                // Must write via `clientChannel`, NOT `context`: this closure
                // runs inside a `makeFutureWithTask` Task which is not bound
                // to the channel's EventLoop. `ChannelHandlerContext` methods
                // assert `inEventLoop` and would trap. `Channel.write` is
                // thread-safe (schedules onto the EL internally).
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                let errHead = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
                clientChannel.write(HTTPServerResponsePart.head(errHead), promise: nil)
                let p = eventLoop.makePromise(of: Void.self)
                clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: p)
                p.futureResult.whenComplete { _ in clientChannel.close(promise: nil) }
                throw error
            }

            // 3. Send 200 Connection Established to the client through the
            //    still-installed HTTPResponseEncoder.
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
            try await clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()

            // 4. Atomic pipeline swap on the EL.
            //
            // Order matters: `HTTPRequestDecoder(leftOverBytesStrategy:
            // .forwardBytes)` flushes any TLS ClientHello bytes that arrived
            // in the same TCP segment as the CONNECT request *synchronously*
            // from `handlerRemoved`. Those bytes must land on `clientGlue`,
            // not on this still-installed `ConnectHandler` (which would drop
            // them in its `.upgrading` state). So:
            //   1. install `upstreamGlue` first — partner ready to receive.
            //   2. remove `selfRef` so it does not eat the flushed bytes.
            //   3. install `clientGlue` at the tail.
            //   4. remove `plainDecoder` — leftover bytes now flow through
            //      `plainEncoder` (outbound only, forwards inbound) and
            //      reach `clientGlue`.
            //   5. remove `plainEncoder`.
            let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
            try await upstreamChannel.pipeline.addHandler(upstreamGlue).get()
            try await eventLoop.submit {
                let sync = clientChannel.pipeline.syncOperations
                _ = sync.removeHandler(selfRef)
                try sync.addHandler(clientGlue)
                _ = sync.removeHandler(boundDecoder.value)
                _ = sync.removeHandler(boundEncoder.value)
            }.get()

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
                let ring = server.eventRing
                Task { await ring.append(event) }
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
        sslHandler: NIOLoopBound<NIOSSLServerHandler>,
        plainDecoder: NIOLoopBound<ByteToMessageHandler<HTTPRequestDecoder>>,
        plainEncoder: NIOLoopBound<HTTPResponseEncoder>,
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
                _ = sync.removeHandler(plainDecoder.value)
                _ = sync.removeHandler(plainEncoder.value)
                _ = sync.removeHandler(connectHandler)
                try sync.addHandler(sslHandler.value, position: .first)
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
        // Route via Channel rather than ChannelHandlerContext: Channel.write
        // resolves to the typed (Sendable) overload cleanly, while
        // ChannelHandlerContext.write resolves to the deprecated NIOAny
        // overload despite the Sendable variant existing. Behavior is
        // identical here — the ConnectHandler is the only outbound consumer
        // before HTTPResponseEncoder.
        let channel = context.channel
        let head = HTTPResponseHead(version: .http1_1, status: status)
        let headPart: HTTPServerResponsePart = .head(head)
        channel.write(headPart, promise: nil)
        let p = context.eventLoop.makePromise(of: Void.self)
        let endPart: HTTPServerResponsePart = .end(nil)
        channel.writeAndFlush(endPart, promise: p)
        p.futureResult.whenComplete { _ in
            channel.close(promise: nil)
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
