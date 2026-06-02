import Foundation
import Logging
import NIO
import NIOHTTP1

/// Buffers a single decrypted HTTPS request, runs `PlaceholderEngine` over
/// headers + body, forwards the modified request to upstream via
/// `UpstreamClient`, and streams the response back to the client.
///
/// Phase 2.x scope:
/// - Request body buffered entirely (size cap 4 MiB), scanned, substituted
/// - Response relayed part-by-part at the wire as it arrives from upstream,
///   never scanned or modified (SPECS §7.2/§7.3 — Phase 2.x streaming)
/// - One request per connection (close after the response ends)
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

    private struct ProcessedRequest {
        let head: HTTPRequestHead
        let body: ByteBuffer?
        let outcome: Outcome

        enum Outcome {
            case bypassed
            case substituted(names: [String])
            case noMatch(unresolved: [String], nonUtf8: Bool, bodyTooLarge: Bool)
            case blocked(alert: Alert)
        }
    }

    private func forwardRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        // Reserved diagnostic endpoint: bypass all proxy logic, emit no event.
        // Used by `iris doctor` check #6 to verify the proxy is alive.
        if head.uri == "/__iris_ping" && head.method == .GET {
            let responseHead = HTTPResponseHead(
                version: .init(major: 1, minor: 1),
                status: .ok,
                headers: HTTPHeaders([
                    ("Content-Type", "text/plain"),
                    ("Content-Length", "3"),
                    ("Cache-Control", "no-store"),
                ])
            )
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: 3)
            buf.writeString("ok\n")
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        let server = self.server
        let host = self.host
        let channel = context.channel
        let eventLoop = context.eventLoop
        let startTime = Date()
        // Snapshot the pause flag at request entry so a flip mid-request
        // doesn't desync the event kind we emit at the end.
        let bypass = server.isPaused
        // Capture the ORIGINAL URI/method before any substitution. Events and
        // logs must carry the original URI, never the post-substitution one:
        // a placeholder in path/query is rewritten with the raw secret value
        // and would otherwise leak into logs, the SSE stream, and (Phase 5)
        // SQLite — violating CLAUDE.md §6.1.
        let originalURI = head.uri
        let originalMethod = head.method.rawValue

        eventLoop.makeFutureWithTask { () async throws -> ProcessedRequest in
            let processed = try await Self.processRequest(
                head: head,
                body: body,
                evaluator: server.exfilRuleEngine,
                engine: server.placeholderEngine,
                logger: server.logger,
                host: host,
                bypass: bypass
            )
            switch processed.outcome {
            case .substituted(let names):
                server.logger.info(
                    "Substituted secrets",
                    metadata: [
                        "host": "\(host)",
                        "secrets": "\(names)",
                        "path": "\(originalURI)",
                    ]
                )
            case .blocked(let alert):
                server.logger.warning(
                    "Exfiltration attempt blocked",
                    metadata: [
                        "host": "\(host)",
                        "rule": "\(alert.rule.rawValue)",
                        "secret": "\(alert.secretName)",
                        "severity": "\(alert.severity.rawValue)",
                    ]
                )
                switch server.currentOnExfilAttempt {
                case .blockOnly:
                    break
                case .blockAndNotify:
                    server.logger.warning(
                        "exfil notify intent (UI deferred to Phase 6)",
                        metadata: ["host": "\(host)"]
                    )
                case .blockNotifyPause:
                    server.logger.warning(
                        "auto-pausing daemon after exfil attempt",
                        metadata: ["host": "\(host)"]
                    )
                    server.setPaused(true)
                }
            case .bypassed, .noMatch:
                break
            }
            return processed
        }.flatMap { processed -> EventLoopFuture<(ProcessedRequest, StreamOutcome)> in
            // Stream the response part-by-part to the client at the wire, no
            // buffering (SPECS §7.3 / §10.12). Resolves at `.end` with the
            // status captured at the head.
            server.upstreamClient.stream(
                head: processed.head,
                body: processed.body,
                host: host,
                port: server.configuration.upstreamPort,
                to: channel,
                on: eventLoop
            ).map { (processed, $0) }
        }.whenComplete { result in
            let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
            switch result {
            case .success(let (processed, outcome)):
                let event = Self.makeEvent(
                    startTime: startTime,
                    host: host,
                    originalURI: originalURI,
                    originalMethod: originalMethod,
                    statusCode: outcome.statusCode,
                    duration: duration,
                    outcome: processed.outcome
                )
                let ring = server.eventRing
                Task { await ring.append(event) }
            case .failure(let error):
                let event = Event(
                    timestamp: startTime,
                    kind: .error,
                    host: host,
                    method: originalMethod,
                    path: originalURI,
                    durationMs: duration
                )
                let ring = server.eventRing
                Task { await ring.append(event) }
                server.logger.warning(
                    "Upstream stream failed",
                    metadata: ["host": "\(host)", "error": "\(error)"]
                )
            }
            channel.close(promise: nil)
        }
    }

    // SPECS §7.2: bodies larger than this are passed through without scanning.
    private static let bodyMaxBytes = 4 * 1024 * 1024

    private static func processRequest(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        evaluator: ExfilRuleEngine,
        engine: PlaceholderEngine,
        logger: Logger,
        host: String,
        bypass: Bool
    ) async throws -> ProcessedRequest {
        if bypass {
            return makeBypassedRequest(head: head, body: body)
        }

        // Strip Accept-Encoding (SPECS §7.5).
        var preparedHeaders = HTTPHeaders()
        for (name, value) in head.headers where name.lowercased() != "accept-encoding" {
            preparedHeaders.add(name: name, value: value)
        }

        // Body size cap (SPECS §7.2).
        var bodyTooLarge = false
        if let original = body {
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init)
            let declaredSize = contentLength ?? original.readableBytes
            if declaredSize > bodyMaxBytes {
                bodyTooLarge = true
                logger.warning(
                    "Body too large, skipping substitution scan",
                    metadata: ["host": "\(host)", "size": "\(declaredSize)"]
                )
            }
        }

        var preparedHead = HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: head.uri,
            headers: preparedHeaders
        )
        preparedHead.version = .http1_1

        if bodyTooLarge {
            return ProcessedRequest(
                head: preparedHead,
                body: body,
                outcome: .noMatch(unresolved: [], nonUtf8: false, bodyTooLarge: true)
            )
        }

        // Decode body for scanning (non-UTF-8 short-circuit). Decoded once,
        // reused by the scanner to avoid a second UTF-8 pass.
        var bodyString: String? = nil
        var nonUtf8 = false
        if let original = body {
            let data = Data(original.readableBytesView)
            if let decoded = String(data: data, encoding: .utf8) {
                bodyString = decoded
            } else {
                nonUtf8 = true
            }
        }

        if nonUtf8 {
            logger.debug(
                "Body is non-UTF-8, skipping substitution scan",
                metadata: ["host": "\(host)"]
            )
            return ProcessedRequest(
                head: preparedHead,
                body: body,
                outcome: .noMatch(unresolved: [], nonUtf8: true, bodyTooLarge: false)
            )
        }

        // Pass 1 — scan.
        let headerPairs: [(name: String, value: String)] = preparedHeaders.map {
            (name: $0.name, value: $0.value)
        }
        let hits = PlaceholderScanner.scan(
            headers: headerPairs,
            uri: preparedHead.uri,
            body: bodyString
        )
        if hits.isEmpty {
            return ProcessedRequest(
                head: preparedHead,
                body: body,
                outcome: .noMatch(unresolved: [], nonUtf8: false, bodyTooLarge: false)
            )
        }

        // Build evaluator context.
        let (path, _) = splitURI(preparedHead.uri)
        let normalizedHost = host.lowercased()
        let contentType = preparedHeaders.first(name: "content-type")?.lowercased()
        let context = RequestContext(
            host: normalizedHost,
            method: preparedHead.method.rawValue,
            path: path,
            contentType: contentType
        )

        // Pass 2 — evaluate.
        let decision = try await evaluator.evaluate(hits: hits, context: context)
        switch decision {
        case .block(let alert, _):
            return ProcessedRequest(
                head: preparedHead,
                body: body,
                outcome: .blocked(alert: alert)
            )
        case .allow(let resolvable):
            if resolvable.isEmpty {
                return ProcessedRequest(
                    head: preparedHead,
                    body: body,
                    outcome: .noMatch(
                        unresolved: hits.map(\.name),
                        nonUtf8: false,
                        bodyTooLarge: false
                    )
                )
            }

            // Pass 3 — substitute. `substituteResolvable` still operates on
            // `Data` bodies; reconvert from the cached UTF-8 string here so
            // we do not have to keep two parallel body representations alive
            // for the common case (no substitution).
            let originalBodyData = bodyString.map { Data($0.utf8) }
            let payload = try await engine.substituteResolvable(
                headers: headerPairs,
                uri: preparedHead.uri,
                body: originalBodyData,
                resolvableHits: resolvable
            )

            if payload.substituted.isEmpty {
                return ProcessedRequest(
                    head: preparedHead,
                    body: body,
                    outcome: .noMatch(
                        unresolved: payload.unresolved,
                        nonUtf8: false,
                        bodyTooLarge: false
                    )
                )
            }

            // Reassemble mutated request.
            var newHeaders = HTTPHeaders()
            for (n, v) in payload.headers {
                newHeaders.add(name: n, value: v)
            }
            var newBody: ByteBuffer? = body
            if let mutated = payload.body, mutated != originalBodyData {
                var buf = ByteBufferAllocator().buffer(capacity: mutated.count)
                buf.writeBytes(mutated)
                newBody = buf
                if newHeaders.contains(name: "content-length") {
                    newHeaders.replaceOrAdd(name: "content-length", value: "\(mutated.count)")
                }
            }
            var newHead = HTTPRequestHead(
                version: .http1_1,
                method: preparedHead.method,
                uri: payload.uri,
                headers: newHeaders
            )
            newHead.version = .http1_1

            await evaluator.recordSubstitution(secretNames: payload.substituted)

            return ProcessedRequest(
                head: newHead,
                body: newBody,
                outcome: .substituted(names: payload.substituted)
            )
        }
    }

    private static func makeBypassedRequest(
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) -> ProcessedRequest {
        var newHeaders = head.headers
        newHeaders.remove(name: "Accept-Encoding")
        var newHead = HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: head.uri,
            headers: newHeaders
        )
        newHead.version = .http1_1
        return ProcessedRequest(head: newHead, body: body, outcome: .bypassed)
    }

    private static func splitURI(_ uri: String) -> (path: String, query: String?) {
        guard let q = uri.firstIndex(of: "?") else { return (uri, nil) }
        return (String(uri[..<q]), String(uri[uri.index(after: q)...]))
    }

    private static func makeEvent(
        startTime: Date,
        host: String,
        originalURI: String,
        originalMethod: String,
        statusCode: Int,
        duration: UInt32,
        outcome: ProcessedRequest.Outcome
    ) -> Event {
        let status = statusCode
        switch outcome {
        case .bypassed:
            return Event(
                timestamp: startTime,
                kind: .passThrough,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: []
            )
        case .substituted(let names):
            return Event(
                timestamp: startTime,
                kind: .substituted,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: names
            )
        case .noMatch:
            return Event(
                timestamp: startTime,
                kind: .noMatch,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: []
            )
        case .blocked(let alert):
            return Event(
                timestamp: startTime,
                kind: .exfilBlocked,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: [],
                alert: alert
            )
        }
    }

}
