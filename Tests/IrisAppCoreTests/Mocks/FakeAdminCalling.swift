import Foundation
import IrisKit

@testable import IrisAppCore

final class FakeAdminCalling: AdminCalling, @unchecked Sendable {
    var calls: [String] = []
    var stubStatus: IrisKit.DaemonStatus = IrisKit.DaemonStatus(
        pid: 1,
        uptimeS: 0,
        version: "test",
        stats: .zero,
        paused: false
    )
    var stubStats: DaemonStats = .zero
    var stubEvents: [Event] = []
    var shouldThrow: Error?
    var stubSecrets: [Secret] = []
    var stubRules: [MITMRule] = []
    var stubPlugins: [Plugin] = []
    var stubConfig: Config = .default
    var stubCATrusted: Bool = false
    var stubConfigPath: String = "/tmp/iris/config.json"
    var stubCAExportPath: String = "/tmp/iris/ca.pem"
    var stubUninstallResult = AdminUninstallResult(caKeyDeleted: true, secretsDeleted: 0)
    var uninstallDeleteSecretsArg: Bool?
    var stubSetResult: ConfigSetResult = ConfigSetResult(applied: [], requiresRestart: [])
    var stubReloadResult: ConfigReloadResult = ConfigReloadResult(reloaded: true, ignored: [])
    /// Captured value bytes from the last add/rotate, to assert the value never leaks into AppModel.
    var capturedValue: Data?
    /// Fires inside `fetchStatus()` (after recording the call, before returning the stub).
    /// Lets a test mutate shared state mid-await to exercise the poll's post-await re-check.
    var onFetchStatus: (@MainActor @Sendable () -> Void)?

    func fetchStatus() async throws -> IrisKit.DaemonStatus {
        calls.append("status")
        if let e = shouldThrow { throw e }
        await onFetchStatus?()
        return stubStatus
    }

    func fetchStats() async throws -> DaemonStats {
        calls.append("stats")
        if let e = shouldThrow { throw e }
        return stubStats
    }

    func pause() async throws {
        calls.append("pause")
        if let e = shouldThrow { throw e }
    }

    func resume() async throws {
        calls.append("resume")
        if let e = shouldThrow { throw e }
    }

    func queryEvents(since: Date?, limit: Int?) async throws -> [Event] {
        calls.append("queryEvents(since:\(since?.timeIntervalSince1970 ?? -1),limit:\(limit ?? -1))")
        if let e = shouldThrow { throw e }
        return stubEvents
    }

    func listSecrets() async throws -> [Secret] {
        calls.append("listSecrets")
        if let e = shouldThrow { throw e }
        return stubSecrets
    }

    func addSecret(name: String, allowedHosts: [String], value: Data) async throws -> Secret {
        calls.append("addSecret(\(name),hosts:\(allowedHosts.joined(separator: "|")),value:\(value.count)B)")
        capturedValue = value
        if let e = shouldThrow { throw e }
        let s = Secret(name: name, allowedHosts: allowedHosts, createdAt: Date(timeIntervalSince1970: 0))
        stubSecrets.append(s)
        return s
    }

    func updateSecret(name: String, allowedHosts: [String]) async throws -> Secret {
        calls.append("updateSecret(\(name),hosts:\(allowedHosts.joined(separator: "|")))")
        if let e = shouldThrow { throw e }
        let s = Secret(name: name, allowedHosts: allowedHosts, createdAt: Date(timeIntervalSince1970: 0))
        stubSecrets.removeAll { $0.name == name }
        stubSecrets.append(s)
        return s
    }

    func rotateSecret(name: String, value: Data) async throws -> Secret {
        calls.append("rotateSecret(\(name),value:\(value.count)B)")
        capturedValue = value
        if let e = shouldThrow { throw e }
        return Secret(name: name, allowedHosts: [], createdAt: Date(timeIntervalSince1970: 0))
    }

    func deleteSecret(name: String) async throws {
        calls.append("deleteSecret(\(name))")
        if let e = shouldThrow { throw e }
        stubSecrets.removeAll { $0.name == name }
    }

    func setQuarantined(name: String, quarantined: Bool) async throws -> Secret {
        calls.append("setQuarantined(\(name),\(quarantined))")
        if let e = shouldThrow { throw e }
        let existing = stubSecrets.first { $0.name == name }
        let s = Secret(
            name: name,
            allowedHosts: existing?.allowedHosts ?? [],
            createdAt: existing?.createdAt ?? Date(timeIntervalSince1970: 0),
            lastUsedAt: existing?.lastUsedAt,
            usageCount: existing?.usageCount ?? 0,
            quarantined: quarantined
        )
        stubSecrets.removeAll { $0.name == name }
        stubSecrets.append(s)
        return s
    }

    func listRules() async throws -> [MITMRule] {
        calls.append("listRules")
        if let e = shouldThrow { throw e }
        return stubRules
    }

