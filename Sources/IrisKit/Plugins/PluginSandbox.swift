import Foundation

/// Launches a plugin executable confined by a generated Seatbelt profile, via
/// the `iris-sandbox-exec` shim. P2a: spawn + caller waits/owns the process.
/// P2b wraps this in the warm-process lifecycle with NDJSON IPC pipes.
public struct PluginSandbox: Sendable {
    /// Path to the `iris-sandbox-exec` binary. Production resolves it next to
    /// the running daemon executable; tests inject the built-products path.
    let shimPath: URL

    public init(shimPath: URL) {
        self.shimPath = shimPath
    }

    /// Writes `profile` to a temp file and spawns the shim, which applies the
    /// sandbox then execs `executable`. The temp profile file is removed when
    /// the process terminates. The caller owns the returned `Process`.
    public func launch(
        executable: String,
        arguments: [String] = [],
        profile: String,
        standardOutput: Pipe? = nil,
        standardError: Pipe? = nil
    ) throws -> Process {
        let profileURL =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugin-\(UUID().uuidString).sb")
        try profile.write(to: profileURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = shimPath
        process.arguments = [profileURL.path, executable] + arguments
        if let standardOutput {
            process.standardOutput = standardOutput
        }
        if let standardError {
            process.standardError = standardError
        }
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: profileURL)
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: profileURL)
            throw error
        }
        return process
    }
}
