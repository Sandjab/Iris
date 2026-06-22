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
    private let onChainChanged: @Sendable ([PluginChainEntry]) -> Void
    private let onCompleteChainChanged: @Sendable ([PluginChainEntry]) -> Void
    private let onResponseChainChanged: @Sendable ([PluginChainEntry]) -> Void
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
        onChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
        onCompleteChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
        onResponseChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
        logger: Logger
    ) {
        self.registry = registry
        self.pluginsDirectory = pluginsDirectory
        self.scratchRoot = scratchRoot
        self.sandbox = sandbox
        self.config = config
        self.emitSystemAlert = emitSystemAlert
        self.onChainChanged = onChainChanged
        self.onCompleteChainChanged = onCompleteChainChanged
        self.onResponseChainChanged = onResponseChainChanged
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

        // Stop hosts no longer desired. Collect the ids first, then mutate — the
        // original loop was already safe (a value-type Dictionary iterates a CoW
        // snapshot), but the explicit form keeps the mutation plainly separate.
        let idsToStop = hosts.keys.filter { !desiredIDs.contains($0) }
        for id in idsToStop {
            guard let host = hosts[id] else { continue }
            await host.shutdown()
            hosts[id] = nil
        }
        // Start newly desired plugins (skip ids mid-restart to avoid a double
        // launch racing the backoff path).
        for plugin in desired
        where hosts[plugin.manifest.id] == nil && !restarting.contains(plugin.manifest.id) {
            await startHost(for: plugin)
        }
        republishChain(desired: desired)
    }

    /// Gracefully stops all hosts. Called at daemon shutdown.
    public func shutdownAll() async {
        shuttingDown = true
        for (_, host) in hosts {
            await host.shutdown()
        }
        hosts.removeAll()
        onChainChanged([])
        onResponseChainChanged([])
        onCompleteChainChanged([])
    }

    // MARK: - Internals

    private func desiredPlugins() async -> [Plugin] {
        let plugins = (try? await registry.list()) ?? []
        return plugins.filter { $0.enabled && $0.hashMatches }
    }

    private func startHost(for plugin: Plugin) async {
        let id = plugin.manifest.id
        // Defense in depth (design §14 #7): the runtime derives the executable and
        // scratch paths from the id. Installed ids are validated at install, but
        // never build a filesystem path from an id that isn't a safe component.
        guard PluginManifest.isSafePathComponent(id) else {
            logger.error("plugin id is not a safe path component; refusing to launch", metadata: ["id": "\(id)"])
            return
        }
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
            // No `desired` in hand here; fetch once (after the disable persists, so
            // the disabled plugin is excluded) before pushing the updated chain.
            let desired = await desiredPlugins()
            republishChain(desired: desired)
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
        republishChain(desired: desired)
    }

    /// Ordered chains of running hosts × their hooks (design §4.4: chain order
    /// persisted in config). Rebuilt and pushed whenever the running set changes.
    /// `desired` is passed in by the caller (which already fetched it) to avoid a
    /// redundant registry re-hash; the chains are eventually-consistent if hosts
    /// mutate concurrently — the next republish reconverges.
    private func republishChain(desired: [Plugin]) {
        var requestEntries: [PluginChainEntry] = []
        var responseEntries: [PluginChainEntry] = []
        var completeEntries: [PluginChainEntry] = []
        for plugin in desired.sorted(by: { $0.order < $1.order }) {
            guard let host = hosts[plugin.manifest.id] else { continue }
            for hook in plugin.manifest.hooks {
                let entry = PluginChainEntry(pluginId: plugin.manifest.id, invoker: host, hook: hook)
                switch hook.event {
                case .onRequest: requestEntries.append(entry)
                case .onResponse: responseEntries.append(entry)
                case .onComplete: completeEntries.append(entry)
                }
            }
        }
        onChainChanged(requestEntries)
        onResponseChainChanged(responseEntries)
        onCompleteChainChanged(completeEntries)
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
