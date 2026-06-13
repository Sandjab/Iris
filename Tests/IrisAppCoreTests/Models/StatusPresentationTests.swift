import IrisKit
import XCTest

@testable import IrisAppCore

final class StatusPresentationTests: XCTestCase {
    // WHY: R4's whole point — state must be distinguishable by SHAPE, not colour alone
    // (colour-blind safety). If two states ever share a symbol, this test fails.
    func test_allStatesUseDistinctSymbols() {
        let symbols = [
            statusGlyph(for: .up(stats: .zero, uptime: 0, paused: false)).symbolName,
            statusGlyph(for: .up(stats: .zero, uptime: 0, paused: true)).symbolName,
            statusGlyph(for: .down(reason: .notRunning)).symbolName,
            statusGlyph(for: .connecting).symbolName,
        ]
        XCTAssertEqual(Set(symbols).count, 4, "each daemon state must have its own glyph shape")
    }

    func test_pausedMapsToPauseGlyph() {
        let g = statusGlyph(for: .up(stats: .zero, uptime: 0, paused: true))
        XCTAssertEqual(g.symbolName, "pause.circle.fill")
        XCTAssertEqual(g.tint, .paused)
    }

    func test_runningMapsToUpTint() {
        XCTAssertEqual(statusGlyph(for: .up(stats: .zero, uptime: 0, paused: false)).tint, .up)
    }

    func test_downMapsToDownTint() {
        XCTAssertEqual(statusGlyph(for: .down(reason: .notRunning)).tint, .down)
    }
}
