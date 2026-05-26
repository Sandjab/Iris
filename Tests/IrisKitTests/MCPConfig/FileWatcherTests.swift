import XCTest
@testable import IrisKit

final class FileWatcherTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["SKIP_FS_TESTS"] != nil {
            throw XCTSkip("SKIP_FS_TESTS set")
        }
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-fw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testWatcherInitAndStop() {
        let path = tmpDir.appendingPathComponent("a.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: path)
        watcher.stop()
        // No assertion — just verifying init + stop don't crash and don't leak.
    }

    func testWatcherEmitsOnWrite() async throws {
        let path = tmpDir.appendingPathComponent("a.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: path, debounce: .milliseconds(50))
        defer { watcher.stop() }

        let exp = expectation(description: "event received")
        let task = Task {
            for await _ in watcher.events() {
                exp.fulfill()
                return
            }
        }
        // Give the FSEventStream ~150ms to arm before the write
        try await Task.sleep(for: .milliseconds(150))
        try "{\"x\":1}".write(toFile: path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 3.0)
        task.cancel()
    }

    func testWatcherIgnoresOtherFilesInDir() async throws {
        let target = tmpDir.appendingPathComponent("a.json").path
        let other = tmpDir.appendingPathComponent("b.json").path
        FileManager.default.createFile(atPath: target, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: other, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: target, debounce: .milliseconds(50))
        defer { watcher.stop() }

        var eventCount = 0
        let task = Task {
            for await _ in watcher.events() { eventCount += 1 }
        }
        try await Task.sleep(for: .milliseconds(150))
        try "{\"y\":2}".write(toFile: other, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(eventCount, 0)
        task.cancel()
    }
}
