import ArgumentParser
import Darwin
import Foundation
import IrisKit

struct SecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage stored secrets (name + allowed-hosts only; values never leave the daemon).",
        subcommands: [Add.self, List.self, Show.self, Edit.self, Rotate.self, Remove.self]
    )

    // MARK: - secret add

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a new secret."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Secret name (used in placeholders as {{kc:NAME}}).")
        var name: String

        @Option(name: .customLong("allowed-hosts"), help: "Comma-separated list of allowed hostnames.")
        var allowedHostsRaw: String = ""

        @Flag(name: .customLong("value-from-stdin"), help: "Read value from stdin (preferred).")
        var valueFromStdin: Bool = false

        @Option(
            name: .customLong("value"),
            help: "Inline value (visible in shell history — prefer --value-from-stdin)."
        )
        var inlineValue: String?

        @Flag(name: .customLong("json"), help: "Emit JSON output.")
        var json: Bool = false

        mutating func run() async throws {
            let hosts: [String] =
                allowedHostsRaw
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let value: Data
            if let inline = inlineValue {
                FileHandle.standardError.write(
                    Data(
                        "warning: --value exposes the secret to shell history; prefer --value-from-stdin\n".utf8
                    )
                )
                value = try SecretReader.read(from: Data(inline.utf8))
            } else if valueFromStdin {
                let bytes = (try? FileHandle.standardInput.readToEnd()) ?? Data()
                value = try SecretReader.read(from: bytes)
            } else {
                throw ValidationError("provide --value-from-stdin or --value <v>")
            }

            let secret = try await withAdminClient(connection) { client in
                try await client.call(
                    .secretAdd,
                    params: SecretAddParams(name: name, allowedHosts: hosts, value: value),
                    returning: Secret.self
                )
            }
            try Output.print(
                humanText: "added secret \(secret.name) (hosts: \(secret.allowedHosts.joined(separator: ",")))",
                jsonValue: secret,
                json: json
            )
        }
    }

    // MARK: - secret list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List all secrets.")

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let secrets = try await withAdminClient(connection) { client in
                try await client.call(.secretList, returning: [Secret].self)
            }
            let humanText: String = {
                let rows = secrets.map { s in
                    [
                        s.name,
                        TextFormatter.uptime(seconds: UInt64(max(0, Int(Date().timeIntervalSince(s.createdAt)))))
                            + " ago",
                        s.lastUsedAt.map {
                            TextFormatter.uptime(seconds: UInt64(max(0, Int(Date().timeIntervalSince($0))))) + " ago"
                        } ?? "-",
                        String(s.usageCount),
                        s.allowedHosts.joined(separator: ","),
                    ]
                }
                if rows.isEmpty { return "no secrets" }
                return TextFormatter.table(
                    headers: ["NAME", "CREATED", "LAST_USED", "USES", "HOSTS"],
                    rows: rows
                )
            }()
            try Output.print(humanText: humanText, jsonValue: secrets, json: json)
        }
    }

    // MARK: - secret show

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a secret's metadata (never its value)."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument var name: String
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let secret = try await withAdminClient(connection) { client in
                try await client.call(
                    .secretGet,
                    params: SecretNameParams(name: name),
                    returning: Secret.self
                )
            }
            try Output.print(
                humanText:
                    "name: \(secret.name)\nhosts: \(secret.allowedHosts.joined(separator: ","))\ncreated: \(secret.createdAt)\nuses: \(secret.usageCount)",
                jsonValue: secret,
                json: json
            )
        }
    }

    // MARK: - secret edit

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Update a secret's allowed-hosts."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument var name: String
        @Option(
            name: .customLong("allowed-hosts"),
            help: "Comma-separated list of allowed hostnames (replaces existing)."
        )
        var allowedHostsRaw: String

        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let hosts =
                allowedHostsRaw
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let secret = try await withAdminClient(connection) { client in
                try await client.call(
                    .secretUpdate,
                    params: SecretUpdateParams(name: name, allowedHosts: hosts),
                    returning: Secret.self
                )
            }
            try Output.print(
                humanText: "updated \(secret.name) (hosts: \(secret.allowedHosts.joined(separator: ",")))",
                jsonValue: secret,
                json: json
            )
        }
    }

    // MARK: - secret rotate

    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Replace a secret's value (reads from stdin or TTY)."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument var name: String
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let value: Data
            if isatty(fileno(stdin)) != 0 {
                guard let prompted = readSecretFromTTY(prompt: "New value for \(name): ") else {
                    throw ValidationError("could not read from TTY")
                }
                value = try SecretReader.read(from: prompted)
            } else {
                let bytes = (try? FileHandle.standardInput.readToEnd()) ?? Data()
                value = try SecretReader.read(from: bytes)
            }
            let secret = try await withAdminClient(connection) { client in
                try await client.call(
                    .secretRotate,
                    params: SecretRotateParams(name: name, value: value),
                    returning: Secret.self
                )
            }
            try Output.print(
                humanText: "rotated \(secret.name)",
                jsonValue: secret,
                json: json
            )
        }
    }

    // MARK: - secret rm

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a secret.")

        @OptionGroup var connection: ConnectionOptions
        @Argument var name: String
        @Flag(name: .customLong("yes"), help: "Skip confirmation prompt.")
        var yes: Bool = false
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            if !yes {
                FileHandle.standardError.write(Data("Type the secret name to confirm deletion: ".utf8))
                guard let line = readLine(strippingNewline: true), line == name else {
                    throw ValidationError("confirmation mismatch; aborting")
                }
            }
            let result = try await withAdminClient(connection) { client in
                try await client.call(
                    .secretDelete,
                    params: SecretNameParams(name: name),
                    returning: SecretDeletedResult.self
                )
            }
            try Output.print(
                humanText: result.deleted ? "deleted \(name)" : "not found: \(name)",
                jsonValue: result,
                json: json
            )
        }
    }
}

/// Reads a line from a TTY without echoing characters. Uses `readpassphrase(3)`
/// (1024-byte buffer) to avoid `getpass(3)`'s 128-char truncation limit.
/// Returns `nil` if no TTY is available or the read fails.
private func readSecretFromTTY(prompt: String) -> Data? {
    var buf = [CChar](repeating: 0, count: 1024)
    guard readpassphrase(prompt, &buf, buf.count, RPP_REQUIRE_TTY) != nil else {
        return nil
    }
    return Data(String(cString: buf).utf8)
}
