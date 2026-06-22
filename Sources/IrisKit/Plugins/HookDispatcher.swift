import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// The single capability the dispatcher needs from a plugin process: send one
/// `on_request` and get a typed result, with a per-call timeout. `PluginHost`
/// is the production conformer; tests inject a mock. The dispatcher body is
/// added in a later P3 task.
public protocol PluginInvoking: Sendable {
    var id: String { get }
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
    /// Fire-and-forget completion notification. Read-only; no return value. Default
    /// is a no-op so conformers that declare no onComplete hook need not implement it.
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws
}

extension PluginInvoking {
    public func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {}
}

// MARK: - PluginChainEntry

/// One running plugin + a hook it declared, in chain order. Built by
/// `PluginHostManager` after reconcile and pushed to the dispatcher. A single
/// entry belongs to either the onRequest chain or the onComplete chain depending
/// on the hook's `event`; the struct itself is event-agnostic.
public struct PluginChainEntry: Sendable {
    public let pluginId: String
    public let invoker: any PluginInvoking
    public let hook: PluginHook

    public init(pluginId: String, invoker: any PluginInvoking, hook: PluginHook) {
        self.pluginId = pluginId
        self.invoker = invoker
        self.hook = hook
    }
}

// MARK: - HookOutcome

public enum HookOutcome: Sendable {
    /// Continue to Iris scan/substitution with this (possibly modified) request.
    case proceed(head: HTTPRequestHead, body: ByteBuffer?)
    /// A plugin blocked the request; no upstream forward.
    case block(pluginId: String, reason: String?)
    /// A plugin returned a synthetic response; no upstream forward.
    case respond(pluginId: String, status: Int, headers: [(String, String)], body: ByteBuffer?)
}

// MARK: - HookDispatcher

public final class HookDispatcher: Sendable {
    /// Iris-side ceiling on a hook's declared timeout (design §4.5 "plafonné par Iris").
    public static let maxHookTimeout: TimeInterval = 5.0
    /// Cap on a plugin-supplied body the dispatcher will relay — applies to both
    /// `modify` and `respond` bodies (mirror MITM scan cap).
    static let maxBodyBytes = 4 * 1024 * 1024

    private let chainBox = NIOLockedValueBox<[PluginChainEntry]>([])
    private let completeChainBox = NIOLockedValueBox<[PluginChainEntry]>([])
    private let logger: Logger

    public init(logger: Logger = Logger(label: "io.iris.plugins.dispatch")) {
        self.logger = logger
    }

    /// Pushed by `PluginHostManager` after each reconcile. Cheap lock write.
    public func updateChain(_ chain: [PluginChainEntry]) {
        chainBox.withLockedValue { $0 = chain }
    }

    /// Pushed by `PluginHostManager` after each reconcile (onComplete chain).
    public func updateCompleteChain(_ chain: [PluginChainEntry]) {
        completeChainBox.withLockedValue { $0 = chain }
    }

    /// Test-only: number of entries in the current chain snapshot. Production code
    /// must not depend on this.
    public var chainCountForTesting: Int { chainBox.withLockedValue { $0.count } }

