import Foundation
import Logging

/// Owns every running plugin host. Reconciles the running set against the
/// registry's enabled set, restarts crashed plugins with exponential backoff,
/// and auto-disables a plugin that crashes past the policy threshold (emitting a
/// high-severity SystemAlert through the injected sink). Cf. docs/plugins-design.md
/// §8/§14 #5.
public actor PluginHostManager {
    public struct Configuration: Sendable {
        public let backoff: PluginBackoffPolicy
        /// Sliding window over which crashes are counted for auto-disable.
        public let crashWindow: TimeInterval
        public let timeouts: PluginHost.Timeouts

        public init(
            backoff: PluginBackoffPolicy = PluginBackoffPolicy(),
            crashWindow: TimeInterval = 60,
            timeouts: PluginHost.Timeouts = PluginHost.Timeouts()
        ) {
            self.backoff = backoff
            self.crashWindow = crashWindow
            self.timeouts = timeouts
        }
    }

    private let registry: PluginRegistry
    private let pluginsDirectory: URL
    private let scratchRoot: URL
    private let sandbox: PluginSandbox
    private let config: Configuration
    private let emitSystemAlert: @Sendable (SystemAlert) async -> Void
    private let logger: Logger

    private var hosts: [String: PluginHost] = [:]
    private var crashTimes: [String: [Date]] = [:]
    private var restarting: Set<String> = []
    private var shuttingDown = false
    private var reconciling = false
    private var reconcilePending = false

    public init(
        registry: PluginRegistry,
        pluginsDirectory: URL,
        scratchRoot: URL,
        sandbox: PluginSandbox,
        config: Configuration = Configuration(),
        emitSystemAlert: @escaping @Sendable (SystemAlert) async -> Void,
        logger: Logger
    ) {
        self.registry = registry
        self.pluginsDirectory = pluginsDirectory
        self.scratchRoot = scratchRoot
        self.sandbox = sandbox
        self.config = config
        self.emitSystemAlert = emitSystemAlert
        self.logger = logger
    }

    /// Launches every enabled+matching plugin. Called once at daemon boot.
    public func startEnabled() async {
        await reconcile()
    }

    /// Diffs the registry's desired set (enabled AND hash-matching) against the
    /// running hosts: starts the missing, stops the extra. Called at boot and
    /// after any plugin mutation (enable/disable/remove/reorder).
    ///
    /// Non-reentrant: actor reentrancy across the `await`s below means a second
    /// `reconcile()` can arrive mid-pass. Running two passes concurrently could
    /// double-launch a plugin during its `start()` window, so a concurrent call
    /// sets a pending flag and the in-flight pass re-runs once it finishes — the
    /// final state always reflects the latest registry.
    public func reconcile() async {
        guard !shuttingDown else { return }
        if reconciling {
            reconcilePending = true
            return
        }
        reconciling = true
        defer { reconciling = false }
        repeat {
            reconcilePending = false
            await performReconcile()
        } while reconcilePending && !shuttingDown
    }

    private func performReconcile() async {
        let desired = await desiredPlugins()
        let desiredIDs = Set(desired.map(\.manifest.id))

        // Stop hosts no longer desired.
        for (id, host) in hosts where !desiredIDs.contains(id) {
            await host.shutdown()
            hosts[id] = nil
        }
        // Start newly desired plugins (skip ids mid-restart to avoid a double
        // launch racing the backoff path).
        for plugin in desired
        where hosts[plugin.manifest.id] == nil && !restarting.contains(plugin.manifest.id) {
            await startHost(for: plugin)
        }
    }

    /// Gracefully stops all hosts. Called at daemon shutdown.
    public func shutdownAll() async {
        shuttingDown = true
        for (_, host) in hosts {
            await host.shutdown()
        }
        hosts.removeAll()
    }

    // MARK: - Internals

    private func desiredPlugins() async -> [Plugin] {
        let plugins = (try? await registry.list()) ?? []
        return plugins.filter { $0.enabled && $0.hashMatches }
    }

    private func startHost(for plugin: Plugin) async {
        let id = plugin.manifest.id
        guard let scratch = makeScratch(for: id) else {
            logger.error("plugin scratch dir setup failed", metadata: ["id": "\(id)"])
            return
        }
        let spec = PluginLaunchSpec(
            id: id,
            executablePath:
                pluginsDirectory
                .appendingPathComponent(id)
                .appendingPathComponent(plugin.manifest.executable)
                .path,
            capabilities: plugin.approvedCapabilities ?? plugin.manifest.capabilities,
            configValues: [:],
            scratchDir: scratch
        )
        let host = PluginHost(
            spec: spec,
            sandbox: sandbox,
            timeouts: config.timeouts,
            logger: logger,
            onUnexpectedExit: { [weak self] crashedID in
                await self?.handleUnexpectedExit(id: crashedID)
            }
        )
        do {
            try await host.start()
            hosts[id] = host
        } catch {
            logger.warning(
                "plugin failed to start",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
            await handleUnexpectedExit(id: id)
        }
    }

    private func handleUnexpectedExit(id: String) async {
        guard !shuttingDown else { return }
        hosts[id] = nil
        // Mark as mid-restart so a concurrent reconcile() (actor reentrancy during
        // the backoff sleep below) does not double-launch this plugin. Bounded by
        // the auto-disable threshold, so nesting via startHost stays shallow.
        restarting.insert(id)
        defer { restarting.remove(id) }

        var times = (crashTimes[id] ?? []).filter { Date().timeIntervalSince($0) < config.crashWindow }
        times.append(Date())
        crashTimes[id] = times

        if config.backoff.shouldDisable(recentCrashCount: times.count) {
            logger.error(
                "plugin auto-disabled after repeated crashes",
                metadata: ["id": "\(id)", "crashes": "\(times.count)"]
            )
            do {
                _ = try await registry.disable(id: id)
            } catch {
                logger.error(
                    "failed to persist plugin auto-disable",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
            }
            crashTimes[id] = nil
            // Terminal: the plugin won't restart, so reclaim its scratch dir
            // (a transient crash leaves it for reuse on the next restart).
            try? FileManager.default.removeItem(at: scratchRoot.appendingPathComponent(id, isDirectory: true))
            await emitSystemAlert(
                SystemAlert(
                    severity: .high,
                    message:
                        "Plugin '\(id)' was auto-disabled after \(times.count) crashes — re-enable it from Settings once fixed."
                )
            )
            return
        }

        let delay = config.backoff.delay(forCrashCount: times.count)
        logger.warning(
            "plugin crashed; scheduling restart",
            metadata: ["id": "\(id)", "crashes": "\(times.count)", "delay_s": "\(delay)"]
        )
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !shuttingDown else { return }
        // Restart only if still desired (a concurrent disable/remove wins).
        let desired = await desiredPlugins()
        guard let plugin = desired.first(where: { $0.manifest.id == id }) else { return }
        await startHost(for: plugin)
    }

    /// Creates `scratchRoot/<id>` and returns its canonical (realpath) URL.
    /// Seatbelt canonicalises write paths, so the profile must carry the
    /// realpath (handoff #3) — `resolvingSymlinksInPath` is not enough.
    private func makeScratch(for id: String) -> URL? {
        let dir = scratchRoot.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let canonical = dir.path.withCString { cString -> String? in
            guard let resolved = realpath(cString, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return canonical.map { URL(fileURLWithPath: $0) }
    }
}
