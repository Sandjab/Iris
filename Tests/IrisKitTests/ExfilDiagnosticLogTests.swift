import Logging
import XCTest

@testable import IrisKit

/// Thread-safe sink for log records emitted by the exfil engine under test.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    func append(_ rendered: String) {
        lock.lock()
        defer { lock.unlock() }
        records.append(rendered)
    }

    /// One blob of everything logged — what a `--log-level debug` operator would see.
    func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        return records.joined(separator: "\n")
    }
}

/// Minimal `LogHandler` that renders `message` + flattened metadata into the sink.
private struct CapturingLogHandler: LogHandler {
    let sink: CapturedLog
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var rendered = message.description
        if let metadata, !metadata.isEmpty {
            let pairs = metadata.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
            rendered += " " + pairs
        }
        sink.append(rendered)
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

final class ExfilDiagnosticLogTests: XCTestCase {
    private func makeLogger(into sink: CapturedLog) -> Logger {
        var logger = Logger(label: "test.exfil.diag") { _ in CapturingLogHandler(sink: sink) }
        logger.logLevel = .debug
        return logger
    }

    /// The diagnostic line that lets us debug R3 over-blocking must show the
    /// hit inventory (names, locations, known/unknown) but NEVER the secret
    /// value — CLAUDE.md §6.1. This is the whole point of the instrumentation:
    /// it is useful for the brainstorm precisely because it is value-free.
    func testHitInventoryLogsNamesAndLocationsButNeverValue() async throws {
        let secretValue = "sk-ant-VALUE-MUST-NEVER-LEAK-IN-DIAG-LOG"
        let knownName = "anthropic_api_key"
        let unknownName = "typo_api_key"  // not in store → "unknown" in R3 design §7.1

        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(secretValue.utf8),
            named: knownName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let sink = CapturedLog()
        let engine = ExfilRuleEngine(
            secretStore: store,
            maxSubstitutionsPerMinuteProvider: { 60 },
            logger: makeLogger(into: sink)
        )

        // Two distinct names (one known, one unknown) → exactly the R3 shape we
        // are trying to understand on claude_code telemetry.
        let hits = [
            PlaceholderHit(
                name: knownName,
                location: .header(name: "x-api-key"),
                snippet: "x-api-key: {{kc:\(knownName)}}"
            ),
            PlaceholderHit(
                name: unknownName,
                location: .body,
                snippet: "...{{kc:\(unknownName)}}..."
            ),
        ]
        let decision = try await engine.evaluate(
            hits: hits,
            context: RequestContext(
                host: "api.anthropic.com",
                method: "POST",
                path: "/api/event_logging/v2/batch",
                contentType: "application/json"
            )
        )
        // Sanity: this is indeed the R3 multipleSecrets block we want to diagnose.
        guard case .block(let alert, _) = decision, alert.rule == .multipleSecrets else {
            return XCTFail("expected R3 multipleSecrets block for two distinct names")
        }

        let dump = sink.dump()

        // §6.1 — non-negotiable: the value never reaches the diagnostic log.
        XCTAssertFalse(dump.contains(secretValue), "diagnostic log leaked the secret value")
        XCTAssertFalse(dump.contains("sk-ant"), "diagnostic log leaked a secret-value prefix")

        // Useful for the brainstorm: names, the known/unknown split, locations,
        // and the distinct count are all present.
        XCTAssertTrue(dump.contains(knownName), "known placeholder name should be logged")
        XCTAssertTrue(dump.contains(unknownName), "unknown placeholder name should be logged")
        XCTAssertTrue(dump.contains("known"), "known flag should be logged")
        XCTAssertTrue(dump.contains("unknown"), "unknown flag should be logged")
        XCTAssertTrue(dump.contains("x-api-key"), "header location should be logged")
        XCTAssertTrue(dump.contains("body"), "body location should be logged")
        XCTAssertTrue(dump.contains("/api/event_logging/v2/batch"), "path should be logged")
    }

    /// At `info` (production default), the per-request inventory must stay quiet:
    /// it is a `debug` opt-in, not background spam (handoff: gate it).
    func testInventoryIsSilentBelowDebugLevel() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("v".utf8),
            named: "a",
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )
        let sink = CapturedLog()
        var logger = Logger(label: "test.exfil.info") { _ in CapturingLogHandler(sink: sink) }
        logger.logLevel = .info
        let engine = ExfilRuleEngine(
            secretStore: store,
            maxSubstitutionsPerMinuteProvider: { 60 },
            logger: logger
        )
        _ = try await engine.evaluate(
            hits: [
                PlaceholderHit(name: "a", location: .header(name: "x-api-key"), snippet: "{{kc:a}}"),
                PlaceholderHit(name: "b", location: .body, snippet: "{{kc:b}}"),
            ],
            context: RequestContext(
                host: "api.anthropic.com",
                method: "POST",
                path: "/x",
                contentType: nil
            )
        )
        XCTAssertTrue(sink.dump().isEmpty, "inventory must not log at info level")
    }
}
