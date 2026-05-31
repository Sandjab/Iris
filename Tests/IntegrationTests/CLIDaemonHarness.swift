import Foundation
import XCTest

// MARK: - Harness

/// Spawns an ephemeral `irisd` instance with in-memory stores and provides
/// a helper to invoke the `iris` binary against it. Cleans up the temp
/// directory and admin socket on `stop()`.
///
/// Port selection: Config validation rejects port 0; we claim two adjacent
/// ephemeral ports from the high range (49152–65535) derived from a random
/// UUID prefix. Collisions are possible but vanishingly rare in CI.
final class CLIDaemonHarness {
    let tmpDir: URL
    let configPath: String
    let adminSocket: String
    /// The port on which irisd's broker proxy is listening.
    let brokerPort: Int
    private(set) var process: Process?

    init() throws {
        // Keep the socket path short: Darwin UDS cap is 104 bytes including NUL.
        // Use /tmp/<8-char UUID prefix> to stay well under the limit.
        let shortID = UUID().uuidString.prefix(8)
        let base = URL(fileURLWithPath: "/tmp/iris-cli-\(shortID)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.tmpDir = base
        // admin.sock sits under the short base path — still under 104 bytes.
        self.adminSocket = base.appendingPathComponent("admin.sock").path
        self.configPath = base.appendingPathComponent("iris.toml").path

        // Derive two adjacent ports from the short ID to reduce collision
        // probability across parallel test runs. Range: 49152–65000.
        let seed = shortID.utf8.reduce(0 as UInt32) { acc, byte in acc &* 31 &+ UInt32(byte) }
        let basePort = 49152 + Int(seed % 15848)
        let proxyPort = basePort
        let eventsPort = basePort + 1
        self.brokerPort = proxyPort

        let toml = """
            [broker]
            listen               = "127.0.0.1:\(proxyPort)"
            events_listen        = "127.0.0.1:\(eventsPort)"
            admin_socket         = "\(adminSocket)"
            log_level            = "error"
            event_retention_days = 1
            event_ring_size      = 100

            [security]
            on_exfil_attempt             = "block_only"
            max_substitutions_per_minute = 60

            [[mitm_host]]
            host = "api.anthropic.com"
            """
        try toml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Lifecycle

    func start() throws {
        let p = Process()
        p.executableURL = ExecutableLocator.irisd
        p.arguments = [
            "--foreground",
            "--config-path", configPath,
            "--in-memory-secrets",
            "--in-memory-ca",
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        self.process = p
        try waitForSocketReady(timeout: 5.0)
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Test helper: terminate the ephemeral daemon to simulate a crash.
    /// Does NOT delete tmpDir so the socket path is preserved for `restartDaemon()`.
    /// Uses SIGTERM with a SIGKILL fallback so CI never hangs.
    func stopDaemon() {
        guard let p = process else { return }
        p.terminate()
        let limit = Date().addingTimeInterval(5.0)
        while p.isRunning && Date() < limit {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        p.waitUntilExit()
        process = nil
        // Remove the stale socket so the daemon can rebind on restart.
        try? FileManager.default.removeItem(atPath: adminSocket)
    }

    /// Test helper: relaunch the daemon on the same admin socket path.
    /// The socket path doesn't move because it was computed in `init` and stored.
    func restartDaemon() throws {
        try start()
    }

    // MARK: - Socket readiness

    private func waitForSocketReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: adminSocket) {
                // Give the server one extra tick to finish binding.
                Thread.sleep(forTimeInterval: 0.05)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Capture irisd stderr to aid diagnosis before throwing.
        if let p = process,
            let pipe = p.standardError as? Pipe
        {
            let errData = pipe.fileHandleForReading.availableData
            let errText = String(data: errData, encoding: .utf8) ?? "<unreadable>"
            throw CLIDaemonHarnessError.timeout(
                "admin socket not ready at \(adminSocket)\nirisd stderr:\n\(errText)"
            )
        }
        throw CLIDaemonHarnessError.timeout("admin socket not ready at \(adminSocket)")
    }

    // MARK: - iris invocation

    /// Invokes `iris` with the exact `args` provided — no `--socket-path`
    /// injection. Use for subcommands that have no `ConnectionOptions`
    /// (e.g. `mcp unwrap`).
    @discardableResult
    func runIrisRaw(
        _ args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 10.0
    ) throws -> (stdout: String, stderr: String, code: Int32) {
        let p = Process()
        p.executableURL = ExecutableLocator.iris
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil {
            p.standardInput = inPipe
        }
        try p.run()
        if let stdinData = stdin {
            inPipe.fileHandleForWriting.write(stdinData)
            try inPipe.fileHandleForWriting.close()
        }

        let limitDate = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < limitDate {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
        }
        p.waitUntilExit()

        let out =
            String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err =
            String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    }

    /// Invokes `iris` with `--socket-path <adminSocket>` injected immediately
    /// after the first element of `args` (the subcommand chain). Example:
    ///
    ///   runIris(["secret", "add", "foo", ...])
    ///   → iris secret add --socket-path <path> foo ...
    ///
    /// `--socket-path` lives on the leaf subcommand's `ConnectionOptions`
    /// option group, not on the root `iris` command.
    @discardableResult
    func runIris(
        _ args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 10.0
    ) throws -> (stdout: String, stderr: String, code: Int32) {
        // Find the position of the first non-subcommand argument (i.e., the
        // first element that starts with "--" or is not one of the known
        // subcommand words). All known subcommand words come first; inject
        // --socket-path right after them.
        let subcommandWords: Set<String> = [
            "secret", "add", "list", "show", "edit", "rotate", "rm", "quarantine", "unquarantine",
            "status", "pause", "resume", "ca", "get", "reload",
            "config", "rule", "logs", "doctor",
            "mcp", "wrap",
        ]
        var insertAt = 0
        while insertAt < args.count && subcommandWords.contains(args[insertAt]) {
            insertAt += 1
        }
        var fullArgs = args
        fullArgs.insert(contentsOf: ["--socket-path", adminSocket], at: insertAt)

        let p = Process()
        p.executableURL = ExecutableLocator.iris
        p.arguments = fullArgs
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil {
            p.standardInput = inPipe
        }
        try p.run()
        if let stdinData = stdin {
            inPipe.fileHandleForWriting.write(stdinData)
            try inPipe.fileHandleForWriting.close()
        }

        let limitDate = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < limitDate {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
        }
        p.waitUntilExit()

        let out =
            String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err =
            String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    }

    // MARK: - Background iris invocation

    /// Background handle for long-running `iris` invocations (e.g. `--watch`).
    /// Caller can read stderr line-by-line, send SIGINT, and wait for exit.
    final class BackgroundIris {
        let process: Process
        let stderrPipe: Pipe
        let stdoutPipe: Pipe

        init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
            self.process = process
            self.stderrPipe = stderrPipe
            self.stdoutPipe = stdoutPipe
        }

        func sendSIGINT() {
            kill(process.processIdentifier, SIGINT)
        }

        func waitForExit(timeout: TimeInterval) -> Int32? {
            let limit = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < limit {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                // Defensive: if the child ignores SIGTERM, fall back to SIGKILL
                // after a short grace period so CI never hangs.
                let killLimit = Date().addingTimeInterval(2.0)
                while process.isRunning && Date() < killLimit {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return nil
            }
            return process.terminationStatus
        }

        func readAllStderr() -> String {
            String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        }
    }

    /// Launches `iris` with `--socket-path` injected and returns immediately.
    /// Use for long-running subcommands like `mcp wrap --watch`.
    func runIrisBackground(_ args: [String]) throws -> BackgroundIris {
        let subcommandWords: Set<String> = [
            "secret", "add", "list", "show", "edit", "rotate", "rm", "quarantine", "unquarantine",
            "status", "pause", "resume", "ca", "get", "reload",
            "config", "rule", "logs", "doctor",
            "mcp", "wrap",
        ]
        var insertAt = 0
        while insertAt < args.count && subcommandWords.contains(args[insertAt]) {
            insertAt += 1
        }
        var fullArgs = args
        fullArgs.insert(contentsOf: ["--socket-path", adminSocket], at: insertAt)

        let p = Process()
        p.executableURL = ExecutableLocator.iris
        p.arguments = fullArgs
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        return BackgroundIris(process: p, stdoutPipe: outPipe, stderrPipe: errPipe)
    }
}

// MARK: - Error

enum CLIDaemonHarnessError: Error {
    case timeout(String)
}
