import NIO
import XCTest

@testable import IrisKit

/// Regression for audit finding L-1: the 4 MiB body cap that decides whether a
/// request body is scanned/substituted must be measured on the bytes ACTUALLY
/// received, never on the client-declared `Content-Length`. A client could
/// otherwise declare an oversized length to skip the exfiltration scan on a tiny
/// body. The `bodyExceedsScanCap` helper takes the buffer itself (not a declared
/// length), so the declared header is structurally out of reach.
final class MITMBodyCapTests: XCTestCase {
    func testSmallBodyIsNotOverCap() {
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeString("{{kc:TOKEN}} in a tiny body")
        XCTAssertFalse(MITMHandler.bodyExceedsScanCap(buffer))
    }

    func testNilBodyIsNotOverCap() {
        XCTAssertFalse(MITMHandler.bodyExceedsScanCap(nil))
    }

    func testBodyAtCapIsNotOverCap() {
        var buffer = ByteBufferAllocator().buffer(capacity: MITMHandler.bodyMaxBytes)
        buffer.writeBytes([UInt8](repeating: 0x41, count: MITMHandler.bodyMaxBytes))
        XCTAssertFalse(MITMHandler.bodyExceedsScanCap(buffer))
    }

    func testBodyAboveCapIsOverCap() {
        var buffer = ByteBufferAllocator().buffer(capacity: MITMHandler.bodyMaxBytes + 1)
        buffer.writeBytes([UInt8](repeating: 0x41, count: MITMHandler.bodyMaxBytes + 1))
        XCTAssertTrue(MITMHandler.bodyExceedsScanCap(buffer))
    }
}
