import XCTest

@testable import IrisKit

final class PluginBackoffPolicyTests: XCTestCase {
    private let policy = PluginBackoffPolicy(
        initialBackoff: 0.25,
        maxBackoff: 30,
        crashThreshold: 5
    )

    func testDelayIsExponentialFromTheInitialValue() {
        XCTAssertEqual(policy.delay(forCrashCount: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forCrashCount: 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forCrashCount: 3), 1.0, accuracy: 1e-9)
    }

    func testDelayIsCappedAtMaxBackoff() {
        XCTAssertEqual(policy.delay(forCrashCount: 20), 30, accuracy: 1e-9)
    }

    func testDelayForZeroOrNegativeIsTheInitialValue() {
        XCTAssertEqual(policy.delay(forCrashCount: 0), 0.25, accuracy: 1e-9)
    }

    func testShouldDisableAtThreshold() {
        XCTAssertFalse(policy.shouldDisable(recentCrashCount: 4))
        XCTAssertTrue(policy.shouldDisable(recentCrashCount: 5))
        XCTAssertTrue(policy.shouldDisable(recentCrashCount: 6))
    }
}