    func addRule(host: String) async throws -> MITMRule {
        calls.append("addRule(\(host))")
        if let e = shouldThrow { throw e }
        let r = MITMRule(host: host, createdAt: Date(timeIntervalSince1970: 0), origin: .user)
        stubRules.append(r)
        return r
    }

    func deleteRule(host: String) async throws {
        calls.append("deleteRule(\(host))")
        if let e = shouldThrow { throw e }
        stubRules.removeAll { $0.host == host }
    }

    func listPlugins() async throws -> [Plugin] {
        calls.append("listPlugins")
        if let e = shouldThrow { throw e }
        return stubPlugins
    }

    func installPlugin(path: String) async throws -> Plugin {
        calls.append("installPlugin(\(path))")
        if let e = shouldThrow { throw e }
        let id = path.split(separator: "/").last.map(String.init) ?? path
        let manifest = PluginManifest(
            id: id,
            name: id,
            version: "0.0.1",
            executable: "plugin",
            hooks: [PluginHook(event: .onRequest, match: HookMatch())]
        )
        let plugin = Plugin(
            manifest: manifest,
            enabled: false,
            order: stubPlugins.count,
            approvedCapabilities: nil,
            pinnedHash: "hash",
            hashMatches: true
        )
        stubPlugins.append(plugin)
        return plugin
    }

    func enablePlugin(id: String) async throws -> Plugin {
        calls.append("enablePlugin(\(id))")
        if let e = shouldThrow { throw e }
        if let idx = stubPlugins.firstIndex(where: { $0.manifest.id == id }) {
            let existing = stubPlugins[idx]
            let updated = Plugin(
                manifest: existing.manifest,
                enabled: true,
                order: existing.order,
                approvedCapabilities: existing.manifest.capabilities,
                pinnedHash: existing.pinnedHash,
                hashMatches: existing.hashMatches
            )
            stubPlugins[idx] = updated
            return updated
        }
        // No match: the real daemon throws for an unknown id — fail loud, never
        // silently succeed (a no-op re-fetch would mask a wrong RPC in tests).
        throw JSONRPCError.pluginUnknown
    }

    func disablePlugin(id: String) async throws -> Plugin {
        calls.append("disablePlugin(\(id))")
        if let e = shouldThrow { throw e }
        if let idx = stubPlugins.firstIndex(where: { $0.manifest.id == id }) {
            let existing = stubPlugins[idx]
            let updated = Plugin(
                manifest: existing.manifest,
                enabled: false,
                order: existing.order,
                approvedCapabilities: existing.approvedCapabilities,
                pinnedHash: existing.pinnedHash,
                hashMatches: existing.hashMatches
            )
            stubPlugins[idx] = updated
            return updated
        }
        // No match: the real daemon throws for an unknown id — fail loud, never
        // silently succeed (a no-op re-fetch would mask a wrong RPC in tests).
        throw JSONRPCError.pluginUnknown
    }

    func removePlugin(id: String) async throws {
        calls.append("removePlugin(\(id))")
        if let e = shouldThrow { throw e }
        stubPlugins.removeAll { $0.manifest.id == id }
    }

    func reorderPlugin(id: String, index: Int) async throws -> [Plugin] {
        calls.append("reorderPlugin(\(id),\(index))")
        if let e = shouldThrow { throw e }
        guard let src = stubPlugins.firstIndex(where: { $0.manifest.id == id }) else {
            return stubPlugins
        }
        var list = stubPlugins
        let plugin = list.remove(at: src)
        let dst = min(max(index, 0), list.count)
        list.insert(plugin, at: dst)
        stubPlugins = list.enumerated().map { i, p in
            Plugin(
                manifest: p.manifest,
                enabled: p.enabled,
                order: i,
                approvedCapabilities: p.approvedCapabilities,
                pinnedHash: p.pinnedHash,
                hashMatches: p.hashMatches
            )
        }
        return stubPlugins
    }

    func fetchConfig() async throws -> Config {
        calls.append("fetchConfig")
        if let e = shouldThrow { throw e }
        return stubConfig
    }

    func setConfig(updates: [ConfigSetParams.Update]) async throws -> ConfigSetResult {
        calls.append("setConfig(\(updates.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))")
        if let e = shouldThrow { throw e }
        return stubSetResult
    }

    func reloadConfig() async throws -> ConfigReloadResult {
        calls.append("reloadConfig")
        if let e = shouldThrow { throw e }
        return stubReloadResult
    }

    func configPath() async throws -> String {
        calls.append("configPath")
        if let e = shouldThrow { throw e }
        return stubConfigPath
    }

    func isCATrusted() async throws -> Bool {
        calls.append("isCATrusted")
        if let e = shouldThrow { throw e }
        return stubCATrusted
    }

    func caExportPath() async throws -> String {
        calls.append("caExportPath")
        if let e = shouldThrow { throw e }
        return stubCAExportPath
    }

    func uninstall(deleteSecrets: Bool) async throws -> AdminUninstallResult {
        calls.append("uninstall")
        uninstallDeleteSecretsArg = deleteSecrets
        if let e = shouldThrow { throw e }
        return stubUninstallResult
    }
}
