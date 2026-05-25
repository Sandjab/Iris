import Foundation
import IrisKit
import Logging
import NIO
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

    private let config: Config
    private let logger: Logger
    private let proxy: ProxyServer
    private let adminServer: AdminServer
    private let eventsServer: EventsServer
    private let eventLoopGroup: EventLoopGroup
    private var didStart = false

    public init(
        config: Config,
        secretBackend: SecretBackend,
        caBackend: CABackend = .keychain,
        caPath: URL,
        logger: Logger
    ) async throws {
        try config.validate()
        self.config = config
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
        let allowedHosts = Set(config.mitmHosts.map(\.host))

        let proxyConfig = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: listenPort,
            allowedHosts: allowedHosts
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

        let dispatcher = AdminDispatcher(
            secretStore: secretStore,
            eventRing: proxy.eventRing,
            caManager: caManager,
            daemon: daemonControl,
            config: config,
            logger: logger
        )

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
                "admin_socket": "\(config.broker.adminSocket)",
                "events_listen": "\(config.broker.eventsListen)",
                "listen": "\(config.broker.listen)",
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
