import XCTest

@testable import IrisKit

final class RedactionTests: XCTestCase {
    func testRedactStringReturnsExpectedFormat() {
        let output = Redaction.redact("sk-ant-abcdef")
        XCTAssertTrue(output.hasPrefix("[REDACTED:"))
        XCTAssertTrue(output.hasSuffix("]"))
        // 8 hex chars = 4 bytes of SHA-256 prefix
        let inner = output.dropFirst("[REDACTED:".count).dropLast()
        XCTAssertEqual(inner.count, 8)
        XCTAssertTrue(inner.allSatisfy { $0.isHexDigit })
    }

    func testRedactNeverLeaksInputValue() {
        let sensitive = "sk-ant-this-must-never-leak"
        let output = Redaction.redact(sensitive)
        XCTAssertFalse(output.contains(sensitive))
        XCTAssertFalse(output.contains("sk-ant"))
    }

    func testRedactIsDeterministic() {
        XCTAssertEqual(Redaction.redact("hello"), Redaction.redact("hello"))
    }

    func testDifferentInputsProduceDifferentRedactions() {
        XCTAssertNotEqual(Redaction.redact("alpha"), Redaction.redact("beta"))
    }

    func testRedactDataAndStringAgree() {
        let value = "some-secret-value"
        XCTAssertEqual(Redaction.redact(value), Redaction.redact(Data(value.utf8)))
    }
}
