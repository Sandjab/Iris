import XCTest

@testable import IrisKit

final class ConfigTests: XCTestCase {
    private let validTOML = """
        [broker]
        listen        = "127.0.0.1:8888"
        events_listen = "127.0.0.1:8889"
        admin_socket  = "~/Library/Application Support/iris/admin.sock"
        log_level     = "info"
        event_retention_days = 7
        event_ring_size = 10000

        [security]
        on_exfil_attempt = "block_and_notify"
        max_substitutions_per_minute = 60

        [[mitm_host]]
        host = "api.anthropic.com"

        [[mitm_host]]
        host = "api.github.com"

        [[mitm_host]]
        host = "api.openai.com"
        """

    func testParsesSPECSExample() throws {
        let config = try ConfigLoader.load(toml: validTOML)
        XCTAssertEqual(config.broker.listen, "127.0.0.1:8888")
        XCTAssertEqual(config.broker.eventsListen, "127.0.0.1:8889")
        XCTAssertEqual(config.broker.logLevel, .info)
        XCTAssertEqual(config.broker.eventRetentionDays, 7)
        XCTAssertEqual(config.broker.eventRingSize, 10_000)
        XCTAssertEqual(config.security.onExfilAttempt, .blockAndNotify)
        XCTAssertEqual(config.security.maxSubstitutionsPerMinute, 60)
        XCTAssertEqual(config.mitmHosts.count, 3)
        XCTAssertEqual(
            config.mitmHosts.map(\.host),
            [
                "api.anthropic.com",
                "api.github.com",
                "api.openai.com",
            ]
        )
    }

    func testAdminSocketTildeExpansion() throws {
        let config = try ConfigLoader.load(toml: validTOML)
        let url = config.broker.resolvedAdminSocketURL
        XCTAssertFalse(url.path.hasPrefix("~"), "tilde should be expanded")
        XCTAssertTrue(url.path.contains("Library/Application Support/iris/admin.sock"))
    }

    func testRejectsInvalidListenAddress() {
        let toml = validTOML.replacingOccurrences(of: "127.0.0.1:8888", with: "not a host:port")
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml)) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "broker.listen")
        }
    }

    func testRejectsOutOfRangePort() {
        let toml = validTOML.replacingOccurrences(of: "127.0.0.1:8888", with: "127.0.0.1:99999")
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml)) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "broker.listen")
        }
    }

    func testRejectsZeroEventRetention() {
        let toml = validTOML.replacingOccurrences(
            of: "event_retention_days = 7",
            with: "event_retention_days = 0"
        )
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml)) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "broker.event_retention_days")
        }
    }

    func testRejectsUnknownLogLevel() {
        let toml = validTOML.replacingOccurrences(
            of: "log_level     = \"info\"",
            with: "log_level     = \"verbose\""
        )
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml))
    }

    func testRejectsUnknownExfilPolicy() {
        let toml = validTOML.replacingOccurrences(
            of: "on_exfil_attempt = \"block_and_notify\"",
            with: "on_exfil_attempt = \"yolo\""
        )
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml))
    }

    func testRejectsInvalidMITMHost() {
        let toml =
            validTOML + """

                [[mitm_host]]
                host = "_not_a_host_"
                """
        XCTAssertThrowsError(try ConfigLoader.load(toml: toml)) { error in
            guard case ConfigError.invalidValue(let field, _) = error else {
                return XCTFail("expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(field, "mitm_host.host")
        }
    }

    func testFileReadFailureSurfacedAsError() {
        let url = URL(fileURLWithPath: "/nonexistent/iris-config-\(UUID()).toml")
        XCTAssertThrowsError(try ConfigLoader.load(from: url)) { error in
            guard case ConfigError.fileReadFailed = error else {
                return XCTFail("expected fileReadFailed, got \(error)")
            }
        }
    }
}
