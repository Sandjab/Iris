import Foundation
import Logging
import XCTest

@testable import IrisKit

final class ConfigStoreTests: XCTestCase {
    var tmpDir: URL!
    var path: URL!
    let logger = Logger(label: "t")

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-configstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        path = tmpDir.appendingPathComponent("config.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testSeedsWhenFileAbsent() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let store = try ConfigStore(path: path, logger: logger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let cfg = await store.current
        XCTAssertEqual(cfg.version, 1)
        XCTAssertEqual(cfg.hosts.map(\.host), ["api.anthropic.com"])
        // Seed timestamp is "now", not the epoch sentinel.
        XCTAssertGreaterThan(cfg.hosts[0].createdAt.timeIntervalSince1970, 1_000_000_000)
        XCTAssertEqual(cfg.hosts[0].origin, .builtin)
    }

    func testSeededFilePermissionsAre0600() async throws {
        _ = try ConfigStore(path: path, logger: logger)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "got \(String(perm, radix: 8))")
    }

    func testAddHostPersistsAndReloadsInNewInstance() async throws {
        let s1 = try ConfigStore(path: path, logger: logger)
        _ = try await s1.addHost("api.example.com", now: Date())
        let s2 = try ConfigStore(path: path, logger: logger)
        let hosts = await s2.listHosts().map(\.host)
        XCTAssertEqual(hosts, ["api.anthropic.com", "api.example.com"])
    }

    func testAddHostIsIdempotent() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        _ = try await store.addHost("api.example.com", now: Date())
        _ = try await store.addHost("api.example.com", now: Date().addingTimeInterval(60))
        let count = await store.listHosts().filter { $0.host == "api.example.com" }.count
        XCTAssertEqual(count, 1)
    }

    func testAddHostRejectsInvalid() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        // Secret.isValidHost (shared validator) rejects spaces and empty hosts.
        await assertThrowsAsync(try await store.addHost("has space.com", now: Date()))
        await assertThrowsAsync(try await store.addHost("", now: Date()))
    }

    func testAddHostHasUserOrigin() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let rule = try await store.addHost("api.example.com", now: Date())
        XCTAssertEqual(rule.origin, .user)
    }

    func testDeleteUserHost() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        _ = try await store.addHost("api.example.com", now: Date())
        let removed = try await store.deleteHost("api.example.com")
        XCTAssertTrue(removed)
        let absent = try await store.deleteHost("nope.example.com")
        XCTAssertFalse(absent)
    }

    func testDeleteBuiltinHostIsRejected() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        // api.anthropic.com is seeded with origin: .builtin → protected.
        await assertThrowsAsync(try await store.deleteHost("api.anthropic.com"))
        let still = await store.listHosts().map(\.host)
        XCTAssertTrue(still.contains("api.anthropic.com"))
    }

    func testBackupCreatedForEachSave() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        // Each addHost triggers a save (and a backup of the prior file).
        for i in 0..<6 {
            _ = try await store.addHost("h\(i).example.com", now: Date().addingTimeInterval(Double(i)))
        }
        let backupsDir = tmpDir.appendingPathComponent("backups")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let backups = files.filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") }
        // Default maxCount is 10 → all 6 prior states kept.
        XCTAssertEqual(backups.count, 6)
    }

    func testBackupRotationHonoursLoweredMaxCount() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        // Lower the cap to 2 by reloading a hand-written config whose max_count=2.
        let lowered = Config(
            version: 1,
            broker: Config.default.broker,
            security: Config.default.security,
            backups: BackupsConfig(maxCount: 2),
            hosts: Config.default.hosts
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(lowered).write(to: path)
        _ = try await store.reloadFromDisk()
        for i in 0..<5 {
            _ = try await store.addHost("h\(i).example.com", now: Date().addingTimeInterval(Double(i)))
        }
        let backupsDir = tmpDir.appendingPathComponent("backups")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let backups = files.filter {
            $0.hasPrefix("config-") && $0.hasSuffix(".json") && !$0.hasPrefix("config-corrupted-")
        }
        XCTAssertLessThanOrEqual(backups.count, 2)
    }

    func testReloadFromDiskOnCorruptSurfacesErrorWithoutReseeding() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        try Data("not valid json {{{".utf8).write(to: path)
        await assertThrowsAsync(try await store.reloadFromDisk())
        // Explicit path must NOT re-seed: the corrupted bytes stay on disk.
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("not valid json"))
    }

    func testCorruptedFileRecoversAtBootDegraded() async throws {
        try Data("not valid json {{{".utf8).write(to: path)
        // Degraded boot: no throw — back up the corrupted file, re-seed defaults, flag recovery.
        let store = try ConfigStore(path: path, logger: logger)
        let recovered = await store.recoveredFromCorruption
        XCTAssertTrue(recovered)
        let cfg = await store.current
        XCTAssertEqual(cfg.hosts.map(\.host), ["api.anthropic.com"])  // defaults re-seeded
        // The main file is now valid defaults...
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("not valid json"))
        // ...and the corrupted content is preserved in a dedicated backup.
        let backupsDir = tmpDir.appendingPathComponent("backups")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("config-corrupted-") })
    }

    // MARK: - filePath

    func testFilePathReturnsResolvedPath() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let fp = await store.filePath
        XCTAssertEqual(fp, path.path)
    }

    // MARK: - applyUpdates (config.set)

    func testApplyUpdatesHotFieldPersistsAndReportsApplied() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let result = try await store.applyUpdates([
            .init(key: "security.on_exfil_attempt", value: "block_only"),
            .init(key: "security.max_substitutions_per_minute", value: "30"),
        ])
        XCTAssertEqual(
            Set(result.applied),
            ["security.on_exfil_attempt", "security.max_substitutions_per_minute"]
        )
        XCTAssertEqual(result.requiresRestart, [])
        let cfg = await store.current
        XCTAssertEqual(cfg.security.onExfilAttempt, .blockOnly)
        XCTAssertEqual(cfg.security.maxSubstitutionsPerMinute, 30)
    }

    func testApplyUpdatesStructuralFieldReportsRequiresRestart() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let result = try await store.applyUpdates([
            .init(key: "broker.listen", value: "127.0.0.1:9999")
        ])
        XCTAssertEqual(result.requiresRestart, ["broker.listen"])
        XCTAssertEqual(result.applied, [])
        let cfg = await store.current
        XCTAssertEqual(cfg.broker.listen, "127.0.0.1:9999")  // persisted regardless
    }

    func testApplyUpdatesUnknownKeyThrows() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        await assertThrowsAsync(try await store.applyUpdates([.init(key: "broker.nope", value: "x")]))
    }

    func testApplyUpdatesInvalidValueThrowsAndLeavesStateIntact() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let before = await store.current.security.maxSubstitutionsPerMinute
        await assertThrowsAsync(
            try await store.applyUpdates([.init(key: "security.max_substitutions_per_minute", value: "0")])
        )
        let after = await store.current.security.maxSubstitutionsPerMinute
        XCTAssertEqual(before, after, "rejected update must not mutate state")
    }
}
