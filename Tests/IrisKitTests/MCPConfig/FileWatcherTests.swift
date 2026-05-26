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

        let counter = EventCounter()
        let task = Task {
            for await _ in watcher.events() { _ = await counter.increment() }
        }
        try await Task.sleep(for: .milliseconds(150))
        try "{\"y\":2}".write(toFile: other, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        let count = await counter.value
        XCTAssertEqual(count, 0)
        task.cancel()
    }

    func testWatcherDebouncesBurstedWrites() async throws {
        let path = tmpDir.appendingPathComponent("a.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: path, debounce: .milliseconds(300))
        defer { watcher.stop() }

        let counter = EventCounter()
        let exp = expectation(description: "single event after burst")
        let task = Task {
            for await _ in watcher.events() {
                let count = await counter.increment()
                if count == 1 { exp.fulfill() }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        for i in 0..<5 {
            try "{\"x\":\(i)}".write(toFile: path, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(30))
        }
        await fulfillment(of: [exp], timeout: 2.0)
        try await Task.sleep(for: .milliseconds(500))
        let final = await counter.value
        XCTAssertEqual(final, 1, "burst should yield exactly one debounced event")
        task.cancel()
    }

    func testWatcherSurvivesAtomicRename() async throws {
        let path = tmpDir.appendingPathComponent("a.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: path, debounce: .milliseconds(50))
        defer { watcher.stop() }

        let exp = expectation(description: "event after atomic rename")
        let task = Task {
            for await _ in watcher.events() {
                exp.fulfill()
                return
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        // Simulate editor atomic save: write to tmp + rename over target.
        let tmpFile = tmpDir.appendingPathComponent("a.json.tmp").path
        try "{\"y\":2}".write(toFile: tmpFile, atomically: false, encoding: .utf8)
        try FileManager.default.replaceItem(
            at: URL(fileURLWithPath: path),
            withItemAt: URL(fileURLWithPath: tmpFile),
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
        await fulfillment(of: [exp], timeout: 3.0)
        task.cancel()
    }

    func testWatcherDetectsFileRecreation() async throws {
        let path = tmpDir.appendingPathComponent("a.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        let watcher = FileWatcher(path: path, debounce: .milliseconds(50))
        defer { watcher.stop() }

        let counter = EventCounter()
        let task = Task {
            for await _ in watcher.events() {
                _ = await counter.increment()
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.removeItem(atPath: path)
        try await Task.sleep(for: .milliseconds(200))
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
        try await Task.sleep(for: .milliseconds(400))
        let events = await counter.value
        XCTAssertGreaterThanOrEqual(events, 1)
        task.cancel()
    }
}

actor EventCounter {
    private(set) var value: Int = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
