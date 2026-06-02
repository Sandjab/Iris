import Foundation
import XCTest

@testable import IrisKit

final class PlaceholderFuzzTests: XCTestCase {
    private static let iterations = 2000

    /// Builds a store containing the known sentinel secret, scoped to
    /// `allowedHosts`. Default host matches the in-scope case.
    private func makeStore(allowedHosts: [String] = ["api.anthropic.com"]) async throws
        -> InMemorySecretStore
    {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(AdversarialInputGenerator.sentinel.utf8),
            named: AdversarialInputGenerator.knownSecretName,
            allowedHosts: allowedHosts,
            createdAt: Date()
        )
        return store
    }

    /// Runs the real pipeline scan → evaluate → substitute, mirroring
    /// MITMHandler. Returns the decision and, when allowed, the payload.
    private func runPipeline(
        _ input: FuzzInput,
        store: InMemorySecretStore,
        host: String,
        method: String = "POST",
        contentType: String? = "application/json"
    ) async throws -> (decision: ExfilDecision, payload: ResolvedRequestPayload?) {
        let bodyText = input.body.flatMap { String(data: $0, encoding: .utf8) }
        let hits = PlaceholderScanner.scan(headers: input.headers, uri: input.uri, body: bodyText)
        let engine = ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { 100_000 })
        let context = RequestContext(
            host: host,
            method: method,
            path: input.uri,
            contentType: contentType
        )
        let decision = try await engine.evaluate(hits: hits, context: context)
        switch decision {
        case .allow(let resolvable):
            let pe = PlaceholderEngine(secretStore: store)
            let payload = try await pe.substituteResolvable(
                headers: input.headers,
                uri: input.uri,
                body: input.body,
                resolvableHits: resolvable
            )
            return (decision, payload)
        case .block:
            return (decision, nil)
        }
    }

    private func allInputs() -> [FuzzInput] {
        AdversarialInputGenerator.namedCorpus
            + AdversarialInputGenerator.generate(count: Self.iterations)
    }

    // MARK: I1 — robustness

    // The assertion checks boundedness directly; a crash would abort the run and
    // a hang would trip the test timeout, so robustness (I1) stays fully covered.
    func testScanStaysBoundedOnAdversarialCorpus() {
        for input in allInputs() {
            let bodyText = input.body.flatMap { String(data: $0, encoding: .utf8) }
            let hits = PlaceholderScanner.scan(
                headers: input.headers,
                uri: input.uri,
                body: bodyText
            )
            let inputChars =
                input.headers.reduce(0) { $0 + $1.name.count + $1.value.count }
                + input.uri.count + (bodyText?.count ?? 0)
            XCTAssertLessThanOrEqual(
                hits.count,
                inputChars + 1,
                "hit count must stay bounded for \(input.label)"
            )
        }
    }

    func testFullPipelineNeverThrowsOnAdversarialCorpus() async throws {
        let store = try await makeStore()
        for input in allInputs() {
            _ = try await runPipeline(input, store: store, host: "api.anthropic.com")
        }
    }

    // MARK: I2 — no secret value in observation artifacts

    /// Builds the Event exactly as MITMHandler would: `path` is the ORIGINAL
    /// (pre-substitution) URI, `substitutedSecrets` holds names, `alert` carries
    /// the placeholder snippet. The sentinel value must never appear in the
    /// encoded event (this is the source of truth for the SSE `data:` line).
    private func observationEvent(
        for input: FuzzInput,
        decision: ExfilDecision,
        payload: ResolvedRequestPayload?
    ) -> Event {
        switch decision {
        case .block(let alert, _):
            return Event(
                timestamp: Date(),
                kind: .exfilBlocked,
                host: "api.anthropic.com",
                method: "POST",
                path: input.uri,
                substitutedSecrets: [],
                alert: alert
            )
        case .allow:
            let substituted = payload?.substituted ?? []
            return Event(
                timestamp: Date(),
                kind: substituted.isEmpty ? .noMatch : .substituted,
                host: "api.anthropic.com",
                method: "POST",
                path: input.uri,
                substitutedSecrets: substituted,
                alert: nil
            )
        }
    }

    func testSentinelNeverLeaksIntoEncodedEvent() async throws {
        let store = try await makeStore()
        let encoder = JSONRPCCoder.makeEncoder()
        let sentinel = AdversarialInputGenerator.sentinel
        for input in allInputs() {
            let (decision, payload) = try await runPipeline(
                input,
                store: store,
                host: "api.anthropic.com"
            )
            let event = observationEvent(for: input, decision: decision, payload: payload)
            let json = try encoder.encode(event)
            let text = String(data: json, encoding: .utf8) ?? ""
            XCTAssertFalse(
                text.contains(sentinel),
                "sentinel leaked into event for input \(input.label)"
            )
        }
    }

    // MARK: I3 — no substitution without explicit scope match

    /// Out-of-scope cases: a well-formed placeholder pointing at the known
    /// secret, where the request destination is NOT in the secret's
    /// `allowed_hosts` (R1) or sits in a non-canonical location (R2).
    private let outOfScopeCorpus: [(input: FuzzInput, host: String)] = [
        (
            FuzzInput(
                headers: [("x-api-key", "{{kc:leaky}}")],
                uri: "/v1/messages",
                body: nil,
                label: "r1-host-mismatch"
            ),
            "evil.example.com"
        ),
        (
            FuzzInput(
                headers: [("x-evil-header", "{{kc:leaky}}")],
                uri: "/v1/messages",
                body: nil,
                label: "r2-non-canonical-header"
            ),
            "api.anthropic.com"
        ),
        (
            FuzzInput(
                headers: [],
                uri: "/v1/{{kc:leaky}}/messages",
                body: nil,
                label: "r2-url-path"
            ),
            "api.anthropic.com"
        ),
        (
            FuzzInput(
                headers: [],
                uri: "/v1/messages?token={{kc:leaky}}",
                body: nil,
                label: "r2-query-string"
            ),
            "api.anthropic.com"
        ),
    ]

    func testOutOfScopePlaceholdersAreNeverSubstituted() async throws {
        let store = try await makeStore(allowedHosts: ["api.anthropic.com"])
        for (input, host) in outOfScopeCorpus {
            let (decision, payload) = try await runPipeline(input, store: store, host: host)
            guard case .block = decision else {
                XCTFail("expected block for out-of-scope case \(input.label)")
                continue
            }
            // Documents the harness contract (runPipeline returns a nil payload on
            // .block); the load-bearing production assertion is the .block guard above.
            XCTAssertNil(
                payload,
                "blocked request must not produce a substituted payload (\(input.label))"
            )
        }
    }

    func testInScopeCanonicalPlaceholderIsSubstituted() async throws {
        let store = try await makeStore(allowedHosts: ["api.anthropic.com"])
        let input = FuzzInput(
            headers: [("x-api-key", "{{kc:leaky}}")],
            uri: "/v1/messages",
            body: nil,
            label: "in-scope-canonical"
        )
        let (decision, payload) = try await runPipeline(
            input,
            store: store,
            host: "api.anthropic.com"
        )
        guard case .allow = decision else {
            return XCTFail("expected allow for in-scope canonical case")
        }
        XCTAssertEqual(payload?.substituted, [AdversarialInputGenerator.knownSecretName])
    }
}
