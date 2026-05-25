import ArgumentParser
import IrisKit

struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause substitution (idempotent)."
    )

    @OptionGroup var connection: ConnectionOptions
    @Flag(name: .customLong("json")) var json: Bool = false

    mutating func run() async throws {
        let result = try await withAdminClient(connection) { client in
            try await client.call(.daemonPause, returning: DaemonPauseResult.self)
        }
        try Output.print(humanText: result.paused ? "paused" : "running", jsonValue: result, json: json)
    }
}

struct ResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume substitution (idempotent)."
    )

    @OptionGroup var connection: ConnectionOptions
    @Flag(name: .customLong("json")) var json: Bool = false

    mutating func run() async throws {
        let result = try await withAdminClient(connection) { client in
            try await client.call(.daemonResume, returning: DaemonPauseResult.self)
        }
        try Output.print(humanText: result.paused ? "paused" : "running", jsonValue: result, json: json)
    }
}
