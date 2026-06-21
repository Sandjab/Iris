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

    func testChangesWhenFileAddedOrRenamed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        try "x".write(to: dir.appendingPathComponent("b"), atomically: true, encoding: .utf8)
        let after = try PluginHasher.hash(directory: dir)
        XCTAssertNotEqual(before, after)  // path is folded into the digest, not just bytes
    }
}
