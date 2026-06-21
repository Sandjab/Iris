import Foundation
import Logging

/// Everything `PluginHost` needs to launch one plugin process. Built by the
/// manager from a `Plugin` view (manifest + approved state).
public struct PluginLaunchSpec: Sendable {
    public let id: String
    public let executablePath: String
    public let capabilities: PluginCapabilities
    public let configValues: [String: String]
    /// Canonical (realpath-resolved) private scratch dir; created by the manager.
    public let scratchDir: URL

    public init(
        id: String,
        executablePath: String,
        capabilities: PluginCapabilities,
        configValues: [String: String],
        scratchDir: URL
    ) {
        self.id = id
        self.executablePath = executablePath
        self.capabilities = capabilities
        self.configValues = configValues
        self.scratchDir = scratchDir
    }
}

public enum PluginHostError: Error, Equatable {
    case notRunning
    case timeout(String)
    case initializeRejected
    case malformedResponse
}

/// Owns a single warm plugin process and its NDJSON IPC channel. Spawns via
/// `PluginSandbox` (Seatbelt shim), runs the `initialize` handshake, keeps the
/// process warm, and shuts it down gracefully (shutdown notification → SIGTERM →
/// SIGKILL). Unexpected exits are reported to the manager via `onUnexpectedExit`.
public actor PluginHost {
    public struct Timeouts: Sendable {
        public let initialize: TimeInterval
        public let shutdown: TimeInterval
        public init(initialize: TimeInterval = 5, shutdown: TimeInterval = 2) {
            self.initialize = initialize
            self.shutdown = shutdown
        }
    }

    private let spec: PluginLaunchSpec
    private let sandbox: PluginSandbox
    private let timeouts: Timeouts
    private let logger: Logger
    private let onUnexpectedExit: @Sendable (String) async -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader: PluginLineReader?
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var stopping = false
    private var started = false

    public init(
        spec: PluginLaunchSpec,
        sandbox: PluginSandbox,
        timeouts: Timeouts = Timeouts(),
        logger: Logger,
        onUnexpectedExit: @escaping @Sendable (String) async -> Void
    ) {
        self.spec = spec
        self.sandbox = sandbox
        self.timeouts = timeouts
        self.logger = logger
        self.onUnexpectedExit = onUnexpectedExit
    }

    public nonisolated var id: String { spec.id }

    /// Spawns the sandboxed process and performs the `initialize` handshake.
    /// Throws (and tears down) if the process fails to start or does not confirm
    /// `ready` within the initialize timeout.
    public func start() async throws {
        let profile = PluginSandboxProfile.generate(
            capabilities: spec.capabilities,
            scratchDir: spec.scratchDir.path
        )
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let process = try sandbox.launch(
            executable: spec.executablePath,
            arguments: [],
            profile: profile,
            currentDirectory: spec.scratchDir,
            standardInput: stdin,
            standardOutput: stdout,
            standardError: stderr
        )
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        let reader = PluginLineReader(
            fileDescriptor: stdout.fileHandleForReading.fileDescriptor,
            onLine: { [weak self] line in
                guard let self else { return }
                Task { await self.handleLine(line) }
            },
            onEOF: { [weak self] in
                guard let self else { return }
                Task { await self.handleEOF() }
            }
        )
        reader.start()
        self.reader = reader

        // Drain stderr at debug; plugin stderr is opaque (the plugin never sees
        // secrets) but we never parse it as protocol data.
        let id = spec.id
        let logger = self.logger
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            logger.debug(
                "plugin stderr",
                metadata: ["id": "\(id)", "bytes": "\(data.count)"]
            )
        }

        // Chain, don't overwrite: PluginSandbox.launch installed a handler that
        // deletes the temp profile file on exit. Overwriting it leaks the .sb.
        let previousHandler = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            previousHandler?(proc)
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        // Any post-spawn failure (timeout, error response, bad/false result)
        // must tear the process down — otherwise a half-initialised plugin leaks.
        do {
            let response = try await send(
                method: PluginRPC.Method.initialize,
                params: PluginRPC.InitializeParams(
                    apiVersion: PluginManifest.supportedApiVersion,
                    configValues: spec.configValues,
                    capabilities: spec.capabilities,
                    scratchDir: spec.scratchDir.path
                ),
                timeout: timeouts.initialize
            )
            guard let result = response.result else {
                throw PluginHostError.initializeRejected
            }
            let initialized = try result.decode(as: PluginRPC.InitializeResult.self)
            guard initialized.ready else {
                throw PluginHostError.initializeRejected
            }
            logger.info("plugin initialized", metadata: ["id": "\(spec.id)"])
            started = true
        } catch {
            await teardown()
            throw error
        }
    }

    /// Graceful stop: send `shutdown`, wait, escalate to SIGTERM then SIGKILL.
    /// Idempotent; sets `stopping` so the termination handler does not report an
    /// unexpected exit.
    public func shutdown() async {
        guard let process, process.isRunning else {
            await teardown()
            return
        }
        stopping = true
        if let line = try? PluginRPC.encodeNotification(method: PluginRPC.Method.shutdown) {
            try? stdinHandle?.write(contentsOf: Data(line.utf8))
        }
        _ = await waitForExit(within: timeouts.shutdown)
        await teardown()  // escalates SIGTERM→SIGKILL if still running
    }

    /// Sends one `on_request` and returns the typed result. Throws
    /// `PluginHostError.timeout` on deadline, `PluginHostError.notRunning` if the
    /// process is gone, or the plugin's JSON-RPC error if it reported one.
    public func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
    {
        guard started else { throw PluginHostError.notRunning }
        let response = try await send(method: PluginRPC.Method.onRequest, params: params, timeout: timeout)
        if let error = response.error { throw error }
        guard let result = response.result else { throw PluginHostError.malformedResponse }
        return try result.decode(as: PluginRPC.OnRequestResult.self)
    }

    // MARK: - IPC

    private func send<P: Encodable>(method: String, params: P, timeout: TimeInterval) async throws
        -> JSONRPCResponse
    {
        let id = nextID
        nextID += 1
        let line = try PluginRPC.encodeRequest(method: method, params: params, id: id)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.failPending(id: id, error: PluginHostError.timeout(method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // Registration happens-before any handleLine (both run on this actor),
            // so a fast reply cannot be missed.
            pending[id] = continuation
            do {
                guard let stdinHandle else { throw PluginHostError.notRunning }
                try stdinHandle.write(contentsOf: Data(line.utf8))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let response = try? PluginRPC.decodeResponse(line) else {
            logger.debug("plugin sent unparseable line", metadata: ["id": "\(spec.id)"])
            return
        }
        guard case .integer(let id) = response.id,
            let continuation = pending.removeValue(forKey: id)
        else {
            return  // unsolicited / unknown id
        }
        continuation.resume(returning: response)
    }

    private func failPending(id: Int64, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func handleEOF() {
        // stdout closed; the process is exiting. terminationHandler does the
        // restart bookkeeping — here we just fail any in-flight requests.
        failAllPending(error: PluginHostError.notRunning)
    }

    private func failAllPending(error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    private func handleTermination() async {
        failAllPending(error: PluginHostError.notRunning)
        // Report unexpected exits ONLY for a host that completed startup. A death
        // during start() is surfaced via the thrown error (the manager counts it
        // once via its startHost catch) — reporting here too would double-count
        // the crash and spawn concurrent restart chains.
        guard started, !stopping else { return }
        await onUnexpectedExit(spec.id)
    }

    // MARK: - Helpers

    /// Polls the process up to `seconds` for exit. Uses `Task.sleep` (no
    /// `Thread.sleep`); messages/exits are quick so a 20ms poll is fine.
    private func waitForExit(within seconds: TimeInterval) async -> Bool {
        let deadlineSteps = max(1, Int(seconds / 0.02))
        for _ in 0..<deadlineSteps {
            if process?.isRunning != true { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return process?.isRunning != true
    }

    private func teardown() async {
        // Deliberate teardown: suppress the unexpected-exit callback that the
        // chained terminationHandler would otherwise fire when we kill below.
        stopping = true
        if let process, process.isRunning {
            process.terminate()  // SIGTERM
            if await waitForExit(within: 1) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(within: 1)
            }
        }
        reader?.stop()
        reader = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        // The chained sandbox terminationHandler removes the temp profile on exit.
        // Best-effort scratch cleanup here.
        try? FileManager.default.removeItem(at: spec.scratchDir)
    }
}

extension PluginHost: PluginInvoking {}
