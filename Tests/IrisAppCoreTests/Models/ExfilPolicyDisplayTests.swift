import IrisKit
import XCTest

@testable import IrisAppCore

final class ExfilPolicyDisplayTests: XCTestCase {
    // WHY: snake_case raw values (block_and_notify) leak the wire format into the UI; the user
    // sees human labels while the daemon still receives the unchanged rawValue.
    func test_humanLabels() {
        XCTAssertEqual(displayName(for: .blockOnly), "Block only")
        XCTAssertEqual(displayName(for: .blockAndNotify), "Block & notify")
        XCTAssertEqual(displayName(for: .blockNotifyPause), "Block, notify & pause")
    }

    // WHY: guard against an un-mapped case silently falling back to snake_case.
    func test_everyCaseHasNonRawLabel() {
        for policy in ExfilAttemptPolicy.allCases {
            XCTAssertFalse(displayName(for: policy).contains("_"), "\(policy) still shows raw value")
        }
    }
}
