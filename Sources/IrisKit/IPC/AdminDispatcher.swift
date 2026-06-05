import Foundation
import Logging

// MARK: - Dispatcher

/// Routes a decoded `JSONRPCRequest` to the appropriate IrisKit service and
/// turns the result (or any thrown error) into a typed `JSONRPCResponse`.
///
/// The dispatcher is `Sendable` and holds only `Sendable` collaborators
/// (`any SecretStore`, `EventRing` actor, `CAManager` actor, the
/// `DaemonControl` protocol). It can be invoked concurrently — each call
/// completes independently — and is wired into `AdminServer` via a
/// `@Sendable` closure adapter.
public struct AdminDispatcher: Sendable {
    public let secretStore: any SecretStore
    public let eventRing: EventRing
    public let caManager: CAManager
    public let daemon: any DaemonControl
    public let configStore: ConfigStore
    public let logger: Logger
    /// Re-applies the live host set to the proxy after a `rule.*` mutation.
    public let onHostsChanged: @Sendable () async -> Void
    /// Re-applies hot security fields to the proxy after a `config.set` mutation.
    public let onSecurityChanged: @Sendable () async -> Void
    /// Owned by the daemon (it has the old snapshot to diff `ignored`); the SIGHUP
    /// path and the RPC `config.reload` path both go through this single closure.
    public let onConfigReload: @Sendable () async throws -> ConfigReloadResult

    public init(
        secretStore: any SecretStore,
        eventRing: EventRing,
        caManager: CAManager,
        daemon: any DaemonControl,
        configStore: ConfigStore,
        onHostsChanged: @escaping @Sendable () async -> Void = {},
        onSecurityChanged: @escaping @Sendable () async -> Void = {},
        onConfigReload: @escaping @Sendable () async throws -> ConfigReloadResult = {
            throw JSONRPCError.internalError
        },
        logger: Logger = Logger(label: "io.iris.admin.dispatcher")
    ) {
        self.secretStore = secretStore
        self.eventRing = eventRing
        self.caManager = caManager
        self.daemon = daemon
        self.configStore = configStore
        self.onHostsChanged = onHostsChanged
        self.onSecurityChanged = onSecurityChanged
        self.onConfigReload = onConfigReload
        self.logger = logger
    }

    // MARK: Public entry point

    public func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let method = AdminMethod(rawValue: request.method) else {
            logger.warning("admin call unknown method", metadata: ["method": "\(request.method)"])
            return .failure(id: request.id, error: .methodNotFound)
        }

        logCall(method: method, id: request.id)

