import Foundation

/// Wire types and (de)serialization for the plugin IPC channel.
///
/// Transport is NDJSON: one **compact** JSON object per line, UTF-8, terminated
/// by `\n` (cf. docs/plugins-design.md §8). The envelope reuses the admin
/// JSON-RPC 2.0 types (`JSONRPCRequest`/`JSONRPCResponse`) and the shared
/// `JSONRPCCoder` (ISO-8601 dates, explicit snake_case `CodingKeys`). The
/// daemon is the client; the plugin is the server.
public enum PluginRPC {
    /// `initialize` params (daemon → plugin) at startup. Carries only non-secret
    /// config and the granted sandbox capabilities — never request data.
    public struct InitializeParams: Codable, Sendable, Equatable {
        public let apiVersion: Int
        public let configValues: [String: String]
        public let capabilities: PluginCapabilities
        /// Canonical (realpath-resolved) private scratch directory the plugin may
        /// write to. The sandbox allows writes only here (cf. PluginSandboxProfile).
        public let scratchDir: String

        enum CodingKeys: String, CodingKey {
            case apiVersion = "api_version"
            case configValues = "config_values"
            case capabilities
            case scratchDir = "scratch_dir"
        }

        public init(
            apiVersion: Int,
            configValues: [String: String],
            capabilities: PluginCapabilities,
            scratchDir: String
        ) {
            self.apiVersion = apiVersion
            self.configValues = configValues
            self.capabilities = capabilities
            self.scratchDir = scratchDir
        }
    }

    /// `initialize` result (plugin → daemon): the plugin confirms it is ready.
    public struct InitializeResult: Codable, Sendable, Equatable {
        public let ready: Bool

        public init(ready: Bool) {
            self.ready = ready
        }
    }

    /// Request/response body envelope. `encoding` is "utf8" for valid UTF-8 text,
    /// "base64" for arbitrary bytes (newline-safe NDJSON, design §8).
    public struct Body: Codable, Sendable, Equatable {
        public let encoding: String
        public let data: String

        public init(encoding: String, data: String) {
            self.encoding = encoding
            self.data = data
        }
    }

    /// `on_request` params (daemon → plugin). Headers are [[name, value], ...] —
    /// the exact wire tuple shape from design §8. Carries placeholders only; the
    /// plugin never sees a resolved secret (invariant §3).
    public struct OnRequestParams: Codable, Sendable, Equatable {
        public let method: String
        public let uri: String
        public let host: String
        public let headers: [[String]]
        public let body: Body?

        public init(method: String, uri: String, host: String, headers: [[String]], body: Body?) {
            self.method = method
            self.uri = uri
            self.host = host
            self.headers = headers
            self.body = body
        }
    }

    /// `on_request` result (plugin → daemon). Flat, action-driven: which fields are
    /// meaningful depends on `action`.
    ///   pass     → (no other fields)
    ///   modify   → `uri` (optional), `headers` (request headers, optional), `body` (optional)
    ///   block    → `reason` (optional)
    ///   respond  → `status` (required), `headers` (response headers, optional), `body` (optional)
    public struct OnRequestResult: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable { case pass, modify, block, respond }
        public let action: Action
        public let uri: String?
        public let headers: [[String]]?
        public let body: Body?
        public let reason: String?
        public let status: Int?

        enum CodingKeys: String, CodingKey { case action, uri, headers, body, reason, status }

        public init(
            action: Action,
            uri: String? = nil,
            headers: [[String]]? = nil,
            body: Body? = nil,
            reason: String? = nil,
            status: Int? = nil
        ) {
            self.action = action
            self.uri = uri
            self.headers = headers
            self.body = body
            self.reason = reason
            self.status = status
        }

