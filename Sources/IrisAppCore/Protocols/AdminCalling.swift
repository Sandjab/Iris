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
}
