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
}

// MARK: - PluginChainEntry

/// One running plugin + the `onRequest` hook it declared, in chain order. Built
/// by `PluginHostManager` after reconcile and pushed to the dispatcher.
public struct PluginChainEntry: Sendable {
    public let pluginId: String
    public let invoker: any PluginInvoking
    public let hook: PluginHook  // event == .onRequest

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
    /// Cap on a `respond` body the dispatcher will relay (mirror MITM scan cap).
    static let maxRespondBodyBytes = 4 * 1024 * 1024

    private let chainBox = NIOLockedValueBox<[PluginChainEntry]>([])
    private let logger: Logger

    public init(logger: Logger = Logger(label: "io.iris.plugins.dispatch")) {
        self.logger = logger
    }

    /// Pushed by `PluginHostManager` after each reconcile. Cheap lock write.
    public func updateChain(_ chain: [PluginChainEntry]) {
        chainBox.withLockedValue { $0 = chain }
    }

    /// Runs the onRequest chain. `host`/`path` are gating inputs; `head`/`body`
    /// are the request as decrypted (placeholders present, pre-Iris-scan).
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
            let timeout = min(Double(entry.hook.timeoutMs) / 1000.0, Self.maxHookTimeout)
            do {
                let result = try await entry.invoker.onRequest(params, timeout: timeout)
                switch result.action {
                case .pass:
                    continue
                case .modify:
                    (curHead, curBody) = Self.applyModify(result, to: curHead, body: curBody)
                case .block:
                    return .block(pluginId: entry.pluginId, reason: result.reason)
                case .respond:
                    let status = result.status ?? 200
                    let headers = (result.headers ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
                    let rbody = Self.decodeBody(result.body, cap: Self.maxRespondBodyBytes)
                    return .respond(pluginId: entry.pluginId, status: status, headers: headers, body: rbody)
                }
            } catch {
                // Value-free: id + failure mode only, never request payload (§6.1).
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

    // MARK: - Wire conversion

    static func makeParams(head: HTTPRequestHead, body: ByteBuffer?, host: String) -> PluginRPC.OnRequestParams {
        let headers = head.headers.map { [$0.name, $0.value] }
        return PluginRPC.OnRequestParams(
            method: head.method.rawValue,
            uri: head.uri,
            host: host,
            headers: headers,
            body: encodeBody(body)
        )
    }

    static func encodeBody(_ body: ByteBuffer?) -> PluginRPC.Body? {
        guard let body, body.readableBytes > 0 else { return nil }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) {
            return PluginRPC.Body(encoding: "utf8", data: utf8)
        }
        return PluginRPC.Body(encoding: "base64", data: data.base64EncodedString())
    }

    static func decodeBody(_ body: PluginRPC.Body?, cap: Int) -> ByteBuffer? {
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

    static func applyModify(
        _ result: PluginRPC.OnRequestResult,
        to head: HTTPRequestHead,
        body: ByteBuffer?
    ) -> (HTTPRequestHead, ByteBuffer?) {
        var newHead = head
        if let uri = result.uri { newHead.uri = uri }
        if let pairs = result.headers {
            var h = HTTPHeaders()
            for p in pairs where p.count == 2 { h.add(name: p[0], value: p[1]) }
            newHead.headers = h
        }
        var newBody = body
        if let b = result.body, let decoded = decodeBody(b, cap: maxRespondBodyBytes) {
            newBody = decoded
            if newHead.headers.contains(name: "content-length") {
                newHead.headers.replaceOrAdd(name: "content-length", value: "\(decoded.readableBytes)")
            }
        }
        return (newHead, newBody)
    }
}
