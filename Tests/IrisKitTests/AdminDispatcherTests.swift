import Foundation
import Logging
import XCTest

@testable import IrisKit

final class AdminDispatcherTests: XCTestCase {

    // MARK: - Helpers

    private final class FakeDaemon: DaemonControl, @unchecked Sendable {
        let processID: Int32 = 42
        let startedAt: Date
        let version: String = "test-1.0"
        private var paused: Bool = false

        init(startedAt: Date = Date(timeIntervalSinceReferenceDate: 0)) {
            self.startedAt = startedAt
        }

        var isPaused: Bool { paused }
        func setPaused(_ paused: Bool) { self.paused = paused }
    }

    private func makeDispatcher(
        secretStore: any SecretStore = InMemorySecretStore(),
        eventRing: EventRing = EventRing(capacity: 64),
        config: Config? = nil,
        daemon: FakeDaemon = FakeDaemon()
    ) async throws -> (AdminDispatcher, FakeDaemon, EventRing) {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let dispatcher = AdminDispatcher(
            secretStore: secretStore,
            eventRing: eventRing,
            caManager: caManager,
            daemon: daemon,
            config: config,
            logger: Logger(label: "test")
        )
        return (dispatcher, daemon, eventRing)
    }

    private func nextID() -> JSONRPCID { .integer(Int64.random(in: 1...1_000_000)) }

    private func request(_ method: AdminMethod, params: JSONValue? = nil) -> JSONRPCRequest {
        JSONRPCRequest(method: method.rawValue, params: params, id: nextID())
    }

    private func unwrapResult(_ response: JSONRPCResponse) throws -> JSONValue {
        if let error = response.error {
            XCTFail("expected success, got error \(error)")
            throw error
        }
        return try XCTUnwrap(response.result)
    }

