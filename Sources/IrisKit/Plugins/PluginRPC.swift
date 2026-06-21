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

    /// Methods spoken on the channel. P2b uses `initialize` (request) and
    /// `shutdown` (notification); `onRequest` lands in P3.
    public enum Method {
        public static let initialize = "initialize"
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
