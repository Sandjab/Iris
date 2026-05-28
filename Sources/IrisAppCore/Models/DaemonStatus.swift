import Foundation
import IrisKit

public enum DaemonStatus: Sendable, Equatable {
    case connecting
    case up(stats: DaemonStats, uptime: TimeInterval, paused: Bool)
    case down(reason: DownReason)

    public enum DownReason: Sendable, Equatable {
        case notRunning
        case rpcError(String)
    }

    public var isUp: Bool {
        if case .up = self { return true }
        return false
    }
}
