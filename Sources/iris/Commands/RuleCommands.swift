import ArgumentParser
import Foundation
import IrisKit

struct RuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rule",
        abstract: "Manage MITM whitelist rules.",
        subcommands: [Add.self, List.self, Remove.self]
    )

    // MARK: - rule add

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a MITM rule (whitelist a host; origin: user)."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "DNS hostname to whitelist for MITM interception.")
        var host: String

        @Flag(name: .customLong("json"), help: "Emit JSON output.")
        var json: Bool = false

        mutating func run() async throws {
            let rule = try await withAdminClient(connection) { client in
                try await client.call(.ruleAdd, params: RuleHostParams(host: host), returning: MITMRule.self)
            }
            try Output.print(
                humanText: TextFormatter.ruleTable(rules: [rule]),
                jsonValue: rule,
                json: json
            )
        }
    }

    // MARK: - rule list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List MITM rules (default + user)."
        )

        @OptionGroup var connection: ConnectionOptions

        @Flag(name: .customLong("json"), help: "Emit JSON output.")
        var json: Bool = false

        mutating func run() async throws {
            let rules = try await withAdminClient(connection) { client in
                try await client.call(.ruleList, returning: [MITMRule].self)
            }
            try Output.print(
                humanText: TextFormatter.ruleTable(rules: rules),
                jsonValue: rules,
                json: json
            )
        }
    }

    // MARK: - rule rm

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract:
                "Remove a user-added MITM rule. Default hosts (origin: default) cannot be removed via CLI."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument var host: String

        @Flag(name: .customLong("json"), help: "Emit JSON output.")
        var json: Bool = false

        mutating func run() async throws {
            do {
                let result = try await withAdminClient(connection) { client in
                    try await client.call(
                        .ruleDelete,
                        params: RuleHostParams(host: host),
                        returning: RuleDeletedResult.self
                    )
                }
                try Output.print(
                    humanText: "deleted: \(result.deleted)",
                    jsonValue: result,
                    json: json
                )
            } catch let error as JSONRPCError where error.code == JSONRPCError.ruleProtected.code {
                FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
                throw ExitCode(IrisExitCode.usage)
            } catch let error as JSONRPCError where error.code == JSONRPCError.ruleNotFound.code {
                FileHandle.standardError.write(Data("error: rule not found: \(host)\n".utf8))
                throw ExitCode(IrisExitCode.usage)
            }
        }
    }
}
