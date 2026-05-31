import Foundation
import IrisKit

@testable import IrisAppCore

final class FakeAdminCalling: AdminCalling, @unchecked Sendable {
    var calls: [String] = []
    var stubStatus: IrisKit.DaemonStatus = IrisKit.DaemonStatus(
        pid: 1,
        uptimeS: 0,
        version: "test",
        stats: .zero
    )
    var stubStats: DaemonStats = .zero
    var stubEvents: [Event] = []
    var shouldThrow: Error?
    var stubSecrets: [Secret] = []
    var stubRules: [MITMRule] = []
    /// Captured value bytes from the last add/rotate, to assert the value never leaks into AppModel.
    var capturedValue: Data?

    func fetchStatus() async throws -> IrisKit.DaemonStatus {
        calls.append("status")
        if let e = shouldThrow { throw e }
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
        let r = MITMRule(host: host, createdAt: Date(timeIntervalSince1970: 0), source: .runtime)
        stubRules.append(r)
        return r
    }

    func deleteRule(host: String) async throws {
        calls.append("deleteRule(\(host))")
        if let e = shouldThrow { throw e }
        stubRules.removeAll { $0.host == host }
    }
}
