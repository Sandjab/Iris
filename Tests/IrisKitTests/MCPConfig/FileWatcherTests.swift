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
}
