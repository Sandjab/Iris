import XCTest

@testable import IrisKit

final class SeededGeneratorTests: XCTestCase {
    func testSameSeedProducesSameSequence() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        let seqA = (0..<100).map { _ in a.next() }
        let seqB = (0..<100).map { _ in b.next() }
        XCTAssertEqual(seqA, seqB)
    }

    func testDifferentSeedsProduceDifferentSequences() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        let seqA = (0..<100).map { _ in a.next() }
        let seqB = (0..<100).map { _ in b.next() }
        XCTAssertNotEqual(seqA, seqB)
    }

    func testConformsToRandomNumberGenerator() {
        var gen = SeededGenerator(seed: 7)
        let n = Int.random(in: 0..<10, using: &gen)
        XCTAssertTrue((0..<10).contains(n))
    }
}
