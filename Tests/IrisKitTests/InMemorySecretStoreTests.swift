import XCTest
@testable import IrisKit

final class InMemorySecretStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAddAndFetchValue() async throws {
        let store = InMemorySecretStore()
        let secret = try await store.add(
            Data("sk-ant-test".utf8),
            named: "anthropic_api_key",
            allowedHosts: ["api.anthropic.com"],
            createdAt: now
        )
        XCTAssertEqual(secret.name, "anthropic_api_key")
        XCTAssertEqual(secret.allowedHosts, ["api.anthropic.com"])
        XCTAssertEqual(secret.usageCount, 0)
        XCTAssertNil(secret.lastUsedAt)

        let value = try await store.value(forName: "anthropic_api_key")
        XCTAssertEqual(value, Data("sk-ant-test".utf8))
    }

    func testAddRejectsDuplicate() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v1".utf8),
            named: "dup",
            allowedHosts: ["example.com"],
            createdAt: now
        )
        do {
            _ = try await store.add(
                Data("v2".utf8),
                named: "dup",
                allowedHosts: ["example.com"],
                createdAt: now
            )
            XCTFail("expected duplicate error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .duplicate("dup"))
        }
    }

    func testAddRejectsInvalidName() async throws {
        let store = InMemorySecretStore()
        do {
            _ = try await store.add(
                Data("v".utf8),
                named: "has space",
                allowedHosts: ["example.com"],
                createdAt: now
            )
            XCTFail("expected invalidName error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .invalidName("has space"))
        }
    }

    func testAddRejectsEmptyAllowedHosts() async throws {
        let store = InMemorySecretStore()
        do {
            _ = try await store.add(
                Data("v".utf8),
                named: "no_hosts",
                allowedHosts: [],
                createdAt: now
            )
            XCTFail("expected invalidAllowedHosts error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .invalidAllowedHosts([]))
        }
    }

    func testAddRejectsInvalidHost() async throws {
        let store = InMemorySecretStore()
        do {
            _ = try await store.add(
                Data("v".utf8),
                named: "bad_host",
                allowedHosts: ["bad host"],
                createdAt: now
            )
            XCTFail("expected invalidAllowedHosts error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .invalidAllowedHosts(["bad host"]))
        }
    }

    func testFetchUnknown() async throws {
        let store = InMemorySecretStore()
        do {
            _ = try await store.value(forName: "missing")
            XCTFail("expected unknownSecret error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .unknownSecret("missing"))
        }
    }

    func testListSorted() async throws {
        let store = InMemorySecretStore()
        for name in ["zeta", "alpha", "mike"] {
            _ = try await store.add(
                Data("v".utf8),
                named: name,
                allowedHosts: ["example.com"],
                createdAt: now
            )
        }
        let list = try await store.list()
        XCTAssertEqual(list.map(\.name), ["alpha", "mike", "zeta"])
    }

    func testUpdateAllowedHosts() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v".utf8),
            named: "key",
            allowedHosts: ["a.example.com"],
            createdAt: now
        )
        let updated = try await store.update(named: "key", allowedHosts: ["b.example.com"])
        XCTAssertEqual(updated.allowedHosts, ["b.example.com"])
        let fetched = try await store.secret(named: "key")
        XCTAssertEqual(fetched.allowedHosts, ["b.example.com"])
    }

    func testRotateReplacesValueOnly() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("old".utf8),
            named: "key",
            allowedHosts: ["example.com"],
            createdAt: now
        )
        _ = try await store.rotate(named: "key", newValue: Data("new".utf8))
        let value = try await store.value(forName: "key")
        XCTAssertEqual(value, Data("new".utf8))
        let metadata = try await store.secret(named: "key")
        XCTAssertEqual(metadata.allowedHosts, ["example.com"])
        XCTAssertEqual(metadata.createdAt, now)
    }

    func testDelete() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v".utf8),
            named: "key",
            allowedHosts: ["example.com"],
            createdAt: now
        )
        try await store.delete(named: "key")
        do {
            _ = try await store.value(forName: "key")
            XCTFail("expected unknownSecret error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .unknownSecret("key"))
        }
    }

    func testDeleteUnknown() async throws {
        let store = InMemorySecretStore()
        do {
            try await store.delete(named: "ghost")
            XCTFail("expected unknownSecret error")
        } catch let error as SecretStoreError {
            XCTAssertEqual(error, .unknownSecret("ghost"))
        }
    }

    func testRecordUsageIncrementsCount() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v".utf8),
            named: "key",
            allowedHosts: ["example.com"],
            createdAt: now
        )
        let later = now.addingTimeInterval(60)
        let first = try await store.recordUsage(of: "key", at: later)
        XCTAssertEqual(first.usageCount, 1)
        XCTAssertEqual(first.lastUsedAt, later)

        let second = try await store.recordUsage(of: "key", at: later.addingTimeInterval(30))
        XCTAssertEqual(second.usageCount, 2)
    }
}
