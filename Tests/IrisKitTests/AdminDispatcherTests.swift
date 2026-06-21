import Foundation
import Logging
import NIOConcurrencyHelpers
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

    /// Builds a dispatcher backed by a temp `ConfigStore`. When `config` is given,
    /// it is written to the temp file first (so `config.get` returns it); otherwise
    /// the store seeds defaults on first boot.
    /// Pass a pre-configured `caManager` to control CA key state (e.g. in `admin.uninstall` tests).
    private func makeDispatcher(
        secretStore: any SecretStore = InMemorySecretStore(),
        eventRing: EventRing = EventRing(capacity: 64),
        config: Config? = nil,
        daemon: FakeDaemon = FakeDaemon(),
        caManager: CAManager? = nil
    ) async throws -> (AdminDispatcher, FakeDaemon, EventRing) {
        let resolvedCAManager: CAManager
        if let caManager {
            resolvedCAManager = caManager
        } else {
            resolvedCAManager = CAManager(keyStore: InMemoryCAKeyStore())
            _ = try await resolvedCAManager.ensureCA()
        }
        let tmpPath = URL(fileURLWithPath: "/tmp/iris-test-config-\(UUID().uuidString).json")
        if let config {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(config).write(to: tmpPath)
        }
        let configStore = try ConfigStore(path: tmpPath, logger: Logger(label: "test"))
        let dispatcher = AdminDispatcher(
            secretStore: secretStore,
            eventRing: eventRing,
            caManager: resolvedCAManager,
            daemon: daemon,
            configStore: configStore,
            pluginRegistry: Self.makeRegistry(configStore),
            logger: Logger(label: "test")
        )
        return (dispatcher, daemon, eventRing)
    }

    /// A `PluginRegistry` over a fresh temp plugins directory. Tests that don't
    /// exercise `plugin.*` only need the dependency to satisfy the dispatcher's
    /// required `pluginRegistry:` parameter; the empty config means `list()` is
    /// `[]` and the directory is never touched.
    private static func makeRegistry(_ configStore: ConfigStore) -> PluginRegistry {
        PluginRegistry(
            pluginsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("iris-test-plugins-\(UUID().uuidString)"),
            configStore: configStore,
            logger: Logger(label: "test")
        )
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

    func testDaemonStatusReflectsPausedState() async throws {
        // #54 — a pause triggered out-of-band (e.g. `iris pause` from the CLI)
        // must surface in daemon.status so the UI can mirror it without acting itself.
        let daemon = FakeDaemon()
        let (dispatcher, _, _) = try await makeDispatcher(daemon: daemon)

        let before = try unwrapResult(await dispatcher.dispatch(request(.daemonStatus)))
            .decode(as: DaemonStatus.self)
        XCTAssertFalse(before.paused, "fresh daemon must report paused=false")

        daemon.setPaused(true)
        let after = try unwrapResult(await dispatcher.dispatch(request(.daemonStatus)))
            .decode(as: DaemonStatus.self)
        XCTAssertTrue(after.paused, "daemon.status must reflect an out-of-band pause")
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

        let tmpPath = URL(fileURLWithPath: "/tmp/iris-test-config-\(UUID().uuidString).json")
        let configStore = try ConfigStore(path: tmpPath, logger: Logger(label: "test"))
        let dispatcher = AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 16),
            caManager: caManager,
            daemon: FakeDaemon(),
            configStore: configStore,
            pluginRegistry: Self.makeRegistry(configStore),
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

    func testConfigGetReturnsSeededConfigOnFreshStore() async throws {
        // A fresh store seeds defaults, so config.get always returns a config
        // (never "absent"): version 1, the built-in api.anthropic.com host.
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.configGet))
        let returned = try unwrapResult(resp).decode(as: Config.self)
        XCTAssertEqual(returned.version, 1)
        XCTAssertEqual(returned.hosts.map(\.host), ["api.anthropic.com"])
        XCTAssertEqual(returned.hosts.first?.origin, .builtin)
    }

    func testConfigGetReturnsConfigWhenPresent() async throws {
        let config = Config(
            version: 1,
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
            backups: BackupsConfig(maxCount: 10),
            hosts: [
                HostEntry(
                    host: "api.example.com",
                    origin: .user,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
        let (dispatcher, _, _) = try await makeDispatcher(config: config)

        let resp = await dispatcher.dispatch(request(.configGet))
        let returned = try unwrapResult(resp).decode(as: Config.self)
        XCTAssertEqual(returned, config)
    }

    // MARK: - config.path

    func testConfigPathReturnsConfigFilePath() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.configPath))
        let result = try unwrapResult(resp).decode(as: ConfigPathResult.self)
        XCTAssertFalse(result.path.isEmpty)
        XCTAssertTrue(result.path.hasSuffix(".json"), "got \(result.path)")
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

    // MARK: - rule.*

    func testRuleAddListDelete() async throws {
        let tmpPath = URL(fileURLWithPath: "/tmp/iris-test-config-\(UUID().uuidString).json")
        let configStore = try ConfigStore(path: tmpPath, logger: Logger(label: "test"))
        // Sendable shared state: same pattern as ProxyServer.pauseFlag (Phase 3)
        // and ProxyServer.allowedHostsBox / securityPolicyBox (Phase 4.x Task 6).
        let onChangedFlag = NIOLockedValueBox<Bool>(false)
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()
        let dispatcher = AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 64),
            caManager: caManager,
            daemon: FakeDaemon(),
            configStore: configStore,
            pluginRegistry: Self.makeRegistry(configStore),
            onHostsChanged: { onChangedFlag.withLockedValue { $0 = true } },
            logger: Logger(label: "test")
        )

        // rule.add — a user host
        let addResp = await dispatcher.dispatch(
            request(.ruleAdd, params: try JSONValue.encoding(RuleHostParams(host: "api.user.example.com")))
        )
        let added = try unwrapResult(addResp).decode(as: MITMRule.self)
        XCTAssertEqual(added.host, "api.user.example.com")
        XCTAssertEqual(added.origin, .user)
        XCTAssertTrue(
            onChangedFlag.withLockedValue { $0 },
            "onHostsChanged must be called after add"
        )

        // rule.list — seeded built-in host + the new user host
        let listResp = await dispatcher.dispatch(request(.ruleList))
        let rules = try unwrapResult(listResp).decode(as: [MITMRule].self)
        let hosts = rules.map(\.host).sorted()
        XCTAssertEqual(hosts, ["api.anthropic.com", "api.user.example.com"])
        let builtinRule = rules.first { $0.host == "api.anthropic.com" }
        XCTAssertEqual(builtinRule?.origin, .builtin, "seeded host must have origin=.builtin in listing")

        // rule.delete — built-in host is protected
        let delBuiltinResp = await dispatcher.dispatch(
            request(.ruleDelete, params: try JSONValue.encoding(RuleHostParams(host: "api.anthropic.com")))
        )
        XCTAssertEqual(delBuiltinResp.error?.code, JSONRPCError.ruleProtected.code)

        // rule.delete — user host succeeds
        onChangedFlag.withLockedValue { $0 = false }
        let delResp = await dispatcher.dispatch(
            request(.ruleDelete, params: try JSONValue.encoding(RuleHostParams(host: "api.user.example.com")))
        )
        let deleted = try unwrapResult(delResp).decode(as: RuleDeletedResult.self)
        XCTAssertTrue(deleted.deleted)
        XCTAssertTrue(
            onChangedFlag.withLockedValue { $0 },
            "onHostsChanged must be called after delete"
        )

        // rule.delete — not found after deletion
        let delAgainResp = await dispatcher.dispatch(
            request(.ruleDelete, params: try JSONValue.encoding(RuleHostParams(host: "api.user.example.com")))
        )
        XCTAssertEqual(delAgainResp.error?.code, JSONRPCError.ruleNotFound.code)
    }

    func testRuleAddOnBuiltinHostIsIdempotent() async throws {
        // rule.add on the seeded built-in host returns its existing rule
        // (origin .builtin) without creating a duplicate entry.
        let (dispatcher, _, _) = try await makeDispatcher()
        let addResp = await dispatcher.dispatch(
            request(.ruleAdd, params: try JSONValue.encoding(RuleHostParams(host: "api.anthropic.com")))
        )
        let rule = try unwrapResult(addResp).decode(as: MITMRule.self)
        XCTAssertEqual(rule.host, "api.anthropic.com")
        XCTAssertEqual(rule.origin, .builtin)

        let listResp = await dispatcher.dispatch(request(.ruleList))
        let rules = try unwrapResult(listResp).decode(as: [MITMRule].self)
        XCTAssertEqual(
            rules.filter { $0.host == "api.anthropic.com" }.count,
            1,
            "must not duplicate the built-in host"
        )
    }

    func testRuleAddInvalidHostReturnsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(
            request(.ruleAdd, params: try JSONValue.encoding(RuleHostParams(host: "not a valid host!")))
        )
        XCTAssertEqual(resp.error?.code, JSONRPCError.invalidParams.code)
    }

    func testRuleListReturnsSeededBuiltinHost() async throws {
        // A fresh store seeds api.anthropic.com (origin .builtin); rule.list reflects it.
        let (dispatcher, _, _) = try await makeDispatcher()
        let resp = await dispatcher.dispatch(request(.ruleList))
        let rules = try unwrapResult(resp).decode(as: [MITMRule].self)
        XCTAssertEqual(rules.map(\.host), ["api.anthropic.com"])
        XCTAssertEqual(rules.first?.origin, .builtin)
    }

    func testEventsClearOnEmptyRingReturnsZero() async throws {
        let ring = EventRing(capacity: 100)
        let (dispatcher, _, _) = try await makeDispatcher(eventRing: ring)

        let resp = await dispatcher.dispatch(request(.eventsClear))
        let result = try unwrapResult(resp).decode(as: EventsClearResult.self)
        XCTAssertEqual(result.deletedCount, 0)
    }

    func testSecretSetQuarantinedRoundTrips() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "a", allowedHosts: ["h"], createdAt: Date())
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: store)

        let onParams = try JSONValue.encoding(SecretQuarantineParams(name: "a", quarantined: true))
        let onResp = await dispatcher.dispatch(request(.secretSetQuarantined, params: onParams))
        let onResult = try unwrapResult(onResp)
        XCTAssertTrue(try onResult.decode(as: Secret.self).quarantined)

        let offParams = try JSONValue.encoding(SecretQuarantineParams(name: "a", quarantined: false))
        let offResp = await dispatcher.dispatch(request(.secretSetQuarantined, params: offParams))
        XCTAssertFalse(try unwrapResult(offResp).decode(as: Secret.self).quarantined)
    }

    func testSecretSetQuarantinedUnknownReturnsError() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        let params = try JSONValue.encoding(SecretQuarantineParams(name: "ghost", quarantined: true))
        let resp = await dispatcher.dispatch(request(.secretSetQuarantined, params: params))
        XCTAssertNotNil(resp.error)
    }

    // MARK: - admin.uninstall

    func testAdminUninstallDeletesCAKeyButKeepsSecretsWhenOptedOut() async throws {
        let secrets = InMemorySecretStore()
        _ = try await secrets.add(Data("V".utf8), named: "TOKEN", allowedHosts: ["api.example.com"], createdAt: Date())
        let keyStore = InMemoryCAKeyStore()
        let ca = CAManager(keyStore: keyStore)
        _ = try await ca.signingKey()
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: secrets, caManager: ca)

        let response = await dispatcher.dispatch(
            request(.adminUninstall, params: try JSONValue.encoding(AdminUninstallParams(deleteSecrets: false)))
        )
        let result = try unwrapResult(response).decode(as: AdminUninstallResult.self)
        XCTAssertTrue(result.caKeyDeleted)
        XCTAssertEqual(result.secretsDeleted, 0)
        let remaining = try await secrets.list()
        XCTAssertEqual(remaining.count, 1, "secrets are NOT touched when opted out")
    }

    func testAdminUninstallDeletesSecretsWhenOptedInAndIsValueFree() async throws {
        let secrets = InMemorySecretStore()
        _ = try await secrets.add(
            Data("SUPERSECRET".utf8),
            named: "TOKEN",
            allowedHosts: ["api.example.com"],
            createdAt: Date()
        )
        let ca = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await ca.signingKey()
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: secrets, caManager: ca)

        let response = await dispatcher.dispatch(
            request(.adminUninstall, params: try JSONValue.encoding(AdminUninstallParams(deleteSecrets: true)))
        )
        let result = try unwrapResult(response).decode(as: AdminUninstallResult.self)
        XCTAssertEqual(result.secretsDeleted, 1)
        let remainingAfterDelete = try await secrets.list()
        XCTAssertEqual(remainingAfterDelete.count, 0)

        // I3 — non-fuite : aucun octet de valeur dans la réponse encodée.
        let dump = String(data: try JSONEncoder().encode(response), encoding: .utf8) ?? ""
        XCTAssertFalse(dump.contains("SUPERSECRET"))
    }

    func testAdminUninstallIsIdempotent() async throws {
        let secrets = InMemorySecretStore()
        let ca = CAManager(keyStore: InMemoryCAKeyStore())
        let (dispatcher, _, _) = try await makeDispatcher(secretStore: secrets, caManager: ca)
        let response = await dispatcher.dispatch(
            request(.adminUninstall, params: try JSONValue.encoding(AdminUninstallParams(deleteSecrets: true)))
        )
        let result = try unwrapResult(response).decode(as: AdminUninstallResult.self)
        XCTAssertFalse(result.caKeyDeleted)
        XCTAssertEqual(result.secretsDeleted, 0)
    }

    // MARK: - plugin.*

    /// Temp state backing a plugin-capable dispatcher. Everything lives under a
    /// single per-test `testDir`, so `cleanup()` removes one directory — and
    /// with it the `config.json`, the `backups/` sidecar `ConfigStore` writes
    /// next to it, the installed-plugins dir, and the install source dir.
    private struct PluginTestContext {
        let testDir: URL
        let sourceDir: URL
        func cleanup() {
            try? FileManager.default.removeItem(at: testDir)
        }
    }

    /// Builds a dispatcher whose `PluginRegistry` operates over a fresh temp
    /// plugins directory, plus a ready-to-install source dir holding a minimal
    /// `org.example.tagger` plugin (manifest + `run`). All paths are nested
    /// under one per-test UUID directory so no sidecar leaks into `$TMPDIR`.
    private func makeDispatcherWithPlugins() async throws -> (AdminDispatcher, PluginTestContext) {
        let caManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await caManager.ensureCA()

        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID().uuidString)")
        let configPath = testDir.appendingPathComponent("config.json")
        let pluginsDir = testDir.appendingPathComponent("plugins")
        let sourceDir = testDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let manifest = #"""
            { "id": "org.example.tagger", "name": "Tagger", "version": "1.0.0", "api_version": 1,
              "executable": "run",
              "hooks": [ { "event": "on_request", "match": { "hosts": ["api.anthropic.com"] }, "mutates": true } ],
              "capabilities": { "network": [], "filesystem": ["scratch"] } }
            """#
        try manifest.write(
            to: sourceDir.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\n".write(
            to: sourceDir.appendingPathComponent("run"),
            atomically: true,
            encoding: .utf8
        )

        let configStore = try ConfigStore(path: configPath, logger: Logger(label: "test"))
        let registry = PluginRegistry(
            pluginsDirectory: pluginsDir,
            configStore: configStore,
            logger: Logger(label: "test")
        )
        let dispatcher = AdminDispatcher(
            secretStore: InMemorySecretStore(),
            eventRing: EventRing(capacity: 64),
            caManager: caManager,
            daemon: FakeDaemon(),
            configStore: configStore,
            pluginRegistry: registry,
            logger: Logger(label: "test")
        )
        let ctx = PluginTestContext(testDir: testDir, sourceDir: sourceDir)
        return (dispatcher, ctx)
    }

    func testPluginInstallListEnableRemove() async throws {
        let (dispatcher, ctx) = try await makeDispatcherWithPlugins()
        defer { ctx.cleanup() }

        // install
        let installResp = await dispatcher.dispatch(
            request(
                .pluginInstall,
                params: try JSONValue.encoding(PluginInstallParams(path: ctx.sourceDir.path))
            )
        )
        let installed = try unwrapResult(installResp).decode(as: Plugin.self)
        XCTAssertEqual(installed.manifest.id, "org.example.tagger")
        XCTAssertFalse(installed.enabled)

        // list
        let listResp = await dispatcher.dispatch(request(.pluginList))
        let list = try unwrapResult(listResp).decode(as: [Plugin].self)
        XCTAssertEqual(list.map(\.manifest.id), ["org.example.tagger"])

        // enable
        let enableResp = await dispatcher.dispatch(
            request(
                .pluginEnable,
                params: try JSONValue.encoding(PluginIdParams(id: "org.example.tagger"))
            )
        )
        XCTAssertTrue(try unwrapResult(enableResp).decode(as: Plugin.self).enabled)

        // remove
        let removeResp = await dispatcher.dispatch(
            request(
                .pluginRemove,
                params: try JSONValue.encoding(PluginIdParams(id: "org.example.tagger"))
            )
        )
        XCTAssertTrue(try unwrapResult(removeResp).decode(as: PluginRemovedResult.self).removed)

        // Effect, not just return shape: the plugin is actually gone.
        let afterResp = await dispatcher.dispatch(request(.pluginList))
        XCTAssertTrue(try unwrapResult(afterResp).decode(as: [Plugin].self).isEmpty)
    }

    func testPluginUnknownMapsToError() async throws {
        let (dispatcher, ctx) = try await makeDispatcherWithPlugins()
        defer { ctx.cleanup() }
        let resp = await dispatcher.dispatch(
            request(.pluginInfo, params: try JSONValue.encoding(PluginIdParams(id: "nope")))
        )
        // Pin the mapping, not just presence: unknownPlugin → -32030 (mapPluginError),
        // so a misroute to the generic -32603 internalError would fail this test.
        XCTAssertEqual(resp.error?.code, -32030)
    }

    func testUnsafeSourceMapsToDedicatedCode() {
        // A rejected client source (symlink / over cap, #8) gets its own code,
        // not the generic plugin I/O error.
        XCTAssertEqual(AdminDispatcher.mapPluginError(.unsafeSource("x")).code, -32035)
    }
}
