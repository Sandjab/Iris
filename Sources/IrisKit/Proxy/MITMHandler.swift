import Foundation
import Logging
import NIO
import NIOHTTP1

/// Buffers a single decrypted HTTPS request, runs `PlaceholderEngine` over
/// headers + body, forwards the modified request to upstream via
/// `UpstreamClient`, and streams the response back to the client.
///
/// Phase 2 limitations:
/// - Request body buffered entirely (no size cap, no streaming)
/// - Response is collected then re-emitted (acceptable for non-streaming
///   responses; SSE handling streams in Phase 2.x)
/// - One request per connection (close after response)
final class MITMHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case head(HTTPRequestHead)
        case body(HTTPRequestHead, ByteBuffer)
        case forwarding
    }

    private let server: ProxyServer
    private let host: String
    private var state: State = .idle

    init(server: ProxyServer, host: String) {
        self.server = server
        self.host = host
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state = .head(head)
        case .body(var incoming):
            switch state {
            case .head(let head):
                state = .body(head, incoming)
            case .body(let head, var existing):
                existing.writeBuffer(&incoming)
                state = .body(head, existing)
            case .idle, .forwarding:
                break
            }
        case .end:
            let head: HTTPRequestHead
            let body: ByteBuffer?
            switch state {
            case .head(let h):
                head = h
                body = nil
            case .body(let h, let b):
                head = h
                body = b
            case .idle, .forwarding:
                return
            }
            state = .forwarding
            forwardRequest(context: context, head: head, body: body)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.logger.warning(
            "MITM channel error",
            metadata: ["host": "\(host)", "error": "\(error)"]
        )
        context.close(promise: nil)
    }

    private func forwardRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        let server = self.server
        let host = self.host
        let channel = context.channel
        let eventLoop = context.eventLoop
        let startTime = Date()

        eventLoop.makeFutureWithTask { () async throws -> (ResolvedRequest, UpstreamResponse) in
            let resolved = try await Self.applySubstitution(
                head: head,
                body: body,
                engine: server.placeholderEngine,
                logger: server.logger,
                host: host
            )
            if !resolved.substituted.isEmpty {
                server.logger.info(
                    "Substituted secrets",
                    metadata: [
                        "host": "\(host)",
                        "secrets": "\(resolved.substituted)",
                        "path": "\(head.uri)",
                    ]
                )
            }
            let upstream = try await server.upstreamClient.send(
                head: resolved.head,
                body: resolved.body,
                host: host,
                port: server.configuration.upstreamPort
            )
            return (resolved, upstream)
        }.flatMap { (resolved, upstream) -> EventLoopFuture<Void> in
            let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
            let event = Event(
                timestamp: startTime,
                kind: resolved.substituted.isEmpty ? .noMatch : .substituted,
                host: host,
                method: head.method.rawValue,
                path: head.uri,
                statusCode: Int(upstream.head.status.code),
                durationMs: duration,
                substitutedSecrets: resolved.substituted
            )
            let ring = server.eventRing
            Task { await ring.append(event) }
            return Self.writeResponse(upstream, to: channel)
        }.whenComplete { result in
            if case .failure(let error) = result {
                let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
                let event = Event(
                    timestamp: startTime,
                    kind: .error,
                    host: host,
                    method: head.method.rawValue,
                    path: head.uri,
                    durationMs: duration
                )
                let ring = server.eventRing
                Task { await ring.append(event) }
                server.logger.warning(
                    "Upstream forwarding failed",
                    metadata: ["host": "\(host)", "error": "\(error)"]
                )
            }
            channel.close(promise: nil)
        }
    }

    // SPECS §7.2: bodies larger than this are passed through without scanning.
    private static let bodyMaxBytes = 4 * 1024 * 1024

    private struct ResolvedRequest {
        let head: HTTPRequestHead
        let body: ByteBuffer?
        let substituted: [String]
    }

    private static func applySubstitution(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        engine: PlaceholderEngine,
        logger: Logger,
        host: String
    ) async throws -> ResolvedRequest {
        var allSubstituted = Set<String>()

        // Headers — strip Accept-Encoding (SPECS §7.5: prevents compressed upstream responses)
        var newHeaders = HTTPHeaders()
        for (name, value) in head.headers {
            if name.lowercased() == "accept-encoding" { continue }
            let nameOutcome = try await engine.substituteString(name)
            let valueOutcome = try await engine.substituteString(value)
            allSubstituted.formUnion(nameOutcome.substituted)
            allSubstituted.formUnion(valueOutcome.substituted)
            let newName = String(data: nameOutcome.output, encoding: .utf8) ?? name
            let newValue = String(data: valueOutcome.output, encoding: .utf8) ?? value
            newHeaders.add(name: newName, value: newValue)
        }

        // URI (path + query)
        let uriOutcome = try await engine.substituteString(head.uri)
        allSubstituted.formUnion(uriOutcome.substituted)
        let newURI = String(data: uriOutcome.output, encoding: .utf8) ?? head.uri

        // Body — skip scan if too large (SPECS §7.2: Content-Length > 4 MiB)
        var newBody = body
        if let originalBody = body {
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init)
            let declaredSize = contentLength ?? originalBody.readableBytes
            if declaredSize > bodyMaxBytes {
                logger.warning(
                    "Body too large, skipping substitution scan",
                    metadata: ["host": "\(host)", "size": "\(declaredSize)"]
                )
            } else {
                let originalData = Data(originalBody.readableBytesView)
                let bodyOutcome = try await engine.substitute(originalData)
                if bodyOutcome.nonUtf8 {
                    logger.debug(
                        "Body is non-UTF-8, skipping substitution scan",
                        metadata: ["host": "\(host)"]
                    )
                } else if !bodyOutcome.substituted.isEmpty {
                    allSubstituted.formUnion(bodyOutcome.substituted)
                    var buffer = ByteBufferAllocator().buffer(capacity: bodyOutcome.output.count)
                    buffer.writeBytes(bodyOutcome.output)
                    newBody = buffer
                    // Keep Content-Length accurate after substitution.
                    if newHeaders.contains(name: "content-length") {
                        newHeaders.replaceOrAdd(name: "content-length", value: "\(bodyOutcome.output.count)")
                    }
                }
            }
        }

        var newHead = HTTPRequestHead(
            version: head.version,
            method: head.method,
            uri: newURI,
            headers: newHeaders
        )
        // Force HTTP/1.1 upstream (Phase 2 sidesteps HTTP/2, SPECS §11.5)
        newHead.version = .http1_1
        return ResolvedRequest(
            head: newHead,
            body: newBody,
            substituted: Array(allSubstituted)
        )
    }

    private static func writeResponse(
        _ response: UpstreamResponse,
        to channel: Channel
    ) -> EventLoopFuture<Void> {
        let headPart = HTTPServerResponsePart.head(
            HTTPResponseHead(
                version: response.head.version,
                status: response.head.status,
                headers: response.head.headers
            )
        )
        // Fire-and-forget intermediate writes; only await the final flush.
        // Chaining flatMap over `channel.write` futures deadlocks because
        // those futures only complete after a subsequent flush, and we are
        // gating the flush on them.
        channel.write(headPart, promise: nil)
        if let body = response.body, body.readableBytes > 0 {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        }
        return channel.writeAndFlush(HTTPServerResponsePart.end(nil))
    }
}
