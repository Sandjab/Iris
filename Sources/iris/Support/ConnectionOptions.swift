import ArgumentParser
import Foundation
import IrisKit

/// `ExitCode` map shared by every `iris` subcommand. Mirrors design §4.2.
enum IrisExitCode {
    static let success: Int32 = 0
    static let logicError: Int32 = 1
    static let daemonUnreachable: Int32 = 2
    static let ioError: Int32 = 3
    static let usage: Int32 = 64  // EX_USAGE
}

/// Surfaces a daemon-unreachable failure with the canonical message before
/// re-throwing as `ExitCode` to short-circuit ArgumentParser.
struct DaemonUnreachable: Error, CustomStringConvertible {
    let socketPath: String
    var description: String {
        "irisd not running. Try: launchctl kickstart -k gui/$UID/io.iris.daemon\n"
            + "  socket: \(socketPath)"
    }
}

/// Option group shared by every subcommand that talks to the daemon.
struct ConnectionOptions: ParsableArguments {
    @Option(
        name: .customLong("socket-path"),
        help: "Path to the admin Unix socket (defaults to ~/Library/Application Support/iris/admin.sock)."
    )
    var socketPath: String?

    @Option(
        name: .customLong("config-path"),
        help: "Read socket path from the TOML config file at this path instead of the default."
    )
    var configPath: String?

    /// Resolves the effective socket path: `--socket-path` > `--config-path` >
    /// `Config.default.broker.expandedAdminSocket`.
    func resolvedSocketPath() throws -> String {
        if let explicit = socketPath, !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let cfgPath = configPath {
            let url = URL(fileURLWithPath: (cfgPath as NSString).expandingTildeInPath)
            let cfg = try ConfigLoader.load(from: url)
            return cfg.broker.expandedAdminSocket
        }
        return Config.default.broker.expandedAdminSocket
    }
}

/// Wraps the lifecycle of an `AdminClient`. Translates connection failures
/// into `DaemonUnreachable` so callers can return `ExitCode(2)`. Single
/// outer do-catch: success path shuts down then returns; error path
/// shuts down (best-effort) then maps `connectFailed` before rethrowing.
func withAdminClient<T: Sendable>(
    _ options: ConnectionOptions,
    body: (AdminClient) async throws -> T
) async throws -> T {
    let path = try options.resolvedSocketPath()
    let client = AdminClient(socketPath: path)
    do {
        let result = try await body(client)
        try await client.shutdown()
        return result
    } catch {
        try? await client.shutdown()
        if let adminErr = error as? AdminClientError, case .connectFailed = adminErr {
            throw DaemonUnreachable(socketPath: path)
        }
        throw error
    }
}
