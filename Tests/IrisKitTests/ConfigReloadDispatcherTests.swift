import Foundation
import Logging
import XCTest

@testable import IrisKit

/// Unit tests for the config.reload path in AdminDispatcher.
///
/// These tests exercise the dispatcher layer in isolation using a custom
/// `onConfigReload` closure — no live Daemon or irisd process is involved.
final class ConfigReloadDispatcherTests: XCTestCase {

    // MARK: - Helpers

    private final class FakeDaemon: DaemonControl, @unchecked Sendable {
        let processID: Int32 = 1
        let startedAt = Date()
        let version = "test"
        private var paused = false
        var isPaused: Bool { paused }
        func setPaused(_ p: Bool) { paused = p }
    }

    private func makeDispatcher(
        onConfigReload: @escaping @Sendable () async throws -> ConfigReloadResult
    ) async throws -> AdminDispatcher {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let tmpPath = URL(fileURLWithPath: "/tmp/iris-test-config-\(UUID().uuidString).json")
        let configStore = try ConfigStore(path: tmpPath, logger: Logger(label: "test"))
        return AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 64),
            caManager: caManager,
            daemon: FakeDaemon(),
            configStore: configStore,
            onConfigReload: onConfigReload,
            logger: Logger(label: "test")
        )
    }

    private func nextID() -> JSONRPCID { .integer(Int64.random(in: 1...1_000_000)) }

    // MARK: - Tests

    func testConfigReloadSuccessReturnsResultWithReloadedTrue() async throws {
        let expected = ConfigReloadResult(reloaded: true, ignored: [])
        let dispatcher = try await makeDispatcher(onConfigReload: { expected })

        let req = JSONRPCRequest(method: AdminMethod.configReload.rawValue, id: nextID())
        let resp = await dispatcher.dispatch(req)

        XCTAssertNil(resp.error, "expected success, got \(resp.error as Any)")
        let result = try XCTUnwrap(resp.result).decode(as: ConfigReloadResult.self)
        XCTAssertTrue(result.reloaded)
        XCTAssertTrue(result.ignored.isEmpty)
    }

    func testConfigReloadWithIgnoredFieldsReturnsThem() async throws {
        let expected = ConfigReloadResult(reloaded: true, ignored: ["broker.listen", "broker.log_level"])
        let dispatcher = try await makeDispatcher(onConfigReload: { expected })

        let req = JSONRPCRequest(method: AdminMethod.configReload.rawValue, id: nextID())
        let resp = await dispatcher.dispatch(req)

        XCTAssertNil(resp.error)
        let result = try XCTUnwrap(resp.result).decode(as: ConfigReloadResult.self)
        XCTAssertEqual(Set(result.ignored), Set(["broker.listen", "broker.log_level"]))
    }

    func testConfigReloadFailureMapsToConfigReloadFailedError() async throws {
        let dispatcher = try await makeDispatcher(onConfigReload: {
            throw JSONRPCError.configReloadFailed("toml parse error: bad syntax at line 5")
        })

        let req = JSONRPCRequest(method: AdminMethod.configReload.rawValue, id: nextID())
        let resp = await dispatcher.dispatch(req)

        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, JSONRPCError.configReloadFailed("x").code)
        XCTAssertTrue(
            resp.error?.message.contains("toml parse error") == true,
            "error message should propagate, got: \(resp.error?.message ?? "<nil>")"
        )
    }

    func testConfigReloadDefaultClosureThrowsInternalError() async throws {
        // An AdminDispatcher constructed without an explicit onConfigReload
        // must return internalError — it signals the handler is not wired yet.
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let tmpPath = URL(fileURLWithPath: "/tmp/iris-test-config-\(UUID().uuidString).json")
        let configStore = try ConfigStore(path: tmpPath, logger: Logger(label: "test"))
        let dispatcher = AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 64),
            caManager: caManager,
            daemon: FakeDaemon(),
            configStore: configStore
                // onConfigReload intentionally omitted — uses default
        )

        let req = JSONRPCRequest(method: AdminMethod.configReload.rawValue, id: nextID())
        let resp = await dispatcher.dispatch(req)

        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, JSONRPCError.internalError.code)
    }
}
