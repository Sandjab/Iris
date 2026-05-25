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
            "Config TOML path (default ~/Library/Application Support/iris/config.toml; falls back to built-in defaults if absent)."
    )
    var configPath: String?

    @Option(
        name: .long,
        help: "CA PEM output path (default ~/Library/Application Support/iris/ca.pem)."
    )
    var caPath: String?

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

        let config = try loadConfig()
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

        logger.info(
            "Starting irisd",
            metadata: [
                "listen": "\(config.broker.listen)",
                "events_listen": "\(config.broker.eventsListen)",
                "admin_socket": "\(config.broker.adminSocket)",
                "allowed_hosts": "\(config.mitmHosts.map(\.host).sorted())",
            ]
        )

        let daemon = try await Daemon(
            config: config,
            secretBackend: inMemorySecrets ? .inMemoryFromEnvironment : .keychain,
            caBackend: inMemoryCa ? .inMemory : .keychain,
            caPath: caURL,
            logger: logger
        )
        try await daemon.run()
    }

    private func loadConfig() throws -> Config {
        if let configPath = configPath {
            let url = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
            return try ConfigLoader.load(from: url)
        }
        let defaultPath = ("~/Library/Application Support/iris/config.toml" as NSString)
            .expandingTildeInPath
        let url = URL(fileURLWithPath: defaultPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return try ConfigLoader.load(from: url)
        }
        return Config.default
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
