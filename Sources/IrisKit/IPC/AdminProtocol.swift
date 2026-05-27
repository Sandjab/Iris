import Foundation

// MARK: - Method registry

/// Admin Unix socket methods exposed by the daemon. Names match SPECS §13.2.
public enum AdminMethod: String, Codable, Sendable, CaseIterable {
    case secretList = "secret.list"
    case secretGet = "secret.get"
    case secretAdd = "secret.add"
    case secretUpdate = "secret.update"
    case secretRotate = "secret.rotate"
    case secretDelete = "secret.delete"
    case daemonStatus = "daemon.status"
    case daemonStats = "daemon.stats"
    case daemonPause = "daemon.pause"
    case daemonResume = "daemon.resume"
    case eventsQuery = "events.query"
    case caExportPath = "ca.export_path"
    case caFingerprint = "ca.fingerprint"
    case caIsTrusted = "ca.is_trusted"
    case configGet = "config.get"
    case ruleAdd = "rule.add"
    case ruleList = "rule.list"
    case ruleDelete = "rule.delete"
    case configReload = "config.reload"
    case eventsClear = "events.clear"
}

// MARK: - Params

public struct SecretAddParams: Codable, Sendable, Equatable {
    public let name: String
    public let allowedHosts: [String]
    /// Binary secret value. Serialized as base64 by the default `Data` Codable.
    public let value: Data

    enum CodingKeys: String, CodingKey {
        case name
        case allowedHosts = "allowed_hosts"
        case value
    }

    public init(name: String, allowedHosts: [String], value: Data) {
        self.name = name
        self.allowedHosts = allowedHosts
        self.value = value
    }
}

public struct SecretNameParams: Codable, Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct SecretUpdateParams: Codable, Sendable, Equatable {
    public let name: String
    public let allowedHosts: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case allowedHosts = "allowed_hosts"
    }

    public init(name: String, allowedHosts: [String]) {
        self.name = name
        self.allowedHosts = allowedHosts
    }
}

public struct SecretRotateParams: Codable, Sendable, Equatable {
    public let name: String
    public let value: Data

    public init(name: String, value: Data) {
        self.name = name
        self.value = value
    }
}

public struct EventsQueryParams: Codable, Sendable, Equatable {
    public let since: Date?
    public let until: Date?
    public let limit: Int?
    public let kind: [Event.Kind]?
    public let host: String?

    public init(
        since: Date? = nil,
        until: Date? = nil,
        limit: Int? = nil,
        kind: [Event.Kind]? = nil,
        host: String? = nil
    ) {
        self.since = since
        self.until = until
        self.limit = limit
        self.kind = kind
        self.host = host
    }
}

public struct RuleHostParams: Codable, Sendable, Equatable {
    public let host: String
    public init(host: String) { self.host = host }
}

// MARK: - Results

public struct SecretDeletedResult: Codable, Sendable, Equatable {
    public let deleted: Bool
    public init(deleted: Bool) { self.deleted = deleted }
}

public struct RuleDeletedResult: Codable, Sendable, Equatable {
    public let deleted: Bool
    public init(deleted: Bool) { self.deleted = deleted }
}

public struct DaemonStats: Codable, Sendable, Equatable {
    public let reqTotal: UInt64
    public let subTotal: UInt64
    public let exfilBlockedTotal: UInt64
    public let errorsTotal: UInt64

    enum CodingKeys: String, CodingKey {
        case reqTotal = "req_total"
        case subTotal = "sub_total"
        case exfilBlockedTotal = "exfil_blocked_total"
        case errorsTotal = "errors_total"
    }

    public init(reqTotal: UInt64, subTotal: UInt64, exfilBlockedTotal: UInt64, errorsTotal: UInt64) {
        self.reqTotal = reqTotal
        self.subTotal = subTotal
        self.exfilBlockedTotal = exfilBlockedTotal
        self.errorsTotal = errorsTotal
    }

    public static let zero = DaemonStats(reqTotal: 0, subTotal: 0, exfilBlockedTotal: 0, errorsTotal: 0)
}

public struct DaemonStatus: Codable, Sendable, Equatable {
    public let pid: Int32
    public let uptimeS: UInt64
    public let version: String
    public let stats: DaemonStats

    enum CodingKeys: String, CodingKey {
        case pid
        case uptimeS = "uptime_s"
        case version
        case stats
    }

    public init(pid: Int32, uptimeS: UInt64, version: String, stats: DaemonStats) {
        self.pid = pid
        self.uptimeS = uptimeS
        self.version = version
        self.stats = stats
    }
}

public struct DaemonPauseResult: Codable, Sendable, Equatable {
    public let paused: Bool
    public init(paused: Bool) { self.paused = paused }
}

public struct CAExportPathResult: Codable, Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct CAFingerprintResult: Codable, Sendable, Equatable {
    public let sha256: String
    public init(sha256: String) { self.sha256 = sha256 }
}

public struct CAIsTrustedResult: Codable, Sendable, Equatable {
    public let trusted: Bool
    public init(trusted: Bool) { self.trusted = trusted }
}

public struct ConfigReloadResult: Codable, Sendable, Equatable {
    public let reloaded: Bool
    public let ignored: [String]
    public init(reloaded: Bool, ignored: [String]) {
        self.reloaded = reloaded
        self.ignored = ignored
    }
}

public struct EventsClearResult: Codable, Sendable, Equatable {
    public let deletedCount: Int
    enum CodingKeys: String, CodingKey { case deletedCount = "deleted_count" }
    public init(deletedCount: Int) { self.deletedCount = deletedCount }
}

// MARK: - Daemon version

/// Version string surfaced by `daemon.status`. Embedded into the binary at
/// build time; for now a literal constant updated alongside releases.
public enum DaemonVersion {
    public static let current = "0.5.2-phase4.x"
}
