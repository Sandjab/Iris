import IrisKit
import Logging
import NIOConcurrencyHelpers
import XCTest

/// Exercises the manager against a real registry + the iris-test-plugin fixture,
/// through the real sandbox. Covers reconcile (start on enable, stop on disable)
/// and the crash-loop → auto-disable + SystemAlert path with shrunk timings.
final class PluginHostManagerTests: XCTestCase {
    /// Installs the fixture (built binary copied into the plugin dir) and enables
    /// it with the given mode, returning (pluginsDir, scratchRoot, registry, store).
    private func makeRegistryWithEnabledFixture(
        mode: String
    ) async throws -> (plugins: URL, scratch: URL, registry: PluginRegistry, store: ConfigStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-mgr-\(UUID().uuidString)")
        let pluginsDir = root.appendingPathComponent("plugins")
        let scratch = root.appendingPathComponent("scratch")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // PluginSandbox passes no argv to the plugin, so the fixture mode is
        // selected by an installed `run.sh` launcher that execs the copied
        // fixture binary with the chosen mode. Both files live in the plugin dir
        // (read+exec are allowed by the deny-default profile).
        let bin = source.appendingPathComponent("bin")
        try FileManager.default.copyItem(at: ExecutableLocator.testPlugin, to: bin)
        let launcher = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexec \"$(dirname \"$0\")/bin\" \(mode)\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let manifest = """
            { "id": "test.mgr.plugin", "name": "Mgr Fixture", "version": "1.0.0",
              "api_version": 1, "executable": "run.sh",
              "hooks": [ { "event": "on_request", "match": {}, "timeout_ms": 200 } ],
              "capabilities": { "network": [], "filesystem": [] } }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        let configPath = root.appendingPathComponent("config.json")
        let store = try ConfigStore(path: configPath, logger: Logger(label: "test"))
        let registry = PluginRegistry(
            pluginsDirectory: pluginsDir,
            configStore: store,
            logger: Logger(label: "test")
        )
        _ = try await registry.install(from: source)
        _ = try await registry.enable(id: "test.mgr.plugin")
        return (pluginsDir, scratch, registry, store)
    }

    private func makeManager(
        plugins: URL,
        scratch: URL,
        registry: PluginRegistry,
        alerts: AlertCollector,
        onChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in }
    ) -> PluginHostManager {
        PluginHostManager(
            registry: registry,
            pluginsDirectory: plugins,
            scratchRoot: scratch,
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            config: PluginHostManager.Configuration(
                backoff: PluginBackoffPolicy(initialBackoff: 0.01, maxBackoff: 0.02, crashThreshold: 5),
                crashWindow: 60,
                timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1)
            ),
            emitSystemAlert: { alert in await alerts.append(alert) },
            onChainChanged: onChainChanged,
            logger: Logger(label: "test")
        )
    }

    func testReconcileStartsThenStopsOnDisable() async throws {
        let env = try await makeRegistryWithEnabledFixture(mode: "ok")
        let alerts = AlertCollector()
        let manager = makeManager(
            plugins: env.plugins,
            scratch: env.scratch,
            registry: env.registry,
            alerts: alerts
        )

        await manager.startEnabled()
        // The fixture wrote its scratch marker during initialize → started.
        let marker = env.scratch.appendingPathComponent("test.mgr.plugin/initialized")
        try await waitUntil(timeout: 8) { FileManager.default.fileExists(atPath: marker.path) }

        _ = try await env.registry.disable(id: "test.mgr.plugin")
        await manager.reconcile()  // host should be torn down without error
        await manager.shutdownAll()
    }

    func testCrashLoopAutoDisablesAndAlerts() async throws {
        let env = try await makeRegistryWithEnabledFixture(mode: "crash")
        let alerts = AlertCollector()
        let manager = makeManager(
            plugins: env.plugins,
            scratch: env.scratch,
            registry: env.registry,
            alerts: alerts
        )

        await manager.startEnabled()
        // 5 fast crashes (10ms backoff) → auto-disable + one high SystemAlert.
        try await waitUntil(timeout: 10) { await alerts.count >= 1 }

        let info = try await env.registry.info(id: "test.mgr.plugin")
        XCTAssertFalse(info.enabled, "plugin must be auto-disabled after crash threshold")
        let alert = await alerts.first
        XCTAssertEqual(alert?.severity, .high)
        XCTAssertTrue(alert?.message.contains("test.mgr.plugin") ?? false)
        await manager.shutdownAll()
    }

    func testReconcilePushesOnRequestChain() async throws {
        let env = try await makeRegistryWithEnabledFixture(mode: "ok")
        let alerts = AlertCollector()
        let pushed = NIOLockedValueBox<[PluginChainEntry]>([])
        let manager = makeManager(
            plugins: env.plugins,
            scratch: env.scratch,
            registry: env.registry,
            alerts: alerts,
            onChainChanged: { chain in pushed.withLockedValue { $0 = chain } }
        )

        await manager.startEnabled()
        let chain = pushed.withLockedValue { $0 }
        XCTAssertEqual(chain.map(\.pluginId), ["test.mgr.plugin"])
        XCTAssertEqual(chain.first?.hook.event, .onRequest)

        await manager.shutdownAll()
        XCTAssertTrue(pushed.withLockedValue { $0 }.isEmpty, "shutdown clears the chain")
    }

    // MARK: - Helpers

    /// Thread-safe alert sink usable as a `@Sendable` closure target.
    actor AlertCollector {
        private(set) var alerts: [SystemAlert] = []
        func append(_ alert: SystemAlert) { alerts.append(alert) }
        var count: Int { alerts.count }
        var first: SystemAlert? { alerts.first }
    }

    /// Bounded async poll (no Thread.sleep). Mirrors the P2a test polling helper.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let steps = max(1, Int(timeout / 0.05))
        for _ in 0..<steps {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
