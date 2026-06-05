import ArgumentParser
import Foundation
import IrisKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect, change, or reload the daemon configuration.",
        subcommands: [Get.self, Set.self, Reload.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the daemon's loaded configuration."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let config = try await withAdminClient(connection) { client in
                try await client.call(.configGet, returning: Config.self)
            }
            let humanText: String = {
                var lines: [String] = []
                lines.append("version = \(config.version)")
                lines.append("")
                lines.append("[broker]")
                lines.append("listen = \"\(config.broker.listen)\"")
                lines.append("events_listen = \"\(config.broker.eventsListen)\"")
                lines.append("admin_socket = \"\(config.broker.adminSocket)\"")
                lines.append("log_level = \"\(config.broker.logLevel.rawValue)\"")
                lines.append("event_retention_days = \(config.broker.eventRetentionDays)")
                lines.append("event_ring_size = \(config.broker.eventRingSize)")
                lines.append("")
                lines.append("[security]")
                lines.append(
                    "on_exfil_attempt = \"\(config.security.onExfilAttempt.rawValue)\""
                )
                lines.append(
                    "max_substitutions_per_minute = \(config.security.maxSubstitutionsPerMinute)"
                )
                lines.append("")
                lines.append("[backups]")
                lines.append("max_count = \(config.backups.maxCount)")
                lines.append("")
                for entry in config.hosts.sorted(by: { $0.host < $1.host }) {
                    lines.append("[[hosts]]")
                    lines.append("host = \"\(entry.host)\"")
                    lines.append("origin = \"\(entry.origin.rawValue)\"")
                    lines.append("")
                }
                return lines.joined(separator: "\n")
            }()
            try Output.print(humanText: humanText, jsonValue: config, json: json)
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a configuration value (e.g. security.on_exfil_attempt block_only)."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Config key (dot-path), e.g. security.max_substitutions_per_minute.")
        var key: String
        @Argument(help: "New value.")
        var value: String
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let params = ConfigSetParams(updates: [.init(key: key, value: value)])
            let result = try await withAdminClient(connection) { client in
                try await client.call(.configSet, params: params, returning: ConfigSetResult.self)
            }
            var lines: [String] = []
            if !result.applied.isEmpty {
                lines.append("applied: \(result.applied.joined(separator: ", "))")
            }
            if !result.requiresRestart.isEmpty {
                lines.append("requires restart: \(result.requiresRestart.joined(separator: ", "))")
            }
            try Output.print(
                humanText: lines.joined(separator: "\n") + "\n",
                jsonValue: result,
                json: json
            )
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reload",
            abstract: "Reload daemon config from config.json (equivalent to SIGHUP)."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(.configReload, returning: ConfigReloadResult.self)
            }
            if !result.ignored.isEmpty {
                let warning =
                    "warning: ignored structural changes (restart required): "
                    + "\(result.ignored.joined(separator: ", "))\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            try Output.print(
                humanText: "reloaded: \(result.reloaded)\n",
                jsonValue: result,
                json: json
            )
        }
    }
}
