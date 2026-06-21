import XCTest

@testable import IrisKit

final class PluginLineReaderTests: XCTestCase {
    func testReassemblesLinesAcrossWritesAndSignalsEOF() throws {
        let pipe = Pipe()
        let linesBox = LockedBox<[String]>([])
        let eof = expectation(description: "eof")

        let reader = PluginLineReader(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            onLine: { line in linesBox.mutate { $0.append(line) } },
            onEOF: { eof.fulfill() }
        )
        reader.start()

        let write = pipe.fileHandleForWriting
        // A line split across two writes, then two lines in one write.
        write.write(Data("hel".utf8))
        write.write(Data("lo\nwor".utf8))
        write.write(Data("ld\nthird\n".utf8))
        try write.close()

        wait(for: [eof], timeout: 5)
        reader.stop()
        XCTAssertEqual(linesBox.value, ["hello", "world", "third"])
    }

    /// Minimal thread-safe box for collecting reader callbacks off the test thread.
    final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ value: T) { storage = value }
        var value: T {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func mutate(_ body: (inout T) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&storage)
        }
    }
}
