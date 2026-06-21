import Foundation

/// Declarative description of a plugin, parsed from its `plugin.json`.
/// P1 models the full schema but only `onRequest` is dispatched (P3); response
/// hooks and config schema are reserved for later phases.
public struct PluginManifest: Codable, Sendable, Hashable {
    /// Supported plugin API contract version. Iris refuses manifests declaring
    /// any other value (forward/backward incompatibility is explicit, never silent).
    public static let supportedApiVersion = 1

    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let apiVersion: Int
    public let executable: String
    public let hooks: [PluginHook]
    public let capabilities: PluginCapabilities

    enum CodingKeys: String, CodingKey {
        case id, name, version, description
        case apiVersion = "api_version"
        case executable, hooks, capabilities
    }

    public init(
        id: String,
        name: String,
        version: String,
        description: String = "",
        apiVersion: Int = PluginManifest.supportedApiVersion,
        executable: String,
        hooks: [PluginHook],
        capabilities: PluginCapabilities = PluginCapabilities()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.apiVersion = apiVersion
        self.executable = executable
        self.hooks = hooks
        self.capabilities = capabilities
    }

    /// Tolerant decode: optional fields default rather than failing, so a
    /// minimal hand-written manifest stays valid.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        self.executable = try c.decode(String.self, forKey: .executable)
        self.hooks = try c.decodeIfPresent([PluginHook].self, forKey: .hooks) ?? []
        self.capabilities =
            try c.decodeIfPresent(PluginCapabilities.self, forKey: .capabilities)
            ?? PluginCapabilities()
    }

    /// Structural + security validation. Rejects path-traversal in `id`/`executable`
    /// (both are used to build filesystem paths) and unsupported API versions.
    public func validate() throws {
        guard Self.isSafePathComponent(id) else {
            throw PluginError.invalidManifest("invalid id: \(id)")
        }
        guard !name.isEmpty else { throw PluginError.invalidManifest("empty name") }
        guard !version.isEmpty else { throw PluginError.invalidManifest("empty version") }
        guard apiVersion == Self.supportedApiVersion else {
            throw PluginError.unsupportedApiVersion(apiVersion)
        }
        guard !executable.isEmpty,
            executable.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
                .allSatisfy(Self.isSafePathComponent)
        else {
            throw PluginError.invalidManifest("invalid executable path: \(executable)")
        }
        guard !hooks.isEmpty else { throw PluginError.invalidManifest("no hooks declared") }
        for hook in hooks {
            guard hook.timeoutMs > 0 else {
                throw PluginError.invalidManifest("timeout_ms must be positive")
            }
        }
    }

    /// A single, non-traversing, filesystem-safe path component.
    static func isSafePathComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != ".." else { return false }
        guard !s.contains("/"), !s.contains("\u{0}") else { return false }
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct PluginHook: Codable, Sendable, Hashable {
    public let event: HookEvent
    public let match: HookMatch
    public let mutates: Bool
    public let onFailure: FailureMode
    public let timeoutMs: Int

    public enum HookEvent: String, Codable, Sendable, CaseIterable {
        case onRequest = "on_request"
        // on_response / on_complete reserved for later phases.
    }

    public enum FailureMode: String, Codable, Sendable, CaseIterable {
        case skip  // continue the chain without this plugin (default, transformers)
        case block  // fail the request closed (policy plugins)
    }

    enum CodingKeys: String, CodingKey {
        case event, match, mutates
        case onFailure = "on_failure"
        case timeoutMs = "timeout_ms"
    }

    public init(
        event: HookEvent,
        match: HookMatch,
        mutates: Bool = false,
        onFailure: FailureMode = .skip,
        timeoutMs: Int = 1000
    ) {
        self.event = event
        self.match = match
        self.mutates = mutates
        self.onFailure = onFailure
        self.timeoutMs = timeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.event = try c.decode(HookEvent.self, forKey: .event)
        self.match = try c.decodeIfPresent(HookMatch.self, forKey: .match) ?? HookMatch()
        self.mutates = try c.decodeIfPresent(Bool.self, forKey: .mutates) ?? false
        self.onFailure = try c.decodeIfPresent(FailureMode.self, forKey: .onFailure) ?? .skip
        self.timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 1000
    }
}

/// Trigger conditions. P1 stores them; P3 evaluates them before any IPC.
public struct HookMatch: Codable, Sendable, Hashable {
    public let hosts: [String]
    public let methods: [String]
    public let pathRegex: String?
    public let contentType: String?

    enum CodingKeys: String, CodingKey {
        case hosts, methods
        case pathRegex = "path_regex"
        case contentType = "content_type"
    }

    public init(
        hosts: [String] = [],
        methods: [String] = [],
        pathRegex: String? = nil,
        contentType: String? = nil
    ) {
        self.hosts = hosts
        self.methods = methods
        self.pathRegex = pathRegex
        self.contentType = contentType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self.methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
        self.pathRegex = try c.decodeIfPresent(String.self, forKey: .pathRegex)
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
    }
}

/// Declared sandbox needs. Empty = no egress / no extra filesystem (deny-by-default).
public struct PluginCapabilities: Codable, Sendable, Hashable {
    public let network: [String]  // host:port allowed for egress
    public let filesystem: [String]  // e.g. ["scratch"]

    public init(network: [String] = [], filesystem: [String] = []) {
        self.network = network
        self.filesystem = filesystem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        self.filesystem = try c.decodeIfPresent([String].self, forKey: .filesystem) ?? []
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case unsupportedApiVersion(Int)
    case duplicateId(String)
    case unknownPlugin(String)
    case hashMismatch(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "Invalid plugin manifest: \(reason)"
        case .unsupportedApiVersion(let v): return "Unsupported plugin api_version: \(v)"
        case .duplicateId(let id): return "Plugin already installed: \(id)"
        case .unknownPlugin(let id): return "Unknown plugin: \(id)"
        case .hashMismatch(let id): return "Plugin content changed since approval: \(id)"
        case .ioError(let msg): return "Plugin I/O error: \(msg)"
        }
    }
}
