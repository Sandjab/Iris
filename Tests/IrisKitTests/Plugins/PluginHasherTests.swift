import XCTest

@testable import IrisKit

final class PluginHasherTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStableAcrossCalls() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "abc".write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try "binary".write(to: dir.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        let h1 = try PluginHasher.hash(directory: dir)
        let h2 = try PluginHasher.hash(directory: dir)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64)  // hex SHA-256
    }

    func testChangesWhenContentChanges() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("run")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let after = try PluginHasher.hash(directory: dir)
        XCTAssertNotEqual(before, after)
    }

    func testChangesWhenFileRenamed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try "x".write(to: a, atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        // True rename: same content, same file count → only the path differs.
        try FileManager.default.moveItem(at: a, to: dir.appendingPathComponent("b"))
        let after = try PluginHasher.hash(directory: dir)
        XCTAssertNotEqual(before, after)  // path is folded into the digest, not just bytes
    }

    func testChangesWhenHiddenFileAdded() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        try "y".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, try PluginHasher.hash(directory: dir))
    }

    func testSameContentSameHashAcrossDifferentBases() throws {
        let dir1 = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir1) }
        let dir2 = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        try "abc".write(to: dir1.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        try "abc".write(to: dir2.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try PluginHasher.hash(directory: dir1), try PluginHasher.hash(directory: dir2))
    }
}
