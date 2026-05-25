import ArgumentParser
import IrisKit

@main
struct IrisCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iris",
        abstract: "IRIS — credentials broker CLI.",
        version: DaemonVersion.current,
        subcommands: [
            SecretCommand.self,
            StatusCommand.self,
            PauseCommand.self,
            ResumeCommand.self,
            CACommand.self,
            ConfigCommand.self,
            RuleCommand.self,
            LogsCommand.self,
        ]
    )
}
