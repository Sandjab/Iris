import Foundation
import Logging

/// Single source of truth for IRIS configuration. Owns `config.json`; the daemon
/// is the only writer. Seeds the file on first run, validates before every write,
/// persists atomically (0600) and keeps timestamped backups with rotation.
///
/// Replaces `ConfigLoader` (TOML parse) and `RuntimeRulesStore` (host persistence).
public actor ConfigStore {
    public enum Error: Swift.Error, Equatable {
        case corrupted(String)  // surfaced only by reloadFromDisk (explicit); at boot we recover
        case ioError(String)
        case invalidHost(String)
        case hostProtected(String)  // delete of an origin: .builtin host
        case unknownKey(String)
        case invalidValue(field: String, value: String)
    }

    private let path: URL
    private let backupsDir: URL
    private let logger: Logger
    private var config: Config

    /// True when boot had to recover from a corrupted `config.json` (file backed up,
    /// defaults re-seeded). The daemon reads this and emits a high-severity startup alert.
    public let recoveredFromCorruption: Bool

    /// Loads `config.json`, seeds defaults if absent, or — if present but corrupted —
    /// backs up the bad file, re-seeds defaults and flags `recoveredFromCorruption`
    /// (degraded boot: daemon stays up, substitution active). Only an unrepairable I/O
    /// error (unreadable dir, full disk) throws and aborts boot.
    public init(path: URL, logger: Logger) throws {
        self.path = path
        let backupsDir = path.deletingLastPathComponent().appendingPathComponent("backups")
        self.backupsDir = backupsDir
        self.logger = logger
        let outcome = try Self.loadOrSeed(path: path, backupsDir: backupsDir, logger: logger)
        self.config = outcome.config
        self.recoveredFromCorruption = outcome.recovered
    }

    // MARK: - Read

    public var current: Config { config }

    /// Resolved path of the config file on disk (for the app's "Reveal in Finder").
    public var filePath: String { path.path }

    public func listHosts() -> [MITMRule] {
        config.hosts
            .sorted { $0.host < $1.host }
            .map { MITMRule(host: $0.host, createdAt: $0.createdAt, origin: $0.origin) }
    }

    public func allowedHosts() -> Set<String> {
        Set(config.hosts.map(\.host))
    }

    // MARK: - Host mutations (back `rule.*`)

    @discardableResult
    public func addHost(_ host: String, now: Date) throws -> MITMRule {
        guard Secret.isValidHost(host) else { throw Error.invalidHost(host) }
        if let existing = config.hosts.first(where: { $0.host == host }) {
            return MITMRule(host: existing.host, createdAt: existing.createdAt, origin: existing.origin)
        }
        let entry = HostEntry(host: host, origin: .user, createdAt: now)
        try persist(config.with(hosts: config.hosts + [entry]))
        return MITMRule(host: entry.host, createdAt: entry.createdAt, origin: entry.origin)
    }

    /// Deletes a host. Rejects `origin: .builtin` hosts (protected) with `.hostProtected`.
    /// Returns `false` if the host was not present.
    @discardableResult
    public func deleteHost(_ host: String) throws -> Bool {
        guard let entry = config.hosts.first(where: { $0.host == host }) else { return false }
        guard entry.origin == .user else { throw Error.hostProtected(host) }
        try persist(config.with(hosts: config.hosts.filter { $0.host != host }))
        return true
    }

    // MARK: - Scalar updates (back `config.set`)

    /// Hot fields take effect at runtime; structural fields persist but require a
    /// restart. Hosts are NOT settable here (use addHost/deleteHost).
    private static let hotKeys: Set<String> = [
        "security.on_exfil_attempt", "security.max_substitutions_per_minute", "backups.max_count",
    ]
    private static let structuralKeys: Set<String> = [
        "broker.listen", "broker.events_listen", "broker.admin_socket",
        "broker.event_retention_days", "broker.event_ring_size", "broker.log_level",
    ]

    /// Applies a batch of scalar updates. Builds a candidate `Config`, validates and
    /// persists it as a whole (atomic: an invalid update mutates nothing). Returns the
    /// keys applied hot vs those needing a restart. Unknown/invalid keys throw before
    /// any write.
    public func applyUpdates(_ updates: [ConfigSetParams.Update]) throws -> ConfigSetResult {
        var broker = config.broker
        var security = config.security
        var backups = config.backups
        var applied: [String] = []
        var requiresRestart: [String] = []

        for u in updates {
            switch u.key {
            case "security.on_exfil_attempt":
                guard let p = ExfilAttemptPolicy(rawValue: u.value) else {
                    throw Error.invalidValue(field: u.key, value: u.value)
                }
                security = SecurityConfig(
                    onExfilAttempt: p,
                    maxSubstitutionsPerMinute: security.maxSubstitutionsPerMinute
                )
            case "security.max_substitutions_per_minute":
                guard let n = Int(u.value) else { throw Error.invalidValue(field: u.key, value: u.value) }
                security = SecurityConfig(
                    onExfilAttempt: security.onExfilAttempt,
                    maxSubstitutionsPerMinute: n
                )
            case "backups.max_count":
                guard let n = Int(u.value) else { throw Error.invalidValue(field: u.key, value: u.value) }
                backups = BackupsConfig(maxCount: n)
            case "broker.log_level":
                guard let l = LogLevel(rawValue: u.value) else {
                    throw Error.invalidValue(field: u.key, value: u.value)
                }
                broker = Self.broker(broker, settingLogLevel: l)
            case "broker.listen":
                broker = Self.broker(broker, settingListen: u.value)
            case "broker.events_listen":
                broker = Self.broker(broker, settingEventsListen: u.value)
            case "broker.admin_socket":
                broker = Self.broker(broker, settingAdminSocket: u.value)
            case "broker.event_retention_days":
                guard let n = Int(u.value) else { throw Error.invalidValue(field: u.key, value: u.value) }
                broker = Self.broker(broker, settingRetentionDays: n)
            case "broker.event_ring_size":
                guard let n = Int(u.value) else { throw Error.invalidValue(field: u.key, value: u.value) }
                broker = Self.broker(broker, settingRingSize: n)
            default:
                throw Error.unknownKey(u.key)
            }
            if Self.hotKeys.contains(u.key) { applied.append(u.key) } else { requiresRestart.append(u.key) }
        }

        let candidate = Config(
            version: config.version,
            broker: broker,
            security: security,
            backups: backups,
            hosts: config.hosts
        )
        try persist(candidate)  // validates, backs up, writes atomically
        return ConfigSetResult(applied: applied, requiresRestart: requiresRestart)
    }

    // BrokerConfig has immutable lets; these helpers rebuild it field-by-field.
    private static func broker(_ b: BrokerConfig, settingLogLevel v: LogLevel) -> BrokerConfig {
        BrokerConfig(
            listen: b.listen,
            eventsListen: b.eventsListen,
            adminSocket: b.adminSocket,
            logLevel: v,
            eventRetentionDays: b.eventRetentionDays,
            eventRingSize: b.eventRingSize
        )
    }
    private static func broker(_ b: BrokerConfig, settingListen v: String) -> BrokerConfig {
        BrokerConfig(
            listen: v,
            eventsListen: b.eventsListen,
            adminSocket: b.adminSocket,
            logLevel: b.logLevel,
            eventRetentionDays: b.eventRetentionDays,
            eventRingSize: b.eventRingSize
        )
    }
    private static func broker(_ b: BrokerConfig, settingEventsListen v: String) -> BrokerConfig {
        BrokerConfig(
            listen: b.listen,
            eventsListen: v,
            adminSocket: b.adminSocket,
            logLevel: b.logLevel,
            eventRetentionDays: b.eventRetentionDays,
            eventRingSize: b.eventRingSize
        )
    }
    private static func broker(_ b: BrokerConfig, settingAdminSocket v: String) -> BrokerConfig {
        BrokerConfig(
            listen: b.listen,
            eventsListen: b.eventsListen,
            adminSocket: v,
            logLevel: b.logLevel,
            eventRetentionDays: b.eventRetentionDays,
            eventRingSize: b.eventRingSize
        )
    }
    private static func broker(_ b: BrokerConfig, settingRetentionDays v: Int) -> BrokerConfig {
        BrokerConfig(
            listen: b.listen,
            eventsListen: b.eventsListen,
            adminSocket: b.adminSocket,
            logLevel: b.logLevel,
            eventRetentionDays: v,
            eventRingSize: b.eventRingSize
        )
    }
    private static func broker(_ b: BrokerConfig, settingRingSize v: Int) -> BrokerConfig {
        BrokerConfig(
            listen: b.listen,
            eventsListen: b.eventsListen,
            adminSocket: b.adminSocket,
            logLevel: b.logLevel,
            eventRetentionDays: b.eventRetentionDays,
            eventRingSize: v
        )
    }

    // MARK: - Reload (manual file edit)

    /// Re-read the file from disk and adopt it. Returns the new config. A parse
    /// failure surfaces as `.corrupted` (the caller maps it to an RPC error); the
    /// on-disk file is left untouched (no degraded re-seed on the explicit path).
    public func reloadFromDisk() throws -> Config {
        let reloaded = try Self.load(path: path)
        try reloaded.validate()
        config = reloaded
        return reloaded
    }

    // MARK: - Loading

    private struct LoadOutcome {
        let config: Config
        let recovered: Bool
    }

    private static func loadOrSeed(path: URL, backupsDir: URL, logger: Logger) throws -> LoadOutcome {
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                return LoadOutcome(config: try load(path: path), recovered: false)
            } catch Error.corrupted(let msg) {
                // Degraded boot: back up the corrupted file, re-seed defaults, flag recovery.
                // An unrepairable Error.ioError from load() (or backup) propagates → boot aborts.
                logger.error(
                    "config.json corrupted — backing up and re-seeding defaults",
                    metadata: ["error": "\(msg)"]
                )
                try backupCorruptedFile(path: path, backupsDir: backupsDir)
                return LoadOutcome(config: try seedDefaults(to: path, logger: logger), recovered: true)
            }
        }
        logger.info("config.json absent — seeding from defaults", metadata: ["path": "\(path.path)"])
        return LoadOutcome(config: try seedDefaults(to: path, logger: logger), recovered: false)
    }

    private static func seedDefaults(to path: URL, logger: Logger) throws -> Config {
        let seed = Config.default.with(
            hosts: Config.default.hosts.map { HostEntry(host: $0.host, origin: $0.origin, createdAt: Date()) }
        )
        try seed.validate()
        try writeAtomic(seed, to: path)
        return seed
    }

    /// Copy a corrupted config aside (`config-corrupted-<stamp>.json`) before re-seeding,
    /// so it stays recoverable. Failure here is an unrepairable I/O situation → abort boot.
    private static func backupCorruptedFile(path: URL, backupsDir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            let stamp = timestampFormatter.string(from: Date())
            let dest = backupsDir.appendingPathComponent("config-corrupted-\(stamp).json")
            let data = try Data(contentsOf: path)
            try data.write(to: dest, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: dest.path
            )
        } catch {
            throw Error.ioError("backup of corrupted config failed: \(error)")
        }
    }

    private static func load(path: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw Error.ioError("read failed: \(error)")
        }
        do {
            return try makeDecoder().decode(Config.self, from: data)
        } catch {
            // Parse failure → .corrupted. Boot recovers (backup+reseed via loadOrSeed);
            // reloadFromDisk (explicit) surfaces it as an RPC error without touching the file.
            throw Error.corrupted("config.json parse failed: \(error)")
        }
    }

    // MARK: - Persistence + backups

    /// Validate → backup current on-disk file → write new atomically → rotate.
    func persist(_ newConfig: Config) throws {
        try newConfig.validate()
        try backupCurrentFile(maxCount: newConfig.backups.maxCount)
        try Self.writeAtomic(newConfig, to: path)
        config = newConfig
    }

    /// Copy the current on-disk file into `backups/config-<stamp>.json`, then prune
    /// oldest beyond `maxCount`. Backup failure aborts the save.
    private func backupCurrentFile(maxCount: Int) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            let stamp = Self.timestampFormatter.string(from: Date())
            // A short suffix guarantees uniqueness if two saves land in the same
            // millisecond; the timestamp prefix still drives chronological sort.
            let suffix = UUID().uuidString.prefix(8)
            let dest = backupsDir.appendingPathComponent("config-\(stamp)-\(suffix).json")
            let data = try Data(contentsOf: path)
            try data.write(to: dest, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: dest.path
            )
            try rotateBackups(maxCount: maxCount)
        } catch {
            throw Error.ioError("backup failed: \(error)")
        }
    }

    private func rotateBackups(maxCount: Int) throws {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        // Only routine `config-<stamp>.json` backups rotate. `config-corrupted-*`
        // copies are preserved on purpose — they may be the only recoverable copy.
        let backups =
            files
            .filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") && !$0.hasPrefix("config-corrupted-") }
            .sorted()  // timestamp in the name sorts chronologically
        guard backups.count > maxCount else { return }
        for name in backups.prefix(backups.count - maxCount) {
            try? FileManager.default.removeItem(at: backupsDir.appendingPathComponent(name))
        }
    }

    private static func writeAtomic(_ config: Config, to path: URL) throws {
        let data: Data
        do {
            data = try makeEncoder().encode(config)
        } catch {
            throw Error.ioError("encode failed: \(error)")
        }
        let parent = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: tmp.path
            )
            // `replaceItemAt` requires an existing destination on some macOS
            // versions (fails NSFileReadNoSuchFileError otherwise) — the seed
            // path has none yet, so move into place when the file is absent.
            // Both paths preserve the 0600 already set on `tmp`.
            if FileManager.default.fileExists(atPath: path.path) {
                _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: path)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.ioError("write failed: \(error)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Fresh formatter per call — `ISO8601DateFormatter` is a non-Sendable class,
    /// so a shared static instance isn't concurrency-safe under strict concurrency.
    /// Fractional seconds keep two saves in the same wall-clock second from
    /// colliding on the backup filename; lexicographic order == chronological.
    private static var timestampFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [
            .withYear, .withMonth, .withDay, .withTime, .withTimeZone, .withFractionalSeconds,
        ]
        return f
    }
}