        // Tolerant decode: only `action` is required.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.action = try c.decode(Action.self, forKey: .action)
            self.uri = try c.decodeIfPresent(String.self, forKey: .uri)
            self.headers = try c.decodeIfPresent([[String]].self, forKey: .headers)
            self.body = try c.decodeIfPresent(Body.self, forKey: .body)
            self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
            self.status = try c.decodeIfPresent(Int.self, forKey: .status)
        }
    }

    /// `on_complete` params (daemon → plugin), a NOTIFICATION (no reply expected).
    /// HTTP-level metadata only — never a body or header (invariant §7.2/§6.1). The
    /// `uri` is the ORIGINAL request URI (placeholder-form), never a resolved secret.
    public struct OnCompleteParams: Codable, Sendable, Equatable {
        public let method: String
        public let uri: String
        public let host: String
        /// Upstream HTTP status, or 0 when the request errored before/mid response.
        public let status: Int
        public let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case method, uri, host, status
            case durationMs = "duration_ms"
        }

        public init(method: String, uri: String, host: String, status: Int, durationMs: Int) {
            self.method = method
            self.uri = uri
            self.host = host
            self.status = status
            self.durationMs = durationMs
        }
    }

    /// `on_response` params (daemon → plugin), request/response (reply expected).
    /// METADATA MODE: status + response headers only — never a response body
    /// (SPECS §7.2 bodies untouched). `uri` is the ORIGINAL request URI
    /// (placeholder-form), never a resolved secret (§6.1).
    public struct OnResponseParams: Codable, Sendable, Equatable {
        public let method: String
        public let uri: String
        public let host: String
        public let status: Int
        public let headers: [[String]]

        public init(method: String, uri: String, host: String, status: Int, headers: [[String]]) {
            self.method = method
            self.uri = uri
            self.host = host
            self.status = status
            self.headers = headers
        }
    }

    /// `on_response` result (plugin → daemon). Flat, action-driven.
    ///   pass   → (no other fields) — relay the head unchanged
    ///   modify → `headers` (overlaid by name onto the response head; status never modified)
    public struct OnResponseResult: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable { case pass, modify }
        public let action: Action
        public let headers: [[String]]?

        enum CodingKeys: String, CodingKey { case action, headers }

        public init(action: Action, headers: [[String]]? = nil) {
            self.action = action
            self.headers = headers
        }

        // Tolerant decode: only `action` is required.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.action = try c.decode(Action.self, forKey: .action)
            self.headers = try c.decodeIfPresent([[String]].self, forKey: .headers)
        }
    }

    /// Methods spoken on the channel. P2b uses `initialize` (request) and
    /// `shutdown` (notification); `onRequest` lands in P3; `onComplete` in P6;
    /// `onResponse` (metadata mode) follows.
    public enum Method {
        public static let initialize = "initialize"
        public static let onRequest = "on_request"
        public static let onComplete = "on_complete"
        public static let onResponse = "on_response"
        public static let shutdown = "shutdown"
    }

    /// Encodes a request as a single compact NDJSON line (trailing `\n`).
    public static func encodeRequest<P: Encodable>(
        method: String,
        params: P,
        id: Int64
    ) throws -> String {
        let request = JSONRPCRequest(
            method: method,
            params: try JSONValue.encoding(params),
            id: .integer(id)
        )
        return try line(from: request)
    }

    /// Encodes a notification (no `id`, no response expected) as one NDJSON line.
    public static func encodeNotification(method: String) throws -> String {
        // A notification omits `id` entirely; build the object directly so no
        // `id` key is emitted (JSONRPCRequest always carries one).
        let object = JSONValue.object([
            "jsonrpc": .string(JSONRPCRequest.version),
            "method": .string(method),
        ])
        return try line(from: object)
    }

    /// Encodes a notification WITH params (no `id`, no response expected) as one
    /// NDJSON line. Used by `on_complete`.
    public static func encodeNotification<P: Encodable>(method: String, params: P) throws -> String {
        let object = JSONValue.object([
            "jsonrpc": .string(JSONRPCRequest.version),
            "method": .string(method),
            "params": try JSONValue.encoding(params),
        ])
        return try line(from: object)
    }

    /// Parses one NDJSON line into a `JSONRPCResponse`.
    public static func decodeResponse(_ line: String) throws -> JSONRPCResponse {
        let data = Data(line.utf8)
        return try JSONRPCCoder.makeDecoder().decode(JSONRPCResponse.self, from: data)
    }

    /// Compact single-line encoding + `\n`. `JSONEncoder` never emits newlines
    /// unless `.prettyPrinted`, so the output is guaranteed single-line.
    private static func line<T: Encodable>(from value: T) throws -> String {
        let data = try JSONRPCCoder.makeEncoder().encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
