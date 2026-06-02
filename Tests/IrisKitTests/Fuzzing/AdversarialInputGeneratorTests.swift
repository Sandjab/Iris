import Foundation
import XCTest

@testable import IrisKit

final class AdversarialInputGeneratorTests: XCTestCase {
    func testGenerationIsDeterministic() {
        let first = AdversarialInputGenerator.generate(count: 500)
        let second = AdversarialInputGenerator.generate(count: 500)
        XCTAssertEqual(first.map(\.label), second.map(\.label))
        XCTAssertEqual(first.map(\.uri), second.map(\.uri))
        XCTAssertEqual(first.map { $0.body }, second.map { $0.body })
    }

    func testNamedCorpusCoversKeyCategories() {
        let labels = Set(AdversarialInputGenerator.namedCorpus.map(\.label))
        for required in [
            "name-too-long", "name-empty", "thousands-occurrences",
            "unbalanced-braces", "nested-placeholder", "non-utf8-body",
            "control-chars", "unicode-name",
        ] {
            XCTAssertTrue(labels.contains(required), "missing corpus category: \(required)")
        }
    }

    func testGeneratedInputsNeverContainSentinel() {
        for input in AdversarialInputGenerator.generate(count: 2000) {
            XCTAssertFalse(input.uri.contains(AdversarialInputGenerator.sentinel))
            for (n, v) in input.headers {
                XCTAssertFalse(n.contains(AdversarialInputGenerator.sentinel))
                XCTAssertFalse(v.contains(AdversarialInputGenerator.sentinel))
            }
            if let body = input.body, let text = String(data: body, encoding: .utf8) {
                XCTAssertFalse(text.contains(AdversarialInputGenerator.sentinel))
            }
        }
    }
}
