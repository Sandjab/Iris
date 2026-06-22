import Foundation
import IrisKit
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSL

/// Phase 3 boot orchestrator. Wires together the proxy, the admin JSON-RPC
/// socket, and the SSE event stream. The daemon owns one
/// `MultiThreadedEventLoopGroup` shared by all NIO listeners; the
/// `AdminServer` and `EventsServer` each install one extra
/// `ChannelHandler` per connection so a single core is plenty for them
/// (the proxy already uses every other core).
public actor Daemon {
    public enum SecretBackend: Sendable {
        case keychain
        /// In-memory store seeded from `IRIS_SECRET_<NAME>` environment
        /// variables. Debug-only — values live in process memory only.
        case inMemoryFromEnvironment
    }

    public enum CABackend: Sendable {
        case keychain
        /// In-memory CA key + cert generated on each boot. Debug-only —
        /// the cert won't be in the trust store, so clients must trust the
        /// PEM at `caPath` themselves.
        case inMemory
    }

    private var currentConfig: Config
    private let configStore: ConfigStore
    private let logger: Logger
    private let proxy: ProxyServer
    private let pluginHostManager: PluginHostManager
    private let adminServer: AdminServer
    private let eventsServer: EventsServer
    private let eventLoopGroup: EventLoopGroup
    private let reloadBox: NIOLockedValueBox<@Sendable () async throws -> ConfigReloadResult>
    private var didStart = false

    public init(
        configStore: ConfigStore,
        secretBackend: SecretBackend,
        caBackend: CABackend = .keychain,
        caPath: URL,
        pluginsDirectory: URL,
        sandboxExecPath: URL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("iris-sandbox-exec")
            ?? URL(fileURLWithPath: "/usr/local/bin/iris-sandbox-exec"),
        scratchRoot: URL = URL(
            fileURLWithPath: ("~/Library/Application Support/iris/plugin-scratch" as NSString)
                .expandingTildeInPath
        ),
        logger: Logger
    ) async throws {
        let config = await configStore.current
        try config.validate()
        self.currentConfig = config
        self.configStore = configStore
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let secretStore: any SecretStore
        switch secretBackend {
        case .keychain:
            secretStore = KeychainSecretStore()
        case .inMemoryFromEnvironment:
            secretStore = try await Self.makeInMemoryStoreFromEnv(logger: logger)
        }

        let caKeyStore: any CAKeyStore
        switch caBackend {
        case .keychain:
            caKeyStore = KeychainCAKeyStore()
        case .inMemory:
            caKeyStore = InMemoryCAKeyStore()
        }
        let caManager = CAManager(
            keyStore: caKeyStore,
            options: CAManager.Options(publicCertPath: caPath)
        )
        let caCert = try await caManager.ensureCA()
        logger.info(
            "CA ready",
            metadata: [
                "fingerprint": "\(caCert.fingerprintSHA256)",
                "pem_path": "\(caPath.path)",
            ]
        )

        let listenHost = try Self.host(of: config.broker.listen)
        let listenPort = try Self.port(of: config.broker.listen)

        // Hosts come straight from the unified config store (no TOML ∪ runtime merge).
        let allowedHosts = await configStore.allowedHosts()

        let proxyConfig = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: listenPort,
            allowedHosts: allowedHosts,
            maxSubstitutionsPerMinute: config.security.maxSubstitutionsPerMinute,
            onExfilAttempt: config.security.onExfilAttempt
        )
        // The hook dispatcher is created before the proxy so it can be injected
        // into it, then wired to PluginHostManager's onChainChanged below: the
        // manager pushes the live plugin chain into this same dispatcher after
        // each reconcile.
        let hookDispatcher = HookDispatcher(logger: logger)
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: caManager,
            group: eventLoopGroup,
            hookDispatcher: hookDispatcher,
            logger: logger
        )
        self.proxy = proxy

        // EventsBus glues the proxy's EventRing to the SSE listener.
        let bus = EventsBus(queueDepth: 1000)
        await proxy.eventRing.attach(bus: bus)

        // Degraded boot: if config.json was corrupted and re-seeded, emit a loud
        // high-severity system alert through the standard event channel (ring →
        // SSE → Security tab / `iris logs`). `recoveredFromCorruption` is an
        // immutable `let` on the store, so it reads synchronously.
        if await configStore.recoveredFromCorruption {
            logger.error("Started in degraded mode: config.json was corrupted and reset to defaults")
            await proxy.eventRing.append(
                Event(
                    timestamp: Date(),
                    kind: .systemAlert,
                    host: "config",
                    method: "-",
                    path: "-",
                    systemAlert: SystemAlert(
                        severity: .high,
                        message:
                            "config.json was corrupted at startup — factory defaults re-seeded; the corrupted file was backed up under backups/."
                    )
                )
            )
        }

        // Daemon control closures bridge the dispatcher to the proxy's
        // paused-flag without pulling the proxy through the IPC layer.
        let daemonControl = InProcessDaemonControl(
            readPaused: { [proxy] in proxy.isPaused },
            writePaused: { [proxy] paused in proxy.setPaused(paused) }
        )

        // Capture proxy + store in local constants so the @Sendable closures
        // below hold direct references without crossing actor isolation.
        let capturedProxy = proxy
        let capturedStore = configStore

        // onConfigReload is defined after `self` is fully initialised (all
        // stored properties are set above). We can't close over `self` here
        // because the actor isn't yet initialised; instead we use a shared
        // mutable box swapped in at the end of init. Both the SIGHUP path and
        // the RPC `config.reload` path go through this single closure, so the
        // daemon's `currentConfig` diff (the `ignored` list) stays authoritative.
        let reloadBox = NIOLockedValueBox<@Sendable () async throws -> ConfigReloadResult>(
            { throw JSONRPCError.internalError }
        )
        let pluginRegistry = PluginRegistry(
            pluginsDirectory: pluginsDirectory,
            configStore: configStore,
            logger: logger
        )
        let pluginHostManager = PluginHostManager(
            registry: pluginRegistry,
            pluginsDirectory: pluginsDirectory,
            scratchRoot: scratchRoot,
            sandbox: PluginSandbox(shimPath: sandboxExecPath),
            emitSystemAlert: { [proxy] alert in
                await proxy.eventRing.append(
                    Event(
                        timestamp: Date(),
                        kind: .systemAlert,
                        host: "plugin",
                        method: "-",
                        path: "-",
                        systemAlert: alert
                    )
                )
            },
            onChainChanged: { [hookDispatcher] chain in hookDispatcher.updateChain(chain) },
            onCompleteChainChanged: { [hookDispatcher] chain in hookDispatcher.updateCompleteChain(chain) },
            logger: logger
        )
        self.pluginHostManager = pluginHostManager
        let dispatcher = AdminDispatcher(
            secretStore: secretStore,
            eventRing: proxy.eventRing,
            caManager: caManager,
            daemon: daemonControl,
            configStore: configStore,
            pluginRegistry: pluginRegistry,
            onHostsChanged: { [capturedProxy, capturedStore] in
                await capturedProxy.updateAllowedHosts(await capturedStore.allowedHosts())
            },
            onSecurityChanged: { [capturedProxy, capturedStore] in
                let cfg = await capturedStore.current
                await capturedProxy.updateSecurityPolicy(
                    maxSubstitutionsPerMinute: cfg.security.maxSubstitutionsPerMinute,
                    onExfilAttempt: cfg.security.onExfilAttempt
                )
            },
            onConfigReload: { [reloadBox] in
                let fn = reloadBox.withLockedValue { $0 }
                return try await fn()
            },
            onPluginsChanged: { [pluginHostManager] in
                await pluginHostManager.reconcile()
            },
            logger: logger
        )
        self.reloadBox = reloadBox

        let dispatcherHandler: AdminServer.RequestHandler = { request in
            await dispatcher.dispatch(request)
        }
        self.adminServer = AdminServer(
            socketPath: config.broker.resolvedAdminSocketURL.path,
            handler: dispatcherHandler,
            group: eventLoopGroup,
            logger: logger
        )

        let eventsHost = try Self.host(of: config.broker.eventsListen)
        let eventsPort = try Self.port(of: config.broker.eventsListen)
        self.eventsServer = EventsServer(
            listenHost: eventsHost,
            listenPort: eventsPort,
            bus: bus,
            eventRing: proxy.eventRing,
            group: eventLoopGroup,
            logger: logger
        )

        // Wire the real reload handler now that all stored properties are set.
        // The closure captures self strongly — Daemon.reload() is on the actor
        // so concurrent SIGHUPs are serialised automatically.
        reloadBox.withLockedValue { [self] fn in
            fn = { [self] in try await self.reload() }
        }
    }

    public func run() async throws {
        guard !didStart else { return }
        didStart = true

        _ = try await proxy.start()
        _ = try await adminServer.start()
        _ = try await eventsServer.start()
        await pluginHostManager.startEnabled()

        logger.info(
            "irisd ready",
            metadata: [
                "admin_socket": "\(currentConfig.broker.adminSocket)",
                "events_listen": "\(currentConfig.broker.eventsListen)",
                "listen": "\(currentConfig.broker.listen)",
            ]
        )

        // Park forever; SIGINT/SIGTERM defaults kill the process. A future
        // graceful path (Phase 7 LaunchAgent) can call `stop()` from a
        // signal handler.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.max)
        }

        try? await stop()
    }

    public func stop() async throws {
        try? await eventsServer.stop()
        try? await adminServer.stop()
        await pluginHostManager.shutdownAll()
        try? await proxy.stop()
        try? await eventLoopGroup.shutdownGracefully()
    }

    /// Test-only accessor for the inner proxy so unit tests can verify
    /// snapshots (`securityPolicySnapshot()`, `allowedHostsSnapshot()`).
    /// Production code MUST NOT depend on this — go through `reload()` /
    /// IPC instead.
    public var proxyForTesting: ProxyServer { proxy }

    // MARK: - Hot reload

    /// Reloads configuration from disk and applies hot-reloadable fields.
    ///
    /// Structural fields that cannot change without a restart (listen addresses,
    /// admin socket, log level, retention settings) are detected and reported
    /// in `ignored`; all other changes take effect immediately.
    ///
    /// Returns `ConfigReloadResult(reloaded: true, ignored:)` on success.
    /// Throws `JSONRPCError.configReloadFailed` if the file cannot be parsed.
    public func reload() async throws -> ConfigReloadResult {
        let newConfig: Config
        do {
            // Re-read config.json from disk and adopt it (parse + validate).
            // A corrupted file surfaces as ConfigStore.Error.corrupted here — it
            // is NOT re-seeded on the explicit reload path; the on-disk file and
            // the running config stay untouched.
            newConfig = try await configStore.reloadFromDisk()
        } catch {
            logger.warning(
                "config.reload failed to parse or validate",
                metadata: ["error": "\(error)"]
            )
            throw JSONRPCError.configReloadFailed("\(error)")
        }

        // Structural fields require a restart; we surface them in `ignored`.
        var ignored: [String] = []
        let old = currentConfig
        if newConfig.broker.listen != old.broker.listen { ignored.append("broker.listen") }
        if newConfig.broker.eventsListen != old.broker.eventsListen { ignored.append("broker.events_listen") }
        if newConfig.broker.adminSocket != old.broker.adminSocket { ignored.append("broker.admin_socket") }
        if newConfig.broker.eventRetentionDays != old.broker.eventRetentionDays {
            ignored.append("broker.event_retention_days")
        }
        if newConfig.broker.eventRingSize != old.broker.eventRingSize { ignored.append("broker.event_ring_size") }
        if newConfig.broker.logLevel != old.broker.logLevel { ignored.append("broker.log_level") }
        if !ignored.isEmpty {
            logger.warning(
                "config.reload: structural fields changed — restart required",
                metadata: ["ignored": "\(ignored)"]
            )
        }

        // Apply hot-reloadable security policy + host set.
        await proxy.updateSecurityPolicy(
            maxSubstitutionsPerMinute: newConfig.security.maxSubstitutionsPerMinute,
            onExfilAttempt: newConfig.security.onExfilAttempt
        )
        currentConfig = newConfig
        await proxy.updateAllowedHosts(Set(newConfig.hosts.map(\.host)))

        logger.info("config.reload OK", metadata: ["ignored": "\(ignored)"])
        return ConfigReloadResult(reloaded: true, ignored: ignored)
    }

    // MARK: - Helpers

    private static func host(of listen: String) throws -> String {
        let parts = listen.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ConfigError.invalidValue(field: "broker.listen", value: listen)
        }
        return String(parts[0])
    }

    private static func port(of listen: String) throws -> Int {
        let parts = listen.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw ConfigError.invalidValue(field: "broker.listen", value: listen)
        }
        return port
    }

    private static let envPrefix = "IRIS_SECRET_"

    private static func makeInMemoryStoreFromEnv(logger: Logger) async throws -> InMemorySecretStore {
        logger.warning(
            "Using in-memory secret store (debug). Values come from \(envPrefix)<NAME> env vars and live in process memory only."
        )
        let store = InMemorySecretStore()
        let env = ProcessInfo.processInfo.environment
        var loaded: [String] = []
        for (key, value) in env where key.hasPrefix(envPrefix) {
            let name = String(key.dropFirst(envPrefix.count)).lowercased()
            do {
                _ = try await store.add(
                    Data(value.utf8),
                    named: name,
                    allowedHosts: ["*"],
                    createdAt: Date()
                )
                loaded.append(name)
            } catch SecretStoreError.invalidName {
                logger.warning("Skipping invalid secret name", metadata: ["name": "\(name)"])
            } catch SecretStoreError.invalidAllowedHosts {
                _ = try await store.add(
                    Data(value.utf8),
                    named: name,
                    allowedHosts: ["debug.invalid"],
                    createdAt: Date()
                )
                loaded.append(name)
            }
        }
        logger.info(
            "Loaded in-memory secrets",
            metadata: ["count": "\(loaded.count)", "names": "\(loaded.sorted())"]
        )
        return store
    }
}
