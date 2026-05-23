import Foundation
import IrisKit
import Logging
import NIOSSL

/// Phase 2 boot orchestrator. Wires together a real Keychain-backed
/// `SecretStore` and `CAManager`, starts the `ProxyServer`, and parks the
/// task waiting for cancellation (SIGINT/SIGTERM via the OS).
public actor Daemon {
    private let proxy: ProxyServer
    private let logger: Logger
    private var didStart = false

    public init(
        listenHost: String,
        listenPort: Int,
        allowedHosts: Set<String>,
        caPath: URL,
        logger: Logger
    ) async throws {
        self.logger = logger
        let secretStore = KeychainSecretStore()
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

        // Park forever. SIGINT/SIGTERM tears down the process and the
        // NIO event loops shut down implicitly. Proper signal handling
        // arrives later. UInt64.max nanoseconds is ~584 years; the
        // process is killed by a signal long before this returns.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.max)
        }

        try await proxy.stop()
    }
}
