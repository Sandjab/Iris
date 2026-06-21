import ArgumentParser
import Foundation
import IrisKit
import Logging

@main
@available(macOS 13, *)
struct IrisDaemonCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "irisd",
        abstract: "IRIS credentials broker daemon (Phase 3 — IPC + SSE)."
    )

    @Flag(name: .long, help: "Run in foreground.")
    var foreground: Bool = false

    @Option(
        name: .long,
        help:
            "Config JSON path (default ~/Library/Application Support/iris/config.json; seeded with defaults if absent)."
    )
    var configPath: String?

    @Option(
        name: .long,
        help: "CA PEM output path (default ~/Library/Application Support/iris/ca.pem)."
    )
    var caPath: String?

    @Option(
        name: .long,
        help: "Plugins directory (default ~/Library/Application Support/iris/plugins)."
    )
    var pluginsPath: String?

    @Option(name: .long, help: "Override broker.log_level (trace|debug|info|warning|error).")
    var logLevel: String?

    @Flag(
        name: .long,
        help: "Read secrets from IRIS_SECRET_<NAME> env vars instead of the Keychain (debug)."
    )
    var inMemorySecrets: Bool = false

    @Flag(
        name: .long,
        help:
            "Generate a fresh in-memory CA on every boot instead of persisting it in the Keychain (debug)."
    )
    var inMemoryCa: Bool = false

    mutating func run() async throws {
        // Restore default disposition for SIGINT/SIGTERM as the very first
        // step. The Swift Concurrency runtime installs handlers that
        // prevent default termination (smoke-tested: `kill -INT` was a
        // no-op otherwise, including while the daemon is blocked on a
        // Keychain ACL prompt during boot). Graceful shutdown (flush
        // events, log "Proxy stopping") can come later when IPC +
        // LaunchAgent require it.
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)

        // Never let a broken pipe (e.g. a plugin subprocess that died mid-write)
        // kill the daemon. Writes to a closed pipe then fail with EPIPE (a
        // catchable error) instead of raising SIGPIPE. Standard daemon hygiene;
        // complements the per-fd F_SETNOSIGPIPE on plugin stdin. Set before any
        // plugin is spawned (Daemon() below builds the plugin host manager).
        signal(SIGPIPE, SIG_IGN)

        let resolvedConfigPath: URL =
            configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(
                fileURLWithPath: ("~/Library/Application Support/iris/config.json" as NSString)
                    .expandingTildeInPath
            )

        // Boot logger (info) until the resolved config's log level is known.
        var bootLogger = Logger(label: "io.iris.daemon")
        bootLogger.logLevel = .info
        let configStore = try ConfigStore(path: resolvedConfigPath, logger: bootLogger)
        let config = await configStore.current

        var logger = Logger(label: "io.iris.daemon")
        let level = logLevel.flatMap(Self.parseLogLevel(_:)) ?? Self.loggerLevel(from: config.broker.logLevel)
        logger.logLevel = level

        let caURL: URL
        if let caPath = caPath {
            caURL = URL(fileURLWithPath: (caPath as NSString).expandingTildeInPath)
        } else {
            let support = ("~/Library/Application Support/iris/ca.pem" as NSString)
                .expandingTildeInPath
            caURL = URL(fileURLWithPath: support)
        }

        let resolvedPluginsDir: URL =
            pluginsPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(
                fileURLWithPath: ("~/Library/Application Support/iris/plugins" as NSString)
                    .expandingTildeInPath
            )

        logger.info(
            "Starting irisd",
            metadata: [
                "listen": "\(config.broker.listen)",
                "events_listen": "\(config.broker.eventsListen)",
                "admin_socket": "\(config.broker.adminSocket)",
                "allowed_hosts": "\(config.hosts.map(\.host).sorted())",
                "config_path": "\(resolvedConfigPath.path)",
            ]
        )

        let daemon = try await Daemon(
            configStore: configStore,
            secretBackend: inMemorySecrets ? .inMemoryFromEnvironment : .keychain,
            caBackend: inMemoryCa ? .inMemory : .keychain,
            caPath: caURL,
            pluginsDirectory: resolvedPluginsDir,
            logger: logger
        )

        // Install SIGHUP handler to trigger hot reload. The token must live as
        // long as the daemon to keep the handler armed; `defer` ensures cleanup
        // even if `daemon.run()` throws.
        let sighupToken = installSIGHUP {
            Task { _ = try? await daemon.reload() }
        }
        defer { withExtendedLifetime(sighupToken) {} }

        try await daemon.run()
    }

    private static func parseLogLevel(_ raw: String) -> Logger.Level? {
        switch raw.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warning
        case "error": return .error
        default: return nil
        }
    }

    private static func loggerLevel(from level: LogLevel) -> Logger.Level {
        switch level {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warning
        case .error: return .error
        }
    }
}
