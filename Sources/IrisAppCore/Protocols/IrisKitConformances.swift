import Foundation
import IrisKit

// MARK: - AdminClient + AdminCalling

extension AdminClient: AdminCalling {
    public func fetchStatus() async throws -> IrisKit.DaemonStatus {
        try await call(.daemonStatus, returning: IrisKit.DaemonStatus.self)
    }

    public func fetchStats() async throws -> DaemonStats {
        try await call(.daemonStats, returning: DaemonStats.self)
    }

    public func pause() async throws {
        _ = try await call(.daemonPause, returning: DaemonPauseResult.self)
    }

    public func resume() async throws {
        _ = try await call(.daemonResume, returning: DaemonPauseResult.self)
    }

    public func queryEvents(since: Date?, limit: Int?) async throws -> [Event] {
        try await call(
            .eventsQuery,
            params: EventsQueryParams(since: since, until: nil, limit: limit, kind: nil, host: nil),
            returning: [Event].self
        )
    }

    public func listSecrets() async throws -> [Secret] {
        try await call(.secretList, returning: [Secret].self)
    }

    public func addSecret(name: String, allowedHosts: [String], value: Data) async throws -> Secret {
        try await call(
            .secretAdd,
            params: SecretAddParams(name: name, allowedHosts: allowedHosts, value: value),
            returning: Secret.self
        )
    }

    public func updateSecret(name: String, allowedHosts: [String]) async throws -> Secret {
        try await call(
            .secretUpdate,
            params: SecretUpdateParams(name: name, allowedHosts: allowedHosts),
            returning: Secret.self
        )
    }

    public func rotateSecret(name: String, value: Data) async throws -> Secret {
        try await call(
            .secretRotate,
            params: SecretRotateParams(name: name, value: value),
            returning: Secret.self
        )
    }

    public func deleteSecret(name: String) async throws {
        _ = try await call(
            .secretDelete,
            params: SecretNameParams(name: name),
            returning: SecretDeletedResult.self
        )
    }

    public func setQuarantined(name: String, quarantined: Bool) async throws -> Secret {
        try await call(
            .secretSetQuarantined,
            params: SecretQuarantineParams(name: name, quarantined: quarantined),
            returning: Secret.self
        )
    }

    public func listRules() async throws -> [MITMRule] {
        try await call(.ruleList, returning: [MITMRule].self)
    }

    public func addRule(host: String) async throws -> MITMRule {
        try await call(.ruleAdd, params: RuleHostParams(host: host), returning: MITMRule.self)
    }

    public func deleteRule(host: String) async throws {
        _ = try await call(
            .ruleDelete,
            params: RuleHostParams(host: host),
            returning: RuleDeletedResult.self
        )
    }

    public func fetchConfig() async throws -> Config {
        try await call(.configGet, returning: Config.self)
    }

    public func setConfig(updates: [ConfigSetParams.Update]) async throws -> ConfigSetResult {
        try await call(.configSet, params: ConfigSetParams(updates: updates), returning: ConfigSetResult.self)
    }

    public func reloadConfig() async throws -> ConfigReloadResult {
        try await call(.configReload, returning: ConfigReloadResult.self)
    }

    public func configPath() async throws -> String {
        try await call(.configPath, returning: ConfigPathResult.self).path
    }

    public func isCATrusted() async throws -> Bool {
        try await call(.caIsTrusted, returning: CAIsTrustedResult.self).trusted
    }

    public func caExportPath() async throws -> String {
        try await call(.caExportPath, returning: CAExportPathResult.self).path
    }
}

// MARK: - EventsClient + EventsSubscribing

extension EventsClient: EventsSubscribing {
    public func subscribe(since: Date?) async throws -> AsyncThrowingStream<EventsClientItem, Error> {
        try await subscribe(since: since, kinds: nil, host: nil)
    }
}
