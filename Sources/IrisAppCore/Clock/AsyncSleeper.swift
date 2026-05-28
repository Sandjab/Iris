import Foundation

public protocol AsyncSleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct SystemSleeper: AsyncSleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
