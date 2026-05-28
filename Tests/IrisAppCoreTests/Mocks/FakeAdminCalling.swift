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
}
