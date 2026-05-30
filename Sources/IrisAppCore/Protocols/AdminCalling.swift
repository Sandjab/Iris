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

    /// List MITM rules (host + source).
    func listRules() async throws -> [MITMRule]

    /// Add a runtime MITM rule. Returns the created MITMRule.
    func addRule(host: String) async throws -> MITMRule

    /// Delete a runtime MITM rule.
    func deleteRule(host: String) async throws
}
