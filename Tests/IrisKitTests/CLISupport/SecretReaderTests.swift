import XCTest
@testable import IrisKit

final class SecretReaderTests: XCTestCase {
    func testReadStripsExactlyOneTrailingNewline() throws {
        let bytes = Data("sk-abcdef\n".utf8)
        let result = try SecretReader.read(from: bytes)
        XCTAssertEqual(result, Data("sk-abcdef".utf8))
    }

    func testReadPreservesInternalNewlines() throws {
        let bytes = Data("line1\nline2\n".utf8)
        let result = try SecretReader.read(from: bytes)
        XCTAssertEqual(result, Data("line1\nline2".utf8))
    }

    func testReadRefusesEmpty() {
        XCTAssertThrowsError(try SecretReader.read(from: Data())) { error in
            XCTAssertEqual(error as? SecretReaderError, .emptyValue)
        }
    }

    func testReadRefusesWhitespaceOnly() {
        XCTAssertThrowsError(try SecretReader.read(from: Data("   \n".utf8))) { error in
            XCTAssertEqual(error as? SecretReaderError, .emptyValue)
        }
    }

    func testReadPreservesBinary() throws {
        let bytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let result = try SecretReader.read(from: bytes)
        XCTAssertEqual(result, bytes)
    }
}
