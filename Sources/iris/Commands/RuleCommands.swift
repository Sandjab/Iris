import ArgumentParser
import Foundation

private func emitNotImplemented(_ command: String) -> Never {
    FileHandle.standardError.write(
        Data(
            "iris \(command): not implemented in Phase 5 (tracked in Phase 4.x — see SPECS §4.3)\n"
                .utf8
        )
    )
    Foundation.exit(IrisExitCode.usage)
}

struct RuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rule",
        abstract:
            "Manage MITM whitelist rules (Phase 4.x — not yet implemented).",
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a MITM rule (Phase 4.x)."
        )
        @Argument var host: String
        mutating func run() async throws { emitNotImplemented("rule add") }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List MITM rules (Phase 4.x)."
        )
        mutating func run() async throws { emitNotImplemented("rule list") }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a MITM rule (Phase 4.x)."
        )
        @Argument var host: String
        mutating func run() async throws { emitNotImplemented("rule rm") }
    }
}