    // MARK: - Routing

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(
            JSONRPCRequest(method: "no.such.method", id: nextID())
        )
        XCTAssertEqual(resp.error?.code, JSONRPCError.methodNotFound.code)
    }

    func testMissingParamsForMethodThatNeedsThemReturnsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.secretGet, params: nil))
        XCTAssertEqual(resp.error?.code, JSONRPCError.invalidParams.code)
    }

    // MARK: - secret.*

    func testSecretAddListGetDelete() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        let addParams = SecretAddParams(
            name: "api_key",
            allowedHosts: ["api.example.com"],
            value: Data("sk-test".utf8)
        )
        let addResp = await dispatcher.dispatch(
            request(.secretAdd, params: try JSONValue.encoding(addParams))
        )
        let added = try unwrapResult(addResp).decode(as: Secret.self)
        XCTAssertEqual(added.name, "api_key")
        XCTAssertEqual(added.allowedHosts, ["api.example.com"])

        let listResp = await dispatcher.dispatch(request(.secretList))
        let list = try unwrapResult(listResp).decode(as: [Secret].self)
        XCTAssertEqual(list.map(\.name), ["api_key"])

        let getResp = await dispatcher.dispatch(
            request(.secretGet, params: try JSONValue.encoding(SecretNameParams(name: "api_key")))
        )
        let got = try unwrapResult(getResp).decode(as: Secret.self)
        XCTAssertEqual(got.name, "api_key")

        let delResp = await dispatcher.dispatch(
            request(
                .secretDelete,
                params: try JSONValue.encoding(SecretNameParams(name: "api_key"))
            )
        )
        let deleted = try unwrapResult(delResp).decode(as: SecretDeletedResult.self)
        XCTAssertTrue(deleted.deleted)

        let getAfterDelete = await dispatcher.dispatch(
            request(.secretGet, params: try JSONValue.encoding(SecretNameParams(name: "api_key")))
        )
        XCTAssertEqual(getAfterDelete.error?.code, -32001)
    }

    func testSecretAddDuplicateMapsToCustomCode() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v".utf8),
            named: "dup",
            allowedHosts: ["a.example.com"],
            createdAt: Date()
        )
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: store)

        let resp = await dispatcher.dispatch(
            request(
                .secretAdd,
                params: try JSONValue.encoding(
                    SecretAddParams(
                        name: "dup",
                        allowedHosts: ["a.example.com"],
                        value: Data("v2".utf8)
                    )
                )
            )
        )
        XCTAssertEqual(resp.error?.code, -32004)
    }

    func testSecretUpdateAndRotate() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v1".utf8),
            named: "key",
            allowedHosts: ["a.example.com"],
            createdAt: Date()
        )
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: store)

        let updateResp = await dispatcher.dispatch(
            request(
                .secretUpdate,
                params: try JSONValue.encoding(
                    SecretUpdateParams(name: "key", allowedHosts: ["b.example.com"])
                )
            )
        )
        let updated = try unwrapResult(updateResp).decode(as: Secret.self)
        XCTAssertEqual(updated.allowedHosts, ["b.example.com"])

        let rotateResp = await dispatcher.dispatch(
            request(
                .secretRotate,
                params: try JSONValue.encoding(
                    SecretRotateParams(name: "key", value: Data("v2".utf8))
                )
            )
        )
        _ = try unwrapResult(rotateResp)
        let value = try await store.value(forName: "key")
        XCTAssertEqual(value, Data("v2".utf8))
    }

    // MARK: - daemon.*

    func testDaemonStatusReportsPidUptimeAndVersion() async throws {
        let daemon = FakeDaemon(startedAt: Date().addingTimeInterval(-120))
        let (dispatcher, _, _) = try await makeDispatcher(daemon: daemon)

        let resp = await dispatcher.dispatch(request(.daemonStatus))
        let status = try unwrapResult(resp).decode(as: DaemonStatus.self)
        XCTAssertEqual(status.pid, daemon.processID)
        XCTAssertEqual(status.version, daemon.version)
        XCTAssertGreaterThanOrEqual(status.uptimeS, 120)
        XCTAssertLessThan(status.uptimeS, 130)
    }

    func testDaemonStatsReflectsEventRingCounters() async throws {
        let ring = EventRing(capacity: 16)
        for kind in [Event.Kind.substituted, .substituted, .noMatch, .exfilBlocked, .error, .passThrough] {
            await ring.append(
                Event(
                    timestamp: Date(),
                    kind: kind,
                    host: "h",
                    method: "POST",
                    path: "/v1"
                )
            )
        }
        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)

        let resp = await dispatcher.dispatch(request(.daemonStats))
        let stats = try unwrapResult(resp).decode(as: DaemonStats.self)
        XCTAssertEqual(stats.reqTotal, 6)
        XCTAssertEqual(stats.subTotal, 2)
        XCTAssertEqual(stats.exfilBlockedTotal, 1)
        XCTAssertEqual(stats.errorsTotal, 1)
    }

    func testDaemonPauseFlipsControlFlag() async throws {
        let daemon = FakeDaemon()
        let (dispatcher, _, _) = try await makeDispatcher(daemon: daemon)

        let pauseResp = await dispatcher.dispatch(request(.daemonPause))
        let pauseResult = try unwrapResult(pauseResp).decode(as: DaemonPauseResult.self)
        XCTAssertTrue(pauseResult.paused)
        XCTAssertTrue(daemon.isPaused)

        let resumeResp = await dispatcher.dispatch(request(.daemonResume))
        let resumeResult = try unwrapResult(resumeResp).decode(as: DaemonPauseResult.self)
        XCTAssertFalse(resumeResult.paused)
        XCTAssertFalse(daemon.isPaused)
    }

    // MARK: - events.query

    func testEventsQueryReturnsAllWhenNoFilter() async throws {
        let ring = EventRing(capacity: 16)
        for index in 0..<3 {
            await ring.append(
                Event(
                    timestamp: Date(),
                    kind: .substituted,
                    host: "h\(index)",
                    method: "POST",
                    path: "/v1"
                )
            )
        }
        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)

        let resp = await dispatcher.dispatch(request(.eventsQuery))
        let events = try unwrapResult(resp).decode(as: [Event].self)
        XCTAssertEqual(events.map(\.host), ["h0", "h1", "h2"])
    }

    func testEventsQueryFiltersByKindHostAndLimit() async throws {
        let ring = EventRing(capacity: 16)
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples: [(Event.Kind, String)] = [
            (.substituted, "a.example.com"),
            (.noMatch, "a.example.com"),
            (.substituted, "b.example.com"),
            (.exfilBlocked, "a.example.com"),
            (.substituted, "a.example.com"),
        ]
        for (offset, sample) in samples.enumerated() {
            await ring.append(
                Event(
                    timestamp: base.addingTimeInterval(Double(offset)),
                    kind: sample.0,
                    host: sample.1,
                    method: "POST",
                    path: "/v1"
                )
            )
        }
        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)

        let params = EventsQueryParams(
            since: base.addingTimeInterval(1),
            limit: 2,
            kind: [.substituted, .exfilBlocked],
            host: "a.example.com"
        )
        let resp = await dispatcher.dispatch(
            request(.eventsQuery, params: try JSONValue.encoding(params))
        )
        let filtered = try unwrapResult(resp).decode(as: [Event].self)
        // Matching events at indices 3 (exfilBlocked, a) and 4 (substituted, a).
        // After limit=2 (suffix), we get both, in insertion order.
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.host == "a.example.com" })
        XCTAssertEqual(filtered.map(\.kind), [.exfilBlocked, .substituted])
    }

    // MARK: - ca.*

    func testCAExportPathReturnsConfiguredPath() async throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/iris-ca-\(UUID().uuidString.prefix(8)).pem")
        let caManager = CAManager(
            keyStore: InMemoryCAKeyStore(),
            options: CAManager.Options(publicCertPath: tmpURL)
        )
        _ = try await caManager.ensureCA()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let dispatcher = AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 16),
            caManager: caManager,
            daemon: FakeDaemon(),
            logger: Logger(label: "test")
        )

        let resp = await dispatcher.dispatch(request(.caExportPath))
        let result = try unwrapResult(resp).decode(as: CAExportPathResult.self)
        XCTAssertEqual(result.path, tmpURL.path)
    }

    func testCAFingerprintReturnsLowercaseHexWithColons() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        let resp = await dispatcher.dispatch(request(.caFingerprint))
        let result = try unwrapResult(resp).decode(as: CAFingerprintResult.self)
        // 32-byte SHA256 → 32 hex pairs → 31 colons.
        let colonCount = result.sha256.filter { $0 == ":" }.count
        XCTAssertEqual(colonCount, 31)
        XCTAssertEqual(result.sha256, result.sha256.lowercased())
    }

    func testCAIsTrustedReturnsFalseWhenCertNotInUserStore() async throws {
        // The in-memory CA we generate is never added to the user trust
        // store, so this must come back false on CI hosts.
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.caIsTrusted))
        let result = try unwrapResult(resp).decode(as: CAIsTrustedResult.self)
        XCTAssertFalse(result.trusted)
    }

    // MARK: - config.get

    func testConfigGetReturnsErrorWhenConfigAbsent() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.configGet))
        XCTAssertEqual(resp.error?.code, -32006)
    }

    func testConfigGetReturnsConfigWhenPresent() async throws {
        let config = Config(
            broker: BrokerConfig(
                listen: "127.0.0.1:8888",
                eventsListen: "127.0.0.1:8899",
                adminSocket: "~/Library/Application Support/iris/admin.sock",
                logLevel: .info,
                eventRetentionDays: 7,
                eventRingSize: 10_000
            ),
            security: SecurityConfig(
                onExfilAttempt: .blockAndNotify,
                maxSubstitutionsPerMinute: 60
            ),
            mitmHosts: [MITMHostEntry(host: "api.example.com")]
        )
        let (dispatcher, _, _) = try await makeDispatcher(config: config)

        let resp = await dispatcher.dispatch(request(.configGet))
        let returned = try unwrapResult(resp).decode(as: Config.self)
        XCTAssertEqual(returned, config)
    }

    // MARK: - events.clear

    func testEventsClearReturnsDeletedCountAndPreservesTotals() async throws {
        let ring = EventRing(capacity: 100)
        for index in 0..<4 {
            await ring.append(
                Event(
                    timestamp: Date(),
                    kind: .substituted,
                    host: "h\(index)",
                    method: "POST",
                    path: "/v1"
                )
            )
        }

        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)
        let resp = await dispatcher.dispatch(request(.eventsClear))
        let result = try unwrapResult(resp).decode(as: EventsClearResult.self)

        XCTAssertEqual(result.deletedCount, 4)
        // Verify entries are gone
        let remaining = await ring.recent(100)
        XCTAssertEqual(remaining.count, 0, "entries should be cleared")
        // Verify totals are preserved
        let totalSubstituted = await ring.count(of: .substituted)
        XCTAssertEqual(totalSubstituted, 4, "totals must survive clear()")
    }

    func testEventsClearOnEmptyRingReturnsZero() async throws {
        let ring = EventRing(capacity: 100)
        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)

        let resp = await dispatcher.dispatch(request(.eventsClear))
        let result = try unwrapResult(resp).decode(as: EventsClearResult.self)
        XCTAssertEqual(result.deletedCount, 0)
    }
}
