import XCTest

@testable import IrisKit

final class PluginSourceValidatorTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("srcval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAcceptsPlainTree() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try PluginSourceValidator.validate(directory: dir))
    }

    func testAcceptsNestedDirectories() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try PluginSourceValidator.validate(directory: dir))
    }

    func testRejectsNonRegularNonDirectoryFile() throws {
        // A FIFO (and likewise sockets / device nodes) is neither a regular file
        // nor a directory; it must be refused, not silently skipped, since
        // copyItem would still copy it into the plugins dir.
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "mkfifo should succeed")
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }

    func testRejectsSymlink() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "real".write(to: dir.appendingPathComponent("real"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link"),
            withDestinationURL: dir.appendingPathComponent("real")
        )
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }

    func testRejectsTooManyFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 {
            try "x".write(to: dir.appendingPathComponent("f\(i)"), atomically: true, encoding: .utf8)
        }
        let limits = PluginSourceValidator.Limits(maxFileCount: 3, maxTotalBytes: 1_000_000)
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir, limits: limits)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }

    func testRejectsTooLarge() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "x", count: 2000).write(
            to: dir.appendingPathComponent("big"),
            atomically: true,
            encoding: .utf8
        )
        let limits = PluginSourceValidator.Limits(maxFileCount: 100, maxTotalBytes: 1000)
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir, limits: limits)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }
}
