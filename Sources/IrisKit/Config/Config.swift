import Foundation

public struct Config: Codable, Sendable, Hashable {
    public let version: Int
    public let broker: BrokerConfig
    public let security: SecurityConfig
    public let backups: BackupsConfig
    public let hosts: [HostEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case broker
        case security
        case backups
        case hosts
    }

    public init(
        version: Int = 1,
        broker: BrokerConfig,
        security: SecurityConfig,
        backups: BackupsConfig,
        hosts: [HostEntry]
    ) {
        self.version = version
        self.broker = broker
        self.security = security
        self.backups = backups
        self.hosts = hosts
    }

    /// Built-in defaults, used to seed `config.json` on first run.
    /// The seeded host carries an epoch sentinel `created_at`; `ConfigStore.seed()`
    /// rewrites it with the real seed timestamp (a static `let` can't call `Date()`).
    public static let `default` = Config(
        version: 1,
        broker: BrokerConfig(
            listen: "127.0.0.1:8888",
            eventsListen: "127.0.0.1:8899",
            adminSocket: "~/Library/Application Support/iris/admin.sock",
            logLevel: .info,
            eventRetentionDays: 7,
            eventRingSize: 10_000
        ),
        security: SecurityConfig(
            onExfilAttempt: .blockAndNotify,
            maxSubstitutionsPerMinute: 60
        ),
        backups: BackupsConfig(maxCount: 10),
        hosts: [HostEntry(host: "api.anthropic.com", origin: .builtin, createdAt: Date(timeIntervalSince1970: 0))]
    )

    /// Returns a copy with `hosts` replaced.
    public func with(hosts: [HostEntry]) -> Config {
        Config(version: version, broker: broker, security: security, backups: backups, hosts: hosts)
    }
}

public struct BackupsConfig: Codable, Sendable, Hashable {
    public let maxCount: Int

    enum CodingKeys: String, CodingKey {
        case maxCount = "max_count"
    }

    public init(maxCount: Int) {
        self.maxCount = maxCount
    }
}

public struct HostEntry: Codable, Sendable, Hashable {
    public let host: String
    public let origin: MITMRule.Origin  // .builtin (seeded, protected) | .user (added)
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case host
        case origin
        case createdAt = "created_at"
    }

    public init(host: String, origin: MITMRule.Origin, createdAt: Date) {
        self.host = host
        self.origin = origin
        self.createdAt = createdAt
    }

    /// Tolerant decode: a host entry without an `origin` key (unlikely, but
    /// robust against a hand-edited file) defaults to `.user`. Seeded hosts
    /// always carry `origin: .builtin`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try c.decode(String.self, forKey: .host)
        self.origin = try c.decodeIfPresent(MITMRule.Origin.self, forKey: .origin) ?? .user
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public struct BrokerConfig: Codable, Sendable, Hashable {
    public let listen: String
    public let eventsListen: String
    public let adminSocket: String
    public let logLevel: LogLevel
    public let eventRetentionDays: Int
    public let eventRingSize: Int

    enum CodingKeys: String, CodingKey {
        case listen
        case eventsListen = "events_listen"
        case adminSocket = "admin_socket"
        case logLevel = "log_level"
        case eventRetentionDays = "event_retention_days"
        case eventRingSize = "event_ring_size"
    }

    public init(
        listen: String,
        eventsListen: String,
        adminSocket: String,
        logLevel: LogLevel,
        eventRetentionDays: Int,
        eventRingSize: Int
    ) {
        self.listen = listen
        self.eventsListen = eventsListen
        self.adminSocket = adminSocket
        self.logLevel = logLevel
        self.eventRetentionDays = eventRetentionDays
        self.eventRingSize = eventRingSize
    }

    /// Tilde-expanded admin socket path, usable as-is for bind/connect.
    public var expandedAdminSocket: String {
        (adminSocket as NSString).expandingTildeInPath
    }

    public var resolvedAdminSocketURL: URL {
        URL(fileURLWithPath: expandedAdminSocket)
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case trace
    case debug
    case info
    case warn
    case error
}

public struct SecurityConfig: Codable, Sendable, Hashable {
    public let onExfilAttempt: ExfilAttemptPolicy
    public let maxSubstitutionsPerMinute: Int

    enum CodingKeys: String, CodingKey {
        case onExfilAttempt = "on_exfil_attempt"
        case maxSubstitutionsPerMinute = "max_substitutions_per_minute"
    }

    public init(onExfilAttempt: ExfilAttemptPolicy, maxSubstitutionsPerMinute: Int) {
        self.onExfilAttempt = onExfilAttempt
        self.maxSubstitutionsPerMinute = maxSubstitutionsPerMinute
    }
}

public enum ExfilAttemptPolicy: String, Codable, Sendable, CaseIterable {
    case blockOnly = "block_only"
    case blockAndNotify = "block_and_notify"
    case blockNotifyPause = "block_notify_pause"
}

extension Config {
    public func validate() throws {
        try broker.validate()
        try security.validate()
        try backups.validate()
        for entry in hosts {
            try entry.validate()
        }
    }
}

extension BackupsConfig {
    public func validate() throws {
        guard maxCount >= 1 else {
            throw ConfigError.invalidValue(field: "backups.max_count", value: "\(maxCount)")
        }
    }
}

extension HostEntry {
    public func validate() throws {
        guard Secret.isValidHost(host) else {
            throw ConfigError.invalidValue(field: "hosts.host", value: host)
        }
    }
}

extension BrokerConfig {
    public func validate() throws {
        try Self.validateListenAddress(listen, field: "broker.listen")
        try Self.validateListenAddress(eventsListen, field: "broker.events_listen")
        if adminSocket.isEmpty {
            throw ConfigError.invalidValue(field: "broker.admin_socket", value: adminSocket)
        }
        guard eventRetentionDays > 0 else {
            throw ConfigError.invalidValue(
                field: "broker.event_retention_days",
                value: "\(eventRetentionDays)"
            )
        }
        guard eventRingSize > 0 else {
            throw ConfigError.invalidValue(
                field: "broker.event_ring_size",
                value: "\(eventRingSize)"
            )
        }
    }

    static func validateListenAddress(_ address: String, field: String) throws {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty,
            let port = Int(parts[1]),
            (1...65535).contains(port)
        else {
            throw ConfigError.invalidValue(field: field, value: address)
        }
    }
}

extension SecurityConfig {
    public func validate() throws {
        guard maxSubstitutionsPerMinute > 0 else {
            throw ConfigError.invalidValue(
                field: "security.max_substitutions_per_minute",
                value: "\(maxSubstitutionsPerMinute)"
            )
        }
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case fileReadFailed(path: String)
    case fileNotUtf8(path: String)
    case tomlParseFailed(message: String)
    case decodeFailed(message: String)
    case invalidValue(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .fileReadFailed(let path):
            return "Could not read config file at \(path)"
        case .fileNotUtf8(let path):
            return "Config file is not UTF-8: \(path)"
        case .tomlParseFailed(let message):
            return "TOML parse failed: \(message)"
        case .decodeFailed(let message):
            return "Config decode failed: \(message)"
        case .invalidValue(let field, let value):
            return "Invalid value '\(value)' for field '\(field)'"
        }
    }
}