    /// Runs the onRequest chain. `host`/`path` are gating inputs; `head`/`body`
    /// are the request as decrypted (placeholders present, pre-Iris-scan).
    ///
    /// A `modify` result *overlays* its returned headers onto the request by name
    /// (unspecified headers survive, so a tagger plugin never has to echo back the
    /// `x-api-key: {{kc:...}}` placeholder); replacing the URI/body is independent.
    /// Header removal is not supported in v1.
    public func onRequest(head: HTTPRequestHead, body: ByteBuffer?, host: String) async -> HookOutcome {
        let chain = chainBox.withLockedValue { $0 }
        if chain.isEmpty { return .proceed(head: head, body: body) }

        let (path, _) = PlaceholderScanner.splitURI(head.uri)
        let method = head.method.rawValue
        let contentType = head.headers.first(name: "content-type")
        let applicable = chain.filter {
            $0.hook.match.matches(host: host, method: method, path: path, requestContentType: contentType)
        }
        if applicable.isEmpty { return .proceed(head: head, body: body) }

        var curHead = head
        var curBody = body
        for entry in applicable {
            let params = Self.makeParams(head: curHead, body: curBody, host: host)
            // Clamp: validate() rejects timeoutMs<=0 for installed plugins, but a
            // hook built in code could carry 0 — never hand the invoker a 0s window.
            let timeout = min(max(Double(entry.hook.timeoutMs) / 1000.0, 0.001), Self.maxHookTimeout)
            do {
                let result = try await entry.invoker.onRequest(params, timeout: timeout)
                switch result.action {
                case .pass:
                    continue
                case .modify:
                    // Decode the modified body once and reuse it in applyModify —
                    // a 4 MiB body decoded twice is wasted CPU/memory on the hot path.
                    let decodedBody = Self.decodeBody(result.body, cap: Self.maxBodyBytes)
                    if result.body != nil, decodedBody == nil {
                        logger.warning(
                            "plugin modify body ignored (over-cap or invalid encoding)",
                            metadata: ["id": "\(entry.pluginId)"]
                        )
                    }
                    (curHead, curBody) = Self.applyModify(
                        result,
                        decodedBody: decodedBody,
                        to: curHead,
                        body: curBody
                    )
                case .block:
                    return .block(pluginId: entry.pluginId, reason: result.reason)
                case .respond:
                    // Clamp at the wire→domain boundary: NIO's HTTPResponseStatus
                    // init does `UInt(statusCode)` for unknown codes, which TRAPS
                    // on a negative int — a plugin returning `status: -1` would
                    // crash the daemon. Reject anything outside the valid HTTP
                    // range and fall back to 200 (value-free warning).
                    let rawStatus = result.status ?? 200
                    let status: Int
                    if (100...599).contains(rawStatus) {
                        status = rawStatus
                    } else {
                        logger.warning(
                            "plugin respond status out of range; using 200",
                            metadata: ["id": "\(entry.pluginId)", "status": "\(rawStatus)"]
                        )
                        status = 200
                    }
                    let headers = (result.headers ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
                    let rbody = Self.decodeBody(result.body, cap: Self.maxBodyBytes)
                    if result.body != nil, rbody == nil {
                        logger.warning(
                            "plugin respond body ignored (over-cap or invalid encoding)",
                            metadata: ["id": "\(entry.pluginId)"]
                        )
                    }
                    return .respond(pluginId: entry.pluginId, status: status, headers: headers, body: rbody)
                }
            } catch {
                // At onRequest the request is PRE-substitution: it carries only
                // placeholders ({{kc:NAME}}), never a resolved secret value
                // (invariant §3; substitution runs later in scanAndSubstitute). So
                // `error` may echo placeholder text but can never carry a secret
                // VALUE — §6.1 (no secret values in logs) holds structurally. Keep
                // the full error for diagnosing flaky plugins.
                logger.warning(
                    "plugin onRequest failed",
                    metadata: [
                        "id": "\(entry.pluginId)",
                        "on_failure": "\(entry.hook.onFailure)",
                        "error": "\(error)",
                    ]
                )
                switch entry.hook.onFailure {
                case .skip: continue
                case .block: return .block(pluginId: entry.pluginId, reason: "plugin error (fail-closed)")
                }
            }
        }
        return .proceed(head: curHead, body: curBody)
    }

    /// Fires the onComplete chain for a finished request. Caller MUST invoke this
    /// off the response-critical path (a detached `Task`): it is fire-and-forget,
    /// read-only, and never returns anything. Gating runs before any IPC; a request
    /// with no applicable onComplete hook costs nothing. Per-plugin errors (dead
    /// process, EPIPE) are logged and swallowed — a misbehaving sink can never
    /// affect the response (already relayed) nor other plugins' delivery.
    public func onComplete(
        method: String,
        uri: String,
        host: String,
        contentType: String?,
        status: Int,
        durationMs: Int
    ) async {
        let chain = completeChainBox.withLockedValue { $0 }
        if chain.isEmpty { return }
        let (path, _) = PlaceholderScanner.splitURI(uri)
        let applicable = chain.filter {
            $0.hook.match.matches(
                host: host,
                method: method,
                path: path,
                requestContentType: contentType,
                status: status
            )
        }
        if applicable.isEmpty { return }
        let params = PluginRPC.OnCompleteParams(
            method: method,
            uri: uri,
            host: host,
            status: status,
            durationMs: durationMs
        )
        for entry in applicable {
            do {
                try await entry.invoker.onComplete(params)
            } catch {
                logger.debug(
                    "plugin onComplete failed",
                    metadata: ["id": "\(entry.pluginId)", "error": "\(error)"]
                )
            }
        }
    }

    // MARK: - Wire conversion

    private static func makeParams(head: HTTPRequestHead, body: ByteBuffer?, host: String)
        -> PluginRPC.OnRequestParams
    {
        let headers = head.headers.map { [$0.name, $0.value] }
        return PluginRPC.OnRequestParams(
            method: head.method.rawValue,
            uri: head.uri,
            host: host,
            headers: headers,
            body: encodeBody(body)
        )
    }

    private static func encodeBody(_ body: ByteBuffer?) -> PluginRPC.Body? {
        guard let body, body.readableBytes > 0 else { return nil }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) {
            return PluginRPC.Body(encoding: "utf8", data: utf8)
        }
        return PluginRPC.Body(encoding: "base64", data: data.base64EncodedString())
    }

    private static func decodeBody(_ body: PluginRPC.Body?, cap: Int) -> ByteBuffer? {
        guard let body else { return nil }
        let data: Data?
        switch body.encoding.lowercased() {
        case "base64": data = Data(base64Encoded: body.data)
        default: data = Data(body.data.utf8)
        }
        guard let bytes = data, bytes.count <= cap else { return nil }
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        return buf
    }

    /// Applies a `modify` result. Headers overlay by name onto the existing set
    /// via `replaceOrAdd` (unspecified headers are preserved — notably the
    /// credential placeholder Iris must still substitute); no header removal in
    /// v1. URI and body replacement are independent of the header overlay.
    private static func applyModify(
        _ result: PluginRPC.OnRequestResult,
        decodedBody: ByteBuffer?,
        to head: HTTPRequestHead,
        body: ByteBuffer?
    ) -> (HTTPRequestHead, ByteBuffer?) {
        var newHead = head
        if let uri = result.uri { newHead.uri = uri }
        if let pairs = result.headers {
            for p in pairs where p.count == 2 {
                newHead.headers.replaceOrAdd(name: p[0], value: p[1])
            }
        }
        var newBody = body
        if let decoded = decodedBody {
            newBody = decoded
            if newHead.headers.contains(name: "content-length") {
                newHead.headers.replaceOrAdd(name: "content-length", value: "\(decoded.readableBytes)")
            }
        }
        return (newHead, newBody)
    }
}
