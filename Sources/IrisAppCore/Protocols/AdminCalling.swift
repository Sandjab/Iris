import Foundation
import IrisKit

/// Abstraction for admin RPC calls used by SyncCoordinator.
/// Enables testing with mocks without touching IrisKit.
public protocol AdminCalling: Sendable {
    /// Fetch current daemon status (PID, uptime, version, stats).
    func fetchStatus() async throws -> IrisKit.DaemonStatus

    /// Fetch daemon statistics (counts, rates).
    func fetchStats() async throws -> DaemonStats

    /// Request daemon pause (stops secret substitution).
    func pause() async throws

    /// Request daemon resume.
    func resume() async throws

    /// Query historical events with optional filters.
    func queryEvents(since: Date?, limit: Int?) async throws -> [Event]

    /// List all secrets (names + metadata, never values).
    func listSecrets() async throws -> [Secret]

    /// Add a secret. `value` is the raw secret bytes (binary-safe). Returns the created Secret.
    func addSecret(name: String, allowedHosts: [String], value: Data) async throws -> Secret

    /// Update a secret's allowed hosts. Returns the updated Secret.
    func updateSecret(name: String, allowedHosts: [String]) async throws -> Secret

    /// Replace a secret's value. Returns the updated Secret.
    func rotateSecret(name: String, value: Data) async throws -> Secret

    /// Delete a secret (removes the Keychain item daemon-side).
    func deleteSecret(name: String) async throws

    /// Toggle quarantine on a secret (disable/enable substitution). Returns the updated Secret.
    func setQuarantined(name: String, quarantined: Bool) async throws -> Secret

    /// List MITM rules (host + source).
    func listRules() async throws -> [MITMRule]

    /// Add a runtime MITM rule. Returns the created MITMRule.
    func addRule(host: String) async throws -> MITMRule

    /// Delete a runtime MITM rule.
    func deleteRule(host: String) async throws

    /// Fetch the full config snapshot (broker/security/backups/hosts).
    func fetchConfig() async throws -> Config

    /// Apply scalar config updates; returns applied vs restart-required keys.
    func setConfig(updates: [ConfigSetParams.Update]) async throws -> ConfigSetResult

    /// Re-read config.json from disk and re-apply.
    func reloadConfig() async throws -> ConfigReloadResult

    /// Resolved path of config.json on disk (for Reveal in Finder).
    func configPath() async throws -> String

    /// Whether the IRIS CA is in the user trust store.
    func isCATrusted() async throws -> Bool

    /// Path of the public CA PEM (for install/uninstall).
    func caExportPath() async throws -> String

    /// Daemon-side uninstall: removes the CA private key always, and the user's
    /// secrets only when `deleteSecrets` is true. Must run while the daemon is
    /// alive (ACL 8b) — call before unregistering the service.
    func uninstall(deleteSecrets: Bool) async throws -> AdminUninstallResult
}
