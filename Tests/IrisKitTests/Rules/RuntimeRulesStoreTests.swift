import Foundation
import Logging
import XCTest

@testable import IrisKit

final class RuntimeRulesStoreTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-rules-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadEmptyWhenFileAbsent() async throws {
        let store = try await RuntimeRulesStore(
            path: tmpDir.appendingPathComponent("r.json"),
            logger: Logger(label: "t")
        )
        let rules = await store.list()
        XCTAssertEqual(rules, [])
    }

    func testAddPersistsAndIsLoadableInNewInstance() async throws {
        let path = tmpDir.appendingPathComponent("r.json")
        let logger = Logger(label: "t")
        let s1 = try await RuntimeRulesStore(path: path, logger: logger)
        let now = Date()
        _ = try await s1.add(host: "api.example.com", now: now)

        let s2 = try await RuntimeRulesStore(path: path, logger: logger)
        let rules = await s2.list()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].host, "api.example.com")
        XCTAssertEqual(rules[0].source, .runtime)
    }

    func testAddIsIdempotentBySameHost() async throws {
        let store = try await RuntimeRulesStore(
            path: tmpDir.appendingPathComponent("r.json"),
            logger: Logger(label: "t")
        )
        _ = try await store.add(host: "api.example.com", now: Date())
        _ = try await store.add(host: "api.example.com", now: Date().addingTimeInterval(60))
        let rules = await store.list()
        XCTAssertEqual(rules.count, 1, "duplicate host must not produce a second entry")
    }

    func testAddRejectsEmptyOrInvalidHost() async throws {
        let store = try await RuntimeRulesStore(
            path: tmpDir.appendingPathComponent("r.json"),
            logger: Logger(label: "t")
        )
        await assertThrowsAsync(try await store.add(host: "", now: Date()))
        await assertThrowsAsync(try await store.add(host: "has/slash", now: Date()))
        await assertThrowsAsync(try await store.add(host: "has space.com", now: Date()))
        // Uppercase: regex requires lowercase only.
        await assertThrowsAsync(try await store.add(host: "API.example.com", now: Date()))
        // Leading/trailing dot: anchored char classes forbid both ends.
        await assertThrowsAsync(try await store.add(host: ".leading-dot.com", now: Date()))
        await assertThrowsAsync(try await store.add(host: "trailing-dot.", now: Date()))
        // Length boundary: max is 253; a 254-char hostname must be rejected.
        let oversized = String(repeating: "a", count: 254)
        await assertThrowsAsync(try await store.add(host: oversized, now: Date()))
    }

    func testDeleteReturnsTrueWhenPresentAndPersists() async throws {
        let path = tmpDir.appendingPathComponent("r.json")
        let logger = Logger(label: "t")
        let s1 = try await RuntimeRulesStore(path: path, logger: logger)
        _ = try await s1.add(host: "api.example.com", now: Date())
        let removed = try await s1.delete(host: "api.example.com")
        XCTAssertTrue(removed)

        let s2 = try await RuntimeRulesStore(path: path, logger: logger)
        let afterDelete = await s2.list()
        XCTAssertEqual(afterDelete, [])
    }

    func testDeleteReturnsFalseWhenAbsent() async throws {
        let store = try await RuntimeRulesStore(
            path: tmpDir.appendingPathComponent("r.json"),
            logger: Logger(label: "t")
        )
        let removed = try await store.delete(host: "absent.example.com")
        XCTAssertFalse(removed)
    }

    func testListSortedByHost() async throws {
        let store = try await RuntimeRulesStore(
            path: tmpDir.appendingPathComponent("r.json"),
            logger: Logger(label: "t")
        )
        _ = try await store.add(host: "zebra.example.com", now: Date())
        _ = try await store.add(host: "alpha.example.com", now: Date())
        _ = try await store.add(host: "mike.example.com", now: Date())
        let hosts = await store.list().map(\.host)
        XCTAssertEqual(hosts, ["alpha.example.com", "mike.example.com", "zebra.example.com"])
    }

    func testFilePermissionsAre0600AfterWrite() async throws {
        let path = tmpDir.appendingPathComponent("r.json")
        let store = try await RuntimeRulesStore(path: path, logger: Logger(label: "t"))
        _ = try await store.add(host: "api.example.com", now: Date())
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "file must be 0600, got \(String(perm, radix: 8))")
    }

    func testCorruptedFileOnDiskDoesNotThrow() async throws {
        let path = tmpDir.appendingPathComponent("r.json")
        // Write garbage to file before initializing the store.
        try Data("not valid json {{{".utf8).write(to: path)
        let store = try await RuntimeRulesStore(path: path, logger: Logger(label: "t"))
        // Should silently degrade — list returns empty, no throw.
        let rules = await store.list()
        XCTAssertEqual(rules, [], "corrupted file must be silently ignored, not thrown")
    }
}

// MARK: - Test helpers

func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected throw" : message(), file: file, line: line)
    } catch {
        // expected
    }
}
