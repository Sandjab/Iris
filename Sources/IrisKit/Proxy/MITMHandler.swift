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
            // `reason` is intentionally stored but NEVER forwarded to the client
            // (block returns an empty 403) nor written to events/logs (§6.1) — it
            // is retained only for a future debug channel.
            case pluginBlocked(pluginId: String, reason: String?)
            case pluginResponded(pluginId: String, status: Int, headers: [(String, String)], body: ByteBuffer?)
        }
    }

    private func forwardRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        // Reserved diagnostic endpoint, used by `iris doctor` check #6 to
        // verify the proxy is alive.
        if PingResponder.matches(head) {
            PingResponder.respond(on: context.channel, closeAfter: false)
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
        // Tracks whether the response head has been relayed yet, so a stream
        // failure can choose between a 502 (nothing sent) and a truncated close
        // (head already on the wire). EL-confined to the client/upstream loop.
        let headWritten = NIOLoopBoundBox(false, eventLoop: eventLoop)

        eventLoop.makeFutureWithTask { () async throws -> ProcessedRequest in
            let processed = try await Self.processRequest(
                head: head,
                body: body,
                dispatcher: server.hookDispatcher,
                evaluator: server.exfilRuleEngine,
                engine: server.placeholderEngine,
                secretStore: server.secretStore,
                logger: server.logger,
                host: host,
                bypass: bypass
            )
            Self.logOutcome(processed.outcome, server: server, host: host, originalURI: originalURI)
            return processed
        }.flatMap { processed -> EventLoopFuture<(ProcessedRequest, StreamOutcome)> in
            switch processed.outcome {
            case .pluginBlocked:
                // A plugin blocked the request: never forward upstream. Return an
                // empty 403; the block reason is deliberately not exposed (§6.1).
                return Self.writeSynthetic(
                    status: 403,
                    headers: [],
                    body: nil,
                    to: channel,
                    on: eventLoop,
                    headWritten: headWritten
                ).map { (processed, $0) }
            case .pluginResponded(_, let status, let headers, let body):
                // A plugin returned a synthetic response: relay it verbatim and
                // never forward upstream (no secret leaves the daemon).
                return Self.writeSynthetic(
                    status: status,
                    headers: headers,
                    body: body,
                    to: channel,
                    on: eventLoop,
                    headWritten: headWritten
                ).map { (processed, $0) }
            default:
                // Stream the response part-by-part to the client at the wire, no
                // buffering (SPECS §7.3 / §10.12). Resolves at `.end` with the
                // status captured at the head.
                return server.upstreamClient.stream(
                    head: processed.head,
                    body: processed.body,
                    host: host,
                    port: server.configuration.upstreamPort,
                    to: channel,
                    on: eventLoop,
                    headWritten: headWritten
                ).map { (processed, $0) }
            }
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
                if !headWritten.value {
                    // Nothing relayed yet (e.g. upstream unreachable) → surface a
                    // 502 before closing, matching the passthrough path (§5 case 1).
                    Self.writeBadGateway(to: channel)
                    return
                }
            // Head already on the wire → cannot change status; truncate by
            // closing (§5 case 2).
            }
            channel.close(promise: nil)
        }
    }

    /// Writes `502 Bad Gateway` (empty body) to the client and closes. Routes
    /// via `Channel.write` (thread-safe), never `context` — this runs in a
    /// future callback that is not guaranteed to be a handler context (the
    /// CONNECT-502 lesson).
    private static func writeBadGateway(to channel: Channel) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    /// Writes a plugin-supplied synthetic response (block/respond) to the client
    /// and resolves with its status. Routes via `Channel.write` (thread-safe),
    /// never `context` — this runs in a future callback (the CONNECT-502 lesson).
    /// Sets `headWritten` so the failure path doesn't double-write. Strips any
    /// plugin-supplied hop-by-hop headers (RFC 7230 §6.1) and sets a correct
    /// content-length for the synthetic body.
    private static func writeSynthetic(
        status: Int,
        headers: [(String, String)],
        body: ByteBuffer?,
        to channel: Channel,
        on eventLoop: EventLoop,
        headWritten: NIOLoopBoundBox<Bool>
    ) -> EventLoopFuture<StreamOutcome> {
        var h = HTTPHeaders()
        // Strip the full RFC 7230 §6.1 hop-by-hop set: a plugin `respond` payload
        // could otherwise inject framing headers that desync the client connection.
        let hopByHop: Set<String> = [
            "content-length", "transfer-encoding", "connection", "keep-alive",
            "upgrade", "te", "trailer", "proxy-authenticate", "proxy-authorization",
            "proxy-connection",
        ]
        for (n, v) in headers where !hopByHop.contains(n.lowercased()) {
            h.add(name: n, value: v)
        }
        h.replaceOrAdd(name: "content-length", value: "\(body?.readableBytes ?? 0)")
        let respHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: status),
            headers: h
        )
        headWritten.value = true
        channel.write(HTTPServerResponsePart.head(respHead), promise: nil)
        if let body, body.readableBytes > 0 {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        }
        let promise = eventLoop.makePromise(of: StreamOutcome.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            promise.succeed(StreamOutcome(statusCode: status))
        }
        return promise.futureResult
    }

    // SPECS §7.2: bodies larger than this are passed through without scanning.
    static let bodyMaxBytes = 4 * 1024 * 1024

    /// Whether a request body is too large to scan/substitute (SPECS §7.2).
    /// SECURITY (audit L-1): the size is measured on the bytes ACTUALLY received
    /// and buffered (`readableBytes`), never on the client-declared
    /// `Content-Length`. Taking the buffer itself — not a declared length — puts
    /// the header structurally out of reach, so a client cannot declare an
    /// oversized length to skip the exfiltration scan on a small body.
    static func bodyExceedsScanCap(_ body: ByteBuffer?) -> Bool {
        (body?.readableBytes ?? 0) > bodyMaxBytes
    }

    private static func processRequest(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        dispatcher: HookDispatcher,
        evaluator: ExfilRuleEngine,
        engine: PlaceholderEngine,
        secretStore: any SecretStore,
        logger: Logger,
        host: String,
        bypass: Bool
    ) async throws -> ProcessedRequest {
        if bypass {
            return makeBypassedRequest(head: head, body: body)
        }
        // P3: the onRequest plugin chain runs BEFORE the Iris scan/substitution.
        // Invariant §3: whatever proceeds upstream is still scanned by
        // `scanAndSubstitute` below; `block`/`respond` never forward upstream (no
        // secret leaves the daemon), so no scan is needed on those paths.
        switch await dispatcher.onRequest(head: head, body: body, host: host) {
        case .block(let pid, let reason):
            return ProcessedRequest(
                head: head,
                body: body,
                outcome: .pluginBlocked(pluginId: pid, reason: reason)
            )
        case .respond(let pid, let status, let headers, let rbody):
            return ProcessedRequest(
                head: head,
                body: body,
                outcome: .pluginResponded(
                    pluginId: pid,
                    status: status,
                    headers: headers,
                    body: rbody
                )
            )
        case .proceed(let h, let b):
            return try await scanAndSubstitute(
                head: h,
                body: b,
                evaluator: evaluator,
                engine: engine,
                secretStore: secretStore,
                logger: logger,
                host: host
            )
        }
    }

    /// The Iris scan/scoping/substitution stage (SPECS §7). Operates on the
    /// request as it will be forwarded upstream — for the plugin path, on the
    /// (possibly modified) request returned by the onRequest chain. Mechanically
    /// extracted from `processRequest`; the logic is unchanged.
    private static func scanAndSubstitute(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        evaluator: ExfilRuleEngine,
        engine: PlaceholderEngine,
        secretStore: any SecretStore,
        logger: Logger,
        host: String
    ) async throws -> ProcessedRequest {
        // Strip Accept-Encoding (SPECS §7.5).
        var preparedHeaders = HTTPHeaders()
        for (name, value) in head.headers where name.lowercased() != "accept-encoding" {
            preparedHeaders.add(name: name, value: value)
        }

        // Body size cap (SPECS §7.2). Measured on bytes actually received, not
        // the declared Content-Length (audit L-1).
        let bodyTooLarge = bodyExceedsScanCap(body)
        if bodyTooLarge {
            logger.warning(
                "Body too large, skipping substitution scan",
                metadata: ["host": "\(host)", "size": "\(body?.readableBytes ?? 0)"]
            )
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
        let (path, _) = PlaceholderScanner.splitURI(preparedHead.uri)
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

            // Best-effort usage bookkeeping: bump `usageCount` / `lastUsedAt` for
            // each substituted secret so `iris secret list` reflects real activity
            // (stale vs unexpectedly-hot secrets). Detached so a slow Keychain
            // write never delays the upstream forward (CLAUDE.md §10: no blocking
            // I/O in the proxy). A telemetry write must NEVER fail the request, so
            // errors are logged (name only, never the value, CLAUDE.md §6.1) and
            // swallowed. Under concurrency the read-modify-write may drop an
            // increment; an approximate counter is acceptable for this signal.
            if !payload.substituted.isEmpty {
                let substitutedNames = payload.substituted
                Task {
                    let now = Date()
                    for name in substitutedNames {
                        do {
                            _ = try await secretStore.recordUsage(of: name, at: now)
                        } catch {
                            logger.warning(
                                "Failed to record secret usage",
                                metadata: ["secret": "\(name)", "error": "\(error)"]
                            )
                        }
                    }
                }
            }

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

    /// Logs the request outcome and applies the exfil-attempt policy (pause).
    /// Runs before the response stream is wired; emits no `Event` (that happens
    /// at `.end`). Secret values never appear — only names (CLAUDE.md §6.1).
    private static func logOutcome(
        _ outcome: ProcessedRequest.Outcome,
        server: ProxyServer,
        host: String,
        originalURI: String
    ) {
        switch outcome {
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
        case .pluginBlocked(let pluginId, _):
            // Value-free: id + host only. The block `reason` is NOT logged (§6.1).
            server.logger.info(
                "plugin blocked request",
                metadata: ["host": "\(host)", "plugin": "\(pluginId)"]
            )
        case .pluginResponded(let pluginId, let st, _, _):
            // Value-free: id + host + status only. Headers/body are NOT logged (§6.1).
            server.logger.info(
                "plugin responded synthetically",
                metadata: ["host": "\(host)", "plugin": "\(pluginId)", "status": "\(st)"]
            )
        case .bypassed, .noMatch:
            break
        }
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
        case .pluginBlocked(let pluginId, _):
            return Event(
                timestamp: startTime,
                kind: .pluginBlocked,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                pluginId: pluginId
            )
        case .pluginResponded(let pluginId, _, _, _):
            return Event(
                timestamp: startTime,
                kind: .pluginResponded,
                host: host,
                method: originalMethod,
                path: originalURI,
                statusCode: status,
                durationMs: duration,
                pluginId: pluginId
            )
        }
    }

}
