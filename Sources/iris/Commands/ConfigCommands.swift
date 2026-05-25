import ArgumentParser
import Foundation
import IrisKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect or reload the daemon configuration.",
        subcommands: [Get.self]
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
                lines.append("[broker]")
                lines.append("listen = \"\(config.broker.listen)\"")
                lines.append("events_listen = \"\(config.broker.eventsListen)\"")
                lines.append("admin_socket = \"\(config.broker.adminSocket)\"")
                lines.append("log_level = \"\(config.broker.logLevel.rawValue)\"")
                lines.append("event_retention_days = \(config.broker.eventRetentionDays)")
                lines.append("event_ring_size = \(config.broker.eventRingSize)")
                lines.append("")
                lines.append("[security]")
                lines.append("on_exfil_attempt = \"\(config.security.onExfilAttempt.rawValue)\"")
                lines.append("max_substitutions_per_minute = \(config.security.maxSubstitutionsPerMinute)")
                lines.append("")
                lines.append("[mitm_host]")
                for entry in config.mitmHosts {
                    lines.append("host = \"\(entry.host)\"")
                }
                return lines.joined(separator: "\n")
            }()
            try Output.print(humanText: humanText, jsonValue: config, json: json)
        }
    }
}
