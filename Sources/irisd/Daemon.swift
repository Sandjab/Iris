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
    private let configPath: URL?
    private let logger: Logger
    private let proxy: ProxyServer
    private let adminServer: AdminServer
    private let eventsServer: EventsServer
    private let eventLoopGroup: EventLoopGroup
    private let runtimeRulesStore: RuntimeRulesStore
    private let reloadBox: NIOLockedValueBox<@Sendable () async throws -> ConfigReloadResult>
    private var didStart = false

    public init(
        config: Config,
        configPath: URL? = nil,
        secretBackend: SecretBackend,
        caBackend: CABackend = .keychain,
        caPath: URL,
        logger: Logger
    ) async throws {
        try config.validate()
        self.currentConfig = config
        self.configPath = configPath
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

        // Runtime rules are stored beside the admin socket.
        let runtimeRulesPath = config.broker.resolvedAdminSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("runtime-rules.json")
        let runtimeRulesParent = runtimeRulesPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: runtimeRulesParent, withIntermediateDirectories: true)
        let runtimeRulesStore = try await RuntimeRulesStore(path: runtimeRulesPath, logger: logger)

        // allowedHosts = TOML hosts ∪ persisted runtime rules.
        let tomlHosts = Set(config.mitmHosts.map(\.host))
        let runtimeHosts = Set(await runtimeRulesStore.list().map(\.host))
        let allowedHosts = tomlHosts.union(runtimeHosts)
        self.runtimeRulesStore = runtimeRulesStore

        let proxyConfig = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: listenPort,
            allowedHosts: allowedHosts,
            maxSubstitutionsPerMinute: config.security.maxSubstitutionsPerMinute,
            onExfilAttempt: config.security.onExfilAttempt
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: caManager,
            group: eventLoopGroup,
            logger: logger
        )
        self.proxy = proxy

        // EventsBus glues the proxy's EventRing to the SSE listener.
        let bus = EventsBus(queueDepth: 1000)
        await proxy.eventRing.attach(bus: bus)

        // Daemon control closures bridge the dispatcher to the proxy's
        // paused-flag without pulling the proxy through the IPC layer.
        let daemonControl = InProcessDaemonControl(
            readPaused: { [proxy] in proxy.isPaused },
            writePaused: { [proxy] paused in proxy.setPaused(paused) }
        )

        // Capture proxy in a local constant so the @Sendable closures below
        // hold a direct reference without crossing actor isolation.
        let capturedProxy = proxy
        let capturedRulesStore = runtimeRulesStore

        // onConfigReload is defined after `self` is fully initialised (all
        // stored properties are set above). We can't close over `self` here
        // because the actor isn't yet initialised; instead we capture the
        // concrete values the reload path needs and supply a sentinel that
        // App.swift replaces via `setReloadHandler` once `init` returns.
        // We use a shared mutable box so that Daemon.run() can swap in the
        // real handler without any additional parameter plumbing.
        let reloadBox = NIOLockedValueBox<@Sendable () async throws -> ConfigReloadResult>(
            { throw JSONRPCError.internalError }
        )
        let dispatcher = AdminDispatcher(
            secretStore: secretStore,
            eventRing: proxy.eventRing,
            caManager: caManager,
            daemon: daemonControl,
            config: config,
            runtimeRulesStore: runtimeRulesStore,
            onRulesChanged: { [capturedProxy, capturedRulesStore] in
                let toml = Set(config.mitmHosts.map(\.host))
                let runtime = Set(await capturedRulesStore.list().map(\.host))
                await capturedProxy.updateAllowedHosts(toml.union(runtime))
            },
            tomlHostsProvider: {
                config.mitmHosts.map(\.host)
            },
            onConfigReload: { [reloadBox] in
                let fn = reloadBox.withLockedValue { $0 }
                return try await fn()
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
        guard let configPath else {
            logger.info("config.reload: no config file backing — no-op")
            return ConfigReloadResult(reloaded: true, ignored: [])
        }

        let newConfig: Config
        do {
            newConfig = try ConfigLoader.load(from: configPath)
            // Defensive: ConfigLoader.load already calls validate(), but call
            // again here to make the contract explicit and to catch any future
            // refactor that splits parse from validate. Cheap, runs once per
            // reload, guarantees no partial application of a bad config.
            try newConfig.validate()
        } catch {
            logger.warning(
                "config.reload failed to parse or validate",
                metadata: ["error": "\(error)"]
            )
            throw JSONRPCError.configReloadFailed("\(error)")
        }

        var ignored: [String] = []

        if newConfig.broker.listen != currentConfig.broker.listen {
            logger.warning(
                "config.reload: ignoring change of broker.listen — restart required",
                metadata: [
                    "old": "\(currentConfig.broker.listen)",
                    "new": "\(newConfig.broker.listen)",
                ]
            )
            ignored.append("broker.listen")
        }
        if newConfig.broker.eventsListen != currentConfig.broker.eventsListen {
            logger.warning(
                "config.reload: ignoring change of broker.events_listen — restart required"
            )
            ignored.append("broker.events_listen")
        }
        if newConfig.broker.adminSocket != currentConfig.broker.adminSocket {
            logger.warning(
                "config.reload: ignoring change of broker.admin_socket — restart required"
            )
            ignored.append("broker.admin_socket")
        }
        if newConfig.broker.eventRetentionDays != currentConfig.broker.eventRetentionDays {
            logger.warning(
                "config.reload: ignoring change of broker.event_retention_days — restart required",
                metadata: [
                    "old": "\(currentConfig.broker.eventRetentionDays)",
                    "new": "\(newConfig.broker.eventRetentionDays)",
                ]
            )
            ignored.append("broker.event_retention_days")
        }
        if newConfig.broker.eventRingSize != currentConfig.broker.eventRingSize {
            logger.warning(
                "config.reload: ignoring change of broker.event_ring_size — restart required",
                metadata: [
                    "old": "\(currentConfig.broker.eventRingSize)",
                    "new": "\(newConfig.broker.eventRingSize)",
                ]
            )
            ignored.append("broker.event_ring_size")
        }
        if newConfig.broker.logLevel != currentConfig.broker.logLevel {
            logger.warning(
                "config.reload: log_level change not yet wired to backend (Phase 5.3.1.x)"
            )
            ignored.append("broker.log_level")
        }

        // Apply hot-reloadable security policy.
        await proxy.updateSecurityPolicy(
            maxSubstitutionsPerMinute: newConfig.security.maxSubstitutionsPerMinute,
            onExfilAttempt: newConfig.security.onExfilAttempt
        )

        // Swap config so tomlHostsProvider reflects the new TOML.
        currentConfig = newConfig

        // Recompute allowedHosts = new TOML hosts ∪ persisted runtime rules.
        let tomlHosts = Set(newConfig.mitmHosts.map(\.host))
        let runtimeHosts = Set(await runtimeRulesStore.list().map(\.host))
        await proxy.updateAllowedHosts(tomlHosts.union(runtimeHosts))

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
