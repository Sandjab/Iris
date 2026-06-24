import ArgumentParser
import Foundation
import IrisKit

struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins (out-of-process request/response hooks).",
        subcommands: [
            List.self,
            Install.self,
            Pack.self,
            Info.self,
            Enable.self,
            Disable.self,
            Remove.self,
            Reorder.self,
        ]
    )
}

extension PluginCommand {
    // MARK: - plugin list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List installed plugins."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugins = try await withAdminClient(connection) { client in
                try await client.call(.pluginList, returning: [Plugin].self)
            }
            let humanText: String = {
                let rows = plugins.map { p in
                    [
                        p.manifest.id,
                        p.displayState.rawValue,
                        p.manifest.version,
                        "\(p.order)",
                        p.hashMatches ? "ok" : "CHANGED",
                    ]
                }
                if rows.isEmpty { return "no plugins" }
                return TextFormatter.table(
                    headers: ["ID", "STATE", "VERSION", "ORDER", "HASH"],
                    rows: rows
                )
            }()
            try Output.print(humanText: humanText, jsonValue: plugins, json: json)
        }
    }

    // MARK: - plugin install

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a plugin from a directory."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Path to the plugin source directory (containing plugin.json).")
        var path: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(
                    .pluginInstall,
                    params: PluginInstallParams(path: path),
                    returning: Plugin.self
                )
            }
            try Output.print(
                humanText:
                    "installed \(plugin.manifest.id) (disabled). Run 'iris plugin enable \(plugin.manifest.id)' to activate.",
                jsonValue: plugin,
                json: json
            )
        }
    }

    // MARK: - plugin pack

    struct Pack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pack",
            abstract: "Assemble an installable plugin bundle (no symlinks) from a built source dir."
        )

        @Argument(help: "Path to the plugin source directory (containing plugin.json).")
        var source: String
        @Option(
            name: [.customShort("o"), .customLong("output")],
            help: "Output bundle directory (default: <source-dir>/dist)."
        )
        var output: String?
        @Flag(help: "Overwrite a non-empty output directory.")
        var force: Bool = false
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        // pack is purely local: URL(fileURLWithPath:) resolves a relative path
        // against the client CWD — no RPC, so no need to send an absolute path.
        mutating func run() async throws {
            let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            let outputURL =
                output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? sourceURL.appendingPathComponent("dist")
            let bundle = try PluginPacker.pack(source: sourceURL, output: outputURL, force: force)
            try Output.print(
                humanText:
                    "packed bundle at \(bundle.path)\nInstall it with: iris plugin install \"\(bundle.path)\"",
                jsonValue: PackResult(bundle: bundle.path),
                json: json
            )
        }
    }

    private struct PackResult: Encodable {
        let bundle: String
    }

    // MARK: - plugin info

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show a plugin's manifest and state."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            do {
                let plugin = try await withAdminClient(connection) { client in
                    try await client.call(.pluginInfo, params: PluginIdParams(id: id), returning: Plugin.self)
                }
                let caps = plugin.approvedCapabilities
                let network = caps.map { $0.network.isEmpty ? "none" : $0.network.joined(separator: ", ") }
                let files = caps.map { $0.filesystem.isEmpty ? "none" : $0.filesystem.joined(separator: ", ") }
                let humanText = """
                    id:       \(plugin.manifest.id)
                    name:     \(plugin.manifest.name)
                    version:  \(plugin.manifest.version)
                    state:    \(plugin.displayState.rawValue)
                    order:    \(plugin.order)
                    hash:     \(plugin.hashMatches ? "ok" : "CHANGED — re-approval required")
                    network:  \(network ?? "(not approved)")
                    files:    \(files ?? "(not approved)")
                    """
                try Output.print(humanText: humanText, jsonValue: plugin, json: json)
            } catch let error as JSONRPCError where error.code == JSONRPCError.pluginUnknown.code {
                try? FileHandle.standardError.write(
                    contentsOf: Data("error: unknown plugin: \(id)\n".utf8)
                )
                throw ExitCode(IrisExitCode.usage)
            }
        }
    }

    // MARK: - plugin enable

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: "Approve capabilities and enable a plugin."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            do {
                let plugin = try await withAdminClient(connection) { client in
                    try await client.call(
                        .pluginEnable,
                        params: PluginIdParams(id: id),
                        returning: Plugin.self
                    )
                }
                try Output.print(humanText: "enabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
            } catch let error as JSONRPCError where error.code == JSONRPCError.pluginHashMismatch.code {
                try? FileHandle.standardError.write(
                    contentsOf: Data(
                        "error: plugin content changed — run 'iris plugin info \(id)' then re-enable.\n".utf8
                    )
                )
                throw ExitCode(IrisExitCode.usage)
            } catch let error as JSONRPCError where error.code == JSONRPCError.pluginUnknown.code {
                try? FileHandle.standardError.write(
                    contentsOf: Data("error: unknown plugin: \(id)\n".utf8)
                )
                throw ExitCode(IrisExitCode.usage)
            }
        }
    }

    // MARK: - plugin disable

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: "Disable a plugin."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            do {
                let plugin = try await withAdminClient(connection) { client in
                    try await client.call(
                        .pluginDisable,
                        params: PluginIdParams(id: id),
                        returning: Plugin.self
                    )
                }
                try Output.print(humanText: "disabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
            } catch let error as JSONRPCError where error.code == JSONRPCError.pluginUnknown.code {
                try? FileHandle.standardError.write(
                    contentsOf: Data("error: unknown plugin: \(id)\n".utf8)
                )
                throw ExitCode(IrisExitCode.usage)
            }
        }
    }

    // MARK: - plugin rm

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove an installed plugin.",
            aliases: ["remove"]
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            do {
                let result = try await withAdminClient(connection) { client in
                    try await client.call(
                        .pluginRemove,
                        params: PluginIdParams(id: id),
                        returning: PluginRemovedResult.self
                    )
                }
                // The daemon throws `unknownPlugin` rather than returning
                // `removed: false`, so a successful response always means removed.
                try Output.print(humanText: "removed \(id)", jsonValue: result, json: json)
            } catch let error as JSONRPCError where error.code == JSONRPCError.pluginUnknown.code {
                try? FileHandle.standardError.write(
                    contentsOf: Data("error: unknown plugin: \(id)\n".utf8)
                )
                throw ExitCode(IrisExitCode.usage)
            }
        }
    }

    // MARK: - plugin reorder

    struct Reorder: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reorder",
            abstract: "Move a plugin to a position in the hook chain."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Argument(help: "Target index (0-based).") var index: Int
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugins = try await withAdminClient(connection) { client in
                try await client.call(
                    .pluginReorder,
                    params: PluginReorderParams(id: id, index: index),
                    returning: [Plugin].self
                )
            }
            let humanText = plugins.map { "\($0.order): \($0.manifest.id)" }.joined(separator: "\n")
            try Output.print(humanText: humanText, jsonValue: plugins, json: json)
        }
    }
}
