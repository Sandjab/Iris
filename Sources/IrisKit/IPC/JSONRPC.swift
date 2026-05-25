import Foundation

// MARK: - Envelope

public struct JSONRPCRequest: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
    public let id: JSONRPCID

    public static let version = "2.0"

    public init(
        method: String,
        params: JSONValue? = nil,
        id: JSONRPCID,
        jsonrpc: String = JSONRPCRequest.version
    ) {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
        self.id = id
    }
}

public struct JSONRPCResponse: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let result: JSONValue?
    public let error: JSONRPCError?
    public let id: JSONRPCID

    public init(
        id: JSONRPCID,
        result: JSONValue?,
        error: JSONRPCError? = nil,
        jsonrpc: String = JSONRPCRequest.version
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCID, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: JSONRPCID, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }
}

// MARK: - ID

/// JSON-RPC 2.0 ids may be integer, string, or null. We accept all three but
/// emit `integer` from the client to keep wire output stable.
public enum JSONRPCID: Codable, Sendable, Hashable {
    case integer(Int64)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSON-RPC id must be integer, string, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Error object

public struct JSONRPCError: Codable, Sendable, Error, Equatable, LocalizedError {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { "JSON-RPC error \(code): \(message)" }
}

extension JSONRPCError {
    // Standard JSON-RPC 2.0 codes (-32700 .. -32603). Names preserved verbatim
    // from the JSON-RPC vocabulary; the swift-format suffix-repetition rule is
    // suppressed locally rather than mangling the well-known identifiers.
    // swift-format-ignore: DontRepeatTypeInStaticProperties
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    // swift-format-ignore: DontRepeatTypeInStaticProperties
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")

    // IRIS custom codes (SPECS §13.2).
    public static func unknownSecret(_ name: String) -> JSONRPCError {
        JSONRPCError(code: -32001, message: "Unknown secret: \(name)")
    }

    public static func invalidName(_ name: String) -> JSONRPCError {
        JSONRPCError(code: -32002, message: "Invalid secret name: \(name)")
    }

    public static func invalidAllowedHosts(_ hosts: [String]) -> JSONRPCError {
        JSONRPCError(code: -32003, message: "Invalid allowed_hosts: \(hosts)")
    }

    public static func duplicate(_ name: String) -> JSONRPCError {
        JSONRPCError(code: -32004, message: "Duplicate secret: \(name)")
    }

    public static let daemonPaused = JSONRPCError(code: -32005, message: "Daemon paused")

    public static func notFound(_ description: String) -> JSONRPCError {
        JSONRPCError(code: -32006, message: "Not found: \(description)")
    }
}

// MARK: - JSON value

/// Loosely-typed JSON tree. The admin protocol carries arbitrary user payloads
/// inside `params` / `result`; this type lets the transport layer remain
/// agnostic of method-specific shapes. Methods round-trip through
/// `JSONValue.encoding(_:)` / `JSONValue.decode(as:)` to typed structs.
public indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        // Order matters: integers must be tried before doubles so that whole
        // numbers stay integers when round-tripping.
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Wraps any `Encodable` value as a `JSONValue` by encoding it with the
    /// shared admin JSON encoder and decoding back into the loose tree.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONRPCCoder.makeEncoder().encode(value)
        return try JSONRPCCoder.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Re-decodes this value into a typed payload using the shared admin
    /// JSON decoder (snake_case + ISO-8601 dates).
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONRPCCoder.makeEncoder().encode(self)
        return try JSONRPCCoder.makeDecoder().decode(T.self, from: data)
    }
}

// MARK: - Shared coders

/// ISO-8601 coders for the admin transport. We do **not** apply
/// `convertTo/FromSnakeCase` strategies because they conflict with types
/// that ship explicit `CodingKeys` whose raw values are already snake_case
/// (notably `Config` / `BrokerConfig`, designed for TOML). Instead, every
/// wire-bound type declares snake_case `CodingKeys` explicitly — see
/// `AdminProtocol.swift` and the `Models/*` types.
///
/// Factories return fresh instances because `JSONEncoder`/`JSONDecoder` are
/// not formally `Sendable`.
public enum JSONRPCCoder {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
