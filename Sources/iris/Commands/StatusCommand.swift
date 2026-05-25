import ArgumentParser
import Foundation
import IrisKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status."
    )

    @OptionGroup var connection: ConnectionOptions
    @Flag(name: .customLong("json")) var json: Bool = false

    mutating func run() async throws {
        let status = try await withAdminClient(connection) { client in
            try await client.call(.daemonStatus, returning: DaemonStatus.self)
        }
        try Output.print(
            humanText: TextFormatter.status(status),
            jsonValue: status,
            json: json
        )
    }
}
