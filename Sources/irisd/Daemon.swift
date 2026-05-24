import Foundation
import IrisKit
import Logging
import NIOSSL

/// Phase 2 boot orchestrator. Wires together a `SecretStore` and `CAManager`,
/// starts the `ProxyServer`, and parks the task waiting for cancellation
/// (SIGINT/SIGTERM via the OS).
public actor Daemon {
    public enum SecretBackend: Sendable {
        case keychain
        /// In-memory store seeded from `IRIS_SECRET_<NAME>` environment
        /// variables. Debug-only — values live in process memory only.
        case inMemoryFromEnvironment
    }

    private let proxy: ProxyServer
    private let logger: Logger
    private var didStart = false

    public init(
        listenHost: String,
        listenPort: Int,
        allowedHosts: Set<String>,
        caPath: URL,
        secretBackend: SecretBackend,
        logger: Logger
    ) async throws {
        self.logger = logger

        let secretStore: any SecretStore
        switch secretBackend {
        case .keychain:
            secretStore = KeychainSecretStore()
        case .inMemoryFromEnvironment:
            secretStore = try await Self.makeInMemoryStoreFromEnv(logger: logger)
        }

        let caKeyStore = KeychainCAKeyStore()
        let caManager = CAManager(
            keyStore: caKeyStore,
            options: CAManager.Options(publicCertPath: caPath)
        )

        // Ensure CA is materialized before the first MITM request lands.
        let caCert = try await caManager.ensureCA()
        logger.info(
            "CA ready",
            metadata: [
                "fingerprint": "\(caCert.fingerprintSHA256)",
                "pem_path": "\(caPath.path)",
            ]
        )

        let config = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: listenPort,
            allowedHosts: allowedHosts
        )
        self.proxy = ProxyServer(
            configuration: config,
            secretStore: secretStore,
            caManager: caManager,
            logger: logger
        )
    }

    public func run() async throws {
        guard !didStart else { return }
        didStart = true
        _ = try await proxy.start()

        // Park forever. With the default signal dispositions restored in
        // the entry point (`IrisDaemonCLI.run()` in App.swift), SIGINT
        // and SIGTERM terminate the process via the OS default action.
        // UInt64.max nanoseconds is ~584 years; the process is killed
        // by a signal long before this returns.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.max)
        }

        try await proxy.stop()
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
                // Allow any host in debug — scoping is Phase 4.
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
                // The "*" placeholder fails the DNS-shape check; fall back to
                // a plausible literal so the entry still loads in debug.
                _ = try await store.add(
                    Data(value.utf8),
                    named: name,
                    allowedHosts: ["debug.invalid"],
                    createdAt: Date()
                )
                loaded.append(name)
            }
        }
        logger.info("Loaded in-memory secrets", metadata: ["count": "\(loaded.count)", "names": "\(loaded.sorted())"])
        return store
    }
}
