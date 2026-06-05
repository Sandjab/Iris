import Foundation
import XCTest

@testable import IrisKit

final class ConfigCodableTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func testDefaultRoundTripsThroughJSON() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try makeEncoder().encode(Config.default)
        let decoded = try decoder.decode(Config.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.broker.listen, "127.0.0.1:8888")
        XCTAssertEqual(decoded.security.onExfilAttempt, .blockAndNotify)
        XCTAssertEqual(decoded.backups.maxCount, 10)
        XCTAssertEqual(decoded.hosts.map(\.host), ["api.anthropic.com"])
        XCTAssertEqual(decoded.hosts[0].origin, .builtin)
    }

    func testSnakeCaseKeysOnWire() throws {
        let json = String(data: try makeEncoder().encode(Config.default), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"on_exfil_attempt\""))
        XCTAssertTrue(json.contains("\"max_substitutions_per_minute\""))
        XCTAssertTrue(json.contains("\"event_retention_days\""))
        XCTAssertTrue(json.contains("\"max_count\""))
        XCTAssertTrue(json.contains("\"created_at\""))
        XCTAssertTrue(json.contains("\"origin\""))
        XCTAssertTrue(json.contains("\"default\""))  // wire value of origin for the seeded host
    }

    func testHostEntryDecodesWithoutOriginKeyAsUser() throws {
        // Robustness: a hand-edited host entry missing `origin` defaults to .user.
        let json = """
            {"host":"api.example.com","created_at":"2023-11-14T22:13:20Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HostEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.origin, .user)
        XCTAssertEqual(entry.host, "api.example.com")
    }

    func testValidateRejectsZeroBackupsMaxCount() {
        let bad = Config(
            version: 1,
            broker: Config.default.broker,
            security: Config.default.security,
            backups: BackupsConfig(maxCount: 0),
            hosts: Config.default.hosts
        )
        XCTAssertThrowsError(try bad.validate()) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "backups.max_count")
        }
    }

    func testValidateRejectsInvalidHost() {
        let bad = Config(
            version: 1,
            broker: Config.default.broker,
            security: Config.default.security,
            backups: Config.default.backups,
            hosts: [HostEntry(host: "_not_a_host_", origin: .user, createdAt: Date())]
        )
        XCTAssertThrowsError(try bad.validate()) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "hosts.host")
        }
    }
}
