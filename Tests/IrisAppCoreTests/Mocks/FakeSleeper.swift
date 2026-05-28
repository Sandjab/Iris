import Foundation

@testable import IrisAppCore

final class FakeSleeper: AsyncSleeper, @unchecked Sendable {
    private(set) var delays: [Double] = []

    func sleep(seconds: Double) async throws {
        delays.append(seconds)
    }
}
