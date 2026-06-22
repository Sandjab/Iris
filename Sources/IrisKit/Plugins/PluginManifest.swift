import Foundation
import NIOConcurrencyHelpers

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
        try capabilities.validate()
    }

    /// Allowed characters for a single path component, built once and cached
    /// rather than reconstructed on every `isSafePathComponent` call.
    private static let safePathComponentChars = CharacterSet(
        charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// A single, non-traversing, filesystem-safe path component.
    static func isSafePathComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != ".." else { return false }
        guard !s.contains("/"), !s.contains("\u{0}") else { return false }
        return s.unicodeScalars.allSatisfy { safePathComponentChars.contains($0) }
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
        case onComplete = "on_complete"
        // on_response reserved for a later phase (PR 2).
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
    /// Response status codes to match (onComplete/onResponse only). nil/empty =
    /// wildcard. Ignored for onRequest (no response status exists at request time).
    public let status: [Int]?

    enum CodingKeys: String, CodingKey {
        case hosts, methods
        case pathRegex = "path_regex"
        case contentType = "content_type"
        case status
    }

    public init(
        hosts: [String] = [],
        methods: [String] = [],
        pathRegex: String? = nil,
        contentType: String? = nil,
        status: [Int]? = nil
    ) {
        self.hosts = hosts
        self.methods = methods
        self.pathRegex = pathRegex
        self.contentType = contentType
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self.methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
        self.pathRegex = try c.decodeIfPresent(String.self, forKey: .pathRegex)
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        self.status = try c.decodeIfPresent([Int].self, forKey: .status)
    }
}

extension HookMatch {
    /// True iff every declared condition matches. Empty/nil condition = wildcard.
    /// Host is exact, case-insensitive, port-stripped (SPECS §8.2; no glob in MVP).
    /// An unparseable `pathRegex` matches nothing (fail-closed gating).
    ///
    /// Two semantics a plugin author should know:
    /// - `contentType` is matched as a **case-insensitive substring**, so a hook
    ///   `contentType: "application/json"` matches a request
    ///   `content-type: application/json; charset=utf-8`.
    /// - Host normalization strips a trailing `:port` and lowercases, mirroring
    ///   `ExfilRuleEngine`'s host normalization. IPv6-literal hosts
    ///   (`[::1]:443`) are NOT specially handled — intentional, for parity with
    ///   `ExfilRuleEngine` (IRIS brokers to DNS API hosts). Gating is fail-closed,
    ///   so an unmatched host merely skips the hook; it is never a security bypass.
    public func matches(
        host: String,
        method: String,
        path: String,
        requestContentType: String?,
        status: Int? = nil
    ) -> Bool {
        if !hosts.isEmpty {
            let normalized = Self.normalizeHost(host)
            guard hosts.contains(where: { Self.normalizeHost($0) == normalized }) else { return false }
        }
        if !methods.isEmpty {
            let m = method.lowercased()
            guard methods.contains(where: { $0.lowercased() == m }) else { return false }
        }
        if let pattern = pathRegex, !pattern.isEmpty {
            guard let regex = Self.compiledRegex(pattern) else { return false }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            guard regex.firstMatch(in: path, range: range) != nil else { return false }
        }
        if let want = contentType, !want.isEmpty {
            guard let have = requestContentType?.lowercased(), have.contains(want.lowercased()) else {
                return false
            }
        }
        // Status is response-only: enforce only when the hook declares it AND a
        // status is supplied (onComplete). At onRequest `status` is nil → skipped.
        if let declared = self.status, !declared.isEmpty, let actual = status {
            guard declared.contains(actual) else { return false }
        }
        return true
    }

    private static func normalizeHost(_ host: String) -> String {
        (host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host).lowercased()
    }

    /// Process-wide cache of compiled path regexes, keyed by pattern. `matches`
    /// runs on the proxy hot path (per request, per active hook); recompiling the
    /// same `NSRegularExpression` every time would add latency. Patterns are few
    /// (one per plugin hook) and stable, so a small lock-protected cache
    /// effectively precompiles them. `NSRegularExpression` is thread-safe for
    /// matching. An unparseable pattern returns nil (not cached) → fail-closed.
    private static let regexCache = NIOLockedValueBox<[String: NSRegularExpression]>([:])

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        regexCache.withLockedValue { cache in
            if let cached = cache[pattern] { return cached }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            cache[pattern] = regex
            return regex
        }
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

    /// Filesystem capability values understood by the v1 sandbox. `scratch` =
    /// a per-plugin private working dir; nothing else is granted by default.
    static let knownFilesystemCapabilities: Set<String> = ["scratch"]

    /// Structural validation of declared capabilities (design §5/§6). Rejects
    /// garbage early (install time) rather than letting it reach the sandbox
    /// profile. Note: SBPL injection is independently neutralised by
    /// `PluginSandboxProfile.sbplString` escaping — this is defense in depth and
    /// a fail-fast UX, not the injection boundary.
    ///
    /// - `network`: each entry is `host:port`, host non-empty and free of
    ///   whitespace/control chars, port a decimal in 1...65535. (The SBPL
    ///   `(remote ip ...)` form is still PROVISIONAL — Seatbelt resolves no DNS —
    ///   so this validates shape, not runtime reachability. Cf. §6/§14.)
    /// - `filesystem`: each entry must be a known capability (`scratch`).
    func validate() throws {
        for endpoint in network {
            guard let colon = endpoint.lastIndex(of: ":") else {
                throw PluginError.invalidManifest("network capability must be host:port: \(endpoint)")
            }
            let host = String(endpoint[..<colon])
            let portString = String(endpoint[endpoint.index(after: colon)...])
            // A host containing ':' is only valid as a bracketed IPv6 literal
            // ([::1]); a bare "::1" splits into host ":" + port "1" and must be
            // rejected as malformed.
            let bracketedIPv6 = host.hasPrefix("[") && host.hasSuffix("]")
            guard !host.isEmpty,
                !host.unicodeScalars.contains(where: {
                    $0 == " " || CharacterSet.controlCharacters.contains($0)
                }),
                !host.contains(":") || bracketedIPv6
            else {
                throw PluginError.invalidManifest("invalid network host: \(endpoint)")
            }
            guard let port = Int(portString), (1...65535).contains(port) else {
                throw PluginError.invalidManifest("invalid network port: \(endpoint)")
            }
        }
        for entry in filesystem where !Self.knownFilesystemCapabilities.contains(entry) {
            throw PluginError.invalidManifest("unknown filesystem capability: \(entry)")
        }
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case unsupportedApiVersion(Int)
    case duplicateId(String)
    case unknownPlugin(String)
    case hashMismatch(String)
    case ioError(String)
    case unsafeSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "Invalid plugin manifest: \(reason)"
        case .unsupportedApiVersion(let v): return "Unsupported plugin api_version: \(v)"
        case .duplicateId(let id): return "Plugin already installed: \(id)"
        case .unknownPlugin(let id): return "Unknown plugin: \(id)"
        case .hashMismatch(let id): return "Plugin content changed since approval: \(id)"
        case .ioError(let msg): return "Plugin I/O error: \(msg)"
        case .unsafeSource(let reason): return "Unsafe plugin source: \(reason)"
        }
    }
}