        do {
            let result = try await handle(method, params: request.params)
            return .success(id: request.id, result: result)
        } catch let error as JSONRPCError {
            return .failure(id: request.id, error: error)
        } catch let error as SecretStoreError {
            return .failure(id: request.id, error: Self.mapSecretStoreError(error))
        } catch let error as ConfigStore.Error {
            switch error {
            case .invalidHost(let h):
                return .failure(
                    id: request.id,
                    error: JSONRPCError(code: JSONRPCError.invalidParams.code, message: "invalid host: \(h)")
                )
            case .hostProtected:
                // Reuse the existing protected-rule error (stable wire code); the CLI
                // already renders it (`rule rm`). A built-in host can't be deleted.
                return .failure(id: request.id, error: .ruleProtected)
            case .unknownKey(let k):
                return .failure(
                    id: request.id,
                    error: JSONRPCError(code: JSONRPCError.invalidParams.code, message: "unknown key: \(k)")
                )
            case .invalidValue(let field, let value):
                return .failure(
                    id: request.id,
                    error: JSONRPCError(
                        code: JSONRPCError.invalidParams.code,
                        message: "invalid value '\(value)' for '\(field)'"
                    )
                )
            case .corrupted(let msg), .ioError(let msg):
                return .failure(
                    id: request.id,
                    error: JSONRPCError(code: JSONRPCError.internalError.code, message: msg)
                )
            }
        } catch {
            logger.error(
                "admin call unexpected error",
                metadata: ["method": "\(method.rawValue)", "error": "\(error)"]
            )
            return .failure(
                id: request.id,
                error: JSONRPCError(
                    code: JSONRPCError.internalError.code,
                    message: "\(error)"
                )
            )
        }
    }

    // MARK: Method handlers

    private func handle(_ method: AdminMethod, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case .secretList:
            let list = try await secretStore.list()
            return try JSONValue.encoding(list)
        case .secretGet:
            let payload = try Self.decode(SecretNameParams.self, from: params)
            let secret = try await secretStore.secret(named: payload.name)
            return try JSONValue.encoding(secret)
        case .secretAdd:
            let payload = try Self.decode(SecretAddParams.self, from: params)
            let secret = try await secretStore.add(
                payload.value,
                named: payload.name,
                allowedHosts: payload.allowedHosts,
                createdAt: Date()
            )
            return try JSONValue.encoding(secret)
        case .secretUpdate:
            let payload = try Self.decode(SecretUpdateParams.self, from: params)
            let secret = try await secretStore.update(
                named: payload.name,
                allowedHosts: payload.allowedHosts
            )
            return try JSONValue.encoding(secret)
        case .secretRotate:
            let payload = try Self.decode(SecretRotateParams.self, from: params)
            let secret = try await secretStore.rotate(
                named: payload.name,
                newValue: payload.value
            )
            return try JSONValue.encoding(secret)
        case .secretDelete:
            let payload = try Self.decode(SecretNameParams.self, from: params)
            try await secretStore.delete(named: payload.name)
            return try JSONValue.encoding(SecretDeletedResult(deleted: true))
        case .secretSetQuarantined:
            let payload = try Self.decode(SecretQuarantineParams.self, from: params)
            let secret = try await secretStore.setQuarantined(payload.quarantined, named: payload.name)
            return try JSONValue.encoding(secret)

        case .daemonStatus:
            let stats = await currentStats()
            let uptime = UInt64(max(0, Date().timeIntervalSince(daemon.startedAt)))
            let status = DaemonStatus(
                pid: daemon.processID,
                uptimeS: uptime,
                version: daemon.version,
                stats: stats
            )
            return try JSONValue.encoding(status)
        case .daemonStats:
            return try JSONValue.encoding(await currentStats())
        case .daemonPause:
            daemon.setPaused(true)
            return try JSONValue.encoding(DaemonPauseResult(paused: true))
        case .daemonResume:
            daemon.setPaused(false)
            return try JSONValue.encoding(DaemonPauseResult(paused: false))

        case .eventsQuery:
            let payload =
                (params == nil)
                ? EventsQueryParams()
                : try Self.decode(EventsQueryParams.self, from: params)
            let filtered = await queryEvents(payload)
            return try JSONValue.encoding(filtered)

        case .caExportPath:
            let path = await caManager.publicCertPath?.path ?? ""
            return try JSONValue.encoding(CAExportPathResult(path: path))
        case .caFingerprint:
            let cert = try await caManager.ensureCA()
            return try JSONValue.encoding(CAFingerprintResult(sha256: cert.fingerprintSHA256))
        case .caIsTrusted:
            let cert = try await caManager.ensureCA()
            let trusted = CATrustStore.isTrusted(fingerprintSHA256: cert.fingerprintSHA256)
            return try JSONValue.encoding(CAIsTrustedResult(trusted: trusted))

        case .configGet:
            return try JSONValue.encoding(await configStore.current)

        case .ruleAdd:
            let payload = try Self.decode(RuleHostParams.self, from: params)
            // addHost is idempotent: an already-present host (built-in or user)
            // returns its existing rule without a second entry.
            let rule = try await configStore.addHost(payload.host, now: Date())
            await onHostsChanged()
            return try JSONValue.encoding(rule)

        case .ruleList:
            return try JSONValue.encoding(await configStore.listHosts())

        case .ruleDelete:
            let payload = try Self.decode(RuleHostParams.self, from: params)
            // deleteHost throws .hostProtected for a built-in (origin: default) host.
            let deleted = try await configStore.deleteHost(payload.host)
            guard deleted else { throw JSONRPCError.ruleNotFound }
            await onHostsChanged()
            return try JSONValue.encoding(RuleDeletedResult(deleted: true))

        case .configReload:
            let result = try await onConfigReload()
            return try JSONValue.encoding(result)

        case .eventsClear:
            let n = await eventRing.clear()
            return try JSONValue.encoding(EventsClearResult(deletedCount: n))
        }
    }

    // MARK: Helpers

    private func currentStats() async -> DaemonStats {
        let counts = await eventRing.counts
        let total = counts.values.reduce(UInt64(0)) { $0 &+ $1 }
        return DaemonStats(
            reqTotal: total,
            subTotal: counts[.substituted, default: 0],
            exfilBlockedTotal: counts[.exfilBlocked, default: 0],
            errorsTotal: counts[.error, default: 0]
        )
    }

    private func queryEvents(_ params: EventsQueryParams) async -> [Event] {
        var events = await eventRing.all
        if let since = params.since {
            events = events.filter { $0.timestamp >= since }
        }
        if let until = params.until {
            events = events.filter { $0.timestamp <= until }
        }
        if let kinds = params.kind, !kinds.isEmpty {
            let allowed = Set(kinds)
            events = events.filter { allowed.contains($0.kind) }
        }
        if let host = params.host {
            events = events.filter { $0.host == host }
        }
        if let limit = params.limit, limit > 0, events.count > limit {
            events = Array(events.suffix(limit))
        }
        return events
    }

    /// Log the incoming call without leaking secret values. SPECS §6 / CLAUDE.md §6.1.
    private func logCall(method: AdminMethod, id: JSONRPCID) {
        // For secret.add / secret.rotate the `params` carry a binary secret
        // value; log only the method + id, never the params.
        switch method {
        case .secretAdd, .secretRotate:
            logger.info(
                "admin call",
                metadata: [
                    "method": "\(method.rawValue)",
                    "id": "\(Self.describe(id))",
                ]
            )
        default:
            logger.info(
                "admin call",
                metadata: [
                    "method": "\(method.rawValue)",
                    "id": "\(Self.describe(id))",
                ]
            )
        }
    }

    private static func describe(_ id: JSONRPCID) -> String {
        switch id {
        case .integer(let value): return "\(value)"
        case .string(let value): return value
        case .null: return "null"
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from params: JSONValue?) throws -> T {
        guard let params = params else {
            throw JSONRPCError(
                code: JSONRPCError.invalidParams.code,
                message: "Method requires params"
            )
        }
        do {
            return try params.decode(as: T.self)
        } catch {
            throw JSONRPCError(
                code: JSONRPCError.invalidParams.code,
                message: "Invalid params: \(error)"
            )
        }
    }

    private static func mapSecretStoreError(_ error: SecretStoreError) -> JSONRPCError {
        switch error {
        case .unknownSecret(let name): return .unknownSecret(name)
        case .invalidName(let name): return .invalidName(name)
        case .invalidAllowedHosts(let hosts): return .invalidAllowedHosts(hosts)
        case .duplicate(let name): return .duplicate(name)
        case .keychainStatus(let status):
            return JSONRPCError(
                code: JSONRPCError.internalError.code,
                message: "Keychain status \(status)"
            )
        case .dataCorruption(let message):
            return JSONRPCError(
                code: JSONRPCError.internalError.code,
                message: "Keychain data corruption: \(message)"
            )
        }
    }
}
