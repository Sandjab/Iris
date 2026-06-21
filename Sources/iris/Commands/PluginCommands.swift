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
            Info.self,
            Enable.self,
            Disable.self,
            Remove.self,
            Reorder.self,
        ]
    )
}

extension PluginCommand {
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

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show a plugin's manifest and state."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(.pluginInfo, params: PluginIdParams(id: id), returning: Plugin.self)
            }
            let caps = plugin.approvedCapabilities
            let humanText = """
                id:       \(plugin.manifest.id)
                name:     \(plugin.manifest.name)
                version:  \(plugin.manifest.version)
                state:    \(plugin.displayState.rawValue)
                order:    \(plugin.order)
                hash:     \(plugin.hashMatches ? "ok" : "CHANGED — re-approval required")
                network:  \(caps?.network.joined(separator: ", ") ?? "(not approved)")
                files:    \(caps?.filesystem.joined(separator: ", ") ?? "(not approved)")
                """
            try Output.print(humanText: humanText, jsonValue: plugin, json: json)
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: "Approve capabilities and enable a plugin."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(
                    .pluginEnable,
                    params: PluginIdParams(id: id),
                    returning: Plugin.self
                )
            }
            try Output.print(humanText: "enabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: "Disable a plugin."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(
                    .pluginDisable,
                    params: PluginIdParams(id: id),
                    returning: Plugin.self
                )
            }
            try Output.print(humanText: "disabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove an installed plugin."
        )

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json: Bool = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(
                    .pluginRemove,
                    params: PluginIdParams(id: id),
                    returning: PluginRemovedResult.self
                )
            }
            try Output.print(
                humanText: result.removed ? "removed \(id)" : "not removed",
                jsonValue: result,
                json: json
            )
        }
    }

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
